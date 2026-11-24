// Logic2Drive – legt Logic-Pro-Projekte als Zip in Google Drive ab und öffnet sie per Doppelklick.
//
// Google Drive kann unter macOS 27 keine Logic-Pakete hochladen. Der Helfer sorgt dafür, dass im
// Drive-Ordner nur noch Zips liegen:
//   Ablegen:      Neues Paket im beobachteten Ordner -> Name.logicx.zip, Paket wandert in die Sicherung.
//   Öffnen:       Name.logicx.zip -> lokal nach ~/Music/Logic/In Arbeit entpacken, in Logic öffnen.
//   Zurücklegen:  Projekt geschlossen + Ruhezeit -> neu packen, Zip im selben Ordner ersetzen.
//   Konflikt:     Hat sich die Zip inzwischen geändert, wird nichts überschrieben, sondern daneben gelegt.
//
// Grundsätze: Nichts wird endgültig gelöscht. Jede Zip wird vor dem Einsetzen entpackt und mit dem
// Original verglichen. Eine lokale Kopie wird erst weggeräumt, wenn der Upload bestätigt ist.

import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation
import Network
import ServiceManagement
import UniformTypeIdentifiers

// helferVersion steht in der Datei VERSION; bauen.sh schreibt daraus build/version.swift.
let projektSeite = "https://github.com/joshinilles/logic2drive"
let fm = FileManager.default
let heim = NSHomeDirectory()
let umgebung = ProcessInfo.processInfo.environment
let datenOrdner = umgebung["LOGIC2DRIVE_DATEN"] ?? heim + "/Library/Application Support/Logic2Drive"
let logicID = "com.apple.logic10"
let datalessFlag: UInt32 = 0x40000000
let still = umgebung["LOGIC2DRIVE_STILL"] == "1"

struct HelferFehler: Error, CustomStringConvertible {
    let description: String
    init(_ t: String) { description = t }
}

func jetzt() -> Double { Date().timeIntervalSince1970 }

// MARK: - Protokoll und Meldungen

let protokollSperre = NSLock()
func protokoll(_ t: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let zeile = "\(f.string(from: Date()))  \(t)\n"
    protokollSperre.lock()
    defer { protokollSperre.unlock() }
    // Die werfenden Varianten: Eine volle Platte darf den Helfer nicht beenden.
    try? FileHandle.standardOutput.write(contentsOf: Data(zeile.utf8))
    let pfad = datenOrdner + "/protokoll.log"
    if let h = FileHandle(forWritingAtPath: pfad) {
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(zeile.utf8))
        try? h.close()
    } else {
        try? Data(zeile.utf8).write(to: URL(fileURLWithPath: pfad))
    }
}

@discardableResult
func lauf(_ programm: String, _ argumente: [String], frist: TimeInterval? = nil) -> (code: Int32, text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: programm)
    p.arguments = argumente
    let rohr = Pipe()
    p.standardOutput = rohr
    p.standardError = rohr
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    var abbruch: DispatchWorkItem?
    if let frist {
        let w = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + frist, execute: w)
        abbruch = w
    }
    let daten = rohr.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    abbruch?.cancel()
    return (p.terminationStatus, String(decoding: daten, as: UTF8.self))
}

func melde(_ text: String) {
    protokoll("MELDUNG: \(text)")
    if still { return }
    lauf("/usr/bin/osascript", ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"Logic2Drive\"", "-e", "end run", text], frist: 10)
}

/// Die letzte Meldung aus dem Protokoll, für die Zeile „Zuletzt“ im Menü.
/// Aus der Datei gelesen, damit sie auch nach einem Neustart des Helfers stimmt.
func letzteMeldung(pfad: String = datenOrdner + "/protokoll.log", heute: Date = Date()) -> String? {
    guard let h = FileHandle(forReadingAtPath: pfad) else { return nil }
    defer { try? h.close() }
    let ende = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: ende > 65536 ? ende - 65536 : 0)
    guard let daten = try? h.readToEnd() else { return nil }
    let marke = "  MELDUNG: "
    for zeile in String(decoding: daten, as: UTF8.self).split(separator: "\n").reversed() {
        guard let r = zeile.range(of: marke) else { continue }
        let ein = DateFormatter()
        ein.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let wann = ein.date(from: String(zeile[..<r.lowerBound])) else { continue }
        let aus = DateFormatter()
        let kal = Calendar.current
        let tage = kal.dateComponents([.day], from: kal.startOfDay(for: wann), to: kal.startOfDay(for: heute)).day ?? 99
        aus.dateFormat = tage == 0 || tage == 1 ? "HH:mm" : "dd.MM. HH:mm"
        let zeit = aus.string(from: wann), was = String(zeile[r.upperBound...])
        // Ganze Sätze je Fall, damit sich die Wortstellung übersetzen lässt.
        return tage == 0 ? L("Zuletzt, heute \(zeit): \(was)") : tage == 1 ? L("Zuletzt, gestern \(zeit): \(was)") : L("Zuletzt, \(zeit): \(was)")
    }
    return nil
}

// MARK: - Dateisystem

func info(_ p: String) -> stat? {
    var s = stat()
    return lstat(p, &s) == 0 ? s : nil
}
func istOrdner(_ s: stat) -> Bool { (s.st_mode & S_IFMT) == S_IFDIR }
func istDatei(_ s: stat) -> Bool { (s.st_mode & S_IFMT) == S_IFREG }
func istDataless(_ s: stat) -> Bool { (s.st_flags & datalessFlag) != 0 }
func aenderungszeit(_ s: stat) -> Double { Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9 }
func letzter(_ p: String) -> String { (p as NSString).lastPathComponent }

/// Projektname ohne Endung: Logic nennt Dokumente je nach Finder-Einstellung mit oder ohne `.logicx`.
func dokName(_ n: String) -> String {
    let k = n.trimmingCharacters(in: .whitespacesAndNewlines)
    return k.lowercased().hasSuffix(".logicx") ? String(k.dropLast(".logicx".count)) : k
}
func offenIn(_ offen: Set<String>, _ namen: String...) -> Bool { namen.contains { offen.contains(dokName($0)) } }

struct Abdruck {
    var hash = ""
    var neueste = 0.0
    var bytes: Int64 = 0
    var dateien = 0
    var hatLink = false
    var hatDataless = false
}

/// Fingerabdruck eines Pakets aus Pfad, Größe und Änderungszeit. Löst keine Downloads aus.
func abdruck(_ wurzel: String) -> Abdruck? {
    var a = Abdruck()
    var zeilen: [String] = []
    let grenze = jetzt() + 60    // Dateien mit Zukunftsdatum (falsche Recorder-Uhr) zählen nicht als „gerade geändert“
    func geh(_ p: String, _ rel: String) -> Bool {
        guard let namen = try? fm.contentsOfDirectory(atPath: p) else { return false }
        for n in namen where n != ".DS_Store" {
            let q = p + "/" + n
            let r = rel.isEmpty ? n : rel + "/" + n
            guard let s = info(q) else { return false }
            if istDataless(s) { a.hatDataless = true; continue }
            switch s.st_mode & S_IFMT {
            case S_IFDIR:
                if !geh(q, r) { return false }
            case S_IFREG:
                a.dateien += 1
                a.bytes += Int64(s.st_size)
                let zeit = aenderungszeit(s)
                if zeit <= grenze { a.neueste = max(a.neueste, zeit) }
                zeilen.append("\(r)|\(s.st_size)|\(s.st_mtimespec.tv_sec).\(s.st_mtimespec.tv_nsec)")
            default:
                a.hatLink = true
            }
        }
        return true
    }
    guard geh(wurzel, "") else { return nil }
    let text = zeilen.sorted().joined(separator: "\n")
    a.hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return a
}

func istProjekt(_ p: String) -> Bool {
    guard let a = info(p + "/Alternatives"), let r = info(p + "/Resources"), istOrdner(a), istOrdner(r) else { return false }
    if istDataless(a) { return false }
    guard let alt = try? fm.contentsOfDirectory(atPath: p + "/Alternatives") else { return false }
    return alt.contains { info(p + "/Alternatives/" + $0 + "/ProjectData") != nil }
}

func md5(_ p: String) -> String? {
    guard let h = FileHandle(forReadingAtPath: p) else { return nil }
    defer { try? h.close() }
    var m = Insecure.MD5()
    var lesefehler = false
    while true {
        let weiter: Bool = autoreleasepool {
            do {
                guard let d = try h.read(upToCount: 1 << 20), !d.isEmpty else { return false }
                m.update(data: d)
                return true
            } catch {
                lesefehler = true    // ein Abbruch darf nicht wie das Dateiende aussehen
                return false
            }
        }
        if !weiter { break }
    }
    if lesefehler { return nil }
    return m.finalize().map { String(format: "%02x", $0) }.joined()
}

func freierPlatz(_ p: String) -> Int64 {
    let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return v?.volumeAvailableCapacityForImportantUsage ?? 0
}

struct UploadStand {
    var hoch = false
    var laedt = false
    var fehler: String?
}

func uploadStand(_ p: String) -> UploadStand? {
    var u = URL(fileURLWithPath: p)
    u.removeAllCachedResourceValues()
    guard let v = try? u.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]) else { return nil }
    return UploadStand(hoch: v.ubiquitousItemIsUploaded ?? false,
                       laedt: v.ubiquitousItemIsUploading ?? false,
                       fehler: v.ubiquitousItemUploadingError?.localizedDescription)
}

func freierPfad(_ ordner: String, stamm: String, endung: String) -> String {
    var k = "\(ordner)/\(stamm)\(endung)"
    var n = 2
    while info(k) != nil {
        k = "\(ordner)/\(stamm) (\(n))\(endung)"
        n += 1
    }
    return k
}

/// Namensteil der Zips, die der Helfer vor dem Ersetzen in die Sicherung kopiert.
let ersetztMarke = " – ersetzt "

func zeitText() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "dd.MM. HH.mm"
    return f.string(from: Date())
}

func vorname() -> String {
    NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
}

// MARK: - Packen

struct Gepackt {
    let pfad: String
    let groesse: Int64
    let md5: String
    let ordner: String
    let abdruck: String     // Stand des Projekts, der in dieser Zip steckt
}

/// Packt ein Paket in eine Zip mit dem obersten Ordner `wurzel` und prüft sie Datei für Datei.
func packen(_ quelle: String, wurzel: String) throws -> Gepackt {
    guard let a = abdruck(quelle) else { throw HelferFehler(L("Projekt nicht lesbar: \(quelle)")) }
    if a.hatDataless { throw HelferFehler(L("Teile des Projekts sind nicht geladen")) }
    if a.hatLink { throw HelferFehler(L("Projekt enthält Verknüpfungen, die ich nicht übernehme")) }
    if freierPlatz(datenOrdner) < a.bytes * 22 / 10 + 500_000_000 { throw HelferFehler(L("Zu wenig freier Speicher")) }
    let w = datenOrdner + "/tmp/" + UUID().uuidString
    try fm.createDirectory(atPath: w, withIntermediateDirectories: true)
    var fertig = false
    defer { if !fertig { try? fm.removeItem(atPath: w) } }
    let kopie = w + "/" + wurzel
    if lauf("/bin/cp", ["-cpR", quelle, kopie]).code != 0 {
        try? fm.removeItem(atPath: kopie)
        let r = lauf("/usr/bin/ditto", [quelle, kopie])
        if r.code != 0 { throw HelferFehler(L("Kopieren fehlgeschlagen: \(r.text.prefix(160))")) }
    }
    // AppleDouble-Reste (`._name`, von exFAT oder Netzlaufwerken) überstehen keine Zip. Nur in der Kopie entfernen.
    let reste = lauf("/usr/bin/find", [kopie, "-type", "f", "-name", "._*", "-delete"])
    if reste.code != 0 { throw HelferFehler(L("Kopie nicht bereinigt: \(reste.text.prefix(160))")) }
    let zip = w + "/neu.zip"
    var r = lauf("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", kopie, zip])
    if r.code != 0 { throw HelferFehler(L("Packen fehlgeschlagen: \(r.text.prefix(160))")) }
    r = lauf("/usr/bin/unzip", ["-tqq", zip])
    if r.code != 0 { throw HelferFehler(L("Zip fehlerhaft: \(r.text.prefix(160))")) }
    let probe = w + "/probe"
    try fm.createDirectory(atPath: probe, withIntermediateDirectories: false)
    r = lauf("/usr/bin/ditto", ["-x", "-k", zip, probe])
    if r.code != 0 { throw HelferFehler(L("Probe-Entpacken fehlgeschlagen: \(r.text.prefix(160))")) }
    r = lauf("/usr/bin/diff", ["-rq", "-x", ".DS_Store", "-x", "._*", quelle, probe + "/" + wurzel])
    if r.code != 0 { throw HelferFehler(L("Zip weicht vom Projekt ab: \(r.text.prefix(200))")) }
    guard abdruck(quelle)?.hash == a.hash else { throw HelferFehler(L("Das Projekt hat sich beim Packen geändert")) }
    try? fm.removeItem(atPath: kopie)
    try? fm.removeItem(atPath: probe)
    guard let s = info(zip), let summe = md5(zip) else { throw HelferFehler(L("Zip nicht lesbar")) }
    fertig = true
    return Gepackt(pfad: zip, groesse: Int64(s.st_size), md5: summe, ordner: w, abdruck: a.hash)
}

func findeProjekt(_ wurzel: String) -> String? {
    if istProjekt(wurzel) { return wurzel }
    guard let e1 = try? fm.contentsOfDirectory(atPath: wurzel) else { return nil }
    for a in e1 where a != "__MACOSX" {
        let p = wurzel + "/" + a
        guard let s = info(p), istOrdner(s) else { continue }
        if istProjekt(p) { return p }
        for b in (try? fm.contentsOfDirectory(atPath: p)) ?? [] {
            let q = p + "/" + b
            if let t = info(q), istOrdner(t), istProjekt(q) { return q }
        }
    }
    return nil
}

// MARK: - Einstellungen und Zustand

struct Einstellungen: Codable {
    var ordner: [String]
    var arbeitsordner: String
    var sicherungsordner: String
    var ruheSekunden: Double
    var stabilSekunden: Double
    var hintergrund: Bool?
    var wachKarenzSekunden: Double?     // so lange ersetzt der Helfer nach Start, Aufwachen oder Netz-Rückkehr nichts in Drive
    var scanAbstandSekunden: Double?    // frühestens so oft geht der Helfer nach Änderungen durch die Ordner (Vorgabe 15)
    var aufbewahrungTage: Int?          // so lange bleiben Originale im Sicherungsordner (Vorgabe 90, 0 = immer)
    var ersetztTage: Int?               // so lange bleiben ersetzte Zips dort (Vorgabe 14, höchstens aufbewahrungTage)
}

