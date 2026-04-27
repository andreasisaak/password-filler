#!/bin/bash
# Rebuild with Xcode-managed signing (Automatic), then install to /Applications.
#
# Xcode pulls the Apple Development provisioning profiles from the developer
# account on first build and embeds them. This replaces the old
# CODE_SIGNING_ALLOWED=NO + manual codesign + sed-expansion dance — Xcode now
# handles entitlements expansion, application-identifier injection, and profile
# embedding automatically.
#
# Phase 6 (notarized release) overrides these settings via xcodebuild flags
# (Manual + Developer ID Application); this script stays focused on dev.
set -u
cd /Users/isaak/sites/password-filler/mac

echo "--- rebuild (Automatic signing) ---"
rm -f /tmp/pf-appbuild.log
# Clear the stale in-bundle copies of embedded tool targets so the post-build
# copy phase never skips with "output newer than input". Xcode's incremental
# logic can miss entitlement-only changes — this forces the cp to run every
# time and costs nothing (files are ~2 MB each, re-copied in <100 ms).
rm -f /Users/isaak/sites/password-filler/mac/build/Debug/PasswordFiller.app/Contents/MacOS/PasswordFillerAgent \
      /Users/isaak/sites/password-filler/mac/build/Debug/PasswordFiller.app/Contents/MacOS/pf-nmh-bridge \
      2>/dev/null || true
xcodebuild build \
  -project PasswordFiller.xcodeproj \
  -target PasswordFiller \
  -configuration Debug \
  > /tmp/pf-appbuild.log 2>&1 &
BGPID=$!
sleep 10
ps auxww | grep -E "clang.*-x c -c /dev/null" | grep -v grep | awk '{print $2}' | xargs -n1 -I{} kill {} 2>/dev/null
wait "$BGPID"; RC=$?
if [[ $RC -ne 0 ]]; then
  echo "BUILD FAILED rc=$RC"
  grep -E "error:" /tmp/pf-appbuild.log | head -20
  echo ""
  echo "If the error mentions provisioning profiles: open PasswordFiller.xcodeproj"
  echo "in Xcode once, pick your team under Signing & Capabilities on each target,"
  echo "and let Xcode download the profiles. Then retry this script."
  exit 1
fi
echo "✅ build OK"

APP=/Users/isaak/sites/password-filler/mac/build/Debug/PasswordFiller.app

echo "--- verify main-app signature ---"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|Runtime|TeamId"

echo "--- kill any running instances ---"
pkill -9 -f PasswordFiller 2>/dev/null || true
sleep 1
rm -f "$HOME/Library/Application Support/app.passwordfiller/daemon.sock"

echo "--- install to /Applications ---"
rm -rf "/Applications/PasswordFiller.app"
cp -R "$APP" "/Applications/PasswordFiller.app"
ls -la "/Applications/PasswordFiller.app/Contents/MacOS/"

# After copying to /Applications, purge the Debug build output so
# LaunchServices stops advertising the `mac/build/Debug/PasswordFiller.app
# /Contents/PlugIns/SafariExt.appex` bundle as a second Safari Web Extension
# (observed as a duplicate "Password Filler Observer" entry in Safari's
# Extension preferences — Phase-5 Partial-2 finding, 2026-04-22). Unregister
# first so the removal propagates into lsregister's index without waiting
# for the next login/indexer pass; rm is silent if the path is already gone.
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREG" -u "$APP" 2>/dev/null || true
rm -rf "$APP"

echo "--- done. Run: open /Applications/PasswordFiller.app ---"
