# Caskroom

Homebrew, the way Apple would have built it: a native macOS 26 app for browsing, installing and updating everything `brew` manages.

Caskroom is a front end to the `brew` command you already have. It runs `brew`, reads its JSON, and shows you the exact command behind every action. It never reimplements Homebrew or touches its files.

## What it does

- **Discover.** Top apps, top command-line tools, what's trending and what's new in Homebrew, laid out like the App Store, with real app icons and project logos.
- **Updates.** One list for formulae and apps, with release notes per package, Update All, and a history of what Caskroom updated.
- **Adopt.** Finds apps already in your Applications folder that Homebrew has a cask for and hands them over without downloading them again.
- **Revert.** Puts a formula back to the version it had before its last update.
- **Services.** `brew services` as Login Items: a switch for start at login, Run and Stop for right now, and the log one click away.
- **Search.** Packages by name, or by the command they install (`rg` finds ripgrep).
- **Security, if you turn it on.** Checks installed formulae against OSV.dev with `brew vulns` and updates the ones that have a fix.
- **Maintenance.** Clean Up with a preview of what it frees, Doctor, Export Brewfile, and warnings for deprecated or disabled packages.

## Requirements

- macOS 26 or later on Apple Silicon
- [Homebrew](https://brew.sh)

## Install

There is no signed download yet. Until there is, build it from source, which needs Xcode 26 or later:

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
