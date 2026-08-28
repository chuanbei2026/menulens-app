#!/bin/bash
# Re-shoot App Store screenshots. See docs/screenshots/README.md.
#
#   IPAD=0 tools/shoot-screenshots.sh <device-udid> <out-root> <path-to-.app> en zh-Hans fr ko
#   IPAD=1 ...   (iPad: no 04_server shot)
#
# Needs a DEBUG build — the launch-argument hooks it drives are #if DEBUG.
# Re-shoot App Store screenshots. Per language: uninstall (wipes the sandbox
# so the samples re-seed in that language), then one launch per view.
set -u
DEV="$1"; OUTROOT="$2"; APP="$3"; shift 3
VIEWS_IPAD="${IPAD:-0}"
BID=ai.xiangyang.MenuLens

# Set the status bar explicitly rather than trusting whatever the device
# happens to carry — it is device-level state another session can change.
#
# batteryState MUST be `discharging`, not `charged`: `charged` draws the green
# battery WITH a lightning bolt, i.e. a phone that is plugged in, which is not
# what a marketing screenshot should show. 9:41 is Apple's own convention,
# from the original iPhone keynote.
xcrun simctl status_bar "$DEV" override \
  --time "9:41" \
  --batteryState discharging --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 >/dev/null 2>&1

shot() { xcrun simctl io "$DEV" screenshot "$1" >/dev/null 2>&1; }
run()  { xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1; xcrun simctl launch "$DEV" $BID "$@" >/dev/null 2>&1; }

for LANG in "$@"; do
  OUT="$OUTROOT/$LANG"; mkdir -p "$OUT"
  xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1
  xcrun simctl uninstall "$DEV" $BID >/dev/null 2>&1
  xcrun simctl install "$DEV" "$APP" >/dev/null 2>&1

  # 01 home — a key is set so the onboarding card is gone and the controls live
  run -target_language "$LANG" -apiKey not-a-real-key-screenshots-only
  sleep 7; shot "$OUT/01_home.png"

  # 02 canvas — the in-place translated menu, order marked for two diners
  run -target_language "$LANG" -openLatest -demoCart
  sleep 20; shot "$OUT/02_canvas.png"

  # 03 list — dish list with thumbnails, search bar, member chips
  run -target_language "$LANG" -openLatest -listMode -demoCart
  sleep 16; shot "$OUT/03_list.png"

  if [ "$VIEWS_IPAD" = "0" ]; then
    # 04 server — the untouched original menu with the order marked on it
    run -target_language "$LANG" -openLatest -showOriginal -demoCart
    sleep 20; shot "$OUT/04_server.png"
  fi
  echo "  $LANG done: $(ls "$OUT" | tr '\n' ' ')"
done
