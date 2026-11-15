import AppKit
import BrewKit
import SwiftUI

/// A small capsule label for package flags (pinned, update…).
struct Tag: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.13), in: Capsule())
    }
}

struct StatusDot: View {
    let status: ServiceStatus

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 8, height: 8)
            .accessibilityLabel(status.label)
    }

    private var color: Color {
        switch status {
        case .started: .green
        case .scheduled: .teal
        case .error: .red
        case .other, .unknown: .orange
        case .stopped, .none: .gray.opacity(0.5)
        }
    }
}

extension ServiceStatus {
    var label: String {
        switch self {
        case .started: "Running"
        case .scheduled: "Scheduled"
        case .stopped: "Stopped"
        case .none: "Not running"
        case .error: "Error"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }
}

/// How Caskroom words an operation. Four forms, not one table: each has its own
/// tense, and the command uses brew's "Upgrade" where the rest say "Update".
extension BrewOperation {
    /// The command, for the activity log and "… failed".
    var title: String {
        switch self {
        case let .install(ref): "Install \(ref.name)"
        case let .adopt(ref): "Adopt \(ref.name)"
        case let .uninstall(ref, _): "Uninstall \(ref.name)"
        case let .zap(ref, _): "Uninstall \(ref.name) and its data"
        case let .upgrade(ref): "Upgrade \(ref.name)"
        case let .reinstall(ref): "Reinstall \(ref.name)"
        case .upgradeAll(_, .none): "Upgrade all"
        case .upgradeAll: "Upgrade all but open apps"
        case .upgradeVulnerable: "Upgrade vulnerable formulae"
        case let .revert(ref, version, _): "Revert \(ref.name) to \(version)"
        case let .pin(ref): "Pin \(ref.name)"
        case let .unpin(ref): "Unpin \(ref.name)"
        case .update: "Update Homebrew"
        case .cleanup: "Clean up"
        case .dumpBrewfile: "Export Brewfile"
        case .installBrewfile: "Install from Brewfile"
        case let .tap(name, _): "Tap \(name)"
        case let .untap(name): "Untap \(name)"
        case let .service(.kill, name): "Stop \(name)"
        case let .service(action, name): "\(action.rawValue.capitalized) \(name)"
        }
    }

    /// What's happening, for a button standing in for this operation.
    var progressVerb: String {
        switch self {
        case .install: "Installing"
        case .adopt: "Adopting"
        case .uninstall, .zap: "Removing"
        case .upgrade, .upgradeAll, .upgradeVulnerable: "Updating"
        case .reinstall: "Reinstalling"
        case .revert: "Reverting"
        case .pin: "Pinning"
        case .unpin: "Unpinning"
        case .update: "Checking"
        case .cleanup: "Cleaning up"
        case .dumpBrewfile: "Exporting"
        case .installBrewfile: "Installing"
        case .tap: "Adding"
        case .untap: "Removing"
        case .service(.start, _), .service(.run, _): "Starting"
        case .service(.stop, _), .service(.kill, _): "Stopping"
        case .service(.restart, _): "Restarting"
        }
    }

    /// "Installing tree", for the activity pill while it runs.
    var inProgressTitle: String {
        switch self {
        case .upgradeAll(_, .none): "Updating all packages"
        case .upgradeAll: "Updating all but open apps"
        case .upgradeVulnerable: "Updating vulnerable formulae"
        case .update: "Checking for updates"
        case .cleanup: "Cleaning up Homebrew"
        case .dumpBrewfile: "Exporting Brewfile"
        case .installBrewfile: "Installing from Brewfile"
        case let .tap(name, _): "Adding tap \(name)"
        case let .untap(name): "Removing tap \(name)"
        default: "\(progressVerb) \(ref?.name ?? "")"
        }
    }

    /// Past tense, for the activity pill once it's done.
    var doneTitle: String {
        switch self {
        case let .install(ref): "Installed \(ref.name)"
        case let .adopt(ref): "Adopted \(ref.name)"
        case let .uninstall(ref, _): "Removed \(ref.name)"
        case let .zap(ref, _): "Removed \(ref.name) and its data"
        case let .upgrade(ref): "Updated \(ref.name)"
        case let .reinstall(ref): "Reinstalled \(ref.name)"
        case .upgradeAll(_, .none): "Updated all packages"
        case .upgradeAll: "Updated all but open apps"
        case .upgradeVulnerable: "Updated vulnerable formulae"
        case let .revert(ref, version, _): "Reverted \(ref.name) to \(version)"
        case let .pin(ref): "Pinned \(ref.name)"
        case let .unpin(ref): "Unpinned \(ref.name)"
        case .update: "Checked for updates"
        case .cleanup: "Cleaned up Homebrew"
        case .dumpBrewfile: "Exported Brewfile"
        case .installBrewfile: "Installed from Brewfile"
        case let .tap(name, _): "Added tap \(name)"
        case let .untap(name): "Removed tap \(name)"
        case let .service(.start, name), let .service(.run, name): "Started \(name)"
        case let .service(.stop, name), let .service(.kill, name): "Stopped \(name)"
        case let .service(.restart, name): "Restarted \(name)"
        }
    }
}

/// The one action that matters for a package right now, App Store style:
/// Install (or Adopt, for an app already in place), Update, Open (an installed
/// app), or progress while brew works on it.
struct PrimaryActionButton: View {
    @Environment(BrewStore.self) private var store
    let ref: PackageRef
    var prominent = false
    /// Shown, each copied on click, in place of a plain "Installed" once
    /// there's nothing left to do: what to type next.
    var commands: [String] = []
    /// The finished run, kept a moment after it settles so the result is seen
    /// even when the refresh is quick.
    @State private var held: OperationRun?

