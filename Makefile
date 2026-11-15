APP = build/Caskroom.app
# Ad-hoc unless Support/release.sh passes a Developer ID identity. Notarisation
# then needs the hardened runtime and a timestamp, and under the hardened
# runtime brew's osascript needs the Apple Events entitlement on Caskroom.
SIGN ?= -
ifneq ($(SIGN),-)
HARDENED = --options runtime --timestamp
ENTITLED = --entitlements Support/Caskroom.entitlements
endif

.PHONY: release app run clean screenshots
release:
	swift build -c release --arch arm64

app: release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	cp .build/release/CaskroomApp $(APP)/Contents/MacOS/Caskroom
	cp .build/release/CaskroomAskpass $(APP)/Contents/Helpers/CaskroomAskpass
	cp Support/Info.plist $(APP)/Contents/Info.plist
ifdef VERSION
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION)" $(APP)/Contents/Info.plist
endif
	xcrun actool $(CURDIR)/Support/AppIcon.icon --compile $(CURDIR)/$(APP)/Contents/Resources \
		--platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
		--output-partial-info-plist $(CURDIR)/.build/AppIcon.plist --errors >/dev/null
	codesign --force $(HARDENED) -s "$(SIGN)" $(APP)/Contents/Helpers/CaskroomAskpass
	codesign --force $(HARDENED) $(ENTITLED) -s "$(SIGN)" $(APP)
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build build

# The site's screenshots (docs/assets), light and dark: the real window, captured
# by the window server, so whatever runs make needs Screen Recording permission.
# Kept at the capture's 2x size for Retina screens; AVIF (quality 90) makes that
# about 100 KB a page, where PNG would be close to 1 MB.
# scene:name pairs; the scene names are SnapshotDriver's.
SHOTS = 1-discover:discover 18-updates-tags:updates 7-app:package 4-services:services
screenshots:
	swift build
	rm -rf .build/screenshots
	for look in light dark; do \
		CASKROOM_SNAPSHOT_SCREEN=1 CASKROOM_APPEARANCE=$$look \
		CASKROOM_SNAPSHOT_ONLY=$$(echo $(SHOTS) | tr ' ' '\n' | cut -d: -f1 | paste -sd, -) \
		CASKROOM_SNAPSHOT_DIR=$(CURDIR)/.build/screenshots/$$look .build/debug/CaskroomApp 2>/dev/null; \
	done
	@for pair in $(SHOTS); do scene=$${pair%%:*}; name=$${pair##*:}; \
		for look in light dark; do suffix=$$([ $$look = dark ] && echo -dark); \
			shot=.build/screenshots/$$look/$$scene.png; \
			[ -s $$shot ] || { echo "no $$shot: does this terminal have Screen Recording permission?"; exit 1; }; \
			sips -s format avif -s formatOptions 90 $$shot --out docs/assets/$$name$$suffix.avif >/dev/null; \
			echo "docs/assets/$$name$$suffix.avif"; \
		done; \
	done
