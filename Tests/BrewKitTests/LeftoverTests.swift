@testable import BrewKit
import XCTest

final class LeftoverTests: XCTestCase {
    private var base: URL!
    private var home: URL { base.appending(path: "home") }
    private var root: URL { base.appending(path: "root") }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "LeftoverTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func make(_ path: String, in folder: URL? = nil, contents: Data = Data()) throws {
        let url = (folder ?? home).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try contents.write(to: url)
        }
    }

    private var app: AppIdentity {
        AppIdentity(
            path: root.appending(path: "Applications/Example.app").path,
            name: "Example",
            bundleID: "com.example.app",
            bundleIDs: ["com.example.app", "com.example.app.helper", "com.example.app.share-extension"],
            helperNames: ["com.example.app.privileged"],
            teamID: "ABCDE12345",
            names: ["Example"]
        )
    }

    private func finder(others: [InstalledApp] = []) -> LeftoverFinder {
        LeftoverFinder(home: home, root: root, temporaryFolders: [], otherApps: others)
    }

    private func found(_ leftovers: [Leftover]) -> [String: Leftover.Evidence] {
        Dictionary(uniqueKeysWithValues: leftovers.map { leftover in
            let path = leftover.path.hasPrefix(home.path + "/")
                ? "~/" + leftover.path.dropFirst(home.path.count + 1)
                : "/" + leftover.path.dropFirst(root.path.count + 1)
            return (String(path), leftover.evidence)
        })
    }

    func testFindsByBundleIDTeamAndName() throws {
        try make("Library/Preferences/com.example.app.plist")
        try make("Library/Preferences/ByHost/com.example.app.0F1E2D3C-AAAA.plist")
        try make("Library/Caches/com.example.app/")
        try make("Library/Containers/com.example.app.share-extension/")
        try make("Library/Group Containers/ABCDE12345.group.example/")
        try make("Library/Application Scripts/ABCDE12345.com.example.app/")
        try make("Library/Saved Application State/com.example.app.savedState/")
        try make("Library/Application Support/Example/")
        try make("Library/Logs/DiagnosticReports/Example-2026-01-02-030405.ips")
        try make(".example/")
        // Not this app's.
        try make("Library/Preferences/com.example.application.plist")
        try make("Library/Preferences/com.other.app.plist")
        try make("Library/Application Support/Examples/")

        let result = found(finder().find(for: app))
        XCTAssertEqual(result, [
            "~/Library/Preferences/com.example.app.plist": .bundleID,
            "~/Library/Preferences/ByHost/com.example.app.0F1E2D3C-AAAA.plist": .bundleID,
            "~/Library/Caches/com.example.app": .bundleID,
            "~/Library/Containers/com.example.app.share-extension": .bundleID,
            "~/Library/Group Containers/ABCDE12345.group.example": .developer,
            "~/Library/Application Scripts/ABCDE12345.com.example.app": .bundleID,
            "~/Library/Saved Application State/com.example.app.savedState": .bundleID,
            "~/Library/Application Support/Example": .name,
            "~/Library/Logs/DiagnosticReports/Example-2026-01-02-030405.ips": .crashReport,
            "~/.example": .dotfile,
        ])
    }

    func testKeepsWhatAnotherAppOwns() throws {
        try make("Library/Preferences/com.example.app.beta.plist")
        try make("Library/Group Containers/ABCDE12345.group.example/")
        try make("Library/Application Support/Example/")
        let others = [InstalledApp(bundleID: "com.example.app.beta", teamID: "ABCDE12345", name: "Example")]

        let result = found(finder(others: others).find(for: app))
        // The beta's preferences stay; the shared container is offered, unticked;
        // a folder named like both apps isn't offered at all.
        XCTAssertEqual(result, ["~/Library/Group Containers/ABCDE12345.group.example": .sharedWithDeveloper])
        XCTAssertFalse(finder(others: others).find(for: app)[0].isCertain)
    }

    func testFindsNothingWhileAnotherCopyIsInstalled() throws {
        try make("Library/Preferences/com.example.app.plist")
        try make("Library/Containers/com.example.app.share-extension/")
        let others = [InstalledApp(bundleID: "com.example.app", name: "Example")]
        XCTAssertEqual(finder(others: others).find(for: app, zapPaths: ["~/Library/Preferences/com.example.app.plist"]), [])
    }

    func testFindsSystemHelpersAndLaunchItems() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.vendor.updater", "ProgramArguments": [app.path + "/Contents/MacOS/Updater"]],
            format: .xml, options: 0
        )
        try make("Library/LaunchAgents/com.vendor.updater.plist", in: root, contents: plist)
        try make("Library/LaunchDaemons/com.example.app.privileged.plist", in: root)
        try make("Library/PrivilegedHelperTools/com.example.app.privileged", in: root)
        try make("Library/LaunchDaemons/com.unrelated.plist", in: root)

        let result = found(finder().find(for: app))
        XCTAssertEqual(result, [
            "/Library/LaunchAgents/com.vendor.updater.plist": .launchItem,
            "/Library/LaunchDaemons/com.example.app.privileged.plist": .bundleID,
            "/Library/PrivilegedHelperTools/com.example.app.privileged": .bundleID,
        ])
    }

    func testExpandsZapGlobsAndNeverTheLibraryItself() throws {
        try make("Library/Preferences/com.vendor.thing.plist")
        try make("Library/Preferences/com.vendor.thing.extra.plist")
        try make(".thing/")
        let result = found(finder().find(for: app, zapPaths: ["~/Library/Preferences/com.vendor.thing*.plist", "~/.thing", "~/Library", "~/Library/Caches"]))
        XCTAssertEqual(result, [
            "~/Library/Preferences/com.vendor.thing.plist": .homebrew,
            "~/Library/Preferences/com.vendor.thing.extra.plist": .homebrew,
            "~/.thing": .homebrew,
        ])
    }

    func testReceiptsClaimOnlyFoldersTheyFilledThemselves() throws {
        try make("Library/Application Support/Vendor/data.bin", in: root)
        try make("Library/Application Support/Vendor/Sub/more.bin", in: root)
        try make("Library/Audio/Plug-Ins/Components/Vendor.component/Contents/Info.plist", in: root)
        try make("Library/Audio/Plug-Ins/Components/Someone Else.component/", in: root)
        let files = [
            "Library/Application Support/Vendor", "Library/Application Support/Vendor/data.bin",
            "Library/Application Support/Vendor/Sub", "Library/Application Support/Vendor/Sub/more.bin",
            "Library/Audio", "Library/Audio/Plug-Ins", "Library/Audio/Plug-Ins/Components",
            "Library/Audio/Plug-Ins/Components/Vendor.component",
            "Library/Audio/Plug-Ins/Components/Vendor.component/Contents",
            "Library/Audio/Plug-Ins/Components/Vendor.component/Contents/Info.plist",
        ].map { root.appending(path: $0).path }

        let result = found(finder().find(for: app, receiptFiles: files))
        XCTAssertEqual(result, [
            "/Library/Application Support/Vendor": .installer,
            "/Library/Audio/Plug-Ins/Components/Vendor.component": .installer,
        ])
    }

    func testRootScriptQuotesPaths() {
        let script = AppRemover.script(moving: ["/Library/LaunchDaemons/it's.plist"], toTrash: "/Users/me/.Trash", forgetting: ["com.example.pkg"], onceGone: "/Applications/Example.app", uid: 501)
        XCTAssertTrue(script.contains(#"launchctl bootout system '/Library/LaunchDaemons/it'\''s.plist'"#))
        XCTAssertTrue(script.contains(#"trash '/Library/LaunchDaemons/it'\''s.plist'"#))
        XCTAssertTrue(script.contains("if [ ! -e '/Applications/Example.app' ]; then pkgutil --forget 'com.example.pkg'"))
    }

    func testReadsCaskZapPaths() throws {
        let url = Bundle.module.url(forResource: "info-installed", withExtension: "json", subdirectory: "Fixtures")!
        let packages = try BrewParser.packages(from: Data(contentsOf: url))
        let warp = try XCTUnwrap(packages.first { $0.name == "warp" })
        XCTAssertTrue(warp.zapPaths.contains("~/.warp"))
        XCTAssertTrue(warp.zapPaths.contains("~/Library/Logs/warp.log*"))
    }
}
