import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Downloads the album cover, shrinks it for the widget and samples its colors.
enum Artwork {
    /// Big enough for the large widget on a Retina display.
    static let maxPixelSize = 600

    /// Loads a cover from the web, or from a local file (Apple Music covers are cached as files).
    static func load(_ url: URL) async -> (data: Data, palette: ArtworkPalette?)? {
        let data: Data
        if url.isFileURL {
            guard let local = try? Data(contentsOf: url) else { return nil }
            data = local
        } else {
            guard let (remote, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            data = remote
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, palette(of: thumbnail))
    }

    /// A 160 px, strongly blurred and saturated copy of the cover, rendered once per track.
    static func blurred(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary) else { return nil }
        let input = CIImage(cgImage: small)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.06])
            .cropped(to: input.extent)
        guard let image = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Two dark background colors (top and bottom halves of the cover) and a light accent
    /// taken from the most saturated part, so white text stays readable on any cover.
    static func palette(of image: CGImage) -> ArtworkPalette? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var top = (r: 0.0, g: 0.0, b: 0.0), bottom = (r: 0.0, g: 0.0, b: 0.0)
        var vivid = (r: 0.5, g: 0.5, b: 0.5), vividScore = -1.0
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                // Bitmap context memory starts with the top row of the image.
                if y < side / 2 { top.r += r; top.g += g; top.b += b } else { bottom.r += r; bottom.g += g; bottom.b += b }
                let maxC = max(r, g, b), minC = min(r, g, b)
                let score = (maxC - minC) * (0.4 + maxC)
                if score > vividScore { vividScore = score; vivid = (r, g, b) }
            }
        }
        let half = Double(side * side / 2)
        return ArtworkPalette(
            top: adjust(top.r / half, top.g / half, top.b / half, brightness: 0.18...0.40),
            bottom: adjust(bottom.r / half, bottom.g / half, bottom.b / half, brightness: 0.08...0.20),
            accent: accent(vivid.r, vivid.g, vivid.b)
        )
    }

    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return (h, s, v)
    }

    private static func rgb(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> RGB {
        let color = NSColor(hue: h, saturation: s, brightness: v, alpha: 1).usingColorSpace(.sRGB) ?? .gray
        return RGB(r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
    }

    private static func adjust(_ r: Double, _ g: Double, _ b: Double, brightness: ClosedRange<CGFloat>) -> RGB {
        let (h, s, v) = hsb(r, g, b)
        return rgb(h, min(s * 1.15, 0.8), min(max(v * 0.6, brightness.lowerBound), brightness.upperBound))
    }

    private static func accent(_ r: Double, _ g: Double, _ b: Double) -> RGB {
        let (h, s, _) = hsb(r, g, b)
        // A grey cover gets an almost white accent instead of a random tint.
        return s < 0.12 ? rgb(0, 0, 0.94) : rgb(h, min(max(s, 0.3), 0.55), 0.98)
    }
}
