// swipenav.swift — Two-finger swipe → Back/Forward for browsers without native swipe navigation (e.g. Ladybird)
// Menu bar app with a settings window; all settings apply live, no recompiling needed.
//
// Build:        swiftc -O swipenav.swift -o swipenav        (requires macOS 13+)
// Install:      copy into SwipeNav.app/Contents/MacOS/ and sign (Info.plist with LSUIElement=true)
// Permissions:  System Settings → Privacy & Security → "Input Monitoring" AND "Accessibility" for SwipeNav
// Debug:        ~/Applications/SwipeNav.app/Contents/MacOS/swipenav -v

import Cocoa
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Settings (UserDefaults, read live)

enum Key {
    static let enabled = "enabled"
    static let swap = "swapDirections"
    static let threshold = "threshold"
    static let ratio = "horizontalRatio"
    static let bundleIDs = "bundleIDs"
    static let backTitles = "backTitles"
    static let forwardTitles = "forwardTitles"
    static let backCode = "backKeyCode", backMods = "backKeyMods", backLabel = "backKeyLabel"
    static let fwdCode = "forwardKeyCode", fwdMods = "forwardKeyMods", fwdLabel = "forwardKeyLabel"
}

enum Defaults {
    static let d = UserDefaults.standard
    static let cmd = Int(NSEvent.ModifierFlags.command.rawValue)
    static let initial: [String: Any] = [
        Key.enabled: true,
        Key.swap: false,                     // false: swipe left → Back, right → Forward
        Key.threshold: 140.0,                // horizontal points needed at release
        Key.ratio: 2.5,                      // |dx| vs |dy| at gesture start to count as horizontal
        Key.bundleIDs: "org.ladybird.Ladybird",
        Key.backTitles: "Back, Go Back, Zurück",
        Key.forwardTitles: "Forward, Go Forward, Vorwärts",
        Key.backCode: 123, Key.backMods: cmd, Key.backLabel: "⌘←",   // Cmd+←
        Key.fwdCode: 124, Key.fwdMods: cmd, Key.fwdLabel: "⌘→",      // Cmd+→
    ]
    static func register() { d.register(defaults: initial) }
    static func reset() { initial.keys.forEach { d.removeObject(forKey: $0) } }
    static func list(_ key: String) -> [String] {
        (d.string(forKey: key) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    static var enabled: Bool { d.bool(forKey: Key.enabled) }
    static var bundleIDs: Set<String> { Set(list(Key.bundleIDs)) }
}

let lockDistance = 10.0   // points of movement after which the gesture axis is decided

let verbose = CommandLine.arguments.contains("-v")
func log(_ s: String) { if verbose { print(s) } }

// MARK: - Navigation

func frontmostTarget() -> NSRunningApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let id = app.bundleIdentifier, Defaults.bundleIDs.contains(id) else { return nil }
    return app
}

func findAndPress(_ el: AXUIElement, _ titles: [String], depth: Int) -> Bool {
    if depth > 4 { return false }
    var title: CFTypeRef?, role: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title) == .success,
       let t = title as? String, titles.contains(t),
       AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
       (role as? String) == (kAXMenuItemRole as String) {
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
          let children = kids as? [AXUIElement] else { return false }
    for child in children where findAndPress(child, titles, depth: depth + 1) { return true }
    return false
}

func pressMenu(_ titles: [String], pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
          let menuBar = bar else { return false }
    return findAndPress(menuBar as! AXUIElement, titles, depth: 0)
}

func cgFlags(_ raw: Int) -> CGEventFlags {
    let m = NSEvent.ModifierFlags(rawValue: UInt(raw))
    var f: CGEventFlags = []
    if m.contains(.command) { f.insert(.maskCommand) }
    if m.contains(.option) { f.insert(.maskAlternate) }
    if m.contains(.control) { f.insert(.maskControl) }
    if m.contains(.shift) { f.insert(.maskShift) }
    return f
}

func sendKey(code: Int, mods: Int) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
        e?.flags = cgFlags(mods)
        e?.post(tap: .cghidEventTap)
    }
}

func navigate(back: Bool, pid: pid_t) {
    // Run outside the tap callback so the tap doesn't hit its timeout
    DispatchQueue.main.async {
        let ok = pressMenu(Defaults.list(back ? Key.backTitles : Key.forwardTitles), pid: pid)
        if !ok {
            sendKey(code: Defaults.d.integer(forKey: back ? Key.backCode : Key.fwdCode),
                    mods: Defaults.d.integer(forKey: back ? Key.backMods : Key.fwdMods))
        }
        log("\(back ? "← back" : "→ forward") via \(ok ? "menu" : "shortcut")")
    }
}

