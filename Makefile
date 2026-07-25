APP := build/Wysi.app

.PHONY: app run test spike clean

app:
	swift build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/debug/Wysi $(APP)/Contents/MacOS/Wysi
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp -R Editor $(APP)/Contents/Resources/Editor
	codesign --force --sign - $(APP)

run: app
	open $(APP)

test:
	swift test

spike:
	spike/run.sh

clean:
	rm -rf .build build
