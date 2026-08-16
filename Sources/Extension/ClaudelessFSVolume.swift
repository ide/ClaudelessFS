import Foundation
import FSKit

/// Read-write passthrough over the pinned root fd, plus the synthesized
/// CLAUDE.md. Every operation resolves fd-relative (`openat`/`fstatat`/...),
/// so the volume works the same at a separate mountpoint or mounted over its
/// own source directory (self-shadow mode).
final class ClaudelessFSVolume: FSVolume {

    private let rootFD: Int32

    /// FSKit tracks items by object identity and reclaims each one, so hand
    /// back the same instance for the same relpath while it's live.
    /// cacheLock guards the map and every item's `fd` field.
    private var itemCache: [String: PassthroughItem] = [:]
    private let cacheLock = NSLock()

    /// Root enumerations iterate a dup of rootFD, which shares its read
    /// offset with it; serialize them so concurrent readers can't collide.
    private let rootEnumLock = NSLock()

    /// Serial queue for kernel cache nudges (see scheduleNudge). Nudges run
    /// after the triggering operation has replied, so the kernel never waits
    /// on one, and this queue never blocks an FSKit operation queue.
    private let nudgeQueue = DispatchQueue(label: "claudelessfs.nudge", qos: .utility)
    /// Mount point resolved from the mount table on first nudge; nudgeQueue only.
    private var cachedMountPoint: String?
    /// Mints distinct ids for cache-nudge phantoms; guarded by cacheLock.
    private var mintSeq: UInt64 = 0
    /// Relpath a nudge is currently unlinking, or nil; guarded by cacheLock.
    /// removeItem refuses to delete anything real at this path — the nudge
    /// wants only the kernel's cache purge, never a removal.
    private var nudgeUnlinkRelpath: String?

    /// Relpaths of items whose createItem fd is (or was) held, oldest first,
    /// so descriptor pressure can evict the fds least likely to still be
    /// needed. Guarded by cacheLock.
    private var heldFDOrder: [String] = []

