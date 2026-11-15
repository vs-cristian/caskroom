import XCTest
@testable import BrewKit

final class BrewDownloadsTests: XCTestCase {
    /// The name brew gave this cask's download, seen in its cache.
    func testHashMatchesBrewsFileName() {
        let url = URL(string: "https://session-manager-downloads.s3.amazonaws.com/plugin/1.2.896.0/mac_arm64/session-manager-plugin.pkg")!
        XCTAssertEqual(BrewDownloads.urlHash(url), "6078ef67dcc292f9f98efc4e0659d606ad5c3b06157699222444bcb064a5739e")
    }

    func testFindsRecentIncompleteDownloadsOnly() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = cache.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        let write = { (name: String, bytes: Int, modified: Date) in
            let file = downloads.appendingPathComponent(name)
            try Data(count: bytes).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        let start = Date.now.addingTimeInterval(-60)
        try write("aaa--app.dmg.incomplete", 1200, .now)
        try write("bbb--done.dmg", 500, .now)                                         // finished: renamed
        try write("ccc--abandoned.pkg.incomplete", 900, start.addingTimeInterval(-3600)) // an earlier, given-up download
        try write("notadownload.incomplete", 10, .now)

        let partial = BrewDownloads.partial(in: cache, since: start)
        XCTAssertEqual(partial.map(\.urlHash), ["aaa"])
        XCTAssertEqual(partial.first?.size, 1200)
    }

    func testNoCacheFolderMeansNothing() {
        XCTAssertEqual(BrewDownloads.partial(in: URL(fileURLWithPath: "/nonexistent-\(UUID())"), since: .distantPast), [])
    }

    func testProgressFractionAndSummary() {
        let progress = DownloadProgress(received: 6_500_000, total: 10_000_000, bytesPerSecond: 21_000)
        XCTAssertEqual(progress.fraction, 0.65)
        // Sizes in the reader's locale ("6,5 MB" on some Macs).
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        XCTAssertEqual(progress.summary, "\(bytes(6_500_000)) of \(bytes(10_000_000)) · \(bytes(21_000))/s")
        XCTAssertNil(DownloadProgress(received: 10).fraction)
        XCTAssertEqual(DownloadProgress(received: 20, total: 10).fraction, 1)
    }

    func testTrackerCountsFinishedFilesAndTotalsOnlyWhenEverySizeIsKnown() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let file = { (hash: String, size: Int64) in BrewDownloads.Partial(urlHash: hash, size: size, modified: t0) }
        var tracker = DownloadTracker()

        XCTAssertNil(tracker.update([], sizes: [:], at: t0), "nothing downloading yet")

        var progress = tracker.update([file("a", 100)], sizes: ["a": 400], at: t0)
        XCTAssertEqual(progress?.received, 100)
        XCTAssertEqual(progress?.total, 400)
        XCTAssertNil(progress?.bytesPerSecond)

        // One second later, a has grown and a second file, of unknown size, started.
        progress = tracker.update([file("a", 300), file("b", 50)], sizes: ["a": 400], at: t0 + 1)
        XCTAssertEqual(progress?.received, 350)
        XCTAssertNil(progress?.total, "b's size isn't known")
        XCTAssertEqual(progress?.bytesPerSecond, 250)

        // a finished (renamed, gone from the list): it counts at its full size.
        progress = tracker.update([file("b", 150)], sizes: ["a": 400, "b": 200], at: t0 + 2)
        XCTAssertEqual(progress?.received, 550)
        XCTAssertEqual(progress?.total, 600)
        XCTAssertEqual(progress?.fraction ?? 0, 550.0 / 600, accuracy: 0.0001)

        // Everything done: no progress to show.
        XCTAssertNil(tracker.update([], sizes: ["a": 400, "b": 200], at: t0 + 3))
    }
}
