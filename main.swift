// Meetboard: your next meeting and a live countdown on a spare display.
// Reads macOS Calendar (EventKit), so any account added in Internet Accounts shows up
// (iCloud, Google, Exchange / Microsoft 365, CalDAV, ICS subscriptions).
// Click the screen to join the next meeting's Teams / Zoom / Meet / Webex link.
// Menu bar item: countdown, join, show or hide the board, open at login, quit (same menu on right-click).
//
// Flags:
//   --demo                       show sample meetings instead of your calendar
//   --snapshot out.png [--scene next|now] [--size 960x640]
//                                render the demo board to a PNG and exit
import AppKit
import EventKit
import ServiceManagement
import CoreLocation

let store = EKEventStore()
let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - Model

struct Meeting {
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var account: String
    var color: NSColor
    var join: URL?
}

func joinURL(_ text: String) -> URL? {
    let pattern = #"https://[^\s<>"]*(teams\.microsoft\.com|teams\.live\.com|zoom\.us|meet\.google\.com|webex\.com)[^\s<>"]*"#
    guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
    return URL(string: String(text[r]))
}

func calendarMeetings(now: Date) -> [Meeting] {
    let end = Calendar.current.date(byAdding: .hour, value: 36, to: now)!
    let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600), end: end, calendars: nil)
    return store.events(matching: pred)
        .filter { e in
            !e.isAllDay && e.endDate > now && e.status != .canceled
                && e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
        }
        .sorted { $0.startDate < $1.startDate }
        .map { e in
            let hay = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
            return Meeting(title: e.title ?? "(no title)", start: e.startDate, end: e.endDate, location: e.location,
                           account: e.calendar?.source?.title ?? "Calendar",
                           color: e.calendar?.color ?? .systemBlue, join: joinURL(hay))
        }
}

func demoMeetings(now: Date, scene: String) -> [Meeting] {
    let cal = Calendar.current
    // Everything hangs off one start time 7m42s away, so a snapshot at 9:52:18 gives round clock times.
    let base = now.addingTimeInterval(7 * 60 + 42)
    func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
    let work = NSColor.systemBlue, side = NSColor.systemPurple, home = NSColor.systemGreen
    let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/demo")
    let zoom = URL(string: "https://zoom.us/j/0000000000")
    var list: [Meeting] = []
    if scene == "now" {
        list.append(Meeting(title: "Design review: checkout flow", start: at(-30), end: at(30), location: nil,
                            account: "Work", color: work, join: teams))
        list.append(Meeting(title: "Weekly sync with Acme Corp", start: at(30), end: at(60), location: "Room 4B",
                            account: "Client", color: side, join: zoom))
    } else {
        list.append(Meeting(title: "Weekly sync with Acme Corp", start: at(0), end: at(30), location: "Room 4B",
                            account: "Client", color: side, join: zoom))
    }
    list.append(Meeting(title: "Sprint planning", start: at(90), end: at(150), location: nil, account: "Work", color: work, join: teams))
    list.append(Meeting(title: "1:1 with Sam", start: at(180), end: at(210), location: nil, account: "Work", color: work, join: teams))
    list.append(Meeting(title: "Dentist", start: at(300), end: at(345), location: "Main St Dental", account: "Personal", color: home, join: nil))
    let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
    list.append(Meeting(title: "Architecture office hours", start: tomorrow.addingTimeInterval(9.5 * 3600),
                        end: tomorrow.addingTimeInterval(10.5 * 3600), location: nil, account: "Work", color: work, join: teams))
    list.append(Meeting(title: "Quarterly roadmap", start: tomorrow.addingTimeInterval(13 * 3600),
                        end: tomorrow.addingTimeInterval(14 * 3600), location: nil, account: "Work", color: work, join: teams))
    return list
}

// MARK: - Drawing

let bg = NSColor(srgbRed: 0.05, green: 0.055, blue: 0.075, alpha: 1)
let card = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.145, alpha: 1)
let dim = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.66, alpha: 1)
let soft = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.90, alpha: 1)
let green = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)

