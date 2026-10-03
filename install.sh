#!/bin/bash
# Builds Pauline, lets it toggle sleep without a password, and starts it at every login.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -eq 0 ]; then
  echo "Run ./install.sh without sudo, it asks for your password when it needs it." >&2
  exit 1
fi

label="com.gamween.pauline"
app="/Applications/Pauline.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
rule="/etc/sudoers.d/pauline"
user="$(id -un)"
domain="gui/$(id -u)"

step() { printf '\n==> %s\n' "$1"; }

# Runs a command as root: sudo in a terminal, the macOS password dialog otherwise.
as_root() {
  if [ -t 0 ]; then
    sudo /bin/sh -c "$1"
  else
    /usr/bin/osascript -e "do shell script \"$1\" with administrator privileges" >/dev/null
  fi
}

# Passes only through a NOPASSWD rule: -k ignores a password typed earlier in this terminal.
allowed() { sudo -k -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; }

step "Building"
./build.sh

step "Installing $app"
# Quitting a running copy gives sleep back before it gets replaced.
launchctl bootout "$domain/$label" 2>/dev/null || true
pkill -x Pauline 2>/dev/null || true
rm -rf "$app"
ditto build/Pauline.app "$app"

step "Allowing Pauline to toggle sleep"
if allowed; then
  echo "Already allowed."
else
  if ! [[ "$user" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "Unexpected user name '$user', stopping before touching sudo." >&2
    exit 1
  fi
  echo "macOS asks for your password once. It allows these two commands, nothing else:"
  echo "  /usr/bin/pmset -a disablesleep 0"
  echo "  /usr/bin/pmset -a disablesleep 1"
  comment="# Lets $user turn sleep on and off without a password. Added by Pauline, removed by its uninstall.sh."
  line="$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
  # Root writes the rule itself under a name sudo skips (it has a dot), checks it with visudo
  # (a broken sudoers file can lock sudo), then moves it in place.
  as_root "umask 0337 && t=/etc/sudoers.d/.pauline.new && /bin/rm -f \$t \
&& /usr/bin/printf '%s\n' '$comment' '$line' > \$t \
&& /usr/sbin/visudo -cf \$t >/dev/null && /usr/sbin/chown root:wheel \$t && /bin/mv -f \$t $rule \
|| { /bin/rm -f \$t; exit 1; }"
  if ! allowed; then
    echo "The rule is in place but sudo still asks for a password. Check $rule." >&2
    exit 1
  fi
fi

step "Starting Pauline at login"
mkdir -p "$(dirname "$agent")"
cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$app/Contents/MacOS/Pauline</string>
		<string>--launchd</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- Relaunch after a crash, not after Quit. -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST
chmod 0644 "$agent"
plutil -lint "$agent" >/dev/null
# launchd can take a moment to forget the previous copy.
for attempt in 1 2 3 4 5; do
  if error="$(launchctl bootstrap "$domain" "$agent" 2>&1)"; then
    break
  fi
  if [ "$attempt" = 5 ]; then
    echo "launchd refused to start Pauline: $error" >&2
    exit 1
  fi
  sleep 1
done

printf '\nDone. Pauline is the cup in your menu bar.\n'
printf '  Click        stay awake with the lid closed, click again to sleep normally\n'
printf '  Right-click  status, battery and Quit\n'
