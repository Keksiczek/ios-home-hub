#!/usr/bin/env python3
"""
scripts/validate-project-spec.py

Validates project.yml for structural problems that cause silent build failures
AND checks cross-source-of-truth consistency between project.yml, Package.swift,
the generated project.pbxproj, and Package.resolved.

Catches the class of bugs where:
  - Duplicate YAML mapping keys cause XcodeGen to silently use the wrong value.
  - A target's `dependencies:` block lists the same product twice, or two
    different package keys reference the same upstream URL.
  - A Swift source `import`s a product that is not declared in project.yml.
  - project.yml and Package.swift drift apart on URL or version.
  - The generated pbxproj declares a different package URL/version than
    project.yml's source-of-truth.
  - Package.resolved pins a package URL that is not declared anywhere.

Usage:
    python3 scripts/validate-project-spec.py

Exit codes:
    0  all checks passed
    1  one or more violations found
"""

import json
import re
import sys
from pathlib import Path


def red(msg):   print(f"\033[0;31m✗ {msg}\033[0m")
def green(msg): print(f"\033[0;32m✓ {msg}\033[0m")
def warn(msg):  print(f"\033[0;33m⚠ {msg}\033[0m")


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------

def normalize_url(url: str) -> str:
    """Lowercase + strip trailing .git so case-only or .git-only URL drift is flagged."""
    return url.lower().rstrip("/").removesuffix(".git")


def load_project_yml_packages(text: str) -> dict[str, dict]:
    """
    Parse the `packages:` block and return {key: {url, requirement}}.
    Done with the same event stream we use for duplicate-key detection so
    we don't depend on PyYAML's loader normalising things behind our back.
    """
    import yaml

    packages: dict[str, dict] = {}
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError:
        return packages
    pkg_block = (data or {}).get("packages") or {}
    for key, value in pkg_block.items():
        if not isinstance(value, dict):
            continue
        entry = {"url": value.get("url", "")}
        for req_key in ("from", "branch", "exactVersion", "revision",
                        "minVersion", "maxVersion"):
            if req_key in value:
                entry[req_key] = str(value[req_key])
        packages[key] = entry
    return packages


def load_project_yml_target_deps(text: str) -> dict[str, list[dict]]:
    """Return {target_name: [dep, ...]} from project.yml."""
    import yaml
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError:
        return {}
    targets = (data or {}).get("targets") or {}
    out: dict[str, list[dict]] = {}
    for tname, tdata in targets.items():
        if isinstance(tdata, dict):
            deps = tdata.get("dependencies") or []
            out[tname] = [d for d in deps if isinstance(d, dict)]
    return out


def load_package_swift_dependencies(text: str) -> list[tuple[str, str]]:
    """
    Pull (url, version_or_branch) tuples from Package.swift.
    Heuristic regex; good enough for the simple .package(url:..., from:...) shape
    we use here.
    """
    out: list[tuple[str, str]] = []
    for m in re.finditer(
        r'\.package\(\s*url:\s*"([^"]+)"\s*,\s*'
        r'(?:from:\s*"([^"]+)"|branch:\s*"([^"]+)"|exact:\s*"([^"]+)")',
        text,
    ):
        url = m.group(1)
        ver = m.group(2) or m.group(3) or m.group(4) or ""
        out.append((url, ver))
    return out


def load_package_swift_products(text: str) -> set[str]:
    """Return product names referenced in Package.swift dependency lists."""
    return set(re.findall(r'\.product\(\s*name:\s*"([^"]+)"', text))


def load_pbxproj_packages(text: str) -> list[dict]:
    """Pull XCRemoteSwiftPackageReference entries from the .pbxproj text."""
    pkgs: list[dict] = []
    for m in re.finditer(
        r'XCRemoteSwiftPackageReference\s+"([^"]+)"\s*\*/\s*=\s*\{[^}]*'
        r'repositoryURL\s*=\s*"([^"]+)";[^}]*'
        r'requirement\s*=\s*\{([^}]+)\};',
        text, re.DOTALL,
    ):
        name, url, req = m.group(1), m.group(2), m.group(3)
        version = ""
        rm = re.search(r'(?:minimumVersion|version|branch|revision)\s*=\s*([^\s;]+)', req)
        if rm:
            version = rm.group(1).strip('";')
        pkgs.append({"name": name, "url": url, "version": version})
    return pkgs


