# Findings Register

Status legend: `OPEN` · `FIXED` · `WONTFIX` · `NEEDS-DEVICE` (only verifiable on hardware)

Severity: **CRITICAL** (crash / data loss / store rejection) · **HIGH** (broken
feature or the reported OOM / bad-answer symptoms) · **MEDIUM** (correctness or
maintainability) · **LOW** (polish).

---

## Round 0 — own analysis

### F-001 · CRITICAL · Privacy usage descriptions never reach `Info.plist`
**Status:** OPEN
**Where:** `project.yml:256-269`

Seven privacy strings are declared as bare build settings:

```yaml
NSMicrophoneUsageDescription: "…"
NSSpeechRecognitionUsageDescription: "…"
NSHomeKitUsageDescription: "…"
NSCalendarsUsageDescription: "…"
NSCalendarsFullAccessUsageDescription: "…"
NSRemindersUsageDescription: "…"
NSRemindersFullAccessUsageDescription: "…"
```

The target uses `GENERATE_INFOPLIST_FILE: YES`. Xcode's generated-plist mechanism
only injects build settings whose name starts with **`INFOPLIST_KEY_`**. Every
other key in this file that needs to reach the plist has the prefix
(`INFOPLIST_KEY_UILaunchScreen_Generation`, `INFOPLIST_KEY_BGTaskScheduler…`,
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`, …). These seven do not, so they
land in the pbxproj as inert build settings and never appear in the bundle:

```
$ grep -n NSMicrophoneUsageDescription HomeHub.xcodeproj/project.pbxproj
1501:  NSMicrophoneUsageDescription = "Potřebujeme mikrofon…";   ← build setting, not plist
```

**Consequences**
- `VoiceService` requesting mic or `SFSpeechRecognizer` authorisation → iOS
  terminates the process immediately (`TCC` crash, not a catchable error).
- The HomeKit / Calendar / Reminders skills crash on first invocation — and the
  comment at `project.yml:258-264` explicitly states the app relies on these
  being present because *the prompt assembler advertises the skills to the model*,
  so the model can trigger them unprompted.
- Automatic App Store rejection.

The irony: the comment block above these lines correctly explains why the keys
are mandatory, and then declares them in the one form that does nothing.

**Fix:** prefix all seven with `INFOPLIST_KEY_`, regenerate, and assert the keys
are present in the built `Info.plist` in `make check`.

---

### F-002 · CRITICAL · `HOMEHUB_HAS_KERNEL_ENTITLEMENTS` is unreachable
**Status:** OPEN
**Where:** `project.yml:123-136` + `KERNEL_ENTITLEMENTS.md` step 4 + `LocalOverride.xcconfig.template:81`

Both documents instruct the developer to set the flag in `LocalOverride.xcconfig`.
`project.yml` removed the `configFiles:` wiring that would make that file part of
the build, and the generated project confirms nothing is attached:

```
$ grep -c baseConfigurationReference HomeHub.xcodeproj/project.pbxproj
0
```

So the documented procedure is a no-op. `DeviceMemoryProvider.kernelEntitlementsEnabled`
is permanently `false`, which means:

- `MemoryTier.generous` is **unreachable** (`DeviceMemoryProvider.swift:195-198`) —
  an 8 GB iPhone 16 Pro is silently demoted to `moderate`.
- `imageTokenBudget` is pinned at 70 instead of 256 (`DeviceMemoryProvider.swift:237`).
- `mlxGPUCacheLimitBytes` is 200 MB instead of 512 MB (`:234` vs `:250`).
- `batchSizeTokens` 256 instead of 512, `microBatchSizeTokens` 64 instead of 128.
- The 2.1 GB single-shard mmap refusal in `MLXRuntime.swift:559-575` **always**
  fires, so large single-shard models are rejected with a Czech error telling
  the user to buy a paid account — which they now have.

This is the root cause of "the paid account unlocked nothing".

**Fix:** Round 1 — see `03-ENTITLEMENTS.md`.

---

### F-003 · HIGH · `LocalOverride.xcconfig.template` would clobber its own flags
**Status:** OPEN
**Where:** `LocalOverride.xcconfig.template:81` and `:88`

Both the kernel-entitlements block and the llama.cpp block assign
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`. In xcconfig semantics `$(inherited)`
resolves against *lower-priority configuration layers*, **not** against an
earlier assignment in the same file — the later line simply wins. A developer
following the comments and uncommenting both would silently lose
`HOMEHUB_HAS_KERNEL_ENTITLEMENTS` and never know.

Moot once F-002 is fixed by removing the xcconfig path entirely, but the
template must stop teaching the broken pattern.

---

### F-004 · MEDIUM · `Makefile` targets a simulator that does not exist
**Status:** OPEN
**Where:** `Makefile:15`

```make
DEST = platform=iOS Simulator,name=iPhone 16
```

Xcode 26.2 on this machine has iPhone 17, 17 Pro, 17 Pro Max, Air, 16e — no
plain "iPhone 16". `make build` and `make test` fail before compiling anything.
CI presumably pins its own destination, so this only bites local development —
which is exactly where it costs the most time.

**Fix:** resolve a destination dynamically, or pin to a generic simulator
destination that does not name a device.

---

### F-005 · MEDIUM · No version control
**Status:** OPEN

`/Users/keks/Developer/ios-home-hub-main` is not a git repository, yet the repo
ships `.gitignore`, `.github/`, a CI drift guard, and `git`-oriented docs. A
multi-round refactor with no diff/revert is a standing risk.

**Fix:** `git init` + baseline commit before further changes land.

---

### F-006 · LOW · Lint tooling documented but absent
**Status:** OPEN

`.swiftlint.yml` is committed; `swiftlint` and `swiftformat` are not installed on
this machine, so no style gate runs locally.

---

*(Findings F-1xx from the memory/OOM agent, F-2xx from the answer-quality agent,
F-3xx from the security agent and F-4xx from the silent-failure agent are appended
as those reviews land.)*
