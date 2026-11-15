# Promotion roadmap

Caskroom is free and open source (MIT). The goal is users and GitHub stars, not revenue.

**The pitch:** Homebrew, the way Apple would have built it. Lead with the App Store-style Discover page and the macOS 26 design. Adopt is not a differentiator: Cork has it, Taphouse sells it in its €9.99 Pro tier, and an app called Caskly appears to exist just for it. Mention it as free here, not as new.

Items marked **(you)** need your accounts, money or eyes; the rest can be done from the repo.

## Phase 0: decide the pitch

- [x] Name: Caskroom
- [x] Licence: MIT
- [x] Hook chosen (above)
- [x] Checked whether Adopt is unique: it isn't (see the pitch)

## Phase 1: make it installable by strangers (weeks 1–3)

- [x] First commit, private repo at `vs-cristian/caskroom`
- [x] README with the hook, features, privacy and build steps
- [ ] **(you)** Real screenshots and a short screen recording for the README: Discover, Updates, a package page, Services. The app's own snapshot captures don't render glass or the sidebar, so these have to be taken on screen.
- [x] Developer ID certificate (team JH3TR8UJG6, expires 15 December 2027) and the `caskroom` notarytool profile, both in the login keychain
- [x] Release script (`Support/release.sh`): builds, signs, notarises, publishes a GitHub Release and writes the tap's cask. Signing and notarising are proven: a rehearsal build passes Gatekeeper as "Notarized Developer ID". Publishing hasn't run.
- [x] Tap repo `vs-cristian/homebrew-tap` (private, no cask until the first release)
- [ ] **(you)** Back up the signing key. Exported to `~/.appstoreconnect/private_keys/caskroom-developer-id-JH3TR8UJG6.p12` (certificate and key, verified); password in the password manager. Left: copy the file somewhere off this Mac. The Copyrail one was lost this way.
- [ ] **(you)** Run the notarised build and check that brew's Apple Events still work under the hardened runtime (uninstall a cask with a login item), plus sudo's password prompt and Adopt
- [x] Caskroom updates itself through brew: its own Updates row offers Update and Relaunch (or Update When I Quit), handed to a detached helper that runs `brew upgrade --cask caskroom` once the app has quit, then reopens it; the next launch shows the log in Activity. Unit-tested against a fake brew; not yet run against a real release.
- [ ] **(you)** Check self-update end to end once there are two releases: install the older one from the tap, Update and Relaunch, and see whether macOS asks for App Management permission (the helper outlives the app that is its responsible process)
- [ ] Test on a clean Mac: no Homebrew, then a fresh Homebrew
- [ ] One-page site: hook, screenshots, install command
- [ ] Commit email: history rewritten to the GitHub noreply address, set in this repo's git config and used by `release.sh` for the tap commit. Pushed. Left: rewrite the tap's README commit (it uses another Gmail address)

## Phase 2: soft launch (week 4)

- [ ] **(you)** Make both repos public (brew can't download a release from a private repo), then cut a release so the tap has a cask
- [ ] **(you)** Post on r/macapps, the MacPowerUsers forum, Mastodon and Bluesky
- [ ] Fix what people report within days and say so in the thread (Taphouse shipped about 8 updates in 10 days)
- [ ] Target: 20–50 real users, obvious bugs gone

## Phase 3: main launch (weeks 5–6)

- [ ] **(you)** Show HN linking the repo; stay in the thread all day (Applite reached about 81 points)
- [ ] **(you)** Product Hunt the following week (Taphouse: 121 upvotes, #10 of the day)
- [ ] "How I built it" article: cancelling brew's whole process group, the sudo askpass helper, Revert

## Phase 4: keep it alive (months 2–3)

- [ ] Changelog post with every release, same channels
- [ ] Pitch blogs and directories: Korben, AlternativeTo, Softpedia
- [ ] Apply to Homebrew's main cask list once the repo meets its notability bar (check the current policy; it also requires passing Gatekeeper)

## Open questions

- macOS 26 and Apple Silicon only shrinks the audience but is also the pitch. Revisit if launch feedback is mostly "doesn't run on my Mac".
- Homebrew now ships an official app (BrewUI). Every launch post should answer "why this one" in its first line.
