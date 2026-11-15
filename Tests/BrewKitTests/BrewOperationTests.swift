import XCTest
@testable import BrewKit

final class BrewOperationTests: XCTestCase {
    func testArgumentsCarryKindFlag() {
        XCTAssertEqual(BrewOperation.install(PackageRef(.cask, "iina")).arguments, ["install", "--cask", "iina"])
        XCTAssertEqual(BrewOperation.uninstall(PackageRef(.formula, "tree")).arguments, ["uninstall", "--formula", "tree"])
        XCTAssertEqual(BrewOperation.pin(PackageRef(.formula, "node")).arguments, ["pin", "--formula", "node"])
        XCTAssertEqual(BrewOperation.upgradeAll(greedy: false).arguments, ["upgrade"])
        XCTAssertEqual(BrewOperation.upgradeAll(greedy: true).arguments, ["upgrade", "--greedy-auto-updates"])
        XCTAssertEqual(BrewOperation.adopt(PackageRef(.cask, "iina")).arguments, ["install", "--cask", "--adopt", "iina"])
        XCTAssertEqual(BrewOperation.zap(PackageRef(.cask, "iina")).arguments, ["uninstall", "--cask", "--zap", "iina"])
        // A cask whose app is already gone: brew refuses it without --force.
        XCTAssertEqual(BrewOperation.uninstall(PackageRef(.cask, "iina"), force: true).arguments, ["uninstall", "--cask", "--force", "iina"])
        XCTAssertEqual(BrewOperation.zap(PackageRef(.cask, "iina"), force: true).command, "brew uninstall --cask --zap --force iina")
        XCTAssertEqual(BrewOperation.cleanup.arguments, ["cleanup"])
        XCTAssertEqual(BrewOperation.dumpBrewfile(URL(fileURLWithPath: "/tmp/Brewfile")).arguments,
                       ["bundle", "dump", "--force", "--file=/tmp/Brewfile"])
        XCTAssertEqual(BrewOperation.service(.restart, name: "mysql@8.4").arguments, ["services", "restart", "mysql@8.4"])
        XCTAssertEqual(BrewOperation.service(.run, name: "redis").arguments, ["services", "run", "redis"])
        XCTAssertEqual(BrewOperation.service(.kill, name: "redis").arguments, ["services", "kill", "redis"])
        XCTAssertEqual(BrewOperation.reinstall(PackageRef(.cask, "iina")).arguments, ["reinstall", "--cask", "iina"])
    }

    func testCommandIsWhatToTypeInTerminal() {
        XCTAssertEqual(BrewOperation.uninstall(PackageRef(.formula, "tree")).command, "brew uninstall --formula tree")
        XCTAssertEqual(BrewOperation.upgradeAll(greedy: false).command, "brew upgrade")
        XCTAssertEqual(BrewOperation.service(.start, name: "mysql@8.4").command, "brew services start mysql@8.4")
        // A path with spaces or quotes still pastes into a shell as one argument.
        XCTAssertEqual(BrewOperation.dumpBrewfile(URL(fileURLWithPath: "/Users/me/My Files/Bob's Brewfile")).command,
                       #"brew bundle dump --force '--file=/Users/me/My Files/Bob'\''s Brewfile'"#)
    }

    func testTapsAndBrewfileImport() {
        XCTAssertEqual(BrewOperation.tap("mongodb/brew").arguments, ["tap", "mongodb/brew"])
        XCTAssertEqual(BrewOperation.tap("me/tools", remote: "git@example.com:me/tools.git").command,
                       "brew tap me/tools git@example.com:me/tools.git")
        XCTAssertEqual(BrewOperation.untap("mongodb/brew").command, "brew untap mongodb/brew")
        // Importing installs what's missing and leaves the rest at its version.
        XCTAssertEqual(BrewOperation.installBrewfile(URL(fileURLWithPath: "/Users/me/My Brewfile")).command,
                       "brew bundle install --no-upgrade '--file=/Users/me/My Brewfile'")
        XCTAssertTrue(BrewOperation.installBrewfile(URL(fileURLWithPath: "/tmp/Brewfile")).allowsAutoUpdate)
        XCTAssertFalse(BrewOperation.tap("a/b").allowsAutoUpdate)
        XCTAssertNil(BrewOperation.untap("a/b").ref)
    }

    func testUpdateAllHoldingBackApps() {
        // Every formula, and only the casks named; the open ones are left out.
        let operation = BrewOperation.upgradeAll(greedy: true, casks: ["iina"])
        XCTAssertEqual(operation.steps, [["upgrade", "--formula"], ["upgrade", "--cask", "--greedy-auto-updates", "iina"]])
        XCTAssertEqual(operation.command, "brew upgrade --formula && brew upgrade --cask --greedy-auto-updates iina")
        XCTAssertEqual(BrewOperation.upgradeAll(greedy: false, casks: []).steps, [["upgrade", "--formula"]])
        XCTAssertEqual(BrewOperation.upgradeAll(greedy: false).steps, [["upgrade"]])
        XCTAssertEqual(BrewOperation.upgradeVulnerable.steps, [["upgrade", "--formula", "--vulnerable"]])
    }

    func testRevertUnlinksThenInstallsTheOldVersion() {
        let ripgrep = PackageRef(.formula, "ripgrep")
        XCTAssertEqual(BrewOperation.revert(ripgrep, to: "14.1.0", tapCore: false).steps,
                       [["unlink", "--formula", "ripgrep"], ["version-install", "ripgrep", "14.1.0"]])
        let withTap = BrewOperation.revert(ripgrep, to: "14.1.0", tapCore: true)
        XCTAssertEqual(withTap.steps.first, ["tap", "--force", "homebrew/core"])
        // Relinks only once the unlink has happened.
        XCTAssertNil(withTap.rollback(afterCompletedSteps: 1))
        XCTAssertEqual(withTap.rollback(afterCompletedSteps: 2), ["link", "--formula", "ripgrep"])
        XCTAssertNil(BrewOperation.upgrade(ripgrep).rollback(afterCompletedSteps: 0))
    }

    func testUpstreamVersion() {
        XCTAssertEqual(PackageKind.formula.upstreamVersion("14.1.1_2"), "14.1.1")
        XCTAssertEqual(PackageKind.formula.upstreamVersion("3.4.0"), "3.4.0")
        XCTAssertEqual(PackageKind.cask.upstreamVersion("0.2026.11.11.08.17.stable_01"), "0.2026.11.11.08.17.stable_01")
    }

    func testOnlyInstallAndUpgradeAutoUpdate() {
        XCTAssertTrue(BrewOperation.install(PackageRef(.formula, "a")).allowsAutoUpdate)
        XCTAssertTrue(BrewOperation.adopt(PackageRef(.cask, "a")).allowsAutoUpdate)
        XCTAssertTrue(BrewOperation.reinstall(PackageRef(.cask, "a")).allowsAutoUpdate)
        XCTAssertTrue(BrewOperation.upgradeAll(greedy: true).allowsAutoUpdate)
        XCTAssertFalse(BrewOperation.cleanup.allowsAutoUpdate)
        XCTAssertFalse(BrewOperation.zap(PackageRef(.cask, "a")).allowsAutoUpdate)
        XCTAssertFalse(BrewOperation.uninstall(PackageRef(.formula, "a")).allowsAutoUpdate)
        XCTAssertFalse(BrewOperation.update.allowsAutoUpdate)
        XCTAssertFalse(BrewOperation.dumpBrewfile(URL(fileURLWithPath: "/tmp/Brewfile")).allowsAutoUpdate)
    }
}
