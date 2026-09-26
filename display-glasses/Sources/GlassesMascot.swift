import UIKit

/// The app's mascot for the glasses lens: a mint speech-bubble head wearing the app's
/// `eyeglasses` symbol. Transparent background, since black is see-through on the display.
enum GlassesMascot {
  static let ink = UIColor(red:0.05, green:0.14, blue:0.15, alpha:1)
  static let mint = UIColor(red:0.78, green:0.94, blue:0.83, alpha:1)

  /// Drawn once and reused; the lens only needs a small icon.
  static let image: UIImage = render(side:128)

  static func render(side: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
    return UIGraphicsImageRenderer(size:CGSize(width:side, height:side), format:format).image { _ in
      let s = side / 1024 // artwork is designed on a 1024 grid, y down
      func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x:x * s, y:y * s) }
      mint.setFill()
      UIBezierPath(roundedRect:CGRect(x:120 * s, y:110 * s, width:784 * s, height:690 * s), cornerRadius:345 * s).fill()
      let tail = UIBezierPath()
      tail.move(to:p(270, 690))
      tail.addCurve(to:p(130, 960), controlPoint1:p(260, 800), controlPoint2:p(220, 900))
      tail.addCurve(to:p(440, 780), controlPoint1:p(260, 940), controlPoint2:p(380, 870))
      tail.close(); tail.fill()
      let config = UIImage.SymbolConfiguration(pointSize:420 * s, weight:.bold)
      if let glasses = UIImage(systemName:"eyeglasses", withConfiguration:config)?.withTintColor(ink, renderingMode:.alwaysOriginal) {
        let w = 640 * s, h = w * glasses.size.height / glasses.size.width
        glasses.draw(in:CGRect(x:(side - w) / 2, y:380 * s - h / 2, width:w, height:h))
      }
      let smile = UIBezierPath()
      smile.move(to:p(412, 575))
      smile.addCurve(to:p(612, 575), controlPoint1:p(460, 645), controlPoint2:p(564, 645))
      smile.lineWidth = 40 * s; smile.lineCapStyle = .round
      ink.setStroke(); smile.stroke()
    }
  }
}
