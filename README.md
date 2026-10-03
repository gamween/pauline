# Pauline

A macOS menu bar app that keeps a MacBook awake with the lid closed.

Turn it on, close the lid, and your builds, downloads and coding agents keep running. Turn it off and the Mac sleeps normally again. `caffeinate` and the apps built on it cannot do this: they block idle sleep, and closing the lid is not idle.

Pauline can also message you through your own Telegram bot: when it turns on, when the battery runs low and when it turns off. You can turn it off from your phone.

## Requirements

- macOS 14.5 or later
- Swift 6: Xcode 16 or later, or its Command Line Tools (`xcode-select --install`)
- An administrator account

## Install

```bash
git clone https://github.com/gamween/pauline.git
cd pauline
./install.sh
```

Run the script as your user, not with `sudo`. It builds the app from source, copies it to `/Applications` and adds a launch agent that starts Pauline at every login and relaunches it after a crash. Pauline then appears in the menu bar. macOS may show a "Background Items Added" notice: that is Pauline.

The script asks for your password once, to add one sudoers rule in `/etc/sudoers.d/pauline`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Your user can run these two commands without a password, and nothing else. `visudo` checks the rule before it goes in place. There is no daemon and no privileged helper: the app runs as your user.

Keep the cloned folder. To update, run `git pull && ./install.sh`. The rule is already there, so no password this time.

## Use

| Action | Result |
| --- | --- |
| Click the icon | Turn Pauline on or off |
| Right-click or Control-click | Menu: state, battery, **Stay Awake** or **Allow Sleep**, Telegram, **Quit Pauline** |

The icon is the Apple emoji of a woman getting a massage while Pauline is off and the Mac sleeps normally, and a woman at her laptop while Pauline is on and the Mac stays awake, even with the lid closed. Pauline draws them at launch from the Apple Color Emoji font of your Mac, in one color that follows a light or dark menu bar. No emoji artwork ships with the app.

Quitting turns Pauline off. To start it again, open it from Applications or Spotlight, or log in again.

## How it works

`pmset -a disablesleep 1` sets the system-wide `SleepDisabled` flag. It is the only setting that also keeps a closed lid awake, and it needs root. Pauline runs `sudo -k -n /usr/bin/pmset -a disablesleep 1`: `-n` never prompts and `-k` ignores a password cached in a terminal, so only the sudoers rule lets it through. Turning off is the same command with `0`.

Every 5 seconds, Pauline reads the flag and the lid from the kernel, along with the battery, the displays and the thermal state. The icon always shows the real state, even when you change the flag from Terminal. Putting the Mac or its screen to sleep (`pmset sleepnow`, `pmset displaysleepnow`) needs no root.

## Safety

`disablesleep` applies to the whole system and survives a restart. While it is on, macOS also skips its own emergency sleep for heat and an empty battery. Pauline does that job instead:

| Case | What Pauline does |
| --- | --- |
| Battery at or under 5% and not charging | Turns off. A closed Mac without an external display goes to sleep. |
| macOS reports a critical temperature | Same. |
| You try to turn it on in either case | Refuses, with an alert that says why. |
| Quit, log out, restart, shut down | Gives sleep back before it exits. |
| Pauline crashes | launchd relaunches it within seconds. Every launch starts off. |
| The Mac restarts | The flag survives, so Pauline turns it off when it starts at login. |
| Built-in screen still lit behind the closed lid | Turns the screen off. |
| External display connected | Never puts the Mac or its screens to sleep. |

A closed MacBook under heavy load still gets hot. Leave it on a desk, not in a bag.

To change the battery floor (it applies within 5 seconds):

```bash
defaults write com.gamween.pauline BatteryFloor -int 10   # 0 turns the floor off
defaults delete com.gamween.pauline BatteryFloor          # back to 5%
```

## Telegram

Optional. Pauline talks to your own bot through the Telegram Bot API, with long polling from your Mac. There is no server in between.

### Connect

1. Right-click the icon, then **Connect Telegram…**
2. Click **Open BotFather**, send `/newbot` and follow the steps. Use a new bot for each Mac: two Macs cannot read the same bot.
3. Paste the token BotFather gives you and click **Connect**.
4. Telegram opens the chat with your bot. Tap **Start**. If Telegram is only on your phone, scan the QR code Pauline shows. **Open the Bot Chat…** in the menu brings the link back until you tap Start.

