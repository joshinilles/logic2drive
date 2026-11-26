// Logic2Drive – Varispeed-Wache. Wer mit Varispeed schneller schneidet, vergisst es leicht vor dem Bouncen,
// und Logic bounct dann in der geänderten Geschwindigkeit. Die Wache sieht über die Bedienungshilfen von macOS
// nach, sobald der Bounce-Dialog aufgeht, schaltet Varispeed aus und meldet das.
//
// Gemessen mit Logic Pro 13.0 (25.11.2026): Der Knopf in der Steuerungsleiste trägt die Kennung
// „controlBar/varispeedButton“, sein Wert ist 0 oder 1. Ist der Knopf in der Steuerungsleiste ausgeblendet,
// sieht die Wache nichts.
//
// Logic Pro 12.4 (gemessen am 25.11.2026 auf einem zweiten Mac, über --varispeed selbsttest): Der Knopf hat keine
// Kennung, er ist ein AXButton mit der Beschreibung „Varispeed“ und dem Wert 0 oder 1.
//
// Solange der Bounce-Dialog offen ist, zählt ein Druck auf den Knopf nicht: Mal tut Logic nichts, mal zeigt der
// Knopf danach „aus“ und Logic bounct trotzdem in der geänderten Geschwindigkeit (26.11.2026, Logic 12.4:
// Knopf nach dem Druck auf 0, die Datei war trotzdem um ein Viertel zu kurz). Die Wache schließt den Dialog
// deshalb immer, schaltet Varispeed dann aus und öffnet den Dialog über das Menü wieder.
// Was die Wache beim Öffnen eines Dialogs sieht, schreibt sie ins Protokoll.

import AppKit
import ApplicationServices

enum Varispeed {
    static let knopfKennung = "controlBar/varispeedButton"

    static func attr(_ e: AXUIElement, _ name: String) -> Any? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func text(_ e: AXUIElement, _ name: String) -> String {
        if let s = attr(e, name) as? String { return s }
        if let n = attr(e, name) as? NSNumber { return n.stringValue }
        return ""
    }

    static func kinder(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }

    /// Tiefensuche mit Grenze: Ein großes Projekt hat tausende Elemente, gesucht wird nur nahe am Fensterrand.
    static func finde(_ e: AXUIElement, tiefe: Int, _ passt: (AXUIElement) -> Bool) -> AXUIElement? {
        if passt(e) { return e }
        guard tiefe > 0 else { return nil }
        for k in kinder(e) { if let f = finde(k, tiefe: tiefe - 1, passt) { return f } }
        return nil
    }

    static func zaehle(_ e: AXUIElement, tiefe: Int, _ passt: (AXUIElement) -> Bool) -> Int {
        var n = passt(e) ? 1 : 0
        guard tiefe > 0 else { return n }
        for k in kinder(e) { n += zaehle(k, tiefe: tiefe - 1, passt) }
        return n
    }

