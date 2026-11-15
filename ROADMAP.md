# Promotion roadmap

Caskroom is free and open source (MIT). The goal is users and GitHub stars, not revenue.

**The pitch:** Homebrew, the way Apple would have built it. Lead with the App Store-style Discover page and the macOS 26 design; Adopt is the second line.

Items marked **(you)** need your accounts, money or eyes; the rest can be done from the repo.

## Phase 0: decide the pitch

- [x] Name: Caskroom
- [x] Licence: MIT
- [x] Hook chosen (above)
- [ ] Check that no competitor has Adopt before leading with it (Cork, Applite, Taphouse, BrewUI)

## Phase 1: make it installable by strangers (weeks 1–3)

- [x] First commit, private repo at `vs-cristian/caskroom`
- [x] README with the hook, features, privacy and build steps
- [ ] **(you)** Real screenshots and a short screen recording for the README: Discover, Updates, a package page, Services. The app's own snapshot captures don't render glass or the sidebar, so these have to be taken on screen.
- [ ] **(you)** Apple Developer account ($99 a year) for a Developer ID certificate. The app is ad-hoc signed today, so Gatekeeper blocks it on anyone else's Mac.
- [ ] Sign with Developer ID and notarise in `make app`
- [ ] Release script: zip the app, publish a GitHub Release
- [ ] Own tap (`vs-cristian/homebrew-tap`) so `brew install --cask vs-cristian/tap/caskroom` works and updates arrive through brew
- [ ] Test on a clean Mac: no Homebrew, then a fresh Homebrew
- [ ] One-page site: hook, screenshots, install command
- [ ] Commit email: decide whether the address in git history should be public before the repo is

## Phase 2: soft launch (week 4)

- [ ] **(you)** Make the repo public
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