// MARK: - Weather (Open-Meteo: free, no key). Location from `defaults write com.otbic.meetboard location "43.65,-79.38"`,
// else Location Services, rounded to about 1 km before it is sent. No location, no weather; the board works without it.

final class Weather: NSObject, CLLocationManagerDelegate {
    struct Now { var symbol: String; var temp: Int }
    var now: Now?
    var onChange: () -> Void = {}
    private let lm = CLLocationManager()
    private var coord: (Double, Double)?

    func start() {
        if let s = UserDefaults.standard.string(forKey: "location") {
            let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 2 { coord = (p[0], p[1]) }
        }
        if coord == nil {
            lm.delegate = self
            lm.desiredAccuracy = kCLLocationAccuracyKilometer
            lm.requestWhenInUseAuthorization()
            lm.requestLocation()
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        coord = (c.latitude, c.longitude); refresh()
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways || m.authorizationStatus == .authorized { m.requestLocation() }
    }

    func refresh() {
        guard let (lat, lon) = coord else { return }
        let unit = Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius"
        let url = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&current=temperature_2m,weather_code,is_day&temperature_unit=%@", lat, lon, unit))!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = j["current"] as? [String: Any],
                  let t = cur["temperature_2m"] as? Double, let code = cur["weather_code"] as? Int else { return }
            let day = (cur["is_day"] as? Int ?? 1) == 1
            DispatchQueue.main.async { self?.now = Now(symbol: weatherSymbol(code, day: day), temp: Int(t.rounded())); self?.onChange() }
        }.resume()
    }
}

// WMO weather codes to SF Symbols.
func weatherSymbol(_ code: Int, day: Bool) -> String {
    switch code {
    case 0: return day ? "sun.max.fill" : "moon.stars.fill"
    case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
    case 3: return "cloud.fill"
    case 45, 48: return "cloud.fog.fill"
    case 51...57: return "cloud.drizzle.fill"
    case 65, 82: return "cloud.heavyrain.fill"
    case 61...67, 80, 81: return "cloud.rain.fill"
    case 71...77, 85, 86: return "cloud.snow.fill"
    case 95...99: return "cloud.bolt.rain.fill"
    default: return "cloud.fill"
    }
}

func weatherImage(_ name: String, size: CGFloat) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.preferringMulticolor())
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}

let weather = Weather()

// The layout is designed at 960x640 and scaled to fit any display.
let designW: CGFloat = 960, designH: CGFloat = 640

final class Board: NSView {
    var meetings: [Meeting] = []
    var status = "Loading calendars..."
    var demoScene: String? = nil
    var fixedNow: Date? = nil
    var now: Date { fixedNow ?? Date() }
    override var isFlipped: Bool { true }

    func reload() {
        meetings = demoScene.map { demoMeetings(now: now, scene: $0) } ?? calendarMeetings(now: now)
        status = meetings.isEmpty ? "No meetings in the next 36 hours" : ""
        needsDisplay = true
    }

    var current: Meeting? { meetings.first { $0.start <= now && $0.end > now } }
    var next: Meeting? { meetings.first { $0.start > now } }

    // The meeting a click joins: the next one if it starts within 10 minutes, else the current one.
    var joinTarget: Meeting? {
        let n = next, c = current
        return (n != nil && n!.start.timeIntervalSince(now) < 600) ? n : (c ?? n)
    }

    override func mouseDown(with event: NSEvent) {
        if let u = joinTarget?.join { NSWorkspace.shared.open(u) }
    }

