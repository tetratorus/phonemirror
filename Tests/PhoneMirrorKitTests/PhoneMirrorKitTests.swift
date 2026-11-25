import CoreGraphics
import XCTest
@testable import PhoneMirrorKit

final class KeyMapTests: XCTestCase {
  func testLettersDigitsAndModifiers() {
    XCTAssertEqual(KeyMap.chord(keyCode: 0x00, flags: []), [0x04])                 // a
    XCTAssertEqual(KeyMap.chord(keyCode: 0x1d, flags: []), [0x27])                 // 0
    XCTAssertEqual(KeyMap.chord(keyCode: 0x08, flags: .maskCommand), [0xe3, 0x06]) // ⌘C
    XCTAssertEqual(KeyMap.chord(keyCode: 0x7b, flags: [.maskShift, .maskAlternate]), [0xe1, 0xe2, 0x50])
    XCTAssertEqual(KeyMap.chord(keyCode: 0x24, flags: []), [0x28])                 // Return
    XCTAssertNil(KeyMap.chord(keyCode: 0x3f, flags: []))                           // fn
  }

  func testEveryUsageIsDistinctAndBelowModifiers() {
    let values = Array(KeyMap.usages.values)
    XCTAssertEqual(Set(values).count, values.count)
    XCTAssertTrue(values.allSatisfy { $0 > 3 && $0 < 0xe0 })
  }
}

final class OrientationTests: XCTestCase {
  /// LightpinkyCore's mapping from an upright point (fractions) to the panel.
  private func panel(_ p: CGPoint, _ o: Orientation) -> CGPoint {
    switch o {
    case .rot0: return p
    case .rot90: return CGPoint(x: p.y, y: 1 - p.x)
    case .rot180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
    case .rot270: return CGPoint(x: 1 - p.y, y: p.x)
    }
  }

  /// Rotating the panel image by `angle` (y-down) must put each panel point
  /// where LightpinkyCore expects its upright counterpart.
  func testDisplayedRotationMatchesTouchMapping() {
    for o in [Orientation.rot0, .rot90, .rot180, .rot270] {
      for upright in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.5, y: 0.9)] {
        let p = panel(upright, o)
        let centered = CGPoint(x: p.x - 0.5, y: p.y - 0.5)
        let r = centered.applying(CGAffineTransform(rotationAngle: o.angle))
        XCTAssertEqual(r.x + 0.5, upright.x, accuracy: 1e-9, "\(o)")
        XCTAssertEqual(r.y + 0.5, upright.y, accuracy: 1e-9, "\(o)")
      }
    }
  }

  func testUprightSizeAndParsing() {
    XCTAssertEqual(Orientation.rot90.upright(CGSize(width: 1206, height: 2622)), CGSize(width: 2622, height: 1206))
    XCTAssertEqual(Orientation(reported: "rot270"), .rot270)
    XCTAssertEqual(Orientation(reported: nil), .rot0)
    XCTAssertEqual(Orientation(reported: "unknown"), .rot0)
  }
}

final class GeometryTests: XCTestCase {
  func testAspectFitAndPixelMapping() {
    let shown = Geometry.aspectFit(CGSize(width: 1000, height: 2000), in: CGRect(x: 0, y: 0, width: 400, height: 400))
    XCTAssertEqual(shown, CGRect(x: 100, y: 0, width: 200, height: 400))
    let screen = CGSize(width: 1000, height: 2000)
    XCTAssertEqual(Geometry.pixel(CGPoint(x: 100, y: 0), displayed: shown, screen: screen), CGPoint(x: 0, y: 0))
    XCTAssertEqual(Geometry.pixel(CGPoint(x: 400, y: 500), displayed: shown, screen: screen), CGPoint(x: 999, y: 1999))
    XCTAssertNil(Geometry.pixel(CGPoint(x: 50, y: 100), displayed: shown, screen: screen, clamped: false))
    XCTAssertEqual(Geometry.pixel(CGPoint(x: 150, y: 100), displayed: shown, screen: screen, clamped: false), CGPoint(x: 250, y: 500))
  }

  func testPointSizes() {
    XCTAssertEqual(Geometry.points(forPixels: CGSize(width: 1206, height: 2622)), CGSize(width: 402, height: 874))
    XCTAssertEqual(Geometry.points(forPixels: CGSize(width: 828, height: 1792)), CGSize(width: 414, height: 896))
  }
}

final class ScrollDragTests: XCTestCase {
  func testSmallScrollNeverTouches() {
    var drag = ScrollDrag(screen: CGSize(width: 1000, height: 2000))
    XCTAssertEqual(drag.begin(at: CGPoint(x: 500, y: 1000)), [])
    XCTAssertEqual(drag.scroll(dx: 0, dy: 6), [])
    XCTAssertEqual(drag.end(), [])
  }

  func testDragFollowsDeltasThenLifts() {
    var drag = ScrollDrag(screen: CGSize(width: 1000, height: 2000))
    _ = drag.begin(at: CGPoint(x: 500, y: 1000))
    XCTAssertEqual(drag.scroll(dx: 0, dy: -30), [.down(CGPoint(x: 500, y: 1000)), .move(CGPoint(x: 500, y: 970))])
    XCTAssertEqual(drag.scroll(dx: 20, dy: -30), [.move(CGPoint(x: 520, y: 940))])
    XCTAssertEqual(drag.end(), [.up(CGPoint(x: 520, y: 940))])
  }

  func testEdgeLiftsAndRestartsFromOrigin() {
    var drag = ScrollDrag(screen: CGSize(width: 1000, height: 2000))
    _ = drag.begin(at: CGPoint(x: 500, y: 100))
    _ = drag.scroll(dx: 0, dy: -50)
    XCTAssertEqual(drag.scroll(dx: 0, dy: -100), [.move(CGPoint(x: 500, y: 4)), .up(CGPoint(x: 500, y: 4))])
    XCTAssertEqual(drag.scroll(dx: 0, dy: -20), [.down(CGPoint(x: 500, y: 100)), .move(CGPoint(x: 500, y: 80))])
  }
}
