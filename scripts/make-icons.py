#!/usr/bin/env python3
"""Builds Tokenroom's app icons from one drawing: a "T" made of two usage meters, white on orange.

  scripts/make-icons.py

Writes Icon Composer files, from which the system draws Liquid Glass and the dark, tinted, and
clear looks:

  TokenroomMobile/AppIcon.icon   iPhone
  TokenroomWatch/AppIcon.icon    Apple Watch (a smaller T, so it clears the round mask)
  Tokenroom/AppIcon.icon         Mac, for Xcode builds (Xcode also makes the macOS 15 sizes from it)

Then renders the Mac file with Icon Composer's ictool, each size drawn at that size, into the PNG
set the swiftc fallback in build.sh uses (Tokenroom/Assets.xcassets/AppIcon.appiconset) and into
docs/images/icon.png. Needs Xcode 26 or later.
"""
import json, os, shutil, subprocess, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
TOP, BOTTOM = "#FFB347", "#DE4F0A"  # background, top to bottom; the app's accent orange sits between

# The T on a 1024 canvas: a horizontal meter over a vertical one, each a track with a white fill.
BAR = 176                                  # thickness of both meters
CROSS_X, CROSS_Y, CROSS_W = 160, 204, 704  # crossbar
CROSS_FILL = 512                           # 73% used
STEM_Y, STEM_H = 420, 416                  # stem, centered, 40 below the crossbar
STEM_FILL = 232                            # 56% used, filled from the bottom
WATCH_SCALE, WATCH_SHIFT = 0.84, -8        # the Watch's round icon needs room at the edges


def color(hex_value):
    r, g, b = (int(hex_value[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return "srgb:%.5f,%.5f,%.5f,1.00000" % (r, g, b)


def capsule(x, y, w, h, scale, shift):
    x, y = 512 + (x - 512) * scale, 512 + (y - 512) * scale + shift
    w, h = w * scale, h * scale
    return '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f"/>' % (x, y, w, h, min(w, h) / 2)


def layer_svg(parts):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            '<g fill="#FFFFFF">%s</g></svg>' % "".join(parts))


def drawings(scale=1.0, shift=0):
    stem_x = 512 - BAR / 2
    track = layer_svg([capsule(CROSS_X, CROSS_Y, CROSS_W, BAR, scale, shift),
                       capsule(stem_x, STEM_Y, BAR, STEM_H, scale, shift)])
    fill = layer_svg([capsule(CROSS_X, CROSS_Y, CROSS_FILL, BAR, scale, shift),
                      capsule(stem_x, STEM_Y + STEM_H - STEM_FILL, BAR, STEM_FILL, scale, shift)])
    return {"Track.svg": track, "Fill.svg": fill}


def icon_json(platforms):
    # The fills are their own glass group in front, nearly opaque so they read white; the tracks
    # sit behind, faint and more translucent. The system tints both in the dark and tinted looks.
    return {
        "fill": {"linear-gradient": [color(TOP), color(BOTTOM)]},
        "groups": [
            {
                "layers": [{"image-name": "Fill.svg", "name": "Fill", "glass": True}],
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.1},
            },
            {
                "layers": [{"image-name": "Track.svg", "name": "Track", "glass": True, "opacity": 0.45}],
                "shadow": {"kind": "neutral", "opacity": 0.2},
                "translucency": {"enabled": True, "value": 0.4},
            },
        ],
        "supported-platforms": platforms,
    }


def write_icon(folder, platforms, scale=1.0, shift=0):
    if os.path.exists(folder):
        shutil.rmtree(folder)
    os.makedirs(os.path.join(folder, "Assets"))
    for name, drawing in drawings(scale, shift).items():
        with open(os.path.join(folder, "Assets", name), "w") as f:
            f.write(drawing)
    with open(os.path.join(folder, "icon.json"), "w") as f:
        json.dump(icon_json(platforms), f, indent=2, sort_keys=True)
        f.write("\n")


# Places an ictool render on the classic macOS grid: the shape at 824 of 1024, centered, with a
# soft shadow below, in sRGB.
COMPOSE = r'''
import AppKit
import UniformTypeIdentifiers
let args = Array(CommandLine.arguments.dropFirst())
for job in stride(from: 0, to: args.count, by: 3) {
    let size = Int(args[job + 1])!
    let scale = CGFloat(size) / 1024
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[job]) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
    let margin = (size - image.width) / 2
    context.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[job + 2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(args[job + 2])") }
}
'''


def mac_pngs(icon, outputs):
    """outputs: [(canvas size, path)]. Renders each at its own size: a 16-pixel icon from the vectors."""
    with tempfile.TemporaryDirectory() as tmp:
        jobs = []
        for size, path in outputs:
            inner = size - 2 * round(size * 100 / 1024)
            render = os.path.join(tmp, "render-%d.png" % size)
            subprocess.run([ICTOOL, icon, "--export-image", "--output-file", render, "--platform", "macOS",
                            "--rendition", "Default", "--width", str(inner), "--height", str(inner), "--scale", "1"],
                           check=True, capture_output=True)
            jobs += [render, str(size), path]
        script = os.path.join(tmp, "compose.swift")
        with open(script, "w") as f:
            f.write(COMPOSE)
        subprocess.run(["xcrun", "swift", script] + jobs, check=True)


def main():
    write_icon(os.path.join(ROOT, "TokenroomMobile", "AppIcon.icon"), {"squares": "shared"})
    write_icon(os.path.join(ROOT, "TokenroomWatch", "AppIcon.icon"), {"circles": ["watchOS"]}, WATCH_SCALE, WATCH_SHIFT)
    mac_icon = os.path.join(ROOT, "Tokenroom", "AppIcon.icon")
    write_icon(mac_icon, {"squares": "shared"})
    iconset = os.path.join(ROOT, "Tokenroom", "Assets.xcassets", "AppIcon.appiconset")
    outputs = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = "icon_%dx%d%s.png" % (points, points, "@2x" if scale == 2 else "")
            outputs.append((points * scale, os.path.join(iconset, name)))
    outputs.append((512, os.path.join(ROOT, "docs", "images", "icon.png")))
    mac_pngs(mac_icon, outputs)
    print("icons written")


if __name__ == "__main__":
    main()
