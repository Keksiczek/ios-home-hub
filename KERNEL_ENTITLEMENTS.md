# Kernel Entitlements: Advanced Memory Optimization

## Overview

HomeHub includes two powerful kernel entitlements that significantly improve LLM performance on memory-constrained devices. However, these are **restricted to paid Apple Developer accounts**.

| Entitlement | Effect | Requirement |
|---|---|---|
| `increased-memory-limit` | Allows app to allocate more memory before Jetsam OOM | Paid Developer Account |
| `extended-virtual-addressing` | Enables 64-bit virtual addressing for larger memory pools | Paid Developer Account |

## Performance Impact

With these entitlements enabled:
- **iPhone SE**: Up to 2x more conversational history (600 → 1200 tokens)
- **iPhone 16 Pro**: 4x larger context windows (2048 → 4096 tokens)
- **iPad Pro**: Full 4096-token conversations without KV cache trimming

**Without these entitlements**, the app still works but uses more conservative memory allocations to prevent Jetsam crashes.

## Prerequisites

1. **Apple Developer Program membership** (paid: $99/year)
   - Free/personal accounts cannot use these entitlements
2. **Team ID** from your Apple Developer account
3. **Provisioning profile** with these capabilities enabled

## Setup Instructions

### Step 1: Verify Developer Account

1. Go to [developer.apple.com](https://developer.apple.com)
2. Sign in with your Apple ID
3. Check your **Membership** page — you should see:
   - Status: "Active"
   - Enrollment type: "Individual" or "Company/Organization"

If you see "Personal Team" or no enrollment, you have a free account. **These entitlements are unavailable** — skip to "Free Account Workarounds" below.

### Step 2: Enable Capabilities in Xcode

1. Open `HomeHub.xcodeproj` in Xcode
2. Select the **HomeHub** target
3. Go to **Signing & Capabilities**
4. Click **+ Capability** and add:
   - "Increased Memory Limit"
   - "Extended Virtual Addressing"
5. Xcode will attempt to auto-generate a new provisioning profile

**Expected result**: Green checkmarks next to both capabilities.

**If you see errors** like "Personal development teams don't support…":
- You have a free developer account (see below)
- These entitlements cannot be used

### Step 3: Update the entitlements file

Edit `HomeHub/HomeHub.entitlements` and add the two kernel keys:

```xml
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.cz.keksiczek.homehub.shared</string>
	</array>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
</dict>
```

### Step 4: Enable the Swift compiler flag

Edit (or create) `LocalOverride.xcconfig` and add:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID

// Kernel entitlements are active — unlock generous memory tier
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) HOMEHUB_HAS_KERNEL_ENTITLEMENTS
```

This activates `DeviceMemoryProvider.kernelEntitlementsEnabled = true` at compile
time, which unlocks the `generous` memory tier (4096-token context, 128 MB MLX cache,
256-token image budget) on flagship devices.

> **Why a compile-time flag?** Runtime mmap probes are unreliable — iOS may succeed
> on small test allocations but still crash on model-sized (3–8 GB) allocations.
> Compile-time mirrors what's actually embedded in the provisioning profile.

### Step 5: Rebuild & Test

```bash
make clean
make setup
open HomeHub.xcodeproj
# Build and run on device
```

You should see no provisioning profile errors.

## Verification

To confirm the entitlements are active:

1. Run the app on your device
2. Open Settings → Models → (select a model)
3. In the debug console, you'll see:
   ```
   Device memory profile:
     physical: 8GB
     usable: 6GB
     tier: generous
     context: 4096 tokens  ← Full context (only possible with entitlements)
     batch: 512 tokens
     ubatch: 128 tokens
   ```

Without entitlements, the context will be capped at 2048 tokens even on a high-memory device.

## Free Account Workarounds

If you have a personal/free developer account, you have two options:

### Option 1: Use Conservative Memory Settings (Current Default)

The app automatically detects your account type and uses reduced memory allocations:
- iPhone SE: 600 tokens safe history
- iPhone 16 Pro: 1400 tokens safe history
- iPad Pro: 2800 tokens safe history

This is stable but doesn't maximize performance. **No changes needed** — just build normally.

### Option 2: Upgrade to Paid Developer Account

The annual $99 Apple Developer Program membership includes:
- Unlimited app distribution
- Advanced device testing
- Direct Apple support
- Access to restricted entitlements like these kernel capabilities

If you plan to distribute the app via TestFlight or the App Store, you need the paid membership anyway.

## Technical Details

### Why These Entitlements Matter for LLMs

Local LLMs on Apple Silicon use **KV cache** — a large buffer of past token states that grows with conversation length.

**Without entitlements**:
- Jetsam aggressively kills background processes
- LLM context is capped to prevent cache explosion
- Long conversations get trimmed

**With entitlements**:
- App gets extra memory headroom before Jetsam intervention
- Extended virtual addressing allows larger single allocations
- Conversations can be longer without aggressive trimming
- Better performance on multi-turn interactions

### Memory Architecture

```
┌─────────────────────────────────┐
│ Physical Device Memory          │
│ (e.g., 8 GB on iPhone 16 Pro)   │
└──────────────┬──────────────────┘
               │
     ┌─────────▼─────────┐
     │ Usable (75%)      │  ← DeviceMemoryProvider estimates
     │ ~6 GB on iPhone   │
     └─────────┬─────────┘
               │
     ┌─────────▼─────────────────────┐
     │ Jetsam Memory Threshold        │
     │ (before kill signals trigger)  │
     │                                 │
     │ Without entitlements: 4.8 GB   │
     │ With entitlements: 5.8 GB      │
     └────────────────────────────────┘