// MARK: - Event tap

enum Axis { case undecided, horizontal, vertical }

var tap: CFMachPort?
var tracking = false
var axis = Axis.undecided
var armed = false
var accX = 0.0, accY = 0.0
var inverted = true
// Settings snapshot per gesture
var gThreshold = 140.0, gRatio = 2.5, gSwap = false

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,          // trackpad only
          event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0          // ignore momentum
    else { return Unmanaged.passUnretained(event) }

    switch event.getIntegerValueField(.scrollWheelEventScrollPhase) {
    case 1: // began
        tracking = Defaults.enabled && frontmostTarget() != nil
        axis = .undecided; armed = false; accX = 0; accY = 0
        gThreshold = Defaults.d.double(forKey: Key.threshold)
        gRatio = Defaults.d.double(forKey: Key.ratio)
        gSwap = Defaults.d.bool(forKey: Key.swap)

    case 2: // changed
        guard tracking else { break }
        accX += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        accY += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if let ns = NSEvent(cgEvent: event) { inverted = ns.isDirectionInvertedFromDevice }

        // (2) Lock the axis early: a gesture that starts vertical never navigates
        if axis == .undecided && abs(accX) + abs(accY) >= lockDistance {
            axis = abs(accX) > gRatio * abs(accY) ? .horizontal : .vertical
            log("axis: \(axis)")
        }
        // (1) Arm when far enough; disarm when moved back → user can still cancel
        if axis == .horizontal {
            let nowArmed = abs(accX) >= gThreshold
            if nowArmed != armed {
                armed = nowArmed
                log(armed ? "armed" : "disarmed")
            }
        }

    case 4: // ended → (1) navigate only on release
        if tracking && axis == .horizontal && armed, let app = frontmostTarget() {
            let fingersMovedLeft = (inverted ? accX : -accX) < 0
            navigate(back: fingersMovedLeft != gSwap, pid: app.processIdentifier)
        }
        tracking = false

    case 8: // cancelled
        tracking = false

    default: break
    }
    return Unmanaged.passUnretained(event)
}

func startTap() -> Bool {
    if tap != nil { return true }
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                    options: .listenOnly, eventsOfInterest: mask,
                                    callback: callback, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    log("event tap active")
    return true
}

func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

func relaunch() {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

// MARK: - Shortcut recorder

func describeKey(code: UInt16, chars: String?, mods: NSEvent.ModifierFlags) -> String {
    var s = ""
    if mods.contains(.control) { s += "⌃" }
    if mods.contains(.option) { s += "⌥" }
    if mods.contains(.shift) { s += "⇧" }
    if mods.contains(.command) { s += "⌘" }
    let names: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 48: "⇥",
                                   49: "Space", 51: "⌫", 117: "⌦", 116: "⇞", 121: "⇟", 115: "↖", 119: "↘"]
    return s + (names[code] ?? chars?.uppercased() ?? "Key \(code)")
}

struct ShortcutRecorder: View {
    let codeKey: String, modsKey: String
    @AppStorage var label: String
    @State private var recording = false
    @State private var monitor: Any?

    init(codeKey: String, modsKey: String, labelKey: String) {
        self.codeKey = codeKey
        self.modsKey = modsKey
        _label = AppStorage(wrappedValue: Defaults.initial[labelKey] as? String ?? "", labelKey)
    }

    var body: some View {
        Button(recording ? "Type shortcut… (Esc cancels)" : label) {
            recording ? stop() : start()
        }
        .onDisappear(perform: stop)
    }

