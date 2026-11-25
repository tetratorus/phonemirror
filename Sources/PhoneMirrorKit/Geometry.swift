import CoreGraphics

public enum Geometry {
  /// `content` scaled to fit and centered in `bounds`.
  public static func aspectFit(_ content: CGSize, in bounds: CGRect) -> CGRect {
    guard content.width > 0, content.height > 0 else { return bounds }
    let scale = min(bounds.width / content.width, bounds.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                  width: size.width, height: size.height)
  }

  /// A point in `displayed` (y-down) as a whole pixel of a `screen`-sized image, clamped inside it.
  public static func pixel(_ point: CGPoint, displayed: CGRect, screen: CGSize) -> CGPoint? {
    guard screen.width > 0, screen.height > 0, displayed.width > 0, displayed.height > 0 else { return nil }
    let nx = min(1, max(0, (point.x - displayed.minX) / displayed.width))
    let ny = min(1, max(0, (point.y - displayed.minY) / displayed.height))
    return CGPoint(x: (nx * (screen.width - 1)).rounded(), y: (ny * (screen.height - 1)).rounded())
  }

  /// iPhone point size for a pixel size: 3x panels from 1080 pixels wide, 2x below.
  public static func points(forPixels size: CGSize) -> CGSize {
    let scale: CGFloat = min(size.width, size.height) >= 1080 ? 3 : 2
    return CGSize(width: (size.width / scale).rounded(), height: (size.height / scale).rounded())
  }
}
