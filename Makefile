SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

APPLICATION_SIGN_IDENTITY ?= Developer ID Application
INSTALLER_SIGN_IDENTITY ?= Developer ID Installer
DEUS_EXPORT_OPTIONS ?= Configuration/Export.local.plist
XCODEBUILD_FLAGS ?= -skipPackagePluginValidation
export DISABLE_SWIFTLINT := 1

build_all: build_ios build_macos build_tvos

build_ios_deb:
	bash Jailbreak/package.sh

build_ios:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme SFI -configuration Debug -destination 'generic/platform=iOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_macos:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme SFM -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_macos_standalone:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme "Deus Airlock" -xcconfig Configuration/Airlock.xcconfig -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_tvos:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme SFT -configuration Debug -destination 'generic/platform=tvOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

release: release_ios release_macos release_tvos

release_ios: archive_ios upload_ios

archive_ios:
	rm -rf build/SFI.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFI -configuration Release -destination 'generic/platform=iOS' -archivePath build/SFI.xcarchive | xcbeautify

upload_ios:
	xcodebuild -exportArchive -archivePath build/SFI.xcarchive -exportOptionsPlist SFI/Upload.plist

release_macos: archive_macos upload_macos

archive_macos:
	rm -rf build/SFM.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFM -configuration Release -archivePath build/SFM.xcarchive | xcbeautify

upload_macos:
	xcodebuild -exportArchive -archivePath build/SFM.xcarchive -exportOptionsPlist SFI/Upload.plist

release_tvos: archive_tvos upload_tvos

archive_tvos:
	rm -rf build/SFT.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFT -configuration Release -archivePath build/SFT.xcarchive | xcbeautify

upload_tvos:
	xcodebuild -exportArchive -archivePath build/SFT.xcarchive -exportOptionsPlist SFI/Upload.plist

release_macos_standalone: release_macos_dmg release_macos_pkg

# Archive commands
archive_macos_standalone_apple:
	rm -rf build/Airlock-arm64.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme "Deus Airlock" -xcconfig Configuration/Airlock.xcconfig -configuration Release -archivePath build/Airlock-arm64.xcarchive -derivedDataPath build/Airlock-arm64.dd ARCHS=arm64 | xcbeautify

archive_macos_standalone_intel:
	rm -rf build/Airlock-x86_64.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme "Deus Airlock" -xcconfig Configuration/Airlock.xcconfig -configuration Release -archivePath build/Airlock-x86_64.xcarchive -derivedDataPath build/Airlock-x86_64.dd ARCHS=x86_64 | xcbeautify

archive_macos_standalone_universal:
	rm -rf build/Airlock-universal.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme "Deus Airlock" -xcconfig Configuration/Airlock.xcconfig -configuration Release -archivePath build/Airlock-universal.xcarchive -derivedDataPath build/Airlock-universal.dd | xcbeautify

archive_macos_standalone: archive_macos_standalone_apple archive_macos_standalone_intel archive_macos_standalone_universal

# Export commands
export_macos_standalone_apple:
	rm -rf build/Airlock-arm64
	xcodebuild -exportArchive -archivePath build/Airlock-arm64.xcarchive -exportOptionsPlist "$(DEUS_EXPORT_OPTIONS)" -exportPath build/Airlock-arm64
	bash Tools/bundle-airlock-cli.sh verify "build/Airlock-arm64/Deus Airlock.app/Contents/Resources/AirlockCLI"

export_macos_standalone_intel:
	rm -rf build/Airlock-x86_64
	xcodebuild -exportArchive -archivePath build/Airlock-x86_64.xcarchive -exportOptionsPlist "$(DEUS_EXPORT_OPTIONS)" -exportPath build/Airlock-x86_64
	bash Tools/bundle-airlock-cli.sh verify "build/Airlock-x86_64/Deus Airlock.app/Contents/Resources/AirlockCLI"

export_macos_standalone_universal:
	rm -rf build/Airlock-universal
	xcodebuild -exportArchive -archivePath build/Airlock-universal.xcarchive -exportOptionsPlist "$(DEUS_EXPORT_OPTIONS)" -exportPath build/Airlock-universal
	bash Tools/bundle-airlock-cli.sh verify "build/Airlock-universal/Deus Airlock.app/Contents/Resources/AirlockCLI"

