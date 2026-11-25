import AppKit
import CoreGraphics
import Foundation
import LightpinkyCore
import QuartzCore

// MARK: - Direct LightpinkyCore session (zero JPEG, zero JSON)

final class DirectPhoneSession {
  private let queue = DispatchQueue(label: "phonemirror.phone", qos: .userInteractive)
  private let stateLock = NSLock()
  private var phone: Phone?
  private var pendingInputs = 0
  private var stopped = false

  var hasPendingInput: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return pendingInputs > 0
  }

  private func isStopped() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopped
  }

  private func ensurePhoneLocked() throws -> Phone {
    if let phone { return phone }
    let devices = try PhoneInfo.discover()
    let wanted = ProcessInfo.processInfo.environment["LIGHTPINKY_DEVICE"]
    let matches = wanted.map { id in
      devices.filter { $0.id == id || $0.udid == id || $0.name == id }
    } ?? devices
    guard matches.count == 1 else {
      throw PhoneError("Expected 1 paired iPhone, found \(matches.count)")
    }
    let connected = Phone(matches[0])
    phone = connected
    return connected
  }

  func nextFrame(wait: Double = 0.05) throws -> CGImage? {
    if isStopped() { return nil }
    return try queue.sync {
      if isStopped() { return nil }
      let p = try ensurePhoneLocked()
      return try p.videoFrame(wait: wait, maxAge: 2)
    }
  }

  func performInput(_ work: @escaping (Phone) throws -> Void, onError: ((String) -> Void)? = nil) {
    stateLock.lock()
    pendingInputs += 1
    stateLock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      defer {
        self.stateLock.lock()
        self.pendingInputs = max(0, self.pendingInputs - 1)
        self.stateLock.unlock()
      }
      if self.isStopped() { return }
      do {
        let p = try self.ensurePhoneLocked()
        try work(p)
      } catch {
        onError?(error.localizedDescription)
      }
    }
  }

  func resetConnection() {
    queue.async { [weak self] in
      self?.phone?.endDisplaySession()
      self?.phone = nil
    }
  }

  func shutdown() {
    stateLock.lock()
    stopped = true
    stateLock.unlock()
    queue.sync {
      phone?.endDisplaySession()
      phone = nil
    }
  }
}

// MARK: - Interactive Direct-Layer Mirror View

final class MirrorView: NSView {
  var onTouch: ((CGPoint, Bool) -> Void)?
  var onLongPress: ((CGPoint) -> Void)?
  var onSwipe: ((CGPoint, CGPoint, Double) -> Void)?
  var onKey: ((String) -> Void)?
  var onType: ((String) -> Void)?
  var onHome: (() -> Void)?
  var onLock: (() -> Void)?

  private let imageLayer = CALayer()
  private var screenSize: CGSize = .zero
  private var isDragging = false
  private var lastDragSentAt: TimeInterval = 0

  private var pendingText = ""
  private var textTimer: Timer?

  private var pendingScrollDelta: CGFloat = 0
  private var scrollOrigin: CGPoint = .zero
  private var scrollTimer: Timer?

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
    imageLayer.contentsGravity = .resizeAspect
    imageLayer.magnificationFilter = .linear
    imageLayer.minificationFilter = .trilinear
    layer?.addSublayer(imageLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = bounds
    CATransaction.commit()
  }

