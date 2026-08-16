import Foundation
import FSKit

/// stat something relative to the pinned root fd, without ever path-resolving
/// ".". In self-shadow mode our own mount covers the root vnode, so resolving
/// "." would loop back into this filesystem and deadlock. fstat on the fd
/// touches the underlying vnode directly. This is the only stat helper in the
/// project — use it everywhere.
func statAt(_ rootFD: Int32, _ relpath: String) -> stat? {
    var st = stat()
    if relpath == "." {
        guard fstat(rootFD, &st) == 0 else { return nil }
    } else {
        guard fstatat(rootFD, relpath, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
    }
    return st
}

/// An item backed by a path relative to the pinned root fd, or — for the one
/// file this project exists to serve — an in-memory blob.
final class PassthroughItem: FSItem {
    /// Path relative to the volume root. The root itself is ".".
    var relpath: String
    let identifier: UInt64
    /// nil for passthrough items. A materialized virtual file keeps its
    /// identifier but drops its blob and becomes a normal passthrough item.
    private(set) var synthetic: Data?

    /// Held fd while the kernel has the item open (openItem/closeItem), or
    /// carried over from createItem. -1 when closed. POSIX checks permissions
    /// at open time, so writes to a 0444 file the caller legitimately opened
    /// (git's loose objects) must go through this fd, not a fresh openat.
    /// Guarded by the volume's cacheLock.
    var fd: Int32 = -1

    var isSynthetic: Bool { synthetic != nil }


    var fsIdentifier: FSItem.Identifier {
        FSItem.Identifier(rawValue: identifier) ?? .invalid
    }

    init(relpath: String, identifier: UInt64, synthetic: Data? = nil) {
        self.relpath = relpath
        self.identifier = identifier
        self.synthetic = synthetic
        super.init()
    }

    /// Join a directory relpath and a child name.
    static func join(_ dir: String, _ name: String) -> String {
        dir == "." ? name : dir + "/" + name
    }

    /// Id for a synthesized file, derived from the parent directory's id.
    /// The high bit keeps it clear of real APFS inode numbers.
    static func syntheticIdentifier(forDirectory id: UInt64) -> UInt64 {
        id | (1 << 63)
    }
}
