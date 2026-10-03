#!/bin/bash
# Gives sleep back, then removes Pauline, its data and everything install.sh added.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=Support/common.sh
source Support/common.sh

stop_pauline
# Pauline gives sleep back when it quits. This is a second safety while the rule still exists.
sudo -k -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || true

still_awake() { ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; }
# powerd applies a change a moment after pmset returns.
settle() { for _ in 1 2 3 4 5 6 7 8 9 10; do still_awake || return 0; sleep 0.2; done; return 1; }

if ! settle; then
  echo "macOS asks for your password to give sleep back."
  as_root "/usr/bin/pmset -a disablesleep 0" || true
  settle || true
fi

# Pauline sends the Telegram closing message as it quits. If it could not (offline), try once more,
# and only if sleep really came back: the chat must never read "off" while the Mac is still awake.
config="$HOME/Library/Application Support/Pauline/telegram.json"
# plutil prints its errors on stdout: keep its output only when the key exists.
read_key() {
  local value
  if value="$(plutil -extract "$1" raw -o - "$config" 2>/dev/null)"; then printf '%s' "$value"; fi
}
if [ -f "$config" ] && ! still_awake && plutil -extract session json -o /dev/null "$config" >/dev/null 2>&1; then
  token="$(read_key token)"
  chat="$(read_key chatID)"
  text="$(read_key session.closingText)"
  if [ -z "$text" ]; then
    pct="$(pmset -g batt | grep -Eo '[0-9]+%' | head -n 1 || true)"
    battery="No battery"
    if [ -n "$pct" ]; then battery="Battery $pct"; fi
    text="Pauline is off"$'\n'"$battery"
  fi
  if [ -n "$token" ] && [ -n "$chat" ]; then
    # The URL holds the token: curl reads it on stdin, so ps never shows it.
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
      curl -s -m 5 -o /dev/null -K - --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" || true
  fi
fi

rm -f "$agent"
rm -rf "$app"
defaults delete "$label" 2>/dev/null || true
# The Telegram settings, and the lock file that keeps one copy running.
rm -rf "$HOME/Library/Application Support/Pauline" "$(getconf DARWIN_USER_TEMP_DIR)$label.lock"
if [ -e "$rule" ]; then
  echo "macOS asks for your password to remove $rule."
  as_root "/bin/rm -f $rule"
fi

if still_awake; then
  echo "Sleep is still disabled. Run: sudo pmset -a disablesleep 0" >&2
  exit 1
fi
echo "Pauline is gone and your Mac sleeps normally."