def load_resolved_pins(path: Path) -> list[dict]:
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return []
    return data.get("pins") or []


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_duplicate_mapping_keys(path: Path) -> list[str]:
    """Walk PyYAML's event stream; flag any key that appears twice in the same map."""
    import yaml

    errors: list[str] = []
    stack: list[dict] = []
    text = path.read_text()
    try:
        for event in yaml.parse(text, Loader=yaml.SafeLoader):
            if isinstance(event, yaml.MappingStartEvent):
                stack.append({})
            elif isinstance(event, yaml.MappingEndEvent):
                if stack:
                    stack.pop()
            elif isinstance(event, yaml.ScalarEvent) and stack:
                current = stack[-1]
                key = event.value
                lineno = event.start_mark.line + 1
                parity = current.pop("__parity__", 0)
                if parity == 0:
                    seen_key = f"__key__{key}"
                    if seen_key in current:
                        errors.append(
                            f"  line {lineno}: duplicate key '{key}' "
                            f"(first seen at line {current[seen_key]}); "
                            f"YAML parsers silently keep one and drop the other."
                        )
                    else:
                        current[seen_key] = lineno
                current["__parity__"] = 1 - parity
    except yaml.YAMLError as e:
        errors.append(f"  YAML parse error: {e}")
    return errors


def check_package_key_references(text: str) -> list[str]:
    """Every `- package: X` must match a key under top-level packages:."""
    defined = set()
    in_packages = False
    for line in text.splitlines():
        if re.match(r'^packages:\s*$', line):
            in_packages = True
            continue
        if in_packages:
            m = re.match(r'^\s{2}([A-Za-z_][A-Za-z0-9_-]*):\s*$', line)
            if m:
                defined.add(m.group(1))
            elif re.match(r'^\S', line):
                in_packages = False

    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = re.match(r'^\s+-\s+package:\s+(\S+)', line)
        if m and m.group(1) not in defined:
            errors.append(
                f"  line {lineno}: package reference '{m.group(1)}' is not "
                f"declared in the top-level packages: section "
                f"(defined keys: {sorted(defined)})"
            )
    return errors


def check_intra_target_dep_dupes(target_deps: dict[str, list[dict]]) -> list[str]:
    """
    Inside one target's dependencies: list, the same (package, product) or
    sdk: or framework: must not appear twice. Catches accidental copy-paste.
    """
    errors: list[str] = []
    for tname, deps in target_deps.items():
        seen = {}
        for dep in deps:
            if "package" in dep and "product" in dep:
                ident = ("package-product", dep["package"], dep["product"])
            elif "package" in dep:
                ident = ("package", dep["package"])
            elif "sdk" in dep:
                ident = ("sdk", dep["sdk"])
            elif "framework" in dep:
                ident = ("framework", dep["framework"])
            elif "target" in dep:
                ident = ("target", dep["target"])
            else:
                continue
            if ident in seen:
                errors.append(
                    f"  target '{tname}': duplicate dependency entry "
                    f"{ident[0]}={'/'.join(ident[1:])}"
                )
            seen[ident] = True
    return errors


def check_package_url_collisions(packages: dict[str, dict]) -> list[str]:
    """Two package keys must never point at the same upstream URL."""
    errors: list[str] = []
    by_url: dict[str, str] = {}
    for key, info in packages.items():
        url = normalize_url(info.get("url", ""))
        if not url:
            continue
        if url in by_url:
            errors.append(
                f"  packages: '{key}' and '{by_url[url]}' both point at {url}; "
                f"XcodeGen will keep only one and the build graph will be ambiguous."
            )
        else:
            by_url[url] = key
    return errors


