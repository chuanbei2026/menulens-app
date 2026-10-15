#!/bin/bash
# Re-shoot App Store screenshots. See docs/screenshots/README.md.
#
#   SESSION_TOKEN=<dev token> IPAD=0 tools/shoot-screenshots.sh <device-udid> <out-root> <path-to-.app> en zh-Hans fr ko
#   SESSION_TOKEN=<dev token> IPAD=1 ...   (iPad: no 06_server shot)
#
# Needs a DEBUG build — the launch-argument hooks it drives are #if DEBUG.
# SESSION_TOKEN is a short-lived dev session (backend/README.md): every shot
# but the sign-in card is taken signed in, and 04_account shows that
# account's real balance and history. Nothing here sends a menu anywhere —
# the shots use the bundled samples, so they cost no credits.
#
# Per language: uninstall (wipes the sandbox so the samples re-seed in that
# language), then one launch per view.
set -u
DEV="$1"; OUTROOT="$2"; APP="$3"; shift 3
VIEWS_IPAD="${IPAD:-0}"
TOKEN="${SESSION_TOKEN:?set SESSION_TOKEN to a dev session token}"
BID=ai.xiangyang.MenuLens

# Set the status bar explicitly rather than trusting whatever the device
# happens to carry — it is device-level state another session can change.
#
# batteryState MUST be `discharging`, not `charged`: `charged` draws the green
# battery WITH a lightning bolt, i.e. a phone that is plugged in, which is not
# what a marketing screenshot should show. 9:41 is Apple's own convention,
# from the original iPhone keynote.
status_bar() {
  xcrun simctl status_bar "$DEV" override \
    --time "9:41" \
    --batteryState discharging --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1
}

# Simulators get shut down from outside (another session's `shutdown all`);
# boot again — and re-apply the status bar, which a reboot drops — rather
# than shoot a dead screen.
ensure_booted() {
  if ! xcrun simctl list devices | grep "$DEV" | grep -q Booted; then
    echo "  (re-booting $DEV)"
    xcrun simctl boot "$DEV" >/dev/null 2>&1
    xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1
    status_bar
  fi
}

# The status bar's date (iPad) is drawn by the system in the DEVICE's
# language, not the app's: set the device to the shot's language and region,
# then reboot so SpringBoard picks it up.
device_language() {
  local locale
  case "$1" in
    zh-Hans) locale=zh_CN ;; fr) locale=fr_FR ;; ko) locale=ko_KR ;; ja) locale=ja_JP ;;
    es) locale=es_ES ;; hi) locale=hi_IN ;; *) locale=en_US ;;
  esac
  ensure_booted
  xcrun simctl spawn "$DEV" defaults write -g AppleLanguages -array "$1" >/dev/null 2>&1
  xcrun simctl spawn "$DEV" defaults write -g AppleLocale -string "$locale" >/dev/null 2>&1
  xcrun simctl shutdown "$DEV" >/dev/null 2>&1
  ensure_booted
}

ensure_booted
status_bar

shot() {
  xcrun simctl io "$DEV" screenshot "$1" >/dev/null 2>&1 || echo "  !! no screenshot for $(basename "$1")"
}
# Every launch: this language, a US storefront (all models, dish pictures
# offered). -noImages: opening a sample must not generate the pictures it
# lacks — that spends the account's credits and puts a progress banner in
# the shot.
run()  {
  ensure_booted
  xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1
  xcrun simctl launch "$DEV" $BID -target_language "$LANG" -AppleLanguages "($LANG)" -storefront USA ${IMAGES:--noImages} "$@" >/dev/null 2>&1
}

for LANG in "$@"; do
  OUT="$OUTROOT/$LANG"; mkdir -p "$OUT"
  rm -f "$OUT"/*.png
  device_language "$LANG"
  xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1
  xcrun simctl uninstall "$DEV" $BID >/dev/null 2>&1
  xcrun simctl install "$DEV" "$APP" >/dev/null 2>&1

  # Seed the samples (and their AI marking) once before the timed shots.
  run -sessionToken "$TOKEN"
  sleep 8

  # 01 canvas — hero: the in-place translated menu, order marked for two diners
  run -sessionToken "$TOKEN" -openLatest -demoCart
  sleep 20; shot "$OUT/01_canvas.png"

  # 02 list — "Worth ordering", AI-badged dish pictures, member chips
  run -sessionToken "$TOKEN" -openLatest -listMode -demoCart
  sleep 16; shot "$OUT/02_list.png"

  # 03 pages — a two-page menu half in: page 1 readable, page 2 still translating
  run -sessionToken "$TOKEN" -demoReceiving
  sleep 16; shot "$OUT/03_pages.png"

  # 04 account — Settings: balance, credit history, Buy credits / Redeem code
  # (the home screen shows behind the sheet on iPad: toggle at its default)
  IMAGES="-generate_dish_images YES" run -sessionToken "$TOKEN" -grantConsent -showSettings
  sleep 10; shot "$OUT/04_account.png"

  # 05 sign-in — the start screen as a new user sees it. -noImages is stored
  # as the toggle's value, so show the default (on) instead; nothing is
  # opened here, so nothing gets generated.
  IMAGES="-generate_dish_images YES" run -signOut
  sleep 8; shot "$OUT/05_signin.png"

  if [ "$VIEWS_IPAD" = "0" ]; then
    # 06 server — the untouched original menu with the order marked on it
    run -sessionToken "$TOKEN" -openLatest -showOriginal -demoCart
    sleep 20; shot "$OUT/06_server.png"
  fi
  echo "  $LANG done: $(ls "$OUT" | tr '\n' ' ')"
done