  func update(frame image: CGImage) {
    screenSize = CGSize(width: image.width, height: image.height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    CATransaction.commit()
  }

  private func displayedRect() -> CGRect {
    guard screenSize.width > 0, screenSize.height > 0 else { return bounds }
    let scale = min(bounds.width / screenSize.width, bounds.height / screenSize.height)
    let w = screenSize.width * scale
    let h = screenSize.height * scale
    return CGRect(
      x: (bounds.width - w) / 2,
      y: (bounds.height - h) / 2,
      width: w,
      height: h
    )
  }

  private func phonePoint(from viewPoint: CGPoint) -> CGPoint? {
    guard screenSize.width > 0, screenSize.height > 0 else { return nil }
    let rect = displayedRect()
    guard rect.width > 0, rect.height > 0 else { return nil }
    let nx = min(1, max(0, (viewPoint.x - rect.minX) / rect.width))
    let ny = min(1, max(0, (viewPoint.y - rect.minY) / rect.height))
    return CGPoint(
      x: (nx * (screenSize.width - 1)).rounded(),
      y: (ny * (screenSize.height - 1)).rounded()
    )
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let pt = convert(event.locationInWindow, from: nil)
    guard let p = phonePoint(from: pt) else { return }
    isDragging = true
    lastDragSentAt = event.timestamp
    onTouch?(p, true)
  }

  override func mouseDragged(with event: NSEvent) {
    guard isDragging else { return }
    // Throttle live touch move reports to ~60Hz
    guard event.timestamp - lastDragSentAt >= 0.016 else { return }
    let pt = convert(event.locationInWindow, from: nil)
    guard let p = phonePoint(from: pt) else { return }
    lastDragSentAt = event.timestamp
    onTouch?(p, true)
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    isDragging = false
    let pt = convert(event.locationInWindow, from: nil)
    guard let p = phonePoint(from: pt) else { return }
    onTouch?(p, false)
  }

  override func rightMouseUp(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    if let p = phonePoint(from: pt) {
      onLongPress?(p)
    }
  }

  override func scrollWheel(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    guard let origin = phonePoint(from: pt) else { return }
    let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
    pendingScrollDelta += dy
    scrollOrigin = origin
    scrollTimer?.invalidate()
    scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
      self?.flushScroll()
    }
  }

