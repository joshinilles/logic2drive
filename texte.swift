// Logic2Drive – Mehrsprachigkeit.
//
// Im Quelltext stehen die deutschen Texte: L("„\(name)“ liegt jetzt als Zip in Google Drive.")
// Daraus wird der Schlüssel „%@“ liegt jetzt als Zip in Google Drive. (jede Einfügung wird zu %@), und unter
// diesem Schlüssel steht die Übersetzung in sprachen/<Sprache>.lproj/Localizable.strings. Eine Übersetzung darf
// die Einfügungen umstellen: %1$@, %2$@. Fehlt ein Eintrag, erscheint der deutsche Text.
// test/texte.py prüft, ob jede Sprache jeden Schlüssel hat.

import Foundation

let sprachen = ["de", "en", "fr", "ar", "fa"]

/// Die Sprache des Macs, wenn der Helfer sie kann, sonst Englisch. LOGIC2DRIVE_SPRACHE legt sie fest (für Tests).
let sprache: String = {
    if let s = ProcessInfo.processInfo.environment["LOGIC2DRIVE_SPRACHE"]?.lowercased(), sprachen.contains(s) { return s }
    for wunsch in Locale.preferredLanguages {
        let kurz = String(wunsch.lowercased().prefix { $0 != "-" && $0 != "_" })
        if sprachen.contains(kurz) { return kurz }
    }
    return "en"
}()

let sprachBundle: Bundle? = sprache == "de" ? nil
    : Bundle.main.path(forResource: sprache, ofType: "lproj").flatMap { Bundle(path: $0) }

/// Arabisch und Farsi laufen von rechts nach links.
let vonRechts = sprache == "ar" || sprache == "fa"

/// macOS selbst hat eine arabische Oberfläche, aber keine persische: Auf einem persisch eingestellten Mac bleibt
/// die Menüleiste linksläufig, und das Zeichen des Helfers sitzt weiter oben rechts.
let menueleisteVonRechts = sprache == "ar"

/// Ein Text mit Einfügungen. Aus "Hallo \(name)" wird der Schlüssel "Hallo %@" und die Werteliste [name].
struct Txt: ExpressibleByStringInterpolation {
    var schluessel: String
    var werte: [String]

    init(stringLiteral wert: String) {
        schluessel = wert.replacingOccurrences(of: "%", with: "%%")
        werte = []
    }

    init(stringInterpolation i: Einfuegung) {
        schluessel = i.schluessel
        werte = i.werte
    }

    struct Einfuegung: StringInterpolationProtocol {
        var schluessel = ""
        var werte: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ text: String) { schluessel += text.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation<T>(_ wert: T) {
            schluessel += "%@"
            werte.append(String(describing: wert))
        }
    }
}

/// Setzt die Werte in ein Muster ein: %@ der Reihe nach, %2$@ gezielt, %% wird zu %.
/// Bewusst von Hand und nicht mit String(format:), damit eine fehlerhafte Übersetzung nichts abstürzen lässt.
func setzeWerteEin(_ muster: String, _ werte: [String]) -> String {
    var aus = ""
    var naechster = 0
    var z = Array(muster)[...]
    while let c = z.first {
        z = z.dropFirst()
        guard c == "%" else { aus.append(c); continue }
        if z.first == "%" { aus.append("%"); z = z.dropFirst(); continue }
        if z.first == "@" {
            z = z.dropFirst()
            if naechster < werte.count { aus += werte[naechster] }
            naechster += 1
            continue
        }
        let ziffern = z.prefix { $0.isNumber }
        let rest = z.dropFirst(ziffern.count)
        if !ziffern.isEmpty, rest.starts(with: "$@"), let n = Int(String(ziffern)) {
            z = rest.dropFirst(2)
            if n >= 1, n <= werte.count { aus += werte[n - 1] }
            continue
        }
        aus.append("%")
    }
    return aus
}

/// Der Text in der Sprache des Macs.
func L(_ t: Txt) -> String {
    let muster = sprachBundle?.localizedString(forKey: t.schluessel, value: t.schluessel, table: nil) ?? t.schluessel
    return setzeWerteEin(muster, t.werte)
}
