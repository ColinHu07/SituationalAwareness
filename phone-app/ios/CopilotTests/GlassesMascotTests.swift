import XCTest
import UIKit
@testable import Copilot

final class GlassesMascotTests: XCTestCase {
  private func alpha(_ image: UIImage, _ x: Int, _ y: Int) -> UInt8 {
    let cg = image.cgImage!
    var pixel = [UInt8](repeating:0, count:4)
    let ctx = CGContext(data:&pixel, width:1, height:1, bitsPerComponent:8, bytesPerRow:4, space:CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in:CGRect(x:-x, y:-(cg.height - 1 - y), width:cg.width, height:cg.height))
    return pixel[3]
  }

  func testMascotIsTransparentAroundTheHeadSoItFloatsOnTheLens() throws {
    let image = GlassesMascot.render(side:256)
    XCTAssertEqual(image.size, CGSize(width:256, height:256))
    XCTAssertEqual(alpha(image, 2, 2), 0, "Corners are see-through")
    XCTAssertEqual(alpha(image, 250, 250), 0)
    XCTAssertEqual(alpha(image, 128, 70), 255, "The head itself is solid")
    if let path = ProcessInfo.processInfo.environment["MASCOT_PREVIEW"] {
      try GlassesMascot.render(side:512).pngData()!.write(to:URL(fileURLWithPath:path))
    }
  }

  func testMascotSaysTheCueOrOtherwiseTheStatus() {
    let cue = GlassesScreen(cue:"Ask what they meant by Friday.", caption:nil, note:nil, paused:false,
                            captionsEnabled:false, ready:false, starting:false, testOnly:false)
    XCTAssertEqual(cue.message, "Ask what they meant by Friday.")
    let idle = GlassesScreen(cue:nil, caption:nil, note:nil, paused:false, captionsEnabled:false, ready:false, starting:false, testOnly:false, sceneOnly:true)
    XCTAssertEqual(idle.message, "Watching the scene automatically.")
    let paused = GlassesScreen(cue:nil, caption:nil, note:nil, paused:true, captionsEnabled:false, ready:false, starting:false, testOnly:false, status:"Camera stopped.")
    XCTAssertEqual(paused.message, "Camera stopped.")
  }

  func testSeeingSummaryIsSeparateFromCaptionsAndClearsWhenPaused() {
    let summary = "A person is seated beside a table."
    let screen = GlassesScreen(cue:"Give them some space.",caption:"P1: Private transcript",note:nil,paused:false,
      captionsEnabled:true,ready:false,starting:false,testOnly:false,sceneSummary:summary)
    XCTAssertEqual(screen.seeing,summary)
    XCTAssertEqual(screen.message,"Give them some space.")
    XCTAssertNil(screen.detail,"Captions still never appear on the glasses")
    let paused = GlassesScreen(cue:screen.cue,caption:nil,note:nil,paused:true,
      captionsEnabled:false,ready:false,starting:false,testOnly:false,sceneSummary:summary)
    XCTAssertNil(paused.seeing)
  }
}
