import AppKit

let size: CGFloat = 1024
let ink = NSColor(red:0.05, green:0.14, blue:0.15, alpha:1)
let mint = NSColor(red:0.78, green:0.94, blue:0.83, alpha:1)
let paper = NSColor(red:0.95, green:0.97, blue:0.95, alpha:1)

// Opaque RGB canvas: App Store icons must not have transparency.
let ctx = CGContext(data:nil, width:Int(size), height:Int(size), bitsPerComponent:8, bytesPerRow:0,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!, bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx, flipped:false)

// Background: the app's dark teal ink with a soft vertical glow.
let bg = NSGradient(starting:NSColor(red:0.09, green:0.24, blue:0.25, alpha:1), ending:ink)!
bg.draw(in:NSRect(x:0, y:0, width:size, height:size), angle:-90)

// Speech-bubble head: a big rounded bubble with a tail at the lower left.
let head = NSBezierPath(roundedRect:NSRect(x:170, y:250, width:684, height:600), xRadius:300, yRadius:300)
let tail = NSBezierPath()
tail.move(to:NSPoint(x:300, y:330))
tail.curve(to:NSPoint(x:190, y:150), controlPoint1:NSPoint(x:290, y:250), controlPoint2:NSPoint(x:250, y:185))
tail.curve(to:NSPoint(x:440, y:275), controlPoint1:NSPoint(x:300, y:175), controlPoint2:NSPoint(x:390, y:215))
tail.close()
// Soft drop shadow so the head lifts off the background.
// Head and tail share one shadow so the join has no seam.
ctx.saveGState()
ctx.setShadow(offset:CGSize(width:0, height:-18), blur:40, color:NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo:nil)
mint.setFill(); head.fill(); tail.fill()
ctx.endTransparencyLayer()
ctx.restoreGState()
// Gentle highlight on the top of the head.
paper.withAlphaComponent(0.55).setFill()
NSBezierPath(ovalIn:NSRect(x:330, y:730, width:260, height:70)).fill()

// The same SF Symbol the app uses for glasses.
let config = NSImage.SymbolConfiguration(pointSize:360, weight:.semibold)
if let glasses = NSImage(systemSymbolName:"eyeglasses", accessibilityDescription:nil)?.withSymbolConfiguration(config) {
  let tinted = NSImage(size:glasses.size, flipped:false) { rect in
    glasses.draw(in:rect); ink.set(); rect.fill(using:.sourceAtop); return true
  }
  let w: CGFloat = 560, h = w * tinted.size.height / tinted.size.width
  tinted.draw(in:NSRect(x:(size - w) / 2, y:520 - h / 2, width:w, height:h))
}

// A small friendly smile.
let smile = NSBezierPath()
smile.move(to:NSPoint(x:432, y:400))
smile.curve(to:NSPoint(x:592, y:400), controlPoint1:NSPoint(x:470, y:345), controlPoint2:NSPoint(x:554, y:345))
smile.lineWidth = 30; smile.lineCapStyle = .round
ink.setStroke(); smile.stroke()

NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage:ctx.makeImage()!)
try! rep.representation(using:.png, properties:[:])!.write(to:URL(fileURLWithPath:"AppIcon.png"))
print("wrote AppIcon.png")
