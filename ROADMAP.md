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
- [x] Real screenshots for the README: Discover, Updates, a package page, Services. `make screenshots` captures the real window, light and dark, into `docs/assets`, and the README shows them in the reader's theme. No screen recording for now; worth adding if launch posts get little response.
- [x] Developer ID certificate (team JH3TR8UJG6, expires 15 December 2027) and the `caskroom` notarytool profile, both in the login keychain
- [x] Release script (`Support/release.sh`): builds, signs, notarises, publishes a GitHub Release and writes the tap's cask. Ran in full for 0.1.0.
- [x] Tap repo `vs-cristian/homebrew-tap` (private, no cask until the first release)
- [x] **(you)** Back up the signing key: `~/.appstoreconnect/private_keys/caskroom-developer-id-JH3TR8UJG6.p12` (certificate and key, verified), password in the password manager. Marked done on your word; no copy off this Mac was found from here.
- [x] **(you)** Run the notarised build and check that brew's Apple Events still work under the hardened runtime (uninstall a cask with a login item), plus sudo's password prompt and Adopt. All passed on 15 November: `session-manager-plugin` (a `.pkg`) installed and uninstalled through Caskroom's password dialog, then through Touch ID once `sudo_local` enabled it; uninstalling Rectangle raised the System Events prompt and removed its login item; adopting Chrome was first refused by macOS (no prompt, Caskroom's App Management message and button appeared, Chrome untouched) and worked once Caskroom was allowed there.
- [x] Caskroom updates itself through brew: its own Updates row offers Update and Relaunch (or Update When I Quit), handed to a detached helper that runs `brew upgrade --cask caskroom` once the app has quit, then reopens it; the next launch shows the log in Activity. Unit-tested against a fake brew; not yet run against a real release.
- [ ] **(you)** Check self-update end to end once there are two releases: install the older one from the tap, Update and Relaunch, and see whether macOS asks for App Management permission (the helper outlives the app that is its responsible process)
- [ ] Test on a clean Mac: no Homebrew, then a fresh Homebrew. Make it a macOS 15 VM, to see the Sequoia fallbacks too
- [x] One-page site: plain HTML/CSS in `docs/` (Apple product-page style, light and dark, real window screenshots, checked at phone width; preview with `python3 -m http.server -d docs`). Live at https://vs-cristian.github.io/caskroom/ since 15 November, GitHub Pages from `main`'s `docs/`; every push to it redeploys. A custom domain can come later.
- [x] Commit email: history rewritten to the GitHub noreply address, set in this repo's git config and used by `release.sh` for the tap commit. The tap's README commit was rewritten too. Both pushed.

## Phase 2: soft launch (week 4)

- [x] **(you)** Make both repos public (brew can't download a release from a private repo), then cut a release so the tap has a cask. Both public on 15 November (history checked first: no secrets, only the noreply email). [0.1.0](https://github.com/vs-cristian/caskroom/releases/tag/v0.1.0) released the same day by `Support/release.sh`; `brew install --cask vs-cristian/tap/caskroom` installed it on this Mac, Gatekeeper accepts it as "Notarized Developer ID" and the first open shows macOS's usual "downloaded from the internet" prompt, nothing worse.
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

- macOS 15 Sequoia is supported from the release after 0.1.0, with plain bordered buttons where macOS 26 has glass; not yet run on a Sequoia Mac (a Sequoia VM would do, and could double as the clean-Mac test). Apple Silicon only still shrinks the audience: revisit if launch feedback is mostly "doesn't run on my Mac".
- Homebrew now ships an official app (BrewUI). Every launch post should answer "why this one" in its first line.
