import Foundation

/// Which formulae declare a background service (`brew services` can run
/// them), from formulae.brew.sh's formula list. Homebrew has no categories;
/// this is one the data gives for free.
public enum ServiceIndex {
    /// Every core formula, about 30 MB (5 MB compressed, which URLSession asks for).
    public static let url = URL(string: "https://formulae.brew.sh/api/formula.json")!

    /// Names of formulae with a `service` block, alphabetically.
    public static func formulae(from data: Data) throws -> [String] {
        guard let formulae = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return formulae.compactMap { formula in
            guard let name = formula["name"] as? String, let service = formula["service"], !(service is NSNull) else { return nil }
            return name
        }
        .sorted()
    }

    public static func fetch() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try formulae(from: data)
    }
}
