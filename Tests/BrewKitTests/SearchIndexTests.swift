import XCTest
@testable import BrewKit

final class SearchIndexTests: XCTestCase {
    let index = SearchIndex(
        formulae: ["tree-sitter", "tree", "gitree", "mongodb/brew/mongodb-community", "wget"],
        casks: ["tree", "treesheets", "mongodb-compass"]
    )

    func testRanksExactThenPrefixThenSubstring() {
        XCTAssertEqual(index.search("tree"), [
            PackageRef(.formula, "tree"), PackageRef(.cask, "tree"),
            PackageRef(.cask, "treesheets"), PackageRef(.formula, "tree-sitter"),
            PackageRef(.formula, "gitree"),
        ])
    }

    func testMatchesLastComponentOfTapName() {
        XCTAssertEqual(index.search("mongodb-comm").first, PackageRef(.formula, "mongodb/brew/mongodb-community"))
    }

    func testCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(index.search("  WGET "), [PackageRef(.formula, "wget")])
    }

    func testEmptyQueryAndLimit() {
        XCTAssertEqual(index.search(" "), [])
        XCTAssertEqual(index.search("e", limit: 2).count, 2)
    }

    func testAddedAndRemoved() {
        let earlier = SearchIndex(formulae: ["tree", "wget", "old"], casks: ["iterm2"])
        let now = SearchIndex(formulae: ["zed-cli", "tree", "wget", "aaa"], casks: ["iterm2", "ghostty"])
        XCTAssertEqual(now.added(since: earlier), [
            PackageRef(.formula, "aaa"), PackageRef(.formula, "zed-cli"), PackageRef(.cask, "ghostty"),
        ])
        XCTAssertEqual(now.removed(since: earlier), [PackageRef(.formula, "old")])
        XCTAssertTrue(now.contains(PackageRef(.cask, "ghostty")))
        XCTAssertFalse(now.contains(PackageRef(.formula, "ghostty")))
    }
}
