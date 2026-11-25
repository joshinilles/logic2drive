// Logic2Drive – das eigene Zeichen: eine Schallplatte (in Anlehnung an Logic Pro) mit einer kleinen Wolke
// unten rechts. Es wird gezeichnet, nicht geladen, damit Menüleiste, Willkommensfenster und App-Symbol
// dieselbe Form zeigen.

import AppKit

/// Zeichnet Platte und Wolke in ein Quadrat der Kante `k` (Ursprung unten links).
func zeichneHelferZeichen(kante k: CGFloat, platte: NSColor, wolke: NSColor) {
    guard let ctx = NSGraphicsContext.current else { return }
    func kreis(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: (x - r) * k, y: (y - r) * k, width: 2 * r * k, height: 2 * r * k))
    }
    /// Die Wolke: ein flacher Sockel und zwei Bögen. `m` bläht sie auf, für die Aussparung in der Platte.
    func wolkenform(_ m: CGFloat) -> [NSBezierPath] {
        let sockel = NSRect(x: (0.50 - m) * k, y: (0.03 - m) * k, width: (0.48 + 2 * m) * k, height: (0.21 + 2 * m) * k)
        let r = sockel.height / 2
        return [NSBezierPath(roundedRect: sockel, xRadius: r, yRadius: r), kreis(0.655, 0.225, 0.115 + m), kreis(0.805, 0.255, 0.145 + m)]
    }
    let (cx, cy): (CGFloat, CGFloat) = (0.44, 0.56)

    platte.setFill()
    kreis(cx, cy, 0.43).fill()

    // Alles Folgende schneidet aus der Platte heraus: Etikett, Mittelloch, zwei Glanzbögen, Platz für die Wolke.
    ctx.compositingOperation = .destinationOut
    NSColor.black.set()
    let etikett = kreis(cx, cy, 0.165)
    etikett.lineWidth = 0.055 * k
    etikett.stroke()
    kreis(cx, cy, 0.048).fill()
    for start in [CGFloat(105), 285] {
        let glanz = NSBezierPath()
        glanz.appendArc(withCenter: NSPoint(x: cx * k, y: cy * k), radius: 0.30 * k, startAngle: start, endAngle: start + 50)
        glanz.lineWidth = 0.05 * k
        glanz.lineCapStyle = .round
        glanz.stroke()
    }
    wolkenform(0.06).forEach { $0.fill() }
    kreis(0.715, 0.30, 0.115).fill()        // füllt die Kerbe zwischen den beiden Bögen, sonst bleibt dort ein Zacken der Platte stehen

    ctx.compositingOperation = .sourceOver
    wolke.setFill()
    wolkenform(0).forEach { $0.fill() }
}

/// Das Zeichen für die Menüleiste. Als Vorlage färbt macOS es je nach Menüleiste hell oder dunkel.
func helferZeichen(_ kante: CGFloat = 18, farbe: NSColor = .black, vorlage: Bool = true) -> NSImage {
    let bild = NSImage(size: NSSize(width: kante, height: kante), flipped: false) { r in
        zeichneHelferZeichen(kante: r.width, platte: farbe, wolke: farbe)
        return true
    }
    bild.isTemplate = vorlage
    bild.accessibilityDescription = "Logic2Drive"
    return bild
}

func schreibePNG(_ pfad: String, pixel: Int, zeichne: (CGFloat) -> Void) -> Bool {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
    rep.size = NSSize(width: pixel, height: pixel)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    zeichne(CGFloat(pixel))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: pfad))) != nil
}

/// Das App-Symbol: weißes Zeichen auf bibletunes-Lila in der Form der macOS-Symbole.
func zeichneAppSymbol(kante k: CGFloat) {
    let flaeche = NSRect(x: 0.098 * k, y: 0.098 * k, width: 0.804 * k, height: 0.804 * k)
    NSColor(srgbRed: 0x60 / 255, green: 0x21 / 255, blue: 0x84 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: flaeche, xRadius: 0.18 * k, yRadius: 0.18 * k).fill()
    // Das Zeichen liegt als eigene Ebene darüber, damit seine Aussparungen das Lila zeigen und kein Loch.
    let innen = 0.56 * k
    let zeichen = helferZeichen(innen, farbe: .white, vorlage: false)
    zeichen.draw(in: NSRect(x: (k - innen) / 2 + 0.012 * k, y: (k - innen) / 2 - 0.012 * k, width: innen, height: innen))
}

