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
| Right-click the switch | Status, battery, toggle and Quit |

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

- **Battery floor**: when the battery is not charging, it gives sleep back at 20% and puts a closed Mac to sleep right away.
- **Heat**: same thing if macOS reports a critical temperature.
- **Starts off**: every launch resets to normal sleep, so after a crash or a restart the Mac sleeps normally again as soon as you log in.
- **Quit means sleep**: quitting Pauline or logging out restores normal sleep.
- **Back after a crash**: launchd relaunches it within seconds.
- **Honest icon**: it reads the real setting from macOS every 5 seconds, even if you change it in Terminal.
- **Dark screen**: if the built-in screen stays lit behind the closed lid, Pauline turns it off.

A closed MacBook under heavy load still gets hot. Leave it on a desk, not in a bag.

To change the battery floor (0 turns it off), run this, it applies within 5 seconds:

```bash
defaults write com.gamween.pauline BatteryFloor -int 30
```

## Uninstall

```bash
./uninstall.sh
```

Gives sleep back, then removes the app, the login item, the settings and the password rule. macOS asks for your password once more.

## Build from source

```bash
./build.sh   # builds build/Pauline.app
swift test   # runs the safety rule tests, needs Xcode
```

| Path | Content |
| --- | --- |
| `Sources/PaulineCore` | Safety rules in plain Swift, no system calls, unit tested |
| `Sources/Pauline` | The menu bar app: AppKit, IOKit and `pmset` |
| `Tests/PaulineCoreTests` | Swift Testing suite |
| `install.sh`, `uninstall.sh` | Password rule, `/Applications` copy and login item |

## License

MIT