The bot answers `Pauline is connected.` with its commands. The Start link carries a one-time code, so only your chat gets linked. After that, the bot ignores every other chat.

### Messages

Each message gives the state, then the battery:

```
Pauline is on
Battery 94%, 20 h left
```

| When | First line |
| --- | --- |
| Pauline turns on | `Pauline is on`, with a **Turn Pauline off** button |
| The battery drops to 30%, 20% and 10% while not charging | `Pauline is on`, with the same button |
| Charging ends: full, or held at 80% by Optimized Battery Charging | `Pauline is on` |
| Pauline turns off, whatever the cause | `Pauline is off`, with a reason in some cases |

The battery line follows the power source: `Battery 41%, 3 h 20 min left`, `Battery 64%, charging, full in 1 h 12 min` or `Battery 100%, charged`.

| Reason | Cause |
| --- | --- |
| `(battery low)` | The battery floor was reached |
| `(too hot)` | macOS reported a critical temperature |
| `(logged out)`, `(Mac restarting)`, `(Mac shut down)` | You logged out, restarted or shut down |
| `(Pauline crashed)` | Pauline crashed. Sent when launchd relaunches it. |
| `(Mac restarted)` | Power loss, kernel panic or forced restart. Sent at the next login. |

The icon, the menu, `/off`, the button, Quit, a reinstall and `pmset` in Terminal close without a reason.

The closing message is always the last one of a session. Pauline saves the session to disk before the opening message goes out, so a crash, a restart or a network outage only delays the closing message. Reminders and replies that cannot leave within 2 minutes are dropped. A closed Mac waits at most 10 seconds for the closing message before going to sleep.

### Commands

| Command | Answer |
| --- | --- |
| `/status` | `Pauline is on` or `Pauline is off`, then the battery |
| `/off` | Turns Pauline off and sends the closing message. A closed Mac without an external display goes to sleep. It never shuts down. |

The **Turn Pauline off** button works like `/off`. Any other message gets the list of commands.

The token, the chat ID and the open session are stored in `~/Library/Application Support/Pauline/telegram.json`, readable by your user only. **Disconnect Telegram** in the menu deletes the file. If Pauline is on at that moment, the chat first gets `Pauline is disconnected from this chat. It is still on.` If the token stops working or the bot is blocked, the menu says so.

## Uninstall

From the cloned folder:

```bash
./uninstall.sh
```

It stops Pauline and gives sleep back. If the closing message has not gone out yet, it tries once more to send it. Then it removes the app, the launch agent, the settings, the Telegram file and the sudoers rule. It asks for your password to remove the rule.

## Development

```bash
./build.sh   # release build in build/Pauline.app, signed ad hoc
swift test   # PaulineCore tests
```

A plain SwiftPM package, with no Xcode project and no dependencies. `build.sh` works with the Command Line Tools. `swift test` uses Swift Testing and needs Xcode: with the Command Line Tools alone, `import Testing` fails.

To try a change, run `./install.sh` again. It rebuilds, replaces the installed app and restarts it, without asking for the password. While Pauline is installed, a copy started any other way (`open`, `swift run`) hands over to the installed one and exits.

```
Sources/PaulineCore/     rules and texts in plain Swift, no system calls, unit tested
  Policy.swift           power state, battery floor, heat, what to do at launch and on each check
  Notifier.swift         when to send a battery reminder or the charging message
  TelegramText.swift     every message the bot sends
  StatusText.swift       menu, tooltip and refusal alert texts
Sources/Pauline/         the AppKit app: reads the system, runs pmset, talks to Telegram
  main.swift             entry point, one copy at a time, handover to launchd
  AppDelegate.swift      icon, menu, checks every 5 seconds, quitting, Telegram setup
  System.swift           IOKit and display readings, pmset calls
  Telegram.swift         Bot API client, long polling, ordered outbox, sessions on disk
  QRCode.swift           the Start link as a QR code
  EmojiIcon.swift        the two Apple emoji as monochrome menu bar icons
Tests/PaulineCoreTests/  Swift Testing suites
Support/Info.plist       bundle metadata, menu bar only
Support/common.sh        paths and helpers shared by the install scripts
build.sh                 builds build/Pauline.app
install.sh               app, sudoers rule, launch agent
uninstall.sh             removes all of it
```

## License

MIT. See [LICENSE](LICENSE).
