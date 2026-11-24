// Logic2Drive – Updates über die Veröffentlichungen auf GitHub.
//
// Sicherheit: Eingespielt wird nur ein Paket, dessen Signatur gültig ist UND von derselben Developer ID (Team)
// stammt wie die laufende App. Wer nur das GitHub-Konto übernimmt, kann damit kein Update unterschieben.
// Eine ad hoc signierte App (eigener Bau ohne Zertifikat) hat kein Team und spielt deshalb nie von selbst ein,
// sie weist nur auf die neue Version hin.

import AppKit
import Security

struct UpdateAngebot {
    let version: String     // ohne „v“
    let zip: URL
    let seite: URL?
}

func versionsZahlen(_ v: String) -> [Int] {
    v.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n")).split(separator: ".").map { Int($0) ?? 0 }
}

func istNeuer(_ a: String, als b: String) -> Bool {
    let x = versionsZahlen(a), y = versionsZahlen(b)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

enum Update {
    static let paketName = "Logic2Drive.zip"
    static let quelle = "https://api.github.com/repos/joshinilles/logic2drive/releases/latest"
    /// Nur für Tests: eine andere Quelle, dann auch als Datei (file://).
    static var testQuelle: String? { ProcessInfo.processInfo.environment["LOGIC2DRIVE_UPDATE_QUELLE"] }
    static var ordner: String { datenOrdner + "/update" }

    /// Das Team der Developer ID, mit der die laufende App signiert ist. `nil` bei einer ad hoc signierten App.
    static func eigenesTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var statisch: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &statisch) == errSecSuccess, let statisch else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(statisch, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let team = d[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
        return team
    }

    static func hole(_ url: URL, frist: TimeInterval) -> Data? {
        var anfrage = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: frist)
        anfrage.setValue("Logic2Drive/\(helferVersion)", forHTTPHeaderField: "User-Agent")
        anfrage.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let fertig = DispatchSemaphore(value: 0)
        var daten: Data?
        URLSession(configuration: .ephemeral).dataTask(with: anfrage) { d, antwort, _ in
            if let h = antwort as? HTTPURLResponse, h.statusCode != 200 { daten = nil } else { daten = d }
            fertig.signal()
        }.resume()
        _ = fertig.wait(timeout: .now() + frist + 5)
        return daten
    }

    /// Fragt die Quelle nach der neuesten Veröffentlichung. `nil` heißt: nichts Neueres da.
    static func suche() throws -> UpdateAngebot? {
        guard let url = URL(string: testQuelle ?? quelle), let daten = hole(url, frist: 20) else {
            throw HelferFehler(L("Die Update-Quelle antwortet nicht"))
        }
        guard let o = try? JSONSerialization.jsonObject(with: daten) as? [String: Any], let marke = o["tag_name"] as? String else {
            throw HelferFehler(L("Die Antwort der Update-Quelle ist nicht lesbar"))
        }
        let version = versionsZahlen(marke).map(String.init).joined(separator: ".")
        guard istNeuer(version, als: helferVersion) else { return nil }
        let pakete = (o["assets"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == paketName }
        guard let adresse = pakete.first?["browser_download_url"] as? String, let zip = URL(string: adresse) else {
            throw HelferFehler(L("Version \(version) ist veröffentlicht, aber ohne \(paketName)"))
        }
        // Außerhalb von Tests nur verschlüsselt und nur von GitHub aus diesem Projekt.
        if testQuelle == nil, !adresse.hasPrefix("https://github.com/joshinilles/logic2drive/releases/download/") {
            throw HelferFehler(L("Das Paket von Version \(version) liegt an einer unerwarteten Adresse"))
        }
        return UpdateAngebot(version: version, zip: zip, seite: (o["html_url"] as? String).flatMap { URL(string: $0) })
    }

    /// Prüft eine App: richtige Kennung, erwartete Version, gültige Signatur vom erwarteten Team.
    static func pruefe(app: String, version: String, team: String) throws {
        guard let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") else { throw HelferFehler(L("Das Paket enthält keine App")) }
        let kennung = Bundle.main.bundleIdentifier ?? "de.bibletunes.logic2drive"
        guard plist["CFBundleIdentifier"] as? String == kennung else { throw HelferFehler(L("Das Paket enthält eine andere App")) }
        guard let v = plist["CFBundleShortVersionString"] as? String, versionsZahlen(v) == versionsZahlen(version) else {
            throw HelferFehler(L("Die App im Paket trägt nicht die angekündigte Version \(version)"))
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, [], &code) == errSecSuccess, let code else {
            throw HelferFehler(L("Die Signatur des Pakets ist nicht lesbar"))
        }
        // Developer ID von Apple ausgestellt, für genau dieses Team und genau diese App.
        let regel = "identifier \"\(kennung)\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        var anforderung: SecRequirement?
        guard SecRequirementCreateWithString(regel as CFString, [], &anforderung) == errSecSuccess, let anforderung else {
            throw HelferFehler(L("Die Signaturregel ließ sich nicht bilden"))
        }
        let wie = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var grund: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, wie, anforderung, &grund) == errSecSuccess else {
            let text = grund.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? L("unbekannt")
            throw HelferFehler(L("Die Signatur des Pakets stimmt nicht (\(text))"))
        }
    }

    /// Lädt das Paket, entpackt es und prüft es. Liefert den Pfad der geprüften App.
    static func ladeUndPruefe(_ a: UpdateAngebot, team: String) throws -> String {
        try? fm.removeItem(atPath: ordner + "/neu")
        try fm.createDirectory(atPath: ordner + "/neu", withIntermediateDirectories: true)
        guard let daten = hole(a.zip, frist: 300), daten.count > 1000 else { throw HelferFehler(L("Das Paket ließ sich nicht laden")) }
        let zip = ordner + "/neu/" + paketName
        try daten.write(to: URL(fileURLWithPath: zip))
        let r = lauf("/usr/bin/ditto", ["-x", "-k", zip, ordner + "/neu"], frist: 120)
        guard r.code == 0 else { throw HelferFehler(L("Das Paket ließ sich nicht entpacken")) }
        try? fm.removeItem(atPath: zip)
        let app = ordner + "/neu/Logic2Drive.app"
        guard let s = info(app), istOrdner(s) else { throw HelferFehler(L("Das Paket enthält keine Logic2Drive.app")) }
        try pruefe(app: app, version: a.version, team: team)
        return app
    }

    /// Setzt die geprüfte App an die Stelle der laufenden. Die bisherige bleibt als `update/vorher.app` liegen.
    static func setzeEin(_ neu: String, version: String, team: String) throws {
        let ziel = Bundle.main.bundleURL
        guard ziel.pathExtension == "app", !ziel.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: ziel.deletingLastPathComponent().path) else {
            throw HelferFehler(L("Die App liegt an einem Ort, an dem sie sich nicht selbst ersetzen kann"))
        }
        let vorher = ordner + "/vorher.app"
        try? fm.removeItem(atPath: vorher)
        try fm.copyItem(atPath: ziel.path, toPath: vorher)
        // Über einen Zwischenordner auf demselben Laufwerk, damit der Tausch in einem Schritt geschieht.
        let zwischen = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: ziel, create: true)
        defer { try? fm.removeItem(at: zwischen) }
        let dort = zwischen.appendingPathComponent("Logic2Drive.app")
        try fm.moveItem(atPath: neu, toPath: dort.path)
        _ = try fm.replaceItemAt(ziel, withItemAt: dort)
        do {
            try pruefe(app: ziel.path, version: version, team: team)      // noch einmal am endgültigen Ort
        } catch {
            try? fm.removeItem(at: ziel)
            try? fm.copyItem(atPath: vorher, toPath: ziel.path)
            throw HelferFehler(L("Nach dem Einsetzen stimmte die Signatur nicht mehr, die bisherige Version ist zurück (\(error))"))
        }
    }

    /// Ein Durchgang ohne Oberfläche: suchen, laden, prüfen, einsetzen. Für `--update-einspielen` und die Tests.
    static func durchgang(einsetzen: Bool) -> (code: Int32, text: String) {
        do {
            guard let a = try suche() else { return (0, L("aktuell: \(helferVersion)")) }
            guard einsetzen else { return (0, L("neu: \(a.version)")) }
            guard let team = eigenesTeam() else { return (3, L("neu: \(a.version), aber diese App ist nicht mit einer Developer ID signiert")) }
            let app = try ladeUndPruefe(a, team: team)
            try setzeEin(app, version: a.version, team: team)
            return (0, L("eingespielt: \(a.version)"))
        } catch {
            return (1, L("abgelehnt: \(error)"))
        }
    }
}
