import AppKit
import BrewKit
import SwiftUI

/// Background services, laid out like System Settings ▸ Login Items.
struct ServicesPage: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if store.lastRefreshed == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.services.isEmpty {
                EmptyPage(
                    title: "No Services",
                    symbol: "gearshape.2",
                    message: "Formulae that run in the background, like databases, appear here once installed."
                )
            } else {
                Form {
                    let running = store.services.filter(\.status.isRunning)
                    let idle = store.services.filter { !$0.status.isRunning }
                    if !running.isEmpty {
                        Section("Running") { ForEach(running) { ServiceRow(entry: $0) } }
                    }
                    if !idle.isEmpty {
                        Section {
                            ForEach(idle) { ServiceRow(entry: $0) }
                        } header: {
                            Text("Not Running")
                        } footer: {
                            Text("A service set to start at login launches each time you log in; turning that off also stops it. Run starts one only until you stop it or log out.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                // A started service moves up into Running, so you see where it went.
                .animation(Motion.list(reduceMotion: reduceMotion), value: store.services)
            }
        }
        .navigationTitle("Services")
        .navigationSubtitle("\(store.services.filter(\.status.isRunning).count) running")
    }
}

private struct ServiceRow: View {
    @Environment(BrewStore.self) private var store
    let entry: ServiceEntry

    var body: some View {
        HStack(spacing: 12) {
            PackageIcon(ref: entry.ref, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).fontWeight(.medium)
                HStack(spacing: 5) {
                    StatusDot(status: entry.status)
                    Text(entry.detail)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // What the sidebar's badge is pointing at: why did it fail?
            if entry.status == .error, let log = entry.existingLog {
                Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                    .buttonStyle(.borderless)
            }
            if let run = store.operation(for: entry.ref) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(run.operation.progressVerb).foregroundStyle(.secondary)
                }
            } else {
                ServiceRunButton(entry: entry)
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("At Login").font(.callout).foregroundStyle(.secondary)
                ServiceLoginToggle(entry: entry).labelsHidden()
            }
            Menu {
                ServiceMenu(store: store, entry: entry, includesControls: false)
                Divider()
                Button("Show Package") { store.path.append(entry.ref) }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 2)
        // Run or Stop gives way to progress, as PrimaryActionButton does.
        .animation(Motion.standard, value: store.isBusy(entry.ref))
    }
}

/// Run or Stop, for now only; starting at login is the toggle beside it.
struct ServiceRunButton: View {
    @Environment(BrewStore.self) private var store
    let entry: ServiceEntry

    var body: some View {
        let command = store.runCommand(entry)
        // As wide as Install, so a list mixing the two lines up.
        Button { store.enqueue(command) } label: {
            Text(entry.status.isRunning ? "Stop" : "Run").frame(minWidth: 48)
        }
        .glassButton()
        .disabled(store.isBusy(entry.ref))
        .help(command.command)
    }
}

/// Whether the service starts at login, as a Login Items switch. Callers label it.
struct ServiceLoginToggle: View {
    @Environment(BrewStore.self) private var store
    let entry: ServiceEntry

    var body: some View {
        let command = store.loginCommand(entry)
        Toggle("Start at Login", isOn: Binding(
            get: { entry.registered },
            set: { _ in store.enqueue(command) }
        ))
        .toggleStyle(.switch)
        .disabled(store.isBusy(entry.ref))
        .help(entry.registered
            ? "Starts at login. Turning this off also stops it (\(command.command))."
            : "Start now and at every login (\(command.command))")
    }
}

/// A service's commands for menus: the package menu (and so the menu bar), and
/// the ⋯ menus beside a service's own controls, which leave those out.
struct ServiceMenu: View {
    let store: BrewStore
    let entry: ServiceEntry
    var includesControls = true

    var body: some View {
        let busy = store.isBusy(entry.ref)
        if includesControls {
            Button(entry.status.isRunning ? "Stop Service" : "Run Service") { store.enqueue(store.runCommand(entry)) }
                .disabled(busy)
            Toggle("Start Service at Login", isOn: Binding(
                get: { entry.registered },
                set: { _ in store.enqueue(store.loginCommand(entry)) }
            ))
            .disabled(busy)
        }
        if entry.status.isRunning && entry.registered {
            Button("Restart Service") { store.enqueue(.service(.restart, name: entry.name)) }
                .disabled(busy)
        }
        if let log = entry.logPath {
            Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                .disabled(!FileManager.default.fileExists(atPath: log))
        }
        if let log = entry.errorLogPath, log != entry.logPath {
            Button("Open Error Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                .disabled(!FileManager.default.fileExists(atPath: log))
        }
        if let file = entry.file {
            Button("Show Launch Agent in Finder") {
                NSWorkspace.shared.selectFile(file, inFileViewerRootedAtPath: "")
            }
        }
    }
}

extension ServiceEntry {
    /// "Running · me · PID 4321", or "Error · exit code 78".
    var detail: String {
        var parts = [status.label]
        if let user { parts.append(user) }
        if let pid { parts.append("PID \(pid)") }
        if let exitCode, exitCode != 0 { parts.append("exit code \(exitCode)") }
        return parts.joined(separator: " · ")
    }

    /// The log most likely to say why it failed, if it's been written: the error log first.
    var existingLog: String? {
        [errorLogPath, logPath].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }
}
