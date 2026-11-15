import Foundation

/// Homebrew's public install analytics (formulae.brew.sh), used to rank what's popular.
public enum HomebrewAnalytics {
    /// One package's place in a ranking.
    public struct Entry: Hashable, Sendable {
        public let ref: PackageRef
        public let rank: Int
        public let installs: Int

        public init(ref: PackageRef, rank: Int, installs: Int) {
            self.ref = ref
            self.rank = rank
            self.installs = installs
        }
    }

    /// A package climbing the ranking: its place now and three months ago.
    public struct Climb: Hashable, Sendable {
        public let ref: PackageRef
        public let rank: Int
        public let earlierRank: Int
    }

    /// Formulae count installs asked for by name, not those pulled in as a
    /// dependency; every cask install is asked for.
    public static func url(for kind: PackageKind, days: Int = 30) -> URL {
        switch kind {
        case .formula: URL(string: "https://formulae.brew.sh/api/analytics/install-on-request/\(days)d.json")!
        case .cask: URL(string: "https://formulae.brew.sh/api/analytics/cask-install/\(days)d.json")!
        }
    }

    /// Every package in rank order, without tap-qualified ones ("user/tap/name"),
    /// which `brew info` can't resolve unless that tap is added.
    public static func ranking(from data: Data, kind: PackageKind) throws -> [Entry] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.items
            .sorted { $0.number < $1.number }
            .compactMap { item in
                guard let name = kind == .formula ? item.formula : item.cask, !name.contains("/") else { return nil }
                return Entry(ref: PackageRef(kind, name), rank: item.number, installs: item.installs)
            }
    }

    /// Names in rank order, as `ranking` has them.
    public static func topNames(from data: Data, kind: PackageKind) throws -> [String] {
        try ranking(from: data, kind: kind).map(\.ref.name)
    }

    /// Packages ranked much higher this month than over the last three: the
    /// most-installed charts show the same names month after month, this shows
    /// what's catching on. Only the top `within` count, so a few installs far
    /// down the list don't look like a surge. Biggest climb first, by ratio.
    public static func climbing(now: [Entry], earlier: [Entry], within: Int = 300, minimumRatio: Double = 1.5) -> [Climb] {
        let earlierRanks = Dictionary(earlier.map { ($0.ref, $0.rank) }, uniquingKeysWith: min)
        return now.prefix(within)
            .compactMap { entry -> (Climb, Double)? in
                // Missing from the 90 days, which include these 30: too new to rank there.
                let before = earlierRanks[entry.ref] ?? (earlier.last?.rank ?? entry.rank) + 1
                let ratio = Double(before) / Double(entry.rank)
                guard ratio >= minimumRatio else { return nil }
                return (Climb(ref: entry.ref, rank: entry.rank, earlierRank: before), ratio)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rank < $1.0.rank }
            .map(\.0)
    }

    /// One package's installs over the last 30 days, from its own API page
    /// (formulae.brew.sh/api/formula/ripgrep.json). Only core formulae and casks
    /// have one.
    public static func monthlyInstalls(of ref: PackageRef) async throws -> Int? {
        let url = URL(string: "https://formulae.brew.sh/api/\(ref.kind.rawValue)/\(ref.name).json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try monthlyInstalls(from: data, ref: ref)
    }

    /// A formula's installs on request (its `--HEAD` builds are counted apart
    /// and left out), or a cask's installs.
    public static func monthlyInstalls(from data: Data, ref: PackageRef) throws -> Int? {
        struct Page: Decodable {
            struct Analytics: Decodable {
                let install: [String: [String: Int]]?
                let installOnRequest: [String: [String: Int]]?

                enum CodingKeys: String, CodingKey {
                    case install
                    case installOnRequest = "install_on_request"
                }
            }
            let analytics: Analytics?
        }
        let analytics = try JSONDecoder().decode(Page.self, from: data).analytics
        let counts = ref.kind == .formula ? analytics?.installOnRequest : analytics?.install
        return counts?["30d"]?[ref.name]
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let number: Int
            let formula: String?
            let cask: String?
            /// "417,814"
            let count: String?

            var installs: Int { Int(count?.filter(\.isNumber) ?? "") ?? 0 }
        }
        let items: [Item]
    }
}
