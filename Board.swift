// The board: header (clock, weather, date or ON AIR, world clocks), nearby plane, current and next meeting, later list.
import AppKit

let bg = NSColor(srgbRed: 0.05, green: 0.055, blue: 0.075, alpha: 1)
let card = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.145, alpha: 1)
let dim = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.66, alpha: 1)
let soft = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.90, alpha: 1)
let green = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)
let sky = NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: 1)

// The layout is designed at 960x640 and scaled to fit any display.
let designW: CGFloat = 960, designH: CGFloat = 640
let planeLoop: Double = 9

func symbol(_ name: String, _ size: CGFloat, _ color: NSColor? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
    var cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    cfg = cfg.applying(color.map { .init(paletteColors: [$0]) } ?? .preferringMulticolor())
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}

final class Board: NSView {
    var meetings: [Meeting] = []      // calendar events (meetings and family)
    var prayers: [Meeting] = []
    var status = "Loading calendars..."
    var onAir: String? = nil          // "camera", "mic" or nil
    var demoScene: String? = nil
    var fixedNow: Date? = nil
    var fixedPlanePhase: Double? = nil
    var now: Date { fixedNow ?? Date() }
    override var isFlipped: Bool { true }

    func reload() {
        meetings = demoScene.map { demoMeetings(now: now, scene: $0) } ?? calendarMeetings(now: now)
        meetings.sort { $0.start < $1.start }
        prayers = Prayer.upcoming(now: now)
        status = meetings.isEmpty && prayers.isEmpty ? "No meetings in the next 36 hours" : ""
        needsDisplay = true
    }

    var current: Meeting? { meetings.first { $0.start <= now && $0.end > now } }
    var next: Meeting? { meetings.first { $0.start > now } }

    // The meeting a click joins: the next one if it starts within 10 minutes, else the current one.
    var joinTarget: Meeting? {
        let n = next, c = current
        return (n != nil && n!.start.timeIntervalSince(now) < 600) ? n : (c ?? n)
    }

    // End of the run of meetings that touch (under a minute apart), starting from the current or next one.
    var backToBackUntil: Date? {
        guard Prefs.bool("b2b"), let first = current ?? next else { return nil }
        var end = first.end, links = 0
        for m in meetings where m.start > first.start {
            if m.start.timeIntervalSince(end) < 60 { end = max(end, m.end); links += 1 } else if m.start > end { break }
        }
        return links > 0 ? end : nil
    }

    var planeVisible: Bool { Prefs.bool("planes") && (planes.nearest != nil) }

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
        let k = min(bounds.width / designW, bounds.height / designH)
        let t = NSAffineTransform()
        t.translateX(by: (bounds.width - designW * k) / 2, yBy: (bounds.height - designH * k) / 2)
        t.scale(by: k)
        t.concat()

        let now = self.now
        let W = designW, H = designH, pad: CGFloat = 32
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"
        let df = DateFormatter(); df.dateFormat = "EEEE, d MMMM"

