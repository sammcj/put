SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:

BUNDLE_ID := net.smcleod.put
APP_NAME := Put
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := .build
CONFIG ?= release
BIN_DIR := $(BUILD_DIR)/$(CONFIG)
BINARY := $(BIN_DIR)/$(APP_NAME)
VERSION := $(shell cat VERSION | tr -d '[:space:]')
BUILD_NUMBER := $(shell date -u +%Y%m%d%H%M)
YEAR := $(shell date +%Y)

ADHOC_IDENTIFIER ?= $(BUNDLE_ID).adhoc

# Dev signing identity: stored in macOS Keychain (service: put-release,
# account: dev-signing-identity). Typically an "Apple Development" cert so
# Accessibility (TCC) trust persists across rebuilds. Populate once with
# `make setup-dev-signing`. APPLE_SIGNING_IDENTITY env var still overrides.
DEV_SIGNING_IDENTITY := $(shell security find-generic-password -s put-release -a dev-signing-identity -w 2>/dev/null)

# Signing cascade: APPLE_SIGNING_IDENTITY env > keychain dev identity > ad-hoc.
CODESIGN_IDENTITY ?= $(if $(APPLE_SIGNING_IDENTITY),$(APPLE_SIGNING_IDENTITY),$(if $(DEV_SIGNING_IDENTITY),$(DEV_SIGNING_IDENTITY),-))

# Release credentials: Keychain-first, service `put-release`. Populate with
# `make setup-release-keychain`.
# CI fallback: if the Keychain entries are empty (e.g. GitHub Actions),
# fall back to the matching APPLE_* env vars.
RELEASE_SIGNING_IDENTITY := $(shell security find-generic-password -s put-release -a signing-identity -w 2>/dev/null)
ifeq ($(strip $(RELEASE_SIGNING_IDENTITY)),)
RELEASE_SIGNING_IDENTITY := $(APPLE_SIGNING_IDENTITY)
endif

RELEASE_API_ISSUER       := $(shell security find-generic-password -s put-release -a api-issuer -w 2>/dev/null)
ifeq ($(strip $(RELEASE_API_ISSUER)),)
RELEASE_API_ISSUER := $(APPLE_API_ISSUER)
endif

RELEASE_API_KEY          := $(shell security find-generic-password -s put-release -a api-key -w 2>/dev/null)
ifeq ($(strip $(RELEASE_API_KEY)),)
RELEASE_API_KEY := $(APPLE_API_KEY)
endif

RELEASE_API_KEY_PATH     := $(shell security find-generic-password -s put-release -a api-key-path -w 2>/dev/null)
ifeq ($(strip $(RELEASE_API_KEY_PATH)),)
RELEASE_API_KEY_PATH := $(APPLE_API_KEY_PATH)
endif

.DEFAULT_GOAL := bundle

.PHONY: help
help:
	@printf 'Targets:\n'
	@printf '  build                   swift build -c $(CONFIG)\n'
	@printf '  bundle                  assemble $(APP_BUNDLE) (default)\n'
	@printf '  sign                    codesign the bundle (uses APPLE_SIGNING_IDENTITY or ad-hoc)\n'
	@printf '  run                     launch the signed bundle\n'
	@printf '  install                 install the signed bundle to /Applications/$(APP_BUNDLE)\n'
	@printf '  test                    hermetic unit tests\n'
	@printf '  test-ax                 integration tests (PUT_RUN_AX_TESTS=1)\n'
	@printf '  lint                    swiftlint + swiftformat\n'
	@printf '  format                  swiftformat in-place\n'
	@printf '  icon                    build AppIcon.icns from Resources/AppIcon.svg (if present)\n'
	@printf '  setup-signing           show available codesign identities + configured creds\n'
	@printf '  setup-dev-signing       store Apple Development identity in Keychain (one-time)\n'
	@printf '  setup-release-keychain  store Developer ID + notarisation creds in macOS Keychain\n'
	@printf '  notarise                Developer ID sign, notarise, staple (reads Keychain or env)\n'
	@printf '  release                 bump patch + notarise + DMG + commit and tag (NO_BUMP=1, NO_TAG=1 to skip either)\n'
	@printf '  verify                  codesign / spctl / stapler checks on built .app and .dmg\n'
	@printf '  github-secrets          print GitHub Actions secrets from Keychain (sensitive)\n'
	@printf '  stamp-version           freeze CHANGELOG [Unreleased] using current VERSION\n'
	@printf '  version                 bump VERSION and freeze CHANGELOG (V=X.Y.Z required)\n'
	@printf '  bump-patch              increment patch in VERSION + freeze CHANGELOG (0.1.0 -> 0.1.1)\n'
	@printf '  clean                   remove $(BUILD_DIR) and $(APP_BUNDLE)\n'

