SUBDIR :=

PREFIX       ?= $(HOME)/Applications
BUILD_DIR    := build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
APP          := $(BUILD_DIR)/Lodge.app
XCODEBUILD   := xcodebuild -project Lodge.xcodeproj -scheme Lodge -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA)
IOS_SIM      ?= iPhone 17
IOS_DERIVED  := $(BUILD_DIR)/DerivedData-ios
IOS_APP      := $(IOS_DERIVED)/Build/Products/Debug-iphonesimulator/LodgeiOS.app
XCODEBUILD_IOS := xcodebuild -project Lodge.xcodeproj -scheme LodgeiOS -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(IOS_DERIVED)

PLATFORM     ?= macos
ARGS         ?=

.PHONY: all clean test uitest run build install publish perf upgrade help \
	build-macos build-ios run-macos run-ios preflight $(SUBDIR)

all: $(SUBDIR) 		# default action
	@[ -f .git/hooks/pre-commit ] || pre-commit install --install-hooks
	@git config commit.template .git-commit-template

clean: $(SUBDIR)	# clean-up environment
	@find . -name '*.sw[po]' -delete
	rm -rf $(BUILD_DIR) LodgeKit/.build

test:				# run LodgeKit unit tests, then Debug builds of the macOS and iPhone/iPad apps
	swift test --package-path LodgeKit
	$(XCODEBUILD) -configuration Debug build
	$(XCODEBUILD_IOS) -configuration Debug build

uitest:				# run the XCUITest smoke tests
	$(XCODEBUILD) test

build: build-macos build-ios	# build every platform: build/Lodge.app and the iPhone/iPad Simulator app

run:				# build and open the app (PLATFORM=macos, or ios for the Simulator; IOS_SIM picks the device)
	@case "$(PLATFORM)" in \
		macos|ios) $(MAKE) --no-print-directory run-$(PLATFORM) ;; \
		*) echo "run: PLATFORM must be macos or ios, not '$(PLATFORM)'" >&2; exit 1 ;; \
	esac

install: build-macos	# copy build/Lodge.app into $(PREFIX) (default ~/Applications)
	@[ -n "$(strip $(PREFIX))" ] || { echo "install: PREFIX must not be empty" >&2; exit 1; }
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/Lodge.app"
	ditto "$(APP)" "$(PREFIX)/Lodge.app"

publish: preflight test	# check .env and that HEAD is origin/main, run the tests, then ship iOS and macOS
	bundle exec fastlane ios publish
	bundle exec fastlane mac publish

perf:				# show CPU and memory of running Lodge and its WebKit helpers (ARGS="--once", "--pid N", "--interval S")
	swift run --package-path LodgeKit -c release lodge-perf $(ARGS)

build-macos:
	$(XCODEBUILD) -configuration Release build
	rm -rf $(APP)
	ditto $(DERIVED_DATA)/Build/Products/Release/Lodge.app $(APP)

build-ios:
	$(XCODEBUILD_IOS) -configuration Debug build

run-macos: build-macos
	open $(APP)

run-ios: build-ios
	xcrun simctl boot "$(IOS_SIM)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(IOS_SIM)" $(IOS_APP)
	xcrun simctl launch "$(IOS_SIM)" dev.lodge.Lodge

preflight:
	bundle exec fastlane preflight

upgrade:			# upgrade all the necessary packages
	pre-commit autoupdate

help:				# show this message
	@printf "Usage: make [OPTION]\n"
	@printf "\n"
	@perl -nle 'print $$& if m{^[\w-]+:.*?#.*$$}' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?#"} {printf "    %-18s %s\n", $$1, $$2}'

$(SUBDIR):
	$(MAKE) -C $@ $(MAKECMDGOALS)
