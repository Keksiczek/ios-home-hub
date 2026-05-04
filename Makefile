# HomeHub — developer workflow targets
#
# Prereqs: Xcode 15.4+, xcodegen (`brew install xcodegen`),
#          llama.xcframework placed as a sibling of this repo root.
#
# Typical first-time flow:
#   make setup          # generate project + resolve packages
#   open HomeHub.xcodeproj

SCHEME   = HomeHub
PROJECT  = HomeHub.xcodeproj
DEST     = generic/platform=iOS

# ── Primary targets ───────────────────────────────────────────────────────────

.PHONY: setup generate resolve validate check ci build test clean sync-resolved verify-transformers help

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

## Compile the app target (requires llama.xcframework as sibling of repo root).
## Does NOT install or archive — use Xcode or xcodebuild archive for that.
build:
	xcodebuild build \
	  -project     $(PROJECT) \
	  -scheme       $(SCHEME) \
	  -destination  '$(DEST)' \
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
	@echo "  build               — compile (needs llama.xcframework sibling)"
	@echo "  test                — run unit tests in simulator"
	@echo "  check               — boundary + validate + smoke-test"
	@echo "  ci                  — run the same guardrails CI runs (no Xcode needed)"
	@echo "  clean               — clean derived data"
	@echo "  sync-resolved       — copy root Package.resolved into xcshareddata"
