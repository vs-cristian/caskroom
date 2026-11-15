import AppKit
import BrewKit
import SwiftUI

/// What uninstalling an app removes, ticked by how sure Caskroom is that each
/// file is the app's, then the outcome. Everything goes to the Trash.
struct AppRemovalSheet: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let removal: AppRemoval

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch removal.state {
            case .scanning:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for \(removal.app.name)'s files…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            case let .refused(message):
                Text(message).fixedSize(horizontal: false, vertical: true)
            case .ready, .removing:
                if store.isRunning(removal) { openWarning }
                LeftoverList(removal: removal)
                footnote
            case let .finished(outcome):
                OutcomeView(removal: removal, outcome: outcome)
            }
            buttons
        }
        .padding(20)
        .frame(width: 600)
        .frame(minHeight: 200)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: removal.app.path))
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch removal.state {
        case let .finished(outcome) where outcome.failed.isEmpty: "\(removal.app.name) Is in the Trash"
        case .finished: "Some Files Couldn't Be Moved"
        case .refused: "Can't Uninstall \(removal.app.name)"
        default: "Uninstall \(removal.app.name)?"
        }
    }

    private var subtitle: String {
        switch removal.state {
        case .scanning, .refused: return removal.app.version.map { "Version \($0)" } ?? removal.app.path
        case let .finished(outcome):
            return outcome.moved.count == 1 ? "1 item moved to the Trash" : "\(outcome.moved.count) items moved to the Trash"
        default:
            let count = removal.selected.count
            let files = count == 0 ? "the app alone" : count == 1 ? "the app and 1 item" : "the app and \(count) items"
            let size = removal.selectedSize > 0 ? ", \(ByteCountFormatter.string(fromByteCount: removal.selectedSize, countStyle: .file))" : ""
            return "Moves \(files) to the Trash\(size)"
        }
    }

    private var openWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("\(removal.app.name) is open. Quit it to uninstall it.")
            Spacer()
            Button("Quit \(removal.app.name)") {
                for app in store.runningParts(of: removal) { app.terminate() }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cask = removal.cask {
                Text("Homebrew uninstalls the app (\(store.uninstallOperation(cask, zap: store.installedPackage(cask)?.hasZap == true).command)), then Caskroom moves what's still there to the Trash.")
            } else {
                Text("Everything goes to the Trash, so you can put it back from there.")
            }
            if let copy = removal.otherCopy {
                Text("Another copy of \(removal.app.name) is at \(copy). Its settings and data are the same files, so only this copy goes.")
            }
            if removal.needsAdministrator {
                Text("Some of these are system-wide, so you'll be asked for an administrator password.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if case .finished = removal.state {
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(removal.state == .removing)
                if case .refused = removal.state {} else {
                    Button(removal.cask == nil ? "Move to Trash" : "Uninstall", role: .destructive) {
                        store.confirmRemoval(removal)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(removal.state != .ready || store.isRunning(removal))
                }
                if removal.state == .removing { ProgressView().controlSize(.small) }
            }
        }
    }

    private func close() {
        store.appRemoval = nil
        dismiss()
    }
}

private struct LeftoverList: View {
    @Bindable var removal: AppRemoval

    var body: some View {
        List {
            row(path: removal.app.path, reason: appReason, toggle: nil)
            ForEach(removal.leftovers) { leftover in
                row(path: leftover.path, reason: reason(leftover), toggle: Binding(
                    get: { removal.selected.contains(leftover.path) },
                    set: { on in
                        if on { removal.selected.insert(leftover.path) } else { removal.selected.remove(leftover.path) }
                    }
                ))
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .environment(\.defaultMinListRowHeight, 40)
        .frame(height: 300)
        .disabled(removal.state == .removing)
    }

    private func row(path: String, reason: String, toggle: Binding<Bool>?) -> some View {
        HStack(spacing: 10) {
            if let toggle {
                Toggle("", isOn: toggle).labelsHidden().toggleStyle(.checkbox)
            } else {
                Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.checkbox).disabled(true)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(display(path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let size = removal.sizes[path] {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    private var appReason: String {
        if removal.cask != nil { return "The app, uninstalled by Homebrew" }
        return LeftoverFinder.needsAdministrator(removal.app.path) ? "The app · needs a password" : "The app"
    }

    private func display(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func reason(_ leftover: Leftover) -> String {
        var text = switch leftover.evidence {
        case .homebrew: "Listed in Homebrew's cask for this app"
        case .installer: "Put there by the app's installer"
        case .bundleID: "Named for the app"
        case .launchItem: "Starts part of the app in the background"
        case .crashReport: "A crash report of the app"
        case .developer: "The developer's shared data; no other app of theirs is installed"
        case .name: "Named like the app"
        case .sharedWithDeveloper: "The developer's shared data, which their other apps may use"
        case .dotfile: "Named like the app; command-line tools use folders like this too"
        }
        if leftover.needsAdministrator { text += " · needs a password" }
        return text
    }
}

private struct OutcomeView: View {
    let removal: AppRemoval
    let outcome: RemovalOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if outcome.administratorDeclined {
                Text("The system-wide files stayed: no administrator password was given.")
            }
            if !outcome.failed.isEmpty {
                List(outcome.failed, id: \.self) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.path).lineLimit(1).truncationMode(.middle).help(failure.path)
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered)
                .frame(height: 200)
            } else {
                Text("You can put anything back from the Trash until you empty it.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
