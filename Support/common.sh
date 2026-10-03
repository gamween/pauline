# shellcheck shell=bash disable=SC2034 # The scripts that source this file use these names.
# Shared by install.sh and uninstall.sh: refuses root, names what Pauline installs,
# and gives two helpers. Sourced, not run on its own.

if [ "$(id -u)" -eq 0 ]; then
  echo "Run ./$(basename "$0") without sudo. It asks for your password when it needs it." >&2
  exit 1
fi

label="com.gamween.pauline"
app="/Applications/Pauline.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
rule="/etc/sudoers.d/pauline"
domain="gui/$(id -u)"

# Runs a command as root: sudo in a terminal, the macOS password dialog otherwise.
as_root() {
  if [ -t 0 ]; then
    sudo /bin/sh -c "$1"
  else
    /usr/bin/osascript -e "do shell script \"$1\" with administrator privileges" >/dev/null
  fi
}

# Quits Pauline and waits until it is gone, 10 s at most.
# Quitting gives sleep back and sends the closing Telegram message.
stop_pauline() {
  launchctl bootout "$domain/$label" 2>/dev/null || true
  pkill -x -U "$(id -u)" Pauline 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -x -U "$(id -u)" Pauline >/dev/null || return 0
    sleep 0.2
  done
}
