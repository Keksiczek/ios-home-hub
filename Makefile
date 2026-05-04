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
DEST     = platform=iOS Simulator,name=iPhone 16

# ── Primary targets ───────────────────────────────────────────────────────────

.PHONY: setup generate resolve validate check ci build build-device test clean sync-resolved verify-transformers help

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
test:
	xcodebuild test \
	  -project $(PROJECT) \
	  -scheme  $(SCHEME) \
	  -destination 'platform=iOS Simulator,name=iPhone 16'

## Verify swift-transformers product boundary (no Hub/Tokenizers as product names).
## Runs automatically as part of `make check` / `make ci`.
verify-transformers:
	@bash scripts/verify-swift-transformers-boundary.sh

## Validate project.yml for duplicate keys and broken package references.
## Run before `make generate` to catch silent YAML override bugs early.
validate:
	@python3 scripts/validate-project-spec.py

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
	@echo "  build               — compile on iPhone 16 simulator (no signing; matches CI)"
	@echo "  build-device        — compile for generic iOS device (needs signing or override)"
	@echo "  test                — run unit tests on iPhone 16 simulator"
	@echo "  check               — boundary + validate + smoke-test"
	@echo "  ci                  — run the same guardrails CI runs (no Xcode needed)"
	@echo "  clean               — clean derived data"
	@echo "  sync-resolved       — copy root Package.resolved into xcshareddata"
