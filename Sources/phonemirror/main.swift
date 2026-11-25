import AppKit
import Foundation
import PhoneMirrorKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let session: PhoneSession
  private var window: NSWindow!
  private var mirrorView: MirrorView!
  private var statusLabel: NSTextField!
  private var streamRunning = false
  private var locked = false
  private var statusHoldUntil = 0.0
  private var zoom: CGFloat = max(0.4, min(2.5, CGFloat(UserDefaults.standard.double(forKey: "zoom")).nonZero ?? 1))

  override init() {
    let env = ProcessInfo.processInfo.environment
    if let still = env["PHONEMIRROR_STILL"] {
      let orientation = env["PHONEMIRROR_STILL_ORIENTATION"] ?? "rot0"
      session = PhoneSession { try StillLink(path: still, orientation: orientation) }
    } else {
      session = PhoneSession { try LightpinkyLink() }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMenu()
    setupWindow()
    startStreaming()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    streamRunning = false
    session.shutdown()
  }

  // MARK: Menus

  private func makeMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
      let holder = NSMenuItem()
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      holder.submenu = menu
      main.addItem(holder)
    }
    func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
              target: AnyObject? = nil) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = mods
      item.target = target ?? self
      return item
    }
    submenu("PhoneMirror", [
      item("Hide PhoneMirror", #selector(NSApplication.hide(_:)), "h", target: NSApp),
      .separator(),
      item("Quit PhoneMirror", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
    ])
    // No Edit menu: Command shortcuts other than these go to the phone.
    submenu("View", [
      item("Home Screen", #selector(pressHome), "1"),
      item("App Switcher", #selector(appSwitcher), "2"),
      item("Spotlight", #selector(spotlight), "3"),
      .separator(),
      item("Larger", #selector(larger), "="),
      item("Actual Size", #selector(actualSize), "0"),
      item("Smaller", #selector(smaller), "-"),
    ])
    submenu("iPhone", [
      item("Unlock", #selector(unlock), "u"),
      item("Lock", #selector(pressLock), "l"),
      item("Reconnect", #selector(reconnect), "r", [.command, .shift]),
    ])
    submenu("Window", [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: NSNull()),
      item("Close", #selector(NSWindow.performClose(_:)), "w", target: NSNull()),
    ])
    for menu in main.items.compactMap(\.submenu) {
      for entry in menu.items where entry.target is NSNull { entry.target = nil }
    }
    return main
  }

  // MARK: Window

  private func setupWindow() {
    let rect = NSRect(x: 200, y: 120, width: 402, height: 874)
    window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
    window.title = "iPhone"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .black
    window.appearance = NSAppearance(named: .darkAqua)
    window.delegate = self
    window.contentAspectRatio = rect.size
    window.setFrameAutosaveName("PhoneMirror")
    // Like iPhone Mirroring, the window keeps the phone's size and shape; no full screen.
    window.collectionBehavior.insert(.fullScreenNone)

    statusLabel = NSTextField(labelWithString: "Connecting…")
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
      let button = NSButton(image: image, target: self, action: action)
      button.isBordered = false
      button.toolTip = tip
      button.contentTintColor = .secondaryLabelColor
      return button
    }
    let bar = NSStackView(views: [
      statusLabel,
      button("house", "Home Screen (⌘1)", #selector(pressHome)),
      button("square.stack", "App Switcher (⌘2)", #selector(appSwitcher)),
      button("magnifyingglass", "Spotlight (⌘3)", #selector(spotlight)),
    ])
    bar.spacing = 10
    bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
    bar.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = bar
    accessory.layoutAttribute = .trailing
    window.addTitlebarAccessoryViewController(accessory)

    mirrorView = MirrorView(frame: NSRect(origin: .zero, size: rect.size))
    mirrorView.autoresizingMask = [.width, .height]
    wireInput()
    window.contentView = mirrorView
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(mirrorView)
    NSApp.activate(ignoringOtherApps: true)
  }

  private var actualPoints: CGSize {
    let screen = mirrorView.screenSize
    return screen.width > 0 ? Geometry.points(forPixels: screen) : CGSize(width: 402, height: 874)
  }

  /// Sizes the window to the phone's point size times `zoom`, keeping its top-left corner,
  /// shrunk and moved as needed to stay on the screen.
  private func fitWindow() {
    let points = actualPoints
    var size = NSSize(width: points.width * zoom, height: points.height * zoom)
    window.contentAspectRatio = points
    let chrome = window.frameRect(forContentRect: .zero).size
    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
      let fit = min(1, (visible.width - chrome.width) / size.width, (visible.height - chrome.height) / size.height)
      size = NSSize(width: size.width * fit, height: size.height * fit)
    }
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: size.width.rounded(), height: size.height.rounded())))
    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
      frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
      frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
    }
    window.setFrame(frame, display: true, animate: false)
  }

  private func setZoom(_ value: CGFloat) {
    zoom = max(0.4, min(2.5, value))
    UserDefaults.standard.set(Double(zoom), forKey: "zoom")
    fitWindow()
  }

  @objc private func larger() { setZoom(zoom * 1.15) }
  @objc private func smaller() { setZoom(zoom / 1.15) }
  @objc private func actualSize() { setZoom(1) }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard let content = window.contentView, actualPoints.width > 0 else { return }
    zoom = content.bounds.width / actualPoints.width
    UserDefaults.standard.set(Double(zoom), forKey: "zoom")
  }

  // MARK: Input

  private func setStatus(_ text: String, hold: Double = 0) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.statusHoldUntil = hold > 0 ? ProcessInfo.processInfo.systemUptime + hold : 0
      self.statusLabel.stringValue = text
    }
  }

  private func perform(_ what: String, _ work: @escaping (PhoneLink) throws -> Void) {
    session.perform(work) { [weak self] err in self?.setStatus("\(what): \(err)", hold: 6) }
  }

  private func wireInput() {
    mirrorView.onTouch = { [weak self] p, down in
      self?.perform("Touch") { try $0.touch(x: p.x, y: p.y, down: down) }
    }
    mirrorView.onLongPress = { [weak self] p in
      self?.perform("Long press") { try $0.gesture(x1: p.x, y1: p.y, x2: p.x, y2: p.y, duration: 0.8) }
    }
    mirrorView.onChord = { [weak self] chord in self?.perform("Key") { try $0.chord(chord) } }
    mirrorView.onText = { [weak self] text in self?.perform("Type") { try $0.paste(text) } }
    mirrorView.onPaste = { [weak self] in
      if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
        self?.perform("Paste") { try $0.paste(text) }
      } else {
        self?.perform("Paste") { try $0.chord([KeyMap.command, 0x19]) }
      }
    }
    mirrorView.onCopy = { [weak self] chord in
      self?.perform("Copy") { link in
        try link.chord(chord)
        Thread.sleep(forTimeInterval: 0.35)
        guard let text = try link.pasteboardText(), !text.isEmpty else { return }
        DispatchQueue.main.async {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      }
    }
    mirrorView.onDropText = { [weak self] p, text in
      self?.perform("Drop") { link in
        try link.gesture(x1: p.x, y1: p.y, x2: p.x, y2: p.y, duration: 0.06)
        Thread.sleep(forTimeInterval: 0.4)
        try link.paste(text)
      }
    }
    mirrorView.onDropURL = { [weak self] url in self?.perform("Open link") { try $0.openURL(url) } }
    mirrorView.onClickWhilePaused = { [weak self] in self?.resume() }
  }

  @objc private func pressHome() { perform("Home") { try $0.home() } }

  @objc private func appSwitcher() {
    perform("App Switcher") { link in
      try link.home()
      Thread.sleep(forTimeInterval: 0.08)
      try link.home()
    }
  }

  @objc private func spotlight() {
    let screen = mirrorView.screenSize
    guard screen.height > 0 else { return }
    perform("Spotlight") { link in
      try link.home()
      Thread.sleep(forTimeInterval: 0.6)
      try link.gesture(x1: screen.width / 2, y1: screen.height * 0.35,
                       x2: screen.width / 2, y2: screen.height * 0.6, duration: 0.3)
    }
  }

  @objc private func pressLock() {
    // The video stream wakes the display, so stop reading frames until asked.
    mirrorView.paused = true
    setStatus("Locking…")
    perform("Lock") { [weak self] link in
      try link.lock()
      self?.setStatus("Locked · click to wake, ⌘U to unlock")
    }
  }

  @objc private func unlock() {
    resume()
    setStatus("Unlocking…", hold: 15)
    perform("Unlock") { [weak self] link in
      try link.unlock()
      self?.setStatus("Unlocked", hold: 1.5)
    }
  }

  @objc private func reconnect() {
    session.reset()
    resume()
  }

  private func resume() { mirrorView.paused = false }

  // MARK: Stream

  private func startStreaming() {
    streamRunning = true
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      var frames = 0
      var windowStart = ProcessInfo.processInfo.systemUptime
      var fps = 0.0
      var lastStatus = 0.0
      var orientation = Orientation.rot0
      var locked = false

      while self.streamRunning {
        if self.session.hasPendingInput || self.mirrorView.paused {
          Thread.sleep(forTimeInterval: 0.01)
          continue
        }
        autoreleasepool {
          do {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastStatus >= 1 {
              lastStatus = now
              if let status = try? self.session.read({ try $0.status() }) {
                orientation = Orientation(reported: status.orientation)
                locked = status.locked
              }
            }
            if let image = try self.session.read({ try $0.frame(wait: 0.05) }) {
              frames += 1
              let now = ProcessInfo.processInfo.systemUptime
              if now - windowStart >= 1 {
                fps = Double(frames) / (now - windowStart)
                frames = 0
                windowStart = now
              }
              let shownOrientation = orientation, shownLocked = locked, shownFPS = fps
              DispatchQueue.main.async {
                if self.mirrorView.update(frame: image, orientation: shownOrientation) { self.fitWindow() }
                if self.mirrorView.paused { return }
                if ProcessInfo.processInfo.systemUptime < self.statusHoldUntil { return }
                self.statusLabel.stringValue = shownLocked
                  ? "Locked · ⌘U to unlock" : String(format: "%.0f fps", shownFPS)
              }
            }
            Thread.sleep(forTimeInterval: 0.012)
          } catch {
            self.setStatus("Waiting: \(error.localizedDescription)")
            self.session.reset()
            Thread.sleep(forTimeInterval: 1)
          }
        }
      }
    }
  }
}

private extension CGFloat {
  var nonZero: CGFloat? { self == 0 ? nil : self }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
