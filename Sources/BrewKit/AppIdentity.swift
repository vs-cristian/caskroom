import Foundation
import Security

/// What an app bundle is known by, for finding the files it leaves outside
/// itself: its bundle ID and those of everything it carries (helpers, login
/// items, extensions, XPC services; each gets its own container and
/// preferences), its privileged helpers, its developer's team ID and its names.
public struct AppIdentity: Hashable, Sendable, Identifiable {
    public var id: String { path }
    /// The bundle, `/Applications/Foo.app`.
    public let path: String
    /// "Foo", from the bundle's file name.
    public let name: String
    public let bundleID: String?
    public let version: String?
    /// The app's own bundle ID first, then those of the bundles inside it.
    /// Bundles inside frameworks are left out: a framework's helper (Sparkle's
    /// Autoupdate) has the same ID in every app that ships it.
    public let bundleIDs: [String]
    /// Executables in `Contents/Library/LaunchServices`, the helpers an app
    /// installs into /Library/PrivilegedHelperTools under the same name.
    public let helperNames: [String]
    /// The developer's team ID from the code signature; nil when unsigned or ad-hoc.
    public let teamID: String?
    /// The names its folders may go by: the file name, `CFBundleName` and the
    /// executable's name, distinct and at least three characters.
    public let names: [String]
    /// Installed from the Mac App Store.
    public let isFromAppStore: Bool

    public init(
        path: String, name: String, bundleID: String?, version: String? = nil,
        bundleIDs: [String]? = nil, helperNames: [String] = [], teamID: String? = nil,
        names: [String]? = nil, isFromAppStore: Bool = false
    ) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.bundleIDs = bundleIDs ?? bundleID.map { [$0] } ?? []
        self.helperNames = helperNames
        self.teamID = teamID
        self.names = names ?? [name]
        self.isFromAppStore = isFromAppStore
    }

    /// One of Apple's own apps, which ship with macOS.
    public var isApple: Bool { bundleID?.lowercased().hasPrefix("com.apple.") == true }

    /// Reads the bundle at `url`; nil when it isn't an app bundle.
    public static func read(at url: URL, readsNestedBundles: Bool = true) -> AppIdentity? {
        let url = url.standardizedFileURL
        guard url.pathExtension == "app", let info = infoDictionary(of: url) else { return nil }
        let bundleID = info["CFBundleIdentifier"] as? String
        let fileName = url.deletingPathExtension().lastPathComponent
        var names: [String] = []
        for candidate in [fileName, info["CFBundleName"] as? String, info["CFBundleExecutable"] as? String] {
            guard let candidate, candidate.count >= 3,
                  !names.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { continue }
            names.append(candidate)
        }
        var bundleIDs = bundleID.map { [$0] } ?? []
        if readsNestedBundles {
            for id in nestedBundleIDs(in: url) where !bundleIDs.contains(id) {
                bundleIDs.append(id)
            }
        }
        let services = url.appending(path: "Contents/Library/LaunchServices")
        let helpers = ((try? FileManager.default.contentsOfDirectory(atPath: services.path)) ?? []).sorted()
        return AppIdentity(
            path: url.path,
            name: fileName,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String,
            bundleIDs: bundleIDs,
            helperNames: helpers,
            teamID: teamIdentifier(of: url),
            names: names,
            isFromAppStore: FileManager.default.fileExists(atPath: url.appending(path: "Contents/_MASReceipt").path)
        )
    }

    /// The `.app`s directly in each folder and one level down (/Applications/Utilities,
    /// a vendor's folder), without their nested bundles or signatures: a quick
    /// list, to tell another app's files from the one being removed.
    public static func apps(in folders: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var apps: [URL] = []
        for folder in folders {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                let url = folder.appending(path: name)
                if url.pathExtension == "app" {
                    apps.append(url)
                } else if isDirectory(url) {
                    for inner in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        apps.append(url.appending(path: inner))
                    }
                }
            }
        }
        return apps
    }

    static func infoDictionary(of bundle: URL) -> [String: Any]? {
        for path in ["Contents/Info.plist", "Info.plist"] {
            if let data = try? Data(contentsOf: bundle.appending(path: path)),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        return nil
    }

    /// Bundle IDs of the apps, extensions and services inside `app`.
    private static func nestedBundleIDs(in app: URL) -> [String] {
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension", "prefPane", "saver", "qlgenerator", "mdimporter", "plugin", "driver"]
        guard let enumerator = FileManager.default.enumerator(
            at: app.appending(path: "Contents"),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var ids: [String] = []
        // Packages aren't descended into by the enumerator, so each bundle is
        // read here and its own Contents searched in turn.
        var pending: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension
            if ext == "framework" || ext == "bundle" {
                enumerator.skipDescendants()
            } else if bundleExtensions.contains(ext) {
                pending.append(url)
            }
        }
        while let bundle = pending.popLast() {
            if let id = infoDictionary(of: bundle)?["CFBundleIdentifier"] as? String, !ids.contains(id) {
                ids.append(id)
            }
            guard let inner = FileManager.default.enumerator(
                at: bundle.appending(path: "Contents"),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in inner {
                let ext = url.pathExtension
                if ext == "framework" || ext == "bundle" {
                    inner.skipDescendants()
                } else if bundleExtensions.contains(ext) {
                    pending.append(url)
                }
            }
        }
        return ids.sorted()
    }

    /// The signing team, from the signature alone: nothing is verified, so this is quick.
    public static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
}
