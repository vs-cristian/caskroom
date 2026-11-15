import Foundation

/// Where a package's release notes can be read. Homebrew keeps no changelogs,
/// but most packages publish one of these.
public enum ReleaseSource: Hashable, Sendable {
    /// A repository's GitHub releases, through its Atom feed (no API key, no
    /// rate limit; the latest ten releases).
    case github(owner: String, repo: String)
    /// The Sparkle appcast an app checks for its own updates.
    case sparkle(URL)

    /// An installed app's Sparkle feed, else the GitHub repository its
    /// download, development repository or homepage is on.
    public static func find(for package: Package) -> ReleaseSource? {
        if package.kind == .cask, package.isInstalled, let path = package.appPath,
           let feed = sparkleFeed(appAt: path) {
            return .sparkle(feed)
        }
        for url in [package.downloadURL, package.headURL, package.homepage].compactMap({ $0 }) {
            if let (owner, repo) = githubRepository(url) { return .github(owner: owner, repo: repo) }
        }
        return nil
    }

    /// "BurntSushi/ripgrep" from a github.com URL: a release download, a
    /// `.git` clone URL or a project page.
    static func githubRepository(_ url: URL) -> (String, String)? {
        guard let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        return repo.isEmpty ? nil : (parts[0], repo)
    }

    /// `SUFeedURL` from the app's Info.plist.
    static func sparkleFeed(appAt path: String) -> URL? {
        let plist = URL(fileURLWithPath: path).appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
              feed.scheme == "https" || feed.scheme == "http" else { return nil }
        return feed
    }

    public var feedURL: URL {
        switch self {
        case let .github(owner, repo): URL(string: "https://github.com/\(owner)/\(repo)/releases.atom")!
        case let .sparkle(url): url
        }
    }

    /// Every release, for more than the feed holds. Sparkle has no such page.
    public var releasesPage: URL? {
        switch self {
        case let .github(owner, repo): URL(string: "https://github.com/\(owner)/\(repo)/releases")
        case .sparkle: nil
        }
    }
}

/// One release from a feed.
public struct ReleaseNote: Identifiable, Hashable, Sendable {
    public var id: String { tag }
    /// A GitHub tag ("v14.1.1", "jq-1.8.0") or a Sparkle item's version.
    public let tag: String
    /// A Sparkle item's build number, which a cask's version sometimes
    /// carries after a comma ("1.5.1,183").
    public let build: String?
    public let title: String?
    public let date: Date?
    /// Plain text, made from the HTML the feed carries; empty when it has none.
    public var text: String
    /// The release's page, or the separate page a Sparkle item's notes are on.
    public let url: URL?

    public init(tag: String, build: String? = nil, title: String? = nil, date: Date? = nil, text: String = "", url: URL? = nil) {
        self.tag = tag
        self.build = build
        self.title = title
        self.date = date
        self.text = text
        self.url = url
    }
}

