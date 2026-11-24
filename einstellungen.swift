// Logic2Drive – Einstellungsfenster. Alles, was man selten braucht, steht hier und nicht im Menü:
// die drei Schalter, die Sprache, Updates mit „Was ist neu“ und wer den Helfer gebaut hat.
// Gebaut mit den Bedienelementen von macOS (Liste wie in den Systemeinstellungen).

import AppKit
import SwiftUI

struct NeuesEintrag: Identifiable {
    let version: String
    let zeilen: [String]
    var id: String { version }
}

/// Liest NEUES.json aus der App: je Version ein paar Zeilen, in der Sprache des Helfers, sonst Englisch, sonst Deutsch.
func ladeNeues() -> [NeuesEintrag] {
    guard let u = Bundle.main.url(forResource: "NEUES", withExtension: "json"), let d = try? Data(contentsOf: u),
          let liste = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
    return liste.compactMap { e in
        guard let v = e["version"] as? String else { return nil }
        let zeilen = (e[sprache] ?? e["en"] ?? e["de"]) as? [String] ?? []
        return zeilen.isEmpty ? nil : NeuesEintrag(version: v, zeilen: zeilen)
    }
}

final class EinstellungenModell: ObservableObject {
    @Published var updatesVonSelbst = true
    @Published var updateText: String?
    @Published var sprachWahl = "auto"
    var lies: () -> (updatesVonSelbst: Bool, updateText: String?, sprachWahl: String) = { (true, nil, "auto") }
    var setzeUpdatesVonSelbst: (Bool) -> Void = { _ in }
    var sucheUpdate: () -> Void = {}
    var setzeSprache: (String) -> Void = { _ in }
    var zeigeEinfuehrung: () -> Void = {}
    let neues = Array(ladeNeues().prefix(3))

    func frisch() {
        let s = lies()
        if s.updatesVonSelbst != updatesVonSelbst { updatesVonSelbst = s.updatesVonSelbst }
        if s.updateText != updateText { updateText = s.updateText }
        if s.sprachWahl != sprachWahl { sprachWahl = s.sprachWahl }
    }
}

/// Der Umschalter von macOS, in der Farbe der Marke. Die Farbe gilt bewusst nur für die Schalter: Auf dem
/// ganzen Fenster färbt sie im aktiven Fenster auch Knöpfe und Auswahlfelder lila ein, und das ist auf
/// dunklem Grund nicht lesbar.
struct MarkenSchalter: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .tint(Marke.deep)
    }
}

