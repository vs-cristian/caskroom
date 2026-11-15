import Foundation

public enum ServiceAction: String, Hashable, Sendable {
    /// Runs it now and registers it to start at login.
    case start
    /// Stops it and unregisters it from login.
    case stop
    /// Stops it if running, then starts and registers it.
    case restart
    /// Runs it now without registering it.
    case run
    /// Stops it now, but leaves it registered to start at login.
    case kill
}

/// A brew command that changes the system. These take Homebrew's lock, so the app
/// runs them one at a time.
public enum BrewOperation: Hashable, Sendable {
    case install(PackageRef)
    /// Installs a cask over an app already in place (dragged in from a disk
    /// image, say), so Homebrew manages it from then on. brew refuses unless the
    /// app is the same version as the cask's.
    case adopt(PackageRef)
    case uninstall(PackageRef)
    /// Uninstalls a cask and deletes what its `zap` stanza lists: settings,
    /// caches, support files.
    case zap(PackageRef)
    case upgrade(PackageRef)
    /// Uninstalls and installs the current version again: mends a broken
    /// install, and lets brew catch up with an app that updated itself.
    case reinstall(PackageRef)
    /// With `greedy`, also casks that updated themselves since brew installed
    /// them, which brew otherwise leaves alone. `casks` limits it to those
    /// casks (every formula is still upgraded), so apps can be held back; nil
    /// is every cask.
    case upgradeAll(greedy: Bool, casks: [String]? = nil)
    /// Upgrades the outdated formulae OSV.dev lists vulnerabilities for. The
    /// new version isn't guaranteed to fix every one.
    case upgradeVulnerable
    /// Installs an older version of a formula as `name@version`, extracted
    /// into a personal tap (`brew version-install`), with the current version
    /// unlinked so the old one is the one on PATH. Extracting needs
    /// homebrew/core's history; `tapCore` fetches it first.
    case revert(PackageRef, to: String, tapCore: Bool)
    case pin(PackageRef)
    case unpin(PackageRef)
    case update
    /// Removes old versions, stale downloads and dependencies nothing needs.
    case cleanup
    /// Writes a Brewfile of every installed formula, cask and tap to `url`,
    /// replacing what's there (the save panel has already asked).
    case dumpBrewfile(URL)
    case service(ServiceAction, name: String)

    /// The brew commands to run, in order; most operations are one. A step
    /// that fails stops the rest.
    public var steps: [[String]] {
        switch self {
        case let .upgradeAll(greedy, casks?):
            let greedyFlag = greedy ? ["--greedy-auto-updates"] : []
            return [["upgrade", "--formula"]] + (casks.isEmpty ? [] : [["upgrade", "--cask"] + greedyFlag + casks])
        case let .revert(ref, version, tapCore):
            return (tapCore ? [["tap", "--force", "homebrew/core"]] : [])
                + [["unlink", ref.kind.flag, ref.name], ["version-install", ref.name, version]]
        default:
            return [arguments]
        }
    }

    /// What undoes the steps that ran when a later one fails: a revert relinks
    /// the current version it unlinked.
    public func rollback(afterCompletedSteps completed: Int) -> [String]? {
        guard case let .revert(ref, _, tapCore) = self, completed > (tapCore ? 1 : 0) else { return nil }
        return ["link", ref.kind.flag, ref.name]
    }

    /// The command of a one-step operation.
    var arguments: [String] {
        switch self {
        case let .install(ref): return ["install", ref.kind.flag, ref.name]
        case let .adopt(ref): return ["install", ref.kind.flag, "--adopt", ref.name]
        case let .uninstall(ref): return ["uninstall", ref.kind.flag, ref.name]
        case let .zap(ref): return ["uninstall", ref.kind.flag, "--zap", ref.name]
        case let .upgrade(ref): return ["upgrade", ref.kind.flag, ref.name]
        case let .reinstall(ref): return ["reinstall", ref.kind.flag, ref.name]
        case let .upgradeAll(greedy, _): return ["upgrade"] + (greedy ? ["--greedy-auto-updates"] : [])
        case .upgradeVulnerable: return ["upgrade", "--formula", "--vulnerable"]
        case .revert: return []
        case let .pin(ref): return ["pin", ref.kind.flag, ref.name]
        case let .unpin(ref): return ["unpin", ref.kind.flag, ref.name]
        case .update: return ["update"]
        case .cleanup: return ["cleanup"]
        case let .dumpBrewfile(url): return ["bundle", "dump", "--force", "--file=\(url.path)"]
        case let .service(action, name): return ["services", action.rawValue, name]
        }
    }

    /// What to type in Terminal to do the same thing.
    public var command: String {
        steps.map(Self.command).joined(separator: " && ")
    }

    /// `brew <arguments>`, as typed in Terminal.
    public static func command(_ arguments: [String]) -> String {
        (["brew"] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// Install, reinstall and upgrade let brew refresh its index first, as it
    /// would in a terminal; everything else runs against the index as it is.
    public var allowsAutoUpdate: Bool {
        switch self {
        case .install, .adopt, .upgrade, .reinstall, .upgradeAll, .upgradeVulnerable: return true
        default: return false
        }
    }

    /// The package this operation acts on, if it acts on one.
    public var ref: PackageRef? {
        switch self {
        case let .install(ref), let .adopt(ref), let .uninstall(ref), let .zap(ref), let .upgrade(ref),
             let .reinstall(ref), let .pin(ref), let .unpin(ref), let .revert(ref, _, _):
            return ref
        case let .service(_, name):
            return PackageRef(.formula, name)
        case .upgradeAll, .upgradeVulnerable, .update, .cleanup, .dumpBrewfile:
            return nil
        }
    }
}

/// `word` as a shell reads it back: untouched when it's safe, else in single quotes.
private func shellQuoted(_ word: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
    guard word.isEmpty || word.unicodeScalars.contains(where: { !safe.contains($0) }) else { return word }
    return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