# DMG commands
build_macos_dmg_apple: archive_macos_standalone_apple export_macos_standalone_apple
	rm -f build/Deus-Airlock-Apple.dmg
	create-dmg \
		--volname "Deus Airlock" \
		--volicon "build/Airlock-arm64/Deus Airlock.app/Contents/Resources/AppIcon.icns" \
		--icon "Deus Airlock.app" 0 0 \
		--hide-extension "Deus Airlock.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/Deus-Airlock-Apple.dmg" "build/Airlock-arm64/Deus Airlock.app"

build_macos_dmg_intel: archive_macos_standalone_intel export_macos_standalone_intel
	rm -f build/Deus-Airlock-Intel.dmg
	create-dmg \
		--volname "Deus Airlock" \
		--volicon "build/Airlock-x86_64/Deus Airlock.app/Contents/Resources/AppIcon.icns" \
		--icon "Deus Airlock.app" 0 0 \
		--hide-extension "Deus Airlock.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/Deus-Airlock-Intel.dmg" "build/Airlock-x86_64/Deus Airlock.app"

build_macos_dmg_universal: archive_macos_standalone_universal export_macos_standalone_universal
	rm -f build/Deus-Airlock-Universal.dmg
	create-dmg \
		--volname "Deus Airlock" \
		--volicon "build/Airlock-universal/Deus Airlock.app/Contents/Resources/AppIcon.icns" \
		--icon "Deus Airlock.app" 0 0 \
		--hide-extension "Deus Airlock.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/Deus-Airlock-Universal.dmg" "build/Airlock-universal/Deus Airlock.app"

build_macos_dmg: build_macos_dmg_apple build_macos_dmg_intel build_macos_dmg_universal

# DMG notarize commands
notarize_macos_dmg_apple:
	xcrun notarytool submit "build/Deus-Airlock-Apple.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/Deus-Airlock-Apple.dmg"

notarize_macos_dmg_intel:
	xcrun notarytool submit "build/Deus-Airlock-Intel.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/Deus-Airlock-Intel.dmg"

notarize_macos_dmg_universal:
	xcrun notarytool submit "build/Deus-Airlock-Universal.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/Deus-Airlock-Universal.dmg"

notarize_macos_dmg: notarize_macos_dmg_apple notarize_macos_dmg_intel notarize_macos_dmg_universal

# DMG release commands
release_macos_dmg_apple: build_macos_dmg_apple notarize_macos_dmg_apple
release_macos_dmg_intel: build_macos_dmg_intel notarize_macos_dmg_intel
release_macos_dmg_universal: build_macos_dmg_universal notarize_macos_dmg_universal
release_macos_dmg: release_macos_dmg_apple release_macos_dmg_intel release_macos_dmg_universal

# PKG commands
build_macos_pkg_apple: archive_macos_standalone_apple export_macos_standalone_apple
	rm -f build/Deus-Airlock-Apple.pkg
	rm -rf build/pkgroot-arm64
	mkdir -p build/pkgroot-arm64
	ditto "build/Airlock-arm64/Deus Airlock.app" "build/pkgroot-arm64/Deus Airlock.app"
	bash Tools/build-airlock-component.sh "build/pkgroot-arm64" build/component-arm64.pkg
	productbuild --distribution SFM.System/distribution-arm64.xml \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/Deus-Airlock-Apple.pkg
	rm -rf build/pkgroot-arm64
	rm -f build/component-arm64.pkg

build_macos_pkg_intel: archive_macos_standalone_intel export_macos_standalone_intel
	rm -f build/Deus-Airlock-Intel.pkg
	rm -rf build/pkgroot-x86_64
	mkdir -p build/pkgroot-x86_64
	ditto "build/Airlock-x86_64/Deus Airlock.app" "build/pkgroot-x86_64/Deus Airlock.app"
	bash Tools/build-airlock-component.sh "build/pkgroot-x86_64" build/component-x86_64.pkg
	productbuild --distribution SFM.System/distribution-x86_64.xml \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/Deus-Airlock-Intel.pkg
	rm -rf build/pkgroot-x86_64
	rm -f build/component-x86_64.pkg

