// Data sources: settings, calendar, location, weather, nearby planes, prayer times, camera / mic in use.
import AppKit
import EventKit
import CoreLocation
import CoreMediaIO
import CoreAudio

// MARK: - Settings (UserDefaults, domain com.otbic.meetboard). The Settings window writes the same keys.

enum Prefs {
    static let defaults: [String: Any] = [
        "weather": true, "units": "auto", "location": "",
        "clocks": false, "zones": "EST, CST, MST, PST, PK, IN", "seasonalLabels": true,
        "onAir": true, "onAirMic": false, "b2b": true, "chime": false, "dnd": false,
        "prayer": false, "prayerMethod": "isna", "asrHanafi": false,
        "family": false, "familyCalendar": "",
        "planes": false, "planeRadius": 5,
    ]
    // Used by --snapshot so screenshots never depend on the machine's own settings.
    static var overrides: [String: Any] = [:]
    static func register() { UserDefaults.standard.register(defaults: defaults) }
    static func bool(_ k: String) -> Bool { overrides[k] as? Bool ?? UserDefaults.standard.bool(forKey: k) }
    static func string(_ k: String) -> String { overrides[k] as? String ?? UserDefaults.standard.string(forKey: k) ?? "" }
    static func int(_ k: String) -> Int { overrides[k] as? Int ?? UserDefaults.standard.integer(forKey: k) }
}

// MARK: - Model

struct Meeting {
    enum Kind { case meeting, family, prayer }
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var account: String
    var color: NSColor
    var join: URL?
    var kind: Kind = .meeting
}

let store = EKEventStore()
let familyColor = NSColor.systemYellow
let prayerColor = NSColor(srgbRed: 0.35, green: 0.78, blue: 0.80, alpha: 1)

func joinURL(_ text: String) -> URL? {
    let pattern = #"https://[^\s<>"]*(teams\.microsoft\.com|teams\.live\.com|zoom\.us|meet\.google\.com|webex\.com)[^\s<>"]*"#
    guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
    return URL(string: String(text[r]))
}

func calendarMeetings(now: Date) -> [Meeting] {
    let end = Calendar.current.date(byAdding: .hour, value: 36, to: now)!
    let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600), end: end, calendars: nil)
    let family = Prefs.bool("family") ? Prefs.string("familyCalendar").lowercased() : ""
    return store.events(matching: pred)
        .filter { e in
            !e.isAllDay && e.endDate > now && e.status != .canceled
                && e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
        }
        .map { e in
            let hay = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
            let isFamily = !family.isEmpty && (e.calendar?.title.lowercased() ?? "") == family
            return Meeting(title: e.title ?? "(no title)", start: e.startDate, end: e.endDate, location: e.location,
                           account: e.calendar?.source?.title ?? "Calendar",
                           color: isFamily ? familyColor : (e.calendar?.color ?? .systemBlue), join: joinURL(hay),
                           kind: isFamily ? .family : .meeting)
        }
}

func calendarNames() -> [String] {
    Array(Set(store.calendars(for: .event).map(\.title))).sorted()
}

// MARK: - Location: typed "lat,lon" in Settings, else Location Services. Rounded to 2 decimals (about 1 km) before use.

final class Locator: NSObject, CLLocationManagerDelegate {
    static let shared = Locator()
    private let lm = CLLocationManager()
    private var gps: CLLocationCoordinate2D?
    private var asked = false
    var onChange: () -> Void = {}

    var coord: (lat: Double, lon: Double)? {
        let p = Prefs.string("location").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if p.count == 2 { return (p[0], p[1]) }
        guard let g = gps else { return nil }
        return ((g.latitude * 100).rounded() / 100, (g.longitude * 100).rounded() / 100)
    }

    // Asks for location only when a feature that needs it is on and no location was typed.
    func ensure() {
        guard Prefs.string("location").isEmpty, !asked else { return }
        asked = true
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyKilometer
        lm.requestWhenInUseAuthorization()
        lm.requestLocation()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.lm.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        let moved = gps.map { abs($0.latitude - c.latitude) > 0.01 || abs($0.longitude - c.longitude) > 0.01 } ?? true
        gps = c
        if moved { onChange() }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways { m.requestLocation() }
    }
}

// MARK: - Weather (Open-Meteo: free, no key)

final class Weather {
    struct Now { var symbol: String; var temp: Int }
    var now: Now?
    var onChange: () -> Void = {}

    func refresh() {
        guard Prefs.bool("weather"), let c = Locator.shared.coord else { return }
        let u = Prefs.string("units")
        let f = u == "f" || (u != "c" && Locale.current.measurementSystem == .us)
        let url = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&current=temperature_2m,weather_code,is_day&temperature_unit=%@",
                                     c.lat, c.lon, f ? "fahrenheit" : "celsius"))!
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

