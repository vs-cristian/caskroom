import Foundation

/// Which casks install which app bundles, from Homebrew's public cask list,
/// so apps installed by hand can be matched to a cask and adopted.
public enum AdoptionIndex {
    /// Every cask, about 20 MB; fetched only when the Adopt page or Discover opens.
    public static let url = URL(string: "https://formulae.brew.sh/api/cask.json")!

    /// App bundle name ("Google Chrome.app") to the tokens of casks that
    /// install it, unversioned casks (no `@beta`) first.
    public static func casksByApp(from data: Data) throws -> [String: [String]] {
        guard let casks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var index: [String: [String]] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                // `app` is a list of names, or of a name and `{"target": …}`.
                for case let app as String in artifact["app"] as? [Any] ?? [] {
                    index[app, default: []].append(token)
                }
            }
        }
        return index.mapValues { tokens in
            tokens.sorted { a, b in a.contains("@") != b.contains("@") ? !a.contains("@") : a < b }
        }
    }

    /// The cask for each app in `apps` (bundle names) that one installs, in
    /// the order given. Apps no cask installs are left out.
    public static func matches(apps: [String], in index: [String: [String]]) -> [(app: String, token: String)] {
        apps.compactMap { app in index[app]?.first.map { (app, $0) } }
    }

    public static func fetch() async throws -> [String: [String]] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try casksByApp(from: data)
    }
}
