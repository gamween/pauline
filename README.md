# Pauline

Keep your MacBook awake with the lid closed, from a single menu bar button.

Close the lid and your downloads, builds, renders and coding agents (Claude Code, Codex...) keep running. Click again and the Mac sleeps normally.

## How it works

1. Click the switch in the menu bar. It turns on.
2. Pauline runs `pmset -a disablesleep 1`, the macOS setting that keeps a Mac awake when the lid closes.
3. Click again: Pauline runs `pmset -a disablesleep 0` and normal sleep is back.

`caffeinate` and the apps built on it (KeepingYouAwake, Raycast Coffee...) cannot do this: they only block *idle* sleep, and closing the lid is not idle.

## Install

Requires macOS 14.5 or later, an administrator account, and Swift 6 from Xcode 16+ or its Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/gamween/pauline.git
cd pauline
./install.sh
```

The script builds the app, copies it to `/Applications`, and asks for your password **once** to add a rule that lets your user run exactly these two commands without a password, nothing else:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

Pauline then starts on its own at every login. macOS shows a "Background Items Added" notice the first time, that is Pauline.

Keep the `pauline` folder: you update with `git pull && ./install.sh` and uninstall from it.

## Use

| Action | Result |
| --- | --- |
| Click the switch | Stay awake with the lid closed, or sleep normally again |
| Right-click the switch | Status, battery, toggle, Telegram and Quit |

<p align="center">
  <img src="docs/switch.png" width="180" alt="The Pauline switch, off on the left and on on the right, in light and dark menu bars" />
</p>

| Switch | Meaning |
| --- | --- |
| Off: outline, knob on the left | Normal sleep |
| On: filled, knob on the right | Awake, even with the lid closed |

After Quit, open Pauline again from Applications or Spotlight.

## Safety

`disablesleep` is a system-wide setting, and it survives a restart. While it is on, macOS also skips its own emergency sleep for overheating and empty batteries. Left on by mistake, a MacBook in a bag keeps running until the battery is empty. Pauline guards against that:

- **Battery floor**: when the battery is not charging, it gives sleep back at 5% and puts a closed Mac to sleep right away. With [Telegram](#telegram) you get reminders at 30, 20 and 10% before that.
- **Heat**: same thing if macOS reports a critical temperature.
- **Starts off**: every launch resets to normal sleep, so after a crash or a restart the Mac sleeps normally again as soon as you log in.
- **Quit means sleep**: quitting Pauline or logging out restores normal sleep.
- **Back after a crash**: launchd relaunches it within seconds.
- **Honest icon**: it reads the real setting from macOS every 5 seconds, even if you change it in Terminal.
- **Dark screen**: if the built-in screen stays lit behind the closed lid, Pauline turns it off.

A closed MacBook under heavy load still gets hot. Leave it on a desk, not in a bag.

To change the battery floor (0 turns it off), run this, it applies within 5 seconds:

```bash
defaults write com.gamween.pauline BatteryFloor -int 10
```

## Telegram

Get messages from your Mac while it stays awake, and answer from your phone. Pauline talks to your own bot, there is no server in between.

1. Right-click the switch, then **Connect Telegram…**
2. Click **Open BotFather**, send `/newbot` and pick a name. BotFather gives you a token. Use a new bot for each Mac.
3. Paste the token in Pauline and click **Connect**.
4. Telegram opens the chat with your bot: tap **Start**. No Telegram on this Mac? Scan the QR code Pauline shows with your phone. Pauline answers "Pauline is connected".

Each time the switch goes on, the chat gets a session:

| When | Message |
| --- | --- |
| Stay awake turns on | `Stay awake is on, lid open.` and the battery, with an **Allow sleep** button |
| Battery at 30%, 20% and 10% | `Battery at 20%, 1 h 5 min left. Your Mac is still awake, lid closed. Stay awake turns off on its own at 5%.` with an **Allow sleep** button |
| Charging is done and the Mac runs on the adapter | `Charging done at 100%. Running on the power adapter.` |
| Stay awake turns off, whatever the reason | `Stay awake is off. Battery reached 5%.`, `On from 11:02 to 14:32 (3 h 30 min).` and `Your Mac is going to sleep.` |

The closing message is always the last one of a session:

| Stay awake ends because | The closing message leaves |
| --- | --- |
| You click the switch, or **Allow Sleep** in the menu | right away |
| You send `/off` or tap **Allow sleep** | right away |
| The battery reaches 5%, or the Mac overheats | right away, before the Mac goes to sleep |
| You quit, update or uninstall Pauline, log out, restart or shut down | before Pauline quits |
| You run `sudo pmset -a disablesleep 0` yourself | within a few seconds |
| Pauline crashes | when launchd starts it again, seconds later |
| The Mac turns off suddenly (forced restart, kernel panic, empty battery with the floor at 0) | at the next login |
| The Mac has no internet at that moment | when it is back online, or at the next launch of Pauline if it quit in the meantime |

**Disconnect Telegram** during a session sends a last message too: `Pauline is disconnected from this chat. Stay awake is still on, you will get no more messages here.`

| Command | Answer |
| --- | --- |
| `/status` | `Stay awake: on, lid closed` and the battery: `Battery: 64%, charging, full in 1 h 12 min`, or unplugged `Battery: 41%, not charging, 3 h 20 min left` |
| `/off` | Turns stay awake off, with the closing message. A closed Mac without an external display goes to sleep, it never shuts down. |

Once linked, the bot only answers the chat that tapped Start. A Mac in a bag far from its Wi-Fi has no internet: its opening and closing messages wait until it is back online, reminders and answers older than 2 minutes are skipped, and the safety rules above keep working. The token is stored in `~/Library/Application Support/Pauline`, readable by your user only. **Disconnect Telegram** in the menu removes it. If the bot gets blocked or its token stops working, the menu says so.

## Uninstall

```bash
./uninstall.sh
```

Gives sleep back, then removes the app, the login item, the settings, the Telegram link and the password rule. macOS asks for your password once more.

## Build from source

```bash
./build.sh   # builds build/Pauline.app
swift test   # runs the safety rule tests, needs Xcode
```

| Path | Content |
| --- | --- |
| `Sources/PaulineCore` | Safety rules in plain Swift, no system calls, unit tested |
| `Sources/Pauline` | The menu bar app: AppKit, IOKit, `pmset` and the Telegram client |
| `Tests/PaulineCoreTests` | Swift Testing suite |
| `install.sh`, `uninstall.sh` | Password rule, `/Applications` copy and login item |

## License

MIT
