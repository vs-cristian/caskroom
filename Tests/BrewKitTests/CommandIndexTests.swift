import XCTest
@testable import BrewKit

final class CommandIndexTests: XCTestCase {
    private let index = CommandIndex(text: """
    ripgrep:rg
    libpq@16:pg_dump psql
    libpq:clusterdb pg_dump pg_dumpall psql
    jq(1.8.1):jq
    broken line
    empty:
    """)

    func testCommandsOfAFormula() {
        XCTAssertEqual(index.commands(of: "libpq"), ["clusterdb", "pg_dump", "pg_dumpall", "psql"])
        // The version in parentheses isn't part of the name.
        XCTAssertEqual(index.commands(of: "jq"), ["jq"])
        XCTAssertEqual(index.commands(of: "nope"), [])
        XCTAssertEqual(index.formulaCount, 4)
    }

    func testSearchByCommand() {
        let hits = index.search("pg_dump")
        // Exact first; the unversioned formula before the versioned one.
        XCTAssertEqual(hits.map(\.command), ["pg_dump", "pg_dumpall"])
        XCTAssertEqual(hits.first?.formulae, ["libpq", "libpq@16"])
        XCTAssertEqual(index.search("RG").first?.formulae, ["ripgrep"])
        XCTAssertTrue(index.search("zzz").isEmpty)
        XCTAssertTrue(index.search("rg grep").isEmpty)
    }
}

final class AdoptionIndexTests: XCTestCase {
    func testAppsToCasks() throws {
        let json = #"""
        [
          {"token": "google-chrome", "artifacts": [{"app": ["Google Chrome.app"]}, {"zap": [{"trash": "~/x"}]}]},
          {"token": "telegram@beta", "artifacts": [{"app": ["Telegram.app"]}]},
          {"token": "telegram", "artifacts": [{"uninstall": [{"quit": "ru.keepcoder.Telegram"}]}, {"app": ["Telegram.app"]}]},
          {"token": "tool", "artifacts": [{"binary": ["tool"]}]},
          {"token": "renamed", "artifacts": [{"app": ["Old Name.app", {"target": "New Name.app"}]}]}
        ]
        """#
        let index = try AdoptionIndex.casksByApp(from: Data(json.utf8))
        XCTAssertEqual(index["Google Chrome.app"], ["google-chrome"])
        XCTAssertEqual(index["Telegram.app"], ["telegram", "telegram@beta"])
        XCTAssertEqual(index["Old Name.app"], ["renamed"])
        XCTAssertEqual(
            AdoptionIndex.matches(apps: ["Safari.app", "Telegram.app", "Google Chrome.app"], in: index).map(\.token),
            ["telegram", "google-chrome"]
        )
    }
}
