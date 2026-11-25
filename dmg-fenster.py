#!/usr/bin/python3
"""Setzt in der .DS_Store eines DMG die Fensterangaben: Größe, keine Seitenleiste, keine Symbolleiste.
Wird von bauen.sh aufgerufen.

  python3 dmg-fenster.py <.DS_Store> <Breite> <Höhe> <sichtbares Objekt> [<sichtbares Objekt> …]

Der Finder schreibt den Eintrag „bwsp“ nur, wenn man am Fenster etwas ändert, und dann mit dem Zustand des
Fensters, in dem er den Ordner gezeigt hat. Öffnet er Ordner als Tab (Systemeinstellung „Tabs bevorzugen:
immer“), wäre das ein fremdes Fenster samt Seitenleiste. Deshalb richtet der Finder nur Symbole und
Hintergrund ein, und dieses Skript trägt das Fenster selbst ein.

Außerdem rückt es versteckte Objekte (Ordner mit dem Hintergrundbild) unter den Fensterrand: Wer im Finder
versteckte Dateien einblendet, sähe sie sonst mitten im Bild. Und es prüft, ob der Finder Hintergrund und
Symbolpositionen wirklich eingetragen hat, sonst bricht der Bau ab.

Die Datei ist ein „Bud1“-Speicher mit einem B-Baum. Hier wird nur der einfache Fall behandelt, den ein DMG
mit zwei Symbolen hat: ein einziges Blatt. Alles andere bricht mit einer Meldung ab.
"""
import plistlib
import struct
import sys

FEST = {b"long": 4, b"shor": 4, b"bool": 1, b"type": 4, b"comp": 8, b"dutc": 8}


def lies_eintraege(d, p, anzahl):
    aus = []
    for _ in range(anzahl):
        start = p
        n = struct.unpack(">I", d[p:p + 4])[0]
        name = d[p + 4:p + 4 + 2 * n].decode("utf-16-be")
        p += 4 + 2 * n
        kennung, art = bytes(d[p:p + 4]), bytes(d[p + 4:p + 8])
        p += 8
        if art in FEST:
            p += FEST[art]
        elif art == b"blob":
            p += 4 + struct.unpack(">I", d[p:p + 4])[0]
        elif art == b"ustr":
            p += 4 + 2 * struct.unpack(">I", d[p:p + 4])[0]
        else:
            sys.exit("unbekannte Art in der .DS_Store: %r" % art)
        aus.append((name, kennung, bytes(d[start:p])))
    return aus, p


def blatt(d):
    """Liefert (Ort des DSDB-Kopfs, Ort des Blatts, Größe des Blatts)."""
    if d[0:8] != b"\x00\x00\x00\x01Bud1":
        sys.exit("keine .DS_Store")
    wurzel = struct.unpack(">I", d[8:12])[0] + 4
    anzahl = struct.unpack(">I", d[wurzel:wurzel + 4])[0]
    adressen = struct.unpack(">%dI" % anzahl, d[wurzel + 8:wurzel + 8 + 4 * anzahl])
    p = wurzel + 8 + 4 * ((anzahl + 255) // 256 * 256)
    verzeichnisse = struct.unpack(">I", d[p:p + 4])[0]
    p += 4
    dsdb = None
    for _ in range(verzeichnisse):
        n = d[p]
        name = bytes(d[p + 1:p + 1 + n])
        nummer = struct.unpack(">I", d[p + 1 + n:p + 5 + n])[0]
        p += 5 + n
        if name == b"DSDB":
            dsdb = nummer

    def ort(nummer):
        a = adressen[nummer]
        return (a & ~0x1F) + 4, 1 << (a & 0x1F)

    kopf, _ = ort(dsdb)
    knoten, ebenen = struct.unpack(">II", d[kopf:kopf + 8])
    if ebenen != 0:
        sys.exit("die .DS_Store hat mehr als ein Blatt, damit kann dieses Skript nicht umgehen")
    wo, gross = ort(knoten)
    if struct.unpack(">I", d[wo:wo + 4])[0] != 0:
        sys.exit("der Wurzelknoten ist kein Blatt")
    return kopf, wo, gross


def schluessel(e):
    return (e[0].lower(), e[1])


def eintrag(name, kennung, daten):
    return (name, kennung, struct.pack(">I", len(name)) + name.encode("utf-16-be") + kennung + b"blob" + struct.pack(">I", len(daten)) + daten)


def blob(e):
    """Inhalt eines blob-Eintrags."""
    return e[2][4 + 2 * len(e[0]) + 12:]


pfad, breite, hoehe, sichtbar = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
d = bytearray(open(pfad, "rb").read())
kopf, wo, gross = blatt(d)
anzahl = struct.unpack(">I", d[wo + 4:wo + 8])[0]
eintraege, _ = lies_eintraege(d, wo + 8, anzahl)
fenster = plistlib.dumps({
    "ContainerShowSidebar": False, "ShowPathbar": False, "ShowSidebar": False, "ShowStatusBar": False,
    "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 0,
    "WindowBounds": "{{200, 300}, {%d, %d}}" % (breite, hoehe),
}, fmt=plistlib.FMT_BINARY)
# Gegenprobe: Hat der Finder Hintergrund und Positionen eingetragen?
ansicht = [e for e in eintraege if (e[0], e[1]) == (".", b"icvp")]
if not ansicht or "backgroundImageAlias" not in plistlib.loads(blob(ansicht[0])):
    sys.exit("der Finder hat kein Hintergrundbild eingetragen")
for name in sichtbar:
    if not any((e[0], e[1]) == (name, b"Iloc") for e in eintraege):
        sys.exit("der Finder hat keine Position für %s eingetragen" % name)
versteckt = sorted({e[0] for e in eintraege if e[0].startswith(".") and e[0] != "."} | {".hintergrund", ".fseventsd"})
eintraege = [e for e in eintraege if (e[0], e[1]) != (".", b"bwsp") and not (e[0] in versteckt and e[1] == b"Iloc")]
eintraege.append(eintrag(".", b"bwsp", fenster))
for i, name in enumerate(versteckt):       # unter dem Fensterrand, nebeneinander
    eintraege.append(eintrag(name, b"Iloc", struct.pack(">II", 100 + 140 * i, hoehe + 400) + b"\xff\xff\xff\xff\xff\xff\x00\x00"))
eintraege.sort(key=schluessel)
inhalt = struct.pack(">II", 0, len(eintraege)) + b"".join(e[2] for e in eintraege)
if len(inhalt) > gross:
    sys.exit("der Fenstereintrag passt nicht mehr in das Blatt (%d von %d Byte)" % (len(inhalt), gross))
d[wo:wo + gross] = inhalt + bytes(gross - len(inhalt))
d[kopf + 8:kopf + 12] = struct.pack(">I", len(eintraege))        # Zahl der Einträge im Baum
open(pfad, "wb").write(d)
# Gegenprobe: noch einmal lesen, wie der Finder es täte
d = bytearray(open(pfad, "rb").read())
kopf, wo, gross = blatt(d)
gelesen, _ = lies_eintraege(d, wo + 8, struct.unpack(">I", d[wo + 4:wo + 8])[0])
print("Einträge:", ", ".join("%s/%s" % (n, k.decode()) for n, k, _ in gelesen))
