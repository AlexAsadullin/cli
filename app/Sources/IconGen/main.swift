// Draws the app icon: the Lucide clock (Resources/icon-src/clock.svg) in white
// on a terracotta squircle.
// Usage: icongen <clock.svg> <output.png>   (1024x1024)
import AppKit

let size = 1024
let clockColor = "#FFFFFF"

let svgText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .replacingOccurrences(of: "currentColor", with: clockColor)
guard let clock = NSImage(data: Data(svgText.utf8)) else { fatalError("cannot load SVG") }

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt body, centered, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.25))
ctx.addPath(squircle)
ctx.setFillColor(CGColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1))   // terracotta #D97757
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
    CGColor(srgbRed: 0.89, green: 0.52, blue: 0.39, alpha: 1),   // top
    CGColor(srgbRed: 0.78, green: 0.39, blue: 0.27, alpha: 1),   // bottom
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

let clockRect = CGRect(x: 512 - 290, y: 512 - 290, width: 580, height: 580)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
clock.draw(in: clockRect)
NSGraphicsContext.current = nil

let url = URL(fileURLWithPath: CommandLine.arguments[2])
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: url)