let weather = Weather()

// MARK: - Nearby planes (api.adsb.lol: free, no key). The closest airborne aircraft within the radius.

struct Plane { var label: String; var detail: String }

final class Planes {
    var nearest: Plane?
    var onChange: () -> Void = {}

    static let airlines = [
        "ACA": "Air Canada", "JZA": "Jazz", "ROU": "Air Canada Rouge", "WJA": "WestJet", "TSC": "Air Transat",
        "POE": "Porter", "FLE": "Flair", "SWG": "Sunwing", "CJT": "Cargojet",
        "DAL": "Delta", "AAL": "American", "UAL": "United", "SWA": "Southwest", "JBU": "JetBlue", "ASA": "Alaska",
        "NKS": "Spirit", "FFT": "Frontier", "SKW": "SkyWest", "RPA": "Republic", "ENY": "Envoy", "EDV": "Endeavor",
        "JIA": "PSA", "GJS": "GoJet", "FDX": "FedEx", "UPS": "UPS",
        "BAW": "British Airways", "VIR": "Virgin Atlantic", "DLH": "Lufthansa", "AFR": "Air France", "KLM": "KLM",
        "IBE": "Iberia", "AZA": "ITA", "SWR": "Swiss", "THY": "Turkish", "UAE": "Emirates", "QTR": "Qatar",
        "ETD": "Etihad", "SVA": "Saudia", "PIA": "PIA", "AIC": "Air India", "EVA": "EVA Air", "CPA": "Cathay",
        "JAL": "JAL", "ANA": "ANA", "KAL": "Korean Air", "QFA": "Qantas", "EIN": "Aer Lingus", "ICE": "Icelandair",
    ]
    static let types = [
        "B738": "Boeing 737-800", "B737": "Boeing 737-700", "B38M": "Boeing 737 MAX 8", "B39M": "Boeing 737 MAX 9",
        "B739": "Boeing 737-900", "B752": "Boeing 757", "B763": "Boeing 767", "B772": "Boeing 777", "B77W": "Boeing 777",
        "B788": "Boeing 787-8", "B789": "Boeing 787-9", "B78X": "Boeing 787-10", "B744": "Boeing 747", "B748": "Boeing 747-8",
        "A319": "Airbus A319", "A320": "Airbus A320", "A321": "Airbus A321", "A20N": "Airbus A320neo", "A21N": "Airbus A321neo",
        "BCS1": "Airbus A220-100", "BCS3": "Airbus A220-300", "A332": "Airbus A330", "A333": "Airbus A330",
        "A339": "Airbus A330neo", "A359": "Airbus A350", "A35K": "Airbus A350-1000", "A388": "Airbus A380",
        "E75L": "Embraer 175", "E75S": "Embraer 175", "E190": "Embraer 190", "E195": "Embraer 195", "E295": "Embraer E195-E2",
        "CRJ2": "CRJ-200", "CRJ7": "CRJ-700", "CRJ9": "CRJ-900", "DH8D": "Dash 8-400", "DH8C": "Dash 8-300",
        "AT76": "ATR 72", "C172": "Cessna 172", "PC12": "Pilatus PC-12",
        "GLF4": "Gulfstream IV", "GLF5": "Gulfstream V", "GLF6": "Gulfstream G650", "GL5T": "Global 5000", "GLEX": "Global Express",
        "GL7T": "Global 7500", "CL30": "Challenger 300", "CL35": "Challenger 350", "CL60": "Challenger 600", "C68A": "Citation Latitude",
        "C680": "Citation Sovereign", "C560": "Citation V", "C25A": "Citation CJ2", "C25B": "Citation CJ3", "E55P": "Phenom 300",
        "E545": "Praetor 500", "LJ45": "Learjet 45", "F2TH": "Falcon 2000", "FA7X": "Falcon 7X", "PC24": "Pilatus PC-24",
    ]

