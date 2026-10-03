import AppKit
import CoreImage.CIFilterBuiltins

/// The Start link as a QR code, for a phone when Telegram is not installed on the Mac.
func qrCode(for url: URL, size: CGFloat) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scale = size / output.extent.width
    let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}
