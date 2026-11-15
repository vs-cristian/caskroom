import CryptoKit
import Foundation

/// How far brew has got with what it's downloading. Without a terminal brew
/// prints no progress, but it downloads each file to
/// `<cache>/downloads/<SHA-256 of the URL>--<file name>.incomplete` and renames
/// it when done, so the file's size is the progress, and the hash says which
/// URL it is.
public enum BrewDownloads {
    /// A file brew is still downloading.
    public struct Partial: Equatable, Sendable {
        /// SHA-256 of the URL, in hex: what `urlHash(_:)` gives for that URL.
        public let urlHash: String
        public let size: Int64
        public let modified: Date

        public init(urlHash: String, size: Int64, modified: Date) {
            self.urlHash = urlHash
            self.size = size
            self.modified = modified
        }
    }

    /// The hash brew names a download after.
    public static func urlHash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads in progress in `cache` (brew's `--cache`), written to since
    /// `since`: an older `.incomplete` file is one brew gave up on.
    public static func partial(in cache: URL, since: Date) -> [Partial] {
        let folder = cache.appendingPathComponent("downloads", isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return files.compactMap { file in
            let name = file.lastPathComponent
            guard name.hasSuffix(".incomplete"), let separator = name.range(of: "--") else { return nil }
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified >= since else { return nil }
            return Partial(urlHash: String(name[..<separator.lowerBound]), size: Int64(values.fileSize ?? 0), modified: modified)
        }
    }

    /// The size the server gives for `url`, following redirects (a GitHub
    /// release asset redirects to its storage), or nil when it doesn't say.
    public static func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength > 0 else { return nil }
        return http.expectedContentLength
    }
}

/// What a running operation has downloaded so far, across its files.
public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    /// Known only when every file's size is.
    public var total: Int64?
    public var bytesPerSecond: Double?

    public init(received: Int64, total: Int64? = nil, bytesPerSecond: Double? = nil) {
        self.received = received
        self.total = total
        self.bytesPerSecond = bytesPerSecond
    }

    /// 0 to 1, when the total is known.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// "6.5 MB of 9.9 MB · 21 KB/s", or "6.5 MB · 21 KB/s" without a total.
    public var summary: String {
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        var text = total.map { "\(bytes(received)) of \(bytes($0))" } ?? bytes(received)
        if let bytesPerSecond, bytesPerSecond > 0 { text += " · \(bytes(Int64(bytesPerSecond)))/s" }
        return text
    }
}

/// Turns successive looks at brew's partial downloads into one progress for
/// an operation that may fetch several files: each file counts once seen, and
/// one that has gone from the list finished (brew renames it).
public struct DownloadTracker: Sendable {
    private var active: [String: Int64] = [:]
    private var finished: [String: Int64] = [:]
    private var last: (date: Date, received: Int64)?
    private var speed: Double?

    public init() {}

    /// Every file seen so far, by URL hash.
    public var seen: Set<String> { Set(active.keys).union(finished.keys) }

    /// The progress after a look at `partial` at `date`, with the sizes known
    /// so far by URL hash; nil while nothing is downloading.
    public mutating func update(_ partial: [BrewDownloads.Partial], sizes: [String: Int64], at date: Date = .now) -> DownloadProgress? {
        let now = partial.reduce(into: [String: Int64]()) { $0[$1.urlHash] = $1.size }
        for (hash, size) in active where now[hash] == nil {
            finished[hash] = sizes[hash] ?? size
        }
        active = now
        guard !active.isEmpty else {
            last = nil
            speed = nil
            return nil
        }
        let received = active.values.reduce(0, +) + finished.values.reduce(0, +)
        if let last, received > last.received, date > last.date {
            let instant = Double(received - last.received) / date.timeIntervalSince(last.date)
            speed = speed.map { $0 * 0.7 + instant * 0.3 } ?? instant
        }
        last = (date, received)
        let known = seen.compactMap { sizes[$0] }
        return DownloadProgress(received: received,
                                total: known.count == seen.count ? known.reduce(0, +) : nil,
                                bytesPerSecond: speed)
    }
}
