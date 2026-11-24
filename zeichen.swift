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
