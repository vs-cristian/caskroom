import Foundation

/// The brew commands the app uses, decoded into models.
public struct BrewService: Sendable {
    public let runner: BrewRunner

    public init(runner: BrewRunner) {
        self.runner = runner
    }

    public func installed() async throws -> [Package] {
        try await decode(["info", "--json=v2", "--installed"], BrewParser.packages)
    }

    /// brew lists a cask that updates itself only when the app on disk is older
    /// than the cask. `greedy` goes by brew's install records instead, so one
    /// that has since updated itself stays listed until brew upgrades it.
    public func outdated(greedy: Bool = false) async throws -> [OutdatedItem] {
        let flags = greedy ? ["--greedy-auto-updates"] : []
        return try await decode(["outdated", "--json=v2"] + flags, BrewParser.outdated)
    }

    /// What `brew cleanup` would free, without removing anything.
    public func cleanupPreview() async throws -> CleanupSummary {
        BrewParser.cleanup(from: try await runner.run(["cleanup", "--dry-run"]))
    }

    /// What `brew doctor` warns about; empty when it found nothing. Warnings go
    /// to stderr and make it exit 1, so that exit is a result, not a failure.
    public func doctor() async throws -> [DoctorWarning] {
        var stderr: [String] = []
        var failure: Error?
        do {
            for try await line in runner.stream(["doctor"]) where line.stream == .stderr {
                stderr.append(line.text)
            }
        } catch {
            failure = error
        }
        let warnings = BrewParser.doctor(from: stderr.joined(separator: "\n"))
        if let failure, warnings.isEmpty { throw failure }
        return warnings
    }

    /// What OSV.dev knows about the installed formulae (`brew vulns`), which
    /// sends their names and versions there. It exits 1 when it finds anything,
    /// or couldn't check everything, so that exit is a result, not a failure.
    public func vulnerabilities() async throws -> VulnerabilityReport {
        var stdout: [String] = []
        var failure: Error?
        do {
            for try await line in runner.stream(["vulns", "--json"]) where line.stream == .stdout {
                stdout.append(line.text)
            }
        } catch {
            failure = error
        }
        do {
            return try BrewParser.vulnerabilities(from: Data(stdout.joined(separator: "\n").utf8))
        } catch {
            throw failure ?? BrewError.decodingFailed(command: "brew vulns --json", message: "\(error)")
        }
    }

    /// Tapped repositories: "homebrew/core", "mongodb/brew"…
    public func taps() async throws -> [String] {
        BrewParser.names(from: try await runner.run(["tap"]))
    }

    /// What's tapped, with counts and where each comes from. Leaves out
    /// homebrew/core and homebrew/cask unless they're really tapped.
    public func tapInfo() async throws -> [Tap] {
        try await decode(["tap-info", "--json", "--installed"], BrewParser.taps)
    }

    /// What the Brewfile at `url` lists and which of it is missing here.
    /// brew evaluates the file (it's Ruby) for each of these commands.
    public func brewfilePlan(at url: URL) async throws -> BrewfilePlan {
        let file = "--file=\(url.path)"
        async let taps = runner.run(["bundle", "list", file, "--tap"])
        async let formulae = runner.run(["bundle", "list", file, "--formula"])
        async let casks = runner.run(["bundle", "list", file, "--cask"])
        async let all = runner.run(["bundle", "list", file, "--all"])
        // check exits 1 when something's missing, and says what on stderr.
        var check: [String] = []
        do {
            for try await line in runner.stream(["bundle", "check", "--verbose", "--no-upgrade", file]) {
                check.append(line.text)
            }
        } catch BrewError.commandFailed {}
        return try await BrewParser.brewfilePlan(
            taps: taps, formulae: formulae, casks: casks, all: all, check: check.joined(separator: "\n")
        )
    }

    /// `info` rather than `list`: the same rows, plus pids, log paths and
    /// whether each starts at login.
    public func services() async throws -> [ServiceEntry] {
        // With no services at all, brew may print a message instead of `[]`.
        try await decode(["services", "info", "--all", "--json"]) { data in
            data.first(where: { $0 > 0x20 }) == UInt8(ascii: "[") ? try BrewParser.services(from: data) : []
        }
    }

    public func info(_ ref: PackageRef) async throws -> Package? {
        try await info(ref.kind, [ref.name]).first
    }

    /// Info for several packages of one kind in a single brew call.
    public func info(_ kind: PackageKind, _ names: [String]) async throws -> [Package] {
        guard !names.isEmpty else { return [] }
        return try await decode(["info", "--json=v2", kind.flag] + names, BrewParser.packages)
    }

    /// How much an installed package takes up on disk ("316.4MB"); nil when
    /// brew counts nothing, as for one that isn't installed.
    public func size(of ref: PackageRef) async throws -> String? {
        let output = try await runner.run(["info", "--sizes", ref.kind.flag, ref.name])
        return BrewParser.sizes(from: output)[ref].flatMap { $0 == "0B" ? nil : $0 }
    }

    /// Every formula installing `ref` would bring along, dependencies of
    /// dependencies included, by name.
    public func allDependencies(of ref: PackageRef) async throws -> [String] {
        BrewParser.names(from: try await runner.run(["deps", ref.kind.flag, ref.name]))
    }

    /// "7.0.13", from `brew --version`.
    public func version() async throws -> String {
        let output = try await runner.run(["--version"])
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? output
        return firstLine.replacingOccurrences(of: "Homebrew ", with: "")
    }

    /// brew's cache (`brew --cache`), where it downloads; see `BrewDownloads`.
    public func cacheDirectory() async throws -> URL {
        let path = try await runner.run(["--cache"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw BrewError.decodingFailed(command: "brew --cache", message: "not a path: \(path)") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public func searchIndex() async throws -> SearchIndex {
        async let formulae = runner.run(["formulae"])
        async let casks = runner.run(["casks"])
        return try await SearchIndex(
            formulae: BrewParser.names(from: formulae),
            casks: BrewParser.names(from: casks)
        )
    }

    /// Runs the operation's steps in order, stopping at the first that fails
    /// and running its rollback, if it has one. With several steps, each one's
    /// command is logged before its output.
    public func perform(_ operation: BrewOperation) -> AsyncThrowingStream<LogLine, Error> {
        let steps = operation.steps
        if steps.count == 1 {
            return runner.stream(steps[0], allowAutoUpdate: operation.allowsAutoUpdate)
        }
        let runner = runner
        return AsyncThrowingStream { continuation in
            let task = Task {
                var completed = 0
                do {
                    for step in steps {
                        continuation.yield(LogLine(.stdout, "==> \(BrewOperation.command(step))"))
                        for try await line in runner.stream(step, allowAutoUpdate: operation.allowsAutoUpdate) {
                            continuation.yield(line)
                        }
                        // A cancelled step's stream just ends; don't go on to the next.
                        try Task.checkCancellation()
                        completed += 1
                    }
                    continuation.finish()
                } catch {
                    if let undo = operation.rollback(afterCompletedSteps: completed) {
                        continuation.yield(LogLine(.stdout, "==> \(BrewOperation.command(undo))"))
                        // Detached: when this was cancelled, the rollback still has to run.
                        _ = await Task.detached { try? await runner.run(undo) }.value
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decode<T>(_ args: [String], _ parse: (Data) throws -> T) async throws -> T {
        let output = try await runner.run(args)
        do {
            return try parse(Data(output.utf8))
        } catch {
            throw BrewError.decodingFailed(command: (["brew"] + args).joined(separator: " "), message: "\(error)")
        }
    }
}
