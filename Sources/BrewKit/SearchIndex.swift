import Foundation

/// Every formula and cask name, searched locally so typing doesn't spawn brew.
public struct SearchIndex: Sendable {
    public let formulae: [String]
    public let casks: [String]

    private let formulaSet: Set<String>
    private let caskSet: Set<String>

    public init(formulae: [String] = [], casks: [String] = []) {
        self.formulae = formulae
        self.casks = casks
        formulaSet = Set(formulae)
        caskSet = Set(casks)
    }

    public var isEmpty: Bool { formulae.isEmpty && casks.isEmpty }

    public func contains(_ ref: PackageRef) -> Bool {
        (ref.kind == .formula ? formulaSet : caskSet).contains(ref.name)
    }

    /// Names in this index that `earlier` didn't have, alphabetically per kind,
    /// formulae first: what Homebrew added between the two. A rename shows up
    /// here too, under its new name.
    public func added(since earlier: SearchIndex) -> [PackageRef] {
        formulae.filter { !earlier.formulaSet.contains($0) }.sorted().map { PackageRef(.formula, $0) }
            + casks.filter { !earlier.caskSet.contains($0) }.sorted().map { PackageRef(.cask, $0) }
    }

    /// Names `earlier` had that this index doesn't: removed, or renamed.
    public func removed(since earlier: SearchIndex) -> [PackageRef] {
        earlier.added(since: self)
    }

    /// Names containing `query` (case-insensitive), best first: exact match, then
    /// prefix, then substring; ties by length, then name. A tap-qualified name
    /// ("mongodb/brew/mongodb-community") matches on its last component too.
    public func search(_ query: String, limit: Int = 200) -> [PackageRef] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        var hits: [(rank: Int, ref: PackageRef)] = []
        for (kind, names) in [(PackageKind.formula, formulae), (.cask, casks)] {
            for name in names {
                let lower = name.lowercased()
                let short = lower.split(separator: "/").last.map(String.init) ?? lower
                let rank: Int
                if short == needle || lower == needle {
                    rank = 0
                } else if short.hasPrefix(needle) || lower.hasPrefix(needle) {
                    rank = 1
                } else if lower.contains(needle) {
                    rank = 2
                } else {
                    continue
                }
                hits.append((rank, PackageRef(kind, name)))
            }
        }
        hits.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.ref.name.count != b.ref.name.count { return a.ref.name.count < b.ref.name.count }
            if a.ref.name != b.ref.name { return a.ref.name < b.ref.name }
            return a.ref.kind == .formula && b.ref.kind == .cask
        }
        return hits.prefix(limit).map(\.ref)
    }
}
