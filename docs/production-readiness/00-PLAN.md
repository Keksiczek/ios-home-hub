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
| 0 | Recon, baseline build, docs skeleton | **done** |
| 1 | Wire kernel entitlements end-to-end | **done** — `141b393` |
| 2 | Recalibrate memory budgets for the entitled build | **partial** — GPU pool + generous window done; moderate tier open (F-104) |
| 3 | Answer quality (prompt, sampling, templates) | **partial** — F-202, F-204 done; F-201, F-203 open |
| 4 | Production readiness (security, silent failures, tests, docs) | **partial** — F-303, F-401/402/403/405, plist + manifest done |

Rounds are not strictly sequential — findings from the parallel review agents
land continuously and get triaged into `01-FINDINGS.md`.

### Session 1 outcome

4 commits on `production-readiness/2026-07`, all building green, test suite
unchanged from baseline (613 pass / 32 fail, identical failing set — see F-007).

Closed: F-001, F-002, F-003, F-004, F-102, F-108, F-202, F-204, F-303,
F-304, F-401, F-402, F-403, F-405, F-101 (partial), F-104 (generous half),
plus the privacy manifest.

The two headline blockers were both cases of *a correct comment sitting above a
declaration that did nothing*: the entitlement flag had no wiring path, and
seven privacy strings never reached the bundle. A third instance
(`UIBackgroundModes`) was found by the guardrail written to prevent the first two.

### Session 2 outcome (2026-07-23, afternoon)

Owner supplied device diagnostics and confirmed the **Apple Developer Program
membership is now active**. Two commits: `f0ecfcc`, `92a6c17`.

Device data falsified two Session-1 assumptions — the entitlement ratio test
(unentitled iPhone 16 Pro reports 74.9 % of physical RAM, so the 0.48 threshold
gave a false "granted") and the tier thresholds (generous was unreachable on any
8 GB device regardless of entitlements). Both corrected: tiers now key off the
**measured** process limit, and the entitlement flag is used only for the mmap
ceiling, which is the one thing measurement cannot see.

Closed since: **F-201** (prompt budget with priority shedding), **F-203**
(`.tool` role, plumbed to MLX's native `Chat.Message.Role.tool`), **F-103**
(entitlement-aware catalog gating + two missing `requiresLargeMmapAddressing`
flags), **F-212** (bullet-point mimicry), **F-213** (unreachable generous tier).

Full suite: 625 pass / 32 fail, failing set identical to baseline.

### Session 3 outcome (2026-07-23, evening)

Full Apple Developer access confirmed active. Commit `e650cf3`.

Model catalog refreshed against the **live Hugging Face API** — it was a
generation behind, missing the entire Qwen3 line, Gemma 3, LFM2.5 and current
Qwen3-VL vision models. Eight entries added with verified sizes and shard
layouts. Adding them surfaced three latent bugs that would have made the new
models silently misbehave (exact-match family switches for stop sequences and
VLM detection, plus `recommendedStarter` depending on array order).

**F-301 closed** via an information-flow guard rather than injection detection.

Full suite: 638 pass / 32 fail, failing set identical to baseline.

### Highest-value work remaining

1. **F-007** — fix the crashing test double first (`FakeMLXLoader.swift:79`) so
   the suite becomes a trustworthy signal, then the stale assertions.
2. **F-101 rest** — `baselineCacheLimitBytes` / `currentCacheTier` still
   unguarded across three concurrent contexts; needs a TSan pass.
3. **F-302** — Lock Screen widget leaks replies + personal memory facts, with no
   setting to disable or redact.
4. **F-205** — summarizer input uncapped, skips the context guard, success
   judged by `!isEmpty`.
5. **F-206** — Phi-3 rendered as ChatML in the fallback template path.
6. **F-406..F-410** — remaining silent-failure sites.
7. **Skill naming** — `RemindersSearch` / `HomeKitSearch` both write despite
   their names, and are on by default. Needs an `enabledTools` migration.

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

## Questions — answered

1. ~~`git init`?~~ **Done.** Branch `production-readiness/2026-07`, remote
   `github.com/Keksiczek/ios-home-hub`. Local tree was identical to
   `origin/main` (271a7f6) at baseline.
2. ~~Distribution target?~~ **App Store**, paid account, all users. So the
   entitlements ship to everyone; the free-tier path is a safety fallback, not
   the design centre.
3. ~~Primary device?~~ **iPhone 16/17 Pro (8 GB)** and **iPad M1**. Both are
   `generous`-tier candidates, which is what the Round 2 tuning targets.

## Open question — needs a product decision

4. **F-301: should state-changing skills require explicit confirmation?**

   Today a fetched web page can cause a Reminder to be created, or a HomeKit
   accessory to be toggled, with **no user confirmation** — the model emits a
   tool call and `SkillManager.run` executes it. `enabledTools` is a
   session-level Settings allow-list, not a per-call gate. It is also reachable
   via Siri through `AskHomeHubIntent` without the app ever appearing, and the
   ephemeral conversation is deleted afterwards, leaving no trace.

   Three options, in order of preference:

   a. **Confirm state-changing skills only.** Read-only skills (`WebSearch`,
      `FetchPage`, `HomeKitSearch` status, `Calculator`) stay automatic;
      anything that writes (Reminders create, HomeKit set, Calendar create)
      shows a one-tap confirmation. `WidgetActionHandler` already works this
      way, so there is a pattern to follow.
   b. **Confirm only after untrusted content.** Refuse to auto-execute a tool
      call emitted in the turn immediately following an `<Observation>` that
      carried fetched web content. Preserves the agentic feel for pure-chat
      turns; narrower protection.
   c. **Accept the risk**, and disable `FetchPage`/`WebSearch` by default so
      untrusted content only enters when the user opts in.

   This is not something to change silently — it alters the core agentic UX,
   which is the app's whole point. Deliberately left for the owner.
