// Meetboard: your next meeting and a live countdown on a spare display.
// Reads macOS Calendar (EventKit), so any account added in Internet Accounts shows up
// (iCloud, Google, Exchange / Microsoft 365, CalDAV, ICS subscriptions).
// Click the screen to join the next meeting's Teams / Zoom / Meet / Webex link.
// Menu bar item: countdown, join, settings, show or hide the board, open at login, quit (same menu on right-click).
//
// Flags:
//   --demo                       show sample meetings instead of your calendar
//   --snapshot out.png [--scene next|now] [--all] [--phase 0.6] [--size 960x640]
//                                render the demo board to a PNG and exit (--all turns every extra on)
import AppKit
import EventKit
import ServiceManagement

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
Prefs.register()

// MARK: - Snapshot mode (renders the demo board to a PNG: no window, no calendar, no network)

if let out = arg("--snapshot") {
    let all = args.contains("--all")
    Prefs.overrides = ["weather": true, "clocks": all, "zones": "EST, CST, MST, PST, PK, IN", "seasonalLabels": true,
                       "b2b": all, "prayer": all, "prayerMethod": "isna", "asrHanafi": false, "planes": all,
                       "family": all, "location": "43.65,-79.38"]
    let size = (arg("--size") ?? "960x640").split(separator: "x").compactMap { Double($0) }
    let w = CGFloat(size.count == 2 ? size[0] : 960), h = CGFloat(size.count == 2 ? size[1] : 640)
    let board = Board(frame: NSRect(x: 0, y: 0, width: w, height: h))
    // A fixed weekday morning so the screenshot is the same every time.
    board.fixedNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 52, second: 18))
    let scene = arg("--scene") ?? "next"
    board.demoScene = scene + (all ? "+" : "")
    board.onAir = all ? "camera" : nil
    board.fixedPlanePhase = Double(arg("--phase") ?? "0.6")
    weather.now = Weather.Now(symbol: "cloud.sun.fill", temp: 4)
    if all {
        planes.nearest = Plane(label: "Air Canada 857", detail: "Boeing 777  ·  34,000 ft  ·  482 kt  ·  3.2 nm away, heading east")
    }
    board.reload()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        board.displayIgnoringOpacity(board.bounds, in: NSGraphicsContext.current!)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("Wrote \(out)")
    exit(0)
}

// MARK: - App

// Which display: the one picked in Settings (any part of its name), else the smallest display that is not
// the main one; with one display, the main one.
func pickScreen() -> NSScreen {
    let screens = NSScreen.screens
    let want = Prefs.string("screen").uppercased()
    if !want.isEmpty, let s = screens.first(where: { $0.localizedName.uppercased().contains(want) }) { return s }
    let others = screens.filter { $0 != NSScreen.main }
    if let s = others.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) { return s }
    return NSScreen.main ?? screens[0]
}

// One board at a time (a login item and a manual launch can overlap).
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var screen = pickScreen()
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.setFrame(screen.frame, display: true)
win.appearance = NSAppearance(named: .darkAqua)
win.collectionBehavior = [.canJoinAllSpaces, .stationary]
win.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
let board = Board(frame: NSRect(origin: .zero, size: screen.frame.size))
win.contentView = board

// Show the board unless it was hidden. With one display it starts hidden; the menu bar item still works.
let showKey = "showBoard"
func boardVisible() -> Bool {
    UserDefaults.standard.object(forKey: showKey) as? Bool ?? (NSScreen.screens.count > 1)
}
func applyBoard() {
    let s = pickScreen()
    if s != screen || win.frame != s.frame {
        screen = s; win.setFrame(s.frame, display: true); board.frame = NSRect(origin: .zero, size: s.frame.size)
    }
    boardVisible() ? win.orderFrontRegardless() : win.orderOut(nil)
}

// MARK: - Menu bar item: countdown to the next meeting, and the app's menu.

