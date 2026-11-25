#!/bin/zsh -f
# Prüft das Installieren über die Installationsdatei (Logic2Drive.dmg), ohne Netz und ohne Logic.
# Gebaut wird eine Testfassung mit eigener Kennung, „Programme“ ist ein Testordner. Rückfragen der App
# erscheinen nicht auf dem Bildschirm: LOGIC2DRIVE_HINWEIS beantwortet sie und schreibt sie ins Protokoll.
# Beim Bauen geht im Finder kurz ein Fenster oder Tab auf. Braucht eine „Developer ID Application“ nicht.
# Aufruf: zsh -f test/installation.sh <Arbeitsordner>
setopt null_glob; zmodload zsh/datetime
Q="${0:A:h:h}"; S="${1:?Aufruf: zsh -f test/installation.sh <Arbeitsordner>}"; mkdir -p -- "$S"; T="${S:A}/installation"
K=de.bibletunes.logic2drive.test
[[ ! -e /Volumes/Logic2Drive ]] || { print -r -- "STOPP: Ein Volume „Logic2Drive“ ist eingehängt, bitte erst auswerfen"; exit 1; }
rm -rf -- "$T"; mkdir -p -- "$T/laden" "$T/programme" "$T/daten"
ok=0; schlecht=0
pruefe() { if eval "$2"; then print -r -- "  ok: $1"; (( ok++ )); else print -r -- "  FEHLER: $1"; (( schlecht++ )); fi; }
warte() { local bis=$(( EPOCHSECONDS + $2 )); while (( EPOCHSECONDS < bis )); do eval "$1" && return 0; sleep 1; done; print -r -- "  Zeitüberschreitung bei: $1"; return 1; }
merke() { zeile=0; [[ -f $T/daten/protokoll.log ]] && zeile=$(wc -l < "$T/daten/protokoll.log" | tr -d ' '); }
seit() { tail -n +$(( zeile + 1 )) "$T/daten/protokoll.log" 2>/dev/null | grep -qE "$1"; }
anzahl() { tail -n +$(( zeile + 1 )) "$T/daten/protokoll.log" 2>/dev/null | grep -cE "$1"; }
DMG="$T/laden/Logic2Drive.dmg"; APP="$T/programme/Logic2Drive.app"
einhaengen() { hdiutil attach "$DMG" -noverify -noautoopen -nobrowse >/dev/null 2>&1; }
eingehaengt() { [[ -d /Volumes/Logic2Drive ]]; }
starte() { open -n -g "$1" --env LOGIC2DRIVE_DATEN="$T/daten" --env LOGIC2DRIVE_STILL=1 --env LOGIC2DRIVE_SPRACHE=de --env LOGIC2DRIVE_PROGRAMME="$T/programme" --env LOGIC2DRIVE_HINWEIS="$2"; }
laeuft() { pgrep -f "$1/Logic2Drive.app/Contents/MacOS/Logic2Drive" >/dev/null; }
beende() { pkill -f "installation/programme/Logic2Drive.app/Contents/MacOS/Logic2Drive"; pkill -f "^/Volumes/Logic2Drive/Logic2Drive.app/Contents/MacOS/Logic2Drive"; sleep 1; }
imPapierkorb() { local f; for f in "$HOME"/.Trash/Logic2Drive*.dmg(N); do [[ $(md5 -q "$f" 2>/dev/null) == $summe ]] && return 0; done; return 1; }
trap 'beende; eingehaengt && hdiutil detach /Volumes/Logic2Drive -quiet 2>/dev/null' EXIT

print -r -- "Baue die Testfassung samt Installationsdatei …"
LOGIC2DRIVE_KENNUNG=$K LOGIC2DRIVE_BUILD="$T/bau" zsh -f "$Q/bauen.sh" --dmg > "$T/bau.log" 2>&1 || { print -r -- "Bau fehlgeschlagen:"; tail -5 "$T/bau.log"; exit 1; }
summe=$(md5 -q "$T/bau/Logic2Drive.dmg")
print -r -- "{\"ordner\":[],\"arbeitsordner\":\"$T/arbeit\",\"sicherungsordner\":\"$T/sicherung\",\"ruheSekunden\":600,\"stabilSekunden\":20}" > "$T/daten/einstellungen.json"
# Die Testfassung soll weder die Einführung zeigen noch nach Updates suchen.
defaults write $K willkommenGezeigt -bool true; defaults write $K updateGeprueft -float $EPOCHSECONDS; defaults write $K updatesAutomatisch -bool false
defaults delete $K installationsdateiBehalten 2>/dev/null

