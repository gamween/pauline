import AppKit

/// The menu bar button, drawn as an on/off switch: an outlined track with the knob on the left
/// when sleep is normal, a filled track with the knob on the right while the Mac stays awake.
/// A template image, so macOS paints it in the menu bar color, light or dark.
enum SwitchIcon {
    static let size = NSSize(width: 30, height: 18)

    static func image(on: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let track = NSRect(x: 1, y: 2, width: 28, height: 14)
            let radius = track.height / 2
            NSColor.black.set()

            if on {
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
                // Knob punched out of the filled track, on the right.
                let knob = NSRect(x: track.maxX - 12.5, y: track.minY + 2.5, width: 9, height: 9)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: knob).fill()
            } else {
                let outline = track.insetBy(dx: 0.75, dy: 0.75)
                let path = NSBezierPath(roundedRect: outline, xRadius: radius - 0.75, yRadius: radius - 0.75)
                path.lineWidth = 1.5
                path.stroke()
                let knob = NSRect(x: track.minX + 3.5, y: track.minY + 3.5, width: 7, height: 7)
                NSBezierPath(ovalIn: knob).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = on ? "Pauline on" : "Pauline off"
        return image
    }
}
