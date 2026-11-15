import Foundation

/// Where Caskroom keeps its files: folders named after the bundle identifier
/// in Support/Info.plist. Spelled out rather than read from the bundle, since
/// a `swift build` binary has none.
enum AppFolders {
    static let identifier = "io.github.vs-cristian.caskroom"

    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: identifier, directoryHint: .isDirectory)

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: identifier, directoryHint: .isDirectory)
}
