import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: swift make-icon.swift <source.png> <output-master.png>")
    exit(1)
}

func rgbaRep(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
    )!
}

func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    body()
    NSGraphicsContext.restoreGraphicsState()
}

guard let source = NSImage(contentsOfFile: args[1]), let firstRep = source.representations.first else {
    print("cannot read \(args[1])")
    exit(1)
}
let w = firstRep.pixelsWide
let h = firstRep.pixelsHigh
let norm = rgbaRep(width: w, height: h)
draw(into: norm) {
    source.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
}

let bytes = norm.bitmapData!
let stride = norm.bytesPerRow

func strength(_ x: Int, _ y: Int) -> Int {
    let p = y * stride + x * 4
    return max(0, Int(bytes[p + 2]) - Int(bytes[p]))
}

var minX = w, maxX = 0, minY = h, maxY = 0
var coreStrength = 0
var core = (r: 10, g: 132, b: 255)
for y in 0..<h {
    for x in 0..<w {
        let s = strength(x, y)
        if s > 38 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            if s > coreStrength {
                coreStrength = s
                let p = y * stride + x * 4
                core = (Int(bytes[p]), Int(bytes[p + 1]), Int(bytes[p + 2]))
            }
        }
    }
}

guard maxX > minX, coreStrength > 76 else {
    print("no glyph found")
    exit(1)
}

let gw = maxX - minX + 1
let gh = maxY - minY + 1
let glyph = rgbaRep(width: gw, height: gh)
let glyphBytes = glyph.bitmapData!
let glyphStride = glyph.bytesPerRow
for y in 0..<gh {
    for x in 0..<gw {
        var alpha = min(255, strength(minX + x, minY + y) * 255 / coreStrength)
        if alpha < 24 { alpha = 0 }
        let p = y * glyphStride + x * 4
        glyphBytes[p] = UInt8(core.r * alpha / 255)
        glyphBytes[p + 1] = UInt8(core.g * alpha / 255)
        glyphBytes[p + 2] = UInt8(core.b * alpha / 255)
        glyphBytes[p + 3] = UInt8(alpha)
    }
}
let glyphImage = NSImage(size: NSSize(width: gw, height: gh))
glyphImage.addRepresentation(glyph)

let master = rgbaRep(width: 1024, height: 1024)
draw(into: master) {
    let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(deviceRed: 0.949, green: 0.957, blue: 0.969, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    let targetWidth = 824.0 * 0.62
    let scale = targetWidth / Double(gw)
    let targetHeight = Double(gh) * scale
    glyphImage.draw(
        in: NSRect(x: (1024 - targetWidth) / 2, y: (1024 - targetHeight) / 2, width: targetWidth, height: targetHeight),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
}

guard let png = master.representation(using: .png, properties: [:]) else {
    print("png encode failed")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (glyph \(gw)x\(gh), core rgb \(core.r),\(core.g),\(core.b))")
