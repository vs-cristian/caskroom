import XCTest
@testable import BrewKit

final class ReleaseNotesTests: XCTestCase {
    /// Trimmed from github.com/BurntSushi/ripgrep/releases.atom: the tool's
    /// releases with its libraries' between them.
    private let atom = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <updated>2026-10-27T18:31:25Z</updated>
        <link rel="alternate" type="text/html" href="https://github.com/BurntSushi/ripgrep/releases/tag/ignore-0.4.34"/>
        <title>ignore-0.4.34</title>
        <content type="html">&lt;p&gt;ignore-0.4.34&lt;/p&gt;</content>
      </entry>
      <entry>
        <updated>2026-10-20T10:00:00Z</updated>
        <link rel="alternate" type="text/html" href="https://github.com/BurntSushi/ripgrep/releases/tag/15.1.0"/>
        <title>15.1.0</title>
        <content type="html">&lt;h2&gt;Bug fixes&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;Fix &lt;code&gt;--json&lt;/code&gt; output &amp;amp; paths&lt;/li&gt;&lt;li&gt;&lt;p&gt;Faster globbing&lt;/p&gt;&lt;/li&gt;&lt;/ul&gt;</content>
      </entry>
      <entry>
        <updated>2026-09-01T10:00:00Z</updated>
        <link rel="alternate" type="text/html" href="https://github.com/BurntSushi/ripgrep/releases/tag/globset-0.4.21"/>
        <title>globset-0.4.21</title>
        <content type="html">&lt;p&gt;globset-0.4.21&lt;/p&gt;</content>
      </entry>
      <entry>
        <updated>2026-08-01T10:00:00Z</updated>
        <link rel="alternate" type="text/html" href="https://github.com/BurntSushi/ripgrep/releases/tag/15.0.1"/>
        <title>15.0.1</title>
        <content type="html">&lt;p&gt;A patch release.&lt;/p&gt;</content>
      </entry>
      <entry>
        <updated>2026-07-01T10:00:00Z</updated>
        <link rel="alternate" type="text/html" href="https://github.com/BurntSushi/ripgrep/releases/tag/15.0.0"/>
        <title>15.0.0</title>
        <content type="html">&lt;p&gt;Big one.&lt;/p&gt;</content>
      </entry>
    </feed>
    """.utf8)

    /// Shaped like iina.io/appcast.xml, with a beta on a channel.
    private let appcast = Data("""
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel>
        <item>
          <title>1.6.0 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <sparkle:version>190</sparkle:version>
          <sparkle:shortVersionString>1.6.0-beta1</sparkle:shortVersionString>
        </item>
        <item>
          <title>1.5.1</title>
          <pubDate>Mon, 02 Nov 2026 19:47:07 -0500</pubDate>
          <sparkle:version>183</sparkle:version>
          <sparkle:shortVersionString>1.5.1</sparkle:shortVersionString>
          <description><![CDATA[<ul><li>Fixed subtitles</li></ul>]]></description>
        </item>
        <item>
          <title>1.5.0</title>
          <enclosure url="https://example.com/IINA.dmg" sparkle:version="180" sparkle:shortVersionString="1.5.0"/>
          <sparkle:releaseNotesLink>https://iina.io/release-note/1.5.0.html</sparkle:releaseNotesLink>
        </item>
      </channel>
    </rss>
    """.utf8)

    func testAtomEntries() {
        let notes = ReleaseNotes.atom(from: atom)
        XCTAssertEqual(notes.map(\.tag), ["ignore-0.4.34", "15.1.0", "globset-0.4.21", "15.0.1", "15.0.0"])
        // A release made from a bare tag says nothing but its name.
        XCTAssertEqual(notes[0].text, "")
        XCTAssertEqual(notes[1].text, "Bug fixes\n\n• Fix --json output & paths\n• Faster globbing")
        XCTAssertEqual(notes[1].url?.absoluteString, "https://github.com/BurntSushi/ripgrep/releases/tag/15.1.0")
        XCTAssertNotNil(notes[1].date)
    }

    func testUpdateShowsReleasesSinceInstalledOfTheSameFamily() {
        let notes = ReleaseNotes.atom(from: atom)
        // The libraries' tags in between aren't ripgrep's.
        XCTAssertEqual(ReleaseNotes.between(notes, installed: "15.0.0", current: "15.1.0").map(\.tag), ["15.1.0", "15.0.1"])
        // Installed version not in the feed: only the new one.
        XCTAssertEqual(ReleaseNotes.between(notes, installed: "14.0.0", current: "15.1.0").map(\.tag), ["15.1.0"])
        XCTAssertEqual(ReleaseNotes.between(notes, installed: nil, current: "15.0.1").map(\.tag), ["15.0.1"])
        XCTAssertEqual(ReleaseNotes.between(notes, installed: "15.0.0", current: "16.0.0").map(\.tag), [])
        XCTAssertEqual(ReleaseNotes.between(notes, installed: "15.0.0", current: "15.1.0", limit: 1).map(\.tag), ["15.1.0"])
    }

    func testPlainestTagWins() {
        let notes = [ReleaseNote(tag: "mysql-cluster-8.4.13"), ReleaseNote(tag: "mysql-8.4.13"), ReleaseNote(tag: "mysql-8.4.12")]
        XCTAssertEqual(ReleaseNotes.between(notes, installed: "8.4.12", current: "8.4.13").map(\.tag), ["mysql-8.4.13"])
    }

    func testTagMatching() {
        XCTAssertTrue(ReleaseNotes.tag("v1.2.3", matches: "1.2.3"))
        XCTAssertTrue(ReleaseNotes.tag("1.2.3", matches: "1.2.3"))
        XCTAssertTrue(ReleaseNotes.tag("jq-1.8.0", matches: "1.8.0"))
        XCTAssertTrue(ReleaseNotes.tag("release/1.2", matches: "1.2"))
        XCTAssertFalse(ReleaseNotes.tag("11.2", matches: "1.2"))
        XCTAssertFalse(ReleaseNotes.tag("0.1.2", matches: "1.2"))
        XCTAssertFalse(ReleaseNotes.tag("1.2.3", matches: "2.3x"))
    }

    func testAppcastItems() {
        let notes = ReleaseNotes.appcast(from: appcast)
        // The beta is on a channel; versions come from elements or the enclosure.
        XCTAssertEqual(notes.map(\.tag), ["1.5.1", "1.5.0"])
        XCTAssertEqual(notes.map(\.build), ["183", "180"])
        XCTAssertEqual(notes[0].text, "• Fixed subtitles")
        XCTAssertNotNil(notes[0].date)
        XCTAssertEqual(notes[1].text, "")
        XCTAssertEqual(notes[1].url?.absoluteString, "https://iina.io/release-note/1.5.0.html")
        // A cask version with a build after the comma matches either part.
        XCTAssertEqual(ReleaseNotes.between(notes, installed: "1.5.0,180", current: "1.5.1,183", sameFamily: false).map(\.tag), ["1.5.1"])
    }

    func testTextFromHTML() {
        XCTAssertEqual(ReleaseNotes.text(fromHTML: "<p>One&nbsp;&amp; two</p><p>Three<br>four</p>"), "One & two\n\nThree\nfour")
        XCTAssertEqual(ReleaseNotes.text(fromHTML: "<style>p{}</style><script>x()</script><h3>New</h3><ol><li>a</li><li>b</li></ol>"), "New\n\n• a\n• b")
        XCTAssertEqual(ReleaseNotes.text(fromHTML: "&#8220;quoted&#x201D; &lt;tag&gt;"), "“quoted” <tag>")
    }

    func testSources() {
        let ripgrep = Package(ref: PackageRef(.formula, "ripgrep"), fullName: "ripgrep",
                              homepage: URL(string: "https://github.com/BurntSushi/ripgrep"))
        XCTAssertEqual(ReleaseSource.find(for: ripgrep), .github(owner: "BurntSushi", repo: "ripgrep"))
        XCTAssertEqual(ReleaseSource.find(for: ripgrep)?.feedURL.absoluteString, "https://github.com/BurntSushi/ripgrep/releases.atom")

        // The download is on GitHub even when the homepage isn't.
        let abseil = Package(ref: PackageRef(.formula, "abseil"), fullName: "abseil",
                             homepage: URL(string: "https://abseil.io"),
                             downloadURL: URL(string: "https://github.com/abseil/abseil-cpp/archive/refs/tags/20260817.0.tar.gz"))
        XCTAssertEqual(ReleaseSource.find(for: abseil), .github(owner: "abseil", repo: "abseil-cpp"))

        let clone = Package(ref: PackageRef(.formula, "x"), fullName: "x", headURL: URL(string: "https://github.com/o/r.git"))
        XCTAssertEqual(ReleaseSource.find(for: clone), .github(owner: "o", repo: "r"))

        let elsewhere = Package(ref: PackageRef(.formula, "y"), fullName: "y", homepage: URL(string: "https://gnu.org/y"))
        XCTAssertNil(ReleaseSource.find(for: elsewhere))
    }
}
