import CoreGraphics

/// The phone display's rotation. Video frames arrive in the panel's own
/// orientation; the mirror shows them upright and reports touches in upright
/// pixels, the coordinate space LightpinkyCore's `touch` and `gesture` take.
public enum Orientation: String {
  case rot0, rot90, rot180, rot270

  public init(reported: String?) { self = reported.flatMap(Orientation.init(rawValue:)) ?? .rot0 }

  public var isSideways: Bool { self == .rot90 || self == .rot270 }

  /// Rotation applied to the panel image (y-down coordinates) to show it upright.
  public var angle: CGFloat {
    switch self {
    case .rot0: return 0
    case .rot90: return .pi / 2
    case .rot180: return .pi
    case .rot270: return -.pi / 2
    }
  }

  public func upright(_ panel: CGSize) -> CGSize {
    isSideways ? CGSize(width: panel.height, height: panel.width) : panel
  }
}
