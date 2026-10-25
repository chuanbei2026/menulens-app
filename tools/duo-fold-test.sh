#!/bin/bash
# Runs DuoFoldUITests on an iPhone Duo simulator and folds / unfolds it when
# the tests ask (they print DUO-FOLD-NOW / DUO-UNFOLD-NOW).
#
#   tools/duo-fold-test.sh <simulator name or UDID> [extra xcodebuild args...]
#   FM_SHOTS=<folder> tools/duo-fold-test.sh FM-Duo     # also save the screenshots
#
# Needs Xcode 27 (the iPhone Duo and iOS 27.1); DEVELOPER_DIR defaults to it.
set -uo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { sed -n '2,8p' "$0"; exit 2; }
SIM="$1"; shift
LOG="$(mktemp -t duo-fold-test)"

"$REPO/tools/duo-fold.sh" "$SIM" unfold --wait --instant

export TEST_RUNNER_DUO_FOLD=1
[ -n "${FM_SHOTS:-}" ] && { mkdir -p "$FM_SHOTS"; export TEST_RUNNER_FM_SHOTS="$FM_SHOTS"; }
DEST="$SIM"
[[ "$SIM" =~ ^[0-9A-F-]{36}$ ]] && DEST="id=$SIM" || DEST="name=$SIM"
xcodebuild test -project "$REPO/MenuLens.xcodeproj" -scheme MenuLens -destination "$DEST" \
  -only-testing:MenuLensUITests/DuoFoldUITests "$@" > "$LOG" 2>&1 &
TEST=$!

# Answer each cue once, in order, as it shows up in the log.
answered=0
while kill -0 "$TEST" 2> /dev/null; do
  cues=$(grep -oE 'DUO-(UN)?FOLD-NOW' "$LOG" | sed -n "$((answered + 1)),\$p")
  for cue in $cues; do
    case "$cue" in
      DUO-FOLD-NOW) "$REPO/tools/duo-fold.sh" "$SIM" fold --wait ;;
      DUO-UNFOLD-NOW) "$REPO/tools/duo-fold.sh" "$SIM" unfold --wait ;;
    esac
    answered=$((answered + 1))
  done
  # Xcode 27's xcodebuild can sit for minutes after the run has reported.
  if grep -qE "^Test Suite 'Selected tests' (passed|failed)" "$LOG"; then
    sleep 20; kill "$TEST" 2> /dev/null
  fi
  sleep 1
done
wait "$TEST"
status=1
grep -q "^Test Suite 'Selected tests' passed" "$LOG" && status=0
grep -E "Test Case .*(passed|failed|skipped)|error:|\*\* TEST" "$LOG"
echo "log: $LOG"
exit $status
