// Logic2Drive – Willkommensfenster. Farben: das Lila und Türkis von bibletunes.
// Der Kopf trägt die Farben und das eigene Zeichen des Helfers, kein Firmenlogo: Das Projekt soll öffentlich
// nutzbar sein (Joshua, 24.11.2026). Darunter stehen bewusst die
// Bedienelemente von macOS: Schalterliste wie in den Systemeinstellungen, normale Knöpfe (Joshua, 24.11.2026).

import AppKit
import SwiftUI

enum Marke {
    static let deep = Color(red: 0x60 / 255, green: 0x21 / 255, blue: 0x84 / 255)      // purple, brand-deep
    static let bright = Color(red: 0x00 / 255, green: 0x99 / 255, blue: 0xa9 / 255)    // teal, brand-bright
    static let linie = Color.black.opacity(0.12)
}

struct WillkommenStand: Equatable {
    var drive = false
    var zip = false
    var autostart = false
    var driveDa = true
    var alle: Bool { drive && zip && autostart }
}

final class WillkommenModell: ObservableObject {
    @Published var stand = WillkommenStand()
    var lies: () -> WillkommenStand = { WillkommenStand() }
    var driveSetzen: (Bool) -> Void = { _ in }
    var zipSetzen: (Bool) -> Void = { _ in }
    var autostartSetzen: (Bool) -> Void = { _ in }
    var fertig: () -> Void = {}
    private var wunsch: [String: (wert: Bool, bis: Date)] = [:]
    private let felder: [(String, WritableKeyPath<WillkommenStand, Bool>)] = [("drive", \.drive), ("zip", \.zip), ("autostart", \.autostart)]

    /// Der Stand kommt vom System. Kurz nach einem Klick gilt aber der Wunsch, bis das System nachgezogen hat,
    /// sonst springt der Schalter für einen Moment zurück.
    func frisch() {
        var neu = lies()
        for (name, feld) in felder {
            guard let w = wunsch[name] else { continue }
            if neu[keyPath: feld] == w.wert || Date() > w.bis { wunsch[name] = nil } else { neu[keyPath: feld] = w.wert }
        }
        if neu != stand { stand = neu }
    }

    func schalter(_ name: String, _ tun: @escaping (Bool) -> Void) -> Binding<Bool> {
        guard let feld = felder.first(where: { $0.0 == name })?.1 else { return .constant(false) }
        return Binding(get: { self.stand[keyPath: feld] }, set: { neu in
            self.stand[keyPath: feld] = neu
            self.wunsch[name] = (neu, Date().addingTimeInterval(4))
            tun(neu)
        })
    }
}

/// Ein Ausschnitt der Menüleiste mit dem Zeichen des Helfers und seinem aufgeklappten Menü.
struct MenueleisteBild: View {
    static let zeit: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: sprache)
        f.setLocalizedDateFormatFromTemplate("EEEdMMMHHmm")
        return f.string(from: Date())
    }()

    var menue: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Logic2Drive").fontWeight(.semibold)
            Text(L("Beobachtet dein Google Drive"))
            Rectangle().fill(Marke.linie).frame(height: 1)
            Text(L("Gerade nichts in Arbeit"))
        }
        .font(.system(size: 12))
        .foregroundColor(.black)
        .padding(12)
        .frame(width: 214, alignment: .leading)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
        .environment(\.layoutDirection, vonRechts ? .rightToLeft : .leftToRight)
    }

    var body: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Marke.bright).frame(width: 28, height: 28)
                Image(nsImage: helferZeichen(18, vorlage: false))
            }
            // Das Menü hängt wie in macOS links bündig unter dem Zeichen.
            .overlay(alignment: .topLeading) { menue.fixedSize().offset(y: 32) }
            Image(systemName: "wifi")
            Image(systemName: "battery.75")
            Text(Self.zeit)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color.black)
        // Die Leiste zeigt die Menüleiste des Systems, und die läuft nur dort von rechts, wo macOS selbst es tut.
        .environment(\.layoutDirection, menueleisteVonRechts ? .rightToLeft : .leftToRight)
        .padding(.bottom, 100)      // Platz für das aufgeklappte Menü
        .overlay(alignment: .bottomLeading) {
            Text(L("So sieht es aus, wenn du auf das Zeichen klickst."))
                .foregroundStyle(.secondary)
                .frame(width: 210, alignment: .leading)
                .padding(.bottom, 34)
        }
    }
}

struct WillkommenAnsicht: View {
    @ObservedObject var modell: WillkommenModell
    @State var seite = 0
    let uhr = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let s = modell.stand
        VStack(alignment: .leading, spacing: 0) {
            // Kopf
            VStack(alignment: .leading, spacing: 10) {
                Image(nsImage: helferZeichen(46, farbe: .white, vorlage: false))
                Spacer(minLength: 0)
                Text(seite == 0 ? L("Willkommen bei Logic2Drive") : L("Drei Dinge einschalten"))
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-0.7)
                Text(seite == 0 ? L("Google Drive kommt mit Logic-Projekten nicht zurecht, mit Zips schon. Logic2Drive legt deine Projekte deshalb als Zip in Google Drive ab und öffnet sie per Doppelklick wieder in Logic.")
                                : L("Danach läuft alles von selbst. Du kannst jeden Punkt später im Menü oben rechts ändern."))
                    .font(.system(size: 16))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 250)
            .background(Marke.deep)