/// Die Google-Drive-Konten dieses Macs. Wer „Google Drive beobachten“ einschaltet, beobachtet genau diese Ordner.
func driveWurzeln() -> [String] {
    let cs = heim + "/Library/CloudStorage"
    let konten = (try? fm.contentsOfDirectory(atPath: cs)) ?? []
    return konten.sorted().filter { $0.hasPrefix("GoogleDrive-") && !$0.contains("(") }.map { "\(cs)/\($0)" }
}

/// Legt eine nicht lesbare Datei unter neuem Namen beiseite, statt sie zu überschreiben.
@discardableResult
func legeBeiseite(_ pfad: String) -> Bool {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let stamm = (letzter(pfad) as NSString).deletingPathExtension + ".unlesbar-" + f.string(from: Date())
    let ziel = freierPfad((pfad as NSString).deletingLastPathComponent, stamm: stamm, endung: ".json")
    do {
        try fm.moveItem(atPath: pfad, toPath: ziel)
        protokoll(L("Nicht lesbare Datei beiseitegelegt: \(letzter(ziel))"))
        return true
    } catch {
        protokoll(L("Nicht lesbare Datei ließ sich nicht beiseitelegen: \(error)"))
        return false
    }
}

func standardEinstellungen() -> Einstellungen {
    // Ohne Einstellungen wird nichts beobachtet. Das Beobachten schaltet man im Menü bewusst ein.
    return Einstellungen(ordner: [],
                         arbeitsordner: heim + "/Music/Logic/In Arbeit",
                         sicherungsordner: heim + "/Music/Logic/Logic2Drive Sicherung",
                         ruheSekunden: 600,
                         stabilSekunden: 300,
                         hintergrund: nil)
}

/// Gesetzt, wenn `einstellungen.json` vorhanden, aber nicht ladbar ist. Dann wird kein Ordner beobachtet.
var einstellungsProblem: String?

func ladeEinstellungen() -> Einstellungen {
    try? fm.createDirectory(atPath: datenOrdner, withIntermediateDirectories: true)
    let pfad = datenOrdner + "/einstellungen.json"
    if fm.fileExists(atPath: pfad) {
        if let d = fm.contents(atPath: pfad), let e = try? JSONDecoder().decode(Einstellungen.self, from: d) { return e }
        // Vorhanden, aber nicht ladbar: nie still auf die Vorgaben (den Testordner) zurückfallen und nichts überschreiben.
        einstellungsProblem = L("Einstellungen nicht lesbar, es wird kein Ordner beobachtet")
        var e = standardEinstellungen()
        e.ordner = []
        return e
    }
    let e = standardEinstellungen()
    let k = JSONEncoder()
    k.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let d = try? k.encode(e) { try? d.write(to: URL(fileURLWithPath: pfad), options: .atomic) }
    return e
}

struct Auftrag: Codable {
    var id = UUID().uuidString
    var art: String              // "ablage" oder "arbeit"
    var name: String
    var phase: String            // "offen", "ruhe", "hochladen", "stubwache", "fehlt"
    var meldung = ""
    var problem: String?         // Dauerfehler, sichtbar am Symbol in der Menüleiste
    // Ablage
    var paket: String?
    var paketInode: UInt64?
    var stub: String?
    var stubBis: Double?
    var paketAbdruck: String?
    // Arbeit
    var quelleZip: String?
    var originalZip: String?     // die Zip, aus der ausgecheckt wurde; quelleZip kann auf die eigene Fassung wechseln
    var arbeitsPfad: String?
    var arbeitsInode: UInt64?
    var wurzelName: String?
    var basisGroesse: Int64?
    var basisDatum: Double?
    var basisMD5: String?
    var abdruckBeimOeffnen: String?
    var gesehenInLogic = false
    var geoeffnetAm: Double?
    var ruheSeit: Double?
    var sofort = false
    var markerPfad: String?
    // Upload
    var zielZip: String?
    var zielGroesse: Int64?
    var zielMD5: String?
    var gepacktAbdruck: String?
    var uploadSeit: Double?
    var uploadOffen = false      // der Stand in zielZip ist noch nicht als hochgeladen bestätigt
    var groesseFalsch = false    // Drive meldet für diese Zip eine falsche Größe, der Inhalt stimmt
    var fassungen = 0            // automatisch angelegte eigene Fassungen, begrenzt gegen Endlosschleifen
    var pauseBis: Double?
    var lesefehlerSeit: Double?  // seit wann die Arbeitskopie nicht lesbar ist
    var stabil = 0
    var abweichung = 0
    var konflikt = false
}

extension Auftrag {
    /// Liest auch Aufträge älterer Versionen: Fehlende Felder bekommen ihren Standardwert.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(art: try c.decode(String.self, forKey: .art),
                  name: try c.decode(String.self, forKey: .name),
                  phase: try c.decode(String.self, forKey: .phase))
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? id
        meldung = try c.decodeIfPresent(String.self, forKey: .meldung) ?? ""
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        paket = try c.decodeIfPresent(String.self, forKey: .paket)
        paketInode = try c.decodeIfPresent(UInt64.self, forKey: .paketInode)
        stub = try c.decodeIfPresent(String.self, forKey: .stub)
        stubBis = try c.decodeIfPresent(Double.self, forKey: .stubBis)
        paketAbdruck = try c.decodeIfPresent(String.self, forKey: .paketAbdruck)
        quelleZip = try c.decodeIfPresent(String.self, forKey: .quelleZip)
        originalZip = try c.decodeIfPresent(String.self, forKey: .originalZip)
        arbeitsPfad = try c.decodeIfPresent(String.self, forKey: .arbeitsPfad)
        arbeitsInode = try c.decodeIfPresent(UInt64.self, forKey: .arbeitsInode)
        wurzelName = try c.decodeIfPresent(String.self, forKey: .wurzelName)
        basisGroesse = try c.decodeIfPresent(Int64.self, forKey: .basisGroesse)
        basisDatum = try c.decodeIfPresent(Double.self, forKey: .basisDatum)
        basisMD5 = try c.decodeIfPresent(String.self, forKey: .basisMD5)
        abdruckBeimOeffnen = try c.decodeIfPresent(String.self, forKey: .abdruckBeimOeffnen)
        gesehenInLogic = try c.decodeIfPresent(Bool.self, forKey: .gesehenInLogic) ?? false
        geoeffnetAm = try c.decodeIfPresent(Double.self, forKey: .geoeffnetAm)
        ruheSeit = try c.decodeIfPresent(Double.self, forKey: .ruheSeit)
        sofort = try c.decodeIfPresent(Bool.self, forKey: .sofort) ?? false
        markerPfad = try c.decodeIfPresent(String.self, forKey: .markerPfad)
        zielZip = try c.decodeIfPresent(String.self, forKey: .zielZip)
        zielGroesse = try c.decodeIfPresent(Int64.self, forKey: .zielGroesse)
        zielMD5 = try c.decodeIfPresent(String.self, forKey: .zielMD5)
        gepacktAbdruck = try c.decodeIfPresent(String.self, forKey: .gepacktAbdruck)
        uploadSeit = try c.decodeIfPresent(Double.self, forKey: .uploadSeit)
        uploadOffen = try c.decodeIfPresent(Bool.self, forKey: .uploadOffen) ?? false
        stabil = try c.decodeIfPresent(Int.self, forKey: .stabil) ?? 0
        abweichung = try c.decodeIfPresent(Int.self, forKey: .abweichung) ?? 0
        groesseFalsch = try c.decodeIfPresent(Bool.self, forKey: .groesseFalsch) ?? false
        fassungen = try c.decodeIfPresent(Int.self, forKey: .fassungen) ?? 0
        pauseBis = try c.decodeIfPresent(Double.self, forKey: .pauseBis)
        lesefehlerSeit = try c.decodeIfPresent(Double.self, forKey: .lesefehlerSeit)
        konflikt = try c.decodeIfPresent(Bool.self, forKey: .konflikt) ?? false
    }
}

struct Marker: Codable {
    var wer: String
    var rechner: String
    var konto: String
    var seit: String
}

func eigenerRechner() -> String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

// MARK: - Der Helfer

final class Helfer {
    let q = DispatchQueue(label: "de.bibletunes.logic2drive")
    var e: Einstellungen
    var auftraege: [Auftrag] = []
    var kandidaten: [String: (abdruck: String, seit: Double)] = [:]
    var zeitgeber: DispatchSourceTimer?
    var strom: FSEventStreamRef?
    var scanFaellig = true
    var letzterScan = 0.0
    var letzteDokumente: (zeit: Double, namen: Set<String>?) = (0, nil)
    var logicFehlerSeit: Double?
    var zuletztGespeichert = Data()
    var geladen = false
    var speichernGesperrt = false
    var warnungen: [String: Double] = [:]
    var herkunft: [UInt64: String] = [:]    // Datei-ID -> Name, unter dem das Paket zuerst gesehen wurde
    var angehalten = false      // nach einem eingesetzten Update: nichts Neues mehr anfangen, gleich wird neu gestartet
    var inLogic: [String: (erst: Double, zuletzt: Double)] = [:]    // Projektname -> wann hier in Logic offen gesehen
    var letzteLogicSicht = 0.0
    var letzteSicherungsPflege = 0.0
    var ordnerGeaendert: (([String]) -> Void)?
    var letztesAufwachen = jetzt()
    var schlafStand = Helfer.schlafzeit()
    let netzSperre = NSLock()       // das Netz wird auf eigener Queue beobachtet, damit langes Packen es nicht verdeckt
    var netzDa = true
    var netzZurueckAm = 0.0
    var netz: NWPathMonitor?
    let wachSperre = NSLock()
    var letzterTakt = jetzt()
    var wachhund: DispatchSourceTimer?
    /// Rückfrage an den Nutzer. Die Antwort kommt später über den Rückruf, damit die Warteschlange nie auf einen Dialog wartet.
    var frage: ((String, String, @escaping (Bool) -> Void) -> Void)?
    var aktualisiert: (([Auftrag]) -> Void)?

    init() { e = ladeEinstellungen() }

    var zustandsPfad: String { datenOrdner + "/auftraege.json" }

