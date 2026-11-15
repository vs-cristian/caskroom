APP = build/Caskroom.app

.PHONY: release app run clean
release:
	swift build -c release --arch arm64

app: release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	cp .build/release/CaskroomApp $(APP)/Contents/MacOS/Caskroom
	cp .build/release/CaskroomAskpass $(APP)/Contents/Helpers/CaskroomAskpass
	cp Support/Info.plist $(APP)/Contents/Info.plist
	xcrun actool $(CURDIR)/Support/AppIcon.icon --compile $(CURDIR)/$(APP)/Contents/Resources \
		--platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
		--output-partial-info-plist $(CURDIR)/.build/AppIcon.plist --errors >/dev/null
	codesign --force -s - $(APP)/Contents/Helpers/CaskroomAskpass
	codesign --force -s - $(APP)
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build build
