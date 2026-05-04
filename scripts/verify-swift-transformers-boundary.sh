#!/usr/bin/env bash
# scripts/verify-swift-transformers-boundary.sh
#
# Guardrail: verifies that project.yml and Package.swift reference ONLY
# exported library products from swift-transformers, never internal targets.
#
# Background
# ----------
# swift-transformers exports exactly one library product:
#
#   .library(name: "Transformers", targets: ["Tokenizers", "Generation", "Models"])
#
# "Hub", "Tokenizers", "Generation", and "Models" are defined as INTERNAL targets.
# They are NOT exported as standalone library products.  Referencing them as
# product names causes SwiftPM to fail at dependency resolution:
#
#   product 'Hub' required by package 'ios-home-hub' target 'HomeHub'
#   not found in package 'swift-transformers'
#
# Strategy
# --------
# 1. If a swift-transformers checkout is present on disk, parse its Package.swift
#    to get the authoritative list of exported library product names and fail if
#    we reference any non-exported name.
# 2. If no checkout is available (CI without SPM resolved, fresh clone), fall
#    back to the known-good product list embedded below.  This still catches the
#    historical Hub/Tokenizers mistake.
#
# Exit codes
#   0 — boundary is correct
#   1 — one or more violations found

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

red()   { printf '\033[0;31m✗ %s\033[0m\n' "$*"; }
green() { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m⚠ %s\033[0m\n' "$*"; }

echo "=== verify-swift-transformers-boundary ==="

# ── 1. Locate upstream checkout ───────────────────────────────────────────────
ST_CHECKOUT=""
SEARCH_PATHS=(
  "$REPO_ROOT/.build/checkouts/swift-transformers"
  "$REPO_ROOT/HomeHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/SourcePackages/checkouts/swift-transformers"
)
# Also search Xcode DerivedData (macOS only; glob may not expand on Linux — OK to fail)
shopt -s nullglob 2>/dev/null || true
for dd_path in "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/swift-transformers; do
  SEARCH_PATHS+=("$dd_path")
done

for candidate in "${SEARCH_PATHS[@]}"; do
  if [ -f "$candidate/Package.swift" ]; then
    ST_CHECKOUT="$candidate"
    break
  fi
done

# ── 2. Determine upstream exported library products ───────────────────────────
if [ -n "$ST_CHECKOUT" ]; then
  echo "Upstream checkout found: $ST_CHECKOUT"
  # Extract names from  .library(name: "X", ...)  lines in upstream Package.swift
  UPSTREAM_PRODUCTS=$(grep -E '\.library\(name:' "$ST_CHECKOUT/Package.swift" \
    | grep -oE 'name:\s*"[^"]+"' \
    | sed -E 's/name:\s*"([^"]+)"/\1/' \
    | sort || true)
  if [ -z "$UPSTREAM_PRODUCTS" ]; then
    warn "Could not parse products from $ST_CHECKOUT/Package.swift — falling back to known list"
    UPSTREAM_PRODUCTS="Transformers"
  else
    echo "Upstream library products: $(echo "$UPSTREAM_PRODUCTS" | tr '\n' ' ')"
  fi
else
  warn "swift-transformers checkout not found on disk."
  warn "Falling back to known-good product list for v0.1.14."
  warn "Run 'xcodebuild -resolvePackageDependencies ...' to populate the checkout"
  warn "and re-run this script for a fully authoritative check."
  UPSTREAM_PRODUCTS="Transformers"
fi

# ── 3. Internal targets that must NEVER appear as product: X ─────────────────
# These are valid Swift module names (import Hub / import Tokenizers work
# because the modules are compiled as transitive deps), but they are NOT
# SwiftPM product names in any known version of swift-transformers.
FORBIDDEN_PRODUCTS="Hub Tokenizers Generation Models"

echo ""
echo "--- Checking project.yml ---"
PROJ_YML="$REPO_ROOT/project.yml"
PROJ_FAIL=0
for bad in $FORBIDDEN_PRODUCTS; do
  # Check for a product: Hub/Tokenizers/etc. line immediately following a
  # SwiftTransformers package reference (within the same dependency block).
  # We use a two-pass approach: find all product: X lines and flag the bad ones
  # only when they appear under the SwiftTransformers package key.
  # Simple heuristic: any `product: Hub` in the file is wrong because no other
  # package in this project has a product named Hub/Tokenizers/Generation/Models.
  if grep -qE "^\s+-?\s*product:\s+$bad\b" "$PROJ_YML" 2>/dev/null; then
    red "project.yml: 'product: $bad' is an internal swift-transformers target, not a product."
    red "  Replace with 'product: Transformers' (the exported library product)."
    PROJ_FAIL=1
    FAIL=1
  fi
done
if [ $PROJ_FAIL -eq 0 ]; then
  # Verify the correct product is actually declared
  if grep -qE "^\s+-?\s*product:\s+Transformers\b" "$PROJ_YML" 2>/dev/null; then
    green "project.yml: 'product: Transformers' declared (correct)"
  else
    warn "project.yml: 'product: Transformers' not found — double-check SwiftTransformers dep"
  fi
fi

echo ""
echo "--- Checking Package.swift ---"
PKG_SWIFT="$REPO_ROOT/Package.swift"
PKG_FAIL=0
if [ -f "$PKG_SWIFT" ]; then
  for bad in $FORBIDDEN_PRODUCTS; do
    if grep -qE "\.product\(name:\s*\"$bad\",\s*package:\s*\"swift-transformers\"\)" \
       "$PKG_SWIFT" 2>/dev/null; then
      red "Package.swift: .product(name: \"$bad\", package: \"swift-transformers\") is an internal target."
      red "  Replace with .product(name: \"Transformers\", package: \"swift-transformers\")."
      PKG_FAIL=1
      FAIL=1
    fi
  done
  if [ $PKG_FAIL -eq 0 ]; then
    if grep -qE "\.product\(name:\s*\"Transformers\",\s*package:\s*\"swift-transformers\"\)" \
       "$PKG_SWIFT" 2>/dev/null; then
      green "Package.swift: .product(name: \"Transformers\", ...) declared (correct)"
    else
      warn "Package.swift: .product(name: \"Transformers\", ...) not found — double-check"
    fi
  fi
else
  warn "Package.swift not found — skipping"
fi

# ── 4. If upstream checkout present, verify no referenced product is missing ──
if [ -n "$ST_CHECKOUT" ] && [ -n "$UPSTREAM_PRODUCTS" ]; then
  echo ""
  echo "--- Cross-checking referenced products against upstream ---"
  # Collect all product: X values referencing SwiftTransformers from project.yml
  REFERENCED=$(grep -A1 "package: SwiftTransformers" "$PROJ_YML" 2>/dev/null \
    | grep -oE "product:\s+\S+" | sed 's/product:\s*//' || true)
  for ref in $REFERENCED; do
    if echo "$UPSTREAM_PRODUCTS" | grep -qF "$ref"; then
      green "product: $ref — confirmed exported by upstream"
    else
      red "product: $ref is NOT in upstream swift-transformers library products (${UPSTREAM_PRODUCTS//$'\n'/, })"
      FAIL=1
    fi
  done
fi

echo ""
if [ $FAIL -eq 0 ]; then
  green "swift-transformers product boundary is correct."
  exit 0
else
  red "swift-transformers boundary violations found — fix before building."
  exit 1
fi
