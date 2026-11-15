import XCTest
@testable import BrewKit

final class ParserTests: XCTestCase {
    func testInstalledFormulaeAndCasks() throws {
        let packages = try BrewParser.packages(from: fixture("info-installed"))
        XCTAssertEqual(packages.filter { $0.kind == .formula }.map(\.name), ["abseil", "mysql@8.4", "node"])
        XCTAssertEqual(packages.filter { $0.kind == .cask }.map(\.name), ["claude-code", "iina", "warp"])

        let mysql = try XCTUnwrap(packages.first { $0.name == "mysql@8.4" })
        XCTAssertTrue(mysql.isInstalled)
        XCTAssertTrue(mysql.installedOnRequest)
        XCTAssertEqual(mysql.latestVersion, "8.4.13")
        XCTAssertNotNil(mysql.caveats)
        XCTAssertFalse(mysql.dependencies.isEmpty)

        let abseil = try XCTUnwrap(packages.first { $0.name == "abseil" })
        XCTAssertFalse(abseil.installedOnRequest)
        XCTAssertNil(abseil.caveats)

        let claude = try XCTUnwrap(packages.first { $0.name == "claude-code" })
        XCTAssertEqual(claude.displayName, "Claude Code")
        XCTAssertEqual(claude.installedVersions, ["2.1.311"])
        XCTAssertTrue(claude.installedOnRequest)
        XCTAssertNil(claude.appPath)  // binary only
        XCTAssertNotNil(claude.installedAt)

        let node = try XCTUnwrap(packages.first { $0.name == "node" })
        XCTAssertEqual(node.license, "MIT")
        XCTAssertNotNil(node.installedAt)
        XCTAssertTrue(node.dependencies.allSatisfy { $0.kind == .formula })
    }

    func testCaskAppPathFromArtifacts() throws {
        let packages = try BrewParser.packages(from: fixture("info-installed"))
        XCTAssertEqual(packages.first { $0.name == "iina" }?.appPath, "/Applications/IINA.app")
        XCTAssertEqual(packages.first { $0.name == "warp" }?.appPath, "/Applications/Warp.app")
    }

    func testCaskAutoUpdatesAndZap() throws {
        let packages = try BrewParser.packages(from: fixture("info-installed"))
        let iina = try XCTUnwrap(packages.first { $0.name == "iina" })
        XCTAssertTrue(iina.autoUpdates)
        XCTAssertTrue(iina.hasZap)
        let claude = try XCTUnwrap(packages.first { $0.name == "claude-code" })
        XCTAssertFalse(claude.autoUpdates)  // null in the JSON
        XCTAssertFalse(packages.first { $0.name == "node" }?.hasZap ?? true)
    }

    func testCleanupDryRun() {
        let output = """
        Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--node-24.tar.gz (21.3MB)
        Would remove (empty directory): /opt/homebrew/lib/gio
        ==> This operation would free approximately 1.2GB of disk space.
        ==> Would autoremove 2 unneeded formulae:
        libfoo
        libbar
        """
        let summary = BrewParser.cleanup(from: output)
        XCTAssertEqual(summary.reclaimable, "1.2GB")
        XCTAssertEqual(summary.unneededFormulae, ["libfoo", "libbar"])
        XCTAssertFalse(summary.isEmpty)
    }

    func testDoctorWarnings() {
        // Captured from a real `brew doctor`, plus a second warning.
        let output = """
        Please note that these warnings are just used to help the Homebrew maintainers
        with debugging if you file an issue. If everything you use Homebrew for is
        working fine: please don't worry or file an issue; just ignore this. Thanks!

        Warning: Root certificates in /etc/ssl/cert.pem can trust compromised CAs.
        Command-line tools using this file may accept forged TLS certificates:
          AAA Certificate Services

        Run `brew doctor` afterwards and after system updates, which can restore
        the roots.

        Warning: Some installed formulae are deprecated or disabled.
          libfoo

        """
        let warnings = BrewParser.doctor(from: output)
        XCTAssertEqual(warnings.map(\.summary), [
            "Root certificates in /etc/ssl/cert.pem can trust compromised CAs.",
            "Some installed formulae are deprecated or disabled.",
        ])
        XCTAssertEqual(warnings[0].detail, """
        Command-line tools using this file may accept forged TLS certificates:
          AAA Certificate Services

        Run `brew doctor` afterwards and after system updates, which can restore
        the roots.
        """)
        XCTAssertEqual(warnings[1].detail, "  libfoo")
    }

