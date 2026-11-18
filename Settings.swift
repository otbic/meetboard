// Settings window (menu bar icon > Settings..., or Cmd-,). Every control writes the same UserDefaults keys the board reads.
import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @AppStorage("showBoard") var showBoard = NSScreen.screens.count > 1
    @AppStorage("screen") var screen = ""
    @State var login = SMAppService.mainApp.status == .enabled

    @AppStorage("weather") var weather = true
    @AppStorage("units") var units = "auto"
    @AppStorage("location") var location = ""
    @AppStorage("clocks") var clocks = false
    @AppStorage("zones") var zones = "EST, CST, MST, PST, PK, IN"
    @AppStorage("seasonalLabels") var seasonal = true

    @AppStorage("onAir") var onAir = true
    @AppStorage("onAirMic") var onAirMic = false
    @AppStorage("b2b") var b2b = true
    @AppStorage("chime") var chime = false
    @AppStorage("dnd") var dnd = false

    @AppStorage("prayer") var prayer = false
    @AppStorage("prayerMethod") var method = "isna"
    @AppStorage("asrHanafi") var hanafi = false
    @AppStorage("family") var family = false
    @AppStorage("familyCalendar") var familyCal = ""
    @AppStorage("planes") var planesOn = false
    @AppStorage("planeRadius") var radius = 5

    let screens = NSScreen.screens.map(\.localizedName)
    let calendars = calendarNames()

    var body: some View {
        Form {
            Section("Board") {
                Toggle("Show board", isOn: $showBoard)
                Picker("Display", selection: $screen) {
                    Text("Automatic (smallest extra display)").tag("")
                    ForEach(screens, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Open at login", isOn: $login)
                    .onChange(of: login) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
            }
            Section {
                Toggle("Weather", isOn: $weather)
                Picker("Units", selection: $units) {
                    Text("Automatic").tag("auto"); Text("°C").tag("c"); Text("°F").tag("f")
                }
                Toggle("World clocks", isOn: $clocks)
                TextField("Time zones", text: $zones)
                Picker("Labels", selection: $seasonal) {
                    Text("EDT, CDT, PDT in summer").tag(true); Text("Always as typed").tag(false)
                }
            } header: { Text("Header") } footer: {
                Text("Codes like EST, CST, MST, PST, AZ, UK, PK, IN, AE, or Label=Area/City, for example Carvana=America/Phoenix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("On-air light when the camera is on", isOn: $onAir)
                Toggle("Also when the microphone is on", isOn: $onAirMic).disabled(!onAir)
                Toggle("Back-to-back warning", isOn: $b2b)
                Toggle("Chime 1 minute before", isOn: $chime)
                Toggle("Do Not Disturb during meetings", isOn: $dnd)
            } header: { Text("Meetings") } footer: {
                Text("Do Not Disturb runs two Shortcuts you make once: \"Meetboard Focus On\" and \"Meetboard Focus Off\" (each a Set Focus action).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Prayer times", isOn: $prayer)
                Picker("Method", selection: $method) {
                    ForEach(Prayer.methods.keys.sorted(), id: \.self) { Text(Prayer.methods[$0]!.name).tag($0) }
                }.disabled(!prayer)
                Picker("Asr", selection: $hanafi) {
                    Text("Standard").tag(false); Text("Hanafi").tag(true)
                }.disabled(!prayer)
                Toggle("Highlight a family calendar", isOn: $family)
                Picker("Calendar", selection: $familyCal) {
                    Text("Choose...").tag("")
                    ForEach(calendars, id: \.self) { Text($0).tag($0) }
                }.disabled(!family)
                Toggle("Nearby planes", isOn: $planesOn)
                HStack {
                    Text("Radius")
                    Slider(value: Binding(get: { Double(radius) }, set: { radius = Int($0) }), in: 2...25, step: 1)
                    Text("\(radius) nm").monospacedDigit().frame(width: 48, alignment: .trailing)
                }.disabled(!planesOn)
                TextField("Location", text: $location, prompt: Text("Automatic, or lat,lon"))
            } header: { Text("Extras") } footer: {
                Text("Weather, prayer times and planes use your location rounded to about 1 km. Planes from adsb.lol, weather from Open-Meteo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 600, idealHeight: 900)
    }
}

final class SettingsWindow {
    static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 900),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Meetboard Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
