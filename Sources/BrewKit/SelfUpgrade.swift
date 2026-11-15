import Foundation

/// Updates the app that runs brew: brew replaces its bundle, so the app has to
/// be gone first. A shell in its own session waits for the app to exit, runs
/// the command, writes the output to `logURL` and, if asked, opens the app
/// again. Its own session keeps it out of the app's process group, so quitting
/// (which signals brew's groups) doesn't stop it.
public struct SelfUpgrade: Sendable {
    public let runner: BrewRunner
    /// Where the log goes, `SelfUpgrade.log`; picked up by the next launch.
    public let directory: URL

    public init(runner: BrewRunner, directory: URL) {
        self.runner = runner
        self.directory = directory
    }

    public var logURL: URL { directory.appending(path: "SelfUpgrade.log") }
    /// The log while brew writes it, renamed once brew has exited.
    var partialLogURL: URL { directory.appending(path: "SelfUpgrade.log.partial") }

    /// The log's last line, with brew's exit status after it.
    static let statusMarker = "caskroom-self-upgrade-exit:"

    private static let script = #"""
    pid=$1 brew=$2 log=$3 partial=$4 relaunch=$5 marker=$6; shift 6
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    "$brew" "$@" >"$partial" 2>&1 </dev/null
    echo "$marker $?" >>"$partial"
    mv -f "$partial" "$log"
    if [ -n "$relaunch" ]; then open "$relaunch"; fi
    """#

    /// Starts the helper: once `pid` has exited, `brew <arguments>`, then
    /// `open relaunch` if given (whether or not brew succeeded, so a failed
    /// update reopens the old version).
    public func start(_ arguments: [String], waitingFor pid: pid_t, relaunch: String?) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: logURL)
        try? fileManager.removeItem(at: partialLogURL)

        let argv = ["/bin/sh", "-c", Self.script, "sh", String(pid), runner.brewURL.path,
                    logURL.path, partialLogURL.path, relaunch ?? "", Self.statusMarker] + arguments
        let env = runner.environment(allowAutoUpdate: true).map { "\($0.key)=\($0.value)" }
        try spawnDetached(argv, environment: env)
    }

    /// How the last update went, read once: the log is deleted. Nil when there's
    /// neither a log nor a partial one.
    public func pickUp() -> Outcome? {
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: logURL)
            try? fileManager.removeItem(at: partialLogURL)
        }
        let finished = fileManager.fileExists(atPath: logURL.path)
        let url = finished ? logURL : partialLogURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let date = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .now
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var status: Int32?
        if finished, let last = lines.last, last.hasPrefix(Self.statusMarker) {
            status = Int32(last.dropFirst(Self.statusMarker.count).trimmingCharacters(in: .whitespaces))
            lines.removeLast()
        }
        return Outcome(log: lines, exitStatus: status, finishedAt: date)
    }

    public struct Outcome: Equatable, Sendable {
        /// brew's stdout and stderr, together.
        public let log: [String]
        /// nil when the helper stopped before brew exited.
        public let exitStatus: Int32?
        public let finishedAt: Date
    }
}

/// posix_spawn in a new session, with stdin, stdout and stderr on /dev/null and
/// none of this process's other descriptors.
private func spawnDetached(_ argv: [String], environment: [String]) throws {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup($0) } + [nil]
    defer {
        cArgs.forEach { free($0) }
        cEnv.forEach { free($0) }
    }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, cEnv)
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
}
