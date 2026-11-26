// Logic2Drive – Prüfung gebouncter Audiodateien. Nach dem Bounce sieht der Helfer einmal durch die Datei und meldet
// Stellen, die beim Hören stören würden: deutlich lauter oder leiser als der Rest, lange Pausen, übersteuerte
// Spitzen, Knackser und Aussetzer. Falschalarme sind schlimmer als ein übersehener Grenzfall: Eine frühere Messung
// im Team meldete „harte Sample-Sprünge“, die normale Zischlaute und Plosive waren. Alle Schwellen sind deshalb
// vorsichtig gewählt und stehen in `PruefSchwelle`.
//
// Die Datei wird blockweise gelesen (1 s je Block, AVAudioFile dekodiert MP3, WAV, AIFF und M4A in Float). Im
// Speicher bleiben nur die Filterzustände, ein Fenster von gut 100 ms für die Knackser-Suche und je 100 ms ein
// Lautheitswert (60 min = 36 000 Werte). Gemessen am 26.11.2026 auf einem M-Mac (-O): 60 min Stereo als MP3 in
// 5,3 s, als 16-Bit-WAV in 2,6 s, höchstens 18 MB Speicher.

import Foundation
import AVFoundation
import Accelerate

enum PruefArt: String { case lauter, leiser, pause, uebersteuert, knackser, aussetzer }

/// von/bis in Sekunden ab Dateianfang. wert: bei lauter/leiser der Abstand zum Bezugspegel in LU, sonst 0.
struct PruefStelle { let art: PruefArt; let von: Double; let bis: Double; let wert: Double }

struct PruefBefund {
    let dauer: Double; let rate: Double; let kanaele: Int
    let lufs: Double        // Gesamtlautheit nach BS.1770 (gegatet), bei Stille -70
    let spitze: Double      // höchste Sample-Spitze in dBFS
    let bezug: Double       // Bezugspegel für lauter/leiser, LUFS
    let stellen: [PruefStelle]   // nach Zeit sortiert

    func bericht() -> String {
        func z(_ x: Double, _ n: Int = 1) -> String { String(format: "%.\(n)f", x) }
        var zeilen = ["Dauer \(z(dauer)) s, \(Int(rate.rounded())) Hz, \(kanaele) \(kanaele == 1 ? "Kanal" : "Kanäle"), "
                      + "Gesamt \(z(lufs)) LUFS, Bezug \(z(bezug)) LUFS, Spitze \(z(spitze)) dBFS"]
        for s in stellen {
            switch s.art {
            case .lauter:       zeilen.append("LAUTER \(z(s.von))-\(z(s.bis)) +\(z(s.wert)) LU")
            case .leiser:       zeilen.append("LEISER \(z(s.von))-\(z(s.bis)) \(z(s.wert)) LU")
            case .pause:        zeilen.append("PAUSE \(z(s.von))-\(z(s.bis))")
            case .uebersteuert: zeilen.append("UEBERSTEUERT \(z(s.von, 3))-\(z(s.bis, 3))")
            case .knackser:     zeilen.append("KNACKSER \(z(s.von, 3))")
            case .aussetzer:    zeilen.append("AUSSETZER \(z(s.von, 3))-\(z(s.bis, 3))")
            }
        }
        if stellen.isEmpty { zeilen.append("OK") }
        return zeilen.joined(separator: "\n")
    }
}

