APP_NAME    = JenaNote
VERSION     = 1.3.0
BUILD_DIR   = .build
BUNDLE      = $(BUILD_DIR)/$(APP_NAME).app
BINARY      = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
DMG         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg
PKG         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).pkg

.PHONY: build run install dmg pkg clean test

run: build
	@open $(BUNDLE)

build:
	swift build -c release --product $(APP_NAME)
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp .build/release/$(APP_NAME) $(BINARY)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@[ -f Resources/$(APP_NAME).icns ] && cp Resources/$(APP_NAME).icns $(BUNDLE)/Contents/Resources/$(APP_NAME).icns || true
	@echo "✓ 빌드 완료: $(BUNDLE)"

test:
	swift test

## ~/Applications 에 설치
install: build
	@rm -rf ~/Applications/$(APP_NAME).app
	@cp -r $(BUNDLE) ~/Applications/$(APP_NAME).app
	@echo "✓ 설치 완료: ~/Applications/$(APP_NAME).app"

## .dmg 배포용 디스크 이미지 생성
dmg: build
	@rm -rf /tmp/dmg-staging-$(APP_NAME)
	@mkdir -p /tmp/dmg-staging-$(APP_NAME)
	@cp -r $(BUNDLE) /tmp/dmg-staging-$(APP_NAME)/
	@ln -s /Applications /tmp/dmg-staging-$(APP_NAME)/Applications
	@chflags nohidden /tmp/dmg-staging-$(APP_NAME)/$(APP_NAME).app
	@xattr -cr /tmp/dmg-staging-$(APP_NAME)/$(APP_NAME).app
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder /tmp/dmg-staging-$(APP_NAME) \
		-ov -format UDZO $(DMG)
	@rm -rf /tmp/dmg-staging-$(APP_NAME)
	@echo "✓ DMG 생성: $(DMG)"

## .pkg 인스톨러 생성
pkg: build
	pkgbuild \
		--install-location /Applications \
		--component $(BUNDLE) \
		--identifier com.jenalab.jenanote \
		--version $(VERSION) \
		$(PKG)
	@echo "✓ 패키지 생성: $(PKG)"

## 빌드 산출물 삭제
clean:
	@rm -rf $(BUILD_DIR)
	@echo "✓ 정리 완료"