.PHONY: build
build:
	swift build -c $(CONFIG)

.PHONY: bundle
bundle: build icon $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) sign

# VERSION is a prerequisite because the recipe bakes it into Info.plist. Without
# it, bumping the version alone leaves every prerequisite older than the target,
# so make skips the recipe and the bundle keeps the previous
# CFBundleShortVersionString while the DMG filename carries the new one.
$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME): $(BINARY) Resources/Info.plist.tmpl Resources/Put.entitlements THIRD-PARTY-NOTICES.md VERSION
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BINARY) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@# MIT requires its notice ship with the binary, not only in the repo.
	cp THIRD-PARTY-NOTICES.md $(APP_BUNDLE)/Contents/Resources/THIRD-PARTY-NOTICES.md
	sed -e 's/__VERSION__/$(VERSION)/g' \
	    -e 's/__BUILD__/$(BUILD_NUMBER)/g' \
	    -e 's/__YEAR__/$(YEAR)/g' \
	    Resources/Info.plist.tmpl > $(APP_BUNDLE)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then \
		cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns; \
	else \
		echo "warning: no AppIcon.icns; generic icon will appear in Finder and System Settings"; \
	fi
	touch $@

.PHONY: sign
sign: $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "WARNING: Signing ad-hoc. Accessibility trust will be revoked on every rebuild."; \
		echo "         Export APPLE_SIGNING_IDENTITY=\"Apple Development: you@example.com (TEAMID)\""; \
		echo "         in your shell profile to make TCC persist. See 'make setup-signing'."; \
	else \
		echo "Signing with: $(CODESIGN_IDENTITY)"; \
	fi
	codesign --force \
		--sign "$(CODESIGN_IDENTITY)" \
		--identifier "$(BUNDLE_ID)" \
		--entitlements Resources/Put.entitlements \
		--options runtime \
		--timestamp=none \
		$(APP_BUNDLE)
	codesign --verify --verbose=2 $(APP_BUNDLE)
	@# Only run Gatekeeper assessment for Developer ID signatures. Ad-hoc and
	@# Apple Development signed bundles are rejected by design (not distributable),
	@# so running spctl on them produces noisy false-negative output.
	@case "$(CODESIGN_IDENTITY)" in \
		*"Developer ID"*) spctl --assess --verbose=2 $(APP_BUNDLE) || true;; \
		*) ;; \
	esac

.PHONY: run
run: bundle
	@pkill -x Put >/dev/null 2>&1 && sleep 0.3 || true
	open -a "$(PWD)/$(APP_BUNDLE)"

# Install the signed release bundle to /Applications. Kills any running Put
# first so the replace succeeds (a running binary can't be deleted on macOS
# if the volume is mounted noatime / sealed). Uses ditto to preserve signature
# metadata and extended attributes that `cp -R` strips on some filesystems.
.PHONY: install
install: bundle
	@if [ ! -d "$(APP_BUNDLE)" ]; then \
		echo "ERROR: $(APP_BUNDLE) not found after build"; exit 1; \
	fi
	@if [ ! -w /Applications ]; then \
		echo "ERROR: /Applications is not writable by this user."; \
		echo "  Run with sudo: sudo make install"; \
		exit 1; \
	fi
	@# Single shell so $$was_running survives across the pgrep → pkill → open
	@# sequence. Previously this relied on .ONESHELL to share state across
	@# separate @-lines, which silently dropped the variable on some Make
	@# configurations and skipped the relaunch.
	@was_running=0; \
	if pgrep -x $(APP_NAME) >/dev/null 2>&1; then was_running=1; fi; \
	pkill -x $(APP_NAME) >/dev/null 2>&1 && sleep 0.3 || true; \
	if [ -d "/Applications/$(APP_BUNDLE)" ]; then \
		echo "Removing existing /Applications/$(APP_BUNDLE)"; \
		rm -rf "/Applications/$(APP_BUNDLE)"; \
	fi; \
	echo "Installing $(APP_BUNDLE) to /Applications"; \
	ditto "$(APP_BUNDLE)" "/Applications/$(APP_BUNDLE)"; \
	if [ "$$was_running" = 1 ]; then \
		echo "Relaunching $(APP_NAME)"; \
		open "/Applications/$(APP_BUNDLE)"; \
	else \
		echo "Installed. Launch with: open -a $(APP_NAME)"; \
	fi

