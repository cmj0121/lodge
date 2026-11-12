SUBDIR :=

PREFIX       ?= $(HOME)/Applications
BUILD_DIR    := build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
APP          := $(BUILD_DIR)/Lodge.app
XCODEBUILD   := xcodebuild -project Lodge.xcodeproj -scheme Lodge -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA)

.PHONY: all clean test uitest run build install upgrade help $(SUBDIR)

all: $(SUBDIR) 		# default action
	@[ -f .git/hooks/pre-commit ] || pre-commit install --install-hooks
	@git config commit.template .git-commit-template

clean: $(SUBDIR)	# clean-up environment
	@find . -name '*.sw[po]' -delete
	rm -rf $(BUILD_DIR) LodgeKit/.build

test:				# run LodgeKit unit tests, then build the app
	swift test --package-path LodgeKit
	$(MAKE) build

uitest:				# run the XCUITest smoke tests
	$(XCODEBUILD) test

run: build			# build and open the app
	open $(APP)

build:				# build the Release app into build/Lodge.app
	$(XCODEBUILD) -configuration Release build
	rm -rf $(APP)
	ditto $(DERIVED_DATA)/Build/Products/Release/Lodge.app $(APP)

install: build		# copy build/Lodge.app into $(PREFIX) (default ~/Applications)
	mkdir -p $(PREFIX)
	rm -rf $(PREFIX)/Lodge.app
	ditto $(APP) $(PREFIX)/Lodge.app

upgrade:			# upgrade all the necessary packages
	pre-commit autoupdate

help:				# show this message
	@printf "Usage: make [OPTION]\n"
	@printf "\n"
	@perl -nle 'print $$& if m{^[\w-]+:.*?#.*$$}' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?#"} {printf "    %-18s %s\n", $$1, $$2}'

$(SUBDIR):
	$(MAKE) -C $@ $(MAKECMDGOALS)
