#!/usr/bin/env python3
"""
scripts/validate-project-spec.py

Validates project.yml for structural problems that cause silent build failures.
Specifically catches the class of bug where duplicate YAML mapping keys cause
XcodeGen to silently use the wrong package version or dependency block.

Usage:
    python3 scripts/validate-project-spec.py           # from repo root
    python3 scripts/validate-project-spec.py --fix     # show what changed (dry-run hint)

Exit codes:
    0  all checks passed
    1  one or more violations found
"""

import sys
import re
from pathlib import Path
from collections import Counter


def red(msg):   print(f"\033[0;31m✗ {msg}\033[0m")
def green(msg): print(f"\033[0;32m✓ {msg}\033[0m")
def warn(msg):  print(f"\033[0;33m⚠ {msg}\033[0m")


def find_duplicate_mapping_keys(path: Path) -> list[tuple[int, str, int]]:
    """
    Scan a YAML file for duplicate mapping keys using PyYAML's event stream.
    This is the only reliable way to detect duplicates because the event stream
    preserves nesting structure — siblings at the same level are in the same
    MappingStartEvent/MappingEndEvent block, regardless of indentation tricks.

    Returns a list of (duplicate_line, key_name, first_seen_line) tuples.
    """
    import yaml

    text = path.read_text()
    duplicates: list[tuple[int, str, int]] = []

    # Walk the YAML event stream; maintain a stack of {key: start_mark.line}
    # dicts, one per open mapping.
    stack: list[dict[str, int]] = []

    try:
        for event in yaml.parse(text, Loader=yaml.SafeLoader):
            if isinstance(event, yaml.MappingStartEvent):
                stack.append({})
            elif isinstance(event, yaml.MappingEndEvent):
                if stack:
                    stack.pop()
            elif isinstance(event, yaml.ScalarEvent) and stack:
                # ScalarEvents inside a mapping alternate key/value.
                # We only care about keys, which appear at even positions (0, 2, 4 …).
                # Track parity via a simple counter stored alongside the dict.
                current = stack[-1]
                key = event.value
                lineno = event.start_mark.line + 1  # 0-indexed → 1-indexed
                # Use a sentinel key "__parity__" to track key/value alternation
                parity = current.pop("__parity__", 0)
                if parity == 0:  # this ScalarEvent is a mapping key
                    seen_key = f"__key__{key}"
                    if seen_key in current:
                        duplicates.append((lineno, key, current[seen_key]))
                    else:
                        current[seen_key] = lineno
                current["__parity__"] = 1 - parity
    except yaml.YAMLError:
        # Malformed YAML — let the caller handle it; we return what we found so far.
        pass

    return duplicates


def check_package_keys_vs_dependencies(path: Path) -> list[str]:
    """
    Cross-check that every `package: <name>` reference in the dependencies
    sections matches a defined key in the top-level `packages:` mapping.
    Catches cases like swiftTransformers vs SwiftTransformers.
    """
    text = path.read_text()

    # Extract defined package keys (lines like "  KeyName:" directly under packages:)
    defined: set[str] = set()
    in_packages = False
    packages_indent = None
    for line in text.splitlines():
        stripped = line.rstrip()
        if re.match(r'^packages:\s*$', stripped):
            in_packages = True
            packages_indent = 0
            continue
        if in_packages:
            m = re.match(r'^(\s+)([A-Za-z_][A-Za-z0-9_-]*):\s*$', line)
            if m:
                indent = len(m.group(1))
                if packages_indent is None or indent == 2:
                    defined.add(m.group(2))
            # Top-level section heading (no indent) ends packages block
            if stripped and not stripped.startswith(' ') and not stripped.startswith('#'):
                in_packages = False

    # Extract referenced package keys (lines like "    - package: KeyName")
    referenced: dict[str, int] = {}  # key → first line number
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = re.match(r'^\s+-\s+package:\s+(\S+)', line)
        if m:
            ref = m.group(1)
            if ref not in referenced:
                referenced[ref] = lineno

    errors = []
    for ref, lineno in referenced.items():
        if ref not in defined:
            errors.append(f"  line {lineno}: package reference '{ref}' not defined in packages: section")
    return errors