    /// The run whose result the button is showing, if it ended in success or failure.
    private var finished: OperationRun? {
        guard let run = store.settlingRun(for: ref) ?? held else { return nil }
        switch run.state {
        case .succeeded, .failed: return run
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let run = store.operation(for: ref) {
                // While brew downloads for this run: a ring that fills, when the size is known.
                let download = run.state == .running && store.runningOperation === run ? store.download : nil
                status {
                    DownloadIndicator(fraction: download?.fraction).controlSize(.mini)
                    Text(run.state == .queued ? "Waiting" : download != nil ? "Downloading" : run.operation.progressVerb)
                        .contentTransition(.interpolate)
                }
                .help(download?.summary ?? "")
                .animation(Motion.quick, value: run.state)
                .animation(Motion.quick, value: download != nil)
            } else if let run = finished {
                status {
                    if run.state == .succeeded {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                            .transition(.drawOn)
                    } else {
                        FailedMark()
                    }
                }
            } else if let package = store.installedPackage(ref) {
                if store.availableUpdate(ref) != nil {
                    if store.updatesOnQuit(ref) {
                        // Waiting for the app to quit; the menu can cancel it.
                        status {
                            Image(systemName: "clock")
                            Text("After Quit")
                        }
                        .help("Updates when you quit \(package.title)")
                    } else if ref == store.selfRef {
                        // Caskroom itself: brew can only replace it once it has quit.
                        glass(Menu("Update") {
                            Button("Update and Relaunch") { store.enqueue(.upgrade(ref)) }
                            Button("Update When I Quit") { store.updateOnQuit(ref) }
                        } primaryAction: {
                            store.enqueue(.upgrade(ref))
                        }
                        .menuStyle(.button))
                        .fixedSize()
                        .help("Caskroom quits, Homebrew updates it, and it opens again. Or choose Update When I Quit.")
                    } else if store.isOpenDuringUpdate(ref) {
                        // Open, and brew would replace it as it runs: offer to wait.
                        glass(Menu("Update") {
                            Button("Update When I Quit") { store.updateOnQuit(ref) }
                            Button("Update Now") { store.enqueue(.upgrade(ref)) }
                        } primaryAction: {
                            store.updateOnQuit(ref)
                        }
                        .menuStyle(.button))
                        .fixedSize()
                        .help("\(package.title) is open. Click to update it when you quit it, or choose Update Now.")
                    } else {
                        action("Update") { store.enqueue(.upgrade(ref)) }
                    }
                } else if let path = package.appPath, FileManager.default.fileExists(atPath: path) {
                    action("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                } else if !commands.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(commands, id: \.self) { command in
                            CommandButton(command: command)
                        }
                    }
                } else {
                    Label("Installed", systemImage: "checkmark")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                }
            } else if store.isAdoptable(ref) {
                action("Adopt") { store.enqueue(.adopt(ref)) }
                    .help("This app is already in Applications. Adopt it so Homebrew keeps it up to date.")
            } else {
                action("Install") { store.enqueue(.install(ref)) }
            }
        }
        .animation(Motion.standard, value: store.isBusy(ref))
        .animation(Motion.standard, value: finished?.id)
        .onChange(of: store.settlingRun(for: ref)?.id) { _, id in
            guard id != nil, let run = store.settlingRun(for: ref) else { return }
            held = run
            Task {
                try? await Task.sleep(for: .seconds(1))
                if held === run { held = nil }
            }
        }
    }

    /// The capsule that stands in for the button while brew works, then shows how it went.
    private func status<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 24)
            .background(.fill.tertiary, in: Capsule())
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        // In a list, Install, Open, Adopt and Update are one width, as in the App Store.
        glass(Button(action: perform) {
            Text(title).frame(minWidth: prominent ? nil : 48)
        })
    }

    /// A capsule of glass, prominent on a package's page.
    private func glass(_ control: some View) -> some View {
        control
            .glassButton(prominent: prominent)
            .buttonBorderShape(.capsule)
            .fontWeight(.semibold)
    }
}