/// Alle Schwellen an einem Ort, zum Nachjustieren. Pegel in LU/LUFS/dBFS, Zeiten in Sekunden.
enum PruefSchwelle {
    // Lauter/leiser gegen den Bezugspegel (Median der Kurzzeitwerte, 3-s-Fenster).
    static let bezugUnterGesamt = 20.0      // Kurzzeitwerte, die mehr als 20 LU unter dem Gesamtwert liegen, zählen nicht
    // 6 LU: Gemessen am 26.11.2026 meldeten bei 5 LU normale Podcast-Folgen mit Musik bis zu sieben Stellen
    // (Das-Kreuz_01: Zwischenmusiken 5,5 bis 6,7 LU über der Sprache). Bei 6 LU bleibt dort höchstens eine, und die
    // acht Tagesgeschichten mit zu lautem Jingle (7,3 bis 8,2 LU) melden weiter alle.
    static let lauterLU = 6.0, lauterDauer = 2.0
    static let leiserLU = 8.0, leiserDauer = 5.0
    static let streckenLuecke = 1.0         // Strecken mit kleinerer Lücke werden eine
    static let pegelAbDauer = 10.0          // kürzere Dateien: keine Lauter/Leiser-Prüfung
    // Pause: 100-ms-Rahmen unter min(-45, max(-60, Bezug - 32)) LUFS, länger als 4 s.
    static let pauseDauer = 4.0, pauseHoechstens = -45.0, pauseMindestens = -60.0, pauseUnterBezug = 32.0
    // Übersteuerung. Verlustbehaftete Dateien (MP3, AAC) brauchen einen Lauf von 4, Begründung in `lautheitUndSpitzen`.
    static let kappPegel: Float = 0.9995, kappLauf = 3, kappLaufVerlustbehaftet = 4, kappLuecke = 0.050
    // Knackser (siehe `pruefeRahmen`). Gemessen am 26.11.2026 mit 54 eingebauten Knacksern in den elf echten Bounces
    // (WAV und MP3 192k) und an den elf Bounces selbst in fünf Fassungen (Original-MP3, 48-kHz-WAV, Mono, MP3 128k,
    // AAC 128k): Fremde Kandidaten erreichten mit allen übrigen Bedingungen höchstens 16,4 dB, eingebaute Knackser
    // in WAV meist über 22 dB, in MP3 rund 6 dB weniger (der Kodierer verschmiert den Impuls).
    static let knackDB = 20.0               // so weit muss die Spitze des Vorhersagefehlers über dem Umfeld liegen
    static let knackVorDB = 6.0             // Kandidaten bis so weit darunter zählen für die Dichte mit
    // Nur 1 ms breit. Zuerst galten 3 ms; damit meldeten 96 echte Sprachdateien 12 Stellen und eine Podcast-Folge
    // eine weitere, und Joshua hörte in keiner einen Knackser (26.11.2026). 12 dieser 13 Stellen waren 2 oder 3 ms
    // breit, von den eingebauten Knacksern dagegen fast alle 1 ms (WAV 45 von 50, MP3 21 von 22).
    static let knackBreiteDB = 12.0, knackBreite = 1   // höchstens 1 ms liegt weniger als 12 dB unter der Spitze
    // Kein Einsatz: Der 13. Fehlalarm (für_dich_und_für_mich, 5,34 s) saß am Anfang eines Wortes nach einer Pause,
    // davor -46 dBFS, danach -23 dBFS. Ein harter Einsatz klingt wie ein Anschlag, nicht wie ein Knackser. Nicht
    // gemeldet wird deshalb, wo (1) eine Seite still ist (unter -40 dBFS), (2) die andere mindestens 15 dB lauter
    // und (3) der Klang auf der lauten Seite gleich weitergeht: Die 5 ms neben der Spitze liegen höchstens 10 dB
    // unter ihr. Ein Impuls neben einem Wort fällt dagegen sofort wieder ab und wird gemeldet.
    // Gemessen an 104 eingebauten Knacksern: Ohne (1) fiel die Quote in WAV von 89 auf 72 % (Sprache schwankt
    // auch innerhalb von 50 ms um mehr als 15 dB), ohne (3) auf 74 %. Mit 10 dB bei (3) blieb der Fehlalarm
    // stehen, mit 15 dB ist er weg; die Quote sinkt dadurch um höchstens ein Prozent.
    // Stand mit allen Regeln (26.11.2026): 115 fehlerfreie Dateien (96 Tagesgeschichten und Gebete, 8 Podcast-
    // Folgen und Jingles, die 11 Bounces vom Vormittag) melden keinen Knackser; von den eingebauten werden in
    // WAV 85 % gefunden, in MP3 54 %. Das ist der Preis für null Fehlalarme.
    static let knackKante = 15.0, knackStill = -40.0, knackWeiter = -15.0
    static let knackUmfeld = 50             // ms beiderseits als Vergleich
    // Die Spitze des Vorhersagefehlers muss mindestens -25 dBFS erreichen (ein Sprung von etwa 0,06). Leisere
    // Kandidaten waren in den echten Bounces Schmatzer in Sprechpausen (blühende_zweige 85,49 s: zwei Ticks bei
    // -26 dBFS in Raumton von -56 dBFS) und Einsätze nach Stille in AAC; ein eingebauter Sprung von 0,1 erreicht
    // -18 dBFS (WAV) bzw. -22 dBFS (MP3).
    static let knackLeise = -25.0
    // Und sie darf höchstens 12 dB unter der Signalspitze des Rahmens liegen: Beim Knackser ist der Impuls selbst
    // das Signal (gemessen -6 bis +5 dB), ein natürlicher Einsatz ist zum größten Teil vorhersagbar (-9 bis -29 dB).
    static let knackGegenSignal = -12.0
    static let knackDichteFenster = 10.0, knackDichteMax = 5   // mehr Kandidaten in 10 s: das ist Material (Schlagzeug)
    static let knackRand = 0.005            // s am Dateianfang und -ende: dort fehlt dem Prädiktor das Umfeld
    // Aussetzer: ein Loch unter -70 dBFS von 10 ms bis 4 s, davor und danach binnen `lochRand` ms über -35 dBFS.
    // Die Obergrenze stand zuerst bei 1 s. Geeicht an echten Fehlern (26.11.2026): die WAV-Exporte der Staffel
    // „Jesus der Jude“ für den ERF vom Sommer 2026, in denen der Ton auf einem 16-Sekunden-Raster für 1,0 s oder
    // 1,9 s abreißt (Bounce auf einem überlasteten Rechner). Mit 4 s meldet die Prüfung für die Dateien 02 bis 07
    // und 11: 0, 0, 26, 1, 1, 13, 10 Aussetzer. Der ERF hatte dieselben Dateien als in Ordnung, einzelne, alle
    // paar Sekunden, einzelne, einzelne, alle paar Sekunden, alle paar Sekunden beschrieben (nur bei 03 hörte er
    // einzelne, die Prüfung findet keine). Mit 1 s fielen die 1,9-s-Löcher in 07 und 11 ganz durch. Über 4 s ist
    // es eine Pause und wird als solche gemeldet.
    // Beide Seiten müssen laut sein. Mit nur einer harten Kante meldete die fehlerfreie Datei 02 405 Stellen:
    // Die Sprache ist dort mit einem Gate geschnitten, jeder Einsatz nach digitaler Stille sieht so aus.
    // MP3 verschmiert die Kanten: Ein 50-ms-Loch in Sprache kam aus LAME 192k über Apples Dekoder mit bis zu 18 ms
    // Übergang bei -50 bis -65 dBFS zurück, darin nur noch 20 ms unter -70. Deshalb zählt zum Loch ein Rand unter
    // `lochKante` von höchstens `lochVerschmiert` ms; außerhalb davon muss es laut sein, und zwar sprunghaft:
    // mindestens `lochSprung` dB über dem Rand. Ohne diese Bedingung meldete eine natürliche Sprechpause mit
    // leisem Raumton (ein_engel_kommt_zu_maria, 6 dB leiser, 55,7 s) einen Aussetzer.
    static let lochLeise = -70.0, lochLaut = -35.0, lochKurz = 0.010, lochLang = 4.0, lochRand = 5   // Rand in ms
    static let lochKante = -45.0, lochVerschmiert = 25, lochSprung = 25.0                            // ms, dB
}