public enum ReleaseNotes {
    /// The notes for an update from `installed` to `current` (newest first, at
    /// most `limit`), or for `current` alone when nothing's installed or the
    /// installed version isn't in the feed. Empty when `current` isn't either.
    public static func load(
        _ source: ReleaseSource, installed: String?, current: String, limit: Int = 5
    ) async throws -> [ReleaseNote] {
        let (data, response) = try await URLSession.shared.data(from: source.feedURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let isSparkle = if case .sparkle = source { true } else { false }
        var notes = between(isSparkle ? appcast(from: data) : atom(from: data), installed: installed,
                            current: current, limit: limit, sameFamily: !isSparkle)
        // Sparkle items often link to their notes rather than carrying them.
        for index in notes.indices where isSparkle && notes[index].text.isEmpty {
            guard let url = notes[index].url, let (page, _) = try? await URLSession.shared.data(from: url) else { continue }
            notes[index].text = text(fromHTML: String(decoding: page, as: UTF8.self))
        }
        return notes
    }

    /// See `load`. A cask's version may hold several parts ("1.5.1,183"); any
    /// matches. With `sameFamily`, releases in between must be tagged like
    /// `current`'s, so a repository that also tags its libraries (ripgrep's
    /// "ignore-0.4.34") shows only the tool's.
    public static func between(
        _ notes: [ReleaseNote], installed: String?, current: String, limit: Int = 5, sameFamily: Bool = true
    ) -> [ReleaseNote] {
        // Of several tags for this version ("mysql-8.4.13", "mysql-cluster-8.4.13"),
        // the plainest is the project's own.
        let candidates = notes.indices.filter { matches(notes[$0], current) }
        guard let currentIndex = candidates.min(by: { a, b in
            (familyPrefix(notes[a].tag, current)?.count ?? .max) < (familyPrefix(notes[b].tag, current)?.count ?? .max)
        }) else { return [] }
        guard let installed, !installed.isEmpty, installed != current,
              let installedIndex = notes[(currentIndex + 1)...].firstIndex(where: { matches($0, installed) })
        else { return [notes[currentIndex]] }
        let family = sameFamily ? familyPrefix(notes[currentIndex].tag, current) : nil
        return Array(notes[currentIndex..<installedIndex].filter { note in
            guard let family else { return true }
            let tag = note.tag.lowercased()
            return tag.hasPrefix(family) && tag.dropFirst(family.count).first?.isNumber == true
        }.prefix(limit))
    }

    /// Whether a release tagged `tag` is `version`: "v1.2", "release-1.2",
    /// "jq-1.2" and "1.2" all are; "11.2" and "0.1.2" aren't.
    public static func tag(_ tag: String, matches version: String) -> Bool {
        let (tag, version) = (tag.lowercased(), version.lowercased())
        guard !version.isEmpty, tag.hasSuffix(version) else { return false }
        guard let last = tag.dropLast(version.count).last else { return true }
        return last == "v" || !(last.isNumber || last.isLetter || last == ".")
    }

    private static func matches(_ note: ReleaseNote, _ version: String) -> Bool {
        version.split(separator: ",").map(String.init).contains { part in
            tag(note.tag, matches: part) || note.build == part
        }
    }

    /// What comes before the version in a tag: "v", "jq-", or nothing.
    private static func familyPrefix(_ tag: String, _ version: String) -> String? {
        let tag = tag.lowercased()
        guard let part = version.split(separator: ",").map({ $0.lowercased() }).first(where: { tag.hasSuffix($0) })
        else { return nil }
        return String(tag.dropLast(part.count))
    }

    // MARK: Feeds

    /// A GitHub releases feed: `<entry>`s with a title, the release page's
    /// link (whose last part is the tag), and HTML content.
    public static func atom(from data: Data) -> [ReleaseNote] {
        FeedParser.parse(data, item: "entry").compactMap { fields in
            let url = fields["link"].flatMap(URL.init(string:))
            guard let tag = url.map({ $0.lastPathComponent }).nonEmpty ?? fields["title"] else { return nil }
            var body = text(fromHTML: fields["content"] ?? "")
            // A release made from a bare tag says only its name, or GitHub's placeholder.
            if body == tag || body == fields["title"] || body == "No content." { body = "" }
            return ReleaseNote(
                tag: tag, title: fields["title"],
                date: fields["updated"].flatMap { try? Date($0, strategy: .iso8601) },
                text: body, url: url
            )
        }
    }

    /// A Sparkle appcast: `<item>`s with versions as elements or as
    /// attributes of their enclosure, and notes as HTML or a link. Items on a
    /// channel (betas) are skipped.
    public static func appcast(from data: Data) -> [ReleaseNote] {
        FeedParser.parse(data, item: "item").compactMap { fields in
            guard fields["sparkle:channel"] == nil else { return nil }
            let build = fields["sparkle:version"] ?? fields["enclosure@sparkle:version"]
            guard let tag = fields["sparkle:shortVersionString"] ?? fields["enclosure@sparkle:shortVersionString"]
                ?? build ?? fields["title"] else { return nil }
            return ReleaseNote(
                tag: tag, build: build, title: fields["title"],
                date: fields["pubDate"].flatMap(rfc822.date(from:)),
                text: text(fromHTML: fields["description"] ?? ""),
                url: (fields["sparkle:releaseNotesLink"] ?? fields["link"]).flatMap(URL.init(string:))
            )
        }
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    // MARK: HTML

    /// Readable text from release-notes HTML: paragraphs and headings on
    /// their own lines, list items as bullets, tags dropped, entities decoded.
    /// Nothing is fetched, unlike an HTML renderer, which would load images.
    public static func text(fromHTML html: String) -> String {
        var text = html
            .replacing(#/(?is)<head\b.*?<\/head>/#, with: "")
            .replacing(#/(?is)<script\b.*?<\/script>/#, with: "")
            .replacing(#/(?is)<style\b.*?<\/style>/#, with: "")
            .replacing(#/(?is)<!--.*?-->/#, with: "")
            .replacing(#/(?i)<br\s*\/?>/#, with: "\n")
            .replacing(#/(?i)<li\b[^>]*>/#, with: "\n• ")
            .replacing(#/(?i)<\/?(p|div|h[1-6]|ul|ol|pre|blockquote|table|tr|section|article)\b[^>]*>/#, with: "\n\n")
            .replacing(#/<[^>]*>/#, with: "")
        text = decodeEntities(text)

        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacing(#/[ \t\u{00A0}]+/#, with: " ").trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if lines.last?.isEmpty == false && lines.last != "•" { lines.append("") }
            } else if lines.last == "•" && line != "•" {
                // A list item whose text was in a paragraph of its own.
                lines[lines.count - 1] = "• " + line
            } else {
                lines.append(line)
            }
        }
        // Bullets of one list sit together, without blank lines between.
        var result: [String] = []
        for (index, line) in lines.enumerated() {
            if line.isEmpty, result.last?.hasPrefix("• ") == true,
               index + 1 < lines.count, lines[index + 1].hasPrefix("• ") { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "hellip": "…", "mdash": "—",
        "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "copy": "©",
    ]

    private static func decodeEntities(_ text: String) -> String {
        text.replacing(#/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);/#) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
            }
            if name == "amp" { return "&" }
            return namedEntities[name] ?? String(match.output.0)
        }
    }
}

/// Collects each item's leaf elements as name → text (CDATA included), plus
/// `link`'s `href` and `enclosure`'s attributes as `enclosure@name`.
private final class FeedParser: NSObject, XMLParserDelegate {
    private let itemElement: String
    private var items: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""

    private init(item: String) {
        itemElement = item
    }

    static func parse(_ data: Data, item: String) -> [[String: String]] {
        let delegate = FeedParser(item: item)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == itemElement {
            current = [:]
            return
        }
        guard current != nil else { return }
        // Atom: the release page is the alternate link (or the only one).
        if name == "link", let href = attributes["href"], attributes["rel"] ?? "alternate" == "alternate" {
            current?["link"] = href
        }
        if name == "enclosure" {
            for (key, value) in attributes { current?["enclosure@\(key)"] = value }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        text += String(decoding: data, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { text = "" }
        guard let item = current else { return }
        if name == itemElement {
            items.append(item)
            current = nil
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first of each: a localized notes link may follow the default.
        if !value.isEmpty, item[name] == nil { current?[name] = value }
        // Present even when empty, so an item on a channel is known as one.
        if name == "sparkle:channel" { current?[name] = value }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

extension PackageKind {
    /// A version as its project numbers it: a formula's "14.1.1_1" (Homebrew's
    /// rebuild of 14.1.1) is "14.1.1". A cask's is left alone.
    public func upstreamVersion(_ version: String) -> String {
        guard self == .formula else { return version }
        return version.replacing(#/_\d+$/#, with: "")
    }
}
