// Logic2Drive – Bounce-Prüfung. Ein Bounce ist schnell gemacht und selten noch einmal ganz angehört. Die Wache
// sieht nach, sobald in einem beobachteten Drive-Ordner eine neue Audiodatei liegt, während Logic läuft, und meldet,
// was beim Durchhören auffallen würde: eine Strecke, die viel lauter oder leiser ist als der Rest (typisch der
// Jingle), eine Pause von mehr als vier Sekunden, übersteuerte Spitzen, Knackser und Aussetzer. Die Messung selbst
// steht in pruefung.swift.
//
// Was als Bounce gilt, lässt sich von außen nicht sicher sagen: Logic verrät weder Ziel noch Zeitpunkt. Deshalb
// gilt eine Audiodatei als frisch gebounct, wenn sie in den letzten Minuten geschrieben wurde, ganz auf diesem Mac
// liegt und Logic läuft. Was Drive von anderen holt, liegt hier nur als Platzhalter ohne Inhalt und bleibt
// unberührt; die Wache würde es sonst zum Prüfen herunterladen. Bounces außerhalb der beobachteten Ordner sieht
// sie nicht.

import AppKit

let audioEndungen: Set<String> = ["mp3", "wav", "aif", "aiff", "m4a"]

enum BounceText {
    static func zeit(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return "\(t / 60):" + (t % 60 < 10 ? "0" : "") + "\(t % 60)"
    }

    /// Höchstens drei Zeiten, der Rest als Zahl: Eine Mitteilung zeigt nur wenige Zeilen.
    static func zeiten(_ stellen: [PruefStelle]) -> String {
        let erste = stellen.prefix(3).map { zeit($0.von) }.joined(separator: ", ")
        return stellen.count > 3 ? L("\(erste) und \(stellen.count - 3) weitere") : erste
    }

    static func saetze(_ b: PruefBefund) -> [String] {
        var aus: [String] = []
        var mehr = 0        // Stellen, die nicht mehr in die Mitteilung passen; sie stehen im Protokoll
        func von(_ art: PruefArt) -> [PruefStelle] { b.stellen.filter { $0.art == art } }
        func erste(_ art: PruefArt) -> ArraySlice<PruefStelle> { mehr += max(0, von(art).count - 2); return von(art).prefix(2) }
        for s in erste(.lauter) {
            aus.append(L("\(zeit(s.von))–\(zeit(s.bis)) ist \(Int(s.wert.rounded())) LU lauter als der Rest"))
        }
        for s in erste(.leiser) {
            aus.append(L("\(zeit(s.von))–\(zeit(s.bis)) ist \(Int((-s.wert).rounded())) LU leiser als der Rest"))
        }
        for s in erste(.pause) {
            aus.append(L("Pause von \(Int((s.bis - s.von).rounded())) s ab \(zeit(s.von))"))
        }
        if !von(.uebersteuert).isEmpty { aus.append(L("übersteuert bei \(zeiten(von(.uebersteuert)))")) }
        // „möglich“: Gemessen wird ein kurzer Impuls, der nicht zum Klang ringsum passt. Das kann ein Schnitt ohne
        // Fade sein, aber auch ein Schmatzer der Stimme. Ob es stört, entscheidet das Ohr.
        if !von(.knackser).isEmpty { aus.append(L("mögliche Knackser bei \(zeiten(von(.knackser)))")) }
        if !von(.aussetzer).isEmpty { aus.append(L("Aussetzer bei \(zeiten(von(.aussetzer)))")) }
        if mehr > 0 { aus.append(L("\(mehr) weitere Stellen im Protokoll")) }
        return aus
    }

    static func mitteilung(name: String, _ b: PruefBefund) -> String {
        L("„\(name)“ geprüft: \(saetze(b).joined(separator: "; ")).")
    }

    /// Woran die Wache denselben Befund wiedererkennt: Art und Sekunde jeder Stelle. Eine Fassung derselben Datei,
    /// die nur insgesamt lauter oder leiser ist (die Lautstärke-Angleichung auf dem Server), hat dieselbe Kennung.
    static func kennung(_ b: PruefBefund) -> String {
        b.stellen.map { "\($0.art.rawValue)\(Int($0.von.rounded()))" }.joined(separator: " ")
    }
}

final class BounceWache {
    var melden: (String) -> Void = { _ in }
    var notieren: (String) -> Void = { _ in }       // nur ins Protokoll, ohne Mitteilung
    /// Nur für Tests: prüft auch, wenn Logic nicht läuft.
    var ohneLogic = ProcessInfo.processInfo.environment["LOGIC2DRIVE_BOUNCE_OHNE_LOGIC"] == "1"

