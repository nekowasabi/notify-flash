APP       := NotifyFlash.app
BUNDLE_ID := com.notifyflash.app

notify-flash: $(wildcard *.swift)
	swiftc -O *.swift -o $@

# Why: アドホック署名は再ビルドで cdhash が変わり既存の AX 許可が無効になる。古い許可を残さないよう再ビルド時だけリセットする。
$(APP): notify-flash Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS
	cp Info.plist $@/Contents/Info.plist
	cp notify-flash $@/Contents/MacOS/notify-flash
	codesign --force --sign - --identifier $(BUNDLE_ID) $@
	tccutil reset Accessibility $(BUNDLE_ID) || true

app: $(APP)

clean:
	rm -rf notify-flash $(APP)

.PHONY: app clean