        // Header: clock, weather, then the date or ON AIR.
        let tw = text(tf.string(from: now), pad, 20, size: 30, weight: .semibold, width: 300, mono: true)
        if Prefs.bool("weather"), let w = weather.now, let img = symbol(w.symbol, 24) {
            let x = pad + tw + 22
            img.draw(in: NSRect(x: x, y: 25, width: img.size.width, height: img.size.height))
            text("\(w.temp)°", x + img.size.width + 8, 24, size: 24, weight: .medium, color: soft, width: 120, mono: true)
        }
        if let air = onAir {
            NSColor.systemRed.setStroke()
            let br = NSBezierPath(rect: NSRect(x: 3, y: 3, width: W - 6, height: H - 6)); br.lineWidth = 6; br.stroke()
            let label = air == "camera" ? "ON AIR" : "MIC ON"
            let lw = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .heavy)]).width + 58
            rounded(NSRect(x: W - pad - lw, y: 22, width: lw, height: 34), 17, .systemRed)
            if let ic = symbol(air == "camera" ? "video.fill" : "mic.fill", 15, .white, weight: .bold) {
                ic.draw(in: NSRect(x: W - pad - lw + 14 + (20 - ic.size.width) / 2, y: 39 - ic.size.height / 2, width: ic.size.width, height: ic.size.height))
            }
            text(label, W - pad - lw + 40, 27, size: 17, weight: .heavy, color: .white, width: lw)
        } else {
            text(df.string(from: now), W - pad - 420, 27, size: 21, color: dim, width: 420, right: true)
        }

        var y: CGFloat = 80
        if Prefs.bool("clocks") {
            var cx = pad
            for (label, tz) in Clocks.parse(Prefs.string("zones"), now: now) {
                let f = DateFormatter(); f.dateFormat = "h:mm a"; f.timeZone = tz
                let lw = text(label, cx, 64, size: 15, weight: .semibold, color: dim, width: 140)
                let need = lw + 7 + (f.string(from: now) as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)]).width
                if cx + need > W - pad { break }
                cx += lw + 7
                cx += text(f.string(from: now), cx, 64, size: 15, color: soft, width: 120, mono: true) + 22
            }
            y = 98
        }
        if planeVisible, let p = planes.nearest {
            drawPlane(p, y: y + 6, pad: pad, W: W)
            y += 48
        }

        if !status.isEmpty {
            text(status, pad, max(y + 40, H / 2 - 20), size: 30, color: dim, width: W - 2 * pad)
            return
        }

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

        // Next meeting: the hero card. It gives up height to the clocks and plane rows.
        if let n = next {
            let secs = Int(n.start.timeIntervalSince(now))
            let big = current == nil
            let h: CGFloat = big ? max(270, 330 - (y - 80)) : 250
            let roomy = h >= 300
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

            let cy = y + (big ? (roomy ? 150 : 136) : 132)
            text(fmt(secs), pad + 22, cy, size: big ? (roomy ? 118 : 100) : 84, weight: .bold, color: cd, width: cardW - 44, mono: true)

            let frac = CGFloat(max(0, min(1, 1 - Double(secs) / 3600)))
            let by = y + h - 26
            rounded(NSRect(x: pad + 26, y: by, width: cardW - 52, height: 6), 3, .white.withAlphaComponent(0.08))
            rounded(NSRect(x: pad + 26, y: by, width: max(6, (cardW - 52) * frac), height: 6), 3, cd)
            y += h + 12
        } else {
            y += 6
        }

        if let until = backToBackUntil {
            if let ic = symbol("exclamationmark.triangle", 15, .systemOrange, weight: .semibold) {
                ic.draw(in: NSRect(x: pad + 6, y: y + 11 - ic.size.height / 2, width: ic.size.width, height: ic.size.height))
            }
            text("Back to back until \(tf.string(from: until)), no break", pad + 32, y, size: 17, weight: .semibold, color: .systemOrange, width: cardW - 32)
            y += 32
        } else {
            y += 6
        }

        // Later today and tomorrow, with prayer times mixed in.
        let after = next?.start ?? now
        let later = (meetings.filter { $0.start > after } + prayers.filter { $0.start > now }).sorted { $0.start < $1.start }
        let lf = DateFormatter(); lf.dateFormat = "EEE h:mm a"
        for e in later where y + 30 < H - 12 {
            let sym = e.kind == .prayer ? "moon.fill" : e.kind == .family ? "star.fill" : nil
            if let sym, let img = symbol(sym, 14, e.color, weight: .semibold) {
                img.draw(in: NSRect(x: pad + 9 - img.size.width / 2, y: y + 13 - img.size.height / 2, width: img.size.width, height: img.size.height))
            } else {
                rounded(NSRect(x: pad + 4, y: y + 8, width: 10, height: 10), 5, e.color)
            }
            let when = Calendar.current.isDate(e.start, inSameDayAs: now) ? tf.string(from: e.start) : lf.string(from: e.start)
            text(when, pad + 26, y, size: 20, color: dim, width: 160, mono: true)
            text(e.title, pad + 190, y, size: 20, color: e.kind == .meeting ? soft : e.color, width: W - pad * 2 - 190)
            y += 34
        }
    }

    // Slim line; the plane glides across with a trail and its details are revealed behind it. 9 second loop.
    func drawPlane(_ p: Plane, y ly: CGFloat, pad: CGFloat, W: CGFloat) {
        let t = fixedPlanePhase ?? Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: planeLoop) / planeLoop
        let x0 = pad, x1 = W - pad, span = x1 - x0
        func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
        let px = x0 + span * CGFloat(-0.08 + 1.16 * clamp(t / 0.95))
        let fade = t < 0.06 ? t / 0.06 : t > 0.88 ? max(0, 1 - (t - 0.88) / 0.07) : 1
        NSColor.white.withAlphaComponent(0.14).setFill(); NSRect(x: x0, y: ly, width: span, height: 1).fill()
        let tx = min(px, x1)
        if tx > x0 + 4 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: x0, y: ly - 1, width: tx - x0, height: 3), xRadius: 1.5, yRadius: 1.5).addClip()
            NSGradient(colors: [sky.withAlphaComponent(0), sky.withAlphaComponent(0.9 * fade)])!
                .draw(in: NSRect(x: x0, y: ly - 1, width: tx - x0, height: 3), angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let img = symbol("airplane", 20, sky.withAlphaComponent(fade), weight: .semibold) {
            img.draw(in: NSRect(x: px - img.size.width / 2, y: ly - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        let r = CGFloat(clamp((t - 0.28) / 0.60))
        let a = t < 0.28 ? 0 : t < 0.34 ? (t - 0.28) / 0.06 : fade
        guard r > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: x0, y: ly + 8, width: span * r, height: 26).clip()
        let s = NSMutableAttributedString(string: p.label, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .heavy),
                                                                         .foregroundColor: NSColor.white.withAlphaComponent(a)])
        if !p.detail.isEmpty {
            s.append(NSAttributedString(string: "  ·  " + p.detail, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular),
                                                                                 .foregroundColor: soft.withAlphaComponent(a * 0.85)]))
        }
        s.draw(at: NSPoint(x: x0, y: ly + 10))
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Demo data (for --demo and --snapshot)