/// Schreibt die Bilder für `iconutil` in einen Ordner `…​.iconset`.
func schreibeAppSymbol(_ ordner: String) -> Bool {
    try? FileManager.default.createDirectory(atPath: ordner, withIntermediateDirectories: true)
    var gut = true
    for (punkte, faktor) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let name = "icon_\(punkte)x\(punkte)\(faktor == 2 ? "@2x" : "").png"
        gut = schreibePNG("\(ordner)/\(name)", pixel: punkte * faktor) { zeichneAppSymbol(kante: $0) } && gut
    }
    return gut
}

// MARK: - Installationsfenster im DMG

/// Maße des Installationsfensters in Punkten. bauen.sh und dmg-fenster.py verwenden dieselben Zahlen.
let dmgBreite: CGFloat = 600, dmgHoehe: CGFloat = 400
let dmgLinks: CGFloat = 165, dmgRechts: CGFloat = 435, dmgMitte: CGFloat = 205     // Mitte der Symbole, von oben gemessen

/// Hintergrund des Installationsfensters: links liegt die App, rechts der Ordner „Programme“, dazwischen ein Pfeil.
/// Der Text steht deutsch und englisch im Bild, weil ein Bild sich nicht nach der Sprache des Macs richtet.
func zeichneDmgHintergrund() {
    let (b, h) = (dmgBreite, dmgHoehe)
    let lila = NSColor(srgbRed: 0x60 / 255, green: 0x21 / 255, blue: 0x84 / 255, alpha: 1)
    NSGradient(starting: NSColor(srgbRed: 0.985, green: 0.98, blue: 0.99, alpha: 1), ending: NSColor(srgbRed: 0.93, green: 0.915, blue: 0.95, alpha: 1))?
        .draw(in: NSRect(x: 0, y: 0, width: b, height: h), angle: -90)
    func text(_ t: String, vonOben y: CGFloat, groesse: CGFloat, fett: Bool, grau: CGFloat) {
        let stil = NSMutableParagraphStyle()
        stil.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: groesse, weight: fett ? .semibold : .regular),
                                                .foregroundColor: NSColor(white: grau, alpha: 1), .paragraphStyle: stil]
        (t as NSString).draw(in: NSRect(x: 20, y: h - y - groesse * 1.4, width: b - 40, height: groesse * 1.5), withAttributes: a)
    }
    text("Zieh Logic2Drive in den Ordner „Programme“", vonOben: 34, groesse: 19, fett: true, grau: 0.1)
    text("Drag Logic2Drive to the Applications folder", vonOben: 64, groesse: 13, fett: false, grau: 0.38)
    let y = h - dmgMitte, anfang = dmgLinks + 82, ende = dmgRechts - 82
    let pfeil = NSBezierPath()
    pfeil.move(to: NSPoint(x: anfang, y: y))
    pfeil.line(to: NSPoint(x: ende - 6, y: y))
    pfeil.move(to: NSPoint(x: ende - 22, y: y + 17))
    pfeil.line(to: NSPoint(x: ende, y: y))
    pfeil.line(to: NSPoint(x: ende - 22, y: y - 17))
    pfeil.lineWidth = 7
    pfeil.lineCapStyle = .round
    pfeil.lineJoinStyle = .round
    lila.setStroke()
    pfeil.stroke()
    text("Danach Logic2Drive aus „Programme“ öffnen  ·  Then open Logic2Drive from Applications", vonOben: h - 40, groesse: 11, fett: false, grau: 0.42)
}

/// Schreibt den Hintergrund in einfacher und doppelter Auflösung; `tiffutil` macht daraus eine Datei für beide.
func schreibeDmgHintergrund(_ ordner: String) -> Bool {
    try? FileManager.default.createDirectory(atPath: ordner, withIntermediateDirectories: true)
    var gut = true
    for faktor in [1, 2] {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(dmgBreite) * faktor, pixelsHigh: Int(dmgHoehe) * faktor,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: CGFloat(faktor), y: CGFloat(faktor))     // gezeichnet wird in Punkten, für beide Auflösungen gleich
        zeichneDmgHintergrund()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: dmgBreite, height: dmgHoehe)       // 144 dpi in der doppelten Fassung, daran erkennt macOS sie
        let png = rep.representation(using: .png, properties: [:])
        gut = (try? png?.write(to: URL(fileURLWithPath: "\(ordner)/dmg-\(faktor)x.png"))) != nil && png != nil && gut
    }
    return gut
}
