import AppKit
import PhoneMirrorKit
import QuartzCore

/// Shows the phone's screen upright and turns mouse, trackpad, keyboard and
/// drops into phone input. Every callback point is in upright screen pixels.
final class MirrorView: NSView {
  var onTouch: ((CGPoint, Bool) -> Void)?
  var onLongPress: ((CGPoint) -> Void)?
  var onChord: (([UInt8]) -> Void)?
  var onText: ((String) -> Void)?
  var onPaste: (() -> Void)?
  var onCopy: (([UInt8]) -> Void)?
  var onDropText: ((CGPoint, String) -> Void)?
  var onDropURL: ((String) -> Void)?
  var onClickWhilePaused: (() -> Void)?
  private let pauseLock = NSLock()
  private var isPaused = false
  /// Read by the stream thread; while set, no frames are read so the phone can sleep.
  var paused: Bool {
    get { pauseLock.lock(); defer { pauseLock.unlock() }; return isPaused }
    set { pauseLock.lock(); isPaused = newValue; pauseLock.unlock() }
  }

  private let imageLayer = CALayer()
  private(set) var panelSize: CGSize = .zero
  private(set) var orientation: Orientation = .rot0
  var screenSize: CGSize { orientation.upright(panelSize) }

  private var isDragging = false
  private var lastDragSentAt: TimeInterval = 0
  private var scroll: ScrollDrag?
  private var wheelTimer: Timer?

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    imageLayer.contentsGravity = .resize
    imageLayer.magnificationFilter = .linear
    imageLayer.minificationFilter = .trilinear
    imageLayer.masksToBounds = true
    imageLayer.cornerCurve = .continuous
    layer?.addSublayer(imageLayer)
    registerForDraggedTypes([.URL, .string])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  override func layout() {
    super.layout()
    layoutImage()
  }

  /// Shows a panel-oriented frame; returns true when the upright size changed.
  @discardableResult
  func update(frame image: CGImage, orientation: Orientation) -> Bool {
    let before = screenSize
    panelSize = CGSize(width: image.width, height: image.height)
    self.orientation = orientation
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    CATransaction.commit()
    if screenSize != before {
      scroll = nil
      layoutImage()
      return true
    }
    return false
  }

  private func layoutImage() {
    let shown = displayedRect()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.setAffineTransform(.identity)
    imageLayer.bounds = CGRect(origin: .zero, size: orientation.isSideways
      ? CGSize(width: shown.height, height: shown.width) : shown.size)
    imageLayer.position = CGPoint(x: shown.midX, y: shown.midY)
    imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: orientation.angle * rotationSign))
    imageLayer.cornerRadius = min(shown.width, shown.height) * 0.13
    CATransaction.commit()
  }

  /// Layer rotation runs the other way when AppKit gives the view a y-up layer.
  private var rotationSign: CGFloat { layer?.isGeometryFlipped == true ? 1 : -1 }

  private func displayedRect() -> CGRect { Geometry.aspectFit(screenSize, in: bounds) }

  /// Input that starts a touch must land on the screen; a finger already down follows to the edge.
  private func phonePoint(_ event: NSEvent, clamped: Bool = false) -> CGPoint? {
    phonePoint(convert(event.locationInWindow, from: nil), clamped: clamped)
  }

  private func phonePoint(_ viewPoint: CGPoint, clamped: Bool = false) -> CGPoint? {
    Geometry.pixel(viewPoint, displayed: displayedRect(), screen: screenSize, clamped: clamped)
  }

  // MARK: Pointer

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if paused { onClickWhilePaused?(); return }
    guard let p = phonePoint(event) else { return }
    isDragging = true
    lastDragSentAt = event.timestamp
    onTouch?(p, true)
  }

  override func mouseDragged(with event: NSEvent) {
    guard isDragging, event.timestamp - lastDragSentAt >= 0.016, let p = phonePoint(event, clamped: true) else { return }
    lastDragSentAt = event.timestamp
    onTouch?(p, true)
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    isDragging = false
    guard let p = phonePoint(event, clamped: true) else { return }
    onTouch?(p, false)
  }

  override func rightMouseUp(with event: NSEvent) {
    if let p = phonePoint(event) { onLongPress?(p) }
  }

  override func scrollWheel(with event: NSEvent) {
    // The phone adds its own momentum when the finger lifts mid-motion.
    guard event.momentumPhase.isEmpty, !paused else { return }
    // Only a scroll that starts over the screen touches down; one under way may leave it.
    let point = phonePoint(event)
    if scroll?.screen != screenSize { scroll = ScrollDrag(screen: screenSize) }
    let shown = displayedRect()
    guard shown.width > 0 else { return }
    let perPoint = screenSize.width / shown.width
    let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
    let dx = event.scrollingDeltaX * lines * perPoint
    let dy = event.scrollingDeltaY * lines * perPoint

    if event.phase.contains(.began) {
      if let point { send(scroll!.begin(at: point)) } else { send(scroll!.end()) }
    } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      send(scroll!.end())
      return
    } else if event.phase.isEmpty {
      // A mouse wheel has no phases: a pause ends the drag.
      if !scroll!.isTracking, let point { send(scroll!.begin(at: point)) }
      wheelTimer?.invalidate()
      wheelTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
        guard let self, self.scroll != nil else { return }
        self.send(self.scroll!.end())
      }
    }
    if dx != 0 || dy != 0 { send(scroll!.scroll(dx: dx, dy: dy)) }
  }

  private func send(_ touches: [ScrollDrag.Touch]) {
    for touch in touches {
      switch touch {
      case .down(let p), .move(let p): onTouch?(p, true)
      case .up(let p): onTouch?(p, false)
      }
    }
  }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    if paused { return }
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control, .capsLock])
    let nonCaps = flags.subtracting(.capsLock)
    if nonCaps == .command {
      switch event.keyCode {
      case 0x09: onPaste?(); return
      case 0x08, 0x07:
        if let chord = KeyMap.chord(keyCode: event.keyCode, flags: CGEventFlags(rawValue: UInt64(nonCaps.rawValue))) {
          onCopy?(chord)
        }
        return
      default: break
      }
    }
    if let chord = KeyMap.chord(keyCode: event.keyCode, flags: CGEventFlags(rawValue: UInt64(flags.rawValue))) {
      onChord?(chord)
    } else if let text = event.characters, !text.isEmpty, !flags.contains(.command), !flags.contains(.control) {
      onText?(text)
    }
  }

  // MARK: Drag and drop

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { paused ? [] : .copy }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let board = sender.draggingPasteboard
    if let url = (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
       ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      onDropURL?(url.absoluteString)
      return true
    }
    guard let text = board.string(forType: .string), !text.isEmpty,
          let p = phonePoint(convert(sender.draggingLocation, from: nil)) else { return false }
    onDropText?(p, text)
    return true
  }
}
