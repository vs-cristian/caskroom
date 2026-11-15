import AppKit
import BrewKit
import SwiftUI

/// Release notes, fetched when first shown and kept until quit. Homebrew
/// stores no changelogs, so they come from the project: its GitHub releases,
/// or the Sparkle feed an installed app updates itself from.
@Observable @MainActor
final class ReleaseNotesStore {
    struct Key: Hashable {
        let ref: PackageRef
        /// Set for an update: notes from after this version.
        let installed: String?
        let current: String
    }

    enum State: Equatable {
        case loading
        /// Possibly empty: the feed didn't have this version.
        case loaded([ReleaseNote], ReleaseSource)
        /// No feed Caskroom can read.
        case unavailable
    }

    private(set) var states: [Key: State] = [:]

    /// The notes for `package`'s update, if `update` is set, else for its latest version.
    static func key(_ package: Package, update: OutdatedItem?) -> Key? {
        let kind = package.kind
        guard let current = update?.currentVersion ?? package.latestVersion else { return nil }
        let installed = update != nil ? package.installedVersions.last.map(kind.upstreamVersion) : nil
        return Key(ref: package.ref, installed: installed, current: kind.upstreamVersion(current))
    }

    func load(_ package: Package, update: OutdatedItem?) async {
        guard let key = Self.key(package, update: update), states[key] == nil else { return }
        guard let source = ReleaseSource.find(for: package) else {
            states[key] = .unavailable
            return
        }
        states[key] = .loading
        // A feed that can't be read counts as one without this version: the
        // releases page or homepage is still linked.
        let notes = (try? await ReleaseNotes.load(source, installed: key.installed, current: key.current)) ?? []
        states[key] = .loaded(notes, source)
    }
}

/// What changed in an update, App Store style: each release's notes, newest
/// first, then a link to read more.
struct WhatsNewView: View {
    @Environment(ReleaseNotesStore.self) private var notesStore
    let package: Package
    var update: OutdatedItem?
    /// Lines of each release's notes shown before "more".
    var lineLimit = 6
    /// Releases shown at most, newest first; All Releases has the rest.
    var noteLimit: Int?

    var body: some View {
        let key = ReleaseNotesStore.key(package, update: update)
        VStack(alignment: .leading, spacing: 14) {
            switch key.flatMap({ notesStore.states[$0] }) {
            case nil, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading release notes…").foregroundStyle(.secondary)
                }
            case let .loaded(notes, source) where !notes.isEmpty:
                ForEach(noteLimit.map { Array(notes.prefix($0)) } ?? notes) { note in
                    NoteView(note: note, lineLimit: lineLimit)
                }
                if let page = source.releasesPage {
                    Link("All Releases", destination: page).font(.callout)
                }
            case let .loaded(_, source):
                message("\(name) hasn't published notes for \(key?.current ?? "this version") where Caskroom can read them.",
                        link: source.releasesPage.map { ("All Releases", $0) } ?? homepage)
            case .unavailable:
                message("\(name) doesn't publish release notes Caskroom can read.", link: homepage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.quick, value: key.flatMap { notesStore.states[$0] })
        .task(id: key) { await notesStore.load(package, update: update) }
    }

    private var name: String { package.title }

    private var homepage: (String, URL)? {
        package.homepage.map { ("Homepage", $0) }
    }

    private func message(_ text: String, link: (String, URL)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let (title, url) = link {
                Link(title, destination: url).font(.callout)
            }
        }
    }
}

private struct NoteView: View {
    let note: ReleaseNote
    let lineLimit: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.tag).font(.headline.monospacedDigit())
                Spacer()
                if let date = note.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if note.text.isEmpty {
                if let url = note.url {
                    Link("Release Notes", destination: url).font(.callout)
                }
            } else {
                Text(note.text)
                    .lineLimit(expanded ? nil : lineLimit)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !expanded && note.text.mayRunPast(lines: lineLimit) {
                    Button("more") { expanded = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }
}

/// The What's New link on an update's row, opening its notes in a popover.
struct WhatsNewButton: View {
    let package: Package
    let update: OutdatedItem
    @State private var shown = false

    var body: some View {
        Button("What's New") { shown = true }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What's New in \(package.title)").font(.title3.weight(.bold))
                        WhatsNewView(package: package, update: update, lineLimit: 12)
                    }
                    .padding(20)
                }
                .frame(width: 440, height: 420)
            }
    }
}