    func refresh() {
        guard Prefs.bool("planes"), let c = Locator.shared.coord else { if nearest != nil { nearest = nil; onChange() }; return }
        let r = max(1, min(50, Prefs.int("planeRadius")))
        let url = URL(string: String(format: "https://api.adsb.lol/v2/point/%.2f/%.2f/%d", c.lat, c.lon, r))!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            var found: Plane?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = j["ac"] as? [[String: Any]] {
                let airborne = list.filter { $0["alt_baro"] is NSNumber && $0["dst"] is NSNumber }
                if let a = airborne.min(by: { ($0["dst"] as! NSNumber).doubleValue < ($1["dst"] as! NSNumber).doubleValue }) {
                    found = Planes.describe(a)
                }
            }
            DispatchQueue.main.async { self?.nearest = found; self?.onChange() }
        }.resume()
    }

    static func describe(_ a: [String: Any]) -> Plane {
        let callsign = (a["flight"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var label = callsign.isEmpty ? (a["r"] as? String ?? "Aircraft") : callsign
        if callsign.count > 3, let airline = airlines[String(callsign.prefix(3))] {
            let num = callsign.dropFirst(3).drop(while: { $0 == "0" })
            label = "\(airline) \(num.isEmpty ? callsign.dropFirst(3) : num)"
        }
        var parts: [String] = []
        if let t = a["t"] as? String, !t.isEmpty { parts.append(types[t] ?? t) }
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        if let alt = (a["alt_baro"] as? NSNumber)?.intValue { parts.append("\(nf.string(from: alt as NSNumber) ?? "\(alt)") ft") }
        if let gs = (a["gs"] as? NSNumber)?.doubleValue { parts.append("\(Int(gs.rounded())) kt") }
        var away = ""
        if let d = (a["dst"] as? NSNumber)?.doubleValue { away = String(format: "%.1f nm away", d) }
        if let tr = (a["track"] as? NSNumber)?.doubleValue {
            let dirs = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
            away += (away.isEmpty ? "heading " : ", heading ") + dirs[Int((tr + 22.5).truncatingRemainder(dividingBy: 360) / 45) % 8]
        }
        if !away.isEmpty { parts.append(away) }
        return Plane(label: label, detail: parts.joined(separator: "  ·  "))
    }
}

let planes = Planes()

// MARK: - Prayer times, calculated on the Mac (standard PrayTimes method; checked against aladhan.com for Toronto).

enum Prayer {
    // Fajr angle, Isha angle (nil = 90 minutes after Maghrib).
    static let methods: [String: (name: String, fajr: Double, isha: Double?)] = [
        "isna": ("ISNA (North America)", 15, 15),
        "mwl": ("Muslim World League", 18, 17),
        "karachi": ("Karachi", 18, 18),
        "egypt": ("Egyptian", 19.5, 17.5),
        "makkah": ("Umm al-Qura (Makkah)", 18.5, nil),
    ]

    static func times(on day: Date, lat: Double, lon: Double) -> [(String, Date)] {
        let m = methods[Prefs.string("prayerMethod")] ?? methods["isna"]!
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: day)
        let start = cal.startOfDay(for: day)
        let tz = Double(TimeZone.current.secondsFromGMT(for: start.addingTimeInterval(12 * 3600))) / 3600
        let rad = Double.pi / 180
        func dsin(_ d: Double) -> Double { sin(d * rad) }
        func dcos(_ d: Double) -> Double { cos(d * rad) }
        func fix(_ a: Double, _ b: Double) -> Double { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }

        var y = Double(c.year!), mo = Double(c.month!)
        if mo <= 2 { y -= 1; mo += 12 }
        let A = floor(y / 100), B = 2 - A + floor(A / 4)
        let jd = floor(365.25 * (y + 4716)) + floor(30.6001 * (mo + 1)) + Double(c.day!) + B - 1524.5 - lon / 360 + 0.5

        // Sun declination and equation of time at a given local hour of the day.
        func sun(_ hour: Double) -> (decl: Double, eqt: Double) {
            let D = jd + (hour - 12) / 24 - 2451545.0
            let g = fix(357.529 + 0.98560028 * D, 360), q = fix(280.459 + 0.98564736 * D, 360)
            let L = fix(q + 1.915 * dsin(g) + 0.020 * dsin(2 * g), 360)
            let e = 23.439 - 0.00000036 * D
            let ra = fix(atan2(dcos(e) * dsin(L), dcos(L)) / rad / 15, 24)
            return (asin(dsin(e) * dsin(L)) / rad, q / 15 - ra)
        }
        func noon(_ hour: Double) -> Double { 12 + tz - lon / 15 - sun(hour).eqt }
        // Time when the sun is at altitude `alt` (negative = below the horizon), before or after noon.
        // Two passes: estimate, then recompute the sun's position at that estimate.
        func at(_ alt: (Double) -> Double, before: Bool, guess: Double) -> Double? {
            var h = guess
            for _ in 0..<2 {
                let s = sun(h)
                let v = (dsin(alt(s.decl)) - dsin(s.decl) * dsin(lat)) / (dcos(s.decl) * dcos(lat))
                guard abs(v) <= 1 else { return nil }
                let d = acos(v) / rad / 15
                h = before ? noon(h) - d : noon(h) + d
            }
            return h
        }
        let dhuhr = noon(12)
        let f = Prefs.bool("asrHanafi") ? 2.0 : 1.0
        var out: [(String, Double?)] = []
        out.append(("Fajr", at({ _ in -m.fajr }, before: true, guess: 5)))
        out.append((cal.component(.weekday, from: day) == 6 ? "Jumu'ah" : "Dhuhr", dhuhr))
        out.append(("Asr", at({ d in atan(1 / (f + tan(abs(lat - d) * rad))) / rad }, before: false, guess: 15)))
        let maghrib = at({ _ in -0.833 }, before: false, guess: 18)
        out.append(("Maghrib", maghrib))
        out.append(("Isha", m.isha.map { a in at({ _ in -a }, before: false, guess: 19) } ?? maghrib.map { $0 + 1.5 }))
        // Rounded up to the minute, so a time is never shown early.
        return out.compactMap { n, h in h.map { (n, start.addingTimeInterval((($0 * 60).rounded(.up)) * 60)) } }
    }

    static func upcoming(now: Date) -> [Meeting] {
        guard Prefs.bool("prayer"), let c = Locator.shared.coord else { return [] }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        return (times(on: now, lat: c.lat, lon: c.lon) + times(on: tomorrow, lat: c.lat, lon: c.lon))
            .filter { $0.1 > now }
            .map { Meeting(title: $0.0, start: $0.1, end: $0.1.addingTimeInterval(60), location: nil, account: "",
                           color: prayerColor, join: nil, kind: .prayer) }
    }
}