    /// Gesamtzeit, die der Mac seit dem Systemstart geschlafen hat (Nanosekunden).
    static func schlafzeit() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) - Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    func sichereEinstellungen() -> Bool {
        guard einstellungsProblem == nil else { return false }
        let k = JSONEncoder()
        k.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try k.encode(e).write(to: URL(fileURLWithPath: datenOrdner + "/einstellungen.json"), options: .atomic)
            return true
        } catch {
            protokoll(L("Einstellungen nicht gespeichert: \(error)"))
            return false
        }
    }

    /// Stellt um, welche Ordner beobachtet werden (Menü „Google Drive beobachten“).
    func setzeOrdner(_ neu: [String]) {
        let alt = e.ordner
        e.ordner = neu
        guard sichereEinstellungen() else {
            e.ordner = alt
            melde(L("Die Einstellung ließ sich nicht speichern. Es bleibt alles, wie es war."))
            return
        }
        if let s = strom {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            strom = nil
        }
        kandidaten = [:]
        startEreignisse()
        scanFaellig = true
        letzterScan = 0
        protokoll(L("Beobachtet jetzt: \(neu.isEmpty ? L("nichts") : neu.joined(separator: ", "))"))
        ordnerGeaendert?(neu)
    }

    /// Geladene Logic-Pakete unter den Ordnern, die nicht sauber in der Cloud liegen. Nur lesend.
    func haengendePakete(in wurzeln: [String]) -> [String] {
        var treffer: [String] = []
        func geh(_ d: String) {
            guard let namen = try? fm.contentsOfDirectory(atPath: d) else { return }
            for n in namen where !n.hasPrefix(".") {
                let p = d + "/" + n
                guard let s = info(p), istOrdner(s), !istDataless(s) else { continue }
                guard n.lowercased().hasSuffix(".logicx") else { geh(p); continue }
                guard istProjekt(p), let st = uploadStand(p) else { continue }
                if !(st.hoch && !st.laedt && st.fehler == nil) { treffer.append(p) }
            }
        }
        for w in wurzeln { geh(w) }
        return treffer
    }

    /// Originale im Sicherungsordner wandern nach der Aufbewahrungsfrist in den Papierkorb.
    func raeumeSicherung() {
        letzteSicherungsPflege = jetzt()
        let tage = e.aufbewahrungTage ?? 90
        guard tage > 0, let namen = try? fm.contentsOfDirectory(atPath: e.sicherungsordner) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        // Ersetzte Zips sind ganze Projekte und kommen bei jedem Zurücklegen dazu: kürzer aufheben, sonst läuft die Platte voll.
        let tageErsetzt = min(tage, max(1, e.ersetztTage ?? 14))
        for n in namen where n.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            // Der Ordner trägt den Tag der Ablage. Erst nach vollen Tagen der Frist danach wird geräumt.
            guard let tag = f.date(from: n) else { continue }
            let alter = Date().timeIntervalSince(tag)
            let ordner = e.sicherungsordner + "/" + n
            var bleibt = 0
            for eintrag in (try? fm.contentsOfDirectory(atPath: ordner)) ?? [] where eintrag != ".DS_Store" {
                let frist = eintrag.contains(ersetztMarke) ? tageErsetzt : tage
                guard alter > Double(frist + 1) * 86400 else { bleibt += 1; continue }
                do {
                    try fm.trashItem(at: URL(fileURLWithPath: ordner + "/" + eintrag), resultingItemURL: nil)
                    protokoll(L("Sicherung nach \(frist) Tagen in den Papierkorb gelegt: \(n)/\(eintrag)"))
                } catch {
                    bleibt += 1
                    protokoll(L("Sicherung nicht weggeräumt (\(n)/\(eintrag)): \(error)"))
                }
            }
            if bleibt == 0 {
                try? fm.removeItem(atPath: ordner + "/.DS_Store")
                rmdir(ordner)       // entfernt den Tagesordner nur, wenn er jetzt leer ist
            }
        }
    }

    /// Meldet einen Dauerfehler sichtbar, höchstens einmal pro Stunde und Anlass.
    func warne(_ anlass: String, _ text: String) {
        let t = jetzt()
        if t - (warnungen[anlass] ?? 0) < 3600 { return }
        warnungen[anlass] = t
        melde(text)
    }

    func lade() {
        guard !geladen else { return }
        geladen = true
        guard fm.fileExists(atPath: zustandsPfad) else { return }
        guard let d = fm.contents(atPath: zustandsPfad) else {
            speichernGesperrt = true
            warne("zustand", L("Die Auftragsliste ist nicht lesbar. Logic2Drive speichert nichts mehr, bis das geklärt ist."))
            return
        }
        do {
            auftraege = try JSONDecoder().decode([Auftrag].self, from: d)
            zuletztGespeichert = d
        } catch {
            protokoll(L("Auftragsliste nicht lesbar: \(error)"))
            if legeBeiseite(zustandsPfad) {
                warne("zustand", L("Die Auftragsliste war nicht lesbar und wurde beiseitegelegt. Prüfe bitte, ob in „In Arbeit“ noch Projekte liegen."))
            } else {
                speichernGesperrt = true
                warne("zustand", L("Die Auftragsliste ist nicht lesbar. Logic2Drive speichert nichts mehr, bis das geklärt ist."))
            }
        }
    }

    func sichere() {
        if speichernGesperrt { aktualisiert?(auftraege); return }
        let k = JSONEncoder()
        k.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let d = try? k.encode(auftraege), d != zuletztGespeichert else { return }
        do {
            try d.write(to: URL(fileURLWithPath: zustandsPfad), options: .atomic)
            zuletztGespeichert = d
        } catch {
            warne("speichern", L("Logic2Drive kann seinen Stand nicht speichern. Ist die Platte voll?"))
        }
        aktualisiert?(auftraege)
    }

    func start() {
        q.async { [self] in
            lade()
            try? fm.removeItem(atPath: datenOrdner + "/tmp")
            try? fm.createDirectory(atPath: datenOrdner + "/eingang", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: e.arbeitsordner, withIntermediateDirectories: true)
            protokoll(L("Logic2Drive \(helferVersion) gestartet. Beobachtet: \(e.ordner.joined(separator: ", "))"))
            raeumeSicherung()
            ordnerGeaendert?(e.ordner)
            if einstellungsProblem != nil {
                warne("einstellungen", L("Die Einstellungen von Logic2Drive sind nicht lesbar. Bis einstellungen.json repariert ist, wird kein Ordner beobachtet."))
            }
            for o in e.ordner where info(o).map({ !istOrdner($0) }) ?? true {
                warne("ordner-fehlt:\(o)", L("Der beobachtete Ordner „\(letzter(o))“ ist nicht da. Neue Projekte dort werden nicht eingepackt."))
            }
            aktualisiert?(auftraege)
            letztesAufwachen = jetzt()
            startEreignisse()
            startNetz()
            startWachhund()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 1, repeating: 2)
            t.setEventHandler { [weak self] in self?.takt() }
            t.resume()
            zeitgeber = t
        }
    }

    func startEreignisse() {
        guard !e.ordner.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let rueckruf: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Helfer>.fromOpaque(info).takeUnretainedValue().scanFaellig = true
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, rueckruf, &ctx, e.ordner as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, q)
        FSEventStreamStart(s)
        strom = s
    }

    func startNetz() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] pfad in
            guard let self else { return }
            let da = pfad.status == .satisfied
            self.netzSperre.lock()
            let zurueck = da && !self.netzDa
            if zurueck { self.netzZurueckAm = jetzt() }
            self.netzDa = da
            self.netzSperre.unlock()
            if zurueck { protokoll(L("Internet ist wieder da, Drive bekommt Zeit zum Abgleichen")) }
        }
        m.start(queue: DispatchQueue(label: "de.bibletunes.logic2drive.netz"))
        netz = m
    }

    /// Meldet, wenn die Warteschlange lange an einem Schritt hängt (etwa an einem Download von Drive ohne Netz).
    func startWachhund() {
        let w = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "de.bibletunes.logic2drive.wachhund"))
        w.schedule(deadline: .now() + 60, repeating: 60)
        var zuLang = 0
        w.setEventHandler { [weak self] in
            guard let self else { return }
            self.wachSperre.lock()
            let alter = jetzt() - self.letzterTakt
            self.wachSperre.unlock()
            zuLang = alter > 1800 ? zuLang + 1 : 0
            if zuLang == 2 {     // zweimal hintereinander: kein Fehlalarm direkt nach dem Aufwachen
                melde(L("Logic2Drive hängt seit über 30 Minuten an einem Schritt und wartet vielleicht auf Google Drive. Deine Arbeit bleibt lokal erhalten."))
            }
        }
        w.resume()
        wachhund = w
    }

    /// Erkennt Schlaf über die Systemuhren, auch mitten in langer Arbeit. Danach gelten Upload-Meldungen als ungeprüft.
    func pruefeSchlaf() {
        let schlaf = Helfer.schlafzeit()
        defer { schlafStand = schlaf }
        guard schlaf - schlafStand > 5_000_000_000 else { return }
        letztesAufwachen = jetzt()
        for a in auftraege where a.phase == "hochladen" {
            aendere(a.id) { $0.uploadSeit = jetzt(); $0.stabil = 0 }
        }
        protokoll(L("Mac ist aufgewacht, Drive bekommt Zeit zum Abgleichen"))
    }

    /// nil heißt: Drive hatte Zeit, fremde Änderungen zu holen. Sonst der Grund zum Warten.
    /// Die Konfliktprüfung sieht nur die lokale Kopie, deshalb wird nach Schlaf oder Funkloch nicht sofort ersetzt.
    func driveNichtBereit() -> String? {
        pruefeSchlaf()
        netzSperre.lock()
        let da = netzDa
        let zurueck = netzZurueckAm
        netzSperre.unlock()
        if !da { return L("Warte auf Internet") }
        let rest = (e.wachKarenzSekunden ?? 180) - (jetzt() - max(letztesAufwachen, zurueck))
        return rest > 0 ? L("Drive gleicht noch ab (noch \(Int(rest.rounded(.up))) s)") : nil
    }

    // MARK: Takt

    func takt() {
        wachSperre.lock()
        letzterTakt = jetzt()
        wachSperre.unlock()
        if angehalten { return }
        pruefeSchlaf()
        pruefeEingang()
        let t = jetzt()
        if t - letzteSicherungsPflege > 6 * 3600 { raeumeSicherung() }
        // Regelmäßig fragen, was in Logic offen ist: Daran erkennt der Helfer Projekte, an denen hier gearbeitet wird.
        if !e.ordner.isEmpty, t - letzteLogicSicht >= 10 {
            letzteLogicSicht = t
            let vorher = inLogic.count
            _ = offeneDokumente()
            if inLogic.count > vorher { scanFaellig = true }
        }
        // Ein Durchlauf über ein ganzes Drive dauert Sekunden, deshalb nicht bei jeder Änderung, sondern mit Abstand.
        if (scanFaellig && t - letzterScan >= (e.scanAbstandSekunden ?? 15)) || t - letzterScan > 60 {
            scanFaellig = false
            letzterScan = t
            scan()
            let dauer = jetzt() - t
            if dauer > 10, t - (warnungen["scan-dauer"] ?? 0) > 3600 {
                warnungen["scan-dauer"] = t
                protokoll(L("Ein Durchlauf über die beobachteten Ordner hat \(Int(dauer)) Sekunden gedauert"))
            }
        } else if !kandidaten.isEmpty {
            // Dazwischen nur die Pakete ansehen, die gerade auf das Einpacken warten.
            for p in Array(kandidaten.keys) {
                var g = Set<String>()
                if let s = info(p), istOrdner(s), !istDataless(s) { pruefeKandidat(p, &g) }
                if !g.contains(p) { kandidaten[p] = nil }
            }
        }
        for id in auftraege.map(\.id) {
            guard let a = auftraege.first(where: { $0.id == id }) else { continue }
            if a.phase == "hochladen" {
                pruefeUpload(id)
            } else if a.phase == "stubwache" {
                pruefeStubwache(id)
            } else if a.art == "arbeit" {
                pruefeArbeit(id)
            }
        }
        sichere()
    }

    func pruefeEingang() {
        let ordner = datenOrdner + "/eingang"
        guard let namen = try? fm.contentsOfDirectory(atPath: ordner) else { return }
        for n in namen.sorted() where n.hasSuffix(".json") {
            let p = ordner + "/" + n
            defer { try? fm.removeItem(atPath: p) }
            guard let d = fm.contents(atPath: p),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let zip = o["zip"] as? String else { continue }
            oeffne(zip, trotzdem: o["trotzdem"] as? Bool ?? false)
        }
    }

    /// Läuft Logic? Gefragt wird nach dem Prozessnamen UND nach der Bundle-ID, weil der Prozess je nach
    /// Version anders heißen kann. Nur zwei eindeutige „nein“ zählen als beendet, jeder Fehler gilt als „läuft“.
    func logicLaeuft() -> Bool {
        if lauf("/usr/bin/pgrep", ["-x", "Logic Pro"], frist: 5).code != 1 { return true }
        let r = lauf("/usr/bin/lsappinfo", ["find", "bundleid=\(logicID)"], frist: 5)
        return !(r.code == 0 && r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Offene Logic-Dokumente als Namen ohne Endung. nil heißt: unbekannt (dann wird nichts entschieden).
    /// `frisch` umgeht den 4-Sekunden-Zwischenspeicher: Pflicht vor allem, was ein Projekt wegräumt oder ersetzt.
    func offeneDokumente(frisch: Bool = false) -> Set<String>? {
        let t = jetzt()
        if !frisch, t - letzteDokumente.zeit < 4 { return letzteDokumente.namen }
        var namen: Set<String>?
        if !logicLaeuft() {
            namen = []
            logicFehlerSeit = nil
        } else {
            let r = lauf("/usr/bin/osascript", [
                "-e", "with timeout of 8 seconds",
                "-e", "if application id \"\(logicID)\" is running then",
                "-e", "tell application id \"\(logicID)\" to set n to name of documents",
                "-e", "set AppleScript's text item delimiters to linefeed",
                "-e", "return n as text",
                "-e", "end if",
                "-e", "return \"\"",
                "-e", "end timeout"], frist: 12)
            if r.code == 0 {
                let offen = Set(r.text.split(whereSeparator: \.isNewline).map { dokName(String($0)) })
                namen = offen
                logicFehlerSeit = nil
                for n in offen { inLogic[n] = (inLogic[n]?.erst ?? t, t) }
                for (n, sicht) in inLogic where t - sicht.zuletzt > 3600 { inLogic[n] = nil }
            } else if r.text.contains("-1743") {
                warne("logic-freigabe", L("Logic2Drive darf Logic nicht abfragen. Erlaube es unter Systemeinstellungen > Datenschutz & Sicherheit > Automation. Bis dahin wird nichts zurückgelegt, solange Logic läuft."))
            } else {
                let seit = logicFehlerSeit ?? t
                logicFehlerSeit = seit
                if t - seit > 300 {
                    warne("logic-abfrage", L("Logic2Drive bekommt seit über 5 Minuten keine Antwort von Logic. Bis dahin wird nichts zurückgelegt."))
                }
            }
        }
        letzteDokumente = (t, namen)
        return namen
    }

    // MARK: Ablegen

    func scan() {
        var gefunden = Set<String>()
        for r in e.ordner { geh(r, &gefunden) }
        for k in kandidaten.keys where !gefunden.contains(k) { kandidaten[k] = nil }
    }

    func geh(_ d: String, _ g: inout Set<String>) {
        guard let namen = try? fm.contentsOfDirectory(atPath: d) else { return }
        for n in namen where !n.hasPrefix(".") {
            let p = d + "/" + n
            guard let s = info(p), istOrdner(s), !istDataless(s) else { continue }
            if n.lowercased().hasSuffix(".logicx") {
                pruefeKandidat(p, &g)
            } else {
                geh(p, &g)
            }
        }
    }

    func pruefeKandidat(_ p: String, _ g: inout Set<String>) {
        let ordner = (p as NSString).deletingLastPathComponent
        let voll = (letzter(p) as NSString).deletingPathExtension
        let ino = info(p).map { UInt64($0.st_ino) }
        // Läuft für genau dieses Paket schon ein Auftrag? Drive behält beim Umbenennen die Datei-ID.
        if auftraege.contains(where: { a in
            a.art == "ablage" && a.paket.map { ($0 as NSString).deletingLastPathComponent } == ordner
                && (a.name == voll || (ino != nil && a.paketInode == ino))
        }) { return }
        guard istProjekt(p), let st = uploadStand(p) else { return }
        let sauber = st.hoch && !st.laedt && st.fehler == nil
        var vorab: Abdruck?
        if sauber && kandidaten[p] == nil {
            // Liegt normal in der Cloud. Eingepackt wird es trotzdem, wenn HIER daran gearbeitet wurde: in Logic
            // offen gesehen und seitdem (oder kurz davor) gespeichert. So bleibt das Archiv liegen, und ein Mac,
            // der ein Projekt nur herunterlädt, packt nicht mit. Wer den Upload gerade noch laufen sah, hat das
            // Paket schon als Kandidaten und kommt gar nicht erst hierher.
            guard let sicht = inLogic[dokName(voll)], let a = abdruck(p), a.neueste > sicht.erst - 600 else { return }
            vorab = a
        }
        g.insert(p)
        if let ino, herkunft[ino] == nil { herkunft[ino] = voll }
        guard let a = vorab ?? abdruck(p), !a.hatDataless else { return }
        if a.hatLink {
            warne("link:\(p)", L("„\(voll)“ enthält Verknüpfungen und kann nicht automatisch eingepackt werden."))
            return
        }
        let t = jetzt()
        guard let k = kandidaten[p], k.abdruck == a.hash else {
            kandidaten[p] = (a.hash, t)
            protokoll(L("Neues Paket erkannt: \(letzter(p))"))
            return
        }
        guard t - k.seit >= e.stabilSekunden, t - a.neueste >= e.stabilSekunden else { return }
        let (basis, stub) = basisUndStub(p)
        guard let offen = offeneDokumente(frisch: true) else { return }
        if offenIn(offen, letzter(p), basis) {
            kandidaten[p] = (a.hash, t)     // die Ruhezeit beginnt erst nach dem Schließen
            return
        }
        if sauber { protokoll(L("\(letzter(p)) liegt schon in der Cloud und wird trotzdem eingepackt, weil hier daran gearbeitet wurde")) }
        uebernimm(p, abdruck: a, basis: basis, stub: stub, inode: ino)
        kandidaten[p] = nil
    }

    func ohneZaehler(_ name: String) -> String {
        if let m = name.range(of: #" \d+$"#, options: .regularExpression) { return String(name[..<m.lowerBound]) }
        return name
    }

    /// Sucht das Paket, nachdem Drive es umbenannt hat. Drive nimmt die nächste freie Nummer („Folge 12“ wird
    /// zu „Folge 16“, wenn 13 bis 15 belegt sind; gemessen 23.11.2026). Nur ein sicherer Treffer zählt
    /// (gleiche Datei-ID oder gleicher Inhalt), sonst könnte ein eigenständiges Projekt erwischt werden.
    func umbenanntesPaket(ordner: String, basis: String, abdruck gesucht: String?, inode: UInt64?) -> String? {
        guard let namen = try? fm.contentsOfDirectory(atPath: ordner) else { return nil }
        let treffer = namen.filter { n in
            guard n.hasSuffix(".logicx") else { return false }
            let k = String(n.dropLast(".logicx".count))
            guard k != basis, ohneZaehler(k) == ohneZaehler(basis), let s = info(ordner + "/" + n) else { return false }
            return istOrdner(s) && !istDataless(s) && istProjekt(ordner + "/" + n)
        }.map { ordner + "/" + $0 }
        if let inode, let t = treffer.first(where: { info($0).map { UInt64($0.st_ino) } == inode }) { return t }
        if let gesucht { return treffer.first { abdruck($0)?.hash == gesucht } }
        return nil
    }

    /// Kopiert die Zip, die gleich ersetzt wird, in die lokale Sicherung. Drives Versionsverlauf hat die alte
    /// Fassung in einer geteilten Ablage nicht aufgehoben (24.11.2026). Ohne geprüfte Kopie wird nicht ersetzt.
    func sichereAlteZip(_ zip: String, name: String, erwartet: String?) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let ordner = "\(e.sicherungsordner)/\(f.string(from: Date()))"
        try fm.createDirectory(atPath: ordner, withIntermediateDirectories: true)
        let ziel = freierPfad(ordner, stamm: "\(name)\(ersetztMarke)\(zeitText())", endung: ".logicx.zip")
        do { try fm.copyItem(atPath: zip, toPath: ziel) } catch {
            try? fm.removeItem(atPath: ziel)
            throw HelferFehler(L("Die bisherige Zip ließ sich nicht sichern: \(error.localizedDescription)"))
        }
        guard let summe = md5(ziel), erwartet == nil || summe == erwartet else {
            try? fm.removeItem(atPath: ziel)
            throw HelferFehler(L("Die Sicherung der bisherigen Zip ist unvollständig"))
        }
        protokoll(L("Bisherige Zip vor dem Ersetzen gesichert: \(ziel)"))
    }

    func ersetzeInDrive(_ ziel: String, mit neu: String) throws {
        var fehler: NSError?
        var problem: String?
        NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: ziel), options: .forReplacing, error: &fehler) { u in
            do { _ = try fm.replaceItemAt(u, withItemAt: URL(fileURLWithPath: neu)) } catch { problem = "\(error)" }
        }
        if let fehler { throw HelferFehler(L("Drive-Datei nicht ersetzbar: \(fehler.localizedDescription)")) }
        if let problem { throw HelferFehler(L("Drive-Datei nicht ersetzbar: \(problem)")) }
    }

    func basisUndStub(_ p: String) -> (String, String?) {
        let ordner = (p as NSString).deletingLastPathComponent
        let voll = (letzter(p) as NSString).deletingPathExtension
        guard let paket = info(p) else { return (voll, nil) }
        // 1. Der Helfer hat das Paket schon unter seinem ursprünglichen Namen gesehen.
        if let k = herkunft[UInt64(paket.st_ino)], k != voll {
            let s = "\(ordner)/\(k).logicx"
            if let i = info(s), istDatei(i), i.st_size == 0 { return (k, s) }
        }
        // 2. Sonst: Drive legt die leere Datei im selben Moment an, in dem es das Paket umbenennt. Beide tragen dann
        //    dasselbe Änderungsdatum und dieselbe Statuszeit (gemessen 23.11.2026). Nur ein eindeutiger Treffer zählt.
        let stamm = ohneZaehler(voll)
        guard stamm != voll, let namen = try? fm.contentsOfDirectory(atPath: ordner) else { return (voll, nil) }
        let treffer = namen.compactMap { n -> String? in
            guard n.hasSuffix(".logicx") else { return nil }
            let k = String(n.dropLast(".logicx".count))
            guard k != voll, ohneZaehler(k) == stamm, let i = info(ordner + "/" + n), istDatei(i), i.st_size == 0,
                  abs(aenderungszeit(i) - aenderungszeit(paket)) < 1,
                  abs(Int(i.st_ctimespec.tv_sec) - Int(paket.st_ctimespec.tv_sec)) < 2 else { return nil }
            return k
        }
        if treffer.count == 1 { return (treffer[0], "\(ordner)/\(treffer[0]).logicx") }
        return (voll, nil)
    }

    func uebernimm(_ p: String, abdruck a: Abdruck, basis: String, stub: String?, inode: UInt64?) {
        let ordner = (p as NSString).deletingLastPathComponent
        do {
            let z = try packen(p, wurzel: basis + ".logicx")
            defer { try? fm.removeItem(atPath: z.ordner) }
            var ziel = "\(ordner)/\(basis).logicx.zip"
            if info(ziel) != nil {
                ziel = freierPfad(ordner, stamm: "\(basis) – Stand \(vorname()) \(zeitText())", endung: ".logicx.zip")
            }
            try fm.moveItem(atPath: z.pfad, toPath: ziel)
            var auftrag = Auftrag(art: "ablage", name: basis, phase: "hochladen")
            auftrag.paket = p
            auftrag.paketInode = inode      // von vor dem Packen: Danach kann unter dem Pfad schon Drives leere Datei liegen
            auftrag.konflikt = letzter(ziel) != basis + ".logicx.zip"
            auftrag.stub = stub
            auftrag.paketAbdruck = z.abdruck
            auftrag.gepacktAbdruck = z.abdruck
            auftrag.zielZip = ziel
            auftrag.zielGroesse = z.groesse
            auftrag.zielMD5 = z.md5
            auftrag.uploadSeit = jetzt()
            auftrag.meldung = L("Zip wird hochgeladen")
            auftraege.append(auftrag)
            protokoll(L("Eingepackt: \(basis) -> \(letzter(ziel)), \(z.groesse) Byte"))
            sichere()
        } catch {
            protokoll(L("Einpacken fehlgeschlagen (\(basis)): \(error)"))
            // Hat Drive das Paket beim Packen umbenannt, ist das kein Fehler für den Nutzer: Der nächste Scan versucht es neu.
            if let s = info(p), istOrdner(s), abdruck(p)?.hash == a.hash {
                warne("packen:\(p)", L("„\(basis)“ ließ sich nicht einpacken: \(error)"))
            }
            kandidaten[p] = nil
        }
    }

    func fertigAblage(_ a: Auftrag) {
        guard var paket = a.paket else { entferne(a.id); return }
        let driveOrdner = (paket as NSString).deletingLastPathComponent
        var aktuell: Abdruck?
        if let s = info(paket), istOrdner(s) {
            guard let gelesen = abdruck(paket) else {
                aendere(a.id) { $0.stabil = 0; $0.meldung = L("Paket gerade nicht lesbar, neuer Versuch folgt") }
                return
            }
            aktuell = gelesen
        }
        if aktuell == nil, let neu = umbenanntesPaket(ordner: driveOrdner, basis: a.name, abdruck: a.paketAbdruck, inode: a.paketInode) {
            protokoll(L("Drive hat \(a.name) umbenannt in \(letzter(neu)), ich führe das Paket weiter"))
            paket = neu
            aendere(a.id) { $0.paket = neu }
            aktuell = abdruck(neu)
        }
        guard let stand = aktuell else {
            protokoll(L("Paket \(a.name) liegt nicht mehr im Drive-Ordner, die Zip bleibt"))
            entferne(a.id)
            return
        }
        // Unmittelbar vor dem Wegräumen frisch fragen: Das Paket kann inzwischen in Logic offen sein.
        guard let offen = offeneDokumente(frisch: true) else {
            aendere(a.id) { $0.stabil = 0; $0.meldung = L("Kann Logic gerade nicht abfragen, das Paket bleibt liegen") }
            return
        }
        if offenIn(offen, letzter(paket), a.name) {
            aendere(a.id) { $0.stabil = 0; $0.meldung = L("Ist in Logic offen, wird nach dem Schließen aufgeräumt") }
            return
        }
        if stand.hash != a.paketAbdruck {
            guard jetzt() - stand.neueste >= e.stabilSekunden else {
                aendere(a.id) { $0.stabil = 0; $0.meldung = L("Paket wurde gerade geändert, warte") }
                return
            }
            if let grund = driveNichtBereit() {
                aendere(a.id) { $0.stabil = 0; $0.meldung = grund }
                return
            }
            packeAblageNeu(a, paket: paket, stand: stand)
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let ordner = "\(e.sicherungsordner)/\(f.string(from: Date()))"
        do {
            try fm.createDirectory(atPath: ordner, withIntermediateDirectories: true)
            let ziel = freierPfad(ordner, stamm: a.name, endung: ".logicx")
            try fm.moveItem(atPath: paket, toPath: ziel)
            protokoll(L("Paket aus dem Drive-Ordner genommen: \(a.name), liegt in \(ziel)"))
            // Drive legt die leere Datei manchmal erst Sekunden später an.
            aendere(a.id) {
                $0.phase = "stubwache"
                $0.stub = "\(driveOrdner)/\(a.name).logicx"
                $0.stubBis = jetzt() + 60
                $0.problem = nil
                $0.meldung = L("Wird aufgeräumt")
            }
            pruefeStubwache(a.id)
        } catch {
            aendere(a.id) { $0.stabil = 0; $0.problem = "\(error)"; $0.meldung = L("Aufräumen fehlgeschlagen: \(error)") }
            protokoll(L("Aufräumen fehlgeschlagen (\(a.name)): \(error)"))
            warne("aufraeumen:\(a.id)", L("„\(a.name)“ liegt als Zip in Drive, das Paket ließ sich aber nicht wegräumen."))
        }
    }

    /// Das Paket hat sich nach dem Einpacken noch geändert: dieselbe Zip mit dem neuen Stand ersetzen.
    func packeAblageNeu(_ a: Auftrag, paket: String, stand: Abdruck) {
        guard let ziel = a.zielZip else { entferne(a.id); return }
        guard let summe = md5(ziel) else {
            aendere(a.id) { $0.stabil = 0; $0.pauseBis = jetzt() + 60; $0.meldung = L("Zip gerade nicht lesbar, neuer Versuch folgt") }
            return
        }
        guard summe == a.zielMD5 else {
            weichtAb(a, grund: L("Die Zip von \(a.name) wurde inzwischen von jemand anderem geändert"))
            return
        }
        do {
            let z = try packen(paket, wurzel: a.name + ".logicx")
            defer { try? fm.removeItem(atPath: z.ordner) }
            guard let offen = offeneDokumente(frisch: true), !offenIn(offen, letzter(paket), a.name) else {
                aendere(a.id) { $0.stabil = 0; $0.meldung = L("Ist in Logic offen, wird nach dem Schließen aufgeräumt") }
                return
            }
            if let grund = driveNichtBereit() {     // Schlaf oder Funkloch während des Packens
                aendere(a.id) { $0.stabil = 0; $0.meldung = grund }
                return
            }
            try ersetzeInDrive(ziel, mit: z.pfad)
            aendere(a.id) {
                $0.paketAbdruck = z.abdruck
                $0.gepacktAbdruck = z.abdruck
                $0.zielGroesse = z.groesse
                $0.zielMD5 = z.md5
                $0.uploadSeit = jetzt()
                $0.stabil = 0
                $0.abweichung = 0
                $0.problem = nil
                $0.meldung = L("Neuer Stand wird hochgeladen")
            }
            protokoll(L("Paket \(a.name) hat sich noch geändert, Zip neu gepackt: \(z.groesse) Byte"))
        } catch {
            protokoll(L("Neu packen fehlgeschlagen (\(a.name)): \(error)"))
            aendere(a.id) { $0.uploadSeit = jetzt(); $0.stabil = 0; $0.problem = "\(error)"; $0.meldung = L("Fehler, neuer Versuch folgt: \(error)") }
            warne("packen:\(a.id)", L("„\(a.name)“ ließ sich nicht neu einpacken: \(error)"))
        }
    }

    /// Legt den Stand als eigene Fassung neben die Zip, ohne etwas zu überschreiben.
    func eigeneFassung(_ id: String, von pfad: String, grund: String) {
        guard let a = auftraege.first(where: { $0.id == id }), let bezug = a.zielZip ?? a.quelleZip else { return }
        let ordner = (bezug as NSString).deletingLastPathComponent
        guard let o = info(ordner), istOrdner(o) else {
            aendere(id) { $0.stabil = 0; $0.abweichung = 0; $0.uploadSeit = jetzt(); $0.problem = L("Drive-Ordner fehlt"); $0.meldung = L("Der Drive-Ordner existiert nicht mehr") }
            warne("ordner:\(id)", L("Der Drive-Ordner von „\(a.name)“ existiert nicht mehr. Die lokale Kopie bleibt."))
            return
        }
        do {
            let z = try packen(pfad, wurzel: a.wurzelName ?? a.name + ".logicx")
            defer { try? fm.removeItem(atPath: z.ordner) }
            let ziel = freierPfad(ordner, stamm: "\(a.name) – Stand \(vorname()) \(zeitText())", endung: ".logicx.zip")
            try fm.moveItem(atPath: z.pfad, toPath: ziel)
            aendere(id) {
                $0.phase = "hochladen"
                $0.zielZip = ziel
                $0.zielGroesse = z.groesse
                $0.zielMD5 = z.md5
                $0.gepacktAbdruck = z.abdruck
                if $0.art == "ablage" { $0.paketAbdruck = z.abdruck }
                $0.uploadSeit = jetzt()
                $0.uploadOffen = false
                $0.stabil = 0
                $0.abweichung = 0
                $0.konflikt = true
                $0.fassungen += 1
                $0.groesseFalsch = false
                $0.pauseBis = nil
                $0.problem = nil
                $0.meldung = L("Konflikt: wird als eigene Fassung hochgeladen")
            }
            protokoll(L("KONFLIKT: \(grund). Neue Fassung daneben: \(letzter(ziel))"))
            sichere()
        } catch {
            protokoll(L("Eigene Fassung fehlgeschlagen (\(a.name)): \(error)"))
            aendere(id) { $0.stabil = 0; $0.abweichung = 0; $0.uploadSeit = jetzt(); $0.problem = "\(error)"; $0.meldung = L("Fehler, neuer Versuch folgt: \(error)") }
            warne("fassung:\(id)", L("Der Stand von „\(a.name)“ ließ sich nicht als eigene Fassung ablegen: \(error). Die lokale Kopie bleibt."))
        }
    }

    func pruefeStubwache(_ id: String) {
        guard let a = auftraege.first(where: { $0.id == id }), let s = a.stub else { return }
        if let i = info(s), istDatei(i), i.st_size == 0 {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: s), resultingItemURL: nil)
                protokoll(L("Leere Datei von Drive in den Papierkorb gelegt: \(letzter(s))"))
            } catch {
                protokoll(L("Leere Datei nicht entfernt: \(error)"))
            }
        } else if jetzt() < (a.stubBis ?? 0) {
            return
        }
        protokoll(L("Abgelegt: \(a.name)"))
        if a.konflikt {
            melde(L("„\(a.name)“ wurde inzwischen geändert. Dein Stand liegt als eigene Fassung daneben."))
        } else {
            melde(L("„\(a.name)“ liegt jetzt als Zip in Google Drive."))
        }
        entferne(id)
    }

    // MARK: Öffnen

    func oeffne(_ zip: String, trotzdem: Bool) {
        lade()      // falls das Öffnen vor dem Start ankommt: nie mit leerer Liste weiterarbeiten
        let name = letzter(zip)
        guard name.lowercased().hasSuffix(".logicx.zip") else { weiterreichen(zip); return }
        if let a = auftraege.first(where: { $0.art == "arbeit" && ($0.quelleZip == zip || $0.originalZip == zip) }) {
            if let w = aktuellerArbeitspfad(a) {
                protokoll(L("\(a.name) ist schon ausgecheckt, öffne die Arbeitskopie"))
                if a.konflikt, a.quelleZip != zip {
                    melde(L("Du öffnest deinen eigenen Stand von „\(a.name)“. Die neuere Fassung in der Zip kannst du öffnen, sobald dein Stand hochgeladen ist."))
                }
                if a.phase == "hochladen" {
                    zurueckInArbeit(a.id, gesehen: false, uploadBestaetigt: false)
                } else {
                    aendere(a.id) { $0.phase = "offen"; $0.gesehenInLogic = false; $0.geoeffnetAm = jetzt(); $0.ruheSeit = nil; $0.sofort = false }
                }
                sichere()
                zeigeInLogic(w)
                return
            }
            protokoll(L("Arbeitskopie von \(a.name) fehlt, der alte Auftrag wird aufgegeben und die Zip neu geöffnet"))
            entferne(a.id)
        }
        let marker = String(zip.dropLast(4)) + ".inarbeit"
        if let d = fm.contents(atPath: marker), let m = try? JSONDecoder().decode(Marker.self, from: d),
           !(m.rechner == eigenerRechner() && m.konto == NSUserName()), !trotzdem {
            let text = L("\(m.wer) arbeitet seit \(m.seit) auf „\(m.rechner)“ an diesem Projekt. Wenn du es trotzdem öffnest, entstehen zwei Fassungen.")
            guard let frage else {
                protokoll(L("Nicht geöffnet, in Arbeit bei \(m.wer): \(name)"))
                return
            }
            // Die Warteschlange wartet nicht auf den Dialog: Die Antwort kommt als neuer Aufruf zurück.
            frage(L("„\(name)“ ist gerade in Arbeit"), text) { [weak self] ja in
                self?.q.async {
                    if ja { self?.oeffne(zip, trotzdem: true) } else { protokoll(L("Nicht geöffnet, in Arbeit bei \(m.wer): \(name)")) }
                }
            }
            return
        }
        do {
            let a = try auschecken(zip, marker: marker)
            auftraege.append(a)
            sichere()
            zeigeInLogic(a.arbeitsPfad!)
        } catch {
            melde(L("„\(name)“ ließ sich nicht öffnen: \(error)"))
        }
    }

    func auschecken(_ zip: String, marker: String) throws -> Auftrag {
        let name = letzter(zip)
        let stamm = String(name.dropLast(".logicx.zip".count))
        // Die Sperre kommt zuerst, vor Laden und Entpacken. Lässt sie sich nicht anlegen, wird nicht geöffnet:
        // Ohne Sperre würden zwei Personen unbemerkt parallel arbeiten.
        let alteSperre = fm.contents(atPath: marker)
        try setzeSperre(marker)
        var ausgecheckt = false
        defer { if !ausgecheckt { nimmSperreZurueck(marker, vorher: alteSperre) } }
        let w = datenOrdner + "/tmp/" + UUID().uuidString
        try fm.createDirectory(atPath: w, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: w) }
        let kopie = w + "/quelle.zip"
        let vorher = info(zip)      // Datum VOR dem Laden: Eine währenddessen eingetroffene Fassung fällt so später auf
        var r = lauf("/usr/bin/ditto", [zip, kopie])       // lädt die Datei bei Bedarf herunter
        if r.code != 0 { throw HelferFehler(L("Laden fehlgeschlagen: \(r.text.prefix(160))")) }
        // Drive meldet gelegentlich verfälschte Größen, die unteren 32 Bit stimmen dann (gemessen). `unzip -t` prüft den Inhalt.
        guard let s = info(zip), let k = info(kopie), k.st_size > 0,
              UInt64(s.st_size) & 0xFFFF_FFFF == UInt64(k.st_size) & 0xFFFF_FFFF, let summe = md5(kopie) else {
            throw HelferFehler(L("Die Zip kam nicht vollständig an"))
        }
        if freierPlatz(datenOrdner) < Int64(k.st_size) * 3 + 500_000_000 { throw HelferFehler(L("Zu wenig freier Speicher")) }
        r = lauf("/usr/bin/unzip", ["-tqq", kopie])
        if r.code != 0 { throw HelferFehler(L("Die Zip ist beschädigt: \(r.text.prefix(160))")) }
        let aus = w + "/aus"
        try fm.createDirectory(atPath: aus, withIntermediateDirectories: false)
        r = lauf("/usr/bin/ditto", ["-x", "-k", kopie, aus])
        if r.code != 0 { throw HelferFehler(L("Entpacken fehlgeschlagen: \(r.text.prefix(160))")) }
        try? fm.removeItem(atPath: aus + "/__MACOSX")
        guard let projekt = findeProjekt(aus) else { throw HelferFehler(L("In der Zip steckt kein Logic-Projekt")) }
        guard let p = abdruck(projekt), !p.hatLink else { throw HelferFehler(L("Die Zip enthält Verknüpfungen, die ich nicht übernehme")) }
        try fm.createDirectory(atPath: e.arbeitsordner, withIntermediateDirectories: true)
        let ziel = freierPfad(e.arbeitsordner, stamm: stamm, endung: ".logicx")
        try fm.moveItem(atPath: projekt, toPath: ziel)
        guard let nachher = abdruck(ziel) else {
            try? fm.trashItem(at: URL(fileURLWithPath: ziel), resultingItemURL: nil)
            throw HelferFehler(L("Arbeitskopie nicht lesbar"))
        }
        ausgecheckt = true

        var a = Auftrag(art: "arbeit", name: stamm, phase: "offen")
        a.quelleZip = zip
        a.originalZip = zip
        a.arbeitsPfad = ziel
        a.arbeitsInode = info(ziel).map { UInt64($0.st_ino) }
        a.wurzelName = stamm + ".logicx"
        a.basisGroesse = Int64(k.st_size)
        a.basisDatum = aenderungszeit(vorher ?? s)
        a.basisMD5 = summe
        a.abdruckBeimOeffnen = nachher.hash
        a.geoeffnetAm = jetzt()
        a.markerPfad = marker
        a.meldung = L("Wird in Logic geöffnet")
        protokoll(L("Ausgecheckt: \(name) -> \(ziel)"))
        return a
    }

    /// Legt die eigene Sperre an und liest sie zur Kontrolle zurück. Wirft, wenn sie danach nicht sicher dasteht.
    func setzeSperre(_ marker: String) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM. HH:mm"
        let m = Marker(wer: NSFullUserName(), rechner: eigenerRechner(), konto: NSUserName(), seit: f.string(from: Date()))
        do {
            try JSONEncoder().encode(m).write(to: URL(fileURLWithPath: marker), options: .atomic)
        } catch {
            throw HelferFehler(L("Die Sperre im Drive-Ordner ließ sich nicht anlegen (\(error.localizedDescription))"))
        }
        guard let d = fm.contents(atPath: marker), let o = try? JSONDecoder().decode(Marker.self, from: d),
              o.rechner == eigenerRechner(), o.konto == NSUserName() else {
            throw HelferFehler(L("Die Sperre im Drive-Ordner ließ sich nicht anlegen"))
        }
    }

    /// Nach einem gescheiterten Auschecken: eigene Sperre wieder entfernen, eine zuvor fremde wiederherstellen.
    func nimmSperreZurueck(_ marker: String, vorher: Data?) {
        guard let d = fm.contents(atPath: marker), let o = try? JSONDecoder().decode(Marker.self, from: d),
              o.rechner == eigenerRechner(), o.konto == NSUserName() else { return }
        if let vorher, let alt = try? JSONDecoder().decode(Marker.self, from: vorher),
           !(alt.rechner == eigenerRechner() && alt.konto == NSUserName()) {
            try? vorher.write(to: URL(fileURLWithPath: marker), options: .atomic)
        } else {
            try? fm.removeItem(atPath: marker)
        }
    }

    func zeigeInLogic(_ p: String) {
        var argumente = ["-b", logicID, p]
        if e.hintergrund == true { argumente.insert("-g", at: 0) }
        let r = lauf("/usr/bin/open", argumente, frist: 30)
        if r.code != 0 {
            protokoll(L("Logic ließ sich nicht öffnen: \(r.text.prefix(160))"))
            warne("logic-oeffnen:\(p)", L("Logic ließ sich nicht öffnen. Die Arbeitskopie liegt im Arbeitsordner."))
        }
    }

    func weiterreichen(_ p: String) {
        let archiv = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: archiv, configuration: NSWorkspace.OpenConfiguration())
        protokoll(L("Keine Logic-Zip, ans Archivprogramm weitergereicht: \(letzter(p))"))
    }

    // MARK: Zurücklegen

    /// Liegt unter dem Pfad genau das Paket, das ausgecheckt wurde? Logic behält beim Sichern die Datei-ID
    /// des Pakets (gemessen 24.11.2026). Ein anderes Paket unter demselben Namen ist nicht die Arbeitskopie.
    func istArbeitskopie(_ a: Auftrag, _ pfad: String) -> Bool {
        guard let s = info(pfad), istOrdner(s) else { return false }
        return a.arbeitsInode == nil || UInt64(s.st_ino) == a.arbeitsInode
    }

    /// Aktueller Pfad der Arbeitskopie, auch wenn sie im Arbeitsordner umbenannt wurde. nil: Sie fehlt.
    func aktuellerArbeitspfad(_ a: Auftrag) -> String? {
        if let w = a.arbeitsPfad, istArbeitskopie(a, w) { return w }
        guard let neu = findeArbeitskopie(a) else { return nil }
        protokoll(L("Arbeitskopie von \(a.name) wurde umbenannt: \(letzter(neu))"))
        aendere(a.id) { $0.arbeitsPfad = neu }
        return neu
    }

    /// Findet eine im Arbeitsordner umbenannte Arbeitskopie an ihrer Datei-ID wieder.
    func findeArbeitskopie(_ a: Auftrag) -> String? {
        guard let ino = a.arbeitsInode, let namen = try? fm.contentsOfDirectory(atPath: e.arbeitsordner) else { return nil }
        for n in namen where n.lowercased().hasSuffix(".logicx") {
            let p = e.arbeitsordner + "/" + n
            if let s = info(p), istOrdner(s), UInt64(s.st_ino) == ino { return p }
        }
        return nil
    }

    func pruefeArbeit(_ id: String) {
        guard let a = auftraege.first(where: { $0.id == id }), var w = a.arbeitsPfad else { return }
        if istArbeitskopie(a, w) {
            // Aufträge aus älteren Versionen kennen die Datei-ID noch nicht: einmalig festhalten, nie umbiegen.
            if a.arbeitsInode == nil, let s = info(w) { aendere(id) { $0.arbeitsInode = UInt64(s.st_ino) } }
        } else if let neu = findeArbeitskopie(a) {
            protokoll(L("Arbeitskopie von \(a.name) wurde umbenannt: \(letzter(neu))"))
            aendere(id) { $0.arbeitsPfad = neu }
            w = neu
        } else {
            if a.phase != "fehlt" {
                let fremd = info(w) != nil
                let grund = fremd ? L("Anderes Paket am Platz der Arbeitskopie") : L("Arbeitskopie fehlt")
                protokoll("\(grund) (\(a.name)): \(w)")
                aendere(id) { $0.phase = "fehlt"; $0.ruheSeit = nil; $0.problem = grund; $0.meldung = grund }
                warne("fehlt:\(id)", fremd
                    ? L("Unter dem Namen der Arbeitskopie von „\(a.name)“ liegt ein anderes Paket. Logic2Drive packt es nicht ein. Leg das ursprüngliche Paket zurück oder gib den Auftrag im Menü auf.")
                    : L("Die Arbeitskopie von „\(a.name)“ ist nicht mehr im Arbeitsordner. Leg genau dieses Paket zurück, zum Beispiel aus dem Papierkorb, oder gib den Auftrag im Menü auf."))
            }
            return
        }
        if a.phase == "fehlt" {
            protokoll(L("Arbeitskopie von \(a.name) ist wieder da"))
            aendere(id) { $0.phase = "ruhe"; $0.ruheSeit = jetzt(); $0.problem = nil; $0.meldung = L("Geschlossen, wird gleich zurückgelegt") }
            return
        }
        guard let offen = offeneDokumente() else {
            aendere(id) { $0.meldung = L("Kann Logic gerade nicht abfragen") }
            return
        }
        let istOffen = offenIn(offen, letzter(w))
        switch a.phase {
        case "offen":
            if istOffen {
                if !a.gesehenInLogic { protokoll(L("In Logic geöffnet: \(a.name)")) }
                aendere(id) { $0.gesehenInLogic = true; $0.meldung = L("In Logic geöffnet") }
            } else if a.gesehenInLogic {
                protokoll(L("Geschlossen: \(a.name), warte \(Int(e.ruheSekunden)) Sekunden Ruhe"))
                aendere(id) { $0.phase = "ruhe"; $0.ruheSeit = jetzt(); $0.meldung = L("Geschlossen, wird gleich zurückgelegt") }
            } else if jetzt() - (a.geoeffnetAm ?? 0) > 120 {
                // Nie als offen erkannt. Automatisch weiter nur, wenn Logic nachweislich beendet ist:
                // Solange es läuft, kann das Projekt trotzdem offen sein, und die Kopie darf nicht weggeräumt werden.
                if !logicLaeuft() {
                    protokoll(L("\(a.name): Logic ist beendet, warte \(Int(e.ruheSekunden)) Sekunden Ruhe"))
                    aendere(id) { $0.phase = "ruhe"; $0.ruheSeit = jetzt(); $0.meldung = L("Geschlossen, wird gleich zurückgelegt") }
                } else if jetzt() - (a.geoeffnetAm ?? 0) > 900 {
                    aendere(id) { $0.meldung = L("Nicht als geöffnet erkannt") }
                    warne("nicht-gesehen:\(id)", L("„\(a.name)“ wurde nicht als geöffnet erkannt. Wenn du nicht daran arbeitest, wähle im Menü „Jetzt zurücklegen“."))
                }
            }
        case "ruhe":
            if istOffen {
                protokoll(L("Wieder geöffnet: \(a.name)"))
                aendere(id) { $0.phase = "offen"; $0.gesehenInLogic = true; $0.ruheSeit = nil; $0.sofort = false; $0.meldung = L("In Logic geöffnet") }
                return
            }
            guard let p = abdruck(w) else {
                // Ein einzelner Lesefehler heilt sich im nächsten Takt. Hält er an, muss er sichtbar werden.
                let seit = a.lesefehlerSeit ?? jetzt()
                aendere(id) { $0.lesefehlerSeit = seit }
                if jetzt() - seit > 120 {
                    aendere(id) { $0.problem = "Arbeitskopie nicht lesbar"; $0.meldung = L("Arbeitskopie nicht lesbar") }
                    warne("lesen:\(id)", L("Die Arbeitskopie von „\(a.name)“ ist nicht lesbar und kann nicht zurückgelegt werden. Sie bleibt im Arbeitsordner."))
                }
                return
            }
            if a.lesefehlerSeit != nil {
                aendere(id) { $0.lesefehlerSeit = nil; if $0.problem == "Arbeitskopie nicht lesbar" { $0.problem = nil; $0.meldung = L("Geschlossen, wird gleich zurückgelegt") } }
            }
            if a.sofort || jetzt() - max(a.ruheSeit ?? 0, p.neueste) >= e.ruheSekunden {
                abschliessen(id, abdruck: p)
            }
        default:
            break
        }
    }

    func jetztZuruecklegen(_ id: String) {
        guard let a = auftraege.first(where: { $0.id == id }), a.art == "arbeit",
              a.phase != "hochladen", a.phase != "fehlt" else { return }
        guard let w = aktuellerArbeitspfad(a) else {
            melde(L("Die Arbeitskopie von „\(a.name)“ liegt nicht mehr an ihrem Platz."))
            return
        }
        guard let offen = offeneDokumente(frisch: true) else {
            melde(L("Ich kann Logic gerade nicht abfragen. Beende Logic ganz, dann lege ich „\(a.name)“ zurück."))
            return
        }
        guard !offenIn(offen, letzter(w)) else {
            melde(L("„\(a.name)“ ist noch in Logic offen. Bitte zuerst schließen."))
            return
        }
        guard let p = abdruck(w) else {
            melde(L("Die Arbeitskopie von „\(a.name)“ ist nicht lesbar."))
            return
        }
        aendere(id) { $0.sofort = true }
        abschliessen(id, abdruck: p)
        sichere()
    }

    /// Gibt einen Auftrag ohne Arbeitskopie auf: eigene Sperre weg, sonst bleibt alles liegen.
    func aufgeben(_ id: String) {
        guard let a = auftraege.first(where: { $0.id == id }) else { return }
        loeseEigeneSperre(a)
        protokoll(L("Auftrag aufgegeben: \(a.name), eine vorhandene Arbeitskopie bleibt liegen"))
        entferne(id)
    }

    func abschliessen(_ id: String, abdruck p: Abdruck) {
        guard let a = auftraege.first(where: { $0.id == id }), let w = a.arbeitsPfad else { return }
        guard let offen = offeneDokumente(frisch: true) else {
            aendere(id) { $0.meldung = L("Kann Logic gerade nicht abfragen") }
            return
        }
        if offenIn(offen, letzter(w)) {
            aendere(id) { $0.phase = "offen"; $0.gesehenInLogic = true; $0.ruheSeit = nil; $0.sofort = false; $0.meldung = L("In Logic geöffnet") }
            return
        }
        if p.hash == a.abdruckBeimOeffnen {
            if a.uploadOffen {
                // Keine neue Arbeit, aber der letzte Stand ist noch nicht oben: Die Kopie bleibt bis zur Bestätigung.
                aendere(id) { $0.phase = "hochladen"; $0.uploadSeit = jetzt(); $0.stabil = 0; $0.abweichung = 0; $0.sofort = false; $0.meldung = L("Wird hochgeladen") }
                return
            }
            protokoll(L("Unverändert: \(a.name), nichts hochzuladen"))
            raeumeArbeitAuf(a)
            melde(L("„\(a.name)“ war unverändert. Die Zip in Drive bleibt, wie sie ist."))
            return
        }
        if let grund = driveNichtBereit() {
            aendere(id) { $0.phase = "ruhe"; $0.ruheSeit = $0.ruheSeit ?? jetzt(); $0.meldung = L("\(grund), lege danach zurück") }
            return
        }
        zuruecklegen(a)
    }

    /// Ist die Zip noch die, von der die Arbeit ausging? nil heißt: gerade nicht feststellbar.
    /// Die Größe allein zählt nicht, Drive meldet sie gelegentlich falsch.
    func quelleStand(_ a: Auftrag) -> Bool? {
        guard let q = a.quelleZip, let s = info(q), istDatei(s) else { return false }
        // Immer die Prüfsumme: Größe und Datum können bei einer fremden Fassung zufällig gleich sein.
        guard let summe = md5(q) else { return nil }
        return summe == a.basisMD5
    }

    /// Hat jemand anderes die Sperre übernommen (Öffnen trotz Warnung), arbeitet er parallel am selben Projekt.
    func sperreFremd(_ a: Auftrag) -> Bool {
        guard let m = a.markerPfad, let d = fm.contents(atPath: m),
              let o = try? JSONDecoder().decode(Marker.self, from: d) else { return false }
        return !(o.rechner == eigenerRechner() && o.konto == NSUserName())
    }

    func zuruecklegen(_ a: Auftrag) {
        guard let w = a.arbeitsPfad, let wurzel = a.wurzelName, let quelle = a.quelleZip else { return }
        do {
            let z = try packen(w, wurzel: wurzel)
            defer { try? fm.removeItem(atPath: z.ordner) }
            // Packen dauert bei großen Projekten Minuten: Wurde es inzwischen wieder geöffnet, abbrechen.
            guard let offen = offeneDokumente(frisch: true) else { throw HelferFehler(L("Logic lässt sich gerade nicht abfragen")) }
            if offenIn(offen, letzter(w)) {
                protokoll(L("Wieder geöffnet beim Packen: \(a.name), Zurücklegen abgebrochen"))
                aendere(a.id) { $0.phase = "offen"; $0.gesehenInLogic = true; $0.ruheSeit = nil; $0.sofort = false; $0.meldung = L("In Logic geöffnet") }
                return
            }
            // Schlaf oder Funkloch während des Packens: Die lokale Zip kann veraltet sein.
            if let grund = driveNichtBereit() {
                aendere(a.id) { $0.phase = "ruhe"; $0.ruheSeit = $0.ruheSeit ?? jetzt(); $0.meldung = L("\(grund), lege danach zurück") }
                return
            }
            guard let unveraendert = quelleStand(a) else { throw HelferFehler(L("Die Zip in Drive ist gerade nicht lesbar")) }
            var ziel = quelle
            var konflikt = false
            if unveraendert && !sperreFremd(a) {
                try sichereAlteZip(quelle, name: a.name, erwartet: a.basisMD5)
                try ersetzeInDrive(quelle, mit: z.pfad)
            } else {
                konflikt = true
                let ordner = (quelle as NSString).deletingLastPathComponent
                guard info(ordner) != nil else { throw HelferFehler(L("Der Drive-Ordner existiert nicht mehr")) }
                ziel = freierPfad(ordner, stamm: "\(a.name) – Stand \(vorname()) \(zeitText())", endung: ".logicx.zip")
                try fm.moveItem(atPath: z.pfad, toPath: ziel)
            }
            aendere(a.id) {
                $0.phase = "hochladen"
                $0.zielZip = ziel
                $0.zielGroesse = z.groesse
                $0.zielMD5 = z.md5
                $0.gepacktAbdruck = z.abdruck
                $0.uploadSeit = jetzt()
                $0.uploadOffen = false
                $0.sofort = false
                $0.stabil = 0
                $0.abweichung = 0
                $0.problem = nil
                $0.konflikt = konflikt || $0.konflikt
                $0.groesseFalsch = false
                $0.fassungen = 0
                $0.pauseBis = nil
                $0.meldung = konflikt ? L("Konflikt: wird als eigene Fassung hochgeladen") : L("Wird hochgeladen")
            }
            protokoll(konflikt ? L("KONFLIKT: \(a.name) hat sich in Drive geändert, neue Fassung daneben: \(letzter(ziel))")
                               : L("Zurückgelegt: \(a.name), \(z.groesse) Byte, Upload läuft"))
            sichere()
        } catch {
            protokoll(L("Zurücklegen fehlgeschlagen (\(a.name)): \(error)"))
            aendere(a.id) { $0.ruheSeit = jetzt(); $0.sofort = false; $0.problem = "\(error)"; $0.meldung = L("Fehler, neuer Versuch folgt: \(error)") }
            warne("zuruecklegen:\(a.id)", L("„\(a.name)“ ließ sich nicht zurücklegen: \(error). Die lokale Kopie bleibt."))
        }
    }

    /// Das Projekt ist wieder in Arbeit, obwohl sein Stand gerade hochlädt. Der hochgeladene Stand wird die neue Basis.
    func zurueckInArbeit(_ id: String, gesehen: Bool, uploadBestaetigt: Bool) {
        guard let a = auftraege.first(where: { $0.id == id }), let ziel = a.zielZip else { return }
        aendere(id) {
            $0.phase = "offen"
            $0.gesehenInLogic = gesehen
            $0.geoeffnetAm = jetzt()
            $0.ruheSeit = nil
            $0.sofort = false
            $0.quelleZip = ziel
            $0.basisGroesse = a.zielGroesse
            $0.basisMD5 = a.zielMD5
            $0.basisDatum = nil         // ohne Datum entscheidet beim Zurücklegen die Prüfsumme
            if let g = a.gepacktAbdruck { $0.abdruckBeimOeffnen = g }
            $0.uploadOffen = !uploadBestaetigt
            $0.pauseBis = nil
            $0.stabil = 0
            $0.abweichung = 0
            $0.meldung = L("Wieder in Logic geöffnet")
        }
        protokoll(L("Wieder in Arbeit während des Uploads: \(a.name), die Arbeitskopie bleibt"))
        sichere()
    }

    func zaehleAbweichung(_ id: String, _ grund: String) {
        aendere(id) { $0.abweichung += 1; $0.stabil = 0 }
        guard let a = auftraege.first(where: { $0.id == id }), a.abweichung >= 3 else { return }
        weichtAb(a, grund: grund)
    }

    /// Die Zip in Drive ist nicht mehr die, die der Helfer hineingelegt hat: den eigenen Stand daneben sichern.
    func weichtAb(_ a: Auftrag, grund: String) {
        protokoll("\(a.name): \(grund)")
        // Höchstens eine automatische Fassung pro Stand, sonst könnte ein Drive-Fehler den Ordner mit Kopien füllen.
        if a.fassungen >= 1 {
            aendere(a.id) { $0.stabil = 0; $0.abweichung = 0; $0.pauseBis = jetzt() + 600; $0.problem = L("Zip weicht wiederholt ab"); $0.meldung = L("Zip in Drive weicht wiederholt ab, bitte prüfen") }
            warne("abweichung:\(a.id)", L("Die Zip von „\(a.name)“ weicht in Drive wiederholt ab. Logic2Drive legt keine weitere Fassung an, die lokale Kopie bleibt."))
            return
        }
        var von = a.art == "arbeit" ? a.arbeitsPfad : a.paket
        if a.art == "ablage", let p = a.paket, info(p).map({ !istOrdner($0) }) ?? true {
            von = umbenanntesPaket(ordner: (p as NSString).deletingLastPathComponent, basis: a.name, abdruck: a.paketAbdruck, inode: a.paketInode)
            if let n = von { aendere(a.id) { $0.paket = n } }
        }
        guard let v = von, info(v) != nil else {
            if a.art == "arbeit" {
                aendere(a.id) { $0.phase = "fehlt"; $0.problem = L("Arbeitskopie fehlt"); $0.meldung = L("Arbeitskopie fehlt") }
                warne("fehlt:\(a.id)", L("Die Zip und die Arbeitskopie von „\(a.name)“ sind nicht mehr da. Gib den Auftrag im Menü auf."))
            } else {
                warne("weg:\(a.id)", L("Die Zip und das Paket von „\(a.name)“ sind nicht mehr im Drive-Ordner."))
                entferne(a.id)
            }
            return
        }
        eigeneFassung(a.id, von: v, grund: grund)
    }

    func pruefeUpload(_ id: String) {
        guard var a = auftraege.first(where: { $0.id == id }), let z = a.zielZip, let seit = a.uploadSeit else { return }
        if let p = a.pauseBis, jetzt() < p { return }
        // Ist das Projekt während des Uploads wieder in Logic offen, darf nichts weggeräumt werden.
        if a.art == "arbeit" {
            if let w = aktuellerArbeitspfad(a) { a.arbeitsPfad = w }    // auch umbenannte Kopien
            guard let offen = offeneDokumente() else {      // ohne Antwort von Logic gar nicht erst die ganze Zip lesen
                aendere(id) { $0.stabil = 0; $0.meldung = L("Kann Logic gerade nicht abfragen, die Kopie bleibt") }
                return
            }
            if let w = a.arbeitsPfad, offenIn(offen, letzter(w)) {
                zurueckInArbeit(id, gesehen: true, uploadBestaetigt: false)
                return
            }
        }
        if a.art == "ablage", let p = a.paket {
            guard let offen = offeneDokumente() else {
                aendere(id) { $0.stabil = 0; $0.meldung = L("Kann Logic gerade nicht abfragen") }
                return
            }
            if offenIn(offen, letzter(p), a.name) {
                aendere(id) { $0.stabil = 0; $0.meldung = L("Ist in Logic offen, wird nach dem Schließen aufgeräumt") }
                return
            }
        }
        // macOS meldet direkt nach dem Ersetzen kurz fälschlich „hochgeladen“ (gemessen 23.11.2026).
        if jetzt() - seit < 6 { return }
        guard let s = info(z), istDatei(s) else {
            zaehleAbweichung(id, L("Die Zip liegt nicht mehr im Drive-Ordner"))
            return
        }
        guard let st = uploadStand(z) else { aendere(id) { $0.stabil = 0 }; return }
        if let f = st.fehler {
            aendere(id) { $0.stabil = 0; $0.problem = f; $0.meldung = L("Upload-Fehler: \(f)") }
            warne("upload:\(id)", L("„\(a.name)“ ließ sich nicht hochladen: \(f). Die lokale Kopie bleibt."))
            return
        }
        if Int64(s.st_size) != a.zielGroesse && !a.groesseFalsch {
            // Eine andere Größe allein beweist nichts, Drive meldet sie gelegentlich falsch. Die Prüfsumme entscheidet.
            aendere(id) { $0.abweichung += 1; $0.stabil = 0 }
            guard let c = auftraege.first(where: { $0.id == id }), c.abweichung >= 3 else { return }
            guard let summe = md5(z) else {
                aendere(id) { $0.abweichung = 0; $0.pauseBis = jetzt() + 60 }
                return
            }
            if summe == a.zielMD5 {
                protokoll(L("Drive meldet für \(a.name) eine falsche Größe, der Inhalt stimmt"))
                aendere(id) { $0.groesseFalsch = true; $0.abweichung = 0 }
            } else {
                weichtAb(c, grund: L("Die Zip in Drive hat sich geändert"))
            }
            return
        }
        guard st.hoch, !st.laedt else {
            aendere(id) { $0.stabil = 0; $0.abweichung = 0 }
            if jetzt() - seit > 3600 {
                aendere(id) { $0.problem = L("Upload dauert ungewöhnlich lange"); $0.meldung = L("Seit über einer Stunde nicht in Drive angekommen") }
                warne("upload-lang:\(id)", L("„\(a.name)“ ist seit über einer Stunde nicht in Google Drive angekommen. Ist Drive pausiert oder das Konto voll? Die lokale Kopie bleibt."))
            }
            return
        }
        aendere(id) { $0.stabil += 1; $0.abweichung = 0 }
        guard let b = auftraege.first(where: { $0.id == id }), b.stabil >= 3 else { return }
        guard let summe = md5(z) else { aendere(id) { $0.stabil = 0; $0.pauseBis = jetzt() + 60 }; return }
        guard summe == a.zielMD5 else {
            weichtAb(b, grund: L("Prüfsumme der Zip in Drive weicht ab"))
            return
        }
        aendere(id) { $0.problem = nil }
        if b.art == "ablage" {
            fertigAblage(b)
            return
        }
        // Letzte Prüfung direkt vor dem Wegräumen der Arbeitskopie.
        guard let w = b.arbeitsPfad, let offen = offeneDokumente(frisch: true) else {
            aendere(id) { $0.stabil = 0; $0.meldung = L("Kann Logic gerade nicht abfragen, die Kopie bleibt") }
            return
        }
        if offenIn(offen, letzter(w)) {
            zurueckInArbeit(id, gesehen: true, uploadBestaetigt: true)
            return
        }
        if info(w) != nil {
            guard let p = abdruck(w) else { aendere(id) { $0.stabil = 0 }; return }
            if let g = b.gepacktAbdruck, p.hash != g {
                protokoll(L("\(b.name) wurde nach dem Packen noch geändert, die Arbeitskopie bleibt"))
                zurueckInArbeit(id, gesehen: true, uploadBestaetigt: true)
                return
            }
        }
        protokoll(L("Upload bestätigt: \(b.name)"))
        raeumeArbeitAuf(b)
        if b.konflikt {
            melde(L("„\(b.name)“ wurde inzwischen geändert. Dein Stand liegt als eigene Fassung daneben."))
        } else {
            melde(L("„\(b.name)“ ist wieder in Google Drive."))
        }
    }

    func loeseEigeneSperre(_ a: Auftrag) {
        if let m = a.markerPfad, let d = fm.contents(atPath: m), let o = try? JSONDecoder().decode(Marker.self, from: d),
           o.rechner == eigenerRechner(), o.konto == NSUserName() {
            try? fm.removeItem(atPath: m)
        }
    }

    func raeumeArbeitAuf(_ a: Auftrag) {
        loeseEigeneSperre(a)
        if let w = a.arbeitsPfad, istArbeitskopie(a, w) {     // nur das ausgecheckte Paket, nie ein anderes unter demselben Namen
            do {
                try fm.trashItem(at: URL(fileURLWithPath: w), resultingItemURL: nil)
            } catch {
                protokoll(L("Arbeitskopie nicht in den Papierkorb gelegt: \(error)"))
            }
        }
        entferne(a.id)
    }

    func aendere(_ id: String, _ f: (inout Auftrag) -> Void) {
        guard let i = auftraege.firstIndex(where: { $0.id == id }) else { return }
        f(&auftraege[i])
    }

    func entferne(_ id: String) {
        auftraege.removeAll { $0.id == id }
        sichere()
    }
}

