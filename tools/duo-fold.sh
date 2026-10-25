#!/bin/bash
# Folds or unfolds an iPhone Duo simulator (iOS 27.1, Xcode 27), from the command line.
#
#   tools/duo-fold.sh <simulator name or UDID> fold|unfold|toggle [--wait] [--instant]
#
#   fold     swap to the 5.4" cover display (hinge closed)
#   unfold   swap to the 7.6" inner display (hinge open)
#   toggle   the other one
#   --wait     return once the swap animation has finished
#   --instant  no hinge animation (duration 0)
#
# There is no simctl subcommand for the hinge (DeviceHub's device chrome has a slider). This builds
# tools/duo/fold.m for the simulator, with the entitlement SpringBoard's display tool service asks for
# in a __TEXT,__entitlements section (simulator processes take their entitlements from there), and runs
# it in the simulator with `simctl spawn`. Each swap ignores the real (simulated) hinge for 10 seconds.
#
# DEVELOPER_DIR defaults to /Applications/Xcode-27.app/Contents/Developer.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/tools/duo/fold.m"
BUILD="${TMPDIR:-/tmp}/menulens-duo-fold"
BIN="$BUILD/fold"

[ $# -ge 2 ] || { sed -n '2,12p' "$0"; exit 2; }
SIM="$1"; ACTION="$2"; shift 2
WAIT="" DURATION=""
for a in "$@"; do
  case "$a" in
    --wait) WAIT="-wait" ;;
    --instant) DURATION="-duration=0" ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

# A name: the UDID of the booted (or any) simulator with that name.
if ! [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then
  UDID=$(xcrun simctl list devices | grep -F "    $SIM (" | grep -m1 -oE '[0-9A-F-]{36}') || true
  [ -n "${UDID:-}" ] || { echo "no simulator named $SIM" >&2; exit 2; }
  SIM="$UDID"
fi

mkdir -p "$BUILD"
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  cat > "$BUILD/fold.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.springboard.sbdisplay.service</key><true/>
</dict></plist>
EOF
  xcrun -sdk iphonesimulator clang -fobjc-arc -framework Foundation -target arm64-apple-ios27.0-simulator \
    -Wl,-sectcreate,__TEXT,__entitlements,"$BUILD/fold.entitlements" "$SRC" -o "$BIN"
  codesign -s - -f "$BIN" 2> /dev/null
fi

case "$ACTION" in
  fold) POS="-position=closed" ;;
  unfold) POS="-position=open" ;;
  toggle) POS="" ;;
  *) echo "unknown action $ACTION (fold, unfold, toggle)" >&2; exit 2 ;;
esac
xcrun simctl spawn "$SIM" "$BIN" $POS $DURATION $WAIT