func demoMeetings(now: Date, scene: String) -> [Meeting] {
    let cal = Calendar.current
    // Everything hangs off one start time 7m42s away, so a snapshot at 9:52:18 gives round clock times.
    let base = now.addingTimeInterval(7 * 60 + 42)
    func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
    let work = NSColor.systemBlue, side = NSColor.systemPurple, home = NSColor.systemGreen
    let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/demo")
    let zoom = URL(string: "https://zoom.us/j/0000000000")
    let full = scene.hasSuffix("+")
    var list: [Meeting] = []
    if scene.hasPrefix("now") {
        list.append(Meeting(title: "Design review: checkout flow", start: at(-30), end: at(30), location: nil, account: "Work", color: work, join: teams))
        list.append(Meeting(title: "Weekly sync with Acme Corp", start: at(30), end: at(60), location: "Room 4B", account: "Client", color: side, join: zoom))
    } else {
        list.append(Meeting(title: "Weekly sync with Acme Corp", start: at(0), end: at(30), location: "Room 4B", account: "Client", color: side, join: zoom))
    }
    let sp: Double = full ? (scene.hasPrefix("now") ? 60 : 30) : 90
    list.append(Meeting(title: "Sprint planning", start: at(sp), end: at(sp + 60), location: nil, account: "Work", color: work, join: teams))
    list.append(Meeting(title: "1:1 with Sam", start: at(180), end: at(210), location: nil, account: "Work", color: work, join: teams))
    if full {
        list.append(Meeting(title: "School pickup", start: at(315), end: at(345), location: nil, account: "Family", color: familyColor, join: nil, kind: .family))
    } else {
        list.append(Meeting(title: "Dentist", start: at(300), end: at(345), location: "Main St Dental", account: "Personal", color: home, join: nil))
    }
    let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
    list.append(Meeting(title: "Architecture office hours", start: tomorrow.addingTimeInterval(9.5 * 3600),
                        end: tomorrow.addingTimeInterval(10.5 * 3600), location: nil, account: "Work", color: work, join: teams))
    list.append(Meeting(title: "Quarterly roadmap", start: tomorrow.addingTimeInterval(13 * 3600),
                        end: tomorrow.addingTimeInterval(14 * 3600), location: nil, account: "Work", color: work, join: teams))
    return list
}
