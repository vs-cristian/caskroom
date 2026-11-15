import Foundation

/// Where a package's logo comes from: its GitHub organisation's avatar, or the
/// icons its homepage declares. Keyed so packages sharing a site share one fetch.
public enum LogoSource: Hashable, Sendable {
    case githubOwner(String)
    case site(URL)

    /// Code hosts whose icon is the host's own brand, not the project's.
    static let codeHosts: Set<String> = [
        "gitlab.com", "sourceforge.net", "codeberg.org", "bitbucket.org", "sr.ht", "git.sr.ht",
        "pypi.org", "crates.io", "launchpad.net", "savannah.gnu.org", "savannah.nongnu.org",
        "salsa.debian.org", "gitlab.freedesktop.org", "gitlab.gnome.org", "invent.kde.org",
        "hackage.haskell.org", "metacpan.org", "www.npmjs.com", "npmjs.com", "pkg.go.dev",
    ]

    public init?(homepage: URL?) {
        guard let homepage, let host = homepage.host()?.lowercased(),
              homepage.scheme == "https" || homepage.scheme == "http" else { return nil }
        if host == "github.com" || host == "www.github.com" {
            guard let owner = homepage.pathComponents.dropFirst().first, !owner.isEmpty else { return nil }
            self = .githubOwner(owner.lowercased())
        } else if Self.codeHosts.contains(host) {
            return nil
        } else {
            self = .site(homepage)
        }
    }

    public var cacheKey: String {
        switch self {
        case let .githubOwner(owner): "github-\(owner)"
        case let .site(url): "site-\(url.host()?.lowercased() ?? url.absoluteString)"
        }
    }
}

public enum LogoError: Error {
    /// Discovery failed in a way worth retrying later (offline, rate-limited).
    case transient
}

public struct LogoLocator: Sendable {
    static let userAgent = "Caskroom/0.1 (macOS Homebrew client)"

    public init() {}

    /// Image URLs to try, most promising first. Empty means there is no logo to
    /// find; `LogoError.transient` means try again another time.
    public func candidates(for source: LogoSource) async throws -> [URL] {
        switch source {
        case let .githubOwner(owner):
            // An organisation's avatar is usually the project's logo; a person's
            // is their face, which is no logo at all.
            let api = URL(string: "https://api.github.com/users/\(owner)")!
            guard let (data, status) = try? await fetch(api), status == 200 else { throw LogoError.transient }
            struct Account: Decodable { let type: String }
            guard (try? JSONDecoder().decode(Account.self, from: data))?.type == "Organization" else { return [] }
            return [URL(string: "https://github.com/\(owner).png?size=256")!]

        case let .site(homepage):
            guard let (data, status) = try? await fetch(homepage, maxBytes: 512 * 1024) else { throw LogoError.transient }
            // Turned away (bot protection, rate limits) or down: the icons
            // are likely refused too, and a miss would be remembered for a week.
            if status == 403 || status == 429 || status >= 500 { throw LogoError.transient }
            var urls = status == 200 ? Self.iconLinks(in: String(decoding: data, as: UTF8.self), base: homepage) : []
            if let root = URL(string: "/", relativeTo: homepage)?.absoluteURL {
                urls.append(root.appending(path: "apple-touch-icon.png"))
                urls.append(root.appending(path: "favicon.ico"))
            }
            var seen = Set<URL>()
            return urls.filter { seen.insert($0).inserted }
        }
    }

    public func fetch(_ url: URL, maxBytes: Int = 2 * 1024 * 1024) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data.prefix(maxBytes), (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The `<link rel="…icon…">` hrefs in `html`, largest declared size first.
    /// Apple touch icons default to 180px and SVGs rank as large; an icon with no
    /// size is assumed small.
    static func iconLinks(in html: String, base: URL) -> [URL] {
        let tagPattern = try! Regex("<link\\b[^>]*>").ignoresCase()
        var ranked: [(size: Int, order: Int, url: URL)] = []
        for (order, match) in html.matches(of: tagPattern).enumerated() {
            let tag = String(html[match.range])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  rel != "mask-icon",
                  let href = attribute("href", in: tag),
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
            else { continue }
            let declared = attribute("sizes", in: tag)?.lowercased()
            let size: Int
            if declared == "any" || url.pathExtension.lowercased() == "svg" {
                size = 512
            } else if let declared, let width = Int(declared.split(separator: "x").first ?? "") {
                size = width
            } else if rel.contains("apple-touch-icon") {
                size = 180
            } else {
                size = 32
            }
            ranked.append((size, order, url))
        }
        return ranked
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.order < $1.order }
            .map(\.url)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = try! Regex("\\b\(name)\\s*=\\s*([\"'])(.*?)\\1").ignoresCase()
        guard let match = tag.firstMatch(of: pattern), let value = match.output[2].substring else { return nil }
        return String(value)
    }
}
