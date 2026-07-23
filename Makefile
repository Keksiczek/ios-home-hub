# HomeHub — developer workflow targets
#
# Prereqs: Xcode 15.4+, xcodegen (`brew install xcodegen`).
# llama.xcframework is OPTIONAL — only needed if you opt in to llama.cpp
# via HOMEHUB_LLAMA_RUNTIME (see README). The default build is MLX-only.
#
# Typical first-time flow:
#   make setup          # generate project + resolve packages
#   open HomeHub.xcodeproj

SCHEME   = HomeHub
PROJECT  = HomeHub.xcodeproj

# Simulator destination.
#
# Pinning a device name (this used to say "iPhone 16") breaks the moment Xcode
# updates its bundled runtimes — Xcode 26.2 ships iPhone 17 / 17 Pro / Air / 16e
# and no plain "iPhone 16", so every `make build` and `make test` failed before
# compiling a single file. `generic/platform=iOS Simulator` builds against the
# simulator SDK without naming a device, so it keeps working across Xcode
# releases.
#
# `make test` still needs a concrete device to boot, so it resolves the newest
# available iPhone at run time — see TEST_DEST below. Override either explicitly:
#   make build DEST='platform=iOS Simulator,name=iPhone 17 Pro'
DEST     = generic/platform=iOS Simulator

# Newest available iPhone simulator, resolved at invocation time. Falls back to
# the generic destination if none is installed (CI images without runtimes).
TEST_DEST = $(shell xcrun simctl list devices available 2>/dev/null \
              | grep -oE 'iPhone [0-9]+[a-zA-Z ]*' | sort -Vr | head -1 \
              | sed 's/^/platform=iOS Simulator,name=/' \
              | sed 's/ *$$//')

# ── Primary targets ───────────────────────────────────────────────────────────

.PHONY: setup generate resolve validate check check-plist ci build build-device test clean sync-resolved verify-transformers help

## Full first-time or post-merge setup (generate project + fetch packages).
setup: generate resolve

## Regenerate HomeHub.xcodeproj from project.yml (source of truth).
## Run this whenever project.yml changes.
generate:
	xcodegen generate

## Fetch / update SPM packages declared in project.yml.
## Reads from xcshareddata/swiftpm/Package.resolved (committed) — no network
## surprises as long as the lockfile is up to date.
resolve:
	xcodebuild -resolvePackageDependencies \
	  -project $(PROJECT) \
	  -scheme  $(SCHEME)

## Compile the app target on the iOS Simulator (no signing required).
## Matches what the build-ios CI job runs — green CI implies this passes.
## Does NOT install or archive — use Xcode or xcodebuild archive for that.
build:
	xcodebuild build \
	  -project     $(PROJECT) \
	  -scheme       $(SCHEME) \
	  -destination  '$(DEST)'

## Compile for a generic iOS device.
## Requires either DEVELOPMENT_TEAM set in your local .xcconfig, OR the
## CODE_SIGNING_ALLOWED=NO override below (which produces an unsignable .app
## — useful only for arch / Metal sanity-checking, not for device deploy).
build-device:
	xcodebuild build \
	  -project     $(PROJECT) \
	  -scheme       $(SCHEME) \
	  -destination 'generic/platform=iOS' \
	  CODE_SIGNING_ALLOWED=NO

## Run unit tests in the iOS simulator.
## Uses TEST_DEST (newest installed iPhone) because tests need a bootable
## device, unlike `make build` which only needs the simulator SDK.
test:
	@echo "Testing on: $(TEST_DEST)"
	xcodebuild test \
	  -project $(PROJECT) \
	  -scheme  $(SCHEME) \
	  -destination '$(TEST_DEST)'

## Verify swift-transformers product boundary (no Hub/Tokenizers as product names).
## Runs automatically as part of `make check` / `make ci`.
verify-transformers:
	@bash scripts/verify-swift-transformers-boundary.sh

## Validate project.yml for duplicate keys and broken package references.
## Run before `make generate` to catch silent YAML override bugs early.
validate:
	@python3 scripts/validate-project-spec.py

## Assert the built app's Info.plist actually carries every key the app needs.
## Requires a prior `make build` — it inspects the BUILT bundle, because that
## is the only place a mis-declared Info.plist key is observable. See the
## script header for the two bugs that motivated it.
check-plist:
	@bash scripts/check-infoplist-keys.sh

## Smoke-check for common portability problems (hardcoded paths, missing files).
## Runs the swift-transformers boundary guardrail first, then spec validation.
check: verify-transformers validate
	@bash scripts/check-clean-build.sh

## Same set of guardrails CI runs. Useful before pushing.
## Doesn't need Xcode — runs on any machine with Python 3 + bash.
ci: check

## Remove Xcode derived data for this project.
clean:
	xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) 2>/dev/null || true
	rm -rf ~/Library/Developer/Xcode/DerivedData/HomeHub-*

## Refresh Package.resolved inside the xcodeproj workspace to match the
## root Package.resolved pins.  Run after manually editing Package.resolved.
sync-resolved:
	@cp Package.resolved \
	  HomeHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
	@echo "Synced Package.resolved → xcshareddata/swiftpm/Package.resolved"

help:
	@echo "Available targets:"
	@echo "  setup               — xcodegen generate + resolve packages (first-time)"
	@echo "  generate            — regenerate .xcodeproj from project.yml"
	@echo "  resolve             — fetch / verify SPM packages"
	@echo "  verify-transformers — check swift-transformers product boundary"
	@echo "  validate            — check project.yml for duplicate keys / bad refs"
	@echo "  check-plist         — assert built Info.plist has every required key (run after build)"
	@echo "  build               — compile on iPhone 16 simulator (no signing; matches CI)"
	@echo "  build-device        — compile for generic iOS device (needs signing or override)"
	@echo "  test                — run unit tests on iPhone 16 simulator"
	@echo "  check               — boundary + validate + smoke-test"
	@echo "  ci                  — run the same guardrails CI runs (no Xcode needed)"
	@echo "  clean               — clean derived data"
	@echo "  sync-resolved       — copy root Package.resolved into xcshareddata"
