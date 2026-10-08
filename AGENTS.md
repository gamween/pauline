# Pauline

Pauline is a macOS menu bar app that controls system sleep and optionally sends
Telegram notifications. Keep safety rules in PaulineCore and system integration
in Pauline.

## Validation

- `swift test` runs the Swift Testing suites; full Xcode is required.
- `./build.sh` builds and signs the release app. Compilation checks Swift types.
- `bash -n build.sh install.sh uninstall.sh Support/common.sh` checks shell syntax.
- No separate lint tool is configured. Check `git diff --check` before committing.

## Operational constraints

- Tests must not run real privileged power commands or use personal Telegram data.
- `install.sh` replaces the app, installs a LaunchAgent and adds a sudoers rule.
  Building alone does not install anything.
- The system sleep flag survives reboots. Power changes need bounded execution,
  serialized transitions and a verified restoration during shutdown.
- Modal AppKit alerts must be scheduled outside MainActor tasks.
- A locally opened app hands over to the installed launchd instance, if present.
- Keep credentials out of logs, test fixtures and command arguments.