.PHONY: test
test:
	swift test -c debug

.PHONY: test-ax
test-ax:
	PUT_RUN_AX_TESTS=1 swift test -c debug --filter IntegrationTests

.PHONY: lint
lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --quiet; \
	else \
		echo "swiftlint not installed (brew install swiftlint)" && exit 1; \
	fi
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat Sources Tests Package.swift --lint; \
	else \
		echo "swiftformat not installed (brew install swiftformat)" && exit 1; \
	fi

.PHONY: format
format:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat Sources Tests Package.swift; \
	else \
		echo "swiftformat not installed" && exit 1; \
	fi

.PHONY: icon
icon: Resources/AppIcon.icns

Resources/AppIcon.icns: Resources/AppIcon.svg
	@if ! command -v rsvg-convert >/dev/null 2>&1; then \
		echo "warning: rsvg-convert not installed (brew install librsvg); skipping icon generation"; \
		exit 0; \
	fi
	@if ! command -v iconutil >/dev/null 2>&1; then \
		echo "warning: iconutil not available; skipping icon generation"; \
		exit 0; \
	fi
	@rm -rf .build/AppIcon.iconset
	@mkdir -p .build/AppIcon.iconset
	rsvg-convert -w 16   Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_16x16.png
	rsvg-convert -w 32   Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_16x16@2x.png
	rsvg-convert -w 32   Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_32x32.png
	rsvg-convert -w 64   Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_32x32@2x.png
	rsvg-convert -w 128  Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_128x128.png
	rsvg-convert -w 256  Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_128x128@2x.png
	rsvg-convert -w 256  Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_256x256.png
	rsvg-convert -w 512  Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_256x256@2x.png
	rsvg-convert -w 512  Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_512x512.png
	rsvg-convert -w 1024 Resources/AppIcon.svg -o .build/AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns

.PHONY: setup-signing
setup-signing:
	@echo "Checking code signing setup..."
	@echo ""
	@echo "Available codesigning identities:"
	@security find-identity -v -p codesigning
	@echo ""
	@echo "--- Dev builds (make / make bundle) ---"
	@echo "Resolved dev identity: $(CODESIGN_IDENTITY)"
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "  WARNING: ad-hoc. Accessibility trust is invalidated on every rebuild."; \
		echo "  Run 'make setup-dev-signing' to store an Apple Development identity in Keychain."; \
	else \
		if security find-identity -v -p codesigning | grep -q "$(CODESIGN_IDENTITY)"; then \
			echo "  OK: identity found in keychain. TCC trust persists across rebuilds."; \
		else \
			echo "  WARNING: identity NOT found in keychain. Sign will fail."; \
		fi; \
		if [ -n "$${APPLE_SIGNING_IDENTITY:-}" ]; then \
			echo "  Source: APPLE_SIGNING_IDENTITY env var"; \
		elif [ -n "$(DEV_SIGNING_IDENTITY)" ]; then \
			echo "  Source: Keychain (put-release/dev-signing-identity)"; \
		fi; \
	fi
	@echo ""
	@echo "--- Release builds (make notarise) ---"
	@if [ -z "$(RELEASE_SIGNING_IDENTITY)" ]; then \
		echo "Keychain signing identity: NOT FOUND (service: put-release)"; \
		echo "  Run 'make setup-release-keychain' to store credentials."; \
	else \
		echo "Keychain signing identity: $(RELEASE_SIGNING_IDENTITY)"; \
		if security find-identity -v -p codesigning | grep -q "$(RELEASE_SIGNING_IDENTITY)"; then \
			case "$(RELEASE_SIGNING_IDENTITY)" in \
				*"Developer ID"*) echo "  OK: Developer ID certificate, valid for release distribution.";; \
				*) echo "  WARNING: Not a Developer ID certificate. 'make notarise' will fail.";; \
			esac; \
		else \
			echo "  WARNING: Certificate not installed in system keychain."; \
		fi; \
	fi
	@if [ -z "$(RELEASE_API_ISSUER)" ] || [ -z "$(RELEASE_API_KEY)" ] || [ -z "$(RELEASE_API_KEY_PATH)" ]; then \
		echo "Notarisation credentials: NOT FOUND in Keychain"; \
	else \
		echo "Notarisation credentials: OK"; \
		if [ -f "$(RELEASE_API_KEY_PATH)" ]; then \
			echo "  API key file: $(RELEASE_API_KEY_PATH)"; \
		else \
			echo "  WARNING: API key file not found at $(RELEASE_API_KEY_PATH)"; \
		fi; \
	fi

