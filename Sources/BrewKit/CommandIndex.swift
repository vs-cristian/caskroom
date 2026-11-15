import Foundation

/// The commands each formula installs, from Homebrew's executables database
/// (the one `brew which-formula` reads): ripgrep installs `rg`, libpq `pg_dump`.
/// Searched locally, like `SearchIndex`.
public struct CommandIndex: Sendable {
    /// Public, like the analytics; brew keeps its own copy in its cache.
    public static let url = URL(string: "https://formulae.brew.sh/api/internal/executables.txt")!

    private let commandsByFormula: [String: [String]]
    /// Every (command, formula) pair, sorted by lowercased command, for a
    /// case-insensitive prefix search.
    private let pairs: [(key: String, command: String, formula: String)]

    public var isEmpty: Bool { commandsByFormula.isEmpty }
    public var formulaCount: Int { commandsByFormula.count }

    /// One formula per line, `name:cmd cmd…`, the name sometimes followed by
    /// its version in parentheses.
    public init(text: String = "") {
        var commandsByFormula: [String: [String]] = [:]
        var pairs: [(key: String, command: String, formula: String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var formula = line[..<colon]
            if let paren = formula.firstIndex(of: "(") { formula = formula[..<paren] }
            let commands = line[line.index(after: colon)...].split(separator: " ").map(String.init)
            guard !formula.isEmpty, !commands.isEmpty else { continue }
            commandsByFormula[String(formula)] = commands
            pairs += commands.map { ($0.lowercased(), $0, String(formula)) }
        }
        self.commandsByFormula = commandsByFormula
        self.pairs = pairs.sorted { $0.key < $1.key }
    }

    /// What to type after installing `formula`, alphabetically.
    public func commands(of formula: String) -> [String] {
        (commandsByFormula[formula] ?? []).sorted()
    }

    /// Commands starting with `query`, each with the formulae that install it:
    /// an exact match first, then shorter commands. Unversioned formulae come
    /// before versioned ones (`libpq` before `libpq@16`).
    public func search(_ query: String, limit: Int = 20) -> [(command: String, formulae: [String])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, !needle.contains(" ") else { return [] }
        // Binary search to the first command not below the needle.
        var low = 0, high = pairs.count
        while low < high {
            let mid = (low + high) / 2
            if pairs[mid].key < needle { low = mid + 1 } else { high = mid }
        }
        var formulae: [String: [String]] = [:]
        var index = low
        while index < pairs.count, pairs[index].key.hasPrefix(needle) {
            formulae[pairs[index].command, default: []].append(pairs[index].formula)
            index += 1
        }
        return formulae.keys
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            .prefix(limit)
            .map { command in
                (command, formulae[command]!.sorted { a, b in
                    a.contains("@") != b.contains("@") ? !a.contains("@") : a.localizedStandardCompare(b) == .orderedAscending
                })
            }
    }

    public static func fetch() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }
}
