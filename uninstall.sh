#!/bin/bash
# Removes Pauline and everything install.sh added, and gives sleep back.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run ./uninstall.sh without sudo, it asks for your password when it needs it." >&2
  exit 1
fi

label="com.gamween.pauline"
app="/Applications/Pauline.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
rule="/etc/sudoers.d/pauline"

as_root() {
  if [ -t 0 ]; then
    sudo /bin/sh -c "$1"
  else
    /usr/bin/osascript -e "do shell script \"$1\" with administrator privileges" >/dev/null
  fi
}

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
pkill -x Pauline 2>/dev/null || true
# Pauline gives sleep back when it quits. This is a second safety while the rule still exists.
sudo -k -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || true

still_awake() { ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; }

# Pauline sends the Telegram closing message as it quits. If it could not (offline), try once more,
# and only if sleep really came back: the chat must never read "off" while the Mac is still awake.
config="$HOME/Library/Application Support/Pauline/telegram.json"
if [ -f "$config" ] && ! still_awake && plutil -extract session json -o /dev/null "$config" >/dev/null 2>&1; then
  token="$(plutil -extract token raw -o - "$config" 2>/dev/null || true)"
  chat="$(plutil -extract chatID raw -o - "$config" 2>/dev/null || true)"
  text="$(plutil -extract session.closingText raw -o - "$config" 2>/dev/null || echo "Pauline is off (uninstalled)")"
  if [ -n "$token" ] && [ -n "$chat" ]; then
    curl -s -m 5 -o /dev/null "https://api.telegram.org/bot$token/sendMessage" \
      --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" || true
  fi
fi

rm -f "$agent"
rm -rf "$app"
defaults delete "$label" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/Pauline"
if [ -e "$rule" ]; then
  echo "macOS asks for your password to remove $rule."
  as_root "/bin/rm -f $rule"
fi

if still_awake; then
  echo "Sleep is still disabled. Run: sudo pmset -a disablesleep 0" >&2
  exit 1
fi
echo "Pauline is gone and your Mac sleeps normally."
