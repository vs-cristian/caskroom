import BrewKit
import SwiftUI

struct Sidebar: View {
    @Environment(BrewStore.self) private var store

    var body: some View {
        let selection = Binding<SidebarItem?>(
            get: { store.searchText.isEmpty ? store.sidebar : nil },
            set: { item in
                guard let item else { return }
                store.searchText = ""
                store.sidebar = item
            }
        )
        List(selection: selection) {
            Section {
                row(.discover)
                row(.updates, badge: store.outdated.count)
                row(.security, badge: store.vulnerabilityReport?.findings.count ?? 0)
            }
            Section("Library") {
                ForEach(LibraryFilter.allCases) { filter in
                    row(.library(filter), badge: filter == .attention ? store.needingAttention.count : 0)
                }
            }
            Section("System") {
                // Badges are for what needs attention: failed services, not running ones.
                row(.services, badge: store.services.filter { $0.status == .error }.count)
                row(.taps)
                // Last, and without a badge: occasionally useful, rarely urgent.
                row(.adopt)
                row(.uninstallApps)
            }
        }
    }

    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(badge)
            .tag(item)
    }
}

/// A list row: icon, name, one line of detail, and trailing content.
struct PackageRow<Trailing: View>: View {
    let ref: PackageRef
    var title: String?
    var subtitle: String?
    var iconSize: CGFloat = 32
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            PackageIcon(ref: ref, size: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? ref.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Separators start under the name, even with a rank before the icon.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
