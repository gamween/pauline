#!/bin/bash
# Builds Pauline, lets it toggle sleep without a password, and starts it at every login.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=Support/common.sh
source Support/common.sh

step() { printf '\n==> %s\n' "$1"; }

# Passes only through the NOPASSWD rule: -k ignores a password typed earlier in this terminal.
# It also gives sleep back, which the install wants anyway.
allowed() { sudo -k -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; }

step "Building"
./build.sh

step "Installing $app"
stop_pauline
rm -rf "$app"
ditto build/Pauline.app "$app"

step "Allowing Pauline to toggle sleep"
if allowed; then
  echo "Already allowed."
else
  user="$(id -un)"
  if ! [[ "$user" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "Unexpected user name '$user'. Stopping before touching sudo." >&2
    exit 1
  fi
  echo "macOS asks for your password once, to allow these two commands and nothing else:"
  echo "  /usr/bin/pmset -a disablesleep 0"
  echo "  /usr/bin/pmset -a disablesleep 1"
  comment="# Lets $user turn sleep on and off without a password. Added by Pauline, removed by its uninstall.sh."
  line="$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
  # Root writes the rule itself, so no process of the user can swap its content before it is installed.
  # It goes under a name sudo skips (it has a dot), visudo checks it (a broken sudoers file can lock sudo),
  # then it moves in place.
  next="/etc/sudoers.d/.pauline.new"
  as_root "umask 0337 && { /bin/echo '$comment'; /bin/echo '$line'; } > $next \
&& /usr/sbin/chown root:wheel $next && /usr/sbin/visudo -cf $next >/dev/null && /bin/mv -f $next $rule \
|| { /bin/rm -f $next; exit 1; }"
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
	<!-- Time to send the closing Telegram message before launchd forces the quit. -->
	<key>ExitTimeOut</key>
	<integer>15</integer>
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

printf '\nDone. Pauline is in your menu bar.\n'
printf '  Click        Stay awake, even with the lid closed.\n'
printf '  Click again  Sleep normally.\n'
printf '  Right-click  Status, battery, Telegram and Quit.\n'
