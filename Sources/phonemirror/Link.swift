import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LightpinkyCore

/// What the mirror needs from a phone. Coordinates are upright screen pixels.
protocol PhoneLink: AnyObject {
  func frame(wait: Double) throws -> CGImage?
  /// Orientation and lock state, polled about once a second.
  func status() throws -> (orientation: String, locked: Bool)
  func touch(x: Double, y: Double, down: Bool) throws
  func gesture(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws
  func chord(_ usages: [UInt8]) throws
  func home() throws
  func paste(_ text: String) throws
  func pasteboardText() throws -> String?
  func openURL(_ url: String) throws
  func lock() throws
  func unlock() throws
  func close()
}

/// A paired iPhone through LightpinkyCore's native CoreDevice channels.
final class LightpinkyLink: PhoneLink {
  private let phone: Phone

  init() throws {
    let devices = try PhoneInfo.discover()
    let wanted = ProcessInfo.processInfo.environment["LIGHTPINKY_DEVICE"]
    let matches = wanted.map { id in devices.filter { $0.id == id || $0.udid == id || $0.name == id } } ?? devices
    guard matches.count == 1 else {
      throw PhoneError(matches.isEmpty ? "No paired iPhone found" :
        "\(matches.count) paired iPhones; set LIGHTPINKY_DEVICE to one UDID")
    }
    phone = Phone(matches[0])
  }

  func frame(wait: Double) throws -> CGImage? { try phone.videoFrame(wait: wait, maxAge: 2) }
  func status() throws -> (orientation: String, locked: Bool) {
    (try phone.orientation(), try phone.power()["Locked"] as? Bool ?? false)
  }
  func touch(x: Double, y: Double, down: Bool) throws { try phone.touch(x: x, y: y, down: down) }
  func gesture(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
    try phone.gesture(x1: x1, y1: y1, x2: x2, y2: y2, duration: duration)
  }
  func chord(_ usages: [UInt8]) throws { try phone.keyChord(usages) }
  func home() throws { try phone.key("home") }
  func paste(_ text: String) throws { try phone.type(text, append: true, submit: false) }
  func pasteboardText() throws -> String? { try phone.pasteboardText() }
  func openURL(_ url: String) throws { try phone.openURL(url) }
  func lock() throws { try phone.lock() }
  func unlock() throws {
    Self.loadUnlockCodeIfNeeded()
    try phone.unlock()
  }
  func close() { phone.endDisplaySession() }

  private static func loadUnlockCodeIfNeeded() {
    if let existing = ProcessInfo.processInfo.environment["IPHONE_UNLOCK_CODE"], !existing.isEmpty {
      return
    }
    guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
    let proc = Process()
    let pipe = Pipe()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = [
      "-c",
      "set +x; if [ -f \"$HOME/.zshrc\" ]; then source \"$HOME/.zshrc\" >/dev/null 2>&1; fi; printf '%s' \"$IPHONE_UNLOCK_CODE\"",
    ]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0,
          let code = String(data: data, encoding: .utf8),
          !code.isEmpty else { return }
    setenv("IPHONE_UNLOCK_CODE", code, 1)
  }
}

/// Shows a still image instead of a phone and logs input to stderr, for
/// checking the window, menus and coordinate mapping on a Mac without one.
/// The image is taken as the panel's frame (portrait for an iPhone).
final class StillLink: PhoneLink {
  private let image: CGImage
  private let orientation: String
  private var clipboard = ""

  init(path: String, orientation: String) throws {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw PhoneError("Cannot read \(path)")
    }
    self.image = image
    self.orientation = orientation
  }

  private func log(_ line: String) { FileHandle.standardError.write(Data("still: \(line)\n".utf8)) }
  func frame(wait: Double) throws -> CGImage? { image }
  func status() throws -> (orientation: String, locked: Bool) { (orientation, false) }
  func touch(x: Double, y: Double, down: Bool) throws { log("touch \(Int(x)),\(Int(y)) \(down ? "down" : "up")") }
  func gesture(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
    log("gesture \(Int(x1)),\(Int(y1)) -> \(Int(x2)),\(Int(y2)) \(String(format: "%.2f", duration))s")
  }
  func chord(_ usages: [UInt8]) throws { log("chord " + usages.map { String(format: "%02x", $0) }.joined(separator: "+")) }
  func home() throws { log("home") }
  func paste(_ text: String) throws { clipboard = text; log("paste \(text.debugDescription)") }
  func pasteboardText() throws -> String? { log("read pasteboard"); return clipboard }
  func openURL(_ url: String) throws { log("open \(url)") }
  func lock() throws { log("lock") }
  func unlock() throws { log("unlock") }
  func close() {}
}

/// Serializes every phone call on one queue; input jumps ahead of frame reads.
final class PhoneSession {
  private let queue = DispatchQueue(label: "phonemirror.phone", qos: .userInteractive)
  private let stateLock = NSLock()
  private let makeLink: () throws -> PhoneLink
  private var link: PhoneLink?
  private var pendingInputs = 0
  private var stopped = false

  init(makeLink: @escaping () throws -> PhoneLink) { self.makeLink = makeLink }

  var hasPendingInput: Bool { locked { pendingInputs > 0 } }

  private func locked<T>(_ body: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body()
  }

  private func connected() throws -> PhoneLink {
    if let link { return link }
    let made = try makeLink()
    link = made
    return made
  }

  /// Runs on the phone queue and returns its result; nil once stopped.
  func read<T>(_ work: (PhoneLink) throws -> T?) throws -> T? {
    if locked({ stopped }) { return nil }
    return try queue.sync {
      if locked({ stopped }) { return nil }
      return try work(connected())
    }
  }

  func perform(_ work: @escaping (PhoneLink) throws -> Void, onError: ((String) -> Void)? = nil) {
    locked { pendingInputs += 1 }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.locked { self.pendingInputs = max(0, self.pendingInputs - 1) } }
      if self.locked({ self.stopped }) { return }
      do { try work(self.connected()) } catch { onError?(error.localizedDescription) }
    }
  }

  func reset() {
    queue.async { [weak self] in
      self?.link?.close()
      self?.link = nil
    }
  }

  /// Waits briefly for clean teardown (closing AX and display sessions) before a tunnel reset.
  func resetSync(timeout: Double = 2) {
    let done = DispatchSemaphore(value: 0)
    queue.async { [weak self] in
      self?.link?.close()
      self?.link = nil
      done.signal()
    }
    _ = done.wait(timeout: .now() + timeout)
  }

  func shutdown() {
    locked { stopped = true }
    queue.sync {
      link?.close()
      link = nil
    }
  }
}