```

The kernel entitlements raise the Jetsam threshold, giving the app more breathing room.

### Provisioning Profile Requirements

Your provisioning profile must include:
- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`

Xcode generates this automatically when you add the capabilities, but you can verify manually:

1. Visit [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles)
2. Find your provisioning profile for `cz.keksiczek.homehub`
3. Click **Edit** and scroll to "Capabilities"
4. Both kernel entitlements should be listed

If missing, **regenerate** the profile in Xcode:
```
Signing & Capabilities → Provisioning Profile → [Manage] → Delete & Recreate
```

## Troubleshooting

### "Personal development teams don't support Extended Virtual Addressing"

**Cause**: You have a free/personal Apple ID account.
**Solution**: Upgrade to the paid Apple Developer Program ($99/year).

### Provisioning Profile Errors After Adding Capabilities

**Cause**: Xcode's auto-provisioning failed to regenerate the profile.
**Solution**:
1. In Xcode: **Signing & Capabilities** → **Provisioning Profile** → click the dropdown
2. Select **Manage Provisioning Profiles**
3. Find your profile and click the delete (−) button
4. Close the window; Xcode will auto-regenerate
5. Rebuild

### App Still Uses Capped Context After Adding Entitlements

**Cause**: Entitlements are in `.entitlements` file but not in the provisioning profile.
**Solution**:
1. Verify the provisioning profile includes both capabilities (see verification above)
2. Delete and regenerate the profile in Xcode
3. Clean build folder: **Cmd+Shift+K**
4. Rebuild

## Related Documentation

- [OPTIMIZATION_GUIDE.md](OPTIMIZATION_GUIDE.md) — Performance tuning strategy
- [DeviceMemoryProvider.swift](HomeHub/Services/DeviceMemoryProvider.swift) — Memory tier detection logic
- [ModelCapabilityProfile.swift](HomeHub/Runtime/ModelCapabilityProfile.swift) — Per-model resource budgets

---

**Last Updated**: May 2026  
**Status**: Available for paid developer accounts  
**Next Review**: When Apple releases new memory management features
