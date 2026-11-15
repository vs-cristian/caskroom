import SwiftUI

/// Caskroom ▸ Settings… (⌘,).
struct SettingsView: View {
    @Environment(BrewStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $store.checksAutomatically)
            } footer: {
                Text("Every few hours while Caskroom is open, it fetches the latest package index (`brew update`) and shows how many updates there are on its Dock icon. If Caskroom is in the background, a notification says what's new.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Also list apps that updated themselves", isOn: $store.greedyAutoUpdates)
            } footer: {
                Text("Homebrew lists an app that updates itself, like a browser or an editor, only when the copy on this Mac is older than the newest version. With this on, Updates also lists one that got there by itself, since Homebrew's records still show the older version, and Update All downloads it again (`brew upgrade --greedy-auto-updates`).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Check for known vulnerabilities", isOn: $store.checksVulnerabilities)
            } footer: {
                Text("Caskroom asks OSV.dev, an open vulnerability database, about your installed formulae (`brew vulns`) and shows what it finds under Security. This sends the names and versions of your formulae to OSV.dev each time it checks: at launch and after each change. Apps (casks) aren't checked.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
