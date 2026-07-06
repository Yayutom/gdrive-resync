#!/usr/bin/env bash
#
# restart-google-drive.sh
# -----------------------------------------------------------------------------
# Cleanly restart "Google Drive for desktop" on macOS to recover from
# File Provider / Finder sync stalls.
#
# Why this exists:
#   Since macOS 12.3, Google Drive for desktop syncs through Apple's File
#   Provider framework (~/Library/CloudStorage/GoogleDrive-*). On macOS 26
#   ("Tahoe") the auth/sync engine can wedge: the client repeatedly fails to
#   refresh its OAuth access token (look for "Failed to refresh access token"
#   in the DriveFS logs), and remote changes stop appearing in Finder.
#   Quitting from the menu bar often leaves wedged helper processes alive, so
#   the stall persists. This script does a *thorough* stop (graceful quit ->
#   SIGTERM -> SIGKILL of every process inside the app bundle) and relaunches,
#   which rebuilds the auth session and the change-notification pipeline.
#
# What it does NOT do:
#   It never touches your files, your Drive data, or the local DriveFS cache.
#   It only restarts processes. Nothing is deleted.
#
# Usage:
#   ./restart-google-drive.sh              # stop + start + verify (default)
#   ./restart-google-drive.sh --diagnose   # show sync/auth health, no restart
#   ./restart-google-drive.sh --status     # show running processes, no restart
#   ./restart-google-drive.sh --no-verify  # restart but skip log verification
#   ./restart-google-drive.sh --help
#
# Exit codes: 0 ok / 1 usage error / 2 not macOS / 3 app not installed
# -----------------------------------------------------------------------------

set -uo pipefail

APP_NAME="Google Drive"
APP_PATH="/Applications/Google Drive.app"
LOG_DIR="$HOME/Library/Application Support/Google/DriveFS/Logs"
DRIVE_LOG="$LOG_DIR/drive_fs.txt"

GRACE_SECONDS=6        # how long to wait for a graceful quit before forcing
VERIFY_SECONDS=30      # how long to watch the log for recovery after relaunch

# --- pretty output ----------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s->%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '%s[fail]%s %s\n' "$RED" "$RST" "$*" >&2; }

# --- guards -----------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || { err "This tool is macOS only."; exit 2; }

# List OS pids of every process whose executable lives inside the app bundle.
# Matching the executable path (not the full command line) means we never hit
# an unrelated process that merely mentions "Google Drive" in its arguments.
drive_pids() {
  ps -Axo pid=,comm= \
    | grep -F "$APP_PATH" \
    | grep -v ' grep' \
    | awk '{print $1}'
}

show_status() {
  local pids; pids="$(drive_pids)"
  if [ -z "$pids" ]; then
    warn "Google Drive is not running."
    return 1
  fi
  ok "Google Drive is running:"
  ps -Axo pid=,lstart=,comm= | grep -F "$APP_PATH" | grep -v ' grep' \
    | sed "s|$APP_PATH/Contents/MacOS/||; s|$APP_PATH/Contents/||" \
    | sed 's/^/    /'
  return 0
}

# --- diagnose: read the DriveFS logs and summarize auth/sync health ----------
diagnose() {
  say "${BOLD}Google Drive — sync/auth diagnosis${RST}"
  say "${DIM}log: $DRIVE_LOG${RST}"
  say ""
  if [ ! -f "$DRIVE_LOG" ]; then
    warn "No DriveFS log found (is Google Drive installed and has it run?)."
    return 0
  fi

  local fails last_fail last_change
  fails="$(grep -c "Failed to refresh access token" "$DRIVE_LOG" 2>/dev/null)"; fails="${fails:-0}"
  if [ "$fails" -gt 0 ]; then
    last_fail="$(grep "Failed to refresh access token" "$DRIVE_LOG" | tail -1)"
    warn "Token-refresh failures in current log: ${BOLD}${fails}${RST}"
    say  "     latest: ${DIM}${last_fail}${RST}"
  else
    ok "No token-refresh failures in current log."
  fi

  last_change="$(grep -E "OnChangeNotificationReceived|Successfully signaled changes" "$DRIVE_LOG" 2>/dev/null | tail -1)"
  if [ -n "$last_change" ]; then
    ok "Sync pipeline has recent activity:"
    say "     ${DIM}${last_change}${RST}"
  else
    warn "No recent change-notification activity found in the log tail."
  fi

  say ""
  show_status || true
}