    func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            Defaults.d.set(Int(e.keyCode), forKey: codeKey)
            Defaults.d.set(Int(mods.rawValue), forKey: modsKey)
            label = describeKey(code: e.keyCode, chars: e.charactersIgnoringModifiers, mods: mods)
            stop()
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @AppStorage(Key.enabled) var enabled = true
    @AppStorage(Key.swap) var swap = false
    @AppStorage(Key.threshold) var threshold = 140.0
    @AppStorage(Key.ratio) var ratio = 2.5
    @AppStorage(Key.bundleIDs) var bundleIDs = "org.ladybird.Ladybird"
    @AppStorage(Key.backTitles) var backTitles = "Back, Go Back, Zurück"
    @AppStorage(Key.forwardTitles) var forwardTitles = "Forward, Go Forward, Vorwärts"
    @State var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State var loginError: String?
    // (3) Permission status, refreshed periodically
    @State var inputMonitoringOK = CGPreflightListenEventAccess()
    @State var accessibilityOK = AXIsProcessTrusted()
    @State var tapActive = tap != nil
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var runningApps: [(name: String, id: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshStatus() {
        inputMonitoringOK = CGPreflightListenEventAccess()
        accessibilityOK = AXIsProcessTrusted()
        tapActive = tap != nil
    }

    func statusRow(_ name: String, ok: Bool, pane: String?) -> some View {
        LabeledContent(name) {
            HStack(spacing: 8) {
                if !ok, let pane { Button("Open Settings") { openPrivacyPane(pane) } }
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
            }
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Enabled", isOn: $enabled)
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section("Permissions") {
                statusRow("Input Monitoring", ok: inputMonitoringOK, pane: "Privacy_ListenEvent")
                statusRow("Accessibility", ok: accessibilityOK, pane: "Privacy_Accessibility")
                statusRow("Gesture detection active", ok: tapActive, pane: nil)
                if !(inputMonitoringOK && accessibilityOK && tapActive) {
                    HStack {
                        Text("After a rebuild, remove and re-add SwipeNav in both lists, then relaunch.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch", action: relaunch)
                    }
                }
            }

            Section("Gesture") {
                Toggle("Swap directions", isOn: $swap)
                Text(swap ? "Swipe left → Forward, swipe right → Back"
                          : "Swipe left → Back, swipe right → Forward")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Swipe distance: \(Int(threshold)) pt") {
                    Slider(value: $threshold, in: 40...400, step: 10)
                }
                LabeledContent(String(format: "Horizontal strictness: %.1f×", ratio)) {
                    Slider(value: $ratio, in: 1...5, step: 0.1)
                }
                Text("Navigation happens when you lift your fingers. Swipe back below the distance to cancel. Strictness decides at the start of a gesture whether it counts as horizontal; vertical scrolls never navigate.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Apps (bundle IDs, comma-separated)") {
                TextField("Bundle IDs", text: $bundleIDs).labelsHidden()
                Menu("Add running app") {
                    ForEach(runningApps, id: \.id) { app in
                        Button("\(app.name) (\(app.id))") {
                            var ids = Defaults.list(Key.bundleIDs)
                            if !ids.contains(app.id) { ids.append(app.id) }
                            bundleIDs = ids.joined(separator: ", ")
                        }
                    }
                }
            }

            Section("Navigation") {
                TextField("Back menu titles", text: $backTitles)
                TextField("Forward menu titles", text: $forwardTitles)
                LabeledContent("Back fallback shortcut") {
                    ShortcutRecorder(codeKey: Key.backCode, modsKey: Key.backMods, labelKey: Key.backLabel)
                }
                LabeledContent("Forward fallback shortcut") {
                    ShortcutRecorder(codeKey: Key.fwdCode, modsKey: Key.fwdMods, labelKey: Key.fwdLabel)
                }
                Text("Menu items are tried first (comma-separated titles). The shortcut is only sent if no matching menu item is found.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults", role: .destructive) { Defaults.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .onReceive(timer) { _ in refreshStatus() }
        .onAppear(perform: refreshStatus)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var enabledItem: NSMenuItem!
    var window: NSWindow?
    var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.register()
        buildMainMenu()
        buildStatusItem()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { log("Accessibility permission missing") }

        if !startTap() {
            // Adds SwipeNav to the Input Monitoring list, then keep retrying until it's granted
            CGRequestListenEventAccess()
            openSettings()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if startTap() { t.invalidate(); self?.updateIcon() }
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(updateIcon),
                                               name: UserDefaults.didChangeNotification, object: nil)
        updateIcon()
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SwipeNav", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // Edit menu so Cmd+C / Cmd+V / Cmd+A work in the settings text fields
    func buildMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func updateIcon() {
        let symbol = tap == nil ? "exclamationmark.triangle"
                   : Defaults.enabled ? "hand.draw" : "hand.raised.slash"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SwipeNav")
    }

    func menuWillOpen(_ menu: NSMenu) { enabledItem.state = Defaults.enabled ? .on : .off }

    @objc func toggleEnabled() { Defaults.d.set(!Defaults.enabled, forKey: Key.enabled) }

    @objc func openSettings() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 760),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: SettingsView())
            w.title = "SwipeNav Settings"
            w.minSize = NSSize(width: 480, height: 400)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