    init(rootFD: Int32, volumeID: FSVolume.Identifier, volumeName: FSFileName) {
        self.rootFD = rootFD
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Helpers

    private func liveItem(atRelpath relpath: String) -> PassthroughItem? {
        guard let st = statAt(rootFD, relpath) else { return nil }
        let inode = UInt64(st.st_ino)

        return cacheLock.withLock {
            if let cached = itemCache[relpath], !cached.isSynthetic, cached.identifier == inode {
                return cached
            }
            let item = PassthroughItem(relpath: relpath, identifier: inode)
            itemCache[relpath] = item
            return item
        }
    }

    private func syntheticItem(atRelpath relpath: String, inDirectory dir: PassthroughItem)
        -> PassthroughItem
    {
        cacheLock.withLock {
            if let cached = itemCache[relpath], cached.isSynthetic {
                return cached
            }
            let item = PassthroughItem(
                relpath: relpath,
                identifier: PassthroughItem.syntheticIdentifier(forDirectory: dir.identifier),
                synthetic: Synthesis.contents
            )
            itemCache[relpath] = item
            return item
        }
    }

    private func passthrough(_ item: FSItem) throws -> PassthroughItem {
        guard let item = item as? PassthroughItem else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        return item
    }

    /// The one gate for mutating operations: casts the item and refuses to
    /// mutate the virtual file, with an error that explains what to do.
    private func mutable(_ item: FSItem, _ operation: String) throws -> PassthroughItem {
        let item = try passthrough(item)
        if item.isSynthetic {
            throw fsError(EPERM,
                "can't \(operation) '\(item.relpath)' — this CLAUDE.md is virtual, made up "
                + "because AGENTS.md exists here and no real CLAUDE.md does. To replace it, "
                + "create a real CLAUDE.md or .claude/CLAUDE.md. To remove it, remove AGENTS.md.")
        }
        return item
    }

    /// The directory whose synthesis inputs a mutation at `relpath` affects,
    /// or nil if it affects none. Changing AGENTS.md or CLAUDE.md matters in
    /// their own directory; changing .claude/CLAUDE.md matters one level up.
    private func synthesisDirectory(forMutatedRelpath relpath: String) -> String? {
        let name = relpath.contains("/")
            ? String(relpath[relpath.index(after: relpath.lastIndex(of: "/")!)...])
            : relpath
        let dir = relpath.contains("/")
            ? String(relpath[..<relpath.lastIndex(of: "/")!])
            : "."
        if name == "AGENTS.md" || name == Synthesis.virtualName {
            if dir.hasSuffix(".claude") && name == Synthesis.virtualName {
                let parent = dir == ".claude" ? "." : String(dir.dropLast(".claude".count + 1))
                return parent
            }
            return dir
        }
        if name == ".claude" {
            // Renaming a whole `.claude` directory in or out (with a
            // CLAUDE.md inside) flips the parent's synthesis without ever
            // touching the watched file names.
            return dir
        }
        return nil
    }

    /// After a mutation that may change whether a directory synthesizes,
    /// nudge the kernel so its caches catch up. Our own cache needs no
    /// eviction here: lookupItem re-checks the predicate before serving the
    /// cached item, and revalidation kills a dead item at the kernel's next
    /// question about it. Keeping the instance alive matters — the kernel
    /// identifies items by instance (opaque per-item file handles), and
    /// unlink(2) internally performs two back-to-back lookups that must
    /// resolve to the same instance; when they don't, lifs silently reports
    /// success without removing anything.
    private func invalidateSynthesis(forMutatedRelpath relpath: String) {
        guard let dir = synthesisDirectory(forMutatedRelpath: relpath) else { return }
        log.info("synthesis inputs changed in \(dir, privacy: .public)")
        scheduleNudge(forDirectory: dir)
    }

    /// The kernel caches lookups of the virtual CLAUDE.md — positively (the
    /// link's vnode, attributes, and target) and negatively (ENOENT) — and
    /// on a local FSKit mount those caches never expire on their own. So
    /// when a mutation flips a directory's synthesis state, poke the kernel
    /// with a no-op namespace operation through the mount:
    ///
    /// 1. unlink(«dir»/CLAUDE.md) evicts a cached virtual link that should
    ///    now be gone. The kernel re-looks-up the name inside its remove;
    ///    lookupItem answers with the same dying item (see the nudge branch
    ///    there), removeItem confirms nothing real exists and replies
    ///    success, and on a successful remove the kernel purges the name
    ///    entry, cached attributes and symlink target, and recycles the
    ///    vnode. A still-valid link refuses the unlink and survives, and
    ///    removeItem never deletes anything real for a nudge, so this is
    ///    safe in every state.
    /// 2. create+unlink of a phantom entry (acknowledged by createItem and
    ///    removeItem without touching disk) purges the directory's negative
    ///    entries, so a virtual link that should now exist stops being
    ///    masked by a cached ENOENT.
    ///
    /// Runs on nudgeQueue after the triggering operation has replied, so
    /// even a fully serialized upcall pipeline just processes the nudge as
    /// the next ordinary operation — no cycles, no waiting.
    private func scheduleNudge(forDirectory dir: String) {
        nudgeQueue.async { [weak self] in
            guard let self, let mountPoint = self.mountPoint() else { return }
            let dirPath = dir == "." ? mountPoint : mountPoint + "/" + dir
            let virtualRelpath = PassthroughItem.join(dir, Synthesis.virtualName)
            if Synthesis.shouldSynthesize(rootFD: self.rootFD, directoryRelpath: dir) {
                let phantomPath = dirPath + "/" + Synthesis.nudgeName
                let fd = open(phantomPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if fd >= 0 { close(fd) }
                unlink(phantomPath)
                log.info("nudged \(dir, privacy: .public): negative entries purged")
            } else if statAt(self.rootFD, virtualRelpath) == nil {
                // Only when nothing real sits at the name. (When a real
                // CLAUDE.md just appeared there, the create or rename that
                // put it in place already purged the kernel's entry.) The
                // nudgeUnlinkRelpath guard makes removeItem refuse this
                // unlink even if a real file materializes mid-flight.
                self.cacheLock.withLock { self.nudgeUnlinkRelpath = virtualRelpath }
                unlink(dirPath + "/" + Synthesis.virtualName)
                self.cacheLock.withLock { self.nudgeUnlinkRelpath = nil }
                log.info("nudged \(dir, privacy: .public): virtual link evicted")
            }
        }
    }

    /// Where this volume is mounted, from the mount table: the claudelessfs
    /// entry whose source (f_mntfromname, a file:// URL) resolves to the
    /// same directory as our pinned rootFD. nudgeQueue only.
    private func mountPoint() -> String? {
        if let cached = cachedMountPoint { return cached }

        var rootPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(rootFD, F_GETPATH, &rootPath) != -1 else { return nil }
        let rootReal = String(cString: rootPath)

        var mntPtr: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mntPtr, MNT_NOWAIT)
        guard count > 0, let mounts = mntPtr else { return nil }
        defer { free(mounts) }

        func fixedString<T>(_ field: inout T) -> String {
            withUnsafeBytes(of: &field) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }

        for i in 0..<Int(count) {
            var m = mounts[i]
            guard fixedString(&m.f_fstypename) == "claudelessfs" else { continue }
            guard let url = URL(string: fixedString(&m.f_mntfromname)), url.isFileURL
            else { continue }
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(url.path, &resolved) != nil,
                  String(cString: resolved) == rootReal
            else { continue }
            let mountPoint = fixedString(&m.f_mntonname)
            cachedMountPoint = mountPoint
            return mountPoint
        }
        return nil
    }

    /// A synthetic item the kernel still holds may have stopped being valid
    /// (AGENTS.md removed, a real CLAUDE.md or .claude/CLAUDE.md created).
    /// Re-check the predicate; if it fails, evict and report ENOENT so the
    /// kernel drops its cached entry at the next attribute refresh.
    private func revalidateSynthetic(_ item: PassthroughItem) throws {
        let dir = item.relpath.contains("/")
            ? String(item.relpath[..<item.relpath.lastIndex(of: "/")!])
            : "."
        if !Synthesis.shouldSynthesize(rootFD: rootFD, directoryRelpath: dir) {
            cacheLock.withLock {
                if itemCache[item.relpath] === item {
                    itemCache.removeValue(forKey: item.relpath)
                }
            }
            log.info("revalidation KILLED virtual \(item.relpath, privacy: .public)")
            throw fs_errorForPOSIXError(ENOENT)
        }
        log.debug("revalidation kept virtual \(item.relpath, privacy: .public)")
    }

    /// Run `body` with a usable fd for the item: the held fd if the item is
    /// open, rootFD if it's the root, else a transient openat that's closed
    /// after. This is the only place that decides how to reach a file, so the
    /// "never path-resolve the root" rule lives here and nowhere else.
    private func withFD<T>(
        _ item: PassthroughItem, flags: Int32, _ body: (Int32) throws -> T
    ) throws -> T {
        let heldFD = cacheLock.withLock { item.fd }
        if heldFD >= 0 { return try body(heldFD) }
        if item.relpath == "." { return try body(rootFD) }

        let fd = openat(rootFD, item.relpath, flags | O_NOFOLLOW)
        guard fd >= 0 else { throw fs_errorForPOSIXError(errno) }
        defer { close(fd) }
        return try body(fd)
    }

    private func closeHeldFDLocked(_ item: PassthroughItem) {
        if item.fd >= 0 {
            close(item.fd)
            item.fd = -1
        }
    }

    /// Out of descriptors: close the oldest held createItem fds. They exist
    /// only so writes can reach a just-created read-only file (git's 0444
    /// loose objects), and that write follows the create within moments —
    /// the oldest fds are long past needing it. Returns whether any closed.
    private func evictHeldFDs() -> Bool {
        cacheLock.withLock {
            var closed = 0
            while closed < 256, !heldFDOrder.isEmpty {
                let relpath = heldFDOrder.removeFirst()
                if let item = itemCache[relpath], item.fd >= 0 {
                    closeHeldFDLocked(item)
                    closed += 1
                }
            }
            if closed > 0 { log.info("descriptor pressure: closed \(closed) held fds") }
            return closed > 0
        }
    }

    // MARK: - Attributes

    private func attributes(for item: PassthroughItem) throws -> FSItem.Attributes {
        if item.isPhantom { return phantomAttributes(for: item) }
        if item.isSynthetic {
            // Skip revalidation only while our own nudge is removing this
            // item; an ENOENT here would abort the kernel's remove before
            // it reaches removeItem's purge-triggering success reply.
            let dyingNudge = cacheLock.withLock { nudgeUnlinkRelpath == item.relpath }
            if !dyingNudge { try revalidateSynthetic(item) }
            return syntheticAttributes(for: item)
        }
        guard let st = statAt(rootFD, item.relpath) else {
            throw fs_errorForPOSIXError(ENOENT)
        }
        return attributes(from: st, identifier: item.identifier)
    }

    private func syntheticAttributes(for item: PassthroughItem) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        let size = UInt64(item.synthetic?.count ?? 0)
        attrs.type = .symlink
        attrs.mode = 0o120755
        attrs.linkCount = 1
        attrs.size = size
        attrs.allocSize = size
        attrs.fileID = item.fsIdentifier
        attrs.uid = getuid()
        attrs.gid = getgid()
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        attrs.modifyTime = now
        attrs.changeTime = now
        attrs.accessTime = now
        attrs.birthTime = now
        return attrs
    }

