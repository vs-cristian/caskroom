import AppKit
import BrewKit
import SwiftUI

/// The toolbar's status pill, like Xcode's activity view: what brew is doing now,
/// or how the last command went. Click for the full log.
///
/// On macOS 26 it draws its own Liquid Glass (RootView hides the toolbar's shared
/// glass behind it) so the glass can move: the pill stretches to fit its title,
/// queued commands split off as a droplet and merge back as the queue drains, and
/// the glass briefly tints green or red when a command finishes. macOS 15 gets
/// filled capsules with the same content and tint.
struct ActivityPill: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    /// How the last command went, shown as a tint for a moment after it finishes.
    @State private var flash: Color?

    var body: some View {
        @Bindable var store = store
        pills
        .animation(Motion.liquid(reduceMotion: reduceMotion), value: title)
        .animation(Motion.liquid(reduceMotion: reduceMotion), value: queued > 0)
        .animation(Motion.quick, value: queued)
        .animation(Motion.standard, value: flash)
        .onChange(of: store.settling?.id) {
            guard let run = store.settling else { return }
            let color: Color? = switch run.state {
            case .succeeded: .green
            case .failed: .red
            default: nil
            }
            guard let color else { return }
            flash = color
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if flash == color { flash = nil }
            }
        }
        // Anchored to a view behind the pill rather than the pill itself: on
        // macOS 15, a popover on a toolbar item's own view, bound to the store,
        // sends the toolbar into a layout loop that hangs the app at launch.
        .background {
            Color.clear.popover(isPresented: $store.showActivity, arrowEdge: .bottom) {
                ActivityView()
                    .frame(width: 520, height: 460)
            }
        }
    }

    @ViewBuilder
    private var pills: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    pill
                        .glassEffect(.regular.tint(flash?.opacity(0.3)).interactive(), in: Capsule())
                        .glassEffectID("pill", in: glass)
                    if queued > 0 {
                        queue
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .glassEffectID("queue", in: glass)
                            // Without motion the droplet simply appears; with it, it pulls out of the pill.
                            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                    }
                }
            }
        } else {
            // macOS 15 has no glass: a filled capsule, as Xcode 16's activity view.
            HStack(spacing: 6) {
                pill
                    .background(Capsule().fill(flash?.opacity(0.25) ?? .clear))
                    .background(Capsule().fill(.quaternary))
                if queued > 0 {
                    queue
                        .background(Capsule().fill(.quaternary))
                        .transition(.move(from: .leading, reduceMotion: reduceMotion))
                }
            }
        }
    }

    private var pill: some View {
        Button {
            store.showActivity.toggle()
        } label: {
            HStack(spacing: 7) {
                icon.frame(width: 14, height: 14)
                Text(title)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minWidth: 160, maxWidth: 380)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show activity (⇧⌘L)")
    }

    private var queue: some View {
        Button {
            store.showActivity = true
        } label: {
            Text("+\(queued)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(queued)))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(queued == 1 ? "1 command waiting" : "\(queued) commands waiting")
    }

    private var queued: Int {
        store.operations.filter { $0.state == .queued }.count
    }

    private var title: String {
        if let run = store.runningOperation { return run.operation.inProgressTitle }
        if let run = store.operations.last {
            switch run.state {
            case .failed: return "\(run.operation.title) failed"
            case .cancelled: return "\(run.operation.title) stopped"
            default: return run.operation.doneTitle
            }
        }
        if store.isRefreshing { return "Loading…" }
        return "Homebrew \(store.brewVersion ?? "")"
    }

    @ViewBuilder
    private var icon: some View {
        if store.runningOperation != nil || (store.isRefreshing && store.operations.isEmpty) {
            DownloadIndicator(fraction: store.runningOperation != nil ? store.download?.fraction : nil).controlSize(.mini)
        } else {
            // One image whose symbol is replaced, so the change animates as a symbol swap.
            let (symbol, color): (String, Color) = switch store.operations.last?.state {
            case .failed?: ("exclamationmark.triangle.fill", .red)
            case .cancelled?: ("slash.circle", .secondary)
            case nil: ("mug.fill", .orange)
            default: ("checkmark.circle.fill", .green)
            }
            Image(systemName: symbol)
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.standard, value: symbol)
        }
    }
}

/// Queued and finished brew commands, with the selected one's output, then
/// updates from earlier sessions (whose output wasn't kept).
struct ActivityView: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: OperationRun.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Clear") { store.clearFinished() }
                    .disabled(!store.operations.contains { $0.state.isFinished })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if store.operations.isEmpty && earlier.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Output from installs, upgrades and other changes appears here.")
                )
            } else if store.operations.isEmpty {
                List { earlierSection }
                    .listStyle(.inset)
            } else {
                List(selection: $selectedID) {
                    ForEach(store.operations.reversed()) { run in
                        OperationRow(run: run).tag(Optional(run.id))
                    }
                    earlierSection
                }
                .listStyle(.inset)
                // A newly queued command slides in at the top; Clear takes the finished ones out.
                .animation(Motion.list(reduceMotion: reduceMotion), value: store.operations.map(\.id))
                .frame(height: 140)
                Divider()
                if let run = selectedRun {
                    LogView(run: run)
                }
            }
        }
    }

    /// Updates finished before this launch.
    private var earlier: [UpdateRecord] {
        store.history.filter { $0.date < store.launchedAt }
    }

    @ViewBuilder
    private var earlierSection: some View {
        if !earlier.isEmpty {
            Section("Earlier") {
                ForEach(earlier) { HistoryRow(record: $0) }
            }
        }
    }

    /// The picked run, else the running one, else the newest.
    private var selectedRun: OperationRun? {
        store.operations.first { $0.id == selectedID }
            ?? store.runningOperation
            ?? store.operations.last
    }
}