/// A failure mark that wiggles once when it appears.
private struct FailedMark: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .symbolEffect(.wiggle, value: shown)
            .onAppear { shown = true }
    }
}

/// A symbol that draws itself in once, for a finish worth marking: the last
/// update done, a clean bill from doctor. Without `drawsIn` it's simply there,
/// so a page that merely opens on that state doesn't replay it.
struct DrawnSymbol: View {
    let systemName: String
    var drawsIn = true
    @State private var drawn = false

    var body: some View {
        ZStack {
            // Holds the symbol's space while it isn't drawn yet.
            Image(systemName: systemName).hidden()
            if drawn || !drawsIn {
                Image(systemName: systemName)
                    .transition(.drawOn)
            }
        }
        .task {
            guard drawsIn else { return }
            // Once the row or page around it has faded in, so the drawing is seen.
            try? await Task.sleep(for: .milliseconds(250))
            drawn = true
        }
        .animation(Motion.standard, value: drawn)
    }
}

/// A placeholder for an empty page: the system's own, with an optional tint.
struct EmptyPage: View {
    let title: String
    let symbol: String
    var message: String?
    var tint: Color = .secondary
    /// Draws the symbol in, for a result that just arrived.
    var drawsIn = false

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                DrawnSymbol(systemName: symbol, drawsIn: drawsIn).foregroundStyle(tint.gradient)
            }
        } description: {
            if let message { Text(message) }
        }
    }
}

/// A spinner, or a ring that fills while brew downloads something whose size
/// is known.
struct DownloadIndicator: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            ProgressView(value: fraction).progressViewStyle(.circular)
        } else {
            ProgressView()
        }
    }
}

/// The brew commands behind a package's actions, each with a Copy button, so
/// nothing Caskroom does is hidden from someone who'd rather use Terminal.
struct CommandList: View {
    let operations: [BrewOperation]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(operations.enumerated()), id: \.element) { index, operation in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline) {
                    Text(operation.command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(operation.command) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy command")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A command in a capsule; clicking copies it, and the icon confirms.
struct CommandButton: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(command)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 6) {
                Text(command).font(.body.monospaced())
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
        }
        .glassButton()
        .buttonBorderShape(.capsule)
        .help("Copy “\(command)”")
    }
}

/// An icon-only Copy button that turns into a checkmark for a moment.
struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .labelStyle(.iconOnly)
        .contentTransition(.symbolEffect(.replace))
        .buttonStyle(.borderless)
        .help(help)
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Wraps children onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(subviews, width: bounds.width).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (origins, CGSize(width: maxX, height: y + lineHeight))
    }
}

extension Date {
    /// "5 min. ago"
    var relative: String {
        formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

extension String {
    /// Whether it may not fit in `lines` lines, so a "more" link is worth
    /// showing. Blank lines take a line too, and long lines wrap, so about 90
    /// characters count as one.
    func mayRunPast(lines: Int) -> Bool {
        split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > lines || count > lines * 90
    }
}

extension Deprecation {
    /// The rest of "because it …". brew's reasons are symbols, worded here as
    /// brew words them, or a maintainer's own phrase, used as written.
    var because: String? {
        guard let reason else { return nil }
        switch reason {
        case "does_not_build": return "does not build"
        case "no_license": return "has no license"
        case "repo_archived": return "has an archived upstream repository"
        case "repo_removed": return "has a removed upstream repository"
        case "unmaintained": return "is not maintained upstream"
        case "unsupported": return "is not supported upstream"
        case "deprecated_upstream": return "is deprecated upstream"
        case "versioned_formula": return "is a versioned formula"
        case "checksum_mismatch": return "was rebuilt from a source file that changed after its release"
        case "discontinued": return "is discontinued upstream"
        case "moved_to_mas": return "is now only on the Mac App Store"
        case "no_longer_available": return "is no longer available upstream"
        case "no_longer_meets_criteria": return "no longer meets Homebrew's criteria for casks"
        case "unsigned": return "is unsigned or doesn't meet signature requirements"
        case "fails_gatekeeper_check": return "doesn't pass the macOS Gatekeeper check"
        case "unreachable": return "is no longer reliably reachable upstream"
        default:
            // A symbol brew added since: "some_reason" reads well enough as words.
            let isSymbol = reason.allSatisfy { $0.isLowercase || $0 == "_" }
            return isSymbol ? reason.replacingOccurrences(of: "_", with: " ") : reason
        }
    }
}

extension Package {
    /// One line on why a deprecated or disabled package needs attention.
    var attentionSummary: String? {
        let (state, stanza) = disabled ? ("Disabled", disabling) : deprecated ? ("Deprecated", deprecation) : (nil, nil)
        guard let state else { return nil }
        return stanza?.because.map { "\(state) because it \($0)" } ?? state
    }

    /// What Homebrew suggests installing instead, if anything.
    var replacement: PackageRef? {
        disabled ? disabling?.replacement ?? deprecation?.replacement : deprecation?.replacement
    }
}
