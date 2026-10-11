import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard let source = NSBitmapImageRep(data: sourceData)?.cgImage else {
    throw NSError(domain: "JableIcon", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "无法读取网站原始图标"])
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let sample = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                       bytesPerRow: source.width * 4, space: colorSpace,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sample.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
let samples = sample.data!.assumingMemoryBound(to: UInt8.self)
let backgroundIndex = (source.height / 2) * source.width * 4
let background = CGColor(colorSpace: colorSpace, components:
    (0..<3).map { CGFloat(samples[backgroundIndex + $0]) / 255 } + [1])!
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: pixels * 4, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        // Supply full-bleed, opaque square artwork. macOS applies its own
        // enclosure, scale and effects; padding or web-style corners here
        // cause the system to put the logo inside an additional background.
        context.setFillColor(background)
        context.fill(canvas)
        context.draw(source, in: canvas)
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
