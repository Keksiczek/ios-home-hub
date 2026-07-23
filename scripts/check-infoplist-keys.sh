#!/usr/bin/env bash
#
# Guardrail: every Info.plist key the app needs must actually reach the bundle.
#
# WHY THIS EXISTS
#
# The target builds its Info.plist with GENERATE_INFOPLIST_FILE=YES. Xcode only
# injects build settings whose name starts with INFOPLIST_KEY_. A setting named
# `NSMicrophoneUsageDescription` (no prefix) is therefore accepted silently by
# both YAML and Xcode, lands in the pbxproj, shows up in `-showBuildSettings`,
# and does absolutely nothing.
#
# That bug shipped twice in this project:
#   * Seven privacy usage descriptions were declared unprefixed, so every
#     mic / speech / HomeKit / Calendar / Reminders request would have been
#     killed by TCC on first use, and the build could not pass App Store review.
#   * UIBackgroundModes was missing entirely, so BGTaskScheduler.submit() threw
#     on every call and the Knowledge Base background ingest never ran. The
#     throw was caught and logged, so nothing surfaced.
#
# Both failure modes are invisible at build time and expensive to diagnose at
# runtime, which is exactly what a guardrail is for. This script checks the
# *built* Info.plist, not project.yml — the whole point is that the declaration
# can look right and still not take effect.
#
# USAGE
#   scripts/check-infoplist-keys.sh [path/to/Built.app]
#
# With no argument it locates the most recently built HomeHub.app under
# DerivedData. Exits non-zero and names the missing keys on failure.

set -euo pipefail

APP_PATH="${1:-}"

if [[ -z "$APP_PATH" ]]; then
    APP_PATH=$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
                    -name "HomeHub.app" -type d -path "*/Build/Products/*" \
                    -not -path "*.dSYM*" 2>/dev/null \
               | xargs -I{} stat -f "%m %N" {} 2>/dev/null \
               | sort -rn | head -1 | cut -d' ' -f2- || true)
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "check-infoplist-keys: no built HomeHub.app found."
    echo "  Build first (make build), or pass the .app path explicitly:"
    echo "    scripts/check-infoplist-keys.sh /path/to/HomeHub.app"
    exit 2
fi

PLIST="${APP_PATH}/Info.plist"
if [[ ! -f "$PLIST" ]]; then
    echo "check-infoplist-keys: no Info.plist inside ${APP_PATH}"
    exit 2
fi

echo "check-infoplist-keys: inspecting ${PLIST}"

# Keys that MUST be present. Each is paired with the call site that crashes or
# silently no-ops without it, so a future failure is self-explaining.
REQUIRED_KEYS=(
    "NSMicrophoneUsageDescription|VoiceService — AVAudioSession record permission"
    "NSSpeechRecognitionUsageDescription|VoiceService — SFSpeechRecognizer.requestAuthorization"
    "NSHomeKitUsageDescription|HomeKitSkill — HMHomeManager() construction"
    "NSCalendarsUsageDescription|CalendarSkill — EKEventStore (pre-iOS 17 path)"
    "NSCalendarsFullAccessUsageDescription|CalendarSkill — requestFullAccessToEvents"
    "NSRemindersUsageDescription|RemindersSkill — EKEventStore (pre-iOS 17 path)"
    "NSRemindersFullAccessUsageDescription|RemindersSkill — requestFullAccessToReminders"
    "BGTaskSchedulerPermittedIdentifiers|IngestScheduler — BGProcessingTaskRequest identifier"
    "UIBackgroundModes|IngestScheduler — BGTaskScheduler.submit needs 'processing'"
    "ITSAppUsesNonExemptEncryption|App Store export compliance"
)

FAILED=0
for entry in "${REQUIRED_KEYS[@]}"; do
    key="${entry%%|*}"
    why="${entry#*|}"
    if /usr/libexec/PlistBuddy -c "Print :${key}" "$PLIST" >/dev/null 2>&1; then
        printf '  ok      %s\n' "$key"
    else
        printf '  MISSING %s\n            needed by: %s\n' "$key" "$why"
        FAILED=1
    fi
done

# UIBackgroundModes must specifically contain "processing" — an empty array
# would pass the presence check above while still breaking BGTaskScheduler.
if /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$PLIST" 2>/dev/null | grep -q "processing"; then
    printf '  ok      UIBackgroundModes contains "processing"\n'
else
    printf '  MISSING UIBackgroundModes does not contain "processing"\n'
    printf '            BGTaskScheduler.submit() will throw BGTaskSchedulerErrorDomain code 1\n'
    FAILED=1
fi

# Privacy manifest — App Store requirement for required-reason API usage.
if [[ -f "${APP_PATH}/PrivacyInfo.xcprivacy" ]]; then
    printf '  ok      PrivacyInfo.xcprivacy present in bundle\n'
else
    printf '  MISSING PrivacyInfo.xcprivacy is not in the built bundle\n'
    printf '            App Store rejects submissions using required-reason APIs without it\n'
    FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo
    echo "check-infoplist-keys: FAILED"
    echo "  Reminder: in project.yml, Info.plist keys need the INFOPLIST_KEY_ prefix."
    echo "  An unprefixed key is accepted everywhere and reaches the bundle nowhere."
    exit 1
fi

echo "check-infoplist-keys: all required keys present"
