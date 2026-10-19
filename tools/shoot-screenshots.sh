#!/bin/bash
# Re-shoot App Store screenshots. See docs/screenshots/README.md.
#
#   SESSION_TOKEN=<dev token> IPAD=0 tools/shoot-screenshots.sh <device-udid> <out-root> <path-to-.app> en zh-Hans fr ko
#   SESSION_TOKEN=<dev token> IPAD=1 ...   (iPad: no 06_server shot)
#   SHOTS="04 05" IPAD=1 ...               only these shots (04 and 05 need no SESSION_TOKEN)
#   BACKEND_URL=http://127.0.0.1:8787/menu ...   where 05's fresh install opens its device account
#
# Needs a DEBUG build — the launch-argument hooks it drives are #if DEBUG.
# SESSION_TOKEN is a short-lived dev session (backend/README.md) for 01–03
# and 06. 04_account shows a device account ("not signed in") with made-up
# history (-demoUsage, and a session built here that is never sent anywhere);
# 05_start is a fresh install's home screen — no sign-in step since 1.1 (4). Nothing here sends a menu anywhere —
# the shots use the bundled samples, so they cost no credits.
#
# Per language: uninstall (wipes the sandbox so the samples re-seed in that
# language), then one launch per view.
set -u
DEV="$1"; OUTROOT="$2"; APP="$3"; shift 3
VIEWS_IPAD="${IPAD:-0}"
SHOTS="${SHOTS:-01 02 03 04 05 06}"
want() { [[ " ${SHOTS} " == *" $1 "* ]]; }
if want 01 || want 02 || want 03 || want 06; then TOKEN="${SESSION_TOKEN:?set SESSION_TOKEN to a dev session token}"; fi
# A device-account session for 04: unsigned, only its claims are read (anon:…).
b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }
DEMO_TOKEN="$(printf '{"alg":"HS256","typ":"JWT"}' | b64url).$(printf '{"iss":"foreignmenu","sub":"anon:00000000-demo","exp":%d}' $(( $(date +%s) + 30*86400 )) | b64url).demo"
BACKEND=(); [ -n "${BACKEND_URL:-}" ] && BACKEND=(-backendURL "${BACKEND_URL}")
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
  for s in $SHOTS; do rm -f "$OUT/${s}_"*.png; done
  device_language "$LANG"
  xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1
  xcrun simctl uninstall "$DEV" $BID >/dev/null 2>&1
  xcrun simctl install "$DEV" "$APP" >/dev/null 2>&1

  # Seed the samples (and their AI marking) once before the timed shots.
  run -sessionToken "${TOKEN:-$DEMO_TOKEN}" -demoUsage
  sleep 8

  if want 01; then
  # 01 canvas — hero: the in-place translated menu, order marked for two diners
  run -sessionToken "$TOKEN" -openLatest -demoCart
  sleep 20; shot "$OUT/01_canvas.png"
  fi
  if want 02; then

  # 02 list — "Worth ordering", AI-badged dish pictures, member chips
  run -sessionToken "$TOKEN" -openLatest -listMode -demoCart
  sleep 16; shot "$OUT/02_list.png"
  fi
  if want 03; then

  # 03 pages — a two-page menu half in: page 1 readable, page 2 still translating
  run -sessionToken "$TOKEN" -demoReceiving
  sleep 16; shot "$OUT/03_pages.png"
  fi

  if want 04; then
  # 04 account — Settings: "not signed in (this device's account)", balance,
  # credit history, Buy credits, the optional Sign in with Apple.
  # -demoUsage: a plausible month of history, nothing sent to the server.
  # (the home screen shows behind the sheet on iPad: toggle at its default)
  IMAGES="-generate_dish_images YES" run -sessionToken "$DEMO_TOKEN" -grantConsent -demoUsage -showSettings
  sleep 10; shot "$OUT/04_account.png"
  fi

  if want 05; then
  # 05 start — a fresh install's home screen: no sign-in, ready to scan.
  # -noImages is stored as the toggle's value, so show the default (on)
  # instead; nothing is opened here, so nothing gets generated.
  rm -f "$OUT/05_signin.png"  # before 1.1 (4): the mandatory sign-in card
  IMAGES="-generate_dish_images YES" run -signOut "${BACKEND[@]}"
  sleep 8; shot "$OUT/05_start.png"
  fi

  if [ "$VIEWS_IPAD" = "0" ] && want 06; then
    # 06 server — the untouched original menu with the order marked on it
    run -sessionToken "$TOKEN" -openLatest -showOriginal -demoCart
    sleep 20; shot "$OUT/06_server.png"
  fi
  echo "  $LANG done: $(ls "$OUT" | tr '\n' ' ')"
done