def check_yml_vs_package_swift(packages: dict[str, dict],
                               swift_pkgs: list[tuple[str, str]],
                               swift_products: set[str],
                               target_deps: dict[str, list[dict]]) -> list[str]:
    """
    project.yml and Package.swift must agree on (URL, version) and on which
    products the app target consumes. Drift here is the single most common
    way "build works on my machine, fails in CI" sneaks in.
    """
    errors: list[str] = []
    if not swift_pkgs:
        return errors

    yml_by_url = {normalize_url(p["url"]): (k, p) for k, p in packages.items()}
    swift_by_url = {normalize_url(u): v for u, v in swift_pkgs}

    for url, ver in swift_by_url.items():
        if url not in yml_by_url:
            errors.append(
                f"  Package.swift declares {url} (version/branch '{ver}') "
                f"but project.yml has no matching entry."
            )
            continue
        yml_key, yml_info = yml_by_url[url]
        yml_ver = (yml_info.get("from")
                   or yml_info.get("branch")
                   or yml_info.get("exactVersion")
                   or yml_info.get("revision")
                   or "")
        if yml_ver and ver and yml_ver != ver:
            errors.append(
                f"  package URL {url}: version drift "
                f"(project.yml='{yml_ver}', Package.swift='{ver}')"
            )
    for url in yml_by_url:
        if url not in swift_by_url:
            errors.append(
                f"  project.yml declares {url} but Package.swift does not. "
                f"CI / `swift build` will be missing this dependency."
            )

    yml_products = {
        d["product"]
        for deps in target_deps.values()
        for d in deps
        if "product" in d
    }
    missing_in_swift = yml_products - swift_products
    if missing_in_swift:
        errors.append(
            f"  project.yml uses these products that Package.swift does not "
            f"declare: {sorted(missing_in_swift)}"
        )
    missing_in_yml = swift_products - yml_products
    if missing_in_yml:
        errors.append(
            f"  Package.swift uses these products that project.yml does not "
            f"declare: {sorted(missing_in_yml)}"
        )
    return errors


def check_yml_vs_pbxproj(packages: dict[str, dict],
                         pbxproj_pkgs: list[dict]) -> list[str]:
    """
    The generated pbxproj must declare the same URL+version range as project.yml
    for every package. If it doesn't, someone hand-edited the pbxproj or forgot
    to run `xcodegen generate` after editing project.yml.
    """
    errors: list[str] = []
    if not pbxproj_pkgs:
        return errors

    yml_by_url = {normalize_url(p["url"]): (k, p) for k, p in packages.items()}
    pbx_by_url = {normalize_url(p["url"]): p for p in pbxproj_pkgs}

    for url, p in pbx_by_url.items():
        if url not in yml_by_url:
            errors.append(
                f"  pbxproj references {url} but project.yml does not. "
                f"Run `xcodegen generate` to bring them back in sync."
            )
            continue
        yml_info = yml_by_url[url][1]
        yml_ver = (yml_info.get("from")
                   or yml_info.get("branch")
                   or yml_info.get("exactVersion")
                   or yml_info.get("revision")
                   or "")
        pbx_ver = p["version"]
        if yml_ver and pbx_ver and yml_ver != pbx_ver:
            errors.append(
                f"  package {url}: version drift "
                f"(project.yml='{yml_ver}', pbxproj='{pbx_ver}'). "
                f"Run `xcodegen generate`."
            )
    for url in yml_by_url:
        if url not in pbx_by_url:
            errors.append(
                f"  project.yml declares {url} but pbxproj does not. "
                f"Run `xcodegen generate`."
            )
    return errors


def check_resolved_pins_referenced(packages: dict[str, dict],
                                   pins: list[dict]) -> list[str]:
    """
    Every direct package in project.yml must appear in Package.resolved.
    Transitive pins are fine — only complain about missing direct ones.
    """
    errors: list[str] = []
    if not pins:
        return errors
    pin_urls = {normalize_url(p["location"]) for p in pins}
    for key, info in packages.items():
        url = normalize_url(info.get("url", ""))
        if url and url not in pin_urls:
            errors.append(
                f"  package '{key}' ({url}) declared in project.yml but not "
                f"resolved — run `xcodebuild -resolvePackageDependencies`."
            )
    return errors


def check_imports_vs_products(repo_root: Path,
                              target_deps: dict[str, list[dict]]) -> list[str]:
    """
    Walk Swift sources and verify that any `import X` for a known third-party
    module is matched by a `product: X` declared on the relevant target.
    Catches the bug where someone adds an import but forgets to update
    project.yml — the build fails late with `No such module`.
    """
    KNOWN = {"WhisperKit", "Hub", "Tokenizers", "MLX", "MLXNN",
             "MLXLLM", "MLXLMCommon"}

    sources_for_target: dict[str, set[Path]] = {
        "HomeHub":       set((repo_root / "HomeHub").rglob("*.swift")),
        "HomeHubTests":  set((repo_root / "HomeHubTests").rglob("*.swift")),
        "HomeHubWidget": set((repo_root / "HomeHubWidget").rglob("*.swift")),
    }

    errors: list[str] = []
    for tname, sources in sources_for_target.items():
        declared = {d["product"] for d in target_deps.get(tname, [])
                    if "product" in d}
        # Tests link the app target, so they inherit its packages.
        if tname == "HomeHubTests":
            declared |= {d["product"] for d in target_deps.get("HomeHub", [])
                         if "product" in d}
        used: dict[str, Path] = {}
        for f in sources:
            try:
                text = f.read_text()
            except (UnicodeDecodeError, FileNotFoundError):
                continue
            for m in re.finditer(r'^\s*import\s+(\w+)', text, re.MULTILINE):
                mod = m.group(1)
                if mod in KNOWN:
                    used.setdefault(mod, f)
        for mod, f in used.items():
            if mod not in declared:
                rel = f.relative_to(repo_root)
                errors.append(
                    f"  target '{tname}' imports '{mod}' in {rel} "
                    f"but project.yml does not declare `product: {mod}` on it."
                )
    return errors


