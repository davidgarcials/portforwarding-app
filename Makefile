.PHONY: build test run clean bundle

APP_NAME = PortForwarding
BUNDLE_DIR = build/$(APP_NAME).app
CONTENTS_DIR = $(BUNDLE_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

build:
	swift build --configuration release

test:
	swift run TestRunner

bundle: build
	mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	cp .build/release/PortForwardingApp $(MACOS_DIR)/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS_DIR)/Info.plist
	cp Resources/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	cp Resources/menubar-icon.png $(RESOURCES_DIR)/menubar-icon.png
	cp Resources/menubar-icon@2x.png $(RESOURCES_DIR)/menubar-icon@2x.png
	@echo "Built $(BUNDLE_DIR)"

run: bundle
	open $(BUNDLE_DIR)

clean:
	swift package clean
	rm -rf build
