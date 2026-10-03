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

rm -f "$agent"
rm -rf "$app"
defaults delete "$label" 2>/dev/null || true
if [ -e "$rule" ]; then
  echo "macOS asks for your password to remove $rule."
  as_root "/bin/rm -f $rule"
fi

if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
  echo "Sleep is still disabled. Run: sudo pmset -a disablesleep 0" >&2
  exit 1
fi
echo "Pauline is gone and your Mac sleeps normally."