.PHONY: setup-dev-signing
setup-dev-signing:
	@echo "Store Apple Development signing identity in macOS Keychain"
	@echo "Service: put-release, account: dev-signing-identity"
	@echo ""
	@echo "This makes dev builds sign with a stable identity so Accessibility"
	@echo "(TCC) trust persists across rebuilds. Run once per machine."
	@echo ""
	@echo "Available codesigning identities:"
	@security find-identity -v -p codesigning | sed 's/^/  /'
	@echo ""
	@read -p "Pick a number from the list above, or paste a full identity string: " choice; \
	 if [ -z "$$choice" ]; then echo "Nothing entered. Aborting."; exit 1; fi; \
	 if echo "$$choice" | grep -qE '^[0-9]+$$'; then \
	   identity=$$(security find-identity -v -p codesigning | awk -v n="$$choice" '$$1 == n")" { \
	     for (i=3; i<=NF; i++) printf "%s%s", (i==3?"":" "), $$i; print "" \
	   }' | sed 's/^"//; s/"$$//'); \
	   if [ -z "$$identity" ]; then echo "No identity at index $$choice. Aborting."; exit 1; fi; \
	   echo "Selected: $$identity"; \
	 else \
	   identity="$$choice"; \
	 fi; \
	 case "$$identity" in \
	   *"Apple Development:"*) ;; \
	   *"Developer ID Application:"*) \
	     echo "WARNING: '$$identity' is a Developer ID cert, not Apple Development."; \
	     echo "         Dev builds will work but release identity is usually a separate cert."; \
	     read -p "Continue anyway? [y/N] " confirm; \
	     case "$$confirm" in y|Y|yes) ;; *) echo "Aborted."; exit 1;; esac;; \
	   *) echo "WARNING: '$$identity' doesn't look like an Apple-issued cert."; \
	      read -p "Continue anyway? [y/N] " confirm; \
	      case "$$confirm" in y|Y|yes) ;; *) echo "Aborted."; exit 1;; esac;; \
	 esac; \
	 security delete-generic-password -s put-release -a dev-signing-identity 2>/dev/null || true; \
	 security add-generic-password -s put-release -a dev-signing-identity -w "$$identity"
	@echo ""
	@echo "Stored. Future 'make bundle' runs will sign with this identity."
	@echo "Reset existing TCC trust once with:"
	@echo "  tccutil reset Accessibility $(BUNDLE_ID)"
	@echo "Then rebuild, grant Accessibility, and trust will persist across rebuilds."