    /// A cache-nudge phantom lives for the moment between its create and its
    /// unlink; give the kernel a plausible empty file for that moment.
    private func phantomAttributes(for item: PassthroughItem) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = .file
        attrs.mode = 0o600
        attrs.linkCount = 1
        attrs.size = 0
        attrs.allocSize = 0
        attrs.fileID = item.fsIdentifier
        attrs.uid = getuid()
        attrs.gid = getgid()
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        attrs.modifyTime = now
        attrs.changeTime = now
        attrs.accessTime = now
        attrs.birthTime = now
        return attrs
    }

    /// `identifier` overrides st_ino: the root must keep reporting id 2
    /// (what `activate` promised). For everything else they're the same.
    private func attributes(from st: stat, identifier: UInt64) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = Self.itemType(fromMode: st.st_mode)
        attrs.mode = UInt32(st.st_mode) & 0o7777
        attrs.linkCount = UInt32(st.st_nlink)
        attrs.uid = st.st_uid
        attrs.gid = st.st_gid
        attrs.size = UInt64(st.st_size)
        attrs.allocSize = UInt64(st.st_blocks) * 512
        attrs.fileID = FSItem.Identifier(rawValue: identifier) ?? .invalid
        attrs.flags = st.st_flags
        attrs.modifyTime = st.st_mtimespec
        attrs.changeTime = st.st_ctimespec
        attrs.accessTime = st.st_atimespec
        attrs.birthTime = st.st_birthtimespec
        return attrs
    }

    private static func itemType(fromMode mode: mode_t) -> FSItem.ItemType {
        switch mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        case S_IFREG: return .file
        case S_IFIFO: return .fifo
        case S_IFCHR: return .charDevice
        case S_IFBLK: return .blockDevice
        case S_IFSOCK: return .socket
        default: return .unknown
        }
    }

    private static func itemType(fromDirentType dtype: UInt8) -> FSItem.ItemType {
        switch Int32(dtype) {
        case DT_DIR: return .directory
        case DT_LNK: return .symlink
        case DT_REG: return .file
        case DT_FIFO: return .fifo
        case DT_CHR: return .charDevice
        case DT_BLK: return .blockDevice
        case DT_SOCK: return .socket
        default: return .unknown
        }
    }
}

