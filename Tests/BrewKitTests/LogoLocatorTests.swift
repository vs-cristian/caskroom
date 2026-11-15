import XCTest
@testable import BrewKit

final class LogoLocatorTests: XCTestCase {
    func testSourceFromHomepage() {
        XCTAssertEqual(LogoSource(homepage: URL(string: "https://github.com/mysql/mysql-server")), .githubOwner("mysql"))
        XCTAssertEqual(LogoSource(homepage: URL(string: "https://GitHub.com/Mas-CLI/mas")), .githubOwner("mas-cli"))
        XCTAssertNil(LogoSource(homepage: URL(string: "https://github.com/")))
        XCTAssertNil(LogoSource(homepage: URL(string: "https://gitlab.com/foo/bar")))
        XCTAssertNil(LogoSource(homepage: URL(string: "ftp://example.com")))
        XCTAssertNil(LogoSource(homepage: nil))
        XCTAssertEqual(LogoSource(homepage: URL(string: "https://redis.io/"))?.cacheKey, "site-redis.io")
    }

    func testPackagesOnOneSiteShareAKey() {
        let a = LogoSource(homepage: URL(string: "https://www.gnu.org/software/wget/"))
        let b = LogoSource(homepage: URL(string: "https://www.gnu.org/software/sed/"))
        XCTAssertEqual(a?.cacheKey, b?.cacheKey)
    }

    func testIconLinksRankedBySize() {
        let html = """
        <head>
        <link rel="icon" href="/favicon.ico">
        <link rel="mask-icon" href="/mask.svg">
        <link rel="icon" sizes="32x32" href="favicon-32.png">
        <LINK REL='apple-touch-icon' HREF='/apple.png'>
        <link rel="icon" sizes="1028x1028" href="/icon.png?v=1&amp;x=2">
        <link rel="stylesheet" href="/site.css">
        </head>
        """
        let urls = LogoLocator.iconLinks(in: html, base: URL(string: "https://redis.io/docs/")!)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://redis.io/icon.png?v=1&x=2",
            "https://redis.io/apple.png",
            "https://redis.io/favicon.ico",
            "https://redis.io/docs/favicon-32.png",
        ])
    }

    func testSVGRanksLarge() {
        let html = #"<link rel="icon" sizes="192x192" href="/icon.png"><link rel="icon" href="/icon.svg">"#
        let urls = LogoLocator.iconLinks(in: html, base: URL(string: "https://claude.com/")!)
        XCTAssertEqual(urls.first?.lastPathComponent, "icon.svg")
    }
}
