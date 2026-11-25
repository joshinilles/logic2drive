// Logic2Drive – Varispeed-Wache. Wer mit Varispeed schneller schneidet, vergisst es leicht vor dem Bouncen,
// und Logic bounct dann in der geänderten Geschwindigkeit. Die Wache sieht über die Bedienungshilfen von macOS
// nach, sobald der Bounce-Dialog aufgeht, schaltet Varispeed aus und meldet das.
//
// Gemessen mit Logic Pro 13.0 (25.11.2026): Der Knopf in der Steuerungsleiste trägt die Kennung
// „controlBar/varispeedButton“, sein Wert ist 0 oder 1, und er lässt sich auch bei offenem Bounce-Dialog drücken.
// Ist der Knopf in der Steuerungsleiste ausgeblendet, sieht die Wache nichts.

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
        guard text(w, "AXSubrole") == "AXDialog" else { return false }
        if zaehle(w, tiefe: 8, { text($0, "AXRole") == "AXCheckBox" && text($0, "AXIdentifier") == "enable" }) >= 3 { return true }
        return text(w, "AXTitle").lowercased().contains("bounc")
    }

    static func bounceDialog(_ app: AXUIElement) -> AXUIElement? { fenster(app).first(where: istBounceDialog) }

    /// Die Varispeed-Knöpfe aller Projektfenster, das Hauptfenster zuerst.
    static func knoepfe(_ app: AXUIElement) -> [AXUIElement] {
        var liste = fenster(app).filter { text($0, "AXSubrole") == "AXStandardWindow" }
        if let i = liste.firstIndex(where: { (attr($0, "AXMain") as? Bool) == true }), i > 0 { liste.insert(liste.remove(at: i), at: 0) }
        return liste.compactMap { finde($0, tiefe: 6) { text($0, "AXIdentifier") == knopfKennung } }
    }

    static func istAn(_ knopf: AXUIElement) -> Bool { text(knopf, "AXValue") == "1" }

    /// Drückt den Knopf und sieht nach, ob Varispeed danach wirklich aus ist.
    static func schalteAus(_ knopf: AXUIElement) -> Bool {
        guard AXUIElementPerformAction(knopf, "AXPress" as CFString) == .success else { return false }
        for _ in 0..<10 {
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
        guard AXObserverCreate(pid, ruf, &b) == .success, let b else { return }
        let app = AXUIElementCreateApplication(pid)
        let ich = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] { AXObserverAddNotification(b, app, n as CFString, ich) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(b), .commonModes)
        beobachter = b
    }

    func pruefe() {
        guard let app = Varispeed.logic() else { return }
        guard Varispeed.bounceDialog(app) != nil else { dialogBehandelt = false; return }
        guard !dialogBehandelt else { return }
        dialogBehandelt = true      // je Dialog einmal: Wer Varispeed danach bewusst wieder einschaltet, behält es
        let an = Varispeed.knoepfe(app).filter(Varispeed.istAn)
        guard !an.isEmpty else { return }
        // Zu welchem Projekt der Dialog gehört, verrät Logic nicht. Bei mehreren offenen Projekten gilt das Hauptfenster.
        if Varispeed.schalteAus(an[0]) {
            melden(L("Varispeed war noch an. Logic2Drive hat es für den Bounce ausgeschaltet."))
        } else {
            melden(L("Achtung: Varispeed ist noch an und ließ sich nicht ausschalten. Schalte es in Logic aus, bevor du bounct."))
        }
    }
}