.PHONY: setup-release-keychain
setup-release-keychain:
	@test -t 0 || { echo "setup-release-keychain needs an interactive terminal."; \
	  echo "stdin is not a tty, so read would take EOF and store empty credentials."; \
	  exit 1; }
	@echo "Store Apple release credentials in macOS Keychain"
	@echo "Service: put-release"
	@echo ""
	@echo "Existing values will be updated if already present. Press Enter to accept"
	@echo "detected defaults (shown in [brackets])."
	@echo ""
	@default_identity=$$(security find-generic-password -s put-release -a signing-identity -w 2>/dev/null); \
	 if [ -n "$$default_identity" ]; then \
	   read -p "Developer ID Application signing identity [$$default_identity]: " identity; \
	   identity=$${identity:-$$default_identity}; \
	 else \
	   read -p "Developer ID Application signing identity: " identity; \
	 fi; \
	 [ -n "$$identity" ] || { echo "Empty value; nothing changed."; exit 1; }; \
	 security delete-generic-password -s put-release -a signing-identity 2>/dev/null || true; \
	 security add-generic-password -s put-release -a signing-identity -w "$$identity"
	@default_issuer=$$(security find-generic-password -s put-release -a api-issuer -w 2>/dev/null); \
	 if [ -n "$$default_issuer" ]; then \
	   read -p "App Store Connect API Issuer ID [$$default_issuer]: " issuer; \
	   issuer=$${issuer:-$$default_issuer}; \
	 else \
	   read -p "App Store Connect API Issuer ID: " issuer; \
	 fi; \
	 [ -n "$$issuer" ] || { echo "Empty value; nothing changed."; exit 1; }; \
	 security delete-generic-password -s put-release -a api-issuer 2>/dev/null || true; \
	 security add-generic-password -s put-release -a api-issuer -w "$$issuer"
	@default_key=$$(security find-generic-password -s put-release -a api-key -w 2>/dev/null); \
	 if [ -n "$$default_key" ]; then \
	   read -p "App Store Connect API Key ID [$$default_key]: " key; \
	   key=$${key:-$$default_key}; \
	 else \
	   read -p "App Store Connect API Key ID: " key; \
	 fi; \
	 [ -n "$$key" ] || { echo "Empty value; nothing changed."; exit 1; }; \
	 security delete-generic-password -s put-release -a api-key 2>/dev/null || true; \
	 security add-generic-password -s put-release -a api-key -w "$$key"
	@default_path=$$(security find-generic-password -s put-release -a api-key-path -w 2>/dev/null); \
	 if [ -n "$$default_path" ]; then \
	   read -p "Path to .p8 key file [$$default_path]: " keypath; \
	   keypath=$${keypath:-$$default_path}; \
	 else \
	   read -p "Path to .p8 key file: " keypath; \
	 fi; \
	 [ -n "$$keypath" ] || { echo "Empty value; nothing changed."; exit 1; }; \
	 security delete-generic-password -s put-release -a api-key-path 2>/dev/null || true; \
	 security add-generic-password -s put-release -a api-key-path -w "$$keypath"
	@echo ""
	@echo "Credentials stored. Run 'make notarise' to build a signed + notarised release."

.PHONY: notarise
notarise: bundle
	@# Resolve identity: prefer Keychain (put-release service), fall back to env var.
	@IDENTITY="$(RELEASE_SIGNING_IDENTITY)"; \
	if [ -z "$$IDENTITY" ]; then IDENTITY="$${DEVELOPER_ID_APPLICATION:-}"; fi; \
	if [ -z "$$IDENTITY" ]; then \
		echo "ERROR: No Developer ID signing identity configured."; \
		echo "  Run 'make setup-release-keychain' or export DEVELOPER_ID_APPLICATION."; \
		exit 1; \
	fi; \
	case "$$IDENTITY" in \
		*"Developer ID Application"*) ;; \
		*) echo "ERROR: '$$IDENTITY' is not a Developer ID Application cert."; exit 1;; \
	esac; \
	echo "Signing: $$IDENTITY"; \
	codesign --force \
		--sign "$$IDENTITY" \
		--identifier "$(BUNDLE_ID)" \
		--entitlements Resources/Put.entitlements \
		--options runtime \
		--timestamp \
		$(APP_BUNDLE); \
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	@mkdir -p dist
	ditto -c -k --keepParent $(APP_BUNDLE) dist/$(APP_NAME)-$(VERSION).zip
	@# Resolve notarisation creds: prefer Keychain, fall back to env vars.
	@if [ -n "$(RELEASE_API_ISSUER)" ] && [ -n "$(RELEASE_API_KEY)" ] && [ -n "$(RELEASE_API_KEY_PATH)" ]; then \
		echo "Using Keychain notarisation credentials (App Store Connect API)"; \
		if [ ! -f "$(RELEASE_API_KEY_PATH)" ]; then \
			echo "ERROR: API key file not found at $(RELEASE_API_KEY_PATH)"; exit 1; \
		fi; \
		xcrun notarytool submit dist/$(APP_NAME)-$(VERSION).zip \
			--issuer "$(RELEASE_API_ISSUER)" \
			--key-id "$(RELEASE_API_KEY)" \
			--key "$(RELEASE_API_KEY_PATH)" \
			--wait; \
	elif [ -n "$${APPLE_ID:-}" ] && [ -n "$${APPLE_TEAM_ID:-}" ] && [ -n "$${APPLE_ID_PASSWORD:-}" ]; then \
		echo "Using env-var notarisation credentials (app-specific password)"; \
		xcrun notarytool submit dist/$(APP_NAME)-$(VERSION).zip \
			--apple-id "$${APPLE_ID}" \
			--team-id "$${APPLE_TEAM_ID}" \
			--password "$${APPLE_ID_PASSWORD}" \
			--wait; \
	else \
		echo "ERROR: No notarisation credentials configured."; \
		echo "  Run 'make setup-release-keychain' (recommended) or export"; \
		echo "  APPLE_ID / APPLE_TEAM_ID / APPLE_ID_PASSWORD."; \
		exit 1; \
	fi
	xcrun stapler staple $(APP_BUNDLE)
	spctl --assess --verbose=4 $(APP_BUNDLE)

