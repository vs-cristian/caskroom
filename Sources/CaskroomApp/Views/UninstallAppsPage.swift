import AppKit
import BrewKit
import SwiftUI
import UniformTypeIdentifiers

/// Apps Homebrew doesn't manage, each with Uninstall…, which removes the app
/// and what it left in the Library folders (`AppRemovalSheet`). An app
/// dropped on the page opens the same sheet. Homebrew's own apps are
/// uninstalled from their pages, the same way.
struct UninstallAppsPage: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let apps = store.otherApps {
                if apps.isEmpty {
                    EmptyPage(
                        title: "No Other Apps",
                        symbol: SidebarItem.uninstallApps.symbol,
                        message: "Every app in Applications is managed by Homebrew or is part of macOS. Homebrew's apps are uninstalled from their pages."
                    )
                } else {
                    list(apps)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            store.uninstallApp(at: app)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Uninstall Apps")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Choose App…", systemImage: "folder") { chooseAppToUninstall(store) }
            }
            ToolbarItem {
                Button("Scan Again", systemImage: "arrow.trianglehead.2.clockwise") {
                    Task { await store.scanOtherApps() }
                }
                .disabled(store.scanningOtherApps)
            }
        }
        .task {
            if store.otherApps == nil { await store.scanOtherApps() }
        }
        // An install or uninstall changes which apps Homebrew manages.
        .onChange(of: store.installed.compactMap(\.appPath)) {
            Task { await store.scanOtherApps() }
        }
    }

    private func list(_ apps: [AppIdentity]) -> some View {
        List {
            Section {
                ForEach(apps) { app in
                    OtherAppRow(app: app)
                        .contextMenu { OtherAppMenu(store: store, app: app) }
                }
            } footer: {
                Text("Apps you installed yourself: from a download, a disk image or the App Store. Uninstalling one moves it to the Trash with its settings, caches, containers, launch agents and helpers, after showing you what it found. You can also drop an app here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .environment(\.defaultMinListRowHeight, 52)
        .animation(Motion.list(reduceMotion: reduceMotion), value: apps.map(\.id))
    }

    private var subtitle: String {
        guard let count = store.otherApps?.count else { return "" }
        return count == 1 ? "1 app outside Homebrew" : "\(count) apps outside Homebrew"
    }
}

private struct OtherAppRow: View {
    @Environment(BrewStore.self) private var store
    let app: AppIdentity

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 12)
            if app.isFromAppStore {
                Tag("App Store")
            } else if store.adoptableApps.contains(where: { $0.package.appPath == app.path }) {
                Tag("Homebrew has it")
                    .help("Adopt Apps can hand it to Homebrew instead, so it's updated with the rest.")
            }
            Button("Uninstall…") { store.uninstallApp(at: URL(fileURLWithPath: app.path)) }
                .controlSize(.small)
                .frame(minWidth: 80, alignment: .trailing)
                .disabled(store.appRemoval != nil)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let folder = (app.path as NSString).deletingLastPathComponent
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return [app.version, folder == "/Applications" ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }
}

/// An app outside Homebrew's actions, for its row's context menu.
struct OtherAppMenu: View {
    let store: BrewStore
    let app: AppIdentity

    var body: some View {
        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) }
        Button("Show in Finder") { NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: "") }
        Divider()
        Button("Uninstall…", role: .destructive) { store.uninstallApp(at: URL(fileURLWithPath: app.path)) }
            .disabled(store.appRemoval != nil)
    }
}

/// File ▸ Uninstall App…: any app, picked in an open panel.
@MainActor
func chooseAppToUninstall(_ store: BrewStore) {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.applicationBundle]
    panel.treatsFilePackagesAsDirectories = false
    panel.prompt = "Uninstall…"
    panel.message = "Choose an app to uninstall with its files."
    let pick = { (response: NSApplication.ModalResponse) in
        if response == .OK, let url = panel.url { store.uninstallApp(at: url) }
    }
    if let window = NSApp.keyWindow {
        panel.beginSheetModal(for: window, completionHandler: pick)
    } else {
        pick(panel.runModal())
    }
}