enum BouncePruefung {
    static func pruefe(_ pfad: String) throws -> PruefBefund {
        let datei = try AVAudioFile(forReading: URL(fileURLWithPath: pfad))
        let format = datei.processingFormat
        let id = (datei.fileFormat.settings[AVFormatIDKey] as? NSNumber)?.uint32Value
        let a = Analyse(rate: format.sampleRate, kanaele: Int(format.channelCount), verlustfrei: id == kAudioFormatLinearPCM)
        guard let puffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, format.sampleRate.rounded()))),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved
        else { throw NSError(domain: "BouncePruefung", code: 1, userInfo: [NSLocalizedDescriptionKey: "Format nicht lesbar"]) }
        while datei.framePosition < datei.length {
            try datei.read(into: puffer)
            let k = Int(puffer.frameLength)
            if k == 0 { break }
            a.verarbeite(puffer.floatChannelData!, k)
        }
        return a.befund()
    }
}

/// Der Zustand einer Prüfung. Lebt nur für eine Datei, deshalb aus jedem Thread aufrufbar.
private final class Analyse {
    let rate: Double, n: Int, verlustfrei: Bool
    var gelesen = 0                     // Samples je Kanal bisher

    // --- Lautheit (ITU-R BS.1770-4) ---
    // K-Bewertung als zwei Biquads, Koeffizienten aus den analogen Prototypen für die tatsächliche Rate berechnet
    // (wie libebur128). Die festen 48-kHz-Werte auf 44,1 kHz angewandt verschieben die Kurve um rund 0,1 dB.
    let k1: [Double], k2: [Double]      // b0 b1 b2 a1 a2
    var kz: [Double]                    // je Kanal 4 Zustände (2 je Stufe, transponierte Direktform II)
    let gewicht: [Double]
    let rahmen100: Int                  // Samples je 100 ms
    var rahmenSumme = 0.0, rahmenFuell = 0
    var energie: [Double] = []          // je 100 ms: gewichtete mittlere Leistung über die Kanäle
    var restEnergie: Double?            // angebrochener letzter Rahmen, nur für die Pausensuche

    // --- Spitze und Übersteuerung ---
    var spitze: Float = 0
    var kappLauf: [Int], kappStart: [Int]
    var kappStellen: [(Int, Int)] = []  // Samplebereiche, schon zusammengefasst

    // --- Knackser und Aussetzer: 1-ms-Rahmen über das Restsignal einer linearen Vorhersage ---
    let ordnung = 16                    // 32 war nicht besser: mehr Kandidaten in fehlerfreien Dateien
    let ms: Int                         // Samples je Rahmen (44 bei 44,1 kHz)
    let schritt: Int, kontext: Int, fenster: Int   // Vorhersage-Schritt 10 ms, Fenster 30 ms mittig darum
    let hann: [Float]
    var puffer: [[Float]]               // je Kanal: `kontext` Samples Vorgeschichte + noch nicht bearbeitete Samples
    var offen = 0                       // davon noch nicht bearbeitet
    var rest: [Float], fen: [Float], filt: [Float]
    var resFr: [[Float]]                // je Kanal und Rahmen: höchster Betrag des Vorhersagefehlers
    var sigFr: [Float] = []             // je Rahmen: höchster Betrag des Signals über alle Kanäle
    var frBasis = 0, frGeprueft = 0, frGesamt = 0
    var umfeld: [Float]
    var kandidaten: [(rahmen: Int, db: Double)] = []
    var lochKern: Int?, lochStart = 0, lochVorher = false
    var loecher: [(Int, Int)] = []

