# Caskroom

Homebrew, the way Apple would have built it: a native Mac app for browsing, installing and updating everything `brew` manages.

Caskroom is a front end to the `brew` command you already have. It runs `brew`, reads its JSON, and shows you the exact command behind every action. It never reimplements Homebrew or touches its files. The one thing it does itself is clear away the files an uninstalled app leaves behind, which `brew` has no command for.

**[vs-cristian.github.io/caskroom](https://vs-cristian.github.io/caskroom/)**

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/discover-dark.avif"><img src="docs/assets/discover.avif" alt="Caskroom's Discover page: an updates banner above the most installed apps this month, each with Install, Update or Adopt."></picture></p>

## What it does

- **Discover.** Top apps, top command-line tools, what's trending and what's new in Homebrew, laid out like the App Store, with real app icons and project logos.
- **Updates.** One list for formulae and apps, with release notes per package, Update All, and a history of what Caskroom updated. ⌘-click several to update, pin or uninstall them together, here or in your library.
- **Adopt.** Finds apps already in your Applications folder that Homebrew has a cask for and hands them over without downloading them again.
- **Uninstall apps completely.** Any app, from Homebrew or not: it goes to the Trash with its settings, caches, containers, launch agents, privileged helpers and installer receipts. You see the list first, ticked by how sure Caskroom is, AppCleaner style. Drop an app on the page, or pick one with File ▸ Uninstall App….
- **Revert.** Puts a formula back to the version it had before its last update.
- **Services.** `brew services` as Login Items: a switch for start at login, Run and Stop for right now, and the log one click away.
- **Search.** Packages by name, or by the command they install (`rg` finds ripgrep).
- **Security, if you turn it on.** Checks installed formulae against OSV.dev with `brew vulns` and updates the ones that have a fix.
- **Taps.** Add and remove third-party taps, and see what each one has given you.
- **Brewfiles.** Export what you have, or import a Brewfile and see what it would install before it does.
- **Maintenance.** Clean Up with a preview of what it frees, Doctor, and warnings for deprecated or disabled packages.

<p align="center">
<picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/updates-dark.avif"><img src="docs/assets/updates.avif" alt="The Updates page: packages with old and new versions, What's New links, a recent update with Revert, and a Clean Up banner." width="32%"></picture>
<picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/services-dark.avif"><img src="docs/assets/services.avif" alt="The Services page: a running service, one that failed and three stopped, each with Run or Stop and an At Login switch." width="32%"></picture>
<picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/package-dark.avif"><img src="docs/assets/package.avif" alt="Blender's package page: version, installs, size and requirements, What's New, Information and the Terminal commands." width="32%"></picture>
</p>

## Requirements

- macOS 15 Sequoia or later on Apple Silicon (Liquid Glass on macOS 26 and later)
- [Homebrew](https://brew.sh)

## Install

```sh
brew install --cask vs-cristian/tap/caskroom
```

Caskroom then keeps itself up to date through brew, like any other app it manages. The download is also on the [releases page](https://github.com/vs-cristian/caskroom/releases).

To build it from source instead, which needs Xcode 26 or later:

```sh
git clone https://github.com/vs-cristian/caskroom.git
cd caskroom
make run
```

`make run` builds `build/Caskroom.app` and opens it. Move it to Applications to keep it.

## What it sends over the network

- **Homebrew's public API** (formulae.brew.sh): install rankings and package lists.
- **Package homepages and GitHub**: logos and release notes for the packages on screen.
- **OSV.dev**: the names and versions of your installed formulae, only after you turn Security on.

There is no analytics and no account.

## Development

```sh
swift build        # debug build
swift test         # unit tests, against a fake brew and JSON fixtures
make app           # release build assembled into build/Caskroom.app
```

`CLAUDE.md` describes the architecture and the reasons behind it.

## How it's built

Caskroom is written with [Claude Code](https://claude.com/claude-code). `CLAUDE.md` is the working design record, kept in the repo so you can see how decisions were made.

## Licence

MIT. See [LICENSE](LICENSE).

Caskroom is not affiliated with or endorsed by the Homebrew project.
