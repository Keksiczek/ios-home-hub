# Kernel Entitlements — Design & Verification

Supersedes the setup procedure in `KERNEL_ENTITLEMENTS.md`, which described a
path that could not work (see "What was broken" below). The background material
in that document — what the entitlements do, the sideload matrix, the Jetsam
explanation — is still accurate and worth keeping.

---

## What the app now does

```
kernelEntitlementsEnabled = kernelEntitlementsDeclared && kernelEntitlementsGranted
```

| Half | Source | Answers |
|---|---|---|
| `kernelEntitlementsDeclared` | `#if HOMEHUB_HAS_KERNEL_ENTITLEMENTS` | "Does this build *intend* to be entitled?" |
| `kernelEntitlementsGranted` | derived jetsam limit vs. physical RAM | "Is the kernel *actually* granting it?" |

Both halves are required, deliberately:

- **The compile flag alone over-promises.** Apple's signing server silently
  strips restricted entitlements from builds signed by a team lacking the
  capability. The `.entitlements` file still lists them and the flag is still
  set, so the binary runs believing it has ~5 GB of headroom — and jetsams the
  moment a large model maps in. This happens with a free Apple ID, with a
  provisioning profile generated before the capability was added, and with
  re-signed builds.
- **The runtime signal alone would under-promise and misfire.** It would let a
  build that never declared the capability opportunistically use budgets it was
  never tested against, and it would misread a device whose limit happens to sit
  near the threshold for unrelated reasons.

## How `kernelEntitlementsGranted` works

```swift
limit  = task_vm_info.phys_footprint + os_proc_available_memory()
ratio  = limit / ProcessInfo.processInfo.physicalMemory
granted = ratio >= 0.48
```

`phys_footprint` is the counter jetsam actually evaluates, and
`os_proc_available_memory()` is the remaining headroom before termination. Their
sum is the effective limit — and it is **time-invariant**: as the app allocates,
footprint rises and available falls by the same amount. So this can be evaluated
at any point in the lifecycle. Sampling `os_proc_available_memory()` alone at
launch would not survive a model being loaded.

Threshold **0.48** sits in the gap between the two observed bands:

| State | Process limit as a fraction of physical RAM | 8 GB device |
|---|---|---|
| Unentitled | ~0.33 – 0.40 | ≈ 3 GB |
| Entitled | ~0.55 – 0.75 | ≈ 5 GB |

Simulator is excluded — it inherits the host Mac's limits, so the ratio would
report "entitled" on any Mac with more RAM than the simulated device. There the
declared flag is honoured so tier-dependent code paths still get exercised in
development and in the simulator-hosted test suite.

### Two approaches that were tried and do not work

Recorded so nobody spends the afternoon re-discovering them.

1. **`SecTaskCreateFromSelf` + `SecTaskCopyValueForEntitlement`** — the obvious
   "just read the signature" answer, and it is genuinely the right API on macOS.
   The symbol is present in `Security.tbd` so it *links*, but `SecTask.h` ships
   macOS-only, so `import Security` does not declare it on iOS. Verified by
   test-compiling against the iOS 26.2 SDK:

   ```
   error: cannot find 'SecTaskCreateFromSelf' in scope
   ```

   Reaching it via `@_silgen_name` would work mechanically but is an
   undeclared-API pattern that is not worth the App Review risk.

2. **Parsing `embedded.mobileprovision`** — works for development, ad-hoc and
   enterprise builds. Useless here: **App Store builds contain no embedded
   provisioning profile**, so it fails in exactly the distribution case that
   matters.

The effective limit is in any case the more relevant signal than the signature:
it is what jetsam enforces, whatever the entitlement dictionary happens to say.

---

## What was broken

`KERNEL_ENTITLEMENTS.md` step 4 and `LocalOverride.xcconfig.template` both
instructed the developer to set the flag in `LocalOverride.xcconfig`. But
`project.yml` had removed the `configFiles:` wiring that would make that file
part of the build (to stop pbxproj drift breaking the CI guard), and nothing
replaced it. The generated project confirmed it:

```
$ grep -c baseConfigurationReference HomeHub.xcodeproj/project.pbxproj
0
```

No xcconfig was attached to any build configuration, so the documented procedure
was a no-op. `kernelEntitlementsEnabled` was permanently `false`, which meant:

- `MemoryTier.generous` was unreachable — an 8 GB iPhone 16 Pro silently
  demoted to `moderate`.
- `imageTokenBudget` pinned at 70 instead of 256.
- MLX GPU cache 200 MB instead of 512 MB; batch 256 instead of 512;
  micro-batch 64 instead of 128.
- The 2.1 GB single-shard mmap refusal in `MLXRuntime` always fired, rejecting
  large single-shard models with an error telling the user to buy a paid
  account — which they had.

Two further bugs meant that even *fixing* the flag would not have delivered the
full benefit, because neither had ever been exercised:

- `HardwareCapabilities` capped A18 / M-series at 256 MB while its own comment
  said "no SoC-side cap", and call sites take `min(memoryBudget, hardwareBudget)`.
  So `min(512, 256)` would have defeated the generous GPU pool on exactly the
  hardware the tier was written for.