// MARK: - Core operations

extension ClaudelessFSVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = true
        caps.supportsSymbolicLinks = true
        caps.supportsPersistentObjectIDs = true
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "claudelessfs")
        var st = statfs()
        if fstatfs(rootFD, &st) == 0 {
            result.blockSize = Int(st.f_bsize)
            result.ioSize = Int(st.f_iosize)
            result.totalBlocks = st.f_blocks
            result.availableBlocks = st.f_bavail
            result.freeBlocks = st.f_bfree
            result.totalFiles = st.f_files
            result.freeFiles = st.f_ffree
        }
        return result
    }

    func activate(
        options: FSTaskOptions,
        replyHandler: @escaping (FSItem?, (any Error)?) -> Void
    ) {
        guard statAt(rootFD, ".") != nil else {
            replyHandler(nil, fs_errorForPOSIXError(errno))
            return
        }
        // The root must report id 2.
        let rootItem = PassthroughItem(
            relpath: ".",
            identifier: UInt64(FSItem.Identifier.rootDirectory.rawValue)
        )
        cacheLock.withLock { itemCache["."] = rootItem }
        replyHandler(rootItem, nil)
    }

    func deactivate(
        options: FSDeactivateOptions = [],
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        cacheLock.withLock {
            for item in itemCache.values { closeHeldFDLocked(item) }
            itemCache.removeAll()
        }
        replyHandler(nil)
    }

    func mount(options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(nil)
    }

    func unmount(replyHandler: @escaping () -> Void) {
        replyHandler()
    }

    func synchronize(
        flags: FSSyncFlags,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        replyHandler(nil)
    }

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        do {
            replyHandler(try attributes(for: try passthrough(item)), nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        do {
            let item = try mutable(item, "change attributes of")
            if item.isPhantom {
                // Accept and drop whatever macOS sets on the short-lived
                // phantom (see scheduleNudge); nothing real backs it.
                var consumed: FSItem.Attribute = []
                for attr in [FSItem.Attribute.mode, .uid, .gid, .size, .flags,
                             .accessTime, .modifyTime] where newAttributes.isValid(attr) {
                    consumed.insert(attr)
                }
                newAttributes.consumedAttributes = consumed
                replyHandler(phantomAttributes(for: item), nil)
                return
            }
            var consumed: FSItem.Attribute = []
            // Metadata setters use the *at calls (they work on symlinks,
            // which an O_NOFOLLOW open can't). The root gets the f-variants
            // on the pinned fd — never path-resolve "." (self-shadow rule).
            let isRoot = item.relpath == "."

            if newAttributes.isValid(.mode) {
                let ok = isRoot
                    ? fchmod(rootFD, mode_t(newAttributes.mode)) == 0
                    : fchmodat(rootFD, item.relpath, mode_t(newAttributes.mode),
                               AT_SYMLINK_NOFOLLOW) == 0
                guard ok else { throw fs_errorForPOSIXError(errno) }
                consumed.insert(.mode)
            }

            if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
                let uid = newAttributes.isValid(.uid) ? newAttributes.uid : UInt32.max
                let gid = newAttributes.isValid(.gid) ? newAttributes.gid : UInt32.max
                let ok = isRoot
                    ? fchown(rootFD, uid, gid) == 0
                    : fchownat(rootFD, item.relpath, uid, gid, AT_SYMLINK_NOFOLLOW) == 0
                guard ok else { throw fs_errorForPOSIXError(errno) }
                if newAttributes.isValid(.uid) { consumed.insert(.uid) }
                if newAttributes.isValid(.gid) { consumed.insert(.gid) }
            }

            if newAttributes.isValid(.size) {
                try withFD(item, flags: O_WRONLY) { fd in
                    guard ftruncate(fd, off_t(newAttributes.size)) == 0 else {
                        throw fs_errorForPOSIXError(errno)
                    }
                }
                consumed.insert(.size)
            }

            if newAttributes.isValid(.accessTime) || newAttributes.isValid(.modifyTime) {
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                             timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
                if newAttributes.isValid(.accessTime) { times[0] = newAttributes.accessTime }
                if newAttributes.isValid(.modifyTime) { times[1] = newAttributes.modifyTime }
                let ok = isRoot
                    ? futimens(rootFD, &times) == 0
                    : utimensat(rootFD, item.relpath, &times, AT_SYMLINK_NOFOLLOW) == 0
                guard ok else { throw fs_errorForPOSIXError(errno) }
                if newAttributes.isValid(.accessTime) { consumed.insert(.accessTime) }
                if newAttributes.isValid(.modifyTime) { consumed.insert(.modifyTime) }
            }

            newAttributes.consumedAttributes = consumed
            replyHandler(try attributes(for: item), nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    /// The entire reason this project exists.
    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let dir = try? passthrough(directory), let component = name.string else {
            replyHandler(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }

        let relpath = PassthroughItem.join(dir.relpath, component)

        if let found = liveItem(atRelpath: relpath) {
            replyHandler(found, name, nil)
            return
        }

        // The real lookup failed. This is the hook.
        if component == Synthesis.virtualName {
            if Synthesis.shouldSynthesize(rootFD: rootFD, directoryRelpath: dir.relpath) {
                let item = syntheticItem(atRelpath: relpath, inDirectory: dir)
                log.info("synthesized CLAUDE.md in \(dir.relpath, privacy: .public)")
                replyHandler(item, name, nil)
                return
            }
            // During our own nudge-unlink, keep answering with the cached
            // dying link: the kernel re-looks-up the name inside its remove
            // and silently drops the whole removal if the answers don't
            // match its vnode. Matching lets the remove reach removeItem,
            // where replying success triggers the kernel's full purge —
            // name-cache entry, cached attributes and symlink target, and
            // the vnode itself.
            let dying: PassthroughItem? = cacheLock.withLock {
                nudgeUnlinkRelpath == relpath ? itemCache[relpath] : nil
            }
            if let dying, dying.isSynthetic {
                replyHandler(dying, name, nil)
                return
            }
        }

        replyHandler(nil, nil, fs_errorForPOSIXError(ENOENT))
    }

    func reclaimItem(_ item: FSItem, replyHandler: @escaping ((any Error)?) -> Void) {
        if let item = try? passthrough(item) {
            cacheLock.withLock {
                closeHeldFDLocked(item)
                if itemCache[item.relpath] === item {
                    itemCache.removeValue(forKey: item.relpath)
                }
            }
        }
        replyHandler(nil)
    }

    func readSymbolicLink(
        _ item: FSItem,
        replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        guard let item = try? passthrough(item) else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        if item.isSynthetic {
            // Every traversal of the virtual link lands here, so this is
            // the revalidation point: if the directory shouldn't synthesize
            // anymore (say, .claude/CLAUDE.md appeared), kill the link.
            do {
                try revalidateSynthetic(item)
                replyHandler(FSFileName(string: Synthesis.targetName), nil)
            } catch {
                replyHandler(nil, error)
            }
            return
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlinkat(rootFD, item.relpath, &buffer, buffer.count - 1)
        guard count >= 0 else {
            replyHandler(nil, fs_errorForPOSIXError(errno))
            return
        }
        buffer[count] = 0
        replyHandler(FSFileName(string: String(cString: buffer)), nil)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes attributesRequest: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let dir = try? passthrough(directory) else {
            replyHandler(verifier, fs_errorForPOSIXError(EINVAL))
            return
        }

        // Root: dup the pinned fd — never openat(".") (self-shadow deadlock).
        let isRoot = dir.relpath == "."
        let dirfd = isRoot
            ? dup(rootFD)
            : openat(rootFD, dir.relpath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirfd >= 0 else {
            replyHandler(verifier, fs_errorForPOSIXError(errno))
            return
        }

        // Verifier: the directory's mtime, so a caller resuming with a stale
        // cookie can tell the directory changed under it.
        var dirStat = stat()
        var currentVerifier = verifier
        if fstat(dirfd, &dirStat) == 0 {
            let mtime = UInt64(truncatingIfNeeded: dirStat.st_mtimespec.tv_sec) &* 1_000_000_000
                &+ UInt64(truncatingIfNeeded: dirStat.st_mtimespec.tv_nsec)
            currentVerifier = FSDirectoryVerifier(rawValue: mtime)
        }

        guard let handle = fdopendir(dirfd) else {
            close(dirfd)
            replyHandler(currentVerifier, fs_errorForPOSIXError(errno))
            return
        }
        defer { closedir(handle) } // also closes dirfd
        if isRoot { rootEnumLock.lock() }
        defer { if isRoot { rootEnumLock.unlock() } }
        rewinddir(handle)

        var index: UInt64 = 0

        while let entry = readdir(handle) {
            var nameBuffer = entry.pointee.d_name
            let name = withUnsafePointer(to: &nameBuffer) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            index += 1
            if index <= cookie.rawValue { continue }

            // packEntry only needs a type and an id, and readdir already
            // gave us both — stat each entry only if attributes were asked for.
            var itemType = Self.itemType(fromDirentType: entry.pointee.d_type)
            var itemID = UInt64(entry.pointee.d_ino)
            var attrs: FSItem.Attributes?

            if attributesRequest != nil || itemType == .unknown {
                guard let st = statAt(rootFD, PassthroughItem.join(dir.relpath, name)) else {
                    continue
                }
                itemType = Self.itemType(fromMode: st.st_mode)
                itemID = UInt64(st.st_ino)
                if attributesRequest != nil {
                    attrs = attributes(from: st, identifier: itemID)
                }
            }

            if !packer.packEntry(
                name: FSFileName(string: name),
                itemType: itemType,
                itemID: FSItem.Identifier(rawValue: itemID) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: index),
                attributes: attrs
            ) {
                break // packer buffer is full; reply success, kernel resumes
            }
        }

        // The virtual CLAUDE.md is deliberately ABSENT here: it exists only
        // when asked for by name. Claude Code reads the exact path (a
        // lookup), while `ls`, Finder, and `git add -A` never see it — so it
        // can't get committed into repositories.
        replyHandler(currentVerifier, nil)
    }

    // MARK: Mutating operations

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        do {
            let dir = try passthrough(directory)
            guard let component = name.string else { throw fs_errorForPOSIXError(EINVAL) }
            let relpath = PassthroughItem.join(dir.relpath, component)

            if component == Synthesis.nudgeName, type == .file {
                // Cache-nudge phantom (see scheduleNudge): acknowledge the
                // create without touching disk. The kernel entering the new
                // name purges the directory's negative cache entries; the
                // paired unlink follows immediately. Never cached, never
                // enumerated, never on disk.
                let item: PassthroughItem = cacheLock.withLock {
                    mintSeq += 1
                    return PassthroughItem(
                        relpath: relpath,
                        identifier: PassthroughItem.phantomIdentifier(sequence: mintSeq),
                        phantom: true
                    )
                }
                if newAttributes.isValid(.mode) { newAttributes.consumedAttributes.insert(.mode) }
                replyHandler(item, name, nil)
                return
            }

            let mode = newAttributes.isValid(.mode)
                ? mode_t(newAttributes.mode)
                : (type == .directory ? 0o755 : 0o644)

            var createdFD: Int32 = -1
            switch type {
            case .directory:
                guard mkdirat(rootFD, relpath, mode) == 0 else {
                    throw fs_errorForPOSIXError(errno)
                }
            case .file:
                // O_RDWR, and keep the fd: the caller may write through this
                // open even when the new mode denies later opens (git creates
                // loose objects 0444 and then writes them).
                createdFD = openat(rootFD, relpath, O_CREAT | O_EXCL | O_RDWR, mode)
                if createdFD < 0 && errno == EMFILE && evictHeldFDs() {
                    createdFD = openat(rootFD, relpath, O_CREAT | O_EXCL | O_RDWR, mode)
                }
                guard createdFD >= 0 else { throw fs_errorForPOSIXError(errno) }
            default:
                throw fs_errorForPOSIXError(ENOTSUP)
            }

            guard let item = liveItem(atRelpath: relpath) else {
                if createdFD >= 0 { close(createdFD) }
                throw fs_errorForPOSIXError(EIO)
            }
            if createdFD >= 0 {
                cacheLock.withLock {
                    item.fd = createdFD
                    heldFDOrder.append(relpath)
                    // Entries whose fd has since closed linger harmlessly;
                    // compact once in a while so the list can't grow forever.
                    if heldFDOrder.count > 8192 {
                        heldFDOrder = heldFDOrder.filter { (itemCache[$0]?.fd ?? -1) >= 0 }
                    }
                }
            }
            if newAttributes.isValid(.mode) { newAttributes.consumedAttributes.insert(.mode) }
            invalidateSynthesis(forMutatedRelpath: relpath)
            replyHandler(item, name, nil)
        } catch {
            replyHandler(nil, nil, error)
        }
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        do {
            let dir = try passthrough(directory)
            guard let component = name.string, let target = contents.string else {
                throw fs_errorForPOSIXError(EINVAL)
            }
            let relpath = PassthroughItem.join(dir.relpath, component)
            guard symlinkat(target, rootFD, relpath) == 0 else {
                throw fs_errorForPOSIXError(errno)
            }
            guard let item = liveItem(atRelpath: relpath) else {
                throw fs_errorForPOSIXError(EIO)
            }
            invalidateSynthesis(forMutatedRelpath: relpath)
            replyHandler(item, name, nil)
        } catch {
            replyHandler(nil, nil, error)
        }
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        do {
            let source = try mutable(item, "hard-link")
            let dir = try passthrough(directory)
            guard let component = name.string else { throw fs_errorForPOSIXError(EINVAL) }
            let relpath = PassthroughItem.join(dir.relpath, component)
            guard linkat(rootFD, source.relpath, rootFD, relpath, 0) == 0 else {
                throw fs_errorForPOSIXError(errno)
            }
            invalidateSynthesis(forMutatedRelpath: relpath)
            replyHandler(name, nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            if let special = try? passthrough(item) {
                if special.isPhantom {
                    replyHandler(nil) // never existed on disk; nothing to do
                    return
                }
                let isNudgeTarget = cacheLock.withLock {
                    nudgeUnlinkRelpath == special.relpath
                }
                if special.isSynthetic {
                    do {
                        // A withdrawn virtual link should report ENOENT, not
                        // the explanatory EPERM; only a still-valid link
                        // refuses removal.
                        try revalidateSynthetic(special)
                    } catch {
                        guard isNudgeTarget else { throw error }
                        // Our own nudge reached the withdrawn link the kernel
                        // still holds. Nothing real exists here, so report
                        // success: the kernel purges a removed entry far more
                        // thoroughly (name cache + vnode recycle) than a
                        // failed one, which is the entire point of the nudge.
                        replyHandler(nil)
                        return
                    }
                }
                // A nudge's unlink exists for its cache purge alone; if it
                // reached something real (a CLAUDE.md that appeared while
                // the nudge was in flight), refuse rather than delete it.
                if isNudgeTarget && !special.isSynthetic {
                    throw fs_errorForPOSIXError(ENOENT)
                }
            }
            let item = try mutable(item, "remove")
            guard let st = statAt(rootFD, item.relpath) else {
                throw fs_errorForPOSIXError(errno)
            }
            let flags: Int32 = (st.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0
            guard unlinkat(rootFD, item.relpath, flags) == 0 else {
                throw fs_errorForPOSIXError(errno)
            }
            cacheLock.withLock { _ = itemCache.removeValue(forKey: item.relpath) }
            invalidateSynthesis(forMutatedRelpath: item.relpath)
            replyHandler(nil)
        } catch {
            replyHandler(error)
        }
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        do {
            let source = try mutable(item, "rename")
            let dstDir = try passthrough(destinationDirectory)
            guard let dstComponent = destinationName.string else {
                throw fs_errorForPOSIXError(EINVAL)
            }
            let dstRelpath = PassthroughItem.join(dstDir.relpath, dstComponent)
            let oldRelpath = source.relpath
            // Renaming *onto* a virtual CLAUDE.md is fine: nothing real is
            // there, and the new real file stops synthesis afterward.
            guard renameat(rootFD, oldRelpath, rootFD, dstRelpath) == 0 else {
                throw fs_errorForPOSIXError(errno)
            }

            cacheLock.withLock {
                itemCache.removeValue(forKey: oldRelpath)
                source.relpath = dstRelpath
                itemCache[dstRelpath] = source
                // The kernel keeps using its held vnodes under a renamed
                // directory — open fds, cwds, child lookups — without a
                // fresh lookup, and each one routes through the same item
                // instance. Rewrite descendant relpaths in place so every
                // held item follows the rename instead of pointing at the
                // old path (or worse, at whatever appears there next).
                let prefix = oldRelpath + "/"
                for key in itemCache.keys.filter({ $0.hasPrefix(prefix) }) {
                    guard let child = itemCache.removeValue(forKey: key) else { continue }
                    child.relpath = dstRelpath + "/" + key.dropFirst(prefix.count)
                    itemCache[child.relpath] = child
                }
            }
            invalidateSynthesis(forMutatedRelpath: oldRelpath)
            invalidateSynthesis(forMutatedRelpath: dstRelpath)

            replyHandler(destinationName, nil)
        } catch {
            replyHandler(nil, error)
        }
    }
}

// MARK: - Read / Write

extension ClaudelessFSVolume: FSVolume.ReadWriteOperations {

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler: @escaping (Int, (any Error)?) -> Void
    ) {
        do {
            let item = try passthrough(item)

            if item.isPhantom {
                replyHandler(0, nil) // phantoms are empty
                return
            }

            if let data = item.synthetic {
                try revalidateSynthetic(item)
                guard offset < data.count else {
                    replyHandler(0, nil)
                    return
                }
                let start = Int(offset)
                let count = min(length, data.count - start, buffer.length)
                buffer.withUnsafeMutableBytes { raw in
                    data.copyBytes(to: raw.bindMemory(to: UInt8.self),
                                   from: start..<(start + count))
                }
                replyHandler(count, nil)
                return
            }

            let count = try withFD(item, flags: O_RDONLY) { fd in
                buffer.withUnsafeMutableBytes { raw in
                    pread(fd, raw.baseAddress, min(length, buffer.length), offset)
                }
            }
            guard count >= 0 else { throw fs_errorForPOSIXError(errno) }
            replyHandler(count, nil)
        } catch {
            replyHandler(0, error)
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler: @escaping (Int, (any Error)?) -> Void
    ) {
        do {
            let item = try mutable(item, "write to")
            if item.isPhantom {
                replyHandler(contents.count, nil) // accepted and dropped
                return
            }
            let written = try withFD(item, flags: O_WRONLY) { fd in
                contents.withUnsafeBytes { raw in
                    pwrite(fd, raw.baseAddress, raw.count, offset)
                }
            }
            guard written >= 0 else { throw fs_errorForPOSIXError(errno) }
            replyHandler(written, nil)
        } catch {
            replyHandler(0, error)
        }
    }
}

// MARK: - Open / Close

extension ClaudelessFSVolume: FSVolume.OpenCloseOperations {

    /// Skip the open/close upcalls entirely. Every open/close pair costs
    /// multiple kernel↔fskitd↔extension round trips (~100µs even hot), on
    /// every file open under the mount. Without them, opens resolve in the
    /// kernel at near-native cost. What we give up: a held fd per kernel
    /// open. What still works: writes into just-created read-only files
    /// (git's 0444 loose objects) use the fd `createItem` keeps, and reads/
    /// writes of normal files use transient fd opens. The kernel does its
    /// own permission checks, same as APFS.
    @objc(isOpenCloseInhibited)
    var openCloseInhibited: Bool {
        log.info("openCloseInhibited read by FSKit")
        return true
    }

    func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let item = try? passthrough(item) else {
            replyHandler(fs_errorForPOSIXError(EINVAL))
            return
        }
        if item.isSynthetic {
            replyHandler(nil) // served from memory; nothing to open
            return
        }

        let error: (any Error)? = cacheLock.withLock {
            if item.fd >= 0 { return nil }
            if item.relpath == "." {
                item.fd = dup(rootFD) // never path-resolve "." (self-shadow)
            } else {
                // Widest access first — the kernel already authorized the
                // caller; we're passthrough, not a second permission check.
                var fd = openat(rootFD, item.relpath, O_RDWR | O_NOFOLLOW)
                if fd < 0 { fd = openat(rootFD, item.relpath, O_RDONLY | O_NOFOLLOW) }
                if fd < 0 && modes.contains(.write) {
                    fd = openat(rootFD, item.relpath, O_WRONLY | O_NOFOLLOW)
                }
                item.fd = fd
            }
            return item.fd >= 0 ? nil : fs_errorForPOSIXError(errno)
        }
        replyHandler(error)
    }

    func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        if let item = try? passthrough(item), modes.isEmpty {
            cacheLock.withLock { closeHeldFDLocked(item) }
        }
        replyHandler(nil)
    }
}

// MARK: - Extended attributes

extension ClaudelessFSVolume: FSVolume.XattrOperations {

    func getXattr(
        named name: FSFileName,
        of item: FSItem,
        replyHandler: @escaping (Data?, (any Error)?) -> Void
    ) {
        do {
            let item = try passthrough(item)
            guard let xname = name.string else { throw fs_errorForPOSIXError(EINVAL) }
            if item.isSynthetic || item.isPhantom { throw fs_errorForPOSIXError(ENOATTR) }

            let data = try withFD(item, flags: O_RDONLY) { fd -> Data in
                let size = fgetxattr(fd, xname, nil, 0, 0, 0)
                guard size >= 0 else { throw fs_errorForPOSIXError(errno) }
                var data = Data(count: size)
                let got = data.withUnsafeMutableBytes { raw in
                    fgetxattr(fd, xname, raw.baseAddress, size, 0, 0)
                }
                guard got >= 0 else { throw fs_errorForPOSIXError(errno) }
                return data.prefix(got)
            }
            replyHandler(data, nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    func setXattr(
        named name: FSFileName,
        to value: Data?,
        on item: FSItem,
        policy: FSVolume.SetXattrPolicy,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            let item = try mutable(item, "set an extended attribute on")
            if item.isPhantom {
                replyHandler(nil) // accept and drop (macOS writes provenance)
                return
            }
            guard let xname = name.string else { throw fs_errorForPOSIXError(EINVAL) }

            try withFD(item, flags: O_RDONLY) { fd in
                if policy == .delete || value == nil {
                    guard fremovexattr(fd, xname, 0) == 0 else {
                        throw fs_errorForPOSIXError(errno)
                    }
                } else {
                    var options: Int32 = 0
                    if policy == .mustCreate { options = XATTR_CREATE }
                    if policy == .mustReplace { options = XATTR_REPLACE }
                    let ok = value!.withUnsafeBytes { raw in
                        fsetxattr(fd, xname, raw.baseAddress, raw.count, 0, options) == 0
                    }
                    guard ok else { throw fs_errorForPOSIXError(errno) }
                }
            }
            replyHandler(nil)
        } catch {
            replyHandler(error)
        }
    }

    func listXattrs(
        of item: FSItem,
        replyHandler: @escaping ([FSFileName]?, (any Error)?) -> Void
    ) {
        do {
            let item = try passthrough(item)
            if item.isSynthetic || item.isPhantom {
                replyHandler([], nil)
                return
            }
            let names = try withFD(item, flags: O_RDONLY) { fd -> [FSFileName] in
                let size = flistxattr(fd, nil, 0, 0)
                guard size >= 0 else { throw fs_errorForPOSIXError(errno) }
                guard size > 0 else { return [] }
                var buffer = [UInt8](repeating: 0, count: size)
                let got = buffer.withUnsafeMutableBytes { raw in
                    flistxattr(fd, raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                               size, 0)
                }
                guard got >= 0 else { throw fs_errorForPOSIXError(errno) }
                // The list is NUL-separated names.
                return buffer.prefix(got).split(separator: 0).map {
                    FSFileName(string: String(decoding: $0, as: UTF8.self))
                }
            }
            replyHandler(names, nil)
        } catch {
            replyHandler(nil, error)
        }
    }
}

// MARK: - pathconf

extension ClaudelessFSVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { Int(NAME_MAX) }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max }
    var maximumXattrSize: Int { Int.max }
}
