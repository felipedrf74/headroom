#!/usr/bin/swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Kind {
    case lightOnDark
    case darkOnLight
}

struct Job {
    var name: String
    var source: URL
    var kind: Kind
}

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let assets = URL(fileURLWithPath: CommandLine.arguments[1])

let jobs = [
    Job(
        name: "GlyphBuild",
        source: scriptDir.appendingPathComponent("grok.svg"),
        kind: .darkOnLight
    ),
    Job(
        name: "GlyphBot",
        source: URL(fileURLWithPath: "/Applications/Grok Bot.app/Contents/Resources/icon.icns"),
        kind: .lightOnDark
    ),
    Job(
        name: "GlyphGPT",
        source: scriptDir.appendingPathComponent("openai.svg"),
        kind: .darkOnLight
    ),
]

func loadCGImage(_ url: URL) -> CGImage? {
    if let image = NSImage(contentsOf: url) {
        var rect = NSRect(origin: .zero, size: image.size)
        if image.size.width < 128 {
            image.size = NSSize(width: 256, height: 256)
            rect.size = image.size
        }
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [
            .interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)
        ])
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
}

func pixels(from image: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (data, width, height)
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func markAlpha(luminance l: Double, alpha a: Double, kind: Kind) -> Double {
    guard a > 0.08 else { return 0 }
    switch kind {
    case .lightOnDark:
        return smoothstep(0.46, 0.78, l)
    case .darkOnLight:
        return smoothstep(0.42, 0.16, l)
    }
}

func keepLargestComponent(_ alpha: inout [Double], width: Int, height: Int) {
    let count = width * height
    var label = [Int](repeating: -1, count: count)
    var sizes: [Int] = []
    var best = -1
    var bestSize = 0
    let dirs = [-1, 1, -width, width]

    for start in 0..<count {
        guard alpha[start] > 0.12, label[start] == -1 else { continue }
        let id = sizes.count
        var size = 0
        var stack = [start]
        label[start] = id
        while let i = stack.popLast() {
            size += 1
            let x = i % width
            for d in dirs {
                if d == -1 && x == 0 { continue }
                if d == 1 && x == width - 1 { continue }
                let n = i + d
                guard n >= 0, n < count, label[n] == -1, alpha[n] > 0.12 else { continue }
                label[n] = id
                stack.append(n)
            }
        }
        sizes.append(size)
        if size > bestSize {
            bestSize = size
            best = id
        }
    }

    guard best >= 0 else { return }
    for i in 0..<count where label[i] != best {
        alpha[i] = 0
    }
}

func extract(_ image: CGImage, kind: Kind) -> CGImage? {
    guard let packed = pixels(from: image) else { return nil }
    let width = packed.width
    let height = packed.height
    var alphaMap = [Double](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let r = Double(packed.data[i]) / 255
            let g = Double(packed.data[i + 1]) / 255
            let b = Double(packed.data[i + 2]) / 255
            let a = Double(packed.data[i + 3]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            alphaMap[y * width + x] = markAlpha(luminance: l, alpha: a, kind: kind)
        }
    }
    keepLargestComponent(&alphaMap, width: width, height: height)
    for i in 0..<alphaMap.count {
        let a = alphaMap[i]
        if a < 0.28 {
            alphaMap[i] = 0
        } else if a > 0.55 {
            alphaMap[i] = 1
        }
    }

    var coreMinX = width, coreMinY = height, coreMaxX = 0, coreMaxY = 0
    for y in 0..<height {
        for x in 0..<width {
            if alphaMap[y * width + x] > 0.7 {
                coreMinX = min(coreMinX, x)
                coreMinY = min(coreMinY, y)
                coreMaxX = max(coreMaxX, x)
                coreMaxY = max(coreMaxY, y)
            }
        }
    }
    if coreMaxX > coreMinX {
        let slop = max(2, Int(Double(max(coreMaxX - coreMinX, coreMaxY - coreMinY)) * 0.04))
        for y in 0..<height {
            for x in 0..<width {
                if x < coreMinX - slop || x > coreMaxX + slop || y < coreMinY - slop || y > coreMaxY + slop {
                    alphaMap[y * width + x] = 0
                }
            }
        }
    }

    func rowFill(_ y: Int) -> Double {
        var sum = 0.0
        for x in 0..<width { sum += alphaMap[y * width + x] }
        return sum / Double(width)
    }
    func colFill(_ x: Int) -> Double {
        var sum = 0.0
        for y in 0..<height { sum += alphaMap[y * width + x] }
        return sum / Double(height)
    }
    var y0 = 0
    while y0 < height, rowFill(y0) < 0.035 { y0 += 1 }
    var y1 = height - 1
    while y1 > y0, rowFill(y1) < 0.035 { y1 -= 1 }
    var x0 = 0
    while x0 < width, colFill(x0) < 0.035 { x0 += 1 }
    var x1 = width - 1
    while x1 > x0, colFill(x1) < 0.035 { x1 -= 1 }
    for y in 0..<height {
        for x in 0..<width {
            if y < y0 || y > y1 || x < x0 || x > x1 {
                alphaMap[y * width + x] = 0
            }
        }
    }

    var minX = width, minY = height, maxX = 0, maxY = 0
    for y in 0..<height {
        for x in 0..<width {
            if alphaMap[y * width + x] > 0.12 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    guard maxX > minX, maxY > minY else { return nil }

    let bw = maxX - minX + 1
    let bh = maxY - minY + 1
    let pad = Int((Double(max(bw, bh)) * (kind == .darkOnLight ? 0.20 : 0.12)).rounded(.up))
    let side = max(bw, bh) + pad * 2
    let ox = (side - bw) / 2
    let oy = (side - bh) / 2

    var out = [UInt8](repeating: 0, count: side * side * 4)
    for y in 0..<bh {
        for x in 0..<bw {
            let src = alphaMap[(minY + y) * width + (minX + x)]
            let dx = ox + x
            let dy = oy + y
            let o = (dy * side + dx) * 4
            let a = UInt8(min(max(src * 255, 0), 255).rounded())
            out[o] = 0
            out[o + 1] = 0
            out[o + 2] = 0
            out[o + 3] = a
        }
    }

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: &out,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    return ctx.makeImage()
}

func scaled(_ image: CGImage, to size: Int) -> CGImage? {
    var data = [UInt8](repeating: 0, count: size * size * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: &data,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "glyph", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "glyph", code: 2)
    }
}

for job in jobs {
    guard let source = loadCGImage(job.source),
          let mark = extract(source, kind: job.kind)
    else {
        fputs("failed \(job.name)\n", stderr)
        continue
    }
    let folder = assets.appendingPathComponent("\(job.name).imageset")
    let sizes = [(1, 24), (2, 48), (3, 72)]
    var contents: [[String: Any]] = []
    for (scale, px) in sizes {
        guard let img = scaled(mark, to: px) else { continue }
        let filename = scale == 1 ? "\(job.name).png" : "\(job.name)@\(scale)x.png"
        try writePNG(img, to: folder.appendingPathComponent(filename))
        contents.append([
            "filename": filename,
            "idiom": "universal",
            "scale": "\(scale)x",
        ])
        print("wrote \(job.name) \(px)px")
    }
    let json: [String: Any] = [
        "images": contents,
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appendingPathComponent("Contents.json"))
}
