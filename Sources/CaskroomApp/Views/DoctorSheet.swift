import BrewKit
import SwiftUI

/// `brew doctor`, Disk Utility First Aid style: the check runs as the sheet
/// opens, then the sheet shows what it found.
struct DoctorSheet: View {
    @Environment(BrewStore.self) private var store
    /// Bumped by Check Again, which restarts the task.
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 640, height: 480)
        .animation(Motion.standard, value: store.doctor)
        .task(id: attempt) { await store.runDoctor() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 26))
                .foregroundStyle(.blue.gradient)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Homebrew Doctor")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        switch store.doctor {
        case .checking, nil: "Checking your Homebrew installation for problems…"
        case let .finished(warnings) where warnings.isEmpty: "No problems found."
        case let .finished(warnings): warnings.count == 1 ? "1 warning" : "\(warnings.count) warnings"
        case .failed: "The check couldn't finish."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.doctor {
        case .checking, nil:
            ProgressView()
        case let .finished(warnings) where warnings.isEmpty:
            // Each result is a fresh check (opening the sheet runs one), so it always draws in.
            EmptyPage(title: "Your System Is Ready to Brew", symbol: "checkmark.seal.fill", tint: .green, drawsIn: true)
        case let .finished(warnings):
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(warnings, id: \.self) { WarningCard(warning: $0) }
                }
                .padding(20)
            }
        case let .failed(message):
            EmptyPage(title: "Couldn't Run Doctor", symbol: "exclamationmark.triangle.fill", message: message, tint: .red)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if case let .finished(warnings) = store.doctor, !warnings.isEmpty {
                Text("Warnings help Homebrew's maintainers debug problems. If everything works, you can ignore them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Check Again") { attempt += 1 }
                .disabled(store.doctor == .checking)
                .help("brew doctor")
            Button("Done") { store.doctor = nil }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct WarningCard: View {
    let warning: DoctorWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(warning.summary).font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            if !warning.detail.isEmpty {
                // brew wraps at 80 columns and indents lists, so keep its layout.
                Text(warning.detail)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
