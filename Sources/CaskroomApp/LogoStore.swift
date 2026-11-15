import AppKit
import BrewKit
import Observation

/// A fetched project logo, with what's needed to lay it out well.
struct Logo {
    let image: NSImage
    /// Largest bitmap width; logos are never drawn larger than this can hold.
    let pixelWidth: Int
    /// Opaque square art (most avatars) fills its tile; a transparent mark sits
    /// on a white tile with a margin.
    let fillsTile: Bool
    /// A transparent mark that's nearly white (ChatGPT's), which would vanish
    /// on white; it sits on a dark tile instead.
    var isLight = false
}

/// Project logos, fetched once and kept in ~/Library/Caches. A site with no
/// usable logo is remembered for a week so it isn't asked again every launch.
@Observable @MainActor
final class LogoStore {
    private(set) var logos: [String: Logo] = [:]

    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private let locator = LogoLocator()
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appending(path: "club.iscout.caskroom/Logos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let minimumWidth = 32
    static let missRetryInterval: TimeInterval = 7 * 24 * 3600
    static let concurrentFetches = 4

    func load(_ source: LogoSource) async {
        let key = source.cacheKey
        guard attempted.insert(key).inserted else { return }

        let imageFile = directory.appending(path: "\(key).png")
        let missFile = directory.appending(path: "\(key).none")
        if let data = try? Data(contentsOf: imageFile), let logo = Self.logo(from: data) {
            logos[key] = logo
            return
        }
        if let modified = try? missFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date.now.timeIntervalSince(modified) < Self.missRetryInterval {
            return
        }

        await acquire()
        defer { release() }
        do {
            let candidates = try await locator.candidates(for: source)
            let (found, answered) = await firstUsable(candidates)
            if let (data, logo) = found {
                logos[key] = logo
                try? data.write(to: imageFile)
            } else if answered || candidates.isEmpty {
                try? Data().write(to: missFile)
            } else {
                // Every fetch failed (timeouts, offline): not a real miss.
                attempted.remove(key)
            }
        } catch {
            // Offline or rate-limited: let a later appearance try again.
            attempted.remove(key)
        }
    }

    /// The first candidate that decodes at 64px or more, else the largest one
    /// over the minimum; and whether any server answered at all.
    private func firstUsable(_ urls: [URL]) async -> (found: (Data, Logo)?, answered: Bool) {
        var fallback: (Data, Logo)?
        var answered = false
        for url in urls {
            guard let (data, status) = try? await locator.fetch(url) else { continue }
            answered = true
            guard status == 200, let logo = Self.logo(from: data), logo.pixelWidth >= Self.minimumWidth else { continue }
            // Store as PNG: .ico and .svg sources come back as whatever NSImage made of them.
            let png = Self.pngData(logo.image) ?? data
            if logo.pixelWidth >= 64 { return ((png, logo), true) }
            if logo.pixelWidth > (fallback?.1.pixelWidth ?? 0) { fallback = (png, logo) }
        }
        return (fallback, answered)
    }

    private static func logo(from data: Data) -> Logo? {
        guard !data.isEmpty, let image = NSImage(data: data), image.size.width > 0 else { return nil }
        let bitmapWidth = image.representations.map(\.pixelsWide).max() ?? 0
        // Vector reps report no pixels; they scale to any size.
        let width = bitmapWidth > 0 ? bitmapWidth : 512
        let square = abs(image.size.width - image.size.height) < image.size.width * 0.05
        guard let rep = thumbnail(image) else { return Logo(image: image, pixelWidth: width, fillsTile: false) }
        let transparentCorners = hasTransparentCorners(rep)
        return Logo(image: image, pixelWidth: width, fillsTile: square && !transparentCorners,
                    isLight: transparentCorners && isLight(rep))
    }

    private static let thumbnailSide = 24

    private static func thumbnail(_ image: NSImage) -> NSBitmapImageRep? {
        let side = thumbnailSide
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func hasTransparentCorners(_ rep: NSBitmapImageRep) -> Bool {
        let side = thumbnailSide
        let corners = [(1, 1), (side - 2, 1), (1, side - 2), (side - 2, side - 2)]
        return corners.contains { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) < 0.5 }
    }

    /// Whether the visible pixels average close to white.
    private static func isLight(_ rep: NSBitmapImageRep) -> Bool {
        var total: CGFloat = 0
        var count = 0
        for x in 0..<thumbnailSide {
            for y in 0..<thumbnailSide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                total += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                count += 1
            }
        }
        return count > 0 && total / CGFloat(count) > 0.9
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func acquire() async {
        if running < Self.concurrentFetches {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