// MARK: - On air: is any camera, or optionally any microphone, in use by any app?

enum OnAir {
    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var ids = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == 0 else { return false }
        for id in ids {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(id, &a, 0, nil, s, &s, &running) == 0, running != 0 { return true }
        }
        return false
    }

    static func micInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == 0 else { return false }
        for id in ids {
            var inAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                    mElement: kAudioObjectPropertyElementMain)
            var sz: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &sz) == 0, sz > 0 else { continue }
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == 0, running != 0 { return true }
        }
        return false
    }

    // "camera", "mic" or nil.
    static func state() -> String? {
        guard Prefs.bool("onAir") else { return nil }
        if cameraInUse() { return "camera" }
        if Prefs.bool("onAirMic"), micInUse() { return "mic" }
        return nil
    }
}

// MARK: - World clocks

enum Clocks {
    static let known: [String: String] = [
        "EST": "America/New_York", "EDT": "America/New_York", "ET": "America/New_York",
        "CST": "America/Chicago", "CDT": "America/Chicago", "CT": "America/Chicago",
        "MST": "America/Denver", "MDT": "America/Denver", "MT": "America/Denver", "AZ": "America/Phoenix",
        "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles", "PT": "America/Los_Angeles",
        "AKST": "America/Anchorage", "HST": "Pacific/Honolulu", "AST": "America/Halifax", "NST": "America/St_Johns",
        "UTC": "UTC", "GMT": "Europe/London", "UK": "Europe/London", "CET": "Europe/Paris", "EET": "Europe/Athens",
        "PK": "Asia/Karachi", "PKT": "Asia/Karachi", "IN": "Asia/Kolkata", "IST": "Asia/Kolkata",
        "AE": "Asia/Dubai", "UAE": "Asia/Dubai", "SA": "Asia/Riyadh", "KSA": "Asia/Riyadh", "BD": "Asia/Dhaka",
        "SG": "Asia/Singapore", "PH": "Asia/Manila", "CN": "Asia/Shanghai", "JP": "Asia/Tokyo",
        "AU": "Australia/Sydney", "AEST": "Australia/Sydney", "NZ": "Pacific/Auckland",
    ]
    static let seasonal: Set<String> = ["EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT", "AKST", "AST"]

    // "EST, CST, PK" or "Carvana=America/Phoenix". Returns (label, zone).
    static func parse(_ s: String, now: Date) -> [(String, TimeZone)] {
        s.split(separator: ",").compactMap { raw in
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let label = parts[0]
            let id = parts.count == 2 ? parts[1] : (known[label.uppercased()] ?? label)
            guard let tz = TimeZone(identifier: id) else { return nil }
            if parts.count == 1, Prefs.bool("seasonalLabels"), seasonal.contains(label.uppercased()) {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.timeZone = tz; f.dateFormat = "zzz"
                let abbr = f.string(from: now)
                if abbr.allSatisfy(\.isLetter) { return (abbr, tz) }
            }
            return (label, tz)
        }
    }
}