struct EinstellungenAnsicht: View {
    @ObservedObject var schalter: WillkommenModell
    @ObservedObject var modell: EinstellungenModell
    let uhr = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let s = schalter.stand
        Form {
            Section(L("Allgemein")) {
                Toggle(isOn: schalter.schalter("drive", schalter.driveSetzen)) {
                    Text(L("Google Drive beobachten"))
                    Text(s.driveDa ? L("Logic2Drive packt Logic-Projekte in deinem Google Drive als Zip ein. Nur so kommen sie vollständig bei den anderen an.")
                                   : L("Auf diesem Mac ist Google Drive noch nicht eingerichtet. Melde dich zuerst dort an."))
                }
                .disabled(!s.driveDa)
                Toggle(isOn: schalter.schalter("zip", schalter.zipSetzen)) {
                    Text(L("Projekte per Doppelklick öffnen"))
                    Text(L("Ein Doppelklick auf eine Projekt-Zip öffnet das Projekt direkt in Logic. Alle anderen Zips öffnen sich wie gewohnt."))
                }
                Toggle(isOn: schalter.schalter("autostart", schalter.autostartSetzen)) {
                    Text(L("Beim Anmelden starten"))
                    Text(L("Logic2Drive startet von selbst, wenn du deinen Mac einschaltest."))
                }
            }

            Section {
                Picker(L("Sprache"), selection: Binding(get: { modell.sprachWahl }, set: { modell.sprachWahl = $0; modell.setzeSprache($0) })) {
                    Text(L("Wie der Mac")).tag("auto")
                    // Jede Sprache in ihrer eigenen Schreibweise, damit man sie auch in einer fremden Oberfläche findet.
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                    Text("Français").tag("fr")
                    Text("العربية").tag("ar")
                    Text("فارسی").tag("fa")
                }
            } header: {
                Text(L("Sprache"))
            } footer: {
                Text(L("Nach einem Wechsel startet Logic2Drive neu.")).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(L("Updates")) {
                LabeledContent(L("Version"), value: helferVersion)
                Toggle(isOn: Binding(get: { modell.updatesVonSelbst }, set: { modell.updatesVonSelbst = $0; modell.setzeUpdatesVonSelbst($0) })) {
                    Text(L("Updates von selbst einspielen"))
                    Text(L("Logic2Drive lädt neue Versionen und spielt sie ein, sobald kein Projekt in Arbeit ist."))
                }
                HStack {
                    if let u = modell.updateText { Text(u).foregroundStyle(.secondary) }
                    Spacer()
                    Button(L("Nach Updates suchen"), action: modell.sucheUpdate)
                }
            }

            if !modell.neues.isEmpty {
                Section(L("Was ist neu")) {
                    ForEach(modell.neues) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Version \(e.version)")).fontWeight(.semibold)
                            ForEach(e.zeilen, id: \.self) { zeile in
                                Text("• " + zeile).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section(L("Über Logic2Drive")) {
                Text(L("Google Drive kommt mit Logic-Projekten nicht zurecht, mit Zips schon. Logic2Drive legt Projekte deshalb als Zip in Google Drive ab und öffnet sie per Doppelklick wieder in Logic."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Gebaut von Joshua Nilles im Auftrag der bibletunes gGmbH."))
                if let u = URL(string: "https://bibletunes.com") { Link("bibletunes.com", destination: u) }
                if let u = URL(string: projektSeite) { Link(L("Quelltext auf GitHub"), destination: u) }
                HStack {
                    Spacer()
                    Button(L("Einführung zeigen"), action: modell.zeigeEinfuehrung)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(MarkenSchalter())
        .frame(width: 540)
        .frame(maxHeight: .infinity)
        .environment(\.layoutDirection, vonRechts ? .rightToLeft : .leftToRight)
        .onReceive(uhr) { _ in
            schalter.frisch()
            modell.frisch()
        }
    }
}

final class EinstellungenFenster: NSObject {
    let modell = EinstellungenModell()
    var fenster: NSWindow?

    func zeige(schalter: WillkommenModell) {
        if fenster == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = L("Logic2Drive – Einstellungen")
            w.isReleasedWhenClosed = false
            let ansicht = NSHostingView(rootView: EinstellungenAnsicht(schalter: schalter, modell: modell))
            ansicht.sizingOptions = []
            w.contentView = ansicht
            w.setContentSize(NSSize(width: 540, height: 700))
            w.center()
            fenster = w
        }
        schalter.frisch()
        modell.frisch()
        NSApp.activate(ignoringOtherApps: true)
        fenster?.makeKeyAndOrderFront(nil)
    }
}

/// Zeichnet das Fenster in eine PNG-Datei, ohne es anzuzeigen. Nur zum Prüfen der Gestaltung.
/// Gezeichnet wird es so, wie es als aktives Fenster aussieht: Erst dann färbt macOS Knöpfe und Schalter ein.
func einstellungenAlsBild(_ pfad: String, dunkel: Bool? = nil) -> Bool {
    _ = NSApplication.shared
    let schalter = WillkommenModell()
    schalter.lies = { WillkommenStand(drive: true, zip: true, autostart: false, driveDa: true) }
    schalter.frisch()
    let modell = EinstellungenModell()
    modell.lies = { (true, L("Version \("9.9") wird eingespielt, sobald nichts in Arbeit ist"), "auto") }
    modell.frisch()
    let ansicht = NSHostingView(rootView: EinstellungenAnsicht(schalter: schalter, modell: modell).environment(\.controlActiveState, .key))
    let groesse = NSSize(width: 540, height: 900)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: groesse), styleMask: [.borderless], backing: .buffered, defer: false)
    if let dunkel {
        w.appearance = NSAppearance(named: dunkel ? .darkAqua : .aqua)
        ansicht.appearance = w.appearance
    }
    w.contentView = ansicht
    ansicht.frame = NSRect(origin: .zero, size: groesse)
    ansicht.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    guard let rep = ansicht.bitmapImageRepForCachingDisplay(in: ansicht.bounds) else { return false }
    ansicht.cacheDisplay(in: ansicht.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: pfad))) != nil
}