    static func logic() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: logicID).first else { return nil }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 1.5)      // Logic antwortet während eines Bounce nicht: nicht hängen bleiben
        return a
    }

    static func fenster(_ app: AXUIElement) -> [AXUIElement] { attr(app, "AXWindows") as? [AXUIElement] ?? [] }

    /// Der Dialog „Projekt oder Abschnitt bouncen“. Erkannt ohne Sprache: ein Dialog mit den Häkchen der Ziele
    /// (Unkomprimiert, MP3, M4A, CD), die alle die Kennung „enable“ tragen. Der Titel ist nur die zweite Wahl.
    static func istBounceDialog(_ w: AXUIElement) -> Bool {
        guard text(w, "AXSubrole") == "AXDialog" || text(w, "AXRole") == "AXSheet" else { return false }
        if zaehle(w, tiefe: 8, { text($0, "AXRole") == "AXCheckBox" && text($0, "AXIdentifier") == "enable" }) >= 3 { return true }
        return text(w, "AXTitle").lowercased().contains("bounc")
    }

    /// Gesucht wird unter den Fenstern und unter den Blättern, die an einem Fenster hängen.
    static func bounceDialog(_ app: AXUIElement) -> AXUIElement? {
        let f = fenster(app)
        return f.first(where: istBounceDialog) ?? f.flatMap { kinder($0).filter { text($0, "AXRole") == "AXSheet" } }.first(where: istBounceDialog)
    }

    /// Die Varispeed-Knöpfe aller Projektfenster, das Hauptfenster zuerst.
    static func knoepfe(_ app: AXUIElement) -> [AXUIElement] {
        var liste = fenster(app).filter { text($0, "AXSubrole") == "AXStandardWindow" }
        if let i = liste.firstIndex(where: { (attr($0, "AXMain") as? Bool) == true }), i > 0 { liste.insert(liste.remove(at: i), at: 0) }
        // Erst nahe am Fensterrand, wo die Steuerungsleiste liegt. Nur wenn dort nichts ist, tiefer.
        return liste.compactMap { finde($0, tiefe: 6, istKnopf) ?? finde($0, tiefe: 12, istKnopf) }
    }

    static func istAn(_ knopf: AXUIElement) -> Bool { text(knopf, "AXValue") == "1" }

    /// Der Knopf an seiner Kennung, sonst an seiner Beschreibung. Die Anzeige der Abweichung heißt auch „Varispeed“,
    /// ist aber eine Gruppe und kein Knopf.
    static func istKnopf(_ e: AXUIElement) -> Bool {
        if !ohneKennung, text(e, "AXIdentifier") == knopfKennung { return true }
        guard ["AXCheckBox", "AXButton"].contains(text(e, "AXRole")) else { return false }
        return text(e, "AXDescription").lowercased() == "varispeed" || text(e, "AXTitle").lowercased() == "varispeed"
    }

    /// Nur für Tests: sucht den Knopf wie in Logic 12.4 an seiner Beschreibung statt an der Kennung.
    static let ohneKennung = ProcessInfo.processInfo.environment["LOGIC2DRIVE_VARISPEED_WIE_12"] != nil

    /// Der Menüpunkt mit dem Kürzel ⌘B ohne weitere Tasten („Projekt oder Abschnitt bouncen“), unabhängig von
    /// Sprache und Version.
    static func bounceMenuepunkt(_ app: AXUIElement) -> AXUIElement? {
        func geh(_ e: AXUIElement, _ tiefe: Int) -> AXUIElement? {
            if text(e, "AXRole") == "AXMenuItem", text(e, "AXMenuItemCmdChar") == "B", text(e, "AXMenuItemCmdModifiers") == "0" { return e }
            guard tiefe > 0 else { return nil }
            for k in kinder(e) { if let f = geh(k, tiefe - 1) { return f } }
            return nil
        }
        guard let leiste = attr(app, "AXMenuBar") else { return nil }
        return geh(leiste as! AXUIElement, 7)
    }

    /// Öffnet den Bounce-Dialog über das Menü und wartet bis zu drei Sekunden, dass er da ist.
    static func oeffneBounceDialog(_ app: AXUIElement) -> AXUIElement? {
        guard let punkt = bounceMenuepunkt(app) else { return nil }
        AXUIElementPerformAction(punkt, "AXPress" as CFString)
        for _ in 0..<30 {
            usleep(100_000)
            if let d = bounceDialog(app) { return d }
        }
        return nil
    }

    /// Bricht einen Dialog ab und wartet, bis er weg ist.
    static func brichAb(_ dialog: AXUIElement, in app: AXUIElement) -> Bool {
        let knopf = attr(dialog, "AXCancelButton").map { $0 as! AXUIElement }
            ?? finde(dialog, tiefe: 8) { text($0, "AXRole") == "AXButton" && ["Abbrechen", "Cancel", "Annuler"].contains(text($0, "AXTitle")) }
        guard let knopf, AXUIElementPerformAction(knopf, "AXPress" as CFString) == .success else { return false }
        for _ in 0..<20 {
            usleep(100_000)
            if bounceDialog(app) == nil { return true }
        }
        return false
    }

    /// Für das Protokoll, wenn kein Knopf gefunden wurde: die Schalter und Knöpfe am oberen Rand der Projektfenster.
    static func knopfListe(_ app: AXUIElement) -> String {
        var zeilen: [String] = []
        func geh(_ e: AXUIElement, _ tiefe: Int) {
            guard zeilen.count < 60 else { return }
            let rolle = text(e, "AXRole")
            if ["AXCheckBox", "AXButton", "AXPopUpButton", "AXMenuButton"].contains(rolle) {
                zeilen.append("\(rolle.dropFirst(2))[\(text(e, "AXDescription"))|\(text(e, "AXTitle"))|\(text(e, "AXIdentifier"))|\(text(e, "AXValue").prefix(12))]")
            }
            if tiefe > 0 { for k in kinder(e) { geh(k, tiefe - 1) } }
        }
        for w in fenster(app) where text(w, "AXSubrole") == "AXStandardWindow" { geh(w, 7) }
        return zeilen.isEmpty ? "nichts gefunden" : zeilen.joined(separator: " ")
    }

    /// Drückt den Knopf und sieht nach, ob Varispeed danach wirklich aus ist.
    static func schalteAus(_ knopf: AXUIElement, zehntel: Int = 10) -> Bool {
        guard AXUIElementPerformAction(knopf, "AXPress" as CFString) == .success else { return false }
        for _ in 0..<zehntel {
            usleep(100_000)
            if !istAn(knopf) { return true }
        }
        return false
    }

    /// Fragt macOS nach der Freigabe „Bedienungshilfen“. Mit `fragen` zeigt macOS den Hinweis mit dem Weg in die
    /// Systemeinstellungen; erteilen kann die Freigabe nur der Mensch am Mac.
    static func erlaubt(fragen: Bool = false) -> Bool {
        if !fragen { return AXIsProcessTrusted() }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func oeffneFreigabe() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    /// Für die Kommandozeile (--varispeed liste): was Logic an Fenstern und an Varispeed-Elementen zeigt.
    /// Damit lässt sich eine fremde Logic-Version aus der Ferne ansehen, über die App, die dort die Freigabe hat.
    static func liste() -> String {
        guard erlaubt() else { return "keine Freigabe „Bedienungshilfen“" }
        guard let app = logic() else { return "Logic läuft nicht" }
        var zeilen: [String] = []
        func geh(_ e: AXUIElement, _ tiefe: Int, _ max: Int) {
            guard zeilen.count < 200 else { return }
            let alles = ["AXDescription", "AXTitle", "AXIdentifier", "AXHelp"].map { text(e, $0) }
            if alles.joined(separator: " ").lowercased().contains("vari") {
                zeilen.append("  Tiefe \(tiefe): \(text(e, "AXRole"))/\(text(e, "AXSubrole")) bes=\(alles[0]) titel=\(alles[1]) id=\(alles[2]) wert=\(text(e, "AXValue").prefix(20)) hilfe=\(alles[3].prefix(50))")
            }
            if tiefe < max { for k in kinder(e) { geh(k, tiefe + 1, max) } }
        }
        for w in fenster(app) {
            zeilen.append("Fenster „\(text(w, "AXTitle"))“ \(text(w, "AXSubrole")) id=\(text(w, "AXIdentifier")) haupt=\(text(w, "AXMain")) bounce=\(istBounceDialog(w))")
            for k in kinder(w) where ["AXSheet", "AXDrawer", "AXWindow"].contains(text(k, "AXRole")) {
                let haken = zaehle(k, tiefe: 8) { text($0, "AXRole") == "AXCheckBox" }
                let namen = kinder(k).prefix(40).map { "\(text($0, "AXRole").dropFirst(2))[\(text($0, "AXTitle"))|\(text($0, "AXDescription"))|\(text($0, "AXIdentifier"))]" }.joined(separator: " ")
                zeilen.append("  angeheftet: \(text(k, "AXRole")) titel=\(text(k, "AXTitle")) id=\(text(k, "AXIdentifier")) Häkchen=\(haken) Inhalt: \(namen)")
            }
            geh(w, 0, 12)
        }
        zeilen.append("Steuerungsleiste: " + knopfListe(app))
        return zeilen.joined(separator: "\n")
    }

    /// Nur zum Prüfen (--varispeed selbsttest): schaltet Varispeed ein, öffnet den Bounce-Dialog über das Menü (⌘B),
    /// lässt die Wache arbeiten, bricht den Dialog ab und stellt Varispeed so wieder her, wie es vorher war.
    /// Dauert rund drei Sekunden und ist in Logic zu sehen.
    static func selbsttest() -> String {
        guard erlaubt() else { return "keine Freigabe „Bedienungshilfen“" }
        guard let app = logic() else { return "Logic läuft nicht" }
        var aus: [String] = []
        guard let knopf = knoepfe(app).first else { return "kein Varispeed-Knopf gefunden\n" + liste() }
        let vorher = istAn(knopf)
        aus.append("Knopf: \(text(knopf, "AXRole")) id=\(text(knopf, "AXIdentifier")), vorher \(vorher ? "an" : "aus")")
        var namen: CFArray?
        AXUIElementCopyActionNames(knopf, &namen)
        var setzbar: DarwinBoolean = false
        AXUIElementIsAttributeSettable(knopf, "AXValue" as CFString, &setzbar)
        aus.append("Aktionen: \((namen as? [String] ?? []).joined(separator: ", ")), Wert setzbar: \(setzbar.boolValue), aktiv: \(text(knopf, "AXEnabled"))")
        // Ohne Dialog zweimal drücken: zeigt, ob sich der Knopf überhaupt schalten lässt, und endet im alten Stand.
        for _ in 0..<2 {
            let r = AXUIElementPerformAction(knopf, "AXPress" as CFString)
            usleep(600_000)
            aus.append("ohne Dialog gedrückt: Ergebnis \(r.rawValue), danach \(istAn(knopf) ? "an" : "aus")")
        }
        if !istAn(knopf) {
            AXUIElementPerformAction(knopf, "AXPress" as CFString)
            usleep(500_000)
            aus.append("eingeschaltet: \(istAn(knopf))")
        }
        guard let punkt = bounceMenuepunkt(app) else { return (aus + ["Menüpunkt ⌘B nicht gefunden"]).joined(separator: "\n") }
        func oeffne() -> AXUIElement? {
            let r = AXUIElementPerformAction(punkt, "AXPress" as CFString)
            aus.append("Menüpunkt „\(text(punkt, "AXTitle"))“ aktiv=\(text(punkt, "AXEnabled")) gedrückt, Ergebnis \(r.rawValue)")
            for _ in 0..<30 {
                usleep(100_000)
                if let d = bounceDialog(app) { return d }
            }
            return nil
        }
        var dialog = oeffne()
        let vorn = NSWorkspace.shared.frontmostApplication
        if dialog == nil, fenster(app).allSatisfy({ text($0, "AXSubrole") == "AXStandardWindow" }),
           let l = NSRunningApplication.runningApplications(withBundleIdentifier: logicID).first {
            // Manche Versionen nehmen den Menübefehl nur an, wenn Logic vorn ist.
            aus.append("zweiter Versuch mit Logic im Vordergrund (vorn war \(vorn?.localizedName ?? "?"))")
            l.activate(options: [])
            usleep(800_000)
            dialog = oeffne()
        }
        defer { if let v = vorn, v.bundleIdentifier != logicID { v.activate(options: []) } }
        aus.append("Fenster: " + fenster(app).map { w in "„\(text(w, "AXTitle"))“ \(text(w, "AXSubrole")) bounce=\(istBounceDialog(w)) Blätter=\(kinder(w).filter { text($0, "AXRole") == "AXSheet" }.count)" }.joined(separator: "; "))
        if let d = dialog {
            aus.append("Bounce-Dialog erkannt, Ziel-Häkchen: \(zaehle(d, tiefe: 8) { text($0, "AXRole") == "AXCheckBox" && text($0, "AXIdentifier") == "enable" })")
            let wache = VarispeedWache()
            wache.melden = { aus.append("Meldung: " + $0) }
            wache.notieren = { aus.append("Protokoll: " + $0) }
            wache.pruefe()
            aus.append("Varispeed nach der Wache: \(istAn(knopf) ? "an" : "aus"), Bounce-Dialog \(bounceDialog(app) == nil ? "zu" : "offen")")
        } else {
            aus.append("KEIN Bounce-Dialog erkannt")
        }
        // Jeden Dialog wieder schließen, den der Test geöffnet hat.
        let offen = fenster(app).filter { text($0, "AXSubrole") == "AXDialog" } + fenster(app).flatMap { kinder($0).filter { text($0, "AXRole") == "AXSheet" } }
        for w in offen {
            if let b = attr(w, "AXCancelButton") { aus.append("Abbrechen: \(AXUIElementPerformAction(b as! AXUIElement, "AXPress" as CFString) == .success)") }
            else if let b = finde(w, tiefe: 8, { text($0, "AXRole") == "AXButton" && ["Abbrechen", "Cancel", "Annuler"].contains(text($0, "AXTitle")) }) {
                aus.append("Abbrechen (über den Titel): \(AXUIElementPerformAction(b, "AXPress" as CFString) == .success)")
            } else { aus.append("Dialog „\(text(w, "AXTitle"))“ ließ sich nicht schließen") }
        }
        usleep(700_000)
        if istAn(knopf) != vorher {
            AXUIElementPerformAction(knopf, "AXPress" as CFString)
            usleep(500_000)
        }
        aus.append("am Ende: Varispeed \(istAn(knopf) ? "an" : "aus") (vorher \(vorher ? "an" : "aus")), Bounce-Dialog \(bounceDialog(app) == nil ? "zu" : "OFFEN")")
        return aus.joined(separator: "\n")
    }

    /// Für die Kommandozeile: der Stand in einer Zeile.
    static func stand() -> String {
        guard erlaubt() else { return "keine Freigabe „Bedienungshilfen“" }
        guard let app = logic() else { return "Logic läuft nicht" }
        let k = knoepfe(app)
        let knopf = k.isEmpty ? "kein Varispeed-Knopf sichtbar" : "Varispeed " + k.map { istAn($0) ? "an" : "aus" }.joined(separator: ", ")
        return knopf + "; Bounce-Dialog " + (bounceDialog(app) == nil ? "zu" : "offen")
    }
}

