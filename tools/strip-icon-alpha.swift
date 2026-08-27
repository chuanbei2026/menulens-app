// Flatten an app icon's alpha channel so App Store Connect accepts it.
//
// Error 90717: "The large app icon ... can't be transparent or contain an
// alpha channel." Icons exported by a designer usually carry their OWN
// rounded corners with transparency outside them — which is also a double
// rounding, since iOS masks the icon with its own superellipse on top.
//
// Filling the square fixes both at once. The fill is NOT a flat colour:
// these backgrounds are gradients, and a flat fill leaves a visible seam at
// the corners. Instead every transparent pixel takes the colour of the
// nearest opaque pixel walking toward the centre, which extends the border
// outward — and iOS clips almost all of it away anyway.
//
//   swiftc -O tools/strip-icon-alpha.swift -o /tmp/strip-icon-alpha
//   /tmp/strip-icon-alpha <in.png> <out.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: strip-icon-alpha <in.png> <out.png>\n", stderr); exit(2) }

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fputs("cannot read \(args[1])\n", stderr); exit(1)
}
let w = image.width, h = image.height
// Premultiplied, so compositing over the fill is just src + fill*(1-a).
var px = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("cannot build bitmap\n", stderr); exit(1)
}
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

@inline(__always) func idx(_ x: Int, _ y: Int) -> Int { (y * w + x) * 4 }

/// Colour of the first fully-opaque pixel on the way to the centre.
func nearestOpaque(_ x0: Int, _ y0: Int) -> (UInt8, UInt8, UInt8) {
    let cx = Double(w) / 2, cy = Double(h) / 2
    let dx = cx - Double(x0), dy = cy - Double(y0)
    let steps = Int(max(abs(dx), abs(dy)))
    if steps > 0 {
        for s in 1...steps {
            let t = Double(s) / Double(steps)
            let x = Int(Double(x0) + dx * t), y = Int(Double(y0) + dy * t)
            let i = idx(min(max(x, 0), w - 1), min(max(y, 0), h - 1))
            if px[i + 3] == 255 { return (px[i], px[i + 1], px[i + 2]) }
        }
    }
    let c = idx(w / 2, h / 2)
    return (px[c], px[c + 1], px[c + 2])
}

var touched = 0
var out = [UInt8](repeating: 255, count: w * h * 4)   // opaque canvas
for y in 0 ..< h {
    for x in 0 ..< w {
        let i = idx(x, y)
        let a = px[i + 3]
        if a == 255 {
            out[i] = px[i]; out[i + 1] = px[i + 1]; out[i + 2] = px[i + 2]
        } else {
            let (fr, fg, fb) = nearestOpaque(x, y)
            let inv = Double(255 - Int(a)) / 255.0
            out[i]     = UInt8(min(255.0, Double(px[i])     + Double(fr) * inv))
            out[i + 1] = UInt8(min(255.0, Double(px[i + 1]) + Double(fg) * inv))
            out[i + 2] = UInt8(min(255.0, Double(px[i + 2]) + Double(fb) * inv))
            touched += 1
        }
        out[i + 3] = 255
    }
}

// noneSkipLast: the 4th byte is ignored, so the PNG carries no alpha channel.
guard let outCtx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let flat = outCtx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)
else { fputs("cannot write \(args[2])\n", stderr); exit(1) }
CGImageDestinationAddImage(dest, flat, nil)
guard CGImageDestinationFinalize(dest) else { fputs("finalize failed\n", stderr); exit(1) }
print("  \(w)×\(h), filled \(touched) non-opaque pixels (\(String(format: "%.1f", Double(touched) * 100 / Double(w * h)))%)")
