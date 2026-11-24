#!/bin/zsh -f
setopt null_glob; zmodload zsh/datetime
S="$1"; T="$S/e5"; DATEN="$T/daten"
B="${0:A:h:h}/build/Logic2Drive.app/Contents/MacOS/Logic2Drive"
# Der Testordner liegt in „Meine Ablage“ (englisch „My Drive“) des ersten Google-Drive-Kontos dieses Macs.
# LOGIC2DRIVE_TESTORDNER legt einen anderen fest.
ABLAGE=("$HOME"/Library/CloudStorage/GoogleDrive-*/(Meine\ Ablage|My\ Drive)(N))
D="${LOGIC2DRIVE_TESTORDNER:-${ABLAGE[1]:+$ABLAGE[1]/Logic2Drive-Test}}"
[[ -n $D ]] || { print -r -- "STOPP: kein Google Drive gefunden, Test nicht gestartet"; exit 1; }
mkdir -p -- "$D"
export LOGIC2DRIVE_SPRACHE=de      # die Prüfungen vergleichen deutsche Ausgaben
V="$HOME/Music/Logic Pro Library.bundle/Projects/Templates/05 Multi-Track Stereo Production.logicx"
pgrep -x "Logic Pro" >/dev/null && { print -r -- "STOPP: Logic läuft, Test nicht gestartet"; exit 1; }
A="$HOME/.Trash/Logic2Drive-Test-$EPOCHSECONDS"; mkdir -p "$A"; for f in "$D"/Helfer-Test-*(D); do mv "$f" "$A/"; done
rm -rf -- "$DATEN" "$T/arbeit" "$T/sicherung" "$T/x"; mkdir -p "$DATEN" "$T/arbeit" "$T/sicherung" "$T/x"
ORDNER="\"$D\""
konfig() { cat > "$DATEN/einstellungen.json" <<JSON
{"ordner":[$ORDNER],"arbeitsordner":"$T/arbeit","sicherungsordner":"$T/sicherung","ruheSekunden":6,"stabilSekunden":6,"hintergrund":true,"wachKarenzSekunden":$1,"scanAbstandSekunden":0}
JSON
}
konfig 0
export LOGIC2DRIVE_DATEN="$DATEN" LOGIC2DRIVE_STILL=1
"$B" --lauf > "$T/helfer.out" 2>&1 &
HP=$!
trap 'kill $HP 2>/dev/null' EXIT
ok=0; schlecht=0
pruefe() { if eval "$2"; then print -r -- "  ok: $1"; (( ok++ )); else print -r -- "  FEHLER: $1"; (( schlecht++ )); fi; }
warte() { local bis=$(( EPOCHSECONDS + $2 )); while (( EPOCHSECONDS < bis )); do eval "$1" && return 0; sleep 1; done; print -r -- "  Zeitüberschreitung bei: $1"; return 1; }
leer() { ! grep -q '"id"' "$DATEN/auftraege.json" 2>/dev/null; }
gesehen() { grep -q '"gesehenInLogic" : true' "$DATEN/auftraege.json" 2>/dev/null; }
schliesse() { /usr/bin/timeout 25 osascript -e 'with timeout of 20 seconds' -e "tell application \"Logic Pro\" to close (first document whose name contains \"$1\") saving no" -e 'end timeout' >/dev/null 2>&1; }
drin() { unzip -Z1 "$1" 2>/dev/null | grep -qF "$2"; }
Z="$D/Helfer-Test-C.logicx.zip"; M="$D/Helfer-Test-C.logicx.inarbeit"

print -r -- "T1 Ablegen"
ditto "$V" "$T/x/Helfer-Test-C.logicx"; mv "$T/x/Helfer-Test-C.logicx" "$D/"
warte '[[ -f $Z && ! -e $D/Helfer-Test-C.logicx && ! -e "$D/Helfer-Test-C 2.logicx" ]] && leer' 180
pruefe "Zip liegt im Drive-Ordner" '[[ -f $Z ]]'
pruefe "kein Paket und keine leere Datei mehr" '[[ ! -e $D/Helfer-Test-C.logicx && ! -e "$D/Helfer-Test-C 2.logicx" ]]'
pruefe "oberster Ordner heißt richtig" '[[ $(unzip -Z1 "$Z" | head -1) == Helfer-Test-C.logicx/ ]]'
pruefe "Paket liegt in der Sicherung" '[[ -n $(print -l "$T"/sicherung/*/Helfer-Test-C.logicx) ]]'

