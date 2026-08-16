// The ClaudelessFS CLI. This binary is also the app bundle's executable —
// the bundle exists to carry the FSKit extension, and this is its only
// entry point. No GUI. Symlink it onto PATH as `claudelessfs`
// (scripts/install.sh does this).
//
// Output is plain text, one fact per line, stable order. Exit code 0 on
// success. Errors go to stderr with a reason and, where possible, a fix.

import Foundation

let moduleID = "claudelessfs.FileSystemExtension"
let fsType = "claudelessfs"

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("claudelessfs: " + message + "\n").utf8))
    exit(1)
}

/// Run a tool, stream its output through, return its exit code.
func run(_ path: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    do {
        try process.run()
    } catch {
        fail("can't run \(path): \(error.localizedDescription)")
    }
    process.waitUntilExit()
    return process.terminationStatus
}

/// Run a tool and capture its stdout.
func capture(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// All current claudelessfs mounts as (source, mountpoint).
func claudelessMounts() -> [(from: String, on: String)] {
    var buffer: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&buffer, MNT_NOWAIT)
    guard count > 0, let buffer else { return [] }
    return (0..<Int(count)).compactMap { i in
        var fs = buffer[i]
        let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard type == fsType else { return nil }
        let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let on = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return (from, on)
    }
}

let enabledPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist")

func enabledModules() -> [String] {
    guard let data = try? Data(contentsOf: enabledPlist),
          let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    else { return [] }
    return list
}

func writeEnabledModules(_ modules: [String]) {
    guard let data = try? PropertyListSerialization.data(
        fromPropertyList: modules, format: .xml, options: 0
    ) else { fail("can't serialize \(enabledPlist.path)") }
    do {
        try data.write(to: enabledPlist)
    } catch {
        fail("can't write \(enabledPlist.path): \(error.localizedDescription)")
    }
}

func restartFskitd() {
    // fskitd caches the enabled-module list, so restart it (needs sudo).
    // On a terminal, let sudo prompt like normal. Without one (an agent or
    // a script), never prompt — print the command instead of hanging.
    let sudoArgs = isatty(0) != 0
        ? ["/usr/bin/pkill", "-x", "fskitd"]
        : ["-n", "/usr/bin/pkill", "-x", "fskitd"]
    if run("/usr/bin/sudo", sudoArgs) != 0 {
        print("fskitd not restarted (no sudo). Run:  sudo pkill -x fskitd")
    }
}

func enable() {
    var modules = enabledModules()
    if modules.contains(moduleID) {
        print("already enabled")
    } else {
        modules.append(moduleID)
        writeEnabledModules(modules)
        print("enabled")
        restartFskitd()
    }
}

/// The real path of this binary, symlinks resolved. executablePath is the
/// exec path (absolute even when invoked as plain `claudelessfs` via PATH,
/// unlike argv[0]); resolving it follows the /usr/local/bin symlink back to
/// the app bundle.
let realExecutablePath = URL(
    fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]
).resolvingSymlinksInPath().path

/// The .app bundle containing this binary, or nil when running loose.
func appBundlePath() -> String? {
    var url = URL(fileURLWithPath: realExecutablePath).deletingLastPathComponent()
    while url.path != "/" {
        if url.path.hasSuffix(".app") { return url.path }
        url.deleteLastPathComponent()
    }
    return nil
}

/// Symlink this binary onto PATH as `claudelessfs`.
func linkCLI() {
    let target = realExecutablePath
    let fm = FileManager.default

    func link(at path: String) -> Bool {
        try? fm.removeItem(atPath: path)
        return (try? fm.createSymbolicLink(atPath: path, withDestinationPath: target)) != nil
    }

    if link(at: "/usr/local/bin/claudelessfs") {
        print("linked /usr/local/bin/claudelessfs")
        return
    }
    // /usr/local/bin is usually root-owned; try sudo on a terminal.
    if isatty(0) != 0,
       run("/usr/bin/sudo", ["ln", "-sf", target, "/usr/local/bin/claudelessfs"]) == 0 {
        print("linked /usr/local/bin/claudelessfs")
        return
    }
    let localBin = NSHomeDirectory() + "/.local/bin"
    try? fm.createDirectory(atPath: localBin, withIntermediateDirectories: true)
    if link(at: localBin + "/claudelessfs") {
        print("linked \(localBin)/claudelessfs (make sure ~/.local/bin is on your PATH)")
    } else {
        print("couldn't link the CLI. Run it from \(target)")
    }
}

// MARK: - Commands

