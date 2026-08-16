import Foundation

/// The whole point of this filesystem.
///
/// Claude Code's resolver probes, per directory:
///   <dir>/CLAUDE.md, <dir>/.claude/CLAUDE.md, <dir>/.claude/rules/*.md, <dir>/CLAUDE.local.md
///
/// We synthesize `CLAUDE.md` when both CLAUDE.md lookups would fail and an
/// AGENTS.md is sitting right there. `.claude/rules/*.md` and CLAUDE.local.md
/// don't block synthesis on purpose: rules are additive, and CLAUDE.local.md
/// is gitignored personal state.
enum Synthesis {
    static let virtualName = "CLAUDE.md"
    static let targetName = "AGENTS.md"

    /// The virtual CLAUDE.md is a symlink to AGENTS.md — the same thing as
    /// Anthropic's documented `ln -s AGENTS.md CLAUDE.md`, synthesized. A
    /// symlink keeps us honest through kernel caches: resolving it always
    /// goes through AGENTS.md's own (correctly invalidated) cache entry, so
    /// deleting AGENTS.md makes CLAUDE.md dangle instantly. `contents` is
    /// what a read of the link itself returns.
    static let contents = Data(targetName.utf8)

    /// The full predicate. Called on lookups AND to revalidate items the
    /// kernel has cached, so it must check everything every time.
    static func shouldSynthesize(rootFD: Int32, directoryRelpath dir: String) -> Bool {
        // A real CLAUDE.md wins — never shadow one. Any type counts,
        // including a symlink.
        var st0 = stat()
        if fstatat(rootFD, PassthroughItem.join(dir, virtualName), &st0, AT_SYMLINK_NOFOLLOW) == 0 {
            return false
        }
        if statAt(rootFD, PassthroughItem.join(dir, ".claude/CLAUDE.md")) != nil {
            return false
        }
        // Only synthesize if there's something to point at: AGENTS.md must
        // be a regular file (or a symlink that resolves to one).
        var st = stat()
        guard fstatat(rootFD, PassthroughItem.join(dir, "AGENTS.md"), &st, 0) == 0 else {
            return false
        }
        return (st.st_mode & S_IFMT) == S_IFREG
    }
}