final class VarispeedWache {
    var melden: (String) -> Void = { _ in }
    var notieren: (String) -> Void = { _ in }       // nur ins Protokoll, ohne Mitteilung
    private var gesehen = Set<String>()             // je Lauf einmal notiert
    private var uhr: Timer?
    private var beobachter: AXObserver?
    private var beobachtet: pid_t = 0
    private var dialogBehandelt = false

    var laeuft: Bool { uhr != nil }

    func start() {
        guard uhr == nil else { return }
        // Die Uhr hängt die Wache an Logic, sobald es läuft und die Freigabe da ist, und ist zugleich das Netz
        // unter dem Beobachter: Verpasst er ein Fenster, sieht sie es spätestens nach anderthalb Sekunden.
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.takt() }
        RunLoop.main.add(t, forMode: .common)
        uhr = t
        takt()
    }

    func stopp() {
        uhr?.invalidate()
        uhr = nil
        loese()
    }

    private func loese() {
        if let b = beobachter { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(b), .commonModes) }
        beobachter = nil
        beobachtet = 0
        dialogBehandelt = false
    }

    private func takt() {
        guard Varispeed.erlaubt(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: logicID).first else { loese(); return }
        if app.processIdentifier != beobachtet { haengeAn(app.processIdentifier) }
        pruefe()
    }

    /// Der Beobachter meldet neue Fenster sofort. So ist Varispeed aus, bevor jemand im Dialog auf OK drücken kann.
    private func haengeAn(_ pid: pid_t) {
        loese()
        beobachtet = pid
        var b: AXObserver?
        let ruf: AXObserverCallback = { _, _, _, zeiger in
            guard let zeiger else { return }
            Unmanaged<VarispeedWache>.fromOpaque(zeiger).takeUnretainedValue().pruefe()
        }
        guard AXObserverCreate(pid, ruf, &b) == .success, let b else { notieren("Varispeed-Wache: Logic lässt sich nicht beobachten, es bleibt beim Nachsehen im Takt"); return }
        let version = NSRunningApplication(processIdentifier: pid)?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
        notieren("Varispeed-Wache beobachtet Logic Pro \(version)")
        let app = AXUIElementCreateApplication(pid)
        let ich = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] { AXObserverAddNotification(b, app, n as CFString, ich) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(b), .commonModes)
        beobachter = b
    }

    private func einmal(_ zeile: String) {
        if gesehen.insert(zeile).inserted { notieren(zeile) }
    }

    func pruefe() {
        guard let app = Varispeed.logic() else { return }
        guard Varispeed.bounceDialog(app) != nil else {
            dialogBehandelt = false
            // Ein Dialog, den die Wache nicht für den Bounce-Dialog hält: einmal notieren, falls sie sich irrt.
            for w in Varispeed.fenster(app) where Varispeed.text(w, "AXSubrole") == "AXDialog" {
                einmal("Varispeed-Wache: Dialog „\(Varispeed.text(w, "AXTitle"))“ gilt nicht als Bounce-Dialog")
            }
            return
        }
        guard !dialogBehandelt else { return }
        dialogBehandelt = true      // je Dialog einmal: Wer Varispeed danach bewusst wieder einschaltet, behält es
        let alle = Varispeed.knoepfe(app)
        if alle.isEmpty {
            notieren("Varispeed-Wache: Bounce-Dialog offen, aber kein Varispeed-Knopf gefunden")
            einmal("Varispeed-Wache sieht in der Steuerungsleiste: " + Varispeed.knopfListe(app))
            return
        }
        let an = alle.filter(Varispeed.istAn)
        notieren("Varispeed-Wache: Bounce-Dialog offen, Varispeed ist \(an.isEmpty ? "aus" : "an") (Wert \(alle.map { Varispeed.text($0, "AXValue") }.joined(separator: ", ")))")
        guard !an.isEmpty else { return }
        // Zu welchem Projekt der Dialog gehört, verrät Logic nicht. Bei mehreren offenen Projekten gilt das Hauptfenster.
        // Bei offenem Dialog ist auf den Knopf kein Verlass, auch wenn er danach „aus“ zeigt: Dialog schließen,
        // ausschalten, Dialog wieder öffnen. Er ist in diesem Moment gerade erst aufgegangen, es geht also keine
        // Eingabe verloren.
        guard let dialog = Varispeed.bounceDialog(app), Varispeed.brichAb(dialog, in: app) else {
            melden(L("Achtung: Varispeed ist noch an und ließ sich nicht ausschalten. Schalte es in Logic aus, bevor du bounct."))
            return
        }
        notieren("Varispeed-Wache: Dialog geschlossen, um Varispeed auszuschalten")
        // Gleich nach dem Schließen nimmt Logic 12 den Knopf noch nicht an (gemessen: eine Sekunde reicht nicht immer).
        // Deshalb mehrere Anläufe, und vor jedem neu nachsehen: Ein verspätet angekommener Druck soll nicht durch
        // den nächsten wieder aufgehoben werden.
        var versuche = 0
        for _ in 0..<6 {
            usleep(350_000)
            guard let k = Varispeed.knoepfe(app).first(where: Varispeed.istAn) else { break }
            versuche += 1
            if Varispeed.schalteAus(k, zehntel: 6) { break }
        }
        usleep(200_000)
        notieren("Varispeed-Wache: \(versuche) Anlauf/Anläufe zum Ausschalten nach dem Schließen")
        guard Varispeed.knoepfe(app).first(where: Varispeed.istAn) == nil else {
            melden(L("Achtung: Varispeed ist noch an und ließ sich nicht ausschalten. Logic2Drive hat den Bounce-Dialog geschlossen. Schalte Varispeed in Logic aus und bounce dann noch einmal."))
            return
        }
        if Varispeed.oeffneBounceDialog(app) != nil {
            melden(L("Varispeed war noch an. Logic2Drive hat es ausgeschaltet und den Bounce-Dialog neu geöffnet."))
        } else {
            melden(L("Varispeed war noch an und ist jetzt aus. Öffne den Bounce-Dialog bitte noch einmal."))
        }
    }
}