# Full release: bump patch version, notarise + stapled .app, then build a signed
# + notarised + stapled DMG. The patch bump runs first so each release ships a
# fresh version. Credentials are validated *before* the bump so a misconfigured
# release doesn't burn a version number. Pass NO_BUMP=1 to re-run a release at
# the current VERSION (e.g. retrying after a transient notarytool failure).
# Credentials resolve through the same Keychain-first cascade as `notarise`.
.PHONY: release
release:
	@if [ -z "$(RELEASE_SIGNING_IDENTITY)" ]; then \
		echo "ERROR: No Developer ID signing identity configured for DMG signing."; \
		echo "  Run 'make setup-release-keychain' or export DEVELOPER_ID_APPLICATION."; \
		exit 1; \
	fi
	@if [ -z "$(RELEASE_API_ISSUER)" ] || [ -z "$(RELEASE_API_KEY)" ] || [ -z "$(RELEASE_API_KEY_PATH)" ]; then \
		if [ -z "$${APPLE_ID:-}" ] || [ -z "$${APPLE_TEAM_ID:-}" ] || [ -z "$${APPLE_ID_PASSWORD:-}" ]; then \
			echo "ERROR: No notarisation credentials configured for DMG notarisation."; \
			exit 1; \
		fi; \
	fi
	@if [ -z "$(NO_BUMP)" ]; then \
		$(MAKE) --no-print-directory bump-patch; \
	else \
		echo "NO_BUMP=1: keeping VERSION at $(VERSION)"; \
	fi
	@# Re-exec into the build step so $(VERSION) is re-evaluated from the
	@# (possibly bumped) VERSION file. Make captures $(VERSION) at parse time;
	@# the recursive make invocation re-reads it.
	@$(MAKE) --no-print-directory _release-build

# Implementation half of `release`: runs after the patch bump (or NO_BUMP=1
# skip) so the notarise/DMG chain sees the new VERSION. Not intended to be
# invoked directly.
.PHONY: _release-build
_release-build: notarise
	@APP_NAME="$(APP_NAME)" \
	 APP_PATH="$(APP_BUNDLE)" \
	 VERSION="$(VERSION)" \
	 DMG_DIR=dist \
	 APPLE_SIGNING_IDENTITY="$(RELEASE_SIGNING_IDENTITY)" \
	 APPLE_API_ISSUER="$(RELEASE_API_ISSUER)" \
	 APPLE_API_KEY="$(RELEASE_API_KEY)" \
	 APPLE_API_KEY_PATH="$(RELEASE_API_KEY_PATH)" \
	 ./scripts/create-dmg.sh
	@$(MAKE) --no-print-directory verify
	@$(MAKE) --no-print-directory _release-tag

