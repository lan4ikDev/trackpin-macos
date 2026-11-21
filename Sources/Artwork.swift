import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Downloads the album cover, shrinks it for the widget and samples its colors.
enum Artwork {
    /// For the mini player, which shows the cover up to about 330 pt wide.
    static let maxPixelSize = 600
    /// For the widget. WidgetKit refuses to draw a widget whose images together exceed an area
    /// tied to the widget's own size, and then silently keeps showing the previous render (a
    /// stale track, or a note instead of the cover). 300 px stays well below that limit even
    /// with the cover drawn twice (cover and blurred background) on the small widget.
    static let widgetPixelSize = 300

    struct Loaded {
        /// JPEG, at most `maxPixelSize`.
        let data: Data
        /// JPEG, at most `widgetPixelSize`.
        let widgetData: Data
        let palette: ArtworkPalette?
    }

    /// Loads a cover from the web, or from a local file (Apple Music covers are cached as files).
    static func load(_ url: URL) async -> Loaded? {
        let original: Data
        if url.isFileURL {
            guard let local = try? Data(contentsOf: url) else { return nil }
            original = local
        } else {
            guard let remote = await download(url) else { return nil }
            original = remote
        }
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let large = thumbnail(source, maxPixelSize), let small = thumbnail(source, widgetPixelSize),
              let data = jpeg(large), let widgetData = jpeg(small) else { return nil }
        return Loaded(data: data, widgetData: widgetData, palette: palette(of: small))
    }

    /// Short timeouts: the widget waits for the cover, and a stuck request would otherwise
    /// hold it for the default 60 seconds.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Downloads `url`, trying again twice after a network error or a server error (5xx, 429).
    /// A missing cover (404 and the like) is not retried.
    private static func download(_ url: URL) async -> Data? {
        let pauses: [UInt64] = [700_000_000, 2_000_000_000]
        for attempt in 0...pauses.count {
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                guard status == 429 || (500...599).contains(status) else { return nil }
            } catch {
                if Task.isCancelled { return nil }
            }
            guard attempt < pauses.count else { break }
            try? await Task.sleep(nanoseconds: pauses[attempt])
        }
        return nil
    }

    private static func thumbnail(_ source: CGImageSource, _ size: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size
        ] as CFDictionary)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
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
