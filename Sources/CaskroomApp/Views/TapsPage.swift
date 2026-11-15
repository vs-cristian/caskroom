import AppKit
import BrewKit
import SwiftUI

/// Repositories of formulae and apps beyond Homebrew's own (`brew tap`),
/// laid out like Services.
struct TapsPage: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let taps = store.taps {
                if taps.isEmpty && store.pendingTaps.isEmpty {
                    EmptyPage(
                        title: "No Taps",
                        symbol: "spigot",
                        message: "A tap adds formulae and apps from outside Homebrew's own collection, such as a company's or a developer's. Add one by its name, like mongodb/brew."
                    )
                } else {
                    list(taps)
                }
            } else if let error = store.tapsError {
                VStack(spacing: 12) {
                    EmptyPage(title: "Couldn't Load Taps", symbol: "exclamationmark.triangle", message: error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await store.loadTaps() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Taps")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Add Tap…", systemImage: "plus") { store.addingTap = true }
                    .help("Add a tap (brew tap)")
            }
        }
        .task { await store.loadTaps() }
    }

    private func list(_ taps: [Tap]) -> some View {
        Form {
            Section {
                ForEach(store.pendingTaps.filter { name in !taps.contains { $0.name == name } }, id: \.self) { name in
                    PendingTapRow(name: name)
                }
                ForEach(taps) { TapRow(tap: $0) }
            } footer: {
                Text("A tap's formulae and apps appear in search alongside Homebrew's own. Homebrew won't remove a tap while anything installed came from it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .animation(Motion.list(reduceMotion: reduceMotion), value: taps.map(\.name) + store.pendingTaps)
    }

    private var subtitle: String {
        guard let count = store.taps?.count else { return "" }
        return count == 1 ? "1 tap" : "\(count) taps"
    }
}

private struct TapRow: View {
    @Environment(BrewStore.self) private var store
    let tap: Tap

    var body: some View {
        let installed = store.installedPackages(from: tap)
        HStack(spacing: 12) {
            TapIcon()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tap.name).fontWeight(.medium)
                    if tap.official { Tag("Official") }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(tap.remote ?? "")
            }
            Spacer()
            if !installed.isEmpty {
                Text("\(installed.count) installed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(installed.map(\.name).formatted(.list(type: .and)))
            }
            if store.isRemoving(tap) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Removing").foregroundStyle(.secondary)
                }
            } else {
                Button("Remove") { store.enqueue(.untap(tap.name)) }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(!installed.isEmpty)
                    .help(installed.isEmpty
                        ? BrewOperation.untap(tap.name).command
                        : "Uninstall \(installed.map(\.name).formatted(.list(type: .and))) first: Homebrew won't remove a tap while anything installed came from it.")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let url = tap.webURL {
                Button("Open Repository") { NSWorkspace.shared.open(url) }
            }
            if let path = tap.path {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
            }
            Button("Copy Name") { copyToPasteboard(tap.name) }
            Divider()
            Button("Remove") { store.enqueue(.untap(tap.name)) }
                .disabled(!installed.isEmpty || store.isRemoving(tap))
        }
    }

    /// "19 formulae · 1 app · updated 5 days ago", and the URL for a tap
    /// that has its own, since adding it again needs it.
    private var detail: String {
        var parts: [String] = []
        if tap.formulaCount > 0 { parts.append(tap.formulaCount == 1 ? "1 formula" : "\(tap.formulaCount) formulae") }
        if tap.caskCount > 0 { parts.append(tap.caskCount == 1 ? "1 app" : "\(tap.caskCount) apps") }
        if parts.isEmpty { parts.append("Empty") }
        if let commit = tap.lastCommit { parts.append("updated \(commit)") }
        if tap.customRemote, let remote = tap.remote { parts.append(remote) }
        return parts.joined(separator: " · ")
    }
}

/// A tap that's queued or being added, before brew lists it.
private struct PendingTapRow: View {
    @Environment(BrewStore.self) private var store
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            TapIcon()
            Text(name).fontWeight(.medium)
            Spacer()
            ProgressView().controlSize(.small)
            Text(store.operations.contains { $0.state == .running && $0.operation == .tap(name) } ? "Adding" : "Waiting")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct TapIcon: View {
    var body: some View {
        Image(systemName: "spigot.fill")
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.brown.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Adds a tap by name, or by URL for one that isn't on GitHub.
struct AddTapSheet: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var remote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("user/repo"))
                    TextField("URL", text: $remote, prompt: Text("Optional"))
                } header: {
                    Text("Add a Tap")
                        .font(.headline)
                        .foregroundStyle(.primary)
                } footer: {
                    Text("A tap's instructions usually say `brew tap user/repo`: the name is the part after `brew tap`, for the GitHub repository user/homebrew-repo. Give a URL only for a tap hosted elsewhere. A tap's formulae run their own install scripts, so add only taps you trust.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let operation {
                    Text(operation.command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let operation { store.enqueue(operation) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(operation == nil || alreadyTapped)
                .help(alreadyTapped ? "\(tapName) is already tapped." : "")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }

    /// What was typed, without a pasted `brew tap ` in front, split into the
    /// name and any URL pasted after it.
    private var typed: (name: String, remote: String?) {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["brew tap ", "tap "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return (words.first ?? "", words.count == 2 ? words[1] : nil)
    }

    private var tapName: String { typed.name }

    private var alreadyTapped: Bool {
        store.taps?.contains { $0.name.caseInsensitiveCompare(tapName) == .orderedSame } ?? false
    }

    private var operation: BrewOperation? {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Tap.isValidName(tapName), name.split(whereSeparator: \.isWhitespace).count <= 4 else { return nil }
        return .tap(tapName, remote: url.isEmpty ? typed.remote : url)
    }
}
