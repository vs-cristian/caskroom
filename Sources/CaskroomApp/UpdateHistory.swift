import BrewKit
import Foundation

/// A package as Caskroom's saved state names it: its kind's raw value
/// ("formula", "cask") and its name, kept apart in JSON files and joined as
/// "cask:firefox" in UserDefaults. Only Caskroom writes these, so an unknown
/// kind can't happen; it would read as a formula.
extension PackageRef {
    init(savedKind kind: String, name: String) {
        self.init(PackageKind(rawValue: kind) ?? .formula, name)
    }

    var savedString: String { "\(kind.rawValue):\(name)" }

    init?(savedString: String) {
        let parts = savedString.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        self.init(savedKind: parts[0], name: parts[1])
    }
}

/// A package brew updated: what Updates lists under Updated Recently, and the
/// Activity popover under Earlier.
struct UpdateRecord: Codable, Hashable, Identifiable {
    let kind: String
    let name: String
    /// A cask's human name, as it was then.
    let title: String?
    let from: String
    let to: String
    let date: Date

    var id: Self { self }
    var ref: PackageRef { PackageRef(savedKind: kind, name: name) }

    init(ref: PackageRef, title: String?, from: String, to: String, date: Date) {
        kind = ref.kind.rawValue
        name = ref.name
        self.title = title
        self.from = from
        self.to = to
        self.date = date
    }
}

/// Finished updates, newest first, in ~/Library/Application Support so they
/// outlast a quit. Only Caskroom's own updates: one made in Terminal isn't seen.
enum UpdateHistory {
    /// More than Updated Recently shows, so the Activity popover has a past.
    static let limit = 200

    private static let file = AppFolders.support.appending(path: "UpdateHistory.json")

    static func load() -> [UpdateRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([UpdateRecord].self, from: data)) ?? []
    }

    static func save(_ records: [UpdateRecord]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: file, options: .atomic)
    }
}
