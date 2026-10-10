import AppKit

// Compares two PNGs pixel by pixel: prints how many pixels differ by more than 2 in any channel, out of how many, and
// the largest channel difference. Writes the differing pixels in red over a dimmed copy of the first PNG when asked.
// Usage: swift compare.swift <a.png> <b.png> [diff.png]
func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard (3 ... 4).contains(CommandLine.arguments.count) else { fail("usage: compare.swift <a.png> <b.png> [diff.png]", code: 2) }

// Both images are redrawn into one sRGB bitmap layout, so PNGs tagged with different profiles still compare.
func pixels(_ path: String) -> (width: Int, height: Int, bytes: [UInt8]) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("not an image: \(path)") }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drawn else { fail("cannot draw: \(path)") }
    return (image.width, image.height, bytes)
}

let a = pixels(CommandLine.arguments[1])
let b = pixels(CommandLine.arguments[2])
guard a.width == b.width, a.height == b.height else { fail("size differs: \(a.width)x\(a.height) and \(b.width)x\(b.height)") }

var differing = 0
var largest = 0
var diff = a.bytes
for pixel in 0 ..< a.width * a.height {
    let offset = pixel * 4
    let delta = (0 ..< 4).map { abs(Int(a.bytes[offset + $0]) - Int(b.bytes[offset + $0])) }.max()!
    largest = max(largest, delta)
    if delta > 2 {
        differing += 1
        diff.replaceSubrange(offset ..< offset + 4, with: [255, 0, 0, 255])
    } else {
        for channel in 0 ..< 3 { diff[offset + channel] /= 3 }
    }
}
print("differing", differing, "of", a.width * a.height, "max", largest)

if CommandLine.arguments.count == 4 {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: a.width, pixelsHigh: a.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: a.width * 4, bitsPerPixel: 32
    )!
    rep.bitmapData!.update(from: diff, count: diff.count)
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("cannot encode the diff") }
    do {
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    } catch {
        fail("cannot write the diff: \(error.localizedDescription)")
    }
}