    func fmt(_ secs: Int) -> String {
        let s = max(0, secs)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    @discardableResult
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
              color: NSColor = .white, width: CGFloat = 900, mono: Bool = false, right: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = right ? .right : .left
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        (s as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size * 1.3), withAttributes: attrs)
        return min(width, (s as NSString).size(withAttributes: attrs).width)
    }

    func rounded(_ r: NSRect, _ radius: CGFloat, _ c: NSColor) {
        c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    func pill(_ s: String, _ x: CGFloat, _ y: CGFloat, _ c: NSColor) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let w = (s as NSString).size(withAttributes: [.font: font]).width + 20
        rounded(NSRect(x: x, y: y, width: w, height: 26), 13, c.withAlphaComponent(0.2))
        text(s, x + 10, y + 3, size: 15, weight: .bold, color: c, width: w)
        return w
    }

    override func draw(_ dirtyRect: NSRect) {
        bg.setFill(); bounds.fill()
        // Scale the 960x640 design to fit, centred.
        let k = min(bounds.width / designW, bounds.height / designH)
        let t = NSAffineTransform()
        t.translateX(by: (bounds.width - designW * k) / 2, yBy: (bounds.height - designH * k) / 2)
        t.scale(by: k)
        t.concat()

        let now = self.now
        let W = designW, H = designH, pad: CGFloat = 32
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"
        let df = DateFormatter(); df.dateFormat = "EEEE, d MMMM"

        let tw = text(tf.string(from: now), pad, 20, size: 30, weight: .semibold, width: 300, mono: true)
        text(df.string(from: now), W - pad - 420, 27, size: 21, color: dim, width: 420, right: true)
        if let w = weather.now, let img = weatherImage(w.symbol, size: 24) {
            let x = pad + tw + 22
            img.draw(in: NSRect(x: x, y: 25, width: img.size.width, height: img.size.height))
            text("\(w.temp)°", x + img.size.width + 8, 24, size: 24, weight: .medium, color: soft, width: 120, mono: true)
        }

        if !status.isEmpty {
            text(status, pad, H / 2 - 20, size: 30, color: dim, width: W - 2 * pad)
            return
        }

        var y: CGFloat = 80
        let cardW = W - 2 * pad

        // In a meeting now: compact red strip.
        if let c = current {
            let total = c.end.timeIntervalSince(c.start), left = c.end.timeIntervalSince(now)
            rounded(NSRect(x: pad, y: y, width: cardW, height: 84), 18, card)
            rounded(NSRect(x: pad, y: y, width: 6, height: 84), 3, .systemRed)
            let pw = pill("NOW", pad + 22, y + 14, .systemRed)
            text("ends in \(fmt(Int(left)))", pad + 30 + pw, y + 15, size: 19, weight: .semibold, color: .systemRed, width: 260, mono: true)
            text(c.title, pad + 22, y + 46, size: 26, weight: .semibold, width: cardW - 44)
            let frac = CGFloat(max(0, min(1, 1 - left / max(total, 1))))
            rounded(NSRect(x: pad + 22, y: y + 78, width: cardW - 44, height: 3), 1.5, .white.withAlphaComponent(0.08))
            rounded(NSRect(x: pad + 22, y: y + 78, width: (cardW - 44) * frac, height: 3), 1.5, .systemRed)
            y += 100
        }

        // Next meeting: the hero card.
        if let n = next {
            let secs = Int(n.start.timeIntervalSince(now))
            let big = current == nil
            let h: CGFloat = big ? 330 : 250
            let cd: NSColor = secs <= 120 ? .systemRed : secs <= 600 ? .systemOrange : green
            rounded(NSRect(x: pad, y: y, width: cardW, height: h), 22, card)
            rounded(NSRect(x: pad, y: y, width: 6, height: h), 3, n.color)

            var px = pad + 26
            px += pill("NEXT", px, y + 20, dim) + 8
            px += pill(n.account.uppercased(), px, y + 20, n.color) + 8
            if n.join != nil { _ = pill("TAP TO JOIN", px, y + 20, .systemBlue) }

            text(n.title, pad + 26, y + 58, size: big ? 40 : 32, weight: .bold, width: cardW - 52)
            let place = n.location.map { $0.isEmpty || $0.hasPrefix("http") ? "" : "  ·  \($0)" } ?? ""
            text("\(tf.string(from: n.start)) to \(tf.string(from: n.end))" + place,
                 pad + 26, y + (big ? 112 : 100), size: 21, color: soft, width: cardW - 52)

            let cy = y + (big ? 150 : 132)
            text(fmt(secs), pad + 22, cy, size: big ? 118 : 84, weight: .bold, color: cd, width: cardW - 44, mono: true)

            // Fills over the last hour before the start.
            let frac = CGFloat(max(0, min(1, 1 - Double(secs) / 3600)))
            let by = y + h - 26
            rounded(NSRect(x: pad + 26, y: by, width: cardW - 52, height: 6), 3, .white.withAlphaComponent(0.08))
            rounded(NSRect(x: pad + 26, y: by, width: max(6, (cardW - 52) * frac), height: 6), 3, cd)
            y += h + 18
        }

        // Later today and tomorrow.
        let later = meetings.filter { $0.start > (next?.start ?? now) }
        let lf = DateFormatter(); lf.dateFormat = "EEE h:mm a"
        for e in later where y + 30 < H - 12 {
            rounded(NSRect(x: pad + 4, y: y + 8, width: 10, height: 10), 5, e.color)
            let when = Calendar.current.isDate(e.start, inSameDayAs: now) ? tf.string(from: e.start) : lf.string(from: e.start)
            text(when, pad + 26, y, size: 20, color: dim, width: 160, mono: true)
            text(e.title, pad + 190, y, size: 20, color: soft, width: W - pad * 2 - 190)
            y += 34
        }
    }
}

