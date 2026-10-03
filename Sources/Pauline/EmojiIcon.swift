import AppKit

/// The menu bar icon: two Apple emoji in one ink, black on a light menu bar and white on a dark one.
/// The Apple Color Emoji font of the Mac draws them at launch, and their shading turns into the ink's opacity.
enum EmojiIcon {
    /// Pauline off, the Mac sleeps normally: woman getting a massage.
    @MainActor static let off = make("\u{1F486}\u{200D}\u{2640}\u{FE0F}", description: "Pauline off")
    /// Pauline on, the Mac stays awake: woman technologist.
    @MainActor static let on = make("\u{1F469}\u{200D}\u{1F4BB}", description: "Pauline on")

    /// Apple Color Emoji's largest bitmap is 160 px: drawn at that size, the icon stays sharp at 18 pt on Retina.
    private static let side = 160
    private static let pointSize: CGFloat = 18
    /// The lightest part of the emoji keeps this much ink, so its outline never vanishes into the menu bar.
    private static let minimumInk = 0.15

    private static func make(_ emoji: String, description: String) -> NSImage {
        let pixels = draw(emoji)
        // Dark menu bar: white ink where the emoji is light. Light menu bar: black ink where it is dark.
        let light = ink(pixels, white: false), dark = ink(pixels, white: true)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            let appearance = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            let isDark = appearance == .darkAqua || appearance == .vibrantDark
            NSGraphicsContext.current?.cgContext.draw(isDark ? dark : light, in: rect)
            return true
        }
        // Drawn again whenever the menu bar switches between light and dark.
        image.cacheMode = .never
        image.accessibilityDescription = description
        return image
    }

    /// The emoji in color, centered in a square bitmap, as premultiplied RGBA bytes.
    private static func draw(_ emoji: String) -> [UInt8] {
        let bitmap = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let font = NSFont(name: "AppleColorEmoji", size: CGFloat(side) * 0.9)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: font]))
        // The glyph's square box, the same for both emoji, so they share one frame and baseline.
        let box = CTLineGetImageBounds(line, bitmap)
        bitmap.textPosition = CGPoint(
            x: (CGFloat(side) - box.width) / 2 - box.minX, y: (CGFloat(side) - box.height) / 2 - box.minY
        )
        CTLineDraw(line, bitmap)
        return Array(UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
    }

    /// The emoji in a single ink: its lightness (for white ink) or darkness (for black ink) becomes opacity.
    private static func ink(_ emoji: [UInt8], white: Bool) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: emoji.count)
        for i in stride(from: 0, to: emoji.count, by: 4) where emoji[i + 3] > 0 {
            let alpha = Double(emoji[i + 3]) / 255
            // Premultiplied channels divided by alpha give the color, then its perceived lightness.
            let lightness = min(1, (0.299 * Double(emoji[i]) + 0.587 * Double(emoji[i + 1]) + 0.114 * Double(emoji[i + 2])) / 255 / alpha)
            let opacity = alpha * (minimumInk + (1 - minimumInk) * (white ? lightness : 1 - lightness))
            let value = UInt8(opacity * 255)
            pixels[i + 3] = value
            if white {
                (pixels[i], pixels[i + 1], pixels[i + 2]) = (value, value, value)
            }
        }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }
}
