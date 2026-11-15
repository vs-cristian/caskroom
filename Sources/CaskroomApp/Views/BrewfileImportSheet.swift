import AppKit
import BrewKit
import SwiftUI

/// What importing a Brewfile would install, before `brew bundle install` does it.
struct BrewfileImportSheet: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let preview: BrewfileImport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: preview.url.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install from Brewfile").font(.headline)
                    Text((preview.url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    store.enqueue(operation)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan?.isSatisfied != false)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var plan: BrewfilePlan? {
        if case let .ready(plan) = preview.state { plan } else { nil }
    }

    private var operation: BrewOperation { .installBrewfile(preview.url) }

    @ViewBuilder
    private var content: some View {
        switch preview.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the Brewfile…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        case let .failed(message):
            Label {
                Text(message)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
        case let .ready(plan):
            if plan.isSatisfied {
                Label("Everything in this Brewfile is already installed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text(summary(plan)).fixedSize(horizontal: false, vertical: true)
                entries(plan)
                Text(operation.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    /// What's missing, by kind, in one scrolling list.
    private func entries(_ plan: BrewfilePlan) -> some View {
        List {
            group("Taps", plan.taps) { name in
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.gray).frame(width: 24)
                    Text(name)
                }
            }
            group("Apps", plan.casks) { row(PackageRef(.cask, $0)) }
            group("Formulae", plan.formulae) { row(PackageRef(.formula, $0)) }
            group("Other", plan.other) { name in
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 24)
                    Text(name)
                }
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds(.disabled)
        .environment(\.defaultMinListRowHeight, 32)
        .frame(height: 220)
    }

    /// An app by its name once `brew info` has it ("Zed", not "zed").
    private func row(_ ref: PackageRef) -> some View {
        PackageRow(ref: ref, title: store.package(ref)?.title, iconSize: 24) { EmptyView() }
            .onAppear { store.requestInfo(ref) }
    }

    @ViewBuilder
    private func group<Row: View>(_ title: String, _ entries: [BrewfilePlan.Entry], row: @escaping (String) -> Row) -> some View {
        let needed = entries.filter(\.needed)
        if !needed.isEmpty {
            Section(title) {
                ForEach(needed, id: \.name) { row($0.name) }
            }
        }
    }

    /// "Installs 3 apps and 2 formulae, and adds 1 tap. 12 are already installed."
    private func summary(_ plan: BrewfilePlan) -> String {
        func count(_ entries: [BrewfilePlan.Entry], _ one: String, _ many: String) -> String? {
            let n = entries.filter(\.needed).count
            return n == 0 ? nil : n == 1 ? "1 \(one)" : "\(n) \(many)"
        }
        let packages = [count(plan.casks, "app", "apps"), count(plan.formulae, "formula", "formulae")].compactMap { $0 }
        var text = packages.isEmpty ? "" : "Installs \(packages.formatted(.list(type: .and)))"
        if let taps = count(plan.taps, "tap", "taps") {
            text += text.isEmpty ? "Adds \(taps)" : ", and adds \(taps)"
        }
        if !text.isEmpty { text += ". " }
        if let other = count(plan.other, "item", "items") {
            text += "\(text.isEmpty ? "It lists" : "It also lists") \(other) for other tools, such as Mac App Store apps or VS Code extensions, which brew bundle installs with those tools. "
        }
        let present = plan.all.filter { !$0.needed }.count
        if present > 0 {
            text += "\(present == 1 ? "1 is" : "\(present) are") already installed and \(present == 1 ? "stays" : "stay") as \(present == 1 ? "it is" : "they are")."
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Asks for a Brewfile, then shows what importing it would install.
@MainActor
func importBrewfile(_ store: BrewStore) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a Brewfile to install what it lists. A Brewfile is a script that Homebrew runs, so open only one you trust."
    panel.prompt = "Choose"
    let open = { (response: NSApplication.ModalResponse) in
        if response == .OK, let url = panel.url { Task { await store.previewBrewfile(url) } }
    }
    if let window = NSApp.keyWindow {
        panel.beginSheetModal(for: window, completionHandler: open)
    } else {
        open(panel.runModal())
    }
}