// MARK: - Snapshot mode (renders the demo board to a PNG, no window, no calendar access)

if let out = arg("--snapshot") {
    let size = (arg("--size") ?? "960x640").split(separator: "x").compactMap { Double($0) }
    let w = CGFloat(size.count == 2 ? size[0] : 960), h = CGFloat(size.count == 2 ? size[1] : 640)
    let board = Board(frame: NSRect(x: 0, y: 0, width: w, height: h))
    // A fixed weekday morning so the screenshot is the same every time.
    board.fixedNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 52, second: 18))
    board.demoScene = arg("--scene") ?? "next"
    weather.now = Weather.Now(symbol: "cloud.sun.fill", temp: 4)
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

// Which display: `defaults write com.otbic.meetboard screen "HDMI"` picks the display whose name contains
// that text. Otherwise the smallest display that is not the main one; with one display, the main one.
func pickScreen() -> NSScreen {
    let screens = NSScreen.screens
    if let want = UserDefaults.standard.string(forKey: "screen")?.uppercased(), !want.isEmpty,
       let s = screens.first(where: { $0.localizedName.uppercased().contains(want) }) { return s }
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

// Show the board unless it was hidden from the menu. With one display it starts hidden; the menu bar item still works.
let showKey = "showBoard"
func boardVisible() -> Bool {
    UserDefaults.standard.object(forKey: showKey) as? Bool ?? (NSScreen.screens.count > 1)
}
func applyBoardVisibility() { boardVisible() ? win.orderFrontRegardless() : win.orderOut(nil) }

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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Meetboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func info(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    func action(_ s: String, _ sel: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self; return i
    }
    @objc func join() { if let u = board.joinTarget?.join { NSWorkspace.shared.open(u) } }
    @objc func toggleBoard() { UserDefaults.standard.set(!boardVisible(), forKey: showKey); applyBoardVisibility() }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }
}

let menuBar = MenuBar()
applyBoardVisibility()

// Start at login once, when running from /Applications. Change it later from the menu bar item.
let loginKey = "loginItemSetOnce"
if Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: loginKey) {
    if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(true, forKey: loginKey) }
}

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
    weather.onChange = { board.needsDisplay = true }
    weather.start()
}
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in board.needsDisplay = true; menuBar.tick() }
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    screen = pickScreen(); win.setFrame(screen.frame, display: true); board.frame = NSRect(origin: .zero, size: screen.frame.size)
    applyBoardVisibility()
}
app.run()