    init(rate: Double, kanaele: Int, verlustfrei: Bool) {
        self.rate = rate; n = kanaele; self.verlustfrei = verlustfrei
        // Stufe 1: Hochregal (+4 dB über ~1,7 kHz), Stufe 2: RLB-Hochpass (~38 Hz).
        var K = tan(Double.pi * 1681.974450955533 / rate)
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416), q1 = 0.7071752369554196
        var a0 = 1 + K / q1 + K * K
        k1 = [(vh + vb * K / q1 + K * K) / a0, 2 * (K * K - vh) / a0, (vh - vb * K / q1 + K * K) / a0,
              2 * (K * K - 1) / a0, (1 - K / q1 + K * K) / a0]
        K = tan(Double.pi * 38.13547087602444 / rate)
        let q2 = 0.5003270373238773
        a0 = 1 + K / q2 + K * K
        k2 = [1, -2, 1, 2 * (K * K - 1) / a0, (1 - K / q2 + K * K) / a0]
        kz = [Double](repeating: 0, count: 4 * kanaele)
        // Gewichte nach BS.1770: L, R, C je 1, Surround 1,41, LFE 0 (nur bei 5.1). Mono ist ein Kanal mit Gewicht 1.
        gewicht = kanaele == 6 ? [1, 1, 1, 0, 1.41, 1.41] : [Double](repeating: 1, count: kanaele)
        rahmen100 = max(1, Int((rate / 10).rounded()))
        kappLauf = [Int](repeating: 0, count: kanaele); kappStart = kappLauf
        ms = max(1, Int((rate / 1000).rounded()))
        schritt = 10 * ms; kontext = 10 * ms; fenster = schritt + 2 * kontext
        var h = [Float](repeating: 0, count: fenster)
        vDSP_hann_window(&h, vDSP_Length(fenster), Int32(vDSP_HANN_DENORM))
        hann = h
        puffer = [[Float]](repeating: [Float](repeating: 0, count: kontext), count: kanaele)
        rest = [Float](repeating: 0, count: schritt); fen = [Float](repeating: 0, count: fenster)
        filt = [Float](repeating: 0, count: ordnung + 1)
        resFr = [[Float]](repeating: [], count: kanaele)
        umfeld = []; umfeld.reserveCapacity(2 * PruefSchwelle.knackUmfeld)
    }

    func verarbeite(_ daten: UnsafePointer<UnsafeMutablePointer<Float>>, _ k: Int) {
        lautheitUndSpitzen(daten, k)
        for c in 0..<n { puffer[c].append(contentsOf: UnsafeBufferPointer(start: daten[c], count: k)) }
        gelesen += k; offen += k
        vorhersage(ende: false)
    }

    // MARK: Lautheit, Spitze, Übersteuerung

    // Übersteuerung. Gemessen am 26.11.2026 (macOS 27, AVAudioFile): Apples MP3-Dekoder kappt bei genau ±1.0,
    // ffmpeg liefert dieselbe Datei bis 1,47. Folgen:
    // - Ein Bounce mit Limiter bei -0,1 dBFS, als MP3 kodiert (LAME 192k/128k), überschwingt: 33 bis 110 einzelne
    //   Samples auf genau 1.0, längster Lauf 2 Samples (auch bei 16 dB in den Limiter). Ein einzelnes Sample auf 1.0
    //   heißt in MP3 also nichts; dort zählt erst ein Lauf von 4.
    // - Echte Sprache 12 dB übersteuert und hart gekappt, dann MP3: Läufe bis 10 Samples auf 1.0, 900 Läufe ab 3.
    // - Tieffrequentes Material (Grundton 150 Hz, vier Harmonische) gekappt und als MP3 kodiert, kommt mit höchstens
    //   0,99 zurück, ohne jeden Lauf: Solche Übersteuerung ist in MP3 aus den Samples nicht zu erkennen.
    // - Die echten Logic-Bounces von heute (MP3 160k) erreichen höchstens 0,991, kein Sample auf 1.0.
    // In WAV/AIFF bleibt die Regel wie verlangt: ein Sample ab 1.0 (Float-WAV über 0 dBFS; 16 Bit erreicht -1.0)
    // oder 3 Samples in Folge ab 0,9995 (gekappte 16-Bit-Spitzen liegen bei 32767/32768).
    func lautheitUndSpitzen(_ daten: UnsafePointer<UnsafeMutablePointer<Float>>, _ k: Int) {
        var quadrate = [Double](repeating: 0, count: k)   // gewichtete K-Leistung je Sample, über die Kanäle summiert
        var treffer: [(Int, Int)] = []
        let b1 = k1, b2 = k2
        let mindestLauf = verlustfrei ? PruefSchwelle.kappLauf : PruefSchwelle.kappLaufVerlustbehaftet
        for c in 0..<n {
            let x = daten[c], g = gewicht[c]
            var s1 = kz[4 * c], s2 = kz[4 * c + 1], s3 = kz[4 * c + 2], s4 = kz[4 * c + 3]
            var lauf = kappLauf[c], start = kappStart[c]
            var sp: Float = 0
            quadrate.withUnsafeMutableBufferPointer { q in
                for i in 0..<k {
                    let v = x[i], d = v.isFinite ? Double(v) : 0   // ein NaN verdürbe den Filter für immer
                    let y1 = b1[0] * d + s1
                    s1 = b1[1] * d - b1[3] * y1 + s2
                    s2 = b1[2] * d - b1[4] * y1
                    let y2 = y1 + s3                     // b0 = 1, b1 = -2, b2 = 1
                    s3 = -2 * y1 - b2[3] * y2 + s4
                    s4 = y1 - b2[4] * y2
                    q[i] += g * y2 * y2
                    let a = abs(v)
                    if a > sp { sp = a }
                    if a >= PruefSchwelle.kappPegel {
                        if lauf == 0 { start = gelesen + i }
                        lauf += 1
                        if lauf >= mindestLauf || (verlustfrei && a >= 1) {
                            if let l = treffer.last, l.0 == start { treffer[treffer.count - 1].1 = gelesen + i }
                            else { treffer.append((start, gelesen + i)) }
                        }
                    } else { lauf = 0 }
                }
            }
            // Ein Lauf über die Blockgrenze gibt im nächsten Block einen eigenen Treffer, das Zusammenfassen fängt ihn.
            kz[4 * c] = s1; kz[4 * c + 1] = s2; kz[4 * c + 2] = s3; kz[4 * c + 3] = s4
            kappLauf[c] = lauf; kappStart[c] = start
            if sp > spitze { spitze = sp }
        }
        for i in 0..<k {
            rahmenSumme += quadrate[i]; rahmenFuell += 1
            if rahmenFuell == rahmen100 { energie.append(rahmenSumme / Double(rahmen100)); rahmenSumme = 0; rahmenFuell = 0 }
        }
        restEnergie = rahmenFuell > 0 ? rahmenSumme / Double(rahmenFuell) : nil
        let luecke = Int(PruefSchwelle.kappLuecke * rate)
        for t in treffer.sorted(by: { $0.0 < $1.0 }) {
            if let l = kappStellen.last, t.0 - l.1 < luecke { kappStellen[kappStellen.count - 1].1 = max(l.1, t.1) }
            else { kappStellen.append(t) }
        }
    }

    // MARK: Lineare Vorhersage

    // Warum Vorhersagefehler statt Hochpass oder zweiter Differenz: Zischlaute haben selbst viel Energie über
    // 5 kHz, die zweite Differenz sieht in ihnen „Sprünge“ (der Falschalarm von früher). Ein Prädiktor 16. Ordnung,
    // alle 10 ms neu aus einem 30-ms-Fenster mittig um den Schritt geschätzt, sagt Zischlaut, Vokal und Musik gut
    // voraus. Was er nicht vorhersagen kann, ist ein Sprung oder Impuls, der nicht zum Klang ringsum passt.
    // Gemessen (26.11.2026): Ein Fenster nur aus der Vergangenheit (48 ms, Schritt 24 ms) passt nach einem
    // Lautwechsel nicht mehr; der Vorhersagefehler wurde dann im Zischlaut größer als das Signal selbst und
    // lieferte 27-dB-Kandidaten in fehlerfreien Dateien.
    func vorhersage(ende: Bool) {
        if ende { for c in 0..<n { puffer[c].append(contentsOf: repeatElement(0, count: fenster)) } }
        var bearbeitet = 0
        while offen > 0 && puffer[0].count - bearbeitet >= fenster {
            let rahmen = min(schritt, offen) / ms
            var sig = [Float](repeating: 0, count: rahmen)
            for c in 0..<n {
                puffer[c].withUnsafeBufferPointer { p in
                    let anfang = p.baseAddress! + bearbeitet          // Fensteranfang, der Schritt liegt in der Mitte
                    vDSP_vmul(anfang, 1, hann, 1, &fen, 1, vDSP_Length(fenster))
                    koeffizienten()
                    let x = anfang + kontext
                    vDSP_conv(x - ordnung, 1, filt, 1, &rest, 1, vDSP_Length(schritt), vDSP_Length(ordnung + 1))
                    rest.withUnsafeBufferPointer { e in
                        for r in 0..<rahmen {
                            var m: Float = 0, s: Float = 0
                            vDSP_maxmgv(e.baseAddress! + r * ms, 1, &m, vDSP_Length(ms))
                            vDSP_maxmgv(x + r * ms, 1, &s, vDSP_Length(ms))
                            resFr[c].append(m)
                            if s > sig[r] { sig[r] = s }
                        }
                    }
                }
            }
            sigFr.append(contentsOf: sig)
            frGesamt += rahmen
            offen -= min(schritt, offen)
            bearbeitet += schritt
        }
        if bearbeitet > 0 { for c in 0..<n { puffer[c].removeFirst(bearbeitet) } }
        pruefeRahmen(ende: ende)
    }

    /// Levinson-Durbin über die Autokorrelation von `fen`, Ergebnis als Faltungskern in `filt`
    /// (filt[p - j] = a_j, filt[p] = 1, damit vDSP_conv e[i] = x[i] + Σ a_j x[i-j] liefert).
    func koeffizienten() {
        let p = ordnung
        var r = [Double](repeating: 0, count: p + 1)
        fen.withUnsafeBufferPointer { w in
            for l in 0...p { var s: Float = 0; vDSP_dotpr(w.baseAddress!, 1, w.baseAddress! + l, 1, &s, vDSP_Length(fenster - l)); r[l] = Double(s) }
        }
        for i in 0..<p { filt[i] = 0 }
        filt[p] = 1
        guard r[0] > 1e-12 else { return }
        r[0] *= 1.0001                   // 40 dB Grundrauschen: hält die Rekursion bei fast reinen Tönen stabil
        var a = [Double](repeating: 0, count: p + 1), alt = a
        a[0] = 1
        var fehler = r[0]
        for i in 1...p {
            var acc = r[i]
            for j in 1..<i { acc += a[j] * r[i - j] }
            let kk = -acc / fehler
            alt = a
            for j in 1..<i { a[j] = alt[j] + kk * alt[i - j] }
            a[i] = kk
            fehler *= 1 - kk * kk
            if fehler <= 0 { break }
        }
        for j in 1...p { filt[p - j] = Float(a[j]) }
    }

    // MARK: Knackser und Aussetzer

    func pruefeRahmen(ende: Bool) {
        let u = PruefSchwelle.knackUmfeld
        let bis = ende ? frGesamt : frGesamt - u
        let leise = Float(pow(10, PruefSchwelle.knackLeise / 20))
        let lochLeise = Float(pow(10, PruefSchwelle.lochLeise / 20)), lochLaut = Float(pow(10, PruefSchwelle.lochLaut / 20))
        let rand = PruefSchwelle.lochRand, verschmiert = PruefSchwelle.lochVerschmiert
        let kante = Float(pow(10, PruefSchwelle.lochKante / 20)), sprung = Float(pow(10, PruefSchwelle.lochSprung / 20))
        let breiteFaktor = Float(pow(10, -PruefSchwelle.knackBreiteDB / 20))
        let gegenSignal = Float(pow(10, PruefSchwelle.knackGegenSignal / 20))
        while frGeprueft < bis {
            let j = frGeprueft, i = j - frBasis
            let anz = frGesamt - frBasis
            // Knackser: je Kanal ist der Rahmen eine schmale, hohe Spitze im Vorhersagefehler.
            var bestes = -Double.infinity
            for c in 0..<n {
                let res = resFr[c], p = res[i]
                guard p >= leise, p >= sigFr[i] * gegenSignal else { continue }
                var spitzeHier = true
                for d in 1...3 {
                    if i - d >= 0 && res[i - d] >= p { spitzeHier = false }
                    if i + d < anz && res[i + d] > p { spitzeHier = false }
                }
                guard spitzeHier else { continue }
                var breite = 0
                for d in -10...10 where i + d >= 0 && i + d < anz && res[i + d] >= p * breiteFaktor { breite += 1 }
                guard breite <= PruefSchwelle.knackBreite else { continue }
                // Davor und danach muss es ähnlich laut sein (Median der Rahmenspitzen je Seite), siehe knackKante.
                var seiten: [Float] = []
                for seite in [-1, 1] {
                    umfeld.removeAll(keepingCapacity: true)
                    for d in 4...u where i + seite * d >= 0 && i + seite * d < anz { umfeld.append(sigFr[i + seite * d]) }
                    if umfeld.count >= 10 { umfeld.sort(); seiten.append(max(1e-6, umfeld[umfeld.count / 2])) }
                }
                if seiten.count == 2, 20 * log10(Double(min(seiten[0], seiten[1]))) < PruefSchwelle.knackStill,
                   abs(20 * log10(Double(seiten[0] / seiten[1]))) > PruefSchwelle.knackKante {
                    let laut = seiten[0] > seiten[1] ? -1 : 1
                    umfeld.removeAll(keepingCapacity: true)
                    for d in 1...5 where i + laut * d >= 0 && i + laut * d < anz { umfeld.append(sigFr[i + laut * d]) }
                    umfeld.sort()
                    if let mitte = umfeld.isEmpty ? nil : umfeld[umfeld.count / 2],
                       mitte >= sigFr[i] * Float(pow(10, PruefSchwelle.knackWeiter / 20)) { continue }
                }
                // Vergleich mit beiden Seiten getrennt, der lautere Median zählt: Ein Einsatz nach einer Pause
                // (Plosiv nach Stille) ragt nur über die stille Seite hinaus, ein Knackser über beide.
                var bezug: Float = 1e-7
                for seite in [-1, 1] {
                    umfeld.removeAll(keepingCapacity: true)
                    for d in 4...u where i + seite * d >= 0 && i + seite * d < anz { umfeld.append(res[i + seite * d]) }
                    if umfeld.count >= 10 { umfeld.sort(); bezug = max(bezug, umfeld[umfeld.count / 2]) }
                }
                bestes = max(bestes, 20 * log10(Double(p / bezug)))
            }
            if bestes >= PruefSchwelle.knackDB - PruefSchwelle.knackVorDB { kandidaten.append((j, bestes)) }
            // Aussetzer: ein Kern unter -70 dBFS; von ihm aus durch den verschmierten Rand (unter -45 dBFS, höchstens
            // 25 ms) nach außen, dort muss binnen 5 ms Klang stehen, der über -35 dBFS und mindestens 25 dB über dem
            // Rand liegt. Natürliche Pausen klingen über viele Millisekunden aus und scheitern an diesem Sprung.
            // Die Rahmen links vom Kern sind beim Eintritt noch im Puffer, die rechts liegen im Vorlauf von 50 ms.
            if sigFr[i] < lochLeise {
                if lochKern == nil {
                    var b = i, randMax: Float = 0
                    while b > 0 && i - b < verschmiert && sigFr[b - 1] < kante { b -= 1; randMax = max(randMax, sigFr[b]) }
                    let laut = max(lochLaut, randMax * sprung)
                    lochKern = j; lochStart = j - (i - b)
                    lochVorher = (max(0, b - rand)..<b).contains { sigFr[$0] >= laut }
                }
            } else if let k = lochKern {
                var e = i, randMax: Float = 0
                while e < anz && e - i < verschmiert && sigFr[e] < kante { randMax = max(randMax, sigFr[e]); e += 1 }
                let laut = max(lochLaut, randMax * sprung)
                let nachher = (e..<min(anz, e + rand)).contains { sigFr[$0] >= laut }
                let ende = j + (e - i), dauer = Double((ende - lochStart) * ms) / rate
                if lochVorher && nachher && j - k >= 3 && dauer >= PruefSchwelle.lochKurz && dauer <= PruefSchwelle.lochLang {
                    loecher.append((lochStart, ende))
                }
                lochKern = nil
            }
            frGeprueft += 1
        }
        // Alte Rahmen wegwerfen, das Umfeld (und der Rand für die Aussetzer) bleibt.
        let weg = frGeprueft - u - 20 - frBasis
        if weg > 4096 {
            for c in 0..<n { resFr[c].removeFirst(weg) }
            sigFr.removeFirst(weg)
            frBasis += weg
        }
    }

    // MARK: Ergebnis

    func befund() -> PruefBefund {
        vorhersage(ende: true)
        let dauer = Double(gelesen) / rate
        func lufs(_ e: Double) -> Double { e > 0 ? -0.691 + 10 * log10(e) : -200 }

        // Gesamtlautheit: 400-ms-Blöcke im 100-ms-Takt, absolut bei -70 LUFS, relativ 10 LU unter dem Mittel gegatet.
        var bloecke: [Double] = []
        if energie.count >= 4 { for j in 3..<energie.count { bloecke.append((energie[j - 3] + energie[j - 2] + energie[j - 1] + energie[j]) / 4) } }
        let absolut = bloecke.filter { lufs($0) > -70 }
        var gesamt = -70.0
        if !absolut.isEmpty {
            let relativ = lufs(absolut.reduce(0, +) / Double(absolut.count)) - 10
            let rel = absolut.filter { lufs($0) > relativ }
            if !rel.isEmpty { gesamt = max(-70, lufs(rel.reduce(0, +) / Double(rel.count))) }
        }

        // Kurzzeitwerte: 3 s im 100-ms-Takt, Zeit = Fenstermitte.
        var kurz: [(mitte: Double, wert: Double, ab: Int)] = []
        if energie.count >= 30 {
            var summe = energie[0..<30].reduce(0, +)
            for j in 29..<energie.count {
                if j > 29 { summe += energie[j] - energie[j - 30] }
                kurz.append((Double(j + 1) * 0.1 - 1.5, lufs(max(0, summe) / 30), j - 29))
            }
        }
        let gueltig = kurz.map(\.wert).filter { $0 > -70 && $0 >= gesamt - PruefSchwelle.bezugUnterGesamt }.sorted()
        var bezug = gesamt
        if !gueltig.isEmpty {
            let m = gueltig.count / 2
            bezug = gueltig.count % 2 == 1 ? gueltig[m] : (gueltig[m - 1] + gueltig[m]) / 2
        }

        var stellen: [PruefStelle] = []

        // Pausen.
        let stillUnter = min(PruefSchwelle.pauseHoechstens, max(PruefSchwelle.pauseMindestens, bezug - PruefSchwelle.pauseUnterBezug))
        var rahmen = energie
        if let r = restEnergie { rahmen.append(r) }
        var still = rahmen.map { lufs($0) < stillUnter }
        var j = 0
        while j < still.count {
            guard still[j] else { j += 1; continue }
            var e = j
            while e < still.count && still[e] { e += 1 }
            let von = Double(j) * 0.1, bis = min(dauer, Double(e) * 0.1)
            if bis - von > PruefSchwelle.pauseDauer { stellen.append(PruefStelle(art: .pause, von: von, bis: bis, wert: 0)) }
            else { for x in j..<e { still[x] = false } }   // kurze Stille ist keine Pause, zählt aber für leiser (unten)
            j = e
        }

        // Lauter und leiser.
        if dauer >= PruefSchwelle.pegelAbDauer && !kurz.isEmpty {
            func strecken(_ passt: (Int) -> Bool, mindestens: Double, art: PruefArt) {
                var liste: [(a: Int, b: Int)] = []
                for (i, _) in kurz.enumerated() where passt(i) {
                    // Lücke zwischen zwei Strecken = Abstand der Fenstermitten minus ein Schritt von 0,1 s.
                    if let l = liste.last, kurz[i].mitte - kurz[l.b].mitte - 0.1 < PruefSchwelle.streckenLuecke - 1e-9 {
                        liste[liste.count - 1].b = i
                    } else { liste.append((i, i)) }
                }
                // Eine Strecke ab dem ersten Fenster reicht bis zum Dateianfang (das erste Fenster hat seine Mitte
                // erst bei 1,5 s), eine bis zum letzten Fenster bis zum Dateiende. So wird sie auch gemessen: Ein
                // 4-s-Jingle am Anfang ergab an den Fenstermitten nur 1,5–3,3 s (der_engel_hat_gute_nachricht).
                for s in liste {
                    let von = s.a == 0 ? 0 : kurz[s.a].mitte, bis = s.b == kurz.count - 1 ? dauer : kurz[s.b].mitte
                    guard bis - von >= mindestens else { continue }
                    let werte = (s.a...s.b).filter(passt).map { kurz[$0].wert - bezug }
                    stellen.append(PruefStelle(art: art, von: von, bis: bis, wert: werte.reduce(0, +) / Double(werte.count)))
                }
            }
            strecken({ kurz[$0].wert >= bezug + PruefSchwelle.lauterLU }, mindestens: PruefSchwelle.lauterDauer, art: .lauter)
            // Leiser zählt nur, wo das Fenster keine Pause berührt: Eine Pause ist schon gemeldet.
            strecken({ i in
                let a = kurz[i].ab
                return kurz[i].wert <= bezug - PruefSchwelle.leiserLU && !(a..<(a + 30)).contains { still[$0] }
            }, mindestens: PruefSchwelle.leiserDauer, art: .leiser)
        }

        for (a, b) in kappStellen {
            stellen.append(PruefStelle(art: .uebersteuert, von: Double(a) / rate, bis: Double(b + 1) / rate, wert: 0))
        }

        // Knackser: Kandidaten binnen 10 ms sind ein Ereignis. Wo sie sich häufen, ist es das Material (Schlagzeug,
        // Perkussion) und kein Fehler: Diese Strecken werden nicht gemeldet.
        var ereignisse: [(rahmen: Int, db: Double)] = []
        for k in kandidaten {
            if let l = ereignisse.last, k.rahmen - l.rahmen <= 10 { if k.db > l.db { ereignisse[ereignisse.count - 1] = k } }
            else { ereignisse.append(k) }
        }
        let halb = PruefSchwelle.knackDichteFenster / 2
        let zeit = { (r: Int) -> Double in Double(r * self.ms) / self.rate }
        for (a, b) in loecher { stellen.append(PruefStelle(art: .aussetzer, von: zeit(a), bis: zeit(b), wert: 0)) }
        for e in ereignisse where e.db >= PruefSchwelle.knackDB {
            let t = zeit(e.rahmen) + 0.0005
            guard t >= PruefSchwelle.knackRand, t <= dauer - PruefSchwelle.knackRand,
                  ereignisse.filter({ abs(zeit($0.rahmen) - t) <= halb }).count <= PruefSchwelle.knackDichteMax,
                  // Die Kanten eines Aussetzers knacken selbst, gekappte Spitzen auch; beides ist schon gemeldet.
                  !loecher.contains(where: { abs(zeit($0.0) - t) < 0.015 || abs(zeit($0.1) - t) < 0.015 }),
                  !kappStellen.contains(where: { Double($0.0) / rate - 0.010 <= t && t <= Double($0.1) / rate + 0.010 })
            else { continue }
            stellen.append(PruefStelle(art: .knackser, von: t, bis: t, wert: 0))
        }

        stellen.sort { $0.von < $1.von }
        let spitzeDB = spitze > 0 ? max(-120, 20 * log10(Double(spitze))) : -120
        return PruefBefund(dauer: dauer, rate: rate, kanaele: n, lufs: gesamt, spitze: spitzeDB, bezug: bezug, stellen: stellen)
    }
}