print -r -- "I1 Die Installationsdatei selbst"
cp "$T/bau/Logic2Drive.dmg" "$DMG"; einhaengen
pruefe "enthält die App und den Verweis auf „Programme“" '[[ -d /Volumes/Logic2Drive/Logic2Drive.app && $(readlink /Volumes/Logic2Drive/Applications) == /Applications ]]'
pruefe "die App darin ist gültig signiert" 'codesign --verify --deep --strict /Volumes/Logic2Drive/Logic2Drive.app 2>/dev/null'
pruefe "Hintergrundbild liegt in beiden Auflösungen bei" '[[ $(tiffutil -info /Volumes/Logic2Drive/.hintergrund/hintergrund.tiff 2>/dev/null | grep -c "Image Width") == 2 ]]'
pruefe "Fensterangaben stehen in der Finder-Datei" 'grep -qa "{{200, 300}, {600, 428}}" /Volumes/Logic2Drive/.DS_Store && grep -qa backgroundImageAlias /Volumes/Logic2Drive/.DS_Store'

print -r -- "I2 App liegt in „Programme“: Die Installationsdatei kommt auf Wunsch in den Papierkorb"
ditto /Volumes/Logic2Drive/Logic2Drive.app "$APP"
pruefe "die App erkennt ihre Installationsdatei" '[[ $("$APP/Contents/MacOS/Logic2Drive" --installationsdatei | cut -f2) == /Volumes/Logic2Drive ]]'
merke; starte "$APP" ja; warte 'seit "Installationsdatei in den Papierkorb gelegt"' 40
pruefe "es wird genau einmal gefragt" '[[ $(anzahl "RÜCKFRAGE: Installationsdatei in den Papierkorb legen") == 1 ]]'
pruefe "das Installationsfenster ist geschlossen" '! eingehaengt'
pruefe "die Datei liegt nicht mehr im Ordner" '[[ ! -e $DMG ]]'
pruefe "sondern im Papierkorb" 'imPapierkorb'
pruefe "die App läuft weiter" 'laeuft "$T/programme"'
beende

print -r -- "I3 „Behalten“ wird für diese Datei gemerkt"
cp "$T/bau/Logic2Drive.dmg" "$DMG"; einhaengen
merke; starte "$APP" nein; warte 'seit "RÜCKFRAGE: Installationsdatei"' 40; sleep 2
pruefe "Datei und Fenster bleiben" 'eingehaengt && [[ -f $DMG ]]'
beende; merke; starte "$APP" ja; warte 'seit "gestartet"' 20; sleep 6
pruefe "beim nächsten Start wird nicht noch einmal gefragt" '! seit "RÜCKFRAGE"'
pruefe "und nichts weggeräumt" 'eingehaengt && [[ -f $DMG ]]'
beende; defaults delete $K installationsdateiBehalten 2>/dev/null

print -r -- "I4 App wird direkt im Installationsfenster geöffnet"
rm -rf -- "$APP"
merke; starte /Volumes/Logic2Drive/Logic2Drive.app ja; warte 'seit "Nach „Programme“ umgezogen"' 40
pruefe "die App fragt und legt sich in „Programme“" 'seit "RÜCKFRAGE: Logic2Drive in den Ordner „Programme“ legen" && [[ -x $APP/Contents/MacOS/Logic2Drive ]]'
pruefe "die Kopie ist gültig signiert" 'codesign --verify --deep --strict "$APP" 2>/dev/null'
warte 'seit "Installationsdatei in den Papierkorb gelegt"' 60
pruefe "sie startet von dort neu und räumt die Installationsdatei weg" '! eingehaengt && [[ ! -e $DMG ]] && laeuft "$T/programme"'
beende

print -r -- "=== Ergebnis: $ok bestanden, $schlecht fehlgeschlagen"
print -r -- "--- Protokoll"; cut -c12- "$T/daten/protokoll.log" | tail -20 | cut -c1-200
(( schlecht == 0 ))