build_macos_pkg_universal: archive_macos_standalone_universal export_macos_standalone_universal
	rm -f build/Deus-Airlock-Universal.pkg
	rm -rf build/pkgroot-universal
	mkdir -p build/pkgroot-universal
	ditto "build/Airlock-universal/Deus Airlock.app" "build/pkgroot-universal/Deus Airlock.app"
	bash Tools/build-airlock-component.sh "build/pkgroot-universal" build/component-universal.pkg
	productbuild --distribution SFM.System/distribution-universal.xml \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/Deus-Airlock-Universal.pkg
	rm -rf build/pkgroot-universal
	rm -f build/component-universal.pkg

build_macos_pkg: build_macos_pkg_apple build_macos_pkg_intel build_macos_pkg_universal

build_macos_pkg_all: archive_macos_standalone_universal export_macos_standalone_universal
	APPLICATION_SIGN_IDENTITY="$(APPLICATION_SIGN_IDENTITY)" INSTALLER_SIGN_IDENTITY="$(INSTALLER_SIGN_IDENTITY)" bash SFM.System/package_from_universal.sh

# PKG notarize commands
notarize_macos_pkg_apple:
	xcrun notarytool submit build/Deus-Airlock-Apple.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/Deus-Airlock-Apple.pkg

notarize_macos_pkg_intel:
	xcrun notarytool submit build/Deus-Airlock-Intel.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/Deus-Airlock-Intel.pkg

notarize_macos_pkg_universal:
	xcrun notarytool submit build/Deus-Airlock-Universal.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/Deus-Airlock-Universal.pkg

notarize_macos_pkg: notarize_macos_pkg_apple notarize_macos_pkg_intel notarize_macos_pkg_universal

notarize_macos_pkg_all:
	set -e; \
	xcrun notarytool submit build/Deus-Airlock-Apple.pkg --wait --keychain-profile "notarytool-password" & apple_pid=$$!; \
	xcrun notarytool submit build/Deus-Airlock-Intel.pkg --wait --keychain-profile "notarytool-password" & intel_pid=$$!; \
	xcrun notarytool submit build/Deus-Airlock-Universal.pkg --wait --keychain-profile "notarytool-password" & universal_pid=$$!; \
	wait $$apple_pid; wait $$intel_pid; wait $$universal_pid
	xcrun stapler staple build/Deus-Airlock-Apple.pkg
	xcrun stapler staple build/Deus-Airlock-Intel.pkg
	xcrun stapler staple build/Deus-Airlock-Universal.pkg

# PKG release commands
release_macos_pkg_apple: build_macos_pkg_apple notarize_macos_pkg_apple
release_macos_pkg_intel: build_macos_pkg_intel notarize_macos_pkg_intel
release_macos_pkg_universal: build_macos_pkg_universal notarize_macos_pkg_universal
release_macos_pkg: release_macos_pkg_apple release_macos_pkg_intel release_macos_pkg_universal

fmt:
	swiftformat .

fmt_install:
	brew install swiftformat

lint:
	swiftlint

lint_install:
	brew install swiftlint

dmg_install:
	brew install create-dmg

clean:
	rm -rf build/SFI.xcarchive
	rm -rf build/SFM.xcarchive
	rm -rf build/SFT.xcarchive
	rm -rf build/Airlock-arm64.xcarchive
	rm -rf build/Airlock-x86_64.xcarchive
	rm -rf build/Airlock-universal.xcarchive
	rm -rf build/Airlock-arm64
	rm -rf build/Airlock-x86_64
	rm -rf build/Airlock-universal
	rm -rf build/SFI.dd
	rm -rf build/SFM.dd
	rm -rf build/SFT.dd
	rm -rf build/Airlock-arm64.dd
	rm -rf build/Airlock-x86_64.dd
	rm -rf build/Airlock-universal.dd
	rm -f build/Deus-Airlock-Apple.dmg build/Deus-Airlock-Intel.dmg build/Deus-Airlock-Universal.dmg
	rm -f build/Deus-Airlock-Apple.pkg build/Deus-Airlock-Intel.pkg build/Deus-Airlock-Universal.pkg
