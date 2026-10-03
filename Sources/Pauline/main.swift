import AppKit

let label = "com.gamween.pauline"

// install.sh starts Pauline through launchd with --launchd, so launchd relaunches it after a crash.
// When it is opened from Finder or Spotlight instead, hand over to that launchd copy if it exists.
if !CommandLine.arguments.contains("--launchd"),
   Shell.run("/bin/launchctl", "kickstart", "gui/\(getuid())/\(label)") == 0 {
    exit(0)
}

// One copy at a time. The kernel drops the lock however the process ends, crash included.
let lock = open(NSTemporaryDirectory() + "\(label).lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, only the menu bar button (LSUIElement does the same once bundled).
app.setActivationPolicy(.accessory)
app.run()