    static let frisch = 600.0       // s: so jung muss die letzte Änderung sein, sonst ist es kein Bounce von eben
    static let ruhe = 4.0           // s ohne Änderung, bevor geprüft wird: Logic schreibt eine lange Datei in Stücken
    static let doppelt = 120.0      // s: PCM und MP3 desselben Bounce ergeben eine Mitteilung, nicht zwei

    private let q = DispatchQueue(label: "de.bibletunes.logic2drive.bounce", qos: .utility)
    private var strom: FSEventStreamRef?
    private var uhr: DispatchSourceTimer?
    private var wartend: [String: (stand: String, seit: Double)] = [:]
    private var geprueft: [String: (stand: String, kennung: String, zeit: Double)] = [:]    // je Pfad der letzte Befund
    private var gemeldet: [String: Double] = [:]                                            // Pfad ohne Endung -> wann

    var laeuft: Bool { strom != nil }

    func start(ordner: [String]) {
        stopp()
        guard !ordner.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let rueckruf: FSEventStreamCallback = { _, info, _, pfade, _, _ in
            guard let info, let liste = unsafeBitCast(pfade, to: NSArray.self) as? [String] else { return }
            let wache = Unmanaged<BounceWache>.fromOpaque(info).takeUnretainedValue()
            for p in liste { wache.gesehen(p) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, rueckruf, &ctx, ordner as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, q)
        FSEventStreamStart(s)
        strom = s
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.takt() }
        t.resume()
        uhr = t
    }

    func stopp() {
        if let s = strom {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        strom = nil
        uhr?.cancel()
        uhr = nil
        q.async { self.wartend = [:] }
    }

    /// Größe und Änderungszeit als Kennzeichen eines Standes; nil für alles, was kein frischer Bounce sein kann.
    private func stand(_ pfad: String) -> String? {
        var s = stat()
        guard lstat(pfad, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size > 0 else { return nil }
        // Platzhalter von Drive: Der Inhalt liegt nicht auf diesem Mac. Lesen würde ihn herunterladen.
        guard s.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        let mtime = Double(s.st_mtimespec.tv_sec)
        guard Date().timeIntervalSince1970 - mtime <= BounceWache.frisch else { return nil }
        return "\(s.st_size):\(s.st_mtimespec.tv_sec).\(s.st_mtimespec.tv_nsec)"
    }

    private func gesehen(_ pfad: String) {
        let name = (pfad as NSString).lastPathComponent
        guard audioEndungen.contains((name as NSString).pathExtension.lowercased()), !name.hasPrefix(".") else { return }
        guard ohneLogic || !NSRunningApplication.runningApplications(withBundleIdentifier: logicID).isEmpty else { return }
        guard let st = stand(pfad), geprueft[pfad]?.stand != st else { return }
        if wartend[pfad]?.stand != st { wartend[pfad] = (st, Date().timeIntervalSince1970) }
    }

    private func takt() {
        let t = Date().timeIntervalSince1970
        for (pfad, w) in wartend {
            guard let st = stand(pfad) else { wartend[pfad] = nil; continue }
            if st != w.stand { wartend[pfad] = (st, t); continue }
            guard t - w.seit >= BounceWache.ruhe else { continue }
            wartend[pfad] = nil
            pruefe(pfad, stand: st)
        }
        for (p, g) in geprueft where t - g.zeit > 86400 { geprueft[p] = nil }
        for (p, z) in gemeldet where t - z > 86400 { gemeldet[p] = nil }
    }

    private func pruefe(_ pfad: String, stand st: String) {
        let name = (pfad as NSString).lastPathComponent
        let befund: PruefBefund
        do { befund = try BouncePruefung.pruefe(pfad) } catch {
            notieren("Bounce-Prüfung: „\(name)“ ließ sich nicht lesen (\(error.localizedDescription))")
            return
        }
        // Logic legt beim MP3-Bounce erst eine PCM-Datei an und löscht sie wieder: nichts melden, was schon weg ist.
        guard stand(pfad) == st else { return }
        let t = Date().timeIntervalSince1970
        let kennung = BounceText.kennung(befund)
        let vorher = geprueft[pfad]
        geprueft[pfad] = (st, kennung, t)
        notieren("Bounce-Prüfung: „\(name)“ – " + befund.bericht().split(separator: "\n").joined(separator: "; "))
        let stamm = (pfad as NSString).deletingPathExtension
        if befund.stellen.isEmpty {
            // Wer nach einer Warnung neu bounct, soll sehen, dass es jetzt stimmt.
            if let vorher, !vorher.kennung.isEmpty { melden(L("„\(name)“ geprüft: jetzt ohne Auffälligkeiten.")) }
            return
        }
        guard vorher?.kennung != kennung else { return }
        if let z = gemeldet[stamm], t - z < BounceWache.doppelt, vorher == nil { return }
        gemeldet[stamm] = t
        melden(BounceText.mitteilung(name: name, befund))
    }
}
