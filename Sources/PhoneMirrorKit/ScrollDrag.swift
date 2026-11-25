import CoreGraphics

/// Turns Mac scrolling into one finger dragging on the phone, so the phone's
/// own scroll physics apply: a trackpad flick released mid-motion keeps
/// gliding, and sideways scrolling turns pages. The finger touches down only
/// after `threshold` pixels so a tiny scroll cannot tap what is under the pointer.
public struct ScrollDrag {
  public enum Touch: Equatable {
    case down(CGPoint), move(CGPoint), up(CGPoint)
  }

  public let screen: CGSize
  public var threshold: CGFloat = 10
  public var margin: CGFloat = 4
  private var origin: CGPoint = .zero
  private var offset: CGPoint = .zero
  private var last: CGPoint?
  public private(set) var isTracking = false

  public init(screen: CGSize) { self.screen = screen }

  public mutating func begin(at point: CGPoint) -> [Touch] {
    let touches = end()
    origin = clamp(point)
    offset = .zero
    isTracking = true
    return touches
  }

  /// Adds a scroll delta in phone pixels; positive y drags the finger down.
  public mutating func scroll(dx: CGFloat, dy: CGFloat) -> [Touch] {
    guard isTracking else { return [] }
    offset.x += dx
    offset.y += dy
    let target = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
    guard let current = last else {
      guard hypot(offset.x, offset.y) >= threshold else { return [] }
      let point = clamp(target)
      last = point
      return [.down(origin), .move(point)]
    }
    let point = clamp(target)
    if point != target {
      // The finger reached the edge: lift it and start again from the origin.
      last = nil
      offset = .zero
      return point == current ? [.up(current)] : [.move(point), .up(point)]
    }
    last = point
    return [.move(point)]
  }

  public mutating func end() -> [Touch] {
    isTracking = false
    offset = .zero
    guard let current = last else { return [] }
    last = nil
    return [.up(current)]
  }

  private func clamp(_ p: CGPoint) -> CGPoint {
    CGPoint(x: min(max(p.x, margin), max(margin, screen.width - 1 - margin)).rounded(),
            y: min(max(p.y, margin), max(margin, screen.height - 1 - margin)).rounded())
  }
}
