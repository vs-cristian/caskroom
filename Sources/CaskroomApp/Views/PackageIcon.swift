import AppKit
import BrewKit
import SwiftUI

/// An installed app's own icon; else the project's logo; else a quiet glyph
/// tile while there's no logo (or none to find).
struct PackageIcon: View {
    @Environment(BrewStore.self) private var store
    @Environment(LogoStore.self) private var logos
    let ref: PackageRef
    var size: CGFloat = 40

    var body: some View {
        let package = store.package(ref)
        let source = LogoSource(homepage: package?.homepage)
        Group {
            if let image = AppIconCache.icon(at: package?.appPath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Group {
                    if let source, let logo = logos.logos[source.cacheKey] {
                        LogoTile(logo: logo, size: size * 0.82)
                    } else {
                        GlyphTile(name: package?.title ?? ref.name, size: size * 0.82)
                    }
                }
                // App icons leave a margin inside their canvas; match it so
                // tiles and real icons line up in a list.
                .frame(width: size, height: size)
                // A fetched logo fades in over the placeholder. Logos already in
                // memory are there on first draw, so this only runs once per logo.
                .animation(Motion.standard, value: source.map { logos.logos[$0.cacheKey] != nil })
            }
        }
        .frame(width: size, height: size)
        .task(id: source) {
            if let source { await logos.load(source) }
        }
        .accessibilityHidden(true)
    }
}

private struct LogoTile: View {
    let logo: Logo
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if logo.fillsTile {
                Image(nsImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                // Never upscale past 1.5× the source's own 2x size: a soft
                // favicon looks worse than a smaller crisp one.
                let mark = min(size * 0.66, CGFloat(logo.pixelWidth) / 2 * 1.5)
                (logo.isLight ? Color(white: 0.12) : Color.white).overlay {
                    Image(nsImage: logo.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: mark, height: mark)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.02)
    }
}

/// The package's initial on a muted tile, tinted by its name so packages
/// without a logo still tell apart in a list, while staying quieter than real art.
private struct GlyphTile: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        shape
            .fill(LinearGradient(
                colors: [Color(hue: hue, saturation: 0.32, brightness: 0.52), Color(hue: hue, saturation: 0.38, brightness: 0.32)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.02)
    }

    /// "lib" prefixes would make half of all libraries an L.
    private var initial: String {
        let trimmed = name.hasPrefix("lib") && name.count > 3 ? name.dropFirst(3) : Substring(name)
        return trimmed.first(where: \.isLetter).map { String($0).uppercased() } ?? "?"
    }

    /// Stable across launches, unlike `hashValue`.
    private var hue: Double {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(sum % 360) / 360
    }
}

@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage?] = [:]

    static func icon(at path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = icons[path] { return cached }
        let icon = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
        icons[path] = icon
        return icon
    }
}