    func testDoctorWithNoWarnings() {
        XCTAssertEqual(BrewParser.doctor(from: ""), [])
    }

    func testCleanupDryRunWithNothingToFree() {
        let summary = BrewParser.cleanup(from: "Would remove (empty directory): /opt/homebrew/lib/gio\n")
        XCTAssertNil(summary.reclaimable)
        XCTAssertEqual(summary.unneededFormulae, [])
        XCTAssertTrue(summary.isEmpty)
    }

    func testCaskDependsOnIgnoresMacOSRequirement() throws {
        let packages = try BrewParser.packages(from: fixture("info-installed"))
        let iina = try XCTUnwrap(packages.first { $0.name == "iina" })
        XCTAssertEqual(iina.dependencies, [])
    }

    func testUninstalledPackage() throws {
        let json = #"{"formulae":[{"name":"tree","full_name":"tree","versions":{"stable":"2.2.1"},"installed":[],"pinned":false,"outdated":false,"caveats":"  ","dependencies":[]}],"casks":[{"token":"iterm2","name":["iTerm2"],"version":"3.5","installed":null,"depends_on":{"formula":"git"},"artifacts":[{"app":["iTerm.app"]},{"zap":[{"trash":["~/x"]}]}]}]}"#
        let packages = try BrewParser.packages(from: Data(json.utf8))
        XCTAssertFalse(packages[0].isInstalled)
        XCTAssertNil(packages[0].caveats)
        XCTAssertFalse(packages[1].isInstalled)
        XCTAssertEqual(packages[1].dependencies, [PackageRef(.formula, "git")])
        XCTAssertEqual(packages[1].appPath, "/Applications/iTerm.app")
    }

    func testOutdated() throws {
        let items = try BrewParser.outdated(from: fixture("outdated"))
        XCTAssertEqual(items.map(\.ref), [
            PackageRef(.formula, "node"), PackageRef(.formula, "mysql@8.4"), PackageRef(.cask, "iina"),
        ])
        XCTAssertEqual(items[0].installedVersions, ["26.12.0"])
        XCTAssertEqual(items[0].currentVersion, "26.13.1")
        XCTAssertTrue(items[1].pinned)
        XCTAssertFalse(items[2].pinned)
    }

    func testServices() throws {
        let services = try BrewParser.services(from: fixture("services"))
        XCTAssertEqual(services.map(\.name), ["mongodb-community@8.0", "mysql@8.4", "postgresql@18", "redis"])
        XCTAssertEqual(services[0].status, .started)
        XCTAssertTrue(services[0].status.isRunning)
        XCTAssertEqual(services[2].status, .none)
        XCTAssertNil(services[2].exitCode)
    }

    func testServiceInfo() throws {
        let services = try BrewParser.services(from: fixture("services-info"))
        XCTAssertEqual(services.map(\.name), ["mongodb-community@8.0", "mysql@8.4", "postgresql@18", "redis"])
        let mysql = services[1]
        XCTAssertEqual(mysql.status, .started)
        XCTAssertEqual(mysql.pid, 4321)
        XCTAssertTrue(mysql.registered)
        XCTAssertNil(mysql.logPath)
        let postgres = services[2]
        XCTAssertFalse(postgres.registered)
        XCTAssertNil(postgres.pid)
        XCTAssertEqual(postgres.logPath, "/opt/homebrew/var/log/postgresql@18.log")
        XCTAssertEqual(postgres.errorLogPath, "/opt/homebrew/var/log/postgresql@18.log")
        // mongodb's entry has no log keys at all.
        XCTAssertNil(services[0].logPath)
    }