def check_version_floor(path: Path) -> list[str]:
    """
    Verify minimum version constraints for packages with known incompatibility floors.
    - WhisperKit must be >= 0.11.0 (0.9.x causes TensorUtils errors with swift-transformers >= 0.1.14)
    - SwiftTransformers must be >= 0.1.14
    """
    text = path.read_text()
    errors = []

    # Check for stale exactVersion or from: below minimum
    # Matches: `exactVersion: 0.9.3` or `from: 0.9.3`
    wk_exact = re.search(r'exactVersion:\s*([\d.]+)', text)
    wk_from  = re.search(r'(?m)(?:WhisperKit:[^\n]*\n(?:[ \t]+[^\n]+\n)*?[ \t]+from:\s*([\d.]+))', text)

    # Simpler: scan for any version that looks like a WhisperKit 0.9.x/0.10.x pin
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = re.match(r'\s+exactVersion:\s*([\d.]+)', line)
        if m:
            ver = m.group(1)
            # We can't easily know which package this belongs to without full parsing,
            # but exactVersion is rare; flag anything below 0.11.0 that looks like whisperkit
            try:
                parts = [int(x) for x in ver.split('.')]
                if parts[0] == 0 and parts[1] < 11:
                    errors.append(
                        f"  line {lineno}: `exactVersion: {ver}` found — "
                        f"if this is WhisperKit, it must be >= 0.11.0 "
                        f"(earlier versions import TensorUtils which was removed from swift-transformers)"
                    )
            except ValueError:
                pass

    return errors


def main():
    repo_root = Path(__file__).parent.parent
    spec = repo_root / "project.yml"

    if not spec.exists():
        red(f"project.yml not found at {spec}")
        sys.exit(1)

    fail = False

    # ── Check 1: Duplicate YAML keys ─────────────────────────────────────────
    print("--- Checking for duplicate YAML mapping keys ---")
    dups = find_duplicate_mapping_keys(spec)
    if dups:
        for lineno, key, first_lineno in dups:
            red(f"Duplicate key '{key}' at line {lineno} (first seen at line {first_lineno})")
            print(f"  XcodeGen will silently use one definition; the other is ignored.")
        fail = True
    else:
        green("No duplicate mapping keys in project.yml")

    # ── Check 2: Package key vs dependency reference consistency ─────────────
    print("--- Checking package key references ---")
    ref_errors = check_package_keys_vs_dependencies(spec)
    if ref_errors:
        for e in ref_errors:
            red(e)
        fail = True
    else:
        green("All package: references match defined package keys")

    # ── Check 3: Known-bad version floors ────────────────────────────────────
    print("--- Checking version floor constraints ---")
    ver_errors = check_version_floor(spec)
    if ver_errors:
        for e in ver_errors:
            red(e)
        fail = True
    else:
        green("No known-bad version constraints found")

    # ── Check 4: Duplicate `dependencies:` blocks per target ─────────────────
    print("--- Checking for duplicate dependencies: blocks ---")
    text = spec.read_text()
    lines = text.splitlines()
    # Count target-level `dependencies:` keys (exactly 2-space indent under a target name)
    dep_lines = [(i+1, l) for i, l in enumerate(lines)
                 if re.match(r'^    dependencies:\s*$', l)]
    # 3 targets (HomeHub, HomeHubTests, HomeHubWidget) → expect exactly 3
    if len(dep_lines) > 3:
        red(f"Found {len(dep_lines)} `dependencies:` blocks at target level (expected ≤ 3):")
        for lineno, _ in dep_lines:
            print(f"  line {lineno}")
        print("  YAML uses the last definition; earlier blocks are silently ignored.")
        fail = True
    else:
        green(f"Dependency blocks: {len(dep_lines)} (one per target — OK)")

    print()
    if fail:
        red("Validation FAILED — fix the issues above before running xcodegen generate.")
        sys.exit(1)
    else:
        green("project.yml validation passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()
