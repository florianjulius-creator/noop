#!/usr/bin/env bash
#
# Install the watch app STRAIGHT onto the paired Apple Watch, instead of waiting for the phone to
# propagate it.
#
#   Tools/install-watch.sh              # install the watch app from the last device build
#   Tools/install-watch.sh --build      # build Release first (Tools/install-device.sh), then install
#
# WHY THIS EXISTS: the watch app is embedded in the iOS bundle (NOOP.app/Watch/NOOPWatch.app), so an
# iPhone install only makes the new version AVAILABLE to the watch — watchOS copies it over on its own
# schedule, which can be many minutes, and sometimes only after a tap in the iPhone's Watch app. On
# 13-09-2026 two rounds of "no difference, still cut off" turned out to be the Watch still running the
# previous build. This installs it directly, in seconds.
#
# REQUIRES, once: Developer Mode ON on the Watch
#   Watch → Instellingen → Privacy en beveiliging → Ontwikkelaarsmodus → aan → herstart.
# Then the watch must be unlocked, on the wrist, and on the same Wi-Fi as this Mac.
#
# Without Developer Mode this fails with "The developer disk image could not be mounted on this
# device" or "Failed to allocate RSD device" — that is the tell, not a code problem.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WATCH="493F960E-540F-5B1D-8ADF-7574DD00919B"   # Apple Watch van Florian
APP="build/Build/Products/Release-iphoneos/NOOP Staging.app/Watch/NOOPWatch.app"

if [ "${1:-}" = "--build" ]; then
  Tools/install-device.sh
fi

[ -d "$APP" ] || { echo "no watch app at $APP — run Tools/install-device.sh first" >&2; exit 1; }

echo "==> built: $(date -r "$APP/NOOPWatch" '+%d-%m %H:%M')"
xcrun devicectl device install app --device "$WATCH" "$APP"