print -r -- "T2 Öffnen, ändern, zurücklegen"
m1=$(md5 -q "$Z"); "$B" --oeffne "$Z"
warte 'gesehen' 240
pruefe "Logic hat das Projekt geöffnet" 'gesehen'
pruefe "Sperre liegt im Drive-Ordner" '[[ -f $M ]]'
pruefe "Arbeitskopie liegt lokal" '[[ -d $T/arbeit/Helfer-Test-C.logicx ]]'
print -r -- "Änderung T2" > "$T/arbeit/Helfer-Test-C.logicx/Resources/test-aenderung-2.txt"
sleep 3; pruefe "solange offen wird nichts hochgeladen" '[[ $(md5 -q "$Z") == $m1 ]]'
schliesse Helfer-Test-C; warte 'leer' 120
m2=$(md5 -q "$Z")
pruefe "Zip wurde ersetzt" '[[ $m2 != $m1 ]]'
pruefe "Änderung steckt in der Zip" 'drin "$Z" test-aenderung-2.txt'
pruefe "Sperre ist weg" '[[ ! -e $M ]]'
pruefe "Arbeitskopie ist weg" '[[ ! -e $T/arbeit/Helfer-Test-C.logicx ]]'
ER=("$T"/sicherung/*/Helfer-Test-C\ –\ ersetzt*.logicx.zip)
pruefe "bisherige Zip liegt unverändert in der Sicherung (0.4.2)" '(( ${#ER} == 1 )) && [[ $(md5 -q "$ER[1]") == $m1 ]]'

print -r -- "T3 Öffnen ohne Änderung"
"$B" --oeffne "$Z"; warte 'gesehen' 120
schliesse Helfer-Test-C; warte 'leer' 60
pruefe "Zip blieb unverändert" '[[ $(md5 -q "$Z") == $m2 ]]'
pruefe "Sperre ist weg" '[[ ! -e $M ]]'

print -r -- "T4 Konflikt"
"$B" --oeffne "$Z"; warte 'gesehen' 120
print -r -- "Änderung T4" > "$T/arbeit/Helfer-Test-C.logicx/Resources/test-aenderung-4.txt"
mkdir -p "$T/x/fremd"; ditto -x -k "$Z" "$T/x/fremd"; print -r -- "Fremde Fassung" > "$T/x/fremd/Helfer-Test-C.logicx/Resources/fremd.txt"
ditto -c -k --sequesterRsrc --keepParent "$T/x/fremd/Helfer-Test-C.logicx" "$T/x/fremd.zip"; mf=$(md5 -q "$T/x/fremd.zip")
"$S/e3/ersetze" "$Z" "$T/x/fremd.zip" >/dev/null
schliesse Helfer-Test-C; warte 'leer' 120
K=("$D"/Helfer-Test-C\ –\ Stand*.logicx.zip)
pruefe "fremde Fassung wurde nicht überschrieben" '[[ $(md5 -q "$Z") == $mf ]]'
pruefe "eigene Fassung liegt daneben" '(( ${#K} == 1 ))'
pruefe "eigene Änderung steckt darin" '(( ${#K} == 1 )) && drin "$K[1]" test-aenderung-4.txt'
pruefe "Sperre ist weg" '[[ ! -e $M ]]'
ER=("$T"/sicherung/*/Helfer-Test-C\ –\ ersetzt*.logicx.zip)
pruefe "ohne Ersetzen keine weitere Sicherung der Zip (0.4.2)" '(( ${#ER} == 1 ))'

