#!/bin/zsh -f
# Prüft den Updater ohne Netz und ohne Logic. Die „Veröffentlichung“ ist eine Datei, die App liegt in einem
# Testordner und ersetzt sich dort selbst. Braucht eine „Developer ID Application“ im Schlüsselbund.
# Aufruf: zsh -f test/update.sh <Arbeitsordner>
setopt null_glob
Q="${0:A:h:h}"; S="${1:?Aufruf: zsh -f test/update.sh <Arbeitsordner>}"; T="$S/update"
security find-identity -v -p codesigning | grep -q '"Developer ID Application: ' || { print -r -- "übersprungen: keine Developer ID im Schlüsselbund"; exit 0 }
rm -rf -- "$T"; mkdir -p -- "$T/pakete"
ok=0; schlecht=0
pruefe() { if eval "$2"; then print -r -- "  ok: $1"; (( ok++ )); else print -r -- "  FEHLER: $1"; (( schlecht++ )); fi; }
bau() { LOGIC2DRIVE_VERSION=$1 LOGIC2DRIVE_BUILD="$T/bau-$2" LOGIC2DRIVE_SIGNATUR="${3:-}" zsh -f "$Q/bauen.sh" > "$T/bau-$2.log" 2>&1 || { print -r -- "Bau $2 fehlgeschlagen"; tail -5 "$T/bau-$2.log"; exit 1 } }
packe() { ditto -c -k --sequesterRsrc --keepParent "$1/Logic2Drive.app" "$T/pakete/$2.zip"; }
quelle() { print -r -- "{\"tag_name\":\"$1\",\"html_url\":\"https://example.invalid/\",\"assets\":[{\"name\":\"Logic2Drive.zip\",\"browser_download_url\":\"file://$T/pakete/$2.zip\"}]}" > "$T/quelle.json"; }
frisch() { rm -rf -- "$T/ort" "$T/daten"; mkdir -p -- "$T/ort" "$T/daten"; ditto "$T/bau-${1:-alt}/Logic2Drive.app" "$T/ort/Logic2Drive.app"; }
helfer() { LOGIC2DRIVE_DATEN="$T/daten" LOGIC2DRIVE_STILL=1 LOGIC2DRIVE_SPRACHE=de LOGIC2DRIVE_UPDATE_QUELLE="file://$T/quelle.json" "$T/ort/Logic2Drive.app/Contents/MacOS/Logic2Drive" "$@"; }

print -r -- "Baue drei Fassungen (1.0 und 9.9 mit Developer ID, 9.9 ohne) …"
bau 1.0 alt; bau 9.9 neu; bau 9.9 adhoc -
packe "$T/bau-neu" gut; packe "$T/bau-alt" alt; packe "$T/bau-adhoc" adhoc
ditto "$T/bau-neu/Logic2Drive.app" "$T/veraendert/Logic2Drive.app"
print -r -- "fremd" >> "$T/veraendert/Logic2Drive.app/Contents/MacOS/Logic2Drive"; packe "$T/veraendert" veraendert

print -r -- "U1 Gültiges Update wird eingespielt"
frisch; quelle v9.9 gut
pruefe "die Suche findet 9.9" '[[ $(helfer --update-suchen) == "neu: 9.9" ]]'
pruefe "die Suche allein ändert nichts" '[[ $(helfer --version) == 1.0 ]]'
aus=$(helfer --update-einspielen)
pruefe "Einspielen meldet Erfolg" '[[ $aus == "eingespielt: 9.9" ]]'
pruefe "die App ist jetzt 9.9" '[[ $(helfer --version) == 9.9 ]]'
pruefe "ihre Signatur ist gültig" 'codesign --verify --deep --strict "$T/ort/Logic2Drive.app" 2>/dev/null'
pruefe "die bisherige Version liegt daneben" '[[ $(defaults read "$T/daten/update/vorher.app/Contents/Info" CFBundleShortVersionString) == 1.0 ]]'

print -r -- "U2 Gleiche Version: nichts zu tun"
frisch; quelle v1.0 alt
pruefe "meldet aktuell" '[[ $(helfer --update-einspielen) == "aktuell: 1.0" ]]'
pruefe "App unverändert" '[[ $(helfer --version) == 1.0 ]]'

print -r -- "U3 Paket nach dem Signieren verändert"
frisch; quelle v9.9 veraendert; aus=$(helfer --update-einspielen)
pruefe "wird abgelehnt" '[[ $aus == abgelehnt:*Signatur* ]]'
pruefe "App bleibt 1.0" '[[ $(helfer --version) == 1.0 ]]'

print -r -- "U4 Paket ohne Developer ID"
frisch; quelle v9.9 adhoc; aus=$(helfer --update-einspielen)
pruefe "wird abgelehnt" '[[ $aus == abgelehnt:*Signatur* ]]'
pruefe "App bleibt 1.0" '[[ $(helfer --version) == 1.0 ]]'

print -r -- "U5 Angekündigt 9.9, im Paket steckt 1.0"
frisch; quelle v9.9 alt; aus=$(helfer --update-einspielen)
pruefe "wird abgelehnt" '[[ $aus == abgelehnt:*angekündigte\ Version* ]]'
pruefe "App bleibt 1.0" '[[ $(helfer --version) == 1.0 ]]'

print -r -- "U6 Eine App ohne Developer ID spielt nie von selbst ein"
frisch adhoc; quelle v10.0 gut; aus=$(helfer --update-einspielen); code=$?
pruefe "weist nur auf die neue Version hin" '[[ $code == 3 && $aus == "neu: 10.0,"* ]]'
pruefe "App bleibt 9.9" '[[ $(helfer --version) == 9.9 ]]'

print -r -- "U7 Quelle nicht erreichbar"
frisch; rm -f -- "$T/quelle.json"; aus=$(helfer --update-einspielen)
pruefe "meldet es, ohne etwas zu ändern" '[[ $aus == abgelehnt:* && $(helfer --version) == 1.0 ]]'

print -r -- "=== Ergebnis: $ok bestanden, $schlecht fehlgeschlagen"
(( schlecht == 0 ))
