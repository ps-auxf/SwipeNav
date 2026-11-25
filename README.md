# SwipeNav

Two-finger trackpad swipe → Back / Forward for macOS browsers that don't support swipe navigation natively, such as the [Ladybird](https://ladybird.org) alpha.

SwipeNav is a tiny menu bar app. It watches trackpad scroll gestures and, when the frontmost app is in its list, triggers that app's **Back** / **Forward** menu items. If it can't find a matching menu item, it sends a configurable keyboard shortcut instead.

## Features

- Navigation happens **when you lift your fingers**. Swipe back below the distance threshold to cancel.
- The axis is **locked at the start of a gesture**, so vertical scrolls never navigate.
- Works with **any app**: add bundle IDs manually or pick from running apps.
- Triggers **menu items via Accessibility**, so it doesn't depend on your keyboard layout. Configurable shortcut fallback with a built-in recorder.
- Swappable swipe direction, adjustable distance and strictness.
- Permission status display with shortcuts to System Settings.
- Launch at login, reset to defaults.
- All settings apply live, no recompiling needed.

## Requirements

- macOS 13 Ventura or later
- A trackpad (Magic Trackpad or built-in)
- Xcode Command Line Tools: `xcode-select --install`

## Build & install

Run from the folder containing `swipenav.swift`:

```bash
# 1. Compile
swiftc -O swipenav.swift -o swipenav

# 2. Create the app bundle
APP=~/Applications/SwipeNav.app
mkdir -p "$APP/Contents/MacOS"
cp swipenav "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>swipenav</string>
    <key>CFBundleIdentifier</key><string>local.swipenav</string>
    <key>CFBundleName</key><string>SwipeNav</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# 3. Sign (ad-hoc; see "Keeping permissions across rebuilds" below)
codesign --force --sign - "$APP"

# 4. Launch
open "$APP"
```

`LSUIElement` makes SwipeNav run without a Dock icon. It only appears in the menu bar.

## Permissions

SwipeNav needs two permissions in **System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| **Input Monitoring** | To read trackpad scroll gestures |
| **Accessibility** | To press menu items and send fallback shortcuts |

On first launch, SwipeNav adds itself to both lists and opens its settings window. Enable both entries. The **Permissions** section shows ✓ / ✗ for each. If "Gesture detection active" stays ✗ after granting access, click **Relaunch**.

## Usage

Click the menu bar icon (✋) for **Enabled**, **Settings…** (⌘,) and **Quit**.

| Setting | Description |
|---|---|
| Enabled | Turns gesture detection on or off. The icon changes accordingly; ⚠️ means a permission is missing. |
| Launch at login | Registers SwipeNav as a login item. |
| Swap directions | Default: swipe **left → Back**, **right → Forward**. Swap for Safari-style behaviour. |
| Swipe distance | Horizontal distance in points needed when you lift your fingers. Higher means fewer accidental triggers. |
| Horizontal strictness | How much more horizontal than vertical a gesture must start to count as a swipe. |
| Apps | Comma-separated bundle IDs. Default: `org.ladybird.Ladybird`. Use **Add running app** or `osascript -e 'id of app "AppName"'` to find an ID. |
| Menu titles | Comma-separated titles of the app's Back / Forward menu items. |
| Fallback shortcuts | Sent only if no matching menu item is found. Default: ⌘← / ⌘→. Click to record a new one, Esc cancels. |

## Keeping permissions across rebuilds

macOS ties privacy permissions to an ad-hoc signed binary's exact build. **After every rebuild**, remove SwipeNav from both permission lists with "–", add it again, then relaunch.

To avoid this, sign with a self-signed certificate:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `SwipeNav Dev`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**.
3. Sign with it instead of ad-hoc:
   ```bash
   codesign --force --sign "SwipeNav Dev" ~/Applications/SwipeNav.app
   ```

Permissions are then tied to your certificate and survive rebuilds.

## Updating

```bash
swiftc -O swipenav.swift -o swipenav
pkill swipenav
cp swipenav ~/Applications/SwipeNav.app/Contents/MacOS/
codesign --force --sign "SwipeNav Dev" ~/Applications/SwipeNav.app   # or --sign -
open ~/Applications/SwipeNav.app
```

## Debugging

Run the binary from Terminal to see what's happening (axis lock, armed/disarmed, menu vs. shortcut):

```bash
pkill swipenav
~/Applications/SwipeNav.app/Contents/MacOS/swipenav -v
```

When started from Terminal this way, macOS checks the **Terminal's** permissions, not SwipeNav's.

## Uninstall

1. Turn off **Launch at login** in the settings, then quit SwipeNav.
2. `rm -rf ~/Applications/SwipeNav.app`
3. `defaults delete local.swipenav`
4. Remove SwipeNav from Input Monitoring and Accessibility in System Settings.

## Known limitations

- **Horizontally scrolling content:** SwipeNav can't see inside the browser. Swiping on a carousel or a wide table may also trigger navigation once the distance is reached. A higher swipe distance reduces this. Only native browser support can solve it properly, because only the browser knows whether the content is already scrolled to its edge.
- **No swipe animation:** Navigation happens instantly on release.
- **Native support:** Once an app supports swipe navigation itself, remove it from SwipeNav's list, otherwise a swipe may navigate twice.

---

Released under the [MIT License](LICENSE). SwipeNav is not affiliated with the Ladybird project.