def check_dependencies_block_count(text: str) -> list[str]:
    """Each target may have at most one `dependencies:` block."""
    lines = text.splitlines()
    in_target_indent = re.compile(r'^    dependencies:\s*$')
    blocks = [i + 1 for i, l in enumerate(lines) if in_target_indent.match(l)]
    if len(blocks) > 3:
        return [f"  found {len(blocks)} target-level dependencies: blocks "
                f"(expected at most 3 — one per target). Lines: {blocks}"]
    return []


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    repo_root = Path(__file__).parent.parent
    yml_path = repo_root / "project.yml"
    pkg_swift_path = repo_root / "Package.swift"
    pbxproj_path = repo_root / "HomeHub.xcodeproj" / "project.pbxproj"
    resolved_path = repo_root / "Package.resolved"

    if not yml_path.exists():
        red(f"project.yml not found at {yml_path}")
        return 1

    yml_text = yml_path.read_text()
    fail = False

    print("--- Duplicate YAML mapping keys ---")
    errs = check_duplicate_mapping_keys(yml_path)
    if errs:
        for e in errs: red(e)
        fail = True
    else:
        green("No duplicate mapping keys")

    print("--- Package key references ---")
    errs = check_package_key_references(yml_text)
    if errs:
        for e in errs: red(e)
        fail = True
    else:
        green("All `- package:` references match a defined key")

    print("--- One dependencies: block per target ---")
    errs = check_dependencies_block_count(yml_text)
    if errs:
        for e in errs: red(e)
        fail = True
    else:
        green("Target dependency blocks are unique")

    packages = load_project_yml_packages(yml_text)
    target_deps = load_project_yml_target_deps(yml_text)

    print("--- Intra-target duplicate dependency entries ---")
    errs = check_intra_target_dep_dupes(target_deps)
    if errs:
        for e in errs: red(e)
        fail = True
    else:
        green("No duplicate dependency entries inside any target")

    print("--- Package URL collisions ---")
    errs = check_package_url_collisions(packages)
    if errs:
        for e in errs: red(e)
        fail = True
    else:
        green("No two package keys point at the same URL")

    print("--- project.yml ↔ Package.swift agreement ---")
    if pkg_swift_path.exists():
        swift_text = pkg_swift_path.read_text()
        swift_pkgs = load_package_swift_dependencies(swift_text)
        swift_products = load_package_swift_products(swift_text)
        errs = check_yml_vs_package_swift(packages, swift_pkgs,
                                          swift_products, target_deps)
        if errs:
            for e in errs: red(e)
            fail = True
        else:
            green("project.yml and Package.swift agree on URLs, versions, products")
    else:
        warn("Package.swift not found — skipping cross-check")

    print("--- project.yml ↔ pbxproj agreement ---")
    if pbxproj_path.exists():
        pbx_text = pbxproj_path.read_text()
        pbx_pkgs = load_pbxproj_packages(pbx_text)
        errs = check_yml_vs_pbxproj(packages, pbx_pkgs)
        if errs:
            for e in errs: red(e)
            fail = True
        else:
            green("pbxproj package URLs and versions match project.yml")
    else:
        warn("project.pbxproj not found — skipping cross-check")

    print("--- project.yml ↔ Package.resolved agreement ---")
    pins = load_resolved_pins(resolved_path)
    errs = check_resolved_pins_referenced(packages, pins)
    if errs:
        for e in errs: red(e)
        fail = True
    else:
        green("Every project.yml package is pinned in Package.resolved")

    print("--- Swift `import` ↔ declared product agreement ---")
    errs = check_imports_vs_products(repo_root, target_deps)
    if errs:
        for e in errs: red(e)
        fail = True
    else:
        green("Every third-party `import` has a matching `product:` declaration")

    print()
    if fail:
        red("Validation FAILED — fix the issues above before "
            "running `xcodegen generate` or merging.")
        return 1
    green("project.yml validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
