APP = build/Caskroom.app
# Ad-hoc unless Support/release.sh passes a Developer ID identity. Notarisation
# then needs the hardened runtime and a timestamp, and under the hardened
# runtime brew's osascript needs the Apple Events entitlement on Caskroom.
SIGN ?= -
ifneq ($(SIGN),-)
HARDENED = --options runtime --timestamp
ENTITLED = --entitlements Support/Caskroom.entitlements
endif

.PHONY: release app run clean
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
