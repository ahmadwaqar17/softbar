#!/bin/bash
# SoftBar installer - an on-screen replacement for a broken MacBook Touch Bar.
# Usage:  bash install.sh        (or: curl -fsSL <raw-url>/install.sh | bash)
# Installs to ~/Applications/SoftBar.app, starts at login. No admin password needed.
set -euo pipefail

APP="$HOME/Applications/SoftBar.app"
AGENT="$HOME/Library/LaunchAgents/com.softbar.agent.plist"
WORK="$(mktemp -d /tmp/softbar.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "This installer is for macOS only."

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl unload "$AGENT" 2>/dev/null || true
  pkill -x SoftBar 2>/dev/null || true
  rm -rf "$APP" "$AGENT"
  say "SoftBar removed. (You can also remove it from Privacy & Security -> Accessibility.)"
  exit 0
fi

# 1. Apple's free Command Line Tools provide the Swift compiler.
if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Apple Command Line Tools (one time, a few minutes)..."
  say "A window will pop up - click 'Install' and agree. This script waits for it."
  xcode-select --install >/dev/null 2>&1 || true
  for _ in $(seq 1 360); do xcode-select -p >/dev/null 2>&1 && break; sleep 5; done
  xcode-select -p >/dev/null 2>&1 || die "Command Line Tools not installed. Run this script again after installing them."
fi

# 2. Write the app source.
say "Building SoftBar..."
cat > "$WORK/SoftBar.swift" <<'EOF_SWIFT'
import Cocoa
import Carbon.HIToolbox

// MARK: - Key posting
let kNXSoundUp: Int32 = 0, kNXSoundDown: Int32 = 1, kNXBrightUp: Int32 = 2, kNXBrightDown: Int32 = 3
let kNXMute: Int32 = 7, kNXPlay: Int32 = 16, kNXNext: Int32 = 17, kNXPrev: Int32 = 18
let kNXIllumUp: Int32 = 21, kNXIllumDown: Int32 = 22

func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) {
            if !flags.isEmpty { e.flags = e.flags.union(flags) }
            e.post(tap: .cghidEventTap)
        }
    }
}

func postSystemKey(_ key: Int32) {
    for down in [true, false] {
        let state: Int = down ? 0xa00 : 0xb00
        let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                                    timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                    data1: (Int(key) << 16) | state, data2: -1)
        ev?.cgEvent?.post(tap: .cghidEventTap)
    }
}

let fKeyCodes: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

// MARK: - Panel that never steals focus
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