final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    override init() {
        super.init()
        let img = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Meetboard")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        item.menu = menu
        board.menu = menu
        tick()
    }

    // "7m", "1h 20m"; orange under 10 minutes, red under 2. Nothing when the next meeting is over 12 hours away.
    func tick() {
        guard let b = item.button else { return }
        guard let n = board.next else { b.attributedTitle = NSAttributedString(string: ""); return }
        let secs = Int(n.start.timeIntervalSince(board.now))
        guard secs < 12 * 3600 else { b.attributedTitle = NSAttributedString(string: ""); return }
        let m = (secs + 59) / 60
        let s = m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]
        if secs <= 120 { attrs[.foregroundColor] = NSColor.systemRed } else if secs <= 600 { attrs[.foregroundColor] = NSColor.systemOrange }
        b.attributedTitle = NSAttributedString(string: " " + s, attributes: attrs)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"
        if let c = board.current { menu.addItem(info("Now: \(c.title), until \(tf.string(from: c.end))")) }
        if let n = board.next { menu.addItem(info("Next: \(n.title), \(tf.string(from: n.start))")) }
        if board.current == nil && board.next == nil { menu.addItem(info(board.status.isEmpty ? "No meetings" : board.status)) }
        if let t = board.joinTarget, t.join != nil {
            menu.addItem(action("Join \(t.title)", #selector(join), key: "j"))
        }
        menu.addItem(.separator())
        let show = action("Show Board", #selector(toggleBoard), key: "b"); show.state = boardVisible() ? .on : .off
        menu.addItem(show)
        let login = action("Open at Login", #selector(toggleLogin), key: ""); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Settings...", #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Meetboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func info(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    func action(_ s: String, _ sel: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self; return i
    }
    @objc func join() { if let u = board.joinTarget?.join { NSWorkspace.shared.open(u) } }
    @objc func toggleBoard() { UserDefaults.standard.set(!boardVisible(), forKey: showKey) }
    @objc func settings() { SettingsWindow.show() }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }
}

let menuBar = MenuBar()
applyBoard()

// Start at login once, when running from /Applications. Change it later from the menu or Settings.
let loginKey = "loginItemSetOnce"
if Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: loginKey) {
    if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(true, forKey: loginKey) }
}

// MARK: - Sources and timers

func needsLocation() -> Bool { Prefs.bool("weather") || Prefs.bool("prayer") || Prefs.bool("planes") }
func refreshSources() {
    if needsLocation() { Locator.shared.ensure() }
    weather.refresh()
    planes.refresh()
    board.reload()
}
Locator.shared.onChange = { refreshSources() }
weather.onChange = { board.needsDisplay = true }
planes.onChange = { board.needsDisplay = true }

if args.contains("--demo") {
    board.demoScene = "next"
    weather.now = Weather.Now(symbol: "cloud.sun.fill", temp: 4)
    board.reload()
} else {
    store.requestFullAccessToEvents { ok, _ in
        DispatchQueue.main.async {
            if ok { board.reload() } else { board.status = "Allow calendars: System Settings > Privacy > Calendars"; board.needsDisplay = true }
            menuBar.tick()
        }
    }
    NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in board.reload() }
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in board.reload() }
    Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in weather.refresh() }
    Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in planes.refresh() }
    refreshSources()
}

// Settings changed (Settings window, menu, or `defaults write`): apply on the next run loop pass.
var settingsPending = false
NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
    guard !settingsPending else { return }
    settingsPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settingsPending = false; applyBoard(); refreshSources() }
}

// On air: poll camera and mic every 2 seconds.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let s = OnAir.state()
    if s != board.onAir { board.onAir = s; board.needsDisplay = true }
}

// Chime a minute before, and Do Not Disturb while in a meeting (through two user Shortcuts).
var chimed = ""
var inMeeting = false
func runShortcut(_ name: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["run", name]
    try? p.run()
}
func everySecond() {
    menuBar.tick()
    if Prefs.bool("chime"), let n = board.next {
        let secs = n.start.timeIntervalSince(board.now), key = "\(n.title)|\(n.start)"
        if secs > 0, secs <= 60, chimed != key { chimed = key; NSSound(named: "Glass")?.play() }
    }
    let now = board.current != nil
    if now != inMeeting {
        inMeeting = now
        if Prefs.bool("dnd") { runShortcut(now ? "Meetboard Focus On" : "Meetboard Focus Off") }
    }
}

// Redraw once a second, or 30 times a second while a plane is crossing.
var frame = 0
Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    frame += 1
    let animating = board.planeVisible && win.isVisible
    if animating || frame % 30 == 0 { board.needsDisplay = true }
    if frame % 30 == 0 { everySecond() }
}
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    applyBoard()
}
app.run()
