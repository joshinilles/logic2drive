#!/bin/zsh -f
# Gesamttest im Drive-Ordner „Meine Ablage/Logic2Drive-Test“. Öffnet und schließt Logic, nur mit Testprojekten.
S="${1:-$(mktemp -d)}"
mkdir -p "$S/e3" "$S/e5"
swiftc -O -o "$S/e3/ersetze" "${0:A:h}/ersetze.swift" || exit 1
zsh -f "${0:A:h}/gesamt.sh" "$S"
