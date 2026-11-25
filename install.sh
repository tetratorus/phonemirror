#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "$0")" && pwd)"
app_dir="${APP_DIR:-$HOME/Applications}"
app_path="$app_dir/PhoneMirror.app"

cd "$repo"
swift build -c release

mkdir -p "$app_dir"
stage="$(mktemp -d "$app_dir/.PhoneMirror.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

bundle="$stage/PhoneMirror.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp ".build/release/phonemirror" "$bundle/Contents/MacOS/PhoneMirror"
chmod 755 "$bundle/Contents/MacOS/PhoneMirror"

# Render a clean rounded iPhone silhouette icon into AppIcon.icns.
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"
swift - "$iconset" <<'SWIFT'
import AppKit
import Foundation

let outDir = CommandLine.arguments[1]

func renderIcon(size: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  )!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(size)

  let bgRect = CGRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
  let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.20, yRadius: s * 0.20)
  let grad = NSGradient(
    starting: NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.22, alpha: 1),
    ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.11, alpha: 1)
  )!
  grad.draw(in: bgPath, angle: -90)

  let pw = s * 0.38
  let ph = s * 0.66
  let px = (s - pw) / 2
  let py = (s - ph) / 2
  let phoneRect = CGRect(x: px, y: py, width: pw, height: ph)
  let phonePath = NSBezierPath(roundedRect: phoneRect, xRadius: s * 0.065, yRadius: s * 0.065)
  NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
  phonePath.lineWidth = max(1.5, s * 0.028)
  phonePath.stroke()

  let screenRect = phoneRect.insetBy(dx: s * 0.026, dy: s * 0.026)
  let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: s * 0.045, yRadius: s * 0.045)
  let screenGrad = NSGradient(
    starting: NSColor(calibratedRed: 0.22, green: 0.56, blue: 0.98, alpha: 1),
    ending: NSColor(calibratedRed: 0.14, green: 0.28, blue: 0.68, alpha: 1)
  )!
  screenGrad.draw(in: screenPath, angle: -65)

  let islandW = pw * 0.34
  let islandH = max(2, s * 0.032)
  let island = NSBezierPath(
    roundedRect: CGRect(x: (s - islandW) / 2, y: py + ph - s * 0.082, width: islandW, height: islandH),
    xRadius: islandH / 2, yRadius: islandH / 2
  )
  NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
  island.fill()

  let barW = pw * 0.38
  let barH = max(1.5, s * 0.016)
  let bar = NSBezierPath(
    roundedRect: CGRect(x: (s - barW) / 2, y: py + s * 0.052, width: barW, height: barH),
    xRadius: barH / 2, yRadius: barH / 2
  )
  NSColor(calibratedWhite: 0.96, alpha: 0.85).setFill()
  bar.fill()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
  ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in specs {
  try renderIcon(size: size).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
SWIFT
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>PhoneMirror</string>
  <key>CFBundleExecutable</key>
  <string>PhoneMirror</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.tetratorus.phonemirror</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PhoneMirror</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$bundle" >/dev/null 2>&1 || true

rm -rf "$app_path"
mv "$bundle" "$app_path"
echo "Installed $app_path"