private struct OperationRow: View {
    @Environment(BrewStore.self) private var store
    let run: OperationRun

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.operation.title).lineLimit(1)
                if let download {
                    if let fraction = download.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    }
                    Text("Downloading · \(download.summary)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .animation(Motion.quick, value: download != nil)
            Spacer()
            if !run.state.isFinished {
                Button {
                    store.cancel(run)
                } label: {
                    Label(run.state == .running ? "Stop" : "Remove from Queue", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(run.state == .running ? "Stop this command" : "Remove from queue")
            }
        }
        // Waiting, running and done crossfade, and the Stop button fades out.
        .animation(Motion.standard, value: run.state)
    }

    /// This run's downloads, while it's the one running and brew is downloading.
    private var download: DownloadProgress? {
        run.state == .running && store.runningOperation === run ? store.download : nil
    }

    @ViewBuilder
    private var icon: some View {
        if run.state == .running {
            DownloadIndicator(fraction: download?.fraction).controlSize(.small)
        } else {
            // One image whose symbol is replaced, as in the activity pill.
            let (symbol, color): (String, Color) = switch run.state {
            case .queued, .running: ("clock", .secondary)
            case .succeeded: ("checkmark.circle.fill", .green)
            case .cancelled: ("slash.circle", .secondary)
            case .failed: ("exclamationmark.circle.fill", .red)
            }
            Image(systemName: symbol)
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

private struct HistoryRow: View {
    let record: UpdateRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).frame(width: 16)
            Text("Updated \(record.name)").lineLimit(1)
            Text("\(record.from) → \(record.to)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }
}

private struct LogView: View {
    let run: OperationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("$ \(run.operation.command)")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button {
                    copyToPasteboard(run.operation.command)
                } label: {
                    Label("Copy Command", systemImage: "terminal")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy command")
                Button {
                    copyToPasteboard(run.log.map(\.text).joined(separator: "\n"))
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy output")
                .disabled(run.log.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if case let .failed(message) = run.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                if run.blockedByAppManagement {
                    Button("Open App Management Settings") { NSWorkspace.shared.open(OperationRun.appManagementSettings) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(run.log.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(line.stream == .stderr ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .onChange(of: run.log.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(run.log.count - 1, anchor: .bottom)
                }
            }
        }
    }
}
