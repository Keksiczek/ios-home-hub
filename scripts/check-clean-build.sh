#!/usr/bin/env bash
# scripts/check-clean-build.sh
#
# Smoke-test: verifies the repo is in a reproducible-build state.
# Run via `make check` or directly: bash scripts/check-clean-build.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed (details printed to stdout)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

red()   { printf '\033[0;31m✗ %s\033[0m\n' "$*"; }
green() { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m⚠ %s\033[0m\n' "$*"; }

# ── 1. No hardcoded user-home paths ──────────────────────────────────────────
echo "--- Checking for hardcoded user paths ---"
HARDCODED=$(grep -rn --include="*.yml" --include="*.pbxproj" --include="*.swift" \
  --include="*.xcconfig" \
  -E '/Users/[^$]|/home/[^$]' \
  "$REPO_ROOT" \
  --exclude-dir=".git" \
  --exclude-dir="DerivedData" \
  2>/dev/null || true)
if [ -n "$HARDCODED" ]; then
  red "Hardcoded user paths found:"
  echo "$HARDCODED"
  FAIL=1
else
  green "No hardcoded user paths in source files"
fi

# ── 2. Required files exist ───────────────────────────────────────────────────
echo "--- Checking required files ---"
REQUIRED_FILES=(
  "project.yml"
  "Package.swift"
  "Package.resolved"
  "HomeHub.xcodeproj/project.pbxproj"
  "HomeHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  "HomeHub/Runtime/HubIntegration.swift"
  "HomeHub/Runtime/MLXRuntime.swift"
  "HomeHub/Runtime/MLXLoader.swift"
  "HomeHub/Runtime/LocalLLMRuntime.swift"
  "HomeHub/Runtime/Bridge/HomeHub-Bridging-Header.h"
  "HomeHub/HomeHub.entitlements"
  "HomeHubWidget/HomeHubWidget.entitlements"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [ -f "$REPO_ROOT/$f" ]; then
    green "Exists: $f"
  else
    red "MISSING: $f"
    FAIL=1
  fi
done

# ── 3. No tracked .bak / .disabled artefacts ─────────────────────────────────
echo "--- Checking for tracked backup artefacts ---"
BAK_TRACKED=$(git -C "$REPO_ROOT" ls-files | grep -E '\.bak[0-9]*$|\.disabled$|\.orig$' || true)
if [ -n "$BAK_TRACKED" ]; then
  red "Backup files are tracked by git (should be removed with git rm --cached):"
  echo "$BAK_TRACKED"
  FAIL=1
else
  green "No tracked .bak/.disabled files"
fi

# ── 4. Package.resolved consistency ──────────────────────────────────────────
echo "--- Checking Package.resolved consistency ---"
ROOT_PINS="$REPO_ROOT/Package.resolved"
XCODE_PINS="$REPO_ROOT/HomeHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ -f "$ROOT_PINS" ] && [ -f "$XCODE_PINS" ]; then
  if diff -q "$ROOT_PINS" "$XCODE_PINS" > /dev/null 2>&1; then
    green "Package.resolved files are identical"
  else
    warn "Package.resolved files differ — run 'make sync-resolved' to sync"
    diff "$ROOT_PINS" "$XCODE_PINS" || true
    # Not a hard failure — xcshareddata version is authoritative for Xcode
  fi
else
  red "One or both Package.resolved files missing"
  FAIL=1
fi

# ── 5. project.yml structural validation (duplicate keys, broken refs) ────────
echo "--- Validating project.yml spec ---"
if python3 "$REPO_ROOT/scripts/validate-project-spec.py" 2>&1; then
  : # validator prints its own green/red lines
else
  FAIL=1
fi

# ── 6. swift-transformers Hub/Tokenizers in project.yml ──────────────────────
echo "--- Checking Hub and Tokenizers are declared in project.yml ---"
if grep -q "product: Hub" "$REPO_ROOT/project.yml" && \
   grep -q "product: Tokenizers" "$REPO_ROOT/project.yml"; then
  green "Hub and Tokenizers products declared in project.yml"
else
  red "Hub and/or Tokenizers missing from project.yml dependencies"
  FAIL=1
fi

# ── 7. Package.swift uses Hub + Tokenizers (not Transformers) ────────────────
echo "--- Checking Package.swift product names ---"
if grep -q '"Hub"' "$REPO_ROOT/Package.swift" && \
   grep -q '"Tokenizers"' "$REPO_ROOT/Package.swift"; then
  green "Package.swift uses Hub + Tokenizers products"
else
  red "Package.swift missing Hub and/or Tokenizers"
  FAIL=1
fi
if grep -q '"Transformers"' "$REPO_ROOT/Package.swift"; then
  red "Package.swift still references legacy 'Transformers' product"
  FAIL=1
fi

# ── 8. pbxproj has XCRemoteSwiftPackageReference entries ─────────────────────
echo "--- Checking pbxproj package sections ---"
PBXPROJ="$REPO_ROOT/HomeHub.xcodeproj/project.pbxproj"
if grep -q "XCRemoteSwiftPackageReference" "$PBXPROJ" && \
   grep -q "XCSwiftPackageProductDependency" "$PBXPROJ"; then
  green "pbxproj contains package reference sections"
else
  red "pbxproj is missing XCRemoteSwiftPackageReference or XCSwiftPackageProductDependency"
  FAIL=1
fi
PKG_DEP_COUNT=$(grep -c "packageProductDependencies" "$PBXPROJ" 2>/dev/null || echo 0)
if [ "$PKG_DEP_COUNT" -eq 0 ]; then
  red "packageProductDependencies missing from pbxproj"
  FAIL=1
else
  green "packageProductDependencies present ($PKG_DEP_COUNT target(s))"
fi

# ── 9. No HomeHubUITests target (source dir doesn't exist) ───────────────────
echo "--- Checking for phantom HomeHubUITests target ---"
if grep -q "HomeHubUITests" "$REPO_ROOT/project.yml" 2>/dev/null; then
  if [ ! -d "$REPO_ROOT/HomeHubUITests" ]; then
    red "project.yml declares HomeHubUITests but directory HomeHubUITests/ doesn't exist"
    FAIL=1
  else
    green "HomeHubUITests declared and directory exists"
  fi
else
  green "No HomeHubUITests target (expected — source dir absent)"
fi

# ── 10. No hardcoded DEVELOPMENT_TEAM in pbxproj ─────────────────────────────
echo "--- Checking for hardcoded DEVELOPMENT_TEAM in pbxproj ---"
PBXPROJ="$REPO_ROOT/HomeHub.xcodeproj/project.pbxproj"
DT_LINES=$(grep -n "DEVELOPMENT_TEAM" "$PBXPROJ" 2>/dev/null | grep -v '= "";' | grep -v '= ""' || true)
if [ -n "$DT_LINES" ]; then
  red "pbxproj has hardcoded DEVELOPMENT_TEAM (breaks other developers' signing):"
  echo "$DT_LINES"
  FAIL=1
else
  green "No hardcoded DEVELOPMENT_TEAM in pbxproj"
fi

# ── 11. Package.resolved hash consistency ────────────────────────────────────
echo "--- Checking Package.resolved byte-for-byte identity ---"
ROOT_HASH=$(sha256sum "$REPO_ROOT/Package.resolved" 2>/dev/null | awk '{print $1}')
XCODE_HASH=$(sha256sum "$XCODE_PINS" 2>/dev/null | awk '{print $1}')
if [ "$ROOT_HASH" = "$XCODE_HASH" ] && [ -n "$ROOT_HASH" ]; then
  green "Package.resolved SHA-256 match ($ROOT_HASH)"
else
  red "Package.resolved files differ by hash (run 'make sync-resolved' and commit both)"
  FAIL=1
fi

# ── 12. import ↔ project.yml product consistency ─────────────────────────────
# (Also covered by validate-project-spec.py, kept here as a second line of
#  defence with cheap greps.)
echo "--- Checking import/product consistency ---"
HUB_IMPORT=$(grep -l "^import Hub" "$REPO_ROOT/HomeHub/Runtime/"*.swift 2>/dev/null | head -1 || true)
if [ -n "$HUB_IMPORT" ]; then
  if grep -q "product: Hub" "$REPO_ROOT/project.yml" && \
     grep -q "product: Tokenizers" "$REPO_ROOT/project.yml"; then
    green "HubIntegration.swift: Hub + Tokenizers imports match project.yml declarations"
  else
    red "HubIntegration.swift imports Hub/Tokenizers but project.yml is missing those products"
    FAIL=1
  fi
fi
WK_IMPORT=$(grep -rl "^import WhisperKit" "$REPO_ROOT/HomeHub/" 2>/dev/null | head -1 || true)
if [ -n "$WK_IMPORT" ]; then
  if grep -q "product: WhisperKit" "$REPO_ROOT/project.yml"; then
    green "WhisperKit import matches project.yml declaration"
  else
    red "File imports WhisperKit but product: WhisperKit missing from project.yml"
    FAIL=1
  fi
fi

# ── 13. Shared schemes exist for every target -–-------------–-––-––-––--–-––-
# Without committed shared schemes a fresh clone can't `xcodebuild -scheme X`
# until somebody opens the project in Xcode and lets it autogenerate one.
echo "--- Checking shared schemes are committed ---"
SCHEMES_DIR="$REPO_ROOT/HomeHub.xcodeproj/xcshareddata/xcschemes"
for s in HomeHub HomeHubWidget; do
  if [ -f "$SCHEMES_DIR/$s.xcscheme" ]; then
    green "Shared scheme present: $s.xcscheme"
  else
    red "Missing shared scheme: $SCHEMES_DIR/$s.xcscheme — run 'make generate' or commit it manually."
    FAIL=1
  fi
done

# ── 14. No tracked xcuserdata / .DS_Store -------------------------------------
echo "--- Checking for tracked per-developer state ---"
LEAKED=$(git -C "$REPO_ROOT" ls-files | grep -E '(^|/)(\.DS_Store|xcuserdata/)' || true)
if [ -n "$LEAKED" ]; then
  red "Per-developer files are tracked (run 'git rm --cached'):"
  echo "$LEAKED"
  FAIL=1
else
  green "No tracked .DS_Store or xcuserdata files"
fi

# ── 15. AppIcon image set is sane ---------------------------------------------
# A reference to AppIcon.png with no actual file produces a build warning on
# every compile and a missing icon in the app bundle.
echo "--- Checking AppIcon asset set integrity ---"
ICON_JSON="$REPO_ROOT/HomeHub/Assets.xcassets/AppIcon.appiconset/Contents.json"
if [ -f "$ICON_JSON" ]; then
  ICON_REF=$(grep -oE '"filename"\s*:\s*"[^"]+"' "$ICON_JSON" | head -1 || true)
  if [ -n "$ICON_REF" ]; then
    FNAME=$(echo "$ICON_REF" | sed -E 's/.*"filename"\s*:\s*"([^"]+)".*/\1/')
    if [ -f "$REPO_ROOT/HomeHub/Assets.xcassets/AppIcon.appiconset/$FNAME" ]; then
      green "AppIcon references $FNAME and the file exists"
    else
      red "AppIcon Contents.json references '$FNAME' but the file is missing — every build will warn."
      FAIL=1
    fi
  else
    green "AppIcon set is intentionally empty (no dangling filename references)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" -eq 0 ]; then
  green "All checks passed — repo should be reproducibly buildable after clone."
  exit 0
else
  red "One or more checks FAILED — fix the issues above before merging."
  exit 1
fi
