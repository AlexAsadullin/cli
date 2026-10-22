// Draws the app icon: the Lucide clock (Resources/icon-src/clock.svg) in white
// on an orange (#E96C47) squircle.
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
ctx.setFillColor(CGColor(srgbRed: 0.914, green: 0.424, blue: 0.278, alpha: 1))   // #E96C47
ctx.fillPath()
ctx.restoreGState()

let clockRect = CGRect(x: 512 - 290, y: 512 - 290, width: 580, height: 580)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
clock.draw(in: clockRect)
NSGraphicsContext.current = nil

let url = URL(fileURLWithPath: CommandLine.arguments[2])
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: url)
