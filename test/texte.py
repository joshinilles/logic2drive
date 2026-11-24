#!/usr/bin/python3
"""Prüft die Übersetzungen des Logic2Drives.

  python3 test/texte.py                 prüft sprachen/*.lproj/Localizable.strings gegen den Quelltext
  python3 test/texte.py --vorlage       gibt alle Schlüssel als Vorlage einer .strings-Datei aus
  python3 test/texte.py --ohne-L DATEI  gibt eine Swift-Datei ohne die L(…)-Hüllen aus (zum Vergleichen)

Ein Schlüssel ist der deutsche Text aus L("…"), jede Einfügung \\(…) ersetzt durch %@, jedes % durch %%.
"""
import glob
import os
import re
import sys

WURZEL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUELLEN = ["main.swift", "willkommen.swift", "update.swift", "zeichen.swift", "einstellungen.swift"]
SPRACHEN = ["en", "fr", "ar", "fa"]


def lies_literal(s, i):
    """s[i] ist das öffnende Anführungszeichen. Liefert (Schlüssel, Index hinter dem schließenden Zeichen)."""
    assert s[i] == '"'
    if s.startswith('"""', i):
        raise ValueError("mehrzeilige Texte (\"\"\") sind in L(…) nicht erlaubt")
    i += 1
    aus = []
    while True:
        c = s[i]
        if c == '"':
            return "".join(aus), i + 1
        if c == "\n":
            raise ValueError("Zeilenende mitten im Text")
        if c == "\\":
            n = s[i + 1]
            if n == "(":
                i = ueberspringe_klammer(s, i + 1)
                aus.append("%@")
                continue
            if n == "u":
                ende = s.index("}", i)
                aus.append(chr(int(s[i + 3:ende], 16)))
                i = ende + 1
                continue
            aus.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0", "r": "\r"}[n])
            i += 2
            continue
        aus.append("%%" if c == "%" else c)
        i += 1


def ueberspringe_klammer(s, i):
    """s[i] ist '('. Liefert den Index hinter der passenden ')'. Texte in der Klammer werden übersprungen."""
    assert s[i] == "("
    tiefe = 0
    while True:
        c = s[i]
        if c == '"':
            _, i = lies_literal(s, i)
            continue
        if c == "(":
            tiefe += 1
        elif c == ")":
            tiefe -= 1
            if tiefe == 0:
                return i + 1
        i += 1


def aufrufe(s):
    """Alle L("…")-Aufrufe: (Start von L, Start des Texts, Ende des Texts, Ende des Aufrufs, Schlüssel)."""
    for m in re.finditer(r'(?<![A-Za-z0-9_.])L\("', s):
        text_ab = m.end() - 1
        schluessel, text_bis = lies_literal(s, text_ab)
        if s[text_bis] != ")":
            raise ValueError("L(…) muss genau einen Text enthalten: " + s[m.start():text_bis + 20])
        yield m.start(), text_ab, text_bis, text_bis + 1, schluessel


def alle_schluessel():
    gefunden = {}
    for datei in QUELLEN:
        pfad = os.path.join(WURZEL, datei)
        if not os.path.exists(pfad):
            continue
        s = open(pfad, encoding="utf-8").read()
        for start, _, _, _, k in aufrufe(s):
            gefunden.setdefault(k, []).append("%s:%d" % (datei, s.count("\n", 0, start) + 1))
    return gefunden


def maske(t):
    return t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def lies_strings(pfad):
    s = open(pfad, encoding="utf-8").read()
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    paare = {}
    doppelt = []
    def entmaske(t):
        return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), t)
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', s, flags=re.S):
        k = entmaske(m.group(1))
        if k in paare:
            doppelt.append(k)
        paare[k] = entmaske(m.group(2))
    return paare, doppelt


def platzhalter(t):
    return len(re.findall(r"%(?:\d+\$)?@", t.replace("%%", "")))


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--ohne-L":
        s = open(sys.argv[2], encoding="utf-8").read()
        # Hüllen können ineinander stecken (ein L(…) in einer Einfügung). Deshalb in jedem Durchgang nur die
        # Aufrufe entfernen, die sich mit keinem früheren überschneiden, und wiederholen, bis keiner mehr da ist.
        while True:
            aus, pos = [], 0
            for start, text_ab, text_bis, ende, _ in aufrufe(s):
                if start < pos:
                    continue
                aus.append(s[pos:start])
                aus.append(s[text_ab:text_bis])
                pos = ende
            if pos == 0:
                break
            aus.append(s[pos:])
            s = "".join(aus)
        sys.stdout.write(s)
        return 0
    schluessel = alle_schluessel()
    if len(sys.argv) > 1 and sys.argv[1] == "--vorlage":
        for k, orte in schluessel.items():
            print("/* %s */" % ", ".join(orte[:3]))
            print('"%s" = "%s";\n' % (maske(k), maske(k)))
        return 0
    print("%d Texte im Quelltext" % len(schluessel))
    fehler = 0
    for sp in SPRACHEN:
        pfad = os.path.join(WURZEL, "sprachen", sp + ".lproj", "Localizable.strings")
        if not os.path.exists(pfad):
            print("%s: FEHLT (%s)" % (sp, pfad))
            fehler += 1
            continue
        paare, doppelt = lies_strings(pfad)
        fehlt = [k for k in schluessel if k not in paare]
        zuviel = [k for k in paare if k not in schluessel]
        falsch = [k for k in schluessel if k in paare and platzhalter(k) != platzhalter(paare[k])]
        gleich = [k for k in schluessel if k in paare and paare[k] == k and re.search(r"[a-zäöü]{4}", k)]
        print("%s: %d Einträge, %d fehlen, %d überzählig, %d mit falscher Zahl an Einfügungen, %d doppelt, %d unübersetzt"
              % (sp, len(paare), len(fehlt), len(zuviel), len(falsch), len(doppelt), len(gleich)))
        for name, liste in (("fehlt", fehlt), ("überzählig", zuviel), ("Einfügungen", falsch), ("doppelt", doppelt), ("unübersetzt", gleich)):
            for k in liste[:8]:
                print("   %s: %s" % (name, maske(k)[:110]))
        fehler += len(fehlt) + len(zuviel) + len(falsch) + len(doppelt)
    return 1 if fehler else 0


if __name__ == "__main__":
    sys.exit(main())
