import BrewKit
import SwiftUI

/// Results for the sidebar search: your library first, then all of Homebrew.
struct SearchResultsPage: View {
    @Environment(BrewStore.self) private var store
    let query: String

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let installed = store.installed.filter {
            $0.name.lowercased().contains(needle)
                || ($0.displayName?.lowercased().contains(needle) ?? false)
                || ($0.desc?.lowercased().contains(needle) ?? false)
        }
        let installedRefs = Set(store.installed.map(\.ref))
        let others = store.searchIndex.search(query, limit: 150).filter { !installedRefs.contains($0) }
        let apps = others.filter { $0.kind == .cask }
        let formulae = others.filter { $0.kind == .formula }
        let commands = store.commandIndex.search(query, limit: 12)

        Group {
            if installed.isEmpty && others.isEmpty && commands.isEmpty {
                EmptyPage(title: "No Results", symbol: "magnifyingglass", message: "Nothing in Homebrew matches “\(query)”.")
            } else {
                List {
                    if !installed.isEmpty {
                        Section("In Your Library") {
                            ForEach(installed) { package in
                                NavigationLink(value: package.ref) {
                                    PackageRow(ref: package.ref, title: package.title, subtitle: package.desc) {
                                        PrimaryActionButton(ref: package.ref).controlSize(.small)
                                    }
                                }
                                .contextMenu { PackageMenu(store: store, ref: package.ref) }
                            }
                        }
                    }
                    if !commands.isEmpty {
                        Section("Commands") {
                            ForEach(commands, id: \.command) { hit in
                                commandRow(hit.command, hit.formulae)
                            }
                        }
                    }
                    results("Apps", apps)
                    results("Formulae", formulae)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                // Rows added to a list that was empty keep AppKit's default
                // height instead of their own; a minimum keeps them whole.
                .environment(\.defaultMinListRowHeight, 44)
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle("“\(query)”")
    }

    /// "rg", installed by ripgrep: what to install for a command you know.
    /// The row opens the first formula; the others are named.
    private func commandRow(_ command: String, _ formulae: [String]) -> some View {
        let ref = PackageRef(.formula, formulae[0])
        let others = formulae.count - 1
        let subtitle = "Installed by \(formulae[0])" + (others == 0 ? "" : others == 1 ? " and \(formulae[1])" : " and \(others) others")
        return NavigationLink(value: ref) {
            PackageRow(ref: ref, title: command, subtitle: subtitle) {
                PrimaryActionButton(ref: ref).controlSize(.small)
            }
        }
        .contextMenu { PackageMenu(store: store, ref: ref) }
    }

    @ViewBuilder
    private func results(_ title: String, _ refs: [PackageRef]) -> some View {
        if !refs.isEmpty {
            Section(title) {
                ForEach(refs, id: \.self) { ref in
                    NavigationLink(value: ref) {
                        PackageRow(ref: ref, title: ref.name, subtitle: store.package(ref)?.desc ?? (ref.kind == .cask ? "App" : "Formula")) {
                            PrimaryActionButton(ref: ref).controlSize(.small)
                        }
                    }
                    .contextMenu { PackageMenu(store: store, ref: ref) }
                }
            }
        }
    }
}
