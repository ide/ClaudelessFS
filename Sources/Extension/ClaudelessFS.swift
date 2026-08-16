import CryptoKit
import Foundation
import FSKit
import os

let log = Logger(subsystem: "claudelessfs", category: "fs")

/// An NSError whose description tells the user what went wrong and what to
/// do about it. `mount` prints the description, and the same text lands in
/// the unified log. Use `fs_errorForPOSIXError` instead when just forwarding
/// an errno with nothing to explain.
func fsError(_ code: Int32, _ message: String) -> NSError {
    let message = "ClaudelessFS: " + message
    log.error("\(message, privacy: .public)")
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
        NSLocalizedDescriptionKey: message,
    ])
}

final class ClaudelessFS: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    /// Keeps the volume alive for the life of the mount.
    private var volume: ClaudelessFSVolume?
    private var rootFD: Int32 = -1
    /// URL we hold security-scoped access to; released in unload.
    private var scopedURL: URL?

    // MARK: - Preflight

    private static let mountExample = "mount -F -t claudelessfs ~/Developer ~/Developer"

    /// Why we refuse to cover this directory, or nil if it's fine.
    private static func refusalReason(forResolvedPath path: String) -> String? {
        if path == "/" || path == "/System/Volumes/Data" {
            return "covering the root volume is impossible: macOS seals the system volume, "
                + "and no mount can cover the root vnode. Cover a subtree instead, "
                + "e.g.: \(mountExample)"
        }

        if path == realHomeDirectory() {
            return "refusing to cover your home directory. ~/Library (keychain, preferences, "
                + "and this extension's own container) would route every I/O through "
                + "ClaudelessFS, and a crash would hang your login session. Cover a project "
                + "tree instead, e.g.: \(mountExample)"
        }

        let system: Set<String> = [
            "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
            "/private", "/private/etc", "/private/var", "/private/tmp",
            "/etc", "/var", "/tmp", "/dev", "/Users", "/Volumes", "/opt",
        ]
        if system.contains(path) {
            return "refusing to cover system directory '\(path)': macOS and running apps "
                + "depend on it, and routing it through a userspace filesystem risks "
                + "system-wide hangs. Cover a project tree instead, e.g.: \(mountExample)"
        }
        return nil
    }

    private static func preflight(sourcePath rawPath: String) -> NSError? {
        var st = stat()
        guard lstat(rawPath, &st) == 0 else {
            return fsError(ENOENT,
                "source '\(rawPath)' does not exist. Pass the directory to serve "
                + "(and optionally cover), e.g.: \(mountExample)")
        }
        // Resolve symlinks so /tmp/foo and /private/tmp/foo get the same answer.
        let path = (rawPath as NSString).resolvingSymlinksInPath
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return fsError(ENOTDIR,
                "source '\(rawPath)' is not a directory. ClaudelessFS serves a directory "
                + "tree; it has no use for files or block devices.")
        }
        if let reason = refusalReason(forResolvedPath: path) {
            return fsError(EPERM, reason)
        }
        return nil
    }

    private static func realHomeDirectory() -> String {
        // NSHomeDirectory() is the sandbox container in an appex; ask passwd.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return "/Users/" + NSUserName()
    }

    // MARK: - FSUnaryFileSystemOperations

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let pathResource = resource as? FSPathURLResource else {
            replyHandler(nil, fsError(EINVAL,
                "expected a directory path, not a block device or URL. "
                + "Mount with: mount -F -t claudelessfs <directory> <mountpoint>"))
            return
        }

        let scoped = pathResource.url.startAccessingSecurityScopedResource()
        defer {
            if scoped { pathResource.url.stopAccessingSecurityScopedResource() }
        }

        let path = pathResource.url.path
        if let error = Self.preflight(sourcePath: path) {
            replyHandler(nil, error)
            return
        }

        replyHandler(
            FSProbeResult.usable(
                name: "ClaudelessFS",
                containerID: FSContainerIdentifier(uuid: Self.stableUUID(for: path))
            ),
            nil
        )
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let pathResource = resource as? FSPathURLResource else {
            replyHandler(nil, fsError(EINVAL, "expected a directory path resource."))
            return
        }

        // Hold scoped access for the volume's lifetime; released in unload.
        if pathResource.url.startAccessingSecurityScopedResource() {
            scopedURL = pathResource.url
        }

        let path = pathResource.url.path
        if let error = Self.preflight(sourcePath: path) {
            replyHandler(nil, error)
            return
        }

        // createItem keeps an fd per new file until the kernel reclaims the
        // item, and reclaim can lag far behind a mass creation (untar, git
        // checkout). At the appex default of 256 descriptors that EMFILEs
        // around file #250, so raise the limit to what the system allows.
        var maxFilesPerProc: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.maxfilesperproc", &maxFilesPerProc, &size, nil, 0)
        var lim = rlimit()
        if getrlimit(RLIMIT_NOFILE, &lim) == 0 {
            let rlimInfinity = rlim_t(Int64.max) // RLIM_INFINITY, unimported by Swift
            let target = rlim_t(max(maxFilesPerProc, 10240))
            lim.rlim_cur = lim.rlim_max == rlimInfinity ? target : min(target, lim.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &lim) != 0 {
                lim.rlim_cur = 10240
                setrlimit(RLIMIT_NOFILE, &lim)
            }
            log.info("descriptor limit now \(lim.rlim_cur)")
        }

        // Pin the source directory NOW, before any mount covers it. Every
        // volume operation resolves relative to this fd, which keeps pointing
        // at the underlying directory even when ClaudelessFS is mounted over
        // its own source (self-shadow mode).
        rootFD = open(path, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else {
            let err = errno
            replyHandler(nil, fsError(err,
                "can't open source directory '\(path)' "
                + "(\(String(cString: strerror(err)))). The extension is sandboxed; if this "
                + "is EPERM, the FSKit security-scoped grant didn't arrive — check that "
                + "FSRequiresSecurityScopedPathURLResources is true in the module's Info.plist."))
            return
        }

        log.info("load: \(path, privacy: .public) fd=\(self.rootFD)")

        volume = ClaudelessFSVolume(
            rootFD: rootFD,
            volumeID: FSVolume.Identifier(uuid: Self.stableUUID(for: path)),
            volumeName: FSFileName(string: "ClaudelessFS")
        )
        // Containers start "not ready", which mount reports as EAGAIN
        // ("Resource temporarily unavailable"). Declare readiness.
        containerStatus = .ready
        replyHandler(volume, nil)
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        volume = nil
        if rootFD >= 0 {
            close(rootFD)
            rootFD = -1
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        replyHandler(nil)
    }

    /// Deterministic UUID from the source path, so remounting the same
    /// directory identifies as the same container.
    private static func stableUUID(for path: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(path.utf8)) // 16 bytes
        return digest.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}
