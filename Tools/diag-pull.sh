#!/usr/bin/env bash
#
# Pull the morning paper trail off the paired iPhone and print it — no photos of the wrist needed.
#
#   Tools/diag-pull.sh                 # copy Documents/diag from the phone, print the tails
#   Tools/diag-pull.sh --device <UDID> # pick a device explicitly
#   Tools/diag-pull.sh --dest <dir>    # where to put the copy (default: /tmp/noop-diag)
#
# What is in there (written by StrandiOS/App/DiagSink.swift):
#   phone.jsonl   every phone-side morning event: message from the wrist, strap pull outcome, push, wake
#   watch.jsonl   the Watch's own self-report (its settings-page lines), sent over WatchConnectivity
#   ble-<day>.log the strap log tail at each morning pull / auto-offload kick
#
# Needs the phone unlocked-once-since-boot and reachable (same Wi-Fi or USB); devicectl says
# "cannot reach" otherwise — retry when it is.

set -euo pipefail

DEVICE="3B63A154-A8EB-51DD-A4D5-80F256CF04EB"
DEST="/tmp/noop-diag"
BUNDLE="ai.breinpro.noop"
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:?--device needs a UDID}"; shift 2 ;;
    --dest)   DEST="${2:?--dest needs a directory}"; shift 2 ;;
    -h|--help) sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

rm -rf "$DEST"
mkdir -p "$DEST"
xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Documents/diag --destination "$DEST" >/dev/null

for f in phone.jsonl watch.jsonl; do
  if [ -f "$DEST/$f" ]; then
    echo "===== $f (last 30) ====="
    tail -n 30 "$DEST/$f"
  fi
done
for f in "$DEST"/ble-*.log; do
  [ -f "$f" ] || continue
  echo "===== $(basename "$f") (last 60 of $(wc -l < "$f")) ====="
  tail -n 60 "$f"
done
echo "copy: $DEST"