# Commit the version bump and tag it, so the tag always names the version the
# artefacts were built with. Runs last, after `verify` passes, so a failed
# release never burns a tag or a version number. NO_TAG=1 skips it.
#
# Only VERSION and CHANGELOG.md are staged. Staging everything would fold
# whatever else is dirty into a release commit, and `release` has usually just
# written those two itself via bump-patch.
#
# Nothing is pushed. The push command is printed instead, because a tag is
# awkward to retract once it is on the remote.
.PHONY: _release-tag
_release-tag:
	@if [ -n "$(NO_TAG)" ]; then echo "NO_TAG=1: skipping commit and tag."; exit 0; fi
	@if ! git rev-parse --git-dir >/dev/null 2>&1; then \
		echo "Not a git repository; skipping commit and tag."; exit 0; \
	fi
	@V=$$(tr -d '[:space:]' < VERSION); TAG="v$$V"; \
	if git rev-parse -q --verify "refs/tags/$$TAG" >/dev/null; then \
		echo "WARNING: tag $$TAG already exists, leaving it untouched."; \
		echo "         The artefacts in dist/ are built for $$V. Either delete the"; \
		echo "         tag or re-run without NO_BUMP=1 to take a fresh version."; \
		exit 0; \
	fi; \
	if ! git diff --quiet -- VERSION CHANGELOG.md || \
	   ! git diff --cached --quiet -- VERSION CHANGELOG.md; then \
		git add VERSION CHANGELOG.md && \
		git commit -q -m "chore: release $$V" && \
		echo "Committed: chore: release $$V"; \
	else \
		echo "VERSION and CHANGELOG.md are already committed; tagging HEAD."; \
	fi; \
	git tag -a "$$TAG" -m "Put $$V" && \
	echo "Tagged $$TAG at $$(git rev-parse --short HEAD)"; \
	echo ""; \
	BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	if [ -t 0 ]; then \
		printf "Push %s and %s to origin? [y/N] " "$$BRANCH" "$$TAG"; \
		read -r reply; \
	else \
		reply=""; \
		echo "stdin is not a tty, so not prompting."; \
	fi; \
	case "$$reply" in \
		y|Y|yes|Yes|YES) \
			git push origin "$$BRANCH" && git push origin "$$TAG" && \
			echo "Pushed $$BRANCH and $$TAG.";; \
		*) \
			echo "Not pushed. To publish:"; \
			echo "  git push origin $$BRANCH && git push origin $$TAG";; \
	esac

# Verify the built .app and latest .dmg are signed, notarised, and stapled.
.PHONY: verify
verify:
	@APP="$(APP_BUNDLE)"; \
	if [ ! -d "$$APP" ]; then \
		echo "ERROR: $$APP not found. Run 'make release' first."; exit 1; \
	fi; \
	DMG=$$(ls -t dist/$(APP_NAME)-*.dmg 2>/dev/null | head -1); \
	echo "=== App: $$APP ==="; \
	echo ""; \
	echo "Signature:"; \
	if codesign --verify --deep --strict --verbose=2 "$$APP" 2>&1 | sed 's/^/  /'; then \
		echo "  OK"; \
	else \
		echo "  FAILED"; exit 1; \
	fi; \
	echo ""; \
	echo "Signing identity:"; \
	codesign -dvv "$$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=|Notarization|flags=' | sed 's/^/  /'; \
	echo ""; \
	echo "Entitlements:"; \
	codesign -d --entitlements :- "$$APP" 2>/dev/null | plutil -p - 2>/dev/null | sed 's/^/  /' || true; \
	echo ""; \
	echo "Gatekeeper:"; \
	spctl --assess --type execute --verbose=2 "$$APP" 2>&1 | sed 's/^/  /' || true; \
	echo ""; \
	echo "Notarisation staple:"; \
	if xcrun stapler validate "$$APP" 2>&1 | grep -q "worked"; then \
		echo "  OK"; \
	else \
		echo "  FAILED"; exit 1; \
	fi; \
	echo ""; \
	if [ -z "$$DMG" ]; then \
		echo "(No DMG found in dist/ -- skipping DMG checks. Run 'make release' to produce one.)"; \
	else \
		echo "=== DMG: $$DMG ==="; \
		echo ""; \
		echo "Signature:"; \
		if codesign --verify --verbose=2 "$$DMG" 2>&1 | sed 's/^/  /'; then \
			echo "  OK"; \
		else \
			echo "  FAILED"; exit 1; \
		fi; \
		echo ""; \
		echo "Signing identity:"; \
		codesign -dvv "$$DMG" 2>&1 | grep -E 'Authority=|TeamIdentifier=|Notarization' | sed 's/^/  /'; \
		echo ""; \
		echo "Gatekeeper:"; \
		spctl --assess --type open --context context:primary-signature --verbose=2 "$$DMG" 2>&1 | sed 's/^/  /' || true; \
		echo ""; \
		echo "Notarisation staple:"; \
		if xcrun stapler validate "$$DMG" 2>&1 | grep -q "worked"; then \
			echo "  OK"; \
		else \
			echo "  FAILED"; exit 1; \
		fi; \
	fi
	@echo ""
	@echo "All checks passed."

