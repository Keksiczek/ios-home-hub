# HomeHub — Production Readiness Programme

**Started:** 2026-07-23
**Trigger:** Owner upgraded to a **paid Apple Developer Program** membership
(Team ID `8Y755TXDN8`, Individual — "Štěpán Kesner"), which unlocks the two
kernel entitlements the whole memory architecture was designed around but
could never actually use.

**Goals, in the owner's words:**
1. Land everything reasonable the paid membership unlocks.
2. Kill the OOM problems (`spatne OOM problemy`).
3. Fix bad model answers (`spatne odpovedi`).
4. Get the app genuinely production-ready.

This folder is the **cross-round memory**. Every round reads it first and
writes to it last, so a fresh session picks up with full context.

| File | Purpose |
|---|---|
| `00-PLAN.md` | This file. Round structure, decisions, open questions. |
| `01-FINDINGS.md` | Findings register. Every issue, with severity + status. |
| `02-PROGRESS.md` | Chronological changelog. What actually changed, per round. |
| `03-ENTITLEMENTS.md` | The entitlement work specifically — design + verification. |

---

## Environment baseline (verified 2026-07-23)

| Fact | Value |
|---|---|
| Xcode | 26.2 (17C52) |
| Swift | 6.0 (project setting) |
| Deployment target | iOS 17.0 |
| Signing identity | `Apple Development: skesnercz@gmail.com (MHCMT64ZTD)` |
| **Team ID** | **`8Y755TXDN8`** |
| Cert validity | 2026-04-11 → 2027-04-11 |
| Provisioning profiles on disk | **none yet** — Xcode has not fetched a profile for the paid team |
| Version control | **none — this is not a git repository** |
| Source size | 224 Swift files, ~61.4 kLOC |
| Project generator | XcodeGen (`project.yml` is source of truth) |
| Local lint tooling | `swiftlint` / `swiftformat` **not installed** (`.swiftlint.yml` exists) |

### ⚠️ Blocking risk: no version control

There is no `.git` here. A multi-round refactor with no way to diff or revert
is dangerous. **Recommendation: `git init` + an initial commit before Round 1
lands any change.** Until that happens, changes are described exhaustively in
`02-PROGRESS.md` so they can be reverted by hand.

---

## Round structure

| Round | Theme | Status |
|---|---|---|
| 0 | Recon, baseline build, docs skeleton | in progress |
| 1 | Wire kernel entitlements end-to-end | pending |
| 2 | Recalibrate memory budgets for the entitled build | pending |
| 3 | Answer quality (prompt, sampling, templates) | pending |
| 4 | Production readiness (security, silent failures, tests, docs) | pending |

Rounds are not strictly sequential — findings from the parallel review agents
land continuously and get triaged into `01-FINDINGS.md`.

---

## Headline discovery from Round 0

**`HOMEHUB_HAS_KERNEL_ENTITLEMENTS` could never be turned on as documented.**

`KERNEL_ENTITLEMENTS.md` Step 4 and `LocalOverride.xcconfig.template` both tell
the developer to set the flag in `LocalOverride.xcconfig`. But `project.yml`
lines 123–136 explicitly removed the `configFiles:` wiring (to stop pbxproj
drift breaking the CI drift guard), and the generated project confirms it:

```
$ grep -c baseConfigurationReference HomeHub.xcodeproj/project.pbxproj
0
```

No xcconfig is attached to any build configuration. So the documented
procedure is a no-op: the developer edits the file, rebuilds, and
`DeviceMemoryProvider.kernelEntitlementsEnabled` stays `false` forever.
Every consequence follows from that — the `generous` tier is unreachable,
the 2.1 GB single-shard mmap refusal always fires, and the image token
budget is permanently pinned at 70.

This is fixed in Round 1. See `03-ENTITLEMENTS.md`.

---

## Design decisions

### D1 — Compile-time flag AND runtime entitlement check (Round 1)

`DeviceMemoryProvider`'s doc comment argues for a compile-time flag because
"runtime mmap probes are unreliable". That reasoning is sound *for mmap
probes*, but it concluded too much: we can ask the kernel directly what
entitlements the running binary was signed with, via
`SecTaskCreateFromSelf` + `SecTaskCopyValueForEntitlement`. That is not a
probe — it is the authoritative answer.

**Decision:** gate the generous tier on `compileTimeFlag && runtimeEntitlement`.

- Compile-time flag = "this build *intends* to be entitled".
- Runtime check = "Apple's signing server actually granted it".

This closes the exact failure mode that makes the entitlement dangerous:
the entitlement silently stripped at signing time (free account, wrong
profile, TestFlight re-sign) while the binary still believes it has
generous headroom — and then jetsams on the user's first big model.

### D2 — Wire the flag in `project.yml`, not in an xcconfig (Round 1)

The xcconfig indirection is what broke. `project.yml` is the single source of
truth for this project and is regenerated deterministically. The flag goes
there, guarded by D1's runtime check so an unentitled build is still safe.

---

## Open questions for the owner

1. **`git init`?** Strongly recommended before more changes land.
2. **Distribution target** — App Store / TestFlight, or personal device install
   only? This changes how strict Round 4 needs to be about privacy strings,
   the iCloud container, and the free-tier fallback path.
3. **Which physical device** is the primary target? The memory tiers in
   Round 2 are calibrated per-device, and knowing the real one (iPhone 16 Pro?
   iPhone 17 Pro? iPad?) lets us tune rather than guess.