// MARK: - Trockenlauf

func trockenlauf(_ wurzeln: [String]) {
    var geprueft = 0, inCloud = 0, wuerde = 0
    func geh(_ d: String) {
        guard let namen = try? fm.contentsOfDirectory(atPath: d) else { return }
        for n in namen where !n.hasPrefix(".") {
            let p = d + "/" + n
            guard let s = info(p), istOrdner(s), !istDataless(s) else { continue }
            guard n.lowercased().hasSuffix(".logicx") else { geh(p); continue }
            guard istProjekt(p), let st = uploadStand(p) else { continue }
            geprueft += 1
            if st.hoch && !st.laedt && st.fehler == nil {
                inCloud += 1
            } else {
                wuerde += 1
                print(L("WÜRDE EINPACKEN: \(p.replacingOccurrences(of: heim, with: "~"))"))
            }
        }
    }
    for w in wurzeln { geh(w) }
    print(L("Geladene Pakete: \(geprueft), davon normal in der Cloud: \(inCloud), würde einpacken: \(wuerde)"))
}

// MARK: - Menüleiste

let helfer = Helfer()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var stand: [Auftrag] = []
    var beobachtet: [String] = []
    var gestartet = false
    var wartendeDateien: [URL] = []     // macOS liefert „Öffnen“ beim Start VOR applicationDidFinishLaunching
    let willkommen = WillkommenFenster()
    let einstellungen = EinstellungenFenster()
    var updateText: String?         // Zeile im Menü, wenn eine neue Version bekannt ist
    var updateSeite: URL?           // gesetzt, wenn die neue Version nur von Hand zu holen ist
    var wartendesUpdate: (app: String, version: String, team: String)?
    var updateLaeuft = false
    var beendeOhneFrage = false
    var updatesAutomatisch: Bool { UserDefaults.standard.object(forKey: "updatesAutomatisch") as? Bool ?? true }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = helferZeichen()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        helfer.aktualisiert = { [weak self] a in
            DispatchQueue.main.async {
                self?.stand = a
                self?.zeigeSymbol()
            }
        }
        helfer.frage = { titel, text, antwort in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = titel
                alert.informativeText = text
                alert.addButton(withTitle: L("Abbrechen"))
                alert.addButton(withTitle: L("Trotzdem öffnen"))
                antwort(alert.runModal() == .alertSecondButtonReturn)
            }
        }
        beobachtet = helfer.e.ordner
        helfer.ordnerGeaendert = { [weak self] o in DispatchQueue.main.async { self?.beobachtet = o } }
        helfer.start()      // lädt zuerst die Aufträge, die Warteschlange hält die Reihenfolge
        gestartet = true
        willkommen.modell.lies = { [weak self] in
            WillkommenStand(drive: self?.beobachtetDrive ?? false, zip: self?.istZipStandard ?? false,
                            autostart: SMAppService.mainApp.status == .enabled, driveDa: !driveWurzeln().isEmpty)
        }
        willkommen.modell.driveSetzen = { [weak self] ein in
            guard let self, ein != self.beobachtetDrive else { return }
            if ein { self.driveEinschalten(immerFragen: false) } else { self.driveUmschalten() }
        }
        willkommen.modell.zipSetzen = { [weak self] ein in self?.zipSetzen(ein) }
        willkommen.modell.autostartSetzen = { [weak self] ein in self?.autostartSetzen(ein) }
        willkommen.geschlossen = { UserDefaults.standard.set(true, forKey: "willkommenGezeigt") }
        // Beim allerersten Start erklärt das Fenster, wo der Helfer steckt und was einzuschalten ist.
        if !UserDefaults.standard.bool(forKey: "willkommenGezeigt") { willkommen.zeige() }
        einstellungen.modell.lies = { [weak self] in (self?.updatesAutomatisch ?? true, self?.updateText, self?.sprachWahl ?? "auto") }
        einstellungen.modell.setzeUpdatesVonSelbst = { UserDefaults.standard.set($0, forKey: "updatesAutomatisch") }
        einstellungen.modell.sucheUpdate = { [weak self] in self?.sucheUpdate(vonHand: true) }
        einstellungen.modell.setzeSprache = { [weak self] in self?.setzeSprache($0) }
        einstellungen.modell.zeigeEinfuehrung = { [weak self] in self?.willkommen.zeige() }
        if UserDefaults.standard.bool(forKey: "einstellungenNachStart") {
            UserDefaults.standard.removeObject(forKey: "einstellungenNachStart")
            einstellungenZeigen()
        }
        starteUpdateUhr()
        let warten = wartendeDateien
        wartendeDateien = []
        if !warten.isEmpty { reicheWeiter(warten) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if gestartet { reicheWeiter(urls) } else { wartendeDateien += urls }
    }

    func reicheWeiter(_ urls: [URL]) {
        helfer.q.async { for u in urls { helfer.oeffne(u.path, trotzdem: false) } }
    }

    func zeigeSymbol() {
        let problem = einstellungsProblem != nil || stand.contains { $0.problem != nil || $0.phase == "fehlt" }
        statusItem.button?.image = problem
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L("Logic2Drive meldet ein Problem")) ?? helferZeichen()
            : helferZeichen()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let kopf = NSMenuItem(title: L("Logic2Drive \(helferVersion)"), action: nil, keyEquivalent: "")
        kopf.isEnabled = false
        menu.addItem(kopf)
        if let u = updateText {
            let z = NSMenuItem(title: u, action: updateSeite == nil ? nil : #selector(updateSeiteOeffnen), keyEquivalent: "")
            z.target = self
            z.isEnabled = updateSeite != nil
            menu.addItem(z)
        }
        if let p = einstellungsProblem {
            let z = NSMenuItem(title: "⚠︎ \(p)", action: nil, keyEquivalent: "")
            z.isEnabled = false
            menu.addItem(z)
        }
        let wo = NSMenuItem(title: beobachtetText, action: nil, keyEquivalent: "")
        wo.isEnabled = false
        menu.addItem(wo)
        menu.addItem(.separator())
        if stand.isEmpty {
            let leer = NSMenuItem(title: L("Gerade nichts in Arbeit"), action: nil, keyEquivalent: "")
            leer.isEnabled = false
            menu.addItem(leer)
        }
        for a in stand {
            let z = NSMenuItem(title: "\(a.name): \(a.meldung)", action: nil, keyEquivalent: "")
            z.isEnabled = false
            menu.addItem(z)
            if a.art == "arbeit" && (a.phase == "fehlt" || (a.phase == "hochladen" && a.problem != nil)) {
                let k = NSMenuItem(title: L("   Auftrag aufgeben und Sperre lösen"), action: #selector(aufgeben(_:)), keyEquivalent: "")
                k.target = self
                k.representedObject = a.id
                menu.addItem(k)
            } else if a.art == "arbeit" && a.phase != "hochladen" {
                let k = NSMenuItem(title: L("   Jetzt zurücklegen"), action: #selector(zuruecklegen(_:)), keyEquivalent: "")
                k.target = self
                k.representedObject = a.id
                menu.addItem(k)
            }
        }
        if let z = letzteMeldung() {
            let zuletzt = NSMenuItem(title: z, action: nil, keyEquivalent: "")
            zuletzt.isEnabled = false
            menu.addItem(zuletzt)
        }
        menu.addItem(.separator())
        let einst = NSMenuItem(title: L("Einstellungen …"), action: #selector(einstellungenZeigen), keyEquivalent: ",")
        einst.target = self
        menu.addItem(einst)
        for (titel, sel) in [(L("Arbeitsordner öffnen"), #selector(arbeitsordner)), (L("Sicherung öffnen"), #selector(sicherungOeffnen)),
                             (L("Protokoll öffnen"), #selector(protokollOeffnen))] {
            let k = NSMenuItem(title: titel, action: sel, keyEquivalent: "")
            k.target = self
            menu.addItem(k)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Schalter im Menü

    var beobachtetDrive: Bool {
        let w = driveWurzeln()
        return !w.isEmpty && Set(beobachtet) == Set(w)
    }

    var beobachtetText: String {
        if beobachtet.isEmpty { return L("Beobachtet keinen Ordner") }
        if beobachtetDrive { return L("Beobachtet dein Google Drive") }
        return L("Beobachtet: ") + beobachtet.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }

    var istZipStandard: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: .zip)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    func hinweis(_ titel: String, _ text: String, knopf: String? = nil) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = titel
        alert.informativeText = text
        if let knopf {
            alert.addButton(withTitle: knopf)
            alert.addButton(withTitle: L("Abbrechen"))
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func driveUmschalten() {
        if beobachtetDrive {
            if hinweis(L("Google Drive nicht mehr beobachten?"), L("Neue Logic-Projekte in Google Drive werden dann nicht mehr automatisch eingepackt. Laufende Aufträge laufen zu Ende."), knopf: L("Ausschalten")) {
                helfer.q.async { helfer.setzeOrdner([]) }
            }
            return
        }
        driveEinschalten(immerFragen: true)
    }

    /// Aus dem Willkommensfenster ist der Klick schon die Zustimmung. Gefragt wird dort nur, wenn sofort etwas eingepackt würde.
    func driveEinschalten(immerFragen: Bool) {
        let wurzeln = driveWurzeln()
        guard !wurzeln.isEmpty else {
            _ = hinweis(L("Kein Google Drive gefunden"), L("Auf diesem Mac ist Google Drive nicht eingerichtet oder nicht angemeldet."))
            return
        }
        guard einstellungsProblem == nil else {
            _ = hinweis(L("Einstellungen nicht lesbar"), L("Solange die Einstellungen nicht lesbar sind, lässt sich das Beobachten nicht einschalten."))
            return
        }
        helfer.q.async {
            let h = helfer.haengendePakete(in: wurzeln)        // nur lesend, zeigt vorab, was sofort passiert
            DispatchQueue.main.async {
                var text = L("Logic2Drive packt dann jedes Logic-Projekt als Zip ein, das an diesem Mac neu in Google Drive gespeichert oder dort geändert wird. Das passiert erst, wenn das Projekt in Logic geschlossen ist. Das Original bleibt \(helfer.e.aufbewahrungTage ?? 90) Tage im Sicherungsordner.")
                if h.isEmpty {
                    text += L("\n\nIm Moment hängt kein Projekt im Upload.")
                } else {
                    let namen = h.prefix(6).map { "• " + ($0 as NSString).lastPathComponent }.joined(separator: "\n")
                    text += h.count == 1 ? L("\n\n1 Projekt hängt gerade im Upload und wird gleich eingepackt:\n\(namen)")
                        : L("\n\n\(h.count) Projekte hängen gerade im Upload und werden gleich eingepackt:\n\(namen)\(h.count > 6 ? "\n…" : "")")
                }
                if (h.isEmpty && !immerFragen) || self.hinweis(L("Google Drive beobachten?"), text, knopf: L("Einschalten")) {
                    helfer.q.async { helfer.setzeOrdner(wurzeln) }
                }
            }
        }
    }

    @objc func zipUmschalten() {
        let ein = !istZipStandard
        if ein, !hinweis(L("Logic-Zips per Doppelklick öffnen?"), L("macOS unterscheidet Zips nur an der Endung .zip. Logic2Drive wird deshalb das Standardprogramm für alle Zips. Eine Zip mit Logic-Projekt (Name.logicx.zip) öffnet sich in Logic, jede andere geht sofort an das Archivprogramm weiter."), knopf: L("Einschalten")) {
            return
        }
        zipSetzen(ein)
    }

    func zipSetzen(_ ein: Bool) {
        let archiv = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app")
        NSWorkspace.shared.setDefaultApplication(at: ein ? Bundle.main.bundleURL : archiv, toOpen: .zip) { fehler in
            guard let fehler else { return }
            DispatchQueue.main.async { _ = self.hinweis(L("Das Standardprogramm ließ sich nicht ändern"), fehler.localizedDescription) }
        }
    }

    @objc func autostartUmschalten() { autostartSetzen(SMAppService.mainApp.status != .enabled) }

    func autostartSetzen(_ ein: Bool) {
        do {
            if ein {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            _ = hinweis(L("Der Autostart ließ sich nicht ändern"), error.localizedDescription)
        }
    }

    @objc func sicherungOeffnen() {
        try? fm.createDirectory(atPath: helfer.e.sicherungsordner, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: helfer.e.sicherungsordner))
    }

    // MARK: Updates

    func starteUpdateUhr() {
        let d = UserDefaults.standard
        if let alt = d.string(forKey: "letzteVersion"), istNeuer(helferVersion, als: alt) {
            helfer.q.async { melde(L("Logic2Drive wurde auf Version \(helferVersion) aktualisiert.")) }
        }
        d.set(helferVersion, forKey: "letzteVersion")
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.updateTakt() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.updateTakt() }
    }

    /// Alle zehn Minuten: ein fertig geprüftes Update einsetzen, sobald Ruhe ist. Einmal am Tag neu suchen.
    func updateTakt() {
        if wartendesUpdate != nil { versucheEinsetzen(); return }
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "updateGeprueft") > 86400 else { return }
        sucheUpdate(vonHand: false)
    }

    @objc func updateSeiteOeffnen() { if let u = updateSeite { NSWorkspace.shared.open(u) } }

    func sucheUpdate(vonHand: Bool) {
        guard !updateLaeuft else { return }
        updateLaeuft = true
        let automatisch = updatesAutomatisch
        DispatchQueue.global(qos: .utility).async {
            var angebot: UpdateAngebot?
            var fehler: String?
            var bereit: (app: String, version: String, team: String)?
            do {
                angebot = try Update.suche()
                if let a = angebot, automatisch, let team = Update.eigenesTeam() {
                    bereit = (try Update.ladeUndPruefe(a, team: team), a.version, team)
                }
            } catch {
                fehler = "\(error)"
                if angebot != nil || vonHand { protokoll(L("Update: \(error)")) }
            }
            DispatchQueue.main.async {
                self.updateLaeuft = false
                // Nach einem Fehlschlag in einer Stunde wieder versuchen, sonst morgen.
                let wann = Date().timeIntervalSince1970 - (fehler == nil ? 0 : 86400 - 3600)
                UserDefaults.standard.set(wann, forKey: "updateGeprueft")
                if let b = bereit {
                    self.wartendesUpdate = b
                    self.updateSeite = nil
                    self.updateText = L("Version \(b.version) wird eingespielt, sobald nichts in Arbeit ist")
                    protokoll(L("Update auf \(b.version) geladen und geprüft, wartet auf Ruhe"))
                    self.versucheEinsetzen()
                } else if let a = angebot {
                    self.updateSeite = a.seite ?? URL(string: projektSeite + "/releases/latest")
                    self.updateText = L("Version \(a.version) ist da – hier klicken")
                    if vonHand {
                        _ = self.hinweis(L("Version \(a.version) ist da"), fehler.map { L("Sie ließ sich nicht von selbst einspielen: \($0)") }
                            ?? L("Du findest sie über die Zeile oben im Menü."))
                    }
                } else if vonHand {
                    _ = self.hinweis(fehler == nil ? L("Du hast die neueste Version") : L("Die Suche hat nicht geklappt"), fehler ?? L("Logic2Drive \(helferVersion)"))
                }
            }
        }
    }

    /// Eingesetzt wird nur, wenn nichts läuft und in der letzten Viertelstunde kein Projekt in Logic offen war.
    func versucheEinsetzen() {
        guard let w = wartendesUpdate else { return }
        helfer.q.async {
            let t = jetzt()
            guard helfer.auftraege.isEmpty, helfer.kandidaten.isEmpty, helfer.inLogic.values.allSatisfy({ t - $0.zuletzt > 900 }) else { return }
            do {
                try Update.setzeEin(w.app, version: w.version, team: w.team)
                helfer.angehalten = true
                protokoll(L("Update auf \(w.version) eingesetzt, Logic2Drive startet neu"))
                DispatchQueue.main.async { self.neustart() }
            } catch {
                protokoll(L("Update auf \(w.version) nicht eingesetzt: \(error)"))
                DispatchQueue.main.async {
                    self.wartendesUpdate = nil
                    self.updateSeite = URL(string: projektSeite + "/releases/latest")
                    self.updateText = L("Version \(w.version) ließ sich nicht einspielen – hier klicken")
                }
            }
        }
    }

    func neustart() {
        beendeOhneFrage = true
        // Erst starten, wenn dieser Prozess beendet ist: Sonst scheitert die neue App an der Sperre der alten.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\"",
                       Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? p.run()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if stand.isEmpty || beendeOhneFrage { return .terminateNow }
        let text = stand.count == 1
            ? L("Ein Auftrag läuft noch. Solange Logic2Drive beendet ist, wird nichts nach Google Drive zurückgelegt. Deine Arbeit bleibt lokal erhalten.")
            : L("\(stand.count) Aufträge laufen noch. Solange Logic2Drive beendet ist, wird nichts nach Google Drive zurückgelegt. Deine Arbeit bleibt lokal erhalten.")
        return hinweis(L("Logic2Drive beenden?"), text, knopf: L("Beenden")) ? .terminateNow : .terminateCancel
    }

    @objc func zuruecklegen(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        helfer.q.async { helfer.jetztZuruecklegen(id) }
    }
    @objc func aufgeben(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        helfer.q.async { helfer.aufgeben(id) }
    }
    @objc func einfuehrung() { willkommen.zeige() }

    @objc func einstellungenZeigen() { einstellungen.zeige(schalter: willkommen.modell) }

    /// Die Sprache des Macs gilt, solange hier nichts anderes gewählt ist. Eine Wahl steht als AppleLanguages in den
    /// Einstellungen der App: So schaltet macOS auch Leserichtung und eigene Dialoge mit um.
    var sprachWahl: String {
        let eigene = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        guard let erste = eigene?.first else { return "auto" }
        let kurz = String(erste.lowercased().prefix { $0 != "-" && $0 != "_" })
        return sprachen.contains(kurz) ? kurz : "auto"
    }

    func setzeSprache(_ wahl: String) {
        guard wahl != sprachWahl else { return }
        let d = UserDefaults.standard
        if wahl == "auto" { d.removeObject(forKey: "AppleLanguages") } else { d.set([wahl], forKey: "AppleLanguages") }
        guard stand.isEmpty else {
            _ = hinweis(L("Die Sprache wechselt beim nächsten Start"), L("Gerade läuft noch ein Auftrag. Logic2Drive startet deshalb nicht von selbst neu."))
            return
        }
        d.set(true, forKey: "einstellungenNachStart")       // nach dem Neustart das Fenster wieder zeigen
        d.synchronize()
        neustart()
    }

    @objc func arbeitsordner() { NSWorkspace.shared.open(URL(fileURLWithPath: helfer.e.arbeitsordner)) }
    @objc func protokollOeffnen() { NSWorkspace.shared.open(URL(fileURLWithPath: datenOrdner + "/protokoll.log")) }
}

// MARK: - Start

func sperreHolen() -> Bool {
    let fd = open(datenOrdner + "/sperre", O_CREAT | O_RDWR, 0o600)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0     // bleibt bis zum Prozessende offen
}

signal(SIGPIPE, SIG_IGN)     // ein geschlossenes Ausgabe-Rohr darf den Helfer nicht beenden
try? fm.createDirectory(atPath: datenOrdner, withIntermediateDirectories: true)
let argumente = Array(CommandLine.arguments.dropFirst())

switch argumente.first {
case "--version":
    print(helferVersion)
case "--trocken":
    trockenlauf(Array(argumente.dropFirst()))
case "--willkommen-bild":
    // Nur zum Prüfen der Gestaltung: --willkommen-bild <Datei.png> [an|aus|ohne-drive] [1|2]
    guard argumente.count >= 2 else { print(L("Aufruf: --willkommen-bild <Datei.png> [an|aus|ohne-drive] [1|2]")); exit(2) }
    let art = argumente.count > 2 ? argumente[2] : "aus"
    let stand = art == "an" ? WillkommenStand(drive: true, zip: true, autostart: true, driveDa: true)
        : art == "ohne-drive" ? WillkommenStand(drive: false, zip: true, autostart: false, driveDa: false)
        : WillkommenStand(drive: false, zip: false, autostart: false, driveDa: true)
    exit(willkommenAlsBild(argumente[1], stand: stand, seite: argumente.count > 3 && argumente[3] == "2" ? 1 : 0) ? 0 : 1)
case "--einstellungen-bild":
    guard argumente.count >= 2 else { print(L("Aufruf: --einstellungen-bild <Datei.png>")); exit(2) }
    exit(einstellungenAlsBild(argumente[1]) ? 0 : 1)
case "--zeichen-bild":
    // Nur zum Prüfen der Gestaltung: --zeichen-bild <Datei.png> <Pixel> [app]
    guard argumente.count >= 3, let px = Int(argumente[2]) else { print(L("Aufruf: --zeichen-bild <Datei.png> <Pixel> [app]")); exit(2) }
    let app = argumente.count > 3 && argumente[3] == "app"
    exit(schreibePNG(argumente[1], pixel: px) { k in
        if app { zeichneAppSymbol(kante: k) } else { zeichneHelferZeichen(kante: k, platte: .black, wolke: .black) }
    } ? 0 : 1)
case "--app-symbol":
    guard argumente.count >= 2 else { print(L("Aufruf: --app-symbol <Ordner.iconset>")); exit(2) }
    exit(schreibeAppSymbol(argumente[1]) ? 0 : 1)
case "--update-suchen", "--update-einspielen":
    // Ohne Oberfläche und ohne Neustart. --update-einspielen ersetzt die App, in der dieses Programm liegt.
    let r = Update.durchgang(einsetzen: argumente.first == "--update-einspielen")
    print(r.text)
    exit(r.code)
case "--zuletzt":
    print(letzteMeldung() ?? "")
case "--status":
    print(String(decoding: fm.contents(atPath: helfer.zustandsPfad) ?? Data("[]".utf8), as: UTF8.self))
case "--oeffne":
    guard argumente.count >= 2 else { print(L("Aufruf: --oeffne <Zip> [--trotzdem]")); exit(2) }
    try? fm.createDirectory(atPath: datenOrdner + "/eingang", withIntermediateDirectories: true)
    let o: [String: Any] = ["zip": argumente[1], "trotzdem": argumente.contains("--trotzdem")]
    let d = try! JSONSerialization.data(withJSONObject: o)
    let z = datenOrdner + "/eingang/" + UUID().uuidString
    try! d.write(to: URL(fileURLWithPath: z + ".tmp"))
    try! fm.moveItem(atPath: z + ".tmp", toPath: z + ".json")
case "--lauf":
    guard sperreHolen() else { print(L("Logic2Drive läuft schon.")); exit(1) }
    helfer.start()
    dispatchMain()
default:
    guard sperreHolen() else { exit(0) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
