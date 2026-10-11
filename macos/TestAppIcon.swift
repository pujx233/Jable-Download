import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let bundle = CommandLine.arguments[2]

func rgba(_ image: CGImage) -> [UInt8] {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                    count: image.width * image.height * 4))
}

// Input assets must not carry web rounding, an inset, or an outer alpha mask.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        let data = try Data(contentsOf: iconset.appendingPathComponent(name))
        let image = NSBitmapImageRep(data: data)!.cgImage!
        precondition(image.width == pixels && image.height == pixels, "Wrong dimensions: \(name)")
        let bytes = rgba(image)
        precondition(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 },
                     "Artwork must be opaque and full-bleed: \(name)")
        print("Icon input: \(name), \(pixels)x\(pixels), fully opaque")
    }
}

func systemIcon(_ path: String, pixels: Int = 1024) -> NSBitmapImageRep {
    let icon = NSWorkspace.shared.icon(forFile: path)
    let pointSize = CGFloat(pixels) / 2
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    bitmap.size = NSSize(width: pointSize, height: pointSize)
    icon.size = bitmap.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    icon.draw(in: NSRect(origin: .zero, size: bitmap.size))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

// Check the actual platform-rendered enclosure, rather than a hand-made radius.
let rendered = rgba(systemIcon(bundle).cgImage!)
let reference = rgba(systemIcon("/System/Library/CoreServices/Finder.app").cgImage!)
for threshold in [8, 128, 240] {
    let differences = stride(from: 3, to: rendered.count, by: 4).filter {
        (Int(rendered[$0]) >= threshold) != (Int(reference[$0]) >= threshold)
    }.count
    precondition(differences <= 1024, "Native enclosure differs from Finder: \(differences) pixels")
    print("Native enclosure, alpha >= \(threshold): \(differences) / 1048576 differing pixels")
}
if CommandLine.arguments.count > 3 {
    try systemIcon(bundle, pixels: 256).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