# Dump the secrets GitHub Actions needs. Sensitive -- do not paste into logs.
.PHONY: github-secrets
github-secrets:
	@echo "=== GitHub Actions secrets ==="
	@echo "Paste into: Settings > Secrets and variables > Actions > New repository secret"
	@echo "WARNING: sensitive values below. Do not share this output."
	@echo ""
	@echo "APPLE_SIGNING_IDENTITY:"
	@if [ -n "$(RELEASE_SIGNING_IDENTITY)" ]; then \
		echo "  $(RELEASE_SIGNING_IDENTITY)"; \
	else \
		echo "  (not configured -- run 'make setup-release-keychain')"; \
	fi
	@echo ""
	@echo "APPLE_CERTIFICATE:"
	@echo "  Export your Developer ID Application cert as .p12 from Keychain Access, then:"
	@echo "    base64 -i /path/to/certificate.p12 | pbcopy"
	@echo "  Paste the clipboard as the secret value."
	@echo ""
	@echo "APPLE_CERTIFICATE_PASSWORD:"
	@echo "  The password you set when exporting the .p12."
	@echo ""
	@echo "APPLE_API_ISSUER:"
	@if [ -n "$(RELEASE_API_ISSUER)" ]; then \
		echo "  $(RELEASE_API_ISSUER)"; \
	else \
		echo "  (not configured)"; \
	fi
	@echo ""
	@echo "APPLE_API_KEY:"
	@if [ -n "$(RELEASE_API_KEY)" ]; then \
		echo "  $(RELEASE_API_KEY)"; \
	else \
		echo "  (not configured)"; \
	fi
	@echo ""
	@echo "APPLE_API_KEY_CONTENT:"
	@if [ -n "$(RELEASE_API_KEY_PATH)" ] && [ -f "$(RELEASE_API_KEY_PATH)" ]; then \
		cat "$(RELEASE_API_KEY_PATH)"; \
	else \
		echo "  (.p8 key file not found at: $(RELEASE_API_KEY_PATH))"; \
	fi
	@echo ""
	@echo "=== Done ==="

# Freeze the CHANGELOG.md [Unreleased] section as a release using the version
# in the VERSION file. Idempotent -- skips if [Unreleased] is empty.
.PHONY: stamp-version
stamp-version:
	@V=$$(cat VERSION | tr -d '[:space:]'); \
	if command -v uv >/dev/null 2>&1; then \
		uv run scripts/version.py stamp --version "$$V" --changelog-only; \
	else \
		python3 scripts/version.py stamp --version "$$V" --changelog-only; \
	fi

# Bump the project version: writes VERSION and freezes CHANGELOG [Unreleased].
# Usage: make version V=0.2.0
.PHONY: version
version:
	@if [ -z "$(V)" ]; then \
		echo "ERROR: pass V=X.Y.Z, e.g. make version V=0.2.0"; exit 1; \
	fi
	@if ! echo "$(V)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$$'; then \
		echo "ERROR: '$(V)' is not a valid semver string"; exit 1; \
	fi
	@echo "$(V)" > VERSION
	@if command -v uv >/dev/null 2>&1; then \
		uv run scripts/version.py stamp --version "$(V)" --changelog-only; \
	else \
		python3 scripts/version.py stamp --version "$(V)" --changelog-only; \
	fi
	@echo "Version bumped to $(V). Commit VERSION + CHANGELOG.md, then 'make release'."

# Bump the patch component: 0.1.0 -> 0.1.1. Writes VERSION and freezes
# CHANGELOG [Unreleased]. Used by `make release` so each release auto-bumps;
# also runnable on its own when you want the bump without a release. Refuses
# pre-release suffixes (e.g. 0.1.0-rc1) since incrementing them is ambiguous.
.PHONY: bump-patch
bump-patch:
	@CUR=$$(cat VERSION | tr -d '[:space:]'); \
	if ! echo "$$CUR" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "ERROR: VERSION '$$CUR' is not plain semver (X.Y.Z); bump manually with 'make version V=...'."; \
		exit 1; \
	fi; \
	MAJ=$${CUR%%.*}; \
	REST=$${CUR#*.}; \
	MIN=$${REST%%.*}; \
	PATCH=$${REST#*.}; \
	NEW="$$MAJ.$$MIN.$$((PATCH + 1))"; \
	echo "$$NEW" > VERSION; \
	if command -v uv >/dev/null 2>&1; then \
		uv run scripts/version.py stamp --version "$$NEW" --changelog-only; \
	else \
		python3 scripts/version.py stamp --version "$$NEW" --changelog-only; \
	fi; \
	echo "Version bumped: $$CUR -> $$NEW"

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR) $(APP_BUNDLE) dist

$(BINARY):
	$(MAKE) build