# --- stop: graceful quit, then escalate to TERM, then KILL -------------------
wait_gone() {   # wait_gone <deadline-seconds>
  local deadline="$1" waited=0
  while [ -n "$(drive_pids)" ] && [ "$waited" -lt "$deadline" ]; do
    sleep 1; waited=$((waited + 1))
  done
  [ -z "$(drive_pids)" ]
}

signal_all() {  # signal_all <signal>
  local sig="$1" p
  drive_pids | while IFS= read -r p; do
    [ -n "$p" ] && kill "-$sig" "$p" 2>/dev/null || true
  done
}

stop_drive() {
  if [ -z "$(drive_pids)" ]; then
    info "Google Drive is not running — nothing to stop."
    return 0
  fi

  info "Asking Google Drive to quit..."
  osascript -e 'tell application "Google Drive" to quit' >/dev/null 2>&1 || true
  if wait_gone "$GRACE_SECONDS"; then ok "Stopped cleanly."; return 0; fi

  warn "Still running — sending SIGTERM to bundle processes..."
  signal_all TERM
  if wait_gone 4; then ok "Stopped (SIGTERM)."; return 0; fi

  warn "Still running — sending SIGKILL..."
  signal_all KILL
  if wait_gone 4; then ok "Stopped (SIGKILL)."; return 0; fi

  err "Could not stop all Google Drive processes:"
  show_status || true
  return 1
}

# --- start ------------------------------------------------------------------
start_drive() {
  info "Launching Google Drive..."
  open -a "$APP_NAME"
  # give the launcher a moment, then confirm a process actually appeared
  local waited=0
  while [ -z "$(drive_pids)" ] && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited + 1))
  done
  if [ -n "$(drive_pids)" ]; then ok "Google Drive launched."; return 0; fi
  err "Google Drive did not appear to start."; return 1
}

# --- verify: watch the log for the sync pipeline coming back to life ---------
verify_recovery() {
  [ -f "$DRIVE_LOG" ] || { warn "No log to verify against (skipping)."; return 0; }
  info "Watching the DriveFS log for recovery (up to ${VERIFY_SECONDS}s)..."
  local waited=0 line=""
  while [ "$waited" -lt "$VERIFY_SECONDS" ]; do
    line="$(tail -n 40 "$DRIVE_LOG" 2>/dev/null \
      | grep -E "OnChangeNotificationReceived|Successfully signaled changes" | tail -1)"
    if [ -n "$line" ]; then
      ok "Sync pipeline is live again:"
      say "     ${DIM}${line}${RST}"
      return 0
    fi
    sleep 2; waited=$((waited + 2))
  done
  warn "No sync activity observed yet. It may just be idle (no changes to pull)."
  warn "Test it: edit a file at drive.google.com and watch it appear in Finder."
  return 0
}

# --- main -------------------------------------------------------------------
usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  case "${1:-}" in
    -h|--help)     usage; exit 0 ;;
    -s|--status)   show_status; exit 0 ;;
    -d|--diagnose) diagnose; exit 0 ;;
    --no-verify)   VERIFY=0 ;;
    "")            VERIFY=1 ;;
    *) err "Unknown option: $1"; say "Try --help"; exit 1 ;;
  esac

  [ -d "$APP_PATH" ] || { err "Google Drive is not installed at $APP_PATH"; exit 3; }

  say "${BOLD}Restarting Google Drive for desktop${RST}"
  stop_drive || exit 1
  start_drive || exit 1
  [ "${VERIFY:-1}" -eq 1 ] && verify_recovery
  say ""
  ok "Done. If Finder still lags, run '--diagnose'; a persistent token-refresh"
  say "     failure means you should re-sign-in (Drive settings -> Disconnect"
  say "     account -> sign in again)."
}

main "$@"
