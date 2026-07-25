APP := build/Wysi.app
CONFIG ?= debug

.PHONY: app run test spike dmg clean

app:
	swift build -c $(CONFIG)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/$(CONFIG)/Wysi $(APP)/Contents/MacOS/Wysi
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp -R Editor $(APP)/Contents/Resources/Editor
	codesign --force --sign - $(APP)

dmg:
	$(MAKE) app CONFIG=release
	rm -rf build/dmg build/WYSI.dmg
	mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname WYSI -srcfolder build/dmg -ov -format UDZO build/WYSI.dmg
	rm -rf build/dmg

run: app
	open $(APP)

test:
	swift test

spike:
	spike/run.sh

clean:
	rm -rf .build build
