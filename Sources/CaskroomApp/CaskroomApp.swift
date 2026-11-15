import AppKit
import BrewKit
import SwiftUI

@main
struct CaskroomApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var logos = LogoStore()
    @State private var releaseNotes = ReleaseNotesStore()

    private var store: BrewStore { appDelegate.store }

    var body: some Scene {
        Window("Caskroom", id: "main") {
            RootView()
                .environment(store)
                .environment(logos)
                .environment(releaseNotes)
                .frame(minWidth: 900, minHeight: 560)
                .task { await SnapshotDriver.runIfRequested(store: store) }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Export Brewfile…") { exportBrewfile(store) }
                    .disabled(store.service == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                    .keyboardShortcut("f")
            }
            CommandGroup(after: .toolbar) {
                Button(store.showActivity ? "Hide Activity" : "Show Activity") { store.showActivity.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(Self.shortcutItems.enumerated()), id: \.offset) { index, item in
                    Button(item.title) {
                        store.searchText = ""
                        store.sidebar = item
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
            PackageCommands(store: store)
            CommandGroup(replacing: .help) {
                Button("Homebrew Documentation") { NSWorkspace.shared.open(URL(string: "https://docs.brew.sh")!) }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }

    private static let shortcutItems: [SidebarItem] = [.discover, .updates, .library(.all), .services, .security]
}

/// The Package menu: Homebrew-wide commands, then the open package page's actions.
struct PackageCommands: Commands {
    let store: BrewStore
    @FocusedValue(\.packageRef) private var ref

    var body: some Commands {
        CommandMenu("Package") {
            Button("Refresh") { Task { await store.refresh() } }
                .keyboardShortcut("r")
                .disabled(store.service == nil)
            Button("Update Package Index") { store.enqueue(.update) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(store.service == nil || store.isPending(.update))
            Button("Update All") { store.enqueue(store.upgradeAll) }
                .disabled(!store.canUpgradeAll || store.isPending(store.upgradeAll))
            Button("Fix Vulnerabilities") { store.enqueue(.upgradeVulnerable) }
                .disabled(!store.checksVulnerabilities || store.fixableVulnerabilities.isEmpty || store.isPending(.upgradeVulnerable))
            Button("Clean Up") { store.enqueue(.cleanup) }
                .disabled(store.service == nil || store.isPending(.cleanup))
            Button("Run Doctor…") { store.doctor = .checking }
                .disabled(store.service == nil || store.doctor != nil)
            Divider()
            if let ref {
                PackageMenu(store: store, ref: ref)
            } else {
                Button("Install") {}.disabled(true)
                Button("Uninstall…") {}.disabled(true)
            }
        }
    }
}

/// Asks where to save, then has brew write the Brewfile there.
@MainActor
private func exportBrewfile(_ store: BrewStore) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Brewfile"
    panel.message = "A Brewfile lists your installed packages, so brew bundle can install them on another Mac."
    let save = { (response: NSApplication.ModalResponse) in
        if response == .OK, let url = panel.url { store.enqueue(.dumpBrewfile(url)) }
    }
    if let window = NSApp.keyWindow {
        panel.beginSheetModal(for: window, completionHandler: save)
    } else {
        save(panel.runModal())
    }
}

extension FocusedValues {
    /// The package whose page is open, for the Package menu.
    @Entry var packageRef: PackageRef?
}

/// Owns the store so quitting can wait for brew. `swift run` launches a bare
/// executable with no bundle; make it a regular, frontmost app so its window takes focus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = BrewStore(service: BrewRunner.locate(askpassURL: askpassHelper).map(BrewService.init))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Notifier.setUp { [store] in
            store.searchText = ""
            store.sidebar = .updates
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-install would orphan brew and drop the queue silently; ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.hasPendingOperations else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while Homebrew is working?"
        alert.informativeText = if let run = store.runningOperation {
            "“\(run.operation.inProgressTitle)” will be stopped, and anything still queued won't run."
        } else {
            "Queued commands won't run."
        }
        alert.addButton(withTitle: "Stop and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            store.selfUpgrade = nil
            return .terminateCancel
        }
        Task {
            await store.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.handOffSelfUpgrade()
    }
}

/// The SUDO_ASKPASS helper: Contents/Helpers in Caskroom.app, or beside the
/// executable in a `swift build` tree.
private var askpassHelper: URL? {
    let candidates = [
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/CaskroomAskpass"),
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "CaskroomAskpass"),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