    func testDeprecationReasonAndReplacement() throws {
        // Fields as `brew info --json=v2` printed them for aftman and affinity-photo.
        let json = #"""
        {"formulae":[{"name":"aftman","deprecated":true,"deprecation_date":"2025-07-19","deprecation_reason":"repo_archived",
          "deprecation_replacement_formula":"mise","deprecation_replacement_cask":null,"disabled":false,
          "disable_date":"2026-07-19","disable_reason":"repo_archived","disable_replacement_formula":"mise","disable_replacement_cask":null}],
         "casks":[{"token":"affinity-photo","deprecated":true,"deprecation_date":"2025-10-30","deprecation_reason":"discontinued",
          "deprecation_replacement_formula":null,"deprecation_replacement_cask":null,"disabled":true,"disable_date":"2026-11-01",
          "disable_reason":"discontinued","disable_replacement_formula":null,"disable_replacement_cask":"affinity"}]}
        """#
        let packages = try BrewParser.packages(from: Data(json.utf8))
        let aftman = packages[0]
        XCTAssertEqual(aftman.deprecation?.reason, "repo_archived")
        XCTAssertEqual(aftman.deprecation?.replacement, PackageRef(.formula, "mise"))
        XCTAssertEqual(aftman.deprecation?.date, Date(timeIntervalSince1970: 1_752_883_200))
        // Not disabled yet, but the date is set.
        XCTAssertFalse(aftman.disabled)
        XCTAssertNotNil(aftman.disabling?.date)

        let affinity = packages[1]
        XCTAssertNil(affinity.deprecation?.replacement)
        XCTAssertTrue(affinity.disabled)
        XCTAssertEqual(affinity.disabling?.reason, "discontinued")
        XCTAssertEqual(affinity.disabling?.replacement, PackageRef(.cask, "affinity"))

        let node = try XCTUnwrap(BrewParser.packages(from: fixture("info-installed")).first { $0.name == "node" })
        XCTAssertNil(node.deprecation)
        XCTAssertNil(node.disabling)
    }

    func testUnknownServiceStatus() throws {
        let json = #"[{"name":"x","status":"something-new","exit_code":1}]"#
        let services = try BrewParser.services(from: Data(json.utf8))
        XCTAssertEqual(services[0].status, .unknown)
        XCTAssertEqual(services[0].exitCode, 1)
    }

    func testAnalyticsTopNames() throws {
        let json = #"{"items":[{"number":2,"cask":"b"},{"number":1,"cask":"a"},{"number":3,"cask":"user/tap/c"}]}"#
        XCTAssertEqual(try HomebrewAnalytics.topNames(from: Data(json.utf8), kind: .cask), ["a", "b"])
    }

    func testAnalyticsRankingCounts() throws {
        let json = #"{"items":[{"number":1,"cask":"codex","count":"417,814"},{"number":2,"cask":"user/tap/x","count":"9"}]}"#
        let ranking = try HomebrewAnalytics.ranking(from: Data(json.utf8), kind: .cask)
        XCTAssertEqual(ranking, [HomebrewAnalytics.Entry(ref: PackageRef(.cask, "codex"), rank: 1, installs: 417_814)])
    }

    func testClimbingComparesRanks() {
        func entries(_ names: [String]) -> [HomebrewAnalytics.Entry] {
            names.enumerated().map { HomebrewAnalytics.Entry(ref: PackageRef(.formula, $1), rank: $0 + 1, installs: 100 - $0) }
        }
        let now = entries(["a", "b", "c", "d", "new"])
        let earlier = entries(["a", "c", "d", "b"])
        let climbs = HomebrewAnalytics.climbing(now: now, earlier: earlier)
        // "new" isn't in the 90 days at all: ranked just past its end (5 → 5 is no climb).
        // "b" went from 4th to 2nd; "c" and "d" fell; "a" held.
        XCTAssertEqual(climbs.map(\.ref.name), ["b"])
        XCTAssertEqual(climbs.first?.earlierRank, 4)
    }

    func testMonthlyInstallsFromPackagePage() throws {
        let formula = #"{"analytics":{"install":{"30d":{"ripgrep":46014}},"install_on_request":{"30d":{"ripgrep":35435,"ripgrep --HEAD":39}}}}"#
        XCTAssertEqual(try HomebrewAnalytics.monthlyInstalls(from: Data(formula.utf8), ref: PackageRef(.formula, "ripgrep")), 35435)
        let cask = #"{"analytics":{"install":{"30d":{"blender":35723}}}}"#
        XCTAssertEqual(try HomebrewAnalytics.monthlyInstalls(from: Data(cask.utf8), ref: PackageRef(.cask, "blender")), 35723)
    }

    func testSizes() {
        let output = """
        ==> Formulae sizes:
        mysql@8.4 316.4MB
        ripgrep        0B
        Total     316.4MB
        ==> Casks sizes:
        blender 982.8MB
        Total   982.8MB
        """
        XCTAssertEqual(BrewParser.sizes(from: output), [
            PackageRef(.formula, "mysql@8.4"): "316.4MB",
            PackageRef(.formula, "ripgrep"): "0B",
            PackageRef(.cask, "blender"): "982.8MB",
        ])
    }

    func testKegOnlyVersionsConflictsAndMacOS() throws {
        let packages = try BrewParser.packages(from: fixture("info-installed"))
        let mysql = try XCTUnwrap(packages.first { $0.name == "mysql@8.4" })
        XCTAssertTrue(mysql.kegOnly)
        XCTAssertEqual(mysql.kegOnlyReason, "versioned_formula")
        XCTAssertTrue(mysql.linked)  // linked by hand in the captured install
        XCTAssertEqual(mysql.otherVersions, [PackageRef(.formula, "mysql@9.7"), PackageRef(.formula, "mysql@8.0")])

        let abseil = try XCTUnwrap(packages.first { $0.name == "abseil" })
        XCTAssertFalse(abseil.kegOnly)

        let claude = try XCTUnwrap(packages.first { $0.name == "claude-code" })
        XCTAssertEqual(claude.conflicts, [PackageRef(.cask, "claude-code@latest")])
        XCTAssertNil(claude.minimumMacOS)

        let iina = try XCTUnwrap(packages.first { $0.name == "iina" })
        XCTAssertEqual(iina.minimumMacOS, "12")
    }

    func testNames() {
        XCTAssertEqual(BrewParser.names(from: "a\n\n b \nc"), ["a", "b", "c"])
    }

    func testDownloadURLsAndQuitDirective() throws {
        let packages = try BrewParser.packages(from: fixture("info-installed"))
        let abseil = try XCTUnwrap(packages.first { $0.name == "abseil" })
        XCTAssertEqual(abseil.downloadURL?.host(), "github.com")
        XCTAssertEqual(abseil.headURL?.absoluteString, "https://github.com/abseil/abseil-cpp.git")
        // IINA's uninstall stanza quits it, so brew quits and reopens it to upgrade; Warp's doesn't.
        XCTAssertEqual(packages.first { $0.name == "iina" }?.quitsApp, true)
        XCTAssertEqual(packages.first { $0.name == "warp" }?.quitsApp, false)
        XCTAssertEqual(packages.first { $0.name == "iina" }?.downloadURL?.absoluteString, "https://dl.iina.io/IINA.v1.5.1.dmg")
    }

    func testVulnerabilities() throws {
        let report = try BrewParser.vulnerabilities(from: fixture("vulns"))
        XCTAssertEqual(report.checked, 72)
        // Only patched findings don't count.
        XCTAssertEqual(report.findings.map(\.name), ["libxml2", "mongodb/brew/mongosh"])
        XCTAssertEqual(report.unchecked, ["abseil", "sometap-formula"])

        let libxml2 = report.findings[0]
        XCTAssertEqual(libxml2.highestSeverity, .high)
        XCTAssertEqual(libxml2.vulnerabilities.first?.id, "CVE-2025-27113")  // worst first
        XCTAssertEqual(libxml2.isFixed(by: "2.13.6"), true)
        XCTAssertEqual(libxml2.isFixed(by: "2.13.5"), false)

        let mongosh = report.findings[1]
        XCTAssertEqual(mongosh.ref, PackageRef(.formula, "mongosh"))
        XCTAssertNil(mongosh.highestSeverity)
        XCTAssertNil(mongosh.vulnerabilities[0].summary)
        // Fixed only in a commit: no telling whether a release has it.
        XCTAssertNil(mongosh.isFixed(by: "2.4.0"))
    }

    func testVersionOrder() {
        XCTAssertEqual(VersionOrder.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(VersionOrder.compare("2.13.6", "2.13.6"), .orderedSame)
        XCTAssertEqual(VersionOrder.compare("v1.2", "1.2.0"), .orderedSame)
        XCTAssertTrue(VersionOrder.isComparable("v1.2"))
        XCTAssertFalse(VersionOrder.isComparable("8a6b9e1c0d2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b"))
        XCTAssertFalse(VersionOrder.isComparable("abc"))
    }

    func testTapsLeaveOutWhatTheAPIOnlyLists() throws {
        // Captured from `brew tap-info --json --installed` (core's formula list cut short).
        let taps = try BrewParser.taps(from: fixture("tap-info"))
        XCTAssertEqual(taps.map(\.name), ["mongodb/brew"])
        let mongo = try XCTUnwrap(taps.first)
        XCTAssertEqual(mongo.formulaCount, 19)
        XCTAssertEqual(mongo.caskCount, 0)
        XCTAssertFalse(mongo.official)
        XCTAssertFalse(mongo.customRemote)
        XCTAssertEqual(mongo.webURL, URL(string: "https://github.com/mongodb/homebrew-brew"))
        XCTAssertNotNil(mongo.lastCommit)
    }

    func testTapNames() {
        XCTAssertTrue(Tap.isValidName("mongodb/brew"))
        XCTAssertTrue(Tap.isValidName("hashicorp/homebrew-tap"))
        XCTAssertTrue(Tap.isValidName("some_one/my.tap-2"))
        XCTAssertFalse(Tap.isValidName("mongodb"))
        XCTAssertFalse(Tap.isValidName("mongodb/brew/mongodb-community"))
        XCTAssertFalse(Tap.isValidName("mongodb/"))
        XCTAssertFalse(Tap.isValidName("mongodb/brew; rm -rf ~"))
        XCTAssertFalse(Tap.isValidName("../brew"))
        XCTAssertEqual(Tap(name: "a/b", remote: "git@example.com:a/b.git").webURL, nil)
        XCTAssertEqual(Tap(name: "a/b", remote: "https://example.com/a/b.git").webURL, URL(string: "https://example.com/a/b"))
    }

    func testBrewfilePlanFollowsBundleCheck() {
        // As `brew bundle list` and `brew bundle check --verbose --no-upgrade` print them.
        let check = """
        brew bundle can't satisfy your Brewfile's dependencies.
        → Tap someone/other needs to be tapped.
        → Cask zed needs to be installed.
        → VSCode Extension ms-python.python needs to be installed.
        → App Final Cut Pro needs to be installed.
        → Formula ripgrep needs to be installed.
        → Formula mongodb/brew/mongodb-community needs to be installed.
        Satisfy missing dependencies with `brew bundle install`.
        """
        let plan = BrewParser.brewfilePlan(
            taps: "mongodb/brew\nsomeone/other\n",
            formulae: "tree\nripgrep\nmongodb/brew/mongodb-community\n",
            casks: "iina\nzed\n",
            all: "mongodb/brew\nsomeone/other\ntree\nripgrep\nmongodb/brew/mongodb-community\niina\nzed\nFinal Cut Pro\nXcode\nms-python.python\n",
            check: check
        )
        XCTAssertEqual(plan.taps, [.init(name: "mongodb/brew", needed: false), .init(name: "someone/other", needed: true)])
        XCTAssertEqual(plan.formulae.filter(\.needed).map(\.name), ["ripgrep", "mongodb/brew/mongodb-community"])
        XCTAssertEqual(plan.casks.filter(\.needed).map(\.name), ["zed"])
        // Names with spaces, and kinds Caskroom doesn't know, still match.
        XCTAssertEqual(plan.other, [.init(name: "Final Cut Pro", needed: true), .init(name: "Xcode", needed: false),
                                    .init(name: "ms-python.python", needed: true)])
        XCTAssertFalse(plan.isSatisfied)
    }

    func testBrewfilePlanAllInstalled() {
        let plan = BrewParser.brewfilePlan(taps: "", formulae: "tree\n", casks: "", all: "tree\n",
                                           check: "The Brewfile's dependencies are satisfied.")
        XCTAssertEqual(plan.formulae, [.init(name: "tree", needed: false)])
        XCTAssertTrue(plan.isSatisfied)
    }

    func testBrewfileFormulaIsNotMistakenForACask() {
        // The same name as a formula and a cask: only the missing kind is needed.
        let plan = BrewParser.brewfilePlan(taps: "", formulae: "docker\n", casks: "docker\n", all: "docker\ndocker\n",
                                           check: "→ Cask docker needs to be installed.")
        XCTAssertEqual(plan.formulae, [.init(name: "docker", needed: false)])
        XCTAssertEqual(plan.casks, [.init(name: "docker", needed: true)])
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
