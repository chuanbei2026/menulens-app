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

shot() { xcrun simctl io "$DEV" screenshot "$1" >/dev/null 2>&1; }
run()  { xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1; xcrun simctl launch "$DEV" $BID "$@" >/dev/null 2>&1; }

for LANG in "$@"; do
  OUT="$OUTROOT/$LANG"; mkdir -p "$OUT"
  xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1
  xcrun simctl uninstall "$DEV" $BID >/dev/null 2>&1
  xcrun simctl install "$DEV" "$APP" >/dev/null 2>&1

  # 01 home — a key is set so the onboarding card is gone and the controls live
  run -target_language "$LANG" -apiKey sk-screenshot-placeholder
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
