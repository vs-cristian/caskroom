import XCTest
@testable import BrewKit

/// Runs BrewRunner against a shell script standing in for brew.
final class BrewRunnerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BrewRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRunReturnsStdoutAndIgnoresStderrWarnings() async throws {
        let runner = try fakeBrew(#"echo "Warning: untrusted tap" >&2; echo one; echo two"#)
        let output = try await runner.run([])
        XCTAssertEqual(output, "one\ntwo")
    }

    func testNonZeroExitThrowsWithStderr() async throws {
        let runner = try fakeBrew(#"echo "Error: No such formula" >&2; exit 1"#)
        do {
            _ = try await runner.run(["install", "nope"])
            XCTFail("expected failure")
        } catch let BrewError.commandFailed(command, exitCode, stderr) {
            XCTAssertEqual(command, "brew install nope")
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(stderr, "Error: No such formula")
        }
    }

    func testStreamsBothPipesWithoutDeadlock() async throws {
        // Far more than a pipe buffer on each stream.
        let runner = try fakeBrew(#"for i in $(seq 1 20000); do echo "out $i"; echo "err $i" >&2; done"#)
        var out = 0, err = 0
        for try await line in runner.stream([]) {
            if line.stream == .stdout { out += 1 } else { err += 1 }
        }
        XCTAssertEqual(out, 20000)
        XCTAssertEqual(err, 20000)
    }

    func testCarriageReturnsSplitLines() async throws {
        let runner = try fakeBrew(#"printf '10%%\r50%%\r100%%\r\ndone'"#)
        var lines: [String] = []
        for try await line in runner.stream([]) { lines.append(line.text) }
        XCTAssertEqual(lines, ["10%", "50%", "100%", "done"])
    }

    func testBlankLinesSurviveButNotCRLFHalves() async throws {
        let runner = try fakeBrew(#"printf 'one\n\ntwo\r\nthree\r\n\nfour'"#)
        var lines: [String] = []
        for try await line in runner.stream([]) { lines.append(line.text) }
        XCTAssertEqual(lines, ["one", "", "two", "three", "", "four"])
    }

    func testEnvironment() async throws {
        let runner = try fakeBrew(#"echo "$HOMEBREW_NO_AUTO_UPDATE|$HOMEBREW_NO_COLOR|$PATH""#)
        let readOnly = try await runner.run([]).split(separator: "|")
        XCTAssertEqual(readOnly[0], "1")
        XCTAssertEqual(readOnly[1], "1")
        XCTAssertTrue(readOnly[2].hasPrefix(dir.path + ":"))

        let mutating = try await runner.run([], allowAutoUpdate: true)
        XCTAssertTrue(mutating.hasPrefix("|1|"))
    }

    func testCancellingTerminatesProcess() async throws {
        let marker = dir.appendingPathComponent("finished")
        let runner = try fakeBrew("echo started; sleep 5; touch '\(marker.path)'")
        let task = Task {
            for try await _ in runner.stream([]) {}
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellingTerminatesChildProcesses() async throws {
        // brew has exited, but a child it started still runs and holds the pipes open.
        let marker = dir.appendingPathComponent("finished")
        let runner = try fakeBrew("(sleep 1; touch '\(marker.path)') & echo started")
        let task = Task {
            for try await _ in runner.stream([]) {}
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAskpassIsPassedToBrew() async throws {
        let askpass = URL(fileURLWithPath: "/Applications/Caskroom.app/Contents/Helpers/CaskroomAskpass")
        let script = try fakeBrew(#"echo "$SUDO_ASKPASS""#)
        let runner = BrewRunner(brewURL: script.brewURL, askpassURL: askpass, sudoPAMFiles: [])
        let output = try await runner.run([])
        XCTAssertEqual(output, askpass.path)
    }

    func testTouchIDReplacesAskpass() async throws {
        let pam = dir.appendingPathComponent("sudo_local")
        try "auth       sufficient     pam_tid.so\n".write(to: pam, atomically: true, encoding: .utf8)
        let askpass = URL(fileURLWithPath: "/Applications/Caskroom.app/Contents/Helpers/CaskroomAskpass")
        let script = try fakeBrew(#"echo "askpass=$SUDO_ASKPASS""#)
        let runner = BrewRunner(brewURL: script.brewURL, askpassURL: askpass, sudoPAMFiles: [pam])
        let output = try await runner.run([])
        XCTAssertEqual(output, "askpass=")
    }

    func testTouchIDDetection() throws {
        func enabled(_ text: String) throws -> Bool {
            let url = dir.appendingPathComponent(UUID().uuidString)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return SudoTouchID.isEnabled(pamFiles: [url])
        }
        // macOS's /etc/pam.d/sudo_local.template, untouched and then enabled.
        XCTAssertFalse(try enabled("# sudo_local: local config file which survives system update and is included for sudo\n#auth       sufficient     pam_tid.so\n"))
        XCTAssertTrue(try enabled("# sudo_local\nauth       sufficient     pam_tid.so\n"))
        XCTAssertTrue(try enabled("auth sufficient /usr/lib/pam/pam_tid.so.2 # full path\n"))
        XCTAssertTrue(try enabled("auth\tsufficient\t/usr/lib/pam/pam_tid.so\n"))
        XCTAssertFalse(try enabled("auth required pam_opendirectory.so\n"))
        XCTAssertFalse(SudoTouchID.isEnabled(pamFiles: [dir.appendingPathComponent("missing")]))
    }

    func testDoctorWarningsAreAResultNotAFailure() async throws {
        let warned = BrewService(runner: try fakeBrew(#"echo "Warning: Unbrewed dylibs" >&2; echo "  libfoo.dylib" >&2; exit 1"#))
        let warnings = try await warned.doctor()
        XCTAssertEqual(warnings, [DoctorWarning(summary: "Unbrewed dylibs", detail: "  libfoo.dylib")])

        let clean = BrewService(runner: try fakeBrew("echo 'Your system is ready to brew.'"))
        let none = try await clean.doctor()
        XCTAssertEqual(none, [])

        let broken = BrewService(runner: try fakeBrew(#"echo "Error: something broke" >&2; exit 1"#))
        do {
            _ = try await broken.doctor()
            XCTFail("expected failure")
        } catch BrewError.commandFailed {}
    }

    func testLocate() throws {
        _ = try fakeBrew("true")
        let missing = dir.appendingPathComponent("missing").path
        let brew = dir.appendingPathComponent("brew").path
        XCTAssertEqual(BrewRunner.locate(candidates: [missing, brew])?.brewURL.path, brew)
        XCTAssertNil(BrewRunner.locate(candidates: [missing]))
    }

    func testStepsRunInOrderAndLogTheirCommands() async throws {
        let runner = try fakeBrew(#"echo "ran $*""#)
        var lines: [String] = []
        for try await line in BrewService(runner: runner).perform(.upgradeAll(greedy: false, casks: ["iina"])) {
            lines.append(line.text)
        }
        XCTAssertEqual(lines, [
            "==> brew upgrade --formula", "ran upgrade --formula",
            "==> brew upgrade --cask iina", "ran upgrade --cask iina",
        ])
    }

    func testFailedRevertRelinksTheCurrentVersion() async throws {
        // version-install fails; the unlink before it is undone.
        let log = dir.appendingPathComponent("calls")
        let runner = try fakeBrew(#"echo "$*" >> '\#(log.path)'; [ "$1" != version-install ]"#)
        var failed = false
        do {
            for try await _ in BrewService(runner: runner).perform(.revert(PackageRef(.formula, "jq"), to: "1.7", tapCore: false)) {}
        } catch {
            failed = true
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(separator: "\n"),
                       ["unlink --formula jq", "version-install jq 1.7", "link --formula jq"])
    }

    func testVulnerabilitiesFoundIsAResult() async throws {
        // brew vulns exits 1 when it finds anything; its JSON is still the answer.
        let json = #"{"findings":[{"formula":"jq","version":"1.7","vulnerabilities":[{"id":"CVE-1","severity":"HIGH","summary":"x","aliases":[],"fixed_versions":["1.7.1"]}],"patched":[]}],"skipped_formulae":[],"checked":3,"complete":true,"outdated_without_sbom":[],"unscanned_formulae":{}}"#
        let runner = try fakeBrew("echo '\(json)'; exit 1")
        let report = try await BrewService(runner: runner).vulnerabilities()
        XCTAssertEqual(report.findings.map(\.name), ["jq"])
        XCTAssertEqual(report.checked, 3)
    }

    func testVulnerabilityCheckThatFailsOutrightThrows() async throws {
        let runner = try fakeBrew(#"echo "Error: OSV.dev unreachable" >&2; exit 1"#)
        do {
            _ = try await BrewService(runner: runner).vulnerabilities()
            XCTFail("expected failure")
        } catch let BrewError.commandFailed(_, _, stderr) {
            XCTAssertEqual(stderr, "Error: OSV.dev unreachable")
        }
    }

    private func fakeBrew(_ body: String) throws -> BrewRunner {
        let url = dir.appendingPathComponent("brew")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return BrewRunner(brewURL: url)
    }
}
