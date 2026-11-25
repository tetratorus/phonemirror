# phonemirror

A native macOS window that mirrors and controls a paired physical iPhone through [LightpinkyCore](https://github.com/tetratorus/lightpinky). Needs an Apple silicon Mac with full Xcode, and an iPhone already paired with it.

```sh
./install.sh          # builds and installs ~/Applications/PhoneMirror.app
open ~/Applications/PhoneMirror.app
```

Or run directly from the terminal:

```sh
swift build -c release && .build/release/phonemirror
```

## Controls

| Mac | iPhone |
| --- | --- |
| Click, drag | Tap, finger drag |
| Right-click | Long press |
| Trackpad or wheel scroll | Finger drag; the phone supplies momentum |
| Typing, including ⌘, ⌥, ⇧ and ⌃ shortcuts | Hardware keyboard |
| ⌘C, ⌘X | Copies on the phone, then puts the phone pasteboard on the Mac's |
| ⌘V | Puts the Mac's text on the phone pasteboard and pastes it |
| Drop text / a link onto the window | Pastes the text / opens the link |
| ⌘1, ⌘2, ⌘3 | Home Screen, App Switcher, Spotlight |
| ⌘=, ⌘0, ⌘- | Larger, actual size, smaller window |
| ⌘U, ⌘L, ⇧⌘R, ⌥⇧⌘R | Unlock (uses `IPHONE_UNLOCK_CODE`), lock, reconnect, hard reset tunnel |

The window follows the phone's rotation and remembers its position.

Not supported, because the developer services lightpinky uses do not expose them: notifications, audio, mirroring while the phone stays locked, file drag and drop, and pinch.

## Without a phone

`PHONEMIRROR_STILL=/path/to/screenshot.png` shows a still image instead and logs every phone call to stderr; `PHONEMIRROR_STILL_ORIENTATION=rot90` (or `rot180`, `rot270`) treats it as a rotated panel frame.

`swift test` covers key mapping, rotation, coordinate mapping and scroll-to-drag.