print -r -- "T5 Fremde Sperre"
print -r -- '{"wer":"Testperson","rechner":"Anderer Mac","konto":"test","seit":"23.11. 12:00"}' > "$M"
"$B" --oeffne "$Z"; sleep 6
pruefe "Projekt wurde nicht geöffnet" 'leer && [[ ! -e $T/arbeit/Helfer-Test-C.logicx ]]'
pruefe "Protokoll nennt den Grund" 'grep -q "Nicht geöffnet, in Arbeit bei Testperson" "$DATEN/protokoll.log"'
pruefe "fremde Sperre bleibt liegen" '[[ -f $M ]]'
rm -f -- "$M"

print -r -- "T6 Neues Paket, während es in Logic offen ist"
E="$D/Helfer-Test-E.logicx"; ditto "$V" "$T/x/Helfer-Test-E.logicx"; mv "$T/x/Helfer-Test-E.logicx" "$D/"; open -g -b com.apple.logic10 "$E"
warte '/usr/bin/timeout 12 osascript -e "tell application \"Logic Pro\" to get name of documents" 2>/dev/null | grep -q Helfer-Test-E' 60
sleep 25
pruefe "solange offen entsteht keine Zip" '[[ ! -e $D/Helfer-Test-E.logicx.zip ]]'
schliesse Helfer-Test-E
warte '[[ -f $D/Helfer-Test-E.logicx.zip && ! -e $E && ! -e "$D/Helfer-Test-E 2.logicx" ]] && leer' 150
pruefe "nach dem Schließen liegt die Zip da" '[[ -f $D/Helfer-Test-E.logicx.zip ]]'
pruefe "kein Paket und keine leere Datei mehr" '[[ ! -e $E && ! -e "$D/Helfer-Test-E 2.logicx" ]]'
pruefe "genau eine Zip für das Projekt" '[[ ! -e "$D/Helfer-Test-E 2.logicx.zip" && $(print -l "$D"/Helfer-Test-E*.zip | wc -l | tr -d " ") == 1 ]]'
pruefe "oberster Ordner heißt richtig" '[[ $(unzip -Z1 "$D/Helfer-Test-E.logicx.zip" | head -1) == Helfer-Test-E.logicx/ ]]'
mkdir -p "$T/x/evgl"; ditto -x -k "$D/Helfer-Test-E.logicx.zip" "$T/x/evgl"; EP=("$T"/sicherung/*/Helfer-Test-E.logicx)
pruefe "Zip enthält den letzten Stand aus der Sicherung" '(( ${#EP} == 1 )) && diff -rq -x .DS_Store "$EP[1]" "$T/x/evgl/Helfer-Test-E.logicx" >/dev/null'

print -r -- "T7 Normale Zip"
mkdir -p "$T/x/n/inhalt"; print -r -- hallo > "$T/x/n/inhalt/a.txt"; ditto -c -k --keepParent "$T/x/n/inhalt" "$T/x/n/normal.zip"; rm -rf -- "$T/x/n/inhalt"
"$B" --oeffne "$T/x/n/normal.zip"; warte '[[ -f $T/x/n/inhalt/a.txt ]]' 25
pruefe "Archivprogramm hat entpackt" '[[ -f $T/x/n/inhalt/a.txt ]]'
pruefe "kein Auftrag angelegt" 'leer'

source "${0:A:h}/befunde.sh"

d=""; pgrep -x "Logic Pro" >/dev/null && d=$(/usr/bin/timeout 15 osascript -e 'tell application "Logic Pro" to get name of documents' 2>/dev/null)
if [[ -z $d ]]; then pgrep -x "Logic Pro" >/dev/null && /usr/bin/timeout 25 osascript -e 'with timeout of 20 seconds' -e 'tell application "Logic Pro" to quit saving no' -e 'end timeout' >/dev/null 2>&1; print -r -- "Logic wieder beendet"; else print -r -- "Logic bleibt offen: $d"; fi
print -r -- "--- Drive-Testordner"; ls -1A "$D" | grep -v DS_Store
print -r -- "=== Ergebnis: $ok bestanden, $schlecht fehlgeschlagen"
print -r -- "--- Protokoll"; cut -c12- "$DATEN/protokoll.log" | tail -45