let usage = """
claudelessfs — virtual CLAUDE.md for directories that only have AGENTS.md

usage:
  claudelessfs setup                            put the CLI on PATH + enable
  claudelessfs mount <directory> [mountpoint]   mount (default: over itself)
  claudelessfs unmount <mountpoint>|all         unmount one or all
  claudelessfs status                           module state and active mounts
  claudelessfs enable                           enable the FSKit module
  claudelessfs disable                          disable the FSKit module
  claudelessfs uninstall                        remove ClaudelessFS completely
"""

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "mount":
    guard args.count >= 2 else { fail("mount needs a directory.\n" + usage) }
    let source = (args[1] as NSString).standardizingPath
    let mountpoint = args.count >= 3 ? (args[2] as NSString).standardizingPath : source
    // mount(8) prints our filesystem's own error messages, which explain
    // any refusal (root volume, home directory, system paths, ...).
    exit(run("/sbin/mount", ["-F", "-t", fsType, source, mountpoint]))

case "unmount", "umount":
    guard args.count >= 2 else { fail("unmount needs a mountpoint, or 'all'.") }
    if args[1] == "all" {
        let mounts = claudelessMounts()
        if mounts.isEmpty { print("no \(fsType) mounts") }
        for mount in mounts {
            print("unmounting \(mount.on)")
            if run("/sbin/umount", [mount.on]) != 0 {
                _ = run("/sbin/umount", ["-f", mount.on])
            }
        }
        exit(0)
    }
    exit(run("/sbin/umount", [(args[1] as NSString).standardizingPath]))

case "status":
    let enabled = enabledModules().contains(moduleID)
    print("module: \(moduleID)")
    print("enabled: \(enabled)")
    let mounts = claudelessMounts()
    print("mounts: \(mounts.count)")
    for mount in mounts {
        print("  \(mount.from) on \(mount.on)")
    }
    exit(0)

case "setup":
    // Register the extension with pluginkit. Copying the app into place
    // doesn't reliably do this on its own, and an unregistered module fails
    // to mount with ExtensionKit error 2. Registration can also lag right
    // after the app lands in /Applications, so verify and retry.
    if let bundle = appBundlePath() {
        let appex = bundle + "/Contents/Extensions/ClaudelessFSExtension.appex"
        if FileManager.default.fileExists(atPath: appex) {
            var registered = false
            for _ in 0..<10 {
                _ = run("/usr/bin/pluginkit", ["-a", appex])
                usleep(500_000)
                if capture("/usr/bin/pluginkit", ["-m", "-i", moduleID]).contains(moduleID) {
                    registered = true
                    break
                }
            }
            print(registered
                ? "registered the file system extension"
                : "warning: extension didn't register; run:  pluginkit -a \(appex)")
        }
    }
    linkCLI()
    enable()
    print("ready. Try:  claudelessfs mount <directory>")
    exit(0)

case "enable":
    enable()
    exit(0)

case "disable":
    let modules = enabledModules()
    if !modules.contains(moduleID) {
        print("already disabled")
    } else {
        writeEnabledModules(modules.filter { $0 != moduleID })
        print("disabled")
        restartFskitd()
    }
    exit(0)

case "uninstall":
    // Unmount everything first so the extension lets go of its fds.
    for mount in claudelessMounts() {
        print("unmounting \(mount.on)")
        if run("/sbin/umount", [mount.on]) != 0 {
            _ = run("/sbin/umount", ["-f", mount.on])
        }
    }
    _ = run("/usr/bin/pkill", ["-f", "ClaudelessFSExtension"])

    // Purge every ClaudelessFS module id, including ones from older builds
    // that used different identifiers.
    let modules = enabledModules()
    let kept = modules.filter { !$0.lowercased().contains("claudelessfs") }
    if kept.count != modules.count {
        writeEnabledModules(kept)
        print("disabled the file system extension")
        restartFskitd()
    }

    let fm = FileManager.default
    for link in ["/usr/local/bin/claudelessfs", NSHomeDirectory() + "/.local/bin/claudelessfs"]
    where (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
        try? fm.removeItem(atPath: link)
        print("removed \(link)")
    }

    // Deleting the running binary's own bundle is fine on macOS: the unlink
    // succeeds and this process keeps running to the end.
    if let bundle = appBundlePath() {
        do {
            try fm.removeItem(atPath: bundle)
            print("removed \(bundle)")
        } catch {
            print("couldn't remove \(bundle): \(error.localizedDescription)")
        }
    }
    print("uninstalled")
    exit(0)

case nil, "help", "--help", "-h":
    print(usage)
    exit(0)

case let other?:
    fail("unknown command '\(other)'.\n" + usage)
}