            // Inhalt mit den Bedienelementen von macOS
            Group {
                if seite == 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("Du findest Logic2Drive oben rechts in der Menüleiste")).font(.title3.weight(.semibold))
                        Text(L("Logic2Drive hat kein Fenster und kein Symbol im Dock. Ein Klick auf das Zeichen zeigt dir, was gerade läuft."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                        MenueleisteBild().padding(.top, 18)
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 24)
                } else {
                    Form {
                        Section {
                            Toggle(isOn: modell.schalter("drive", modell.driveSetzen)) {
                                Text(L("Google Drive beobachten"))
                                Text(s.driveDa ? L("Logic2Drive packt Logic-Projekte in deinem Google Drive als Zip ein. Nur so kommen sie vollständig bei den anderen an.")
                                               : L("Auf diesem Mac ist Google Drive noch nicht eingerichtet. Melde dich zuerst dort an."))
                            }
                            .disabled(!s.driveDa)
                            Toggle(isOn: modell.schalter("zip", modell.zipSetzen)) {
                                Text(L("Projekte per Doppelklick öffnen"))
                                Text(L("Ein Doppelklick auf eine Projekt-Zip öffnet das Projekt direkt in Logic. Alle anderen Zips öffnen sich wie gewohnt."))
                            }
                            Toggle(isOn: modell.schalter("autostart", modell.autostartSetzen)) {
                                Text(L("Beim Anmelden starten"))
                                Text(L("Logic2Drive startet von selbst, wenn du deinen Mac einschaltest."))
                            }
                        } footer: {
                            Text(L("Fragt dein Mac später, ob Logic2Drive Logic Pro steuern darf, klicke bitte auf „Erlauben“. Nur so lässt sich erkennen, wann ein Projekt geschlossen ist."))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .formStyle(.grouped)
                    .toggleStyle(.switch)
                    .tint(Marke.deep)
                    .scrollDisabled(true)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Fuß
            HStack(spacing: 12) {
                if seite == 0 {
                    Text(L("Schritt 1 von 2")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Weiter")) { seite = 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Text(s.alle ? L("Alles ist eingeschaltet.") : L("Noch nicht alles eingeschaltet.")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Zurück")) { seite = 0 }
                    Button(s.alle ? L("Fertig") : L("Später fertig machen"), action: modell.fertig)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .tint(Marke.deep)
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
        .frame(width: 600)
        .frame(maxHeight: .infinity)
        .environment(\.layoutDirection, vonRechts ? .rightToLeft : .leftToRight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(uhr) { _ in modell.frisch() }
    }
}

final class WillkommenFenster: NSObject, NSWindowDelegate {
    let modell = WillkommenModell()
    var fenster: NSWindow?
    var geschlossen: () -> Void = {}

    func zeige() {
        if fenster == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 594),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Logic2Drive"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .aqua)       // weißer Grund und schwarze Schrift, auch im Dunkelmodus
            let ansicht = NSHostingView(rootView: WillkommenAnsicht(modell: modell).ignoresSafeArea())
            ansicht.sizingOptions = []      // sonst legt SwiftUI die Fenstergröße fest und rechnet die Titelleiste dazu
            w.contentView = ansicht
            w.setFrame(NSRect(x: 0, y: 0, width: 600, height: 594), display: false)     // der Inhalt reicht bis unter die Titelleiste
            w.delegate = self
            w.center()
            fenster = w
        }
        modell.fertig = { [weak self] in self?.fenster?.close() }
        modell.frisch()
        NSApp.activate(ignoringOtherApps: true)
        fenster?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { geschlossen() }
}

/// Zeichnet das Fenster in eine PNG-Datei, ohne es anzuzeigen. Nur zum Prüfen der Gestaltung.
func willkommenAlsBild(_ pfad: String, stand: WillkommenStand, seite: Int) -> Bool {
    _ = NSApplication.shared
    let modell = WillkommenModell()
    modell.lies = { stand }
    modell.frisch()
    let ansicht = NSHostingView(rootView: WillkommenAnsicht(modell: modell, seite: seite))
    ansicht.appearance = NSAppearance(named: .aqua)
    let groesse = NSSize(width: 600, height: 594)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: groesse), styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: .aqua)
    w.contentView = ansicht
    ansicht.frame = NSRect(origin: .zero, size: groesse)
    ansicht.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    guard let rep = ansicht.bitmapImageRepForCachingDisplay(in: ansicht.bounds) else { return false }
    ansicht.cacheDisplay(in: ansicht.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: pfad))) != nil
}