var hotKeyCallback: (() -> Void)?

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: BarPanel!
    var controlsRow: NSStackView!
    var fnRow: NSStackView!
    var statusItem: NSStatusItem!
    var showingFn = false
    var lockedFn = false
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildPanel()
        buildStatusItem()
        registerHotKey()
        // Hold the physical fn key to show F1-F12, like the real Touch Bar.
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.fnChanged(e) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.fnChanged(e); return e }
        checkAccessibility(prompt: true)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkAccessibility(prompt: false) }
    }

    // MARK: UI
    func makeButton(_ title: String, symbol: String?, tip: String, repeats: Bool = false, width: CGFloat = 44,
                    action: @escaping () -> Void) -> NSButton {
        let b = ActionButton(frame: .zero)
        b.handler = action
        b.target = b
        b.action = #selector(ActionButton.fire)
        b.bezelStyle = .regularSquare
        b.isBordered = true
        b.setButtonType(.momentaryPushIn)
        b.toolTip = tip
        b.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        var usedSymbol = false
        if let s = symbol, #available(macOS 11.0, *) {
            if let img = NSImage(systemSymbolName: s, accessibilityDescription: tip) {
                b.image = img
                b.imagePosition = .imageOnly
                usedSymbol = true
            }
        }
        if !usedSymbol { b.title = title }
        if repeats {
            b.isContinuous = true
            b.setPeriodicDelay(0.35, interval: 0.08)
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    func gap() -> NSView {
        let v = NSView(frame: .zero)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 10).isActive = true
        return v
    }

    func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 5
        s.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        return s
    }

    func buildPanel() {
        let esc = { (w: CGFloat) in self.makeButton("esc", symbol: nil, tip: "Escape", width: w) { postKey(53) } }
        controlsRow = row([
            esc(52), gap(),
            makeButton("☀−", symbol: "sun.min", tip: "Brightness down", repeats: true) { postSystemKey(kNXBrightDown) },
            makeButton("☀+", symbol: "sun.max", tip: "Brightness up", repeats: true) { postSystemKey(kNXBrightUp) },
            makeButton("⌨−", symbol: "light.min", tip: "Keyboard light down", repeats: true) { postSystemKey(kNXIllumDown) },
            makeButton("⌨+", symbol: "light.max", tip: "Keyboard light up", repeats: true) { postSystemKey(kNXIllumUp) },
            gap(),
            makeButton("⏮", symbol: "backward.fill", tip: "Previous") { postSystemKey(kNXPrev) },
            makeButton("⏯", symbol: "playpause.fill", tip: "Play / Pause") { postSystemKey(kNXPlay) },
            makeButton("⏭", symbol: "forward.fill", tip: "Next") { postSystemKey(kNXNext) },
            gap(),
            makeButton("🔇", symbol: "speaker.slash.fill", tip: "Mute") { postSystemKey(kNXMute) },
            makeButton("🔉", symbol: "speaker.wave.1.fill", tip: "Volume down", repeats: true) { postSystemKey(kNXSoundDown) },
            makeButton("🔊", symbol: "speaker.wave.3.fill", tip: "Volume up", repeats: true) { postSystemKey(kNXSoundUp) },
            gap(),
            makeButton("📷", symbol: "camera.viewfinder", tip: "Screenshot (⇧⌘5)") { postKey(23, flags: [.maskShift, .maskCommand]) },
            makeButton("🔒", symbol: "lock.fill", tip: "Lock screen (⌃⌘Q)") { postKey(12, flags: [.maskControl, .maskCommand]) },
            makeButton("fn", symbol: nil, tip: "Show F1–F12", width: 40) { [weak self] in self?.toggleFnLock() },
        ])
        var fnViews: [NSView] = [esc(52), gap()]
        for (i, code) in fnKeyCodesEnumerated() {
            fnViews.append(makeButton("F\(i + 1)", symbol: nil, tip: "F\(i + 1)", width: 46) { postKey(code) })
        }
        fnViews.append(gap())
        fnViews.append(makeButton("✕", symbol: "xmark", tip: "Back to controls", width: 40) { [weak self] in self?.toggleFnLock() })
        fnRow = row(fnViews)

        panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 44),
                         styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        panel.contentView = fx
        for r in [controlsRow!, fnRow!] {
            r.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(r)
            r.centerXAnchor.constraint(equalTo: fx.centerXAnchor).isActive = true
            r.centerYAnchor.constraint(equalTo: fx.centerYAnchor).isActive = true
        }
        fnRow.isHidden = true
        layout(resetPosition: !panel.setFrameUsingName("SoftBarFrame"))
        panel.setFrameAutosaveName("SoftBarFrame")
        panel.orderFrontRegardless()
    }

    func fnKeyCodesEnumerated() -> [(Int, CGKeyCode)] {
        return fKeyCodes.enumerated().map { ($0.offset, $0.element) }
    }

    func layout(resetPosition: Bool = false) {
        let active = showingFn ? fnRow! : controlsRow!
        controlsRow.isHidden = showingFn
        fnRow.isHidden = !showingFn
        let size = active.fittingSize
        var f = panel.frame
        let centerX = f.midX
        f.size = NSSize(width: size.width, height: size.height)
        if resetPosition, let scr = NSScreen.main {
            f.origin.x = scr.visibleFrame.midX - size.width / 2
            f.origin.y = scr.visibleFrame.minY + 8
        } else {
            f.origin.x = centerX - size.width / 2
        }
        panel.setFrame(f, display: true)
    }

    func setFn(_ on: Bool) {
        if on == showingFn { return }
        showingFn = on
        layout()
    }

    func toggleFnLock() {
        lockedFn = !showingFn
        setFn(lockedFn)
    }

    func fnChanged(_ e: NSEvent) {
        let fnDown = e.modifierFlags.contains(.function)
        setFn(fnDown || lockedFn)
    }

    // MARK: Menu bar
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled",
                                                       accessibilityDescription: "SoftBar") {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "▭"
        }
        let m = NSMenu()
        m.addItem(withTitle: "Show / Hide Bar   (⌃⌥T)", action: #selector(toggleBar), keyEquivalent: "").target = self
        m.addItem(withTitle: "Function Keys (F1–F12)", action: #selector(menuFn), keyEquivalent: "").target = self
        m.addItem(withTitle: "Move Bar to Bottom Center", action: #selector(resetPos), keyEquivalent: "").target = self
        m.addItem(withTitle: "Accessibility Permission…", action: #selector(openAX), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit SoftBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc func toggleBar() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
    @objc func menuFn() { toggleFnLock(); panel.orderFrontRegardless() }
    @objc func resetPos() { layout(resetPosition: true); panel.orderFrontRegardless() }
    @objc func openAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func checkAccessibility(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let ok = AXIsProcessTrustedWithOptions(opts)
        panel.alphaValue = ok ? 1.0 : 0.55
        statusItem?.button?.toolTip = ok ? "SoftBar" : "SoftBar needs Accessibility permission"
    }

    // MARK: Global hotkey ⌃⌥T
    func registerHotKey() {
        hotKeyCallback = { [weak self] in self?.toggleBar() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { hotKeyCallback?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53424152), id: 1) // 'SBAR'
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
EOF_SWIFT

swiftc -O "$WORK/SoftBar.swift" -o "$WORK/SoftBar" -framework Cocoa -framework Carbon 2>"$WORK/build.log" || {
  cat "$WORK/build.log"; die "Build failed (log above)."; }

# 3. Assemble the .app bundle.
say "Installing to $APP"
pkill -x SoftBar 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/SoftBar" "$APP/Contents/MacOS/SoftBar"
cat > "$APP/Contents/Info.plist" <<'EOF_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.softbar.app</string>
  <key>CFBundleName</key><string>SoftBar</string>
  <key>CFBundleExecutable</key><string>SoftBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF_PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# 4. Start at login.
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF_AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.softbar.agent</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF_AGENT
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl load -w "$AGENT" 2>/dev/null || true

# 5. Launch, then open the exact permission page so the user only flips one switch.
open "$APP"
sleep 2
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
say "Done! SoftBar is running at the bottom of the screen."
cat <<'EOF_MSG'

  LAST STEP (macOS requires you to do this yourself):
    The Accessibility settings page just opened.
    Turn ON the switch next to "SoftBar". That's it - the bar starts working instantly.

  Tips:
    - Hold the fn key to show F1-F12, or click "fn" on the bar.
    - Ctrl+Option+T shows/hides the bar. Drag it anywhere.
    - Menu bar icon has more options and Quit.
    - Uninstall:  bash install.sh --uninstall   (or see README)
EOF_MSG