  private func flushScroll() {
    let delta = pendingScrollDelta
    pendingScrollDelta = 0
    guard abs(delta) > 6, screenSize.height > 0 else { return }
    let travel = min(screenSize.height * 0.45, max(80, abs(delta) * 2.5))
    let sign: CGFloat = delta > 0 ? 1 : -1
    let y1 = min(screenSize.height - 40, max(40, scrollOrigin.y))
    let y2 = min(screenSize.height - 40, max(40, y1 + sign * travel))
    guard abs(y2 - y1) > 20 else { return }
    onSwipe?(CGPoint(x: scrollOrigin.x, y: y1), CGPoint(x: scrollOrigin.x, y: y2), 0.22)
  }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "v":
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
          flushText()
          onType?(str)
        }
        return
      case "h":
        flushText()
        onHome?()
        return
      case "l":
        flushText()
        onLock?()
        return
      case "q":
        NSApp.terminate(nil)
        return
      default:
        break
      }
    }

    switch event.keyCode {
    case 36, 76: flushText(); onKey?("enter"); return
    case 51: flushText(); onKey?("delete"); return
    case 117: flushText(); onKey?("forward_delete"); return
    case 48: flushText(); onKey?("tab"); return
    case 53: flushText(); onKey?("escape"); return
    case 126: flushText(); onKey?("dpad_up"); return
    case 125: flushText(); onKey?("dpad_down"); return
    case 123: flushText(); onKey?("dpad_left"); return
    case 124: flushText(); onKey?("dpad_right"); return
    default: break
    }

    if !flags.contains(.command), !flags.contains(.control),
       let chars = event.characters, !chars.isEmpty {
      pendingText.append(chars)
      textTimer?.invalidate()
      textTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: false) { [weak self] _ in
        self?.flushText()
      }
    }
  }

  private func flushText() {
    textTimer?.invalidate()
    textTimer = nil
    guard !pendingText.isEmpty else { return }
    let text = pendingText
    pendingText = ""
    onType?(text)
  }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let session = DirectPhoneSession()
  private var window: NSWindow!
  private var mirrorView: MirrorView!
  private var statusLabel: NSTextField!
  private var streamRunning = false
  private var hasSizedWindow = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupUI()
    startStreaming()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    streamRunning = false
    session.shutdown()
  }

  private func setupUI() {
    let initialRect = NSRect(x: 200, y: 120, width: 410, height: 860)
    window = NSWindow(
      contentRect: initialRect,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "PhoneMirror (Direct HEVC)"
    window.delegate = self
    window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)

    let root = NSView(frame: initialRect)
    root.autoresizingMask = [.width, .height]

    let barHeight: CGFloat = 34
    let bar = NSView(frame: NSRect(x: 0, y: 0, width: initialRect.width, height: barHeight))
    bar.autoresizingMask = [.width, .maxYMargin]
    bar.wantsLayer = true
    bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor

    let homeBtn = NSButton(title: "Home", target: self, action: #selector(pressHome))
    homeBtn.bezelStyle = .rounded
    homeBtn.frame = NSRect(x: 8, y: 4, width: 62, height: 26)
    bar.addSubview(homeBtn)

    let lockBtn = NSButton(title: "Lock", target: self, action: #selector(pressLock))
    lockBtn.bezelStyle = .rounded
    lockBtn.frame = NSRect(x: 74, y: 4, width: 56, height: 26)
    bar.addSubview(lockBtn)

    statusLabel = NSTextField(labelWithString: "Connecting to iPhone...")
    statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.frame = NSRect(x: 138, y: 9, width: initialRect.width - 146, height: 16)
    statusLabel.autoresizingMask = [.width]
    bar.addSubview(statusLabel)

    mirrorView = MirrorView(frame: NSRect(x: 0, y: barHeight, width: initialRect.width, height: initialRect.height - barHeight))
    mirrorView.autoresizingMask = [.width, .height]
    mirrorView.onTouch = { [weak self] pt, down in
      self?.session.performInput({ try $0.touch(x: pt.x, y: pt.y, down: down) }) { err in
        self?.setStatus("Touch error: \(err)")
      }
    }
    mirrorView.onLongPress = { [weak self] pt in
      self?.session.performInput({ try $0.gesture(x1: pt.x, y1: pt.y, x2: pt.x, y2: pt.y, duration: 0.8) }) { err in
        self?.setStatus("Long-press error: \(err)")
      }
    }
    mirrorView.onSwipe = { [weak self] p1, p2, dur in
      self?.session.performInput({ try $0.gesture(x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y, duration: dur) }) { err in
        self?.setStatus("Swipe error: \(err)")
      }
    }
    mirrorView.onKey = { [weak self] key in
      self?.session.performInput({ try $0.key(key) }) { err in
        self?.setStatus("Key error: \(err)")
      }
    }
    mirrorView.onType = { [weak self] text in
      self?.session.performInput({ try $0.type(text, append: true, submit: false) }) { err in
        self?.setStatus("Type error: \(err)")
      }
    }
    mirrorView.onHome = { [weak self] in self?.pressHome() }
    mirrorView.onLock = { [weak self] in self?.pressLock() }

    root.addSubview(bar)
    root.addSubview(mirrorView)
    window.contentView = root
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(mirrorView)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func pressHome() {
    session.performInput({ try $0.key("home") }) { [weak self] err in
      self?.setStatus("Home error: \(err)")
    }
  }

  @objc private func pressLock() {
    session.performInput({ try $0.lock() }) { [weak self] err in
      self?.setStatus("Lock error: \(err)")
    }
  }

  private func setStatus(_ text: String) {
    DispatchQueue.main.async { [weak self] in
      self?.statusLabel.stringValue = text
    }
  }

  private func startStreaming() {
    streamRunning = true
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      var frameCount = 0
      var fpsWindowStart = ProcessInfo.processInfo.systemUptime
      var currentFPS = 0.0

      while self.streamRunning {
        if self.session.hasPendingInput {
          Thread.sleep(forTimeInterval: 0.005)
          continue
        }
        autoreleasepool {
          do {
            if let image = try self.session.nextFrame(wait: 0.05) {
              frameCount += 1
              let now = ProcessInfo.processInfo.systemUptime
              if now - fpsWindowStart >= 1.0 {
                currentFPS = Double(frameCount) / (now - fpsWindowStart)
                frameCount = 0
                fpsWindowStart = now
              }
              DispatchQueue.main.async {
                if !self.hasSizedWindow, image.width > 0, image.height > 0 {
                  self.hasSizedWindow = true
                  let targetWidth: CGFloat = 390
                  let aspect = CGFloat(image.height) / CGFloat(image.width)
                  let targetHeight = (targetWidth * aspect).rounded() + 34
                  self.window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
                }
                self.mirrorView.update(frame: image)
                self.statusLabel.stringValue = String(
                  format: "Live · %.0f fps · %dx%d",
                  currentFPS, image.width, image.height
                )
              }
            }
            Thread.sleep(forTimeInterval: 0.014)
          } catch {
            self.setStatus("Waiting: \(error.localizedDescription)")
            self.session.resetConnection()
            Thread.sleep(forTimeInterval: 0.5)
          }
        }
      }
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
