import AppKit
import BrewKit

/// A Brewfile chosen for import, while its sheet is open.
struct BrewfileImport: Identifiable {
    enum State {
        case loading
        case failed(String)
        case ready(BrewfilePlan)
    }

    let id = UUID()
    let url: URL
    var state: State
}

/// Several packages to uninstall, as the dialog presents them.
struct BulkUninstall: Identifiable {
    let id = UUID()
    /// What will go, in order: each package before anything it depends on,
    /// since brew refuses to uninstall what an installed package still needs.
    let order: [PackageRef]
    /// What has to stay, each with the installed packages outside the
    /// selection that need it.
    let kept: [(ref: PackageRef, neededBy: [PackageRef])]
}

extension BrewStore {
    // MARK: Taps

    func loadTaps() async {
        guard let service else { return }
        do {
            taps = try await service.tapInfo().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            tapsError = nil
        } catch {
            tapsError = error.localizedDescription
        }
    }

    /// Installed packages that came from `tap`. brew won't untap it while there are any.
    func installedPackages(from tap: Tap) -> [Package] {
        installed.filter { $0.tap == tap.name }
    }

    /// Taps being added: queued or running `brew tap`s.
    var pendingTaps: [String] {
        operations.compactMap { run in
            guard !run.state.isFinished, case let .tap(name, _) = run.operation else { return nil }
            return name
        }
    }

    /// The queued or running `brew untap` of `name`, if there is one.
    func isRemoving(_ tap: Tap) -> Bool {
        operations.contains { !$0.state.isFinished && $0.operation == .untap(tap.name) }
    }

    // MARK: Brewfiles

    /// Opens the import sheet for `url` and has brew read the file.
    func previewBrewfile(_ url: URL) async {
        guard let service else { return }
        let preview = BrewfileImport(url: url, state: .loading)
        brewfileImport = preview
        let state: BrewfileImport.State
        do {
            state = .ready(try await service.brewfilePlan(at: url))
        } catch let BrewError.commandFailed(_, _, stderr) where !stderr.isEmpty {
            // "Error: Invalid Brewfile: …:2: syntax error found", with the line.
            state = .failed(stderr.replacingOccurrences(of: "Error: ", with: ""))
        } catch {
            state = .failed(error.localizedDescription)
        }
        // Closed, or another file chosen, in the meantime.
        guard brewfileImport?.id == preview.id else { return }
        brewfileImport?.state = state
    }

    // MARK: Several packages at once

    /// Those of `refs` with an update to offer.
    func updatable(_ refs: some Sequence<PackageRef>) -> [PackageRef] {
        refs.filter { availableUpdate($0) != nil }
    }

    /// Updates each of `refs` that has an update, as its own Update button
    /// would: an app brew would replace while it's open (Caskroom included)
    /// waits until it quits.
    func update(_ refs: some Sequence<PackageRef>) {
        for ref in updatable(refs) where !isBusy(ref) {
            if isOpenDuringUpdate(ref) {
                updateOnQuit(ref)
            } else {
                enqueue(.upgrade(ref))
            }
        }
    }

    /// Pins (or unpins) each of `refs` that isn't already.
    func setPinned(_ pinned: Bool, _ refs: some Sequence<PackageRef>) {
        for ref in refs {
            guard let package = installedPackage(ref), package.pinned != pinned, !isBusy(ref) else { continue }
            enqueue(pinned ? .pin(ref) : .unpin(ref))
        }
    }

    /// Asks before uninstalling; RootView shows the dialog. A single package
    /// gets its own dialog, with Delete App Data where it applies.
    func requestUninstall(_ refs: some Sequence<PackageRef>) {
        let refs = Set(refs.filter { installedPackage($0) != nil })
        if refs.count == 1 {
            uninstallCandidate = refs.first
        } else if refs.count > 1 {
            bulkUninstall = uninstallPlan(refs)
        }
    }

    /// Which of `refs` can go and in what order. A package something outside
    /// the selection still needs stays, and so does whatever that one needs.
    func uninstallPlan(_ refs: Set<PackageRef>) -> BulkUninstall {
        var kept: Set<PackageRef> = []
        func neededBy(_ ref: PackageRef) -> [PackageRef] {
            dependents(of: ref).filter { !refs.contains($0) || kept.contains($0) }
        }
        var changed = true
        while changed {
            changed = false
            for ref in refs where !kept.contains(ref) && !neededBy(ref).isEmpty {
                kept.insert(ref)
                changed = true
            }
        }
        var remaining = refs.subtracting(kept)
        var order: [PackageRef] = []
        while !remaining.isEmpty {
            // Those nothing left in the batch depends on go first.
            var ready = remaining.filter { ref in !dependents(of: ref).contains(where: remaining.contains) }
            // A cycle, which brew wouldn't have installed: let brew sort it out.
            if ready.isEmpty { ready = remaining }
            order += ready.sorted { $0.name < $1.name }
            remaining.subtract(ready)
        }
        return BulkUninstall(
            order: order,
            kept: kept.sorted { $0.name < $1.name }.map { ($0, neededBy($0)) }
        )
    }

    func uninstall(_ plan: BulkUninstall) {
        for ref in plan.order {
            enqueue(uninstallOperation(ref))
        }
    }
}
