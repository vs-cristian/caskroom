import AppKit
import BrewKit
import SwiftUI

/// Selecting several package rows while a click still opens one, App Store
/// style: ⌘-click and ⇧-click select, as in Finder, and a plain click opens
/// the package's page. Rows can't be `NavigationLink`s for this: a link opens
/// on ⌘-click too. A plain click is told apart by the mouse-down that changed
/// the selection (`PlainClick`). Return or a double click opens the one selected.
///
/// The selection's context menu, the menu bar's Package menu and Delete act on
/// all of it.
struct PackageSelection: ViewModifier {
    @Environment(BrewStore.self) private var store
    @Binding var selection: Set<PackageRef>

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, new in
                guard new.count == 1, let ref = new.first, PlainClick.consume() else { return }
                open(ref)
            }
            .contextMenu(forSelectionType: PackageRef.self) { refs in
                if refs.count == 1, let ref = refs.first {
                    PackageMenu(store: store, ref: ref)
                } else if !refs.isEmpty {
                    SelectionMenu(store: store, refs: refs)
                }
            } primaryAction: { refs in
                if refs.count == 1, let ref = refs.first { open(ref) }
            }
            .onDeleteCommand { store.requestUninstall(selection) }
            .onExitCommand { selection = [] }
            .focusedValue(\.selectedPackages, selection.count > 1 ? selection : nil)
    }

    private func open(_ ref: PackageRef) {
        // Back from the page, nothing is left selected.
        selection = []
        store.path.append(ref)
    }
}

extension View {
    func packageSelection(_ selection: Binding<Set<PackageRef>>) -> some View {
        modifier(PackageSelection(selection: selection))
    }
}

/// When a plain left click (no ⌘, ⇧ or ⌃) last went down, from a local event
/// monitor: SwiftUI reports a selection change without the click behind it.
@MainActor
enum PlainClick {
    private static var last: Date?
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            last = event.modifierFlags.intersection([.command, .shift, .control]).isEmpty ? .now : nil
            return event
        }
    }

    /// Whether a plain click just went down; true once per click.
    static func consume() -> Bool {
        defer { last = nil }
        return last.map { Date.now.timeIntervalSince($0) < 0.5 } ?? false
    }
}

/// What can be done to several packages at once: the selection's context
/// menu, and the menu bar's Package menu while rows are selected.
struct SelectionMenu: View {
    let store: BrewStore
    let refs: Set<PackageRef>

    var body: some View {
        let installed = refs.compactMap(store.installedPackage).sorted { $0.name < $1.name }
        let updatable = store.updatable(installed.map(\.ref))
        let unpinned = installed.filter { !$0.pinned }
        let pinned = installed.filter(\.pinned)
        if !updatable.isEmpty {
            Button("Update \(count(updatable.count))") { store.update(updatable) }
                .help(updatable.contains(where: store.isOpenDuringUpdate)
                    ? "Apps that are open update when you quit them."
                    : "")
        }
        if !unpinned.isEmpty {
            Button("Pin \(count(unpinned.count))") { store.setPinned(true, unpinned.map(\.ref)) }
        }
        if !pinned.isEmpty {
            Button("Unpin \(count(pinned.count))") { store.setPinned(false, pinned.map(\.ref)) }
        }
        if !installed.isEmpty {
            Divider()
            Button("Uninstall \(count(installed.count))…", role: .destructive) {
                store.requestUninstall(installed.map(\.ref))
            }
        }
    }

    private func count(_ n: Int) -> String {
        n == 1 ? "1 Package" : "\(n) Packages"
    }
}

extension FocusedValues {
    /// The rows selected in a package list, when there are several.
    @Entry var selectedPackages: Set<PackageRef>?
}