- The generous tier declared the same 4096-token context as moderate while
  doubling the history budget, and MLX enforces no `n_ctx`, so the assembled
  prompt could quietly exceed the window.

---

## Setup, current

The flag and both entitlement keys are declared in `project.yml` and committed.
There is nothing per-developer left to configure. After a fresh clone:

```bash
make setup
```

To build and run on a device, the only requirement is that the signing team
matches. `DEVELOPMENT_TEAM` is set to `8Y755TXDN8` in `project.yml`; forks
should change it there or override on the command line:

```bash
xcodebuild -project HomeHub.xcodeproj -scheme HomeHub DEVELOPMENT_TEAM=YOURTEAMID
```

> **Status 2026-07-23: the Apple Developer Program membership is active.** The
> entitlements will be granted once the capabilities are added to the App ID —
> see the step below. Until Xcode has regenerated the provisioning profile, the
> build still runs correctly with the mmap ceiling in force.

### One-time Apple Developer portal step

The entitlements are only granted if the App ID has the capabilities enabled.
In Xcode → the **HomeHub** target → **Signing & Capabilities**, add:

- **Increased Memory Limit**
- **Extended Virtual Addressing**

Xcode regenerates the provisioning profile. If it refuses, the account is not on
the paid program or the App ID needs the capability added manually at
[developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers).

> These capabilities **are** permitted for App Store distribution, so every user
> of a store build gets them — not only local development installs.

---

## Verification

### On device (the only place this is real)

Run the app and read the Console line emitted at startup by
`DeviceMemoryProvider`:

```
Device memory profile:
  physical: 8GB
  usable: 6GB
  proc budget now: 4900MB          ← ~5 GB means entitled; ~3 GB means not
  tier: generous (8GB+)            ← 'moderate' here means it did not take
  context: 8192 tokens
  batch: 512 tokens
  ubatch: 128 tokens
  mlx cache: 512MB
  image budget: 256 tokens
  entitlements: active — process limit 5012 MB, generous memory budgets
```

The `entitlements:` line is the summary to read first. Its three failure modes
are distinguished on purpose:

| Message | Meaning | Action |
|---|---|---|
| `active — process limit N MB, generous memory budgets` | Working. | none |
| `DECLARED BUT NOT GRANTED — process limit only N MB` | Signing server stripped them. | Regenerate the provisioning profile with **both** capabilities. |
| `not declared` | Build flag absent. | Check `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. |
| `declared; not verifiable on Simulator` | Expected on simulator. | none |

The same summary is surfaced in **Settings → Developer Diagnostics**.

### At build time

```bash
plutil -p HomeHub/HomeHub.entitlements
```

must show both kernel keys. And after `make build`:

```bash
make check-plist
```

asserts the built `Info.plist` carries every key the app depends on. That script
exists because three separate Info.plist bugs shipped in this project while
looking correct in `project.yml`, in the pbxproj, and in
`xcodebuild -showBuildSettings`. **The bundle is the only source of truth.**

---

## Catalog gating (F-103) — done

The static `recommendedFor: [.iPadMSeries]` on Gemma 3n E2B/E4B, Mistral 7B,
Llama 3.1 8B, Qwen2-VL 7B and Phi 3.5 Mini is a compile-time literal, so it
could never know whether the running build was entitled. Several of those
entries carried comments saying to revisit the gating "when entitlements ship".

`LocalModel.effectiveRecommendedFor` now resolves it at runtime, adding
`.iPhone` only when **both** hold:

1. the build declares the kernel entitlements — without
   `extended-virtual-addressing` a >2 GB shard cannot be mapped at all, so
   recommending the model would send the user through a multi-GB download to a
   guaranteed failure; and
2. the device measures into the `generous` tier — the real headroom question,
   measured rather than assumed.

It only ever *widens* the list, so nothing previously recommended stops being
so. Consumed by `ModelsView.isRiskyOnPhone` and the browser's "iPhone safe"
filter. Purely advisory: the binding checks remain `MLXRuntime`'s per-shard
mmap pre-flight and `RuntimeManager.evaluateFeasibility`.

Also set `requiresLargeMmapAddressing: true` on **Mistral 7B v0.3** (4.1 GB) and
**Llama 3.1 8B** (4.5 GB), which were missing it while same-size-class siblings
had it — so a non-entitled user got no warning and found out only after
downloading ~4 GB.

> Erring towards `true` on an unverified shard layout is the safe direction: a
> false positive costs one advisory line, a false negative costs a 4 GB
> download. To confirm, check whether the repo has a
> `model.safetensors.index.json` (absent ⇒ single shard) and clear the flag if
> either turns out to be sharded.

## Still to do

Nothing blocking. Remaining entitlement-adjacent items are in `01-FINDINGS.md`:
the per-shard ceiling constant (`sandboxedSingleShardCeilingBytes`) is still a
single source of truth and correct; `MLXRuntime`'s pre-flight already no-ops
once entitled.
