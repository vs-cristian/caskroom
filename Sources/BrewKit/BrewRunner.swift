import Foundation

public enum BrewError: Error, LocalizedError, Equatable {
    case brewNotFound
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case decodingFailed(command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Homebrew was not found in /opt/homebrew or /usr/local."
        case let .commandFailed(command, exitCode, stderr):
            let detail = stderr.isEmpty ? "" : "\n\(stderr)"
            return "`\(command)` exited with status \(exitCode).\(detail)"
        case let .decodingFailed(command, message):
            return "Couldn't read the output of `\(command)`: \(message)"
        }
    }
}

public struct LogLine: Hashable, Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public let stream: Stream
    public let text: String

    public init(_ stream: Stream, _ text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Runs the `brew` binary. Both stdout and stderr are drained concurrently, so a
/// command that writes heavily to both (install, upgrade) can't fill a pipe and
/// stall.
public struct BrewRunner: Sendable {
    public static let defaultCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public let brewURL: URL
    /// Passed to brew as `SUDO_ASKPASS`, so `sudo -A` can ask for a password
    /// without a terminal. Without it, anything that needs sudo fails.
    public let askpassURL: URL?
    /// Checked before every command for Touch ID (see `SudoTouchID`), which
    /// replaces the askpass helper when enabled.
    public let sudoPAMFiles: [URL]

    public init(brewURL: URL, askpassURL: URL? = nil, sudoPAMFiles: [URL] = SudoTouchID.defaultPAMFiles) {
        self.brewURL = brewURL
        self.askpassURL = askpassURL
        self.sudoPAMFiles = sudoPAMFiles
    }

    /// Where Homebrew links what it installs: /opt/homebrew, or /usr/local on Intel.
    public var prefix: String {
        brewURL.deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// The first existing brew among `candidates`, or nil when Homebrew isn't installed.
    public static func locate(candidates: [String] = defaultCandidates, askpassURL: URL? = nil) -> BrewRunner? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { BrewRunner(brewURL: URL(fileURLWithPath: $0), askpassURL: askpassURL) }
    }

    /// Run `brew <args>` to completion and return its stdout. Throws
    /// `BrewError.commandFailed` on a non-zero exit. Warnings on stderr are ignored
    /// unless the command fails.
    public func run(_ args: [String], allowAutoUpdate: Bool = false) async throws -> String {
        var out: [String] = []
        for try await line in stream(args, allowAutoUpdate: allowAutoUpdate) where line.stream == .stdout {
            out.append(line.text)
        }
        return out.joined(separator: "\n")
    }

    /// Run `brew <args>`, yielding output lines as they arrive. The stream throws
    /// `BrewError.commandFailed` after the last line if the exit status is non-zero.
    /// Cancelling the consuming task terminates brew and everything it started.
    public func stream(_ args: [String], allowAutoUpdate: Bool = false) -> AsyncThrowingStream<LogLine, Error> {
        launch(brewURL, args, command: (["brew"] + args).joined(separator: " "), environment: environment(allowAutoUpdate: allowAutoUpdate))
    }

    /// Runs `script` with `/bin/sh` as root, through sudo: Touch ID when it's
    /// on, else the askpass helper's password dialog, which says `reason`.
    /// Fails without either, since there's no terminal to ask in.
    public func privileged(_ script: String, reason: String) -> AsyncThrowingStream<LogLine, Error> {
        var env = environment(allowAutoUpdate: false)
        let askpass = env["SUDO_ASKPASS"] != nil
        if askpass { env["CASKROOM_ASKPASS_REASON"] = reason }
        let args = (askpass ? ["-A"] : []) + ["/bin/sh", "-c", script]
        return launch(URL(fileURLWithPath: "/usr/bin/sudo"), args, command: "sudo sh -c …", environment: env)
    }

    private func launch(_ executable: URL, _ args: [String], command: String, environment: [String: String]) -> AsyncThrowingStream<LogLine, Error> {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // No terminal: anything that would prompt fails fast instead of hanging.
        // sudo asks through SUDO_ASKPASS instead.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // The stream ends once both pipes hit EOF and the process has exited.
        // Exit is observed through terminationHandler: waitUntilExit on a
        // dispatch worker depends on a run loop and can miss the exit.
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                // Process makes brew a process-group leader, and everything it
                // spawns (curl, installers, sudo and its prompt) joins that group.
                // Signal the group even after brew itself has exited: a child
                // can outlive it and keep the stream open.
                if case .cancelled = termination, process.processIdentifier > 0 {
                    killpg(process.processIdentifier, SIGTERM)
                }
            }

            do {
                try process.run()
            } catch {
                group.leave()
                continuation.finish(throwing: BrewError.brewNotFound)
                return
            }

            let stderrTail = TailBuffer(limit: 40)
            for (pipe, kind) in [(outPipe, LogLine.Stream.stdout), (errPipe, .stderr)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    readLines(from: pipe.fileHandleForReading) { text in
                        if kind == .stderr { stderrTail.append(text) }
                        continuation.yield(LogLine(kind, text))
                    }
                    group.leave()
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                if process.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: BrewError.commandFailed(
                        command: command,
                        exitCode: process.terminationStatus,
                        stderr: stderrTail.joined()
                    ))
                }
            }
        }
    }

    func environment(allowAutoUpdate: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // An app launched from Finder gets a bare PATH; brew and the tools it
        // shells out to need its own bin and the system dirs.
        let brewBin = brewURL.deletingLastPathComponent().path
        let path = [brewBin, "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"]]
            .compactMap { $0 }
            .joined(separator: ":")
        env["PATH"] = path
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        // Read per command, so turning Touch ID on or off applies without a relaunch.
        if SudoTouchID.isEnabled(pamFiles: sudoPAMFiles) {
            env.removeValue(forKey: "SUDO_ASKPASS")
        } else if let askpassURL {
            env["SUDO_ASKPASS"] = askpassURL.path
        }
        if allowAutoUpdate {
            env.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
        } else {
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return env
    }
}

/// Reads `handle` to EOF, calling `onLine` for each line. `\r` counts as a line
/// break too, so progress output that redraws in place arrives as separate lines.
/// A blank line is kept only as `\n` after `\n`: an empty piece after `\r` is the
/// rest of a `\r\n`, or a redraw.
private func readLines(from handle: FileHandle, onLine: (String) -> Void) {
    var buffer = Data()
    var previousBreak: UInt8?
    func emit(_ range: Range<Data.Index>, endingWith lineBreak: UInt8?) {
        let text = String(decoding: buffer[range], as: UTF8.self)
        if !text.isEmpty || (lineBreak == 0x0A && previousBreak == 0x0A) { onLine(text) }
        previousBreak = lineBreak
    }
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        // Emit every complete line, then drop them in one go: removing per line
        // would shift the rest of the buffer each time.
        var lineStart = buffer.startIndex
        for index in buffer.indices where buffer[index] == 0x0A || buffer[index] == 0x0D {
            emit(lineStart..<index, endingWith: buffer[index])
            lineStart = index + 1
        }
        buffer.removeSubrange(buffer.startIndex..<lineStart)
    }
    emit(buffer.startIndex..<buffer.endIndex, endingWith: nil)
}

/// The last `limit` lines appended, thread-safe.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func joined() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
