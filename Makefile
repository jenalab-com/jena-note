APP_NAME    = JenaNote
VERSION     = 1.0.0
BUILD_DIR   = .build
BUNDLE      = $(BUILD_DIR)/$(APP_NAME).app
BINARY      = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
PKG         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).pkg
SOURCES     = $(shell find Sources -name "*.swift" | sort)

.PHONY: build run install pkg clean

## 개발용 빌드 + 실행
run: build
	@open $(BUNDLE)

## .app 번들 빌드
build: $(BINARY)

$(BINARY): $(SOURCES) Resources/Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	swiftc -framework AppKit -O $(SOURCES) -o $(BINARY)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@[ -f Resources/$(APP_NAME).icns ] && cp Resources/$(APP_NAME).icns $(BUNDLE)/Contents/Resources/$(APP_NAME).icns || true
	@echo "✓ 빌드 완료: $(BUNDLE)"

## ~/Applications 에 설치
install: build
	@rm -rf ~/Applications/$(APP_NAME).app
	@cp -r $(BUNDLE) ~/Applications/$(APP_NAME).app
	@echo "✓ 설치 완료: ~/Applications/$(APP_NAME).app"

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
