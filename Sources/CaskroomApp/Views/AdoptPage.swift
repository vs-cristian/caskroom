import BrewKit
import SwiftUI

/// Apps installed by hand that a Homebrew cask installs too. Adopting one
/// lets Homebrew update it from then on. The scan reads Homebrew's cask list
/// (downloaded at most daily), so it runs only once this page or Discover opens.
struct AdoptPage: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch store.adoption {
            case nil, .scanning:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for apps Homebrew could manage…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn't Look for Apps", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.scanAdoptableApps() } }
                }
            case .finished where store.adoptableApps.isEmpty:
                EmptyPage(
                    title: "Nothing to Adopt",
                    symbol: SidebarItem.adopt.symbol,
                    message: "Every app in Applications that Homebrew has a cask for is already managed by Homebrew, or comes from the App Store."
                )
            case .finished:
                let apps = store.adoptableApps
                List {
                    Section {
                        ForEach(apps) { app in
                            NavigationLink(value: app.package.ref) {
                                AdoptRow(app: app)
                            }
                            .contextMenu { PackageMenu(store: store, ref: app.package.ref) }
                        }
                    } footer: {
                        Text("Adopting hands an app to Homebrew without downloading it again, so Updates and Update All keep it current. Homebrew adopts an app only at the version its cask has, unless the app updates itself. App Store apps aren't listed. macOS lets Homebrew change an app in place only if Caskroom is allowed under Privacy & Security ▸ App Management.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .environment(\.defaultMinListRowHeight, 56)
                // An adopted app leaves the list.
                .animation(Motion.list(reduceMotion: reduceMotion), value: apps.map(\.id))
            }
        }
        .navigationTitle("Adopt Apps")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Scan Again", systemImage: "arrow.trianglehead.2.clockwise") {
                    Task { await store.scanAdoptableApps() }
                }
                .disabled(store.adoption == .scanning)
            }
        }
        .task {
            if store.adoption == nil { await store.scanAdoptableApps() }
        }
    }

    private var subtitle: String {
        let count = store.adoptableApps.count
        return count == 1 ? "1 app" : "\(count) apps"
    }
}

private struct AdoptRow: View {
    let app: AdoptableApp

    var body: some View {
        PackageRow(
            ref: app.package.ref,
            title: app.package.title,
            subtitle: app.package.desc,
            iconSize: 44
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.appVersion ?? "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if app.package.autoUpdates {
                    Tag("Updates itself")
                } else if !app.versionMatches {
                    Tag("Different version", color: .orange)
                        .help("Homebrew's cask has \(app.package.latestVersion ?? "another version"). Update the app to that version first, or Homebrew won't adopt it.")
                }
            }
            PrimaryActionButton(ref: app.package.ref)
                .controlSize(.small)
                .frame(minWidth: 80, alignment: .trailing)
        }
    }
}
