#!/usr/bin/env bash
#
# Build this fork Release and install it on the paired iPhone, without opening Xcode.
#
#   Tools/install-device.sh                 # build Release + install on the one paired iPhone
#   Tools/install-device.sh --build-only    # build, print the bundle path, do not install
#   Tools/install-device.sh --device <UDID> # pick a device explicitly (needed if two are paired)
#
# WHY THIS EXISTS: the `NOOPiOS` scheme's run configuration is Debug, so installing from Xcode's Run
# button ships a `-Onone` build with `ENABLE_TESTABILITY` on. That is correct for development and
# roughly an order of magnitude slower for everything Swift does — SwiftUI body evaluation, GRDB row
# decoding, the analytics engine. A daily-driver install must be Release. This script hard-codes
# `-configuration Release` and refuses to install anything that did not land in `Release-iphoneos`,
# so the slow build cannot reach the phone by accident again.
#
# It pins `-derivedDataPath build` rather than reading the default DerivedData location: that path
# carries a hash of the project's location, so it silently changes if the checkout ever moves and an
# install script holding the old path would then install a stale bundle.
#
# The watch app and the widget extension are embedded in the iOS bundle (`Watch/NOOPWatch.app`,
# `PlugIns/NOOPWidgets.appex`), so this one install covers phone, widget and wrist.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="build"
PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
PRODUCT_NAME="NOOP Staging"
APP="$PRODUCTS/$PRODUCT_NAME.app"

BUILD_ONLY=0
DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) BUILD_ONLY=1; shift ;;
    --device)     DEVICE="${2:?--device needs a UDID}"; shift 2 ;;
    -h|--help)    sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The device may run a newer OS than the released Xcode's SDK (iPhone/Watch on an iOS 27 beta while
# only Xcode 26.x is GA). Building against a too-old SDK produces a bundle the device refuses, so
# prefer Xcode-beta when it is installed. Once the matching Xcode is GA this picks it up by itself.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
echo "==> toolchain: $(xcodebuild -version | head -1) ($(xcode-select -p))"

# project.yml is the source of truth; Strand.xcodeproj is generated and gitignored. Regenerate only
# when the manifest is newer, so a plain reinstall does not rewrite the project every time.
if [ ! -d Strand.xcodeproj ] || [ project.yml -nt Strand.xcodeproj ]; then
  echo "==> project.yml is newer than Strand.xcodeproj — running xcodegen"
  xcodegen generate
fi

# 13-09-2026: the build number was pinned at 316 in project.yml, so every build produced the SAME
# CFBundleVersion. devicectl force-replaces the iPhone app regardless, but watchOS only copies the
# embedded watch app to the wrist when its version is NEWER — with 316 every time, the Watch kept
# running whatever it installed first, for days. A minute-resolution stamp (yymmddHHMM) is always
# larger than the last one and stays inside CFBundleVersion's integer limit. Override an exact value
# with NOOP_BUILD_NUMBER when a specific number is needed.
BUILD_NUMBER="${NOOP_BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
echo "==> building NOOPiOS, configuration Release, build $BUILD_NUMBER"
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build

# xcodebuild's own exit status already gated the build; this catches the subtler failure where a
# future edit changes the configuration or product name and we would otherwise install whatever
# happens to be lying around from an earlier run.
[ -d "$APP" ] || { echo "expected Release bundle missing: $APP" >&2; exit 1; }

# 13-09-2026: a compile error made this script exit non-zero for two days, but the failure was read
# through a pipe (`install-device.sh | grep ...` reports grep's status, not the script's), so every
# "install" silently re-installed a bundle from 11-09 and two days of watch fixes were judged on code
# that never shipped. Freshness is therefore asserted here, where no wrapper can hide it: the bundle
# must be newer than every source file that goes into it.
STALE=$(find Strand StrandiOS NOOPWatch NOOPWatchComplications Packages \
          -name '*.swift' -newer "$APP/$PRODUCT_NAME" -print 2>/dev/null | head -3 || true)
if [ -n "$STALE" ]; then
  echo "REFUSING TO INSTALL: the built bundle is older than its sources — the build did not run." >&2
  echo "$STALE" | sed 's/^/  newer: /' >&2
  exit 1
fi
[ -d "$APP/Watch/NOOPWatch.app" ] || echo "WARNING: no embedded watch app in the bundle" >&2
[ -d "$APP/PlugIns/NOOPWidgets.appex" ] || echo "WARNING: no embedded widget extension in the bundle" >&2

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD_NO=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
echo "==> built $BUNDLE_ID $VERSION ($BUILD_NO)"
echo "    $REPO_ROOT/$APP"

if [ "$BUILD_ONLY" = 1 ]; then
  echo "==> --build-only: not installing"
  exit 0
fi

if [ -z "$DEVICE" ]; then
  # One physical iPhone is the normal case. Refuse to guess when there are several, rather than
  # install onto whichever one the listing happens to print first. Written for bash 3.2 (no
  # mapfile) and without awk interval expressions, so it runs on a stock macOS shell.
  FOUND=$(xcrun devicectl list devices 2>/dev/null | awk '
    /physical/ && /iPhone/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+$/) print $i
    }')
  COUNT=$(printf '%s\n' "$FOUND" | grep -c . || true)
  case "$COUNT" in
    1) DEVICE="$FOUND" ;;
    0) echo "no paired physical iPhone found — connect it and trust this Mac" >&2; exit 1 ;;
    *) echo "several iPhones paired; pass --device <UDID>:" >&2
       printf '  %s\n' "$FOUND" >&2; exit 1 ;;
  esac
fi

# Every devicectl command mounts the developer disk image first, and that mount fails while the
# device is locked — including read-only ones. Say so up front instead of letting the install fail
# with a CoreDeviceError the caller has to decode.
if ! xcrun devicectl device info lockState --device "$DEVICE" >/dev/null 2>&1; then
  echo "cannot reach $DEVICE — unlock the iPhone, keep it connected, and retry" >&2
  exit 1
fi

echo "==> installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null

# Verify against the DEVICE, not against the build we just made: an install that silently landed as
# a different version, or a container that got replaced instead of upgraded, is exactly what a
# post-install check is for. The store size is printed because it is the one number that shows the
# imported history survived (same bundle id + same signing team = upgrade install, container kept).
echo "==> installed, per the device:"
xcrun devicectl device info apps --device "$DEVICE" --include-all-apps 2>/dev/null \
  | awk -v id="$BUNDLE_ID" '$0 ~ id {print "    " $0}'
xcrun devicectl device info files --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --subdirectory "Library/Application Support/OpenWhoop" 2>/dev/null \
  | awk '/whoop.sqlite/ {print "    " $0}'

cat <<'NEXT'
==> next, on the phone
    1. Open the app. The FIRST launch runs any pending database migrations over a store that is
       hundreds of MB — let it finish rather than force-quitting it.
    2. Force-quit, reopen, and open the watch app once. That resets the watch bridge's 30-minute
       push gate, which is what otherwise leaves the complications blank after an install.
    3. If scrolling still is not smooth: Settings > Advanced > "Reduce motion in NOOP".
NEXT
