#!/bin/zsh -f
# Tests zur Namensregel (0.6.8): Jede Zip, die der Helfer in Drive ablegt, trägt einen Namen, der auch über
# Cloud Sync auf der Synology ankommt. Wird von befunde.sh eingebunden und läuft dann im Drive-Testordner.
#
#   zsh -f test/namen.sh [Arbeitsordner]
#
# Allein aufgerufen läuft es lokal, ohne Google Drive und ohne Logic. Dort bestätigt niemand den Upload: Die
# Prüfungen sehen dann nur auf Name, Inhalt und Nachbarn der Zip und lassen aus, was Logic oder Drive braucht.
if ! typeset -f pruefe >/dev/null; then
  setopt null_glob; zmodload zsh/datetime
  LOKAL=1; S="${1:-$(mktemp -d)}"; T="$S/namen"; DATEN="$T/daten"; D="$T/drive"
  B="${LOGIC2DRIVE_APP:-${0:A:h:h}/build/Logic2Drive.app}/Contents/MacOS/Logic2Drive"
  V="$HOME/Music/Logic Pro Library.bundle/Projects/Templates/05 Multi-Track Stereo Production.logicx"
  [[ -x $B && -d $V ]] || { print -r -- "STOPP: App oder Vorlage fehlt ($B)"; exit 1; }
  rm -rf -- "$T"; mkdir -p "$DATEN" "$D" "$T/arbeit" "$T/sicherung" "$T/x"
  export LOGIC2DRIVE_SPRACHE=de LOGIC2DRIVE_DATEN="$DATEN" LOGIC2DRIVE_STILL=1
  print -r -- "{\"ordner\":[\"$D\"],\"arbeitsordner\":\"$T/arbeit\",\"sicherungsordner\":\"$T/sicherung\",\"ruheSekunden\":6,\"stabilSekunden\":6,\"hintergrund\":true,\"wachKarenzSekunden\":0,\"scanAbstandSekunden\":0}" > "$DATEN/einstellungen.json"
  "$B" --lauf > "$T/helfer.out" 2>&1 &
  HP=$!
  trap 'kill $HP 2>/dev/null' EXIT
  ok=0; schlecht=0
  pruefe() { if eval "$2"; then print -r -- "  ok: $1"; (( ok++ )); else print -r -- "  FEHLER: $1"; (( schlecht++ )); fi; }
  warte() { local bis=$(( EPOCHSECONDS + $2 )); while (( EPOCHSECONDS < bis )); do eval "$1" && return 0; sleep 1; done; print -r -- "  Zeitüberschreitung bei: $1"; return 1; }
  leer() { ! grep -q '"id"' "$DATEN/auftraege.json" 2>/dev/null; }
  drin() { unzip -Z1 "$1" 2>/dev/null | grep -qF "$2"; }
  merke() { zeile=$(wc -l < "$DATEN/protokoll.log" | tr -d ' '); }
  seit() { tail -n +$(( zeile + 1 )) "$DATEN/protokoll.log" | grep -qE "$1"; }
  stopp() { kill $HP 2>/dev/null; wait $HP 2>/dev/null; }
  neustart() { stopp; "$B" --lauf >> "$T/helfer.out" 2>&1 & HP=$!; sleep 1; }
  sleep 1
fi

# Vergleiche laufen Byte für Byte: Für das Dateisystem sind „ö“ und „o + Trema“ derselbe Name, für Drive
# und die Synology nicht. `[[ -e ]]` reicht deshalb nicht, gezählt wird, was das Verzeichnis wirklich nennt.
heisst() { local f; for f in "$1"/*(DN:t); do [[ $f == "$2" ]] && return 0; done; return 1; }
# Oberster Ordner in der Zip. `unzip -Z1` ersetzt Umlaute durch Fragezeichen, deshalb auspacken und nachsehen.
wurzel() { rm -rf -- "$T/x/w"; mkdir -p "$T/x/w"; ditto -x -k "$1" "$T/x/w" 2>/dev/null; local a=("$T/x/w"/*.logicx(N:t)); print -r -- "$a[1]"; }
gleich() { diff -rq -x .DS_Store "$1" "$2" >/dev/null 2>&1; }
bytes() { print -rn -- "$1" | wc -c | tr -d ' '; }
abgelegt() { [[ -n $LOKAL ]] || leer; }      # in Drive erst fertig, wenn der Upload bestätigt und das Paket weggeräumt ist
# Lokal bestätigt niemand den Upload, Paket und Auftrag blieben liegen. Wegräumen, was in Drive der Helfer wegräumt.
lokalFertig() { [[ -n $LOKAL ]] || return 0; stopp; rm -rf -- "$D/$1.logicx"; print -r -- '[]' > "$DATEN/auftraege.json"; neustart; }
driveID() { xattr -p 'com.google.drivefs.item-id#S' "$1" 2>/dev/null; }
name() { "$B" --sicherer-name "$1"; }
# Legt ein Projekt mit Merkmal in den beobachteten Ordner. $1 Name des Pakets, $2 Merkmal. Das Vergleichsstück
# bleibt unter $T/x/n-<Merkmal>.logicx liegen.
lege() {
  rm -rf -- "$T/x/n-$2.logicx" "$T/x/n-neu.logicx"
  ditto "$V" "$T/x/n-$2.logicx"; print -r -- "$2" > "$T/x/n-$2.logicx/Resources/merkmal-$2.txt"
  ditto "$T/x/n-$2.logicx" "$T/x/n-neu.logicx"; mv "$T/x/n-neu.logicx" "$D/$1.logicx"
}
# Eine Zip, wie sie eine ältere Version abgelegt hätte: Name der Zip und Ordner darin tragen den rohen Namen.
alteZip() {
  rm -rf -- "$T/x/alt"; mkdir -p "$T/x/alt"; ditto "$V" "$T/x/alt/$1.logicx"; print -r -- "$2" > "$T/x/alt/$1.logicx/Resources/merkmal-$2.txt"
  ditto -c -k --sequesterRsrc --keepParent "$T/x/alt/$1.logicx" "$D/$1.logicx.zip"
}
ICH="$(scutil --get ComputerName)"
OE=$'\xc3\xb6'; OTREMA=$'o\xcc\x88'       # ö zusammengesetzt (NFC) und zerlegt (NFD)

print -r -- "T33 Namensregel, Funktion für sich (0.6.8)"
pruefe "Schrägstrich und Doppelpunkt zwischen Leerzeichen" '[[ $(name "Weihnachten / Kinder : Psalmen") == "Weihnachten - Kinder - Psalmen" ]]'
pruefe "Schrägstrich und Doppelpunkt ohne Leerzeichen" '[[ $(name "A/B:C") == "A-B-C" ]]'
pruefe "Zeichen, die Windows und SMB nicht kennen" '[[ $(name "a\\b*c\"d<e>f?g|h") == "a-b-c-d-e-f-g-h" ]]'
pruefe "Zeilenumbruch und Tabulator fallen weg" '[[ $(name $'"'"'Zeile1\nZeile2\tX'"'"') == "Zeile1Zeile2X" ]]'
pruefe "Ersatzzeichen aus alten SMB-Kopien fallen weg" '[[ $(name $'"'"'Alt\xef\x80\xa2Name\xef\x80\xa8'"'"') == "AltName" ]]'
pruefe "Ränder: Leerzeichen, Punkte am Ende, kein Punkt am Anfang" '[[ $(name "  .versteckt.. ") == "versteckt" ]]'
pruefe "leerer Name" '[[ $(name "") == "Ohne Namen" && $(name " . ") == "Ohne Namen" ]]'
BLEIBT='Folge 3 – „Advent“ & #1 (neu) [x] = ~$ + Vol. 2,  doppelt 🎵'
pruefe "alles andere bleibt" '[[ $(name "$BLEIBT") == "$BLEIBT" ]]'
pruefe "zerlegter Umlaut wird zusammengesetzt" '[[ $(name "H${OTREMA}rbuch") == "H${OE}rbuch" ]]'
LANG70="${(l:140::ä:)}"; LANG60="${(l:120::ä:)}"
pruefe "Kürzen trennt keinen Umlaut (120 Byte)" '[[ $(name "$LANG70") == "$LANG60" && $(bytes "$(name "$LANG70")") == 120 ]]'
WILD=$' ..A / B:C\\D \n E.. '
pruefe "zweimal angewendet ändert sich nichts mehr" '[[ $(name "$(name "$WILD")") == "$(name "$WILD")" ]]'

print -r -- "T34 Projekt mit Finder-Schrägstrich (0.6.8)"
merke; R1="Helfer-Test-N1 : Kinder und Psalmen"; S1="Helfer-Test-N1 - Kinder und Psalmen"; lege "$R1" n1
warte '[[ -f "$D/$S1.logicx.zip" ]] && abgelegt' 180
pruefe "Zip trägt den sicheren Namen" 'heisst "$D" "$S1.logicx.zip"'
pruefe "keine Zip mit Doppelpunkt" '! heisst "$D" "$R1.logicx.zip"'
pruefe "oberster Ordner in der Zip heißt genauso" '[[ $(wurzel "$D/$S1.logicx.zip") == "$S1.logicx" ]]'
pruefe "Inhalt des Projekts unverändert" 'gleich "$T/x/n-n1.logicx" "$T/x/w/$S1.logicx"'
pruefe "Anpassung wird einmal gemeldet" '[[ $(tail -n +$(( zeile + 1 )) "$DATEN/protokoll.log" | grep -cF "MELDUNG: Name angepasst: $R1 -> $S1") == 1 ]]'
[[ -n $LOKAL ]] || pruefe "Paket liegt mit seinem alten Namen in der Sicherung" '[[ ! -e "$D/$R1.logicx" && -n $(print -l "$T"/sicherung/*/"$R1.logicx"(N)) ]]'
lokalFertig "$R1"

print -r -- "T35 Leerzeichen am Ende des Namens (0.6.8)"
merke; lege "Helfer-Test-N2 " n2; S2="Helfer-Test-N2"
warte '[[ -f "$D/$S2.logicx.zip" ]] && abgelegt' 180
pruefe "Zip ohne Leerzeichen vor der Endung" 'heisst "$D" "$S2.logicx.zip" && ! heisst "$D" "$S2 .logicx.zip"'
pruefe "oberster Ordner in der Zip heißt genauso" '[[ $(wurzel "$D/$S2.logicx.zip") == "$S2.logicx" ]]'
pruefe "Inhalt des Projekts unverändert" 'gleich "$T/x/n-n2.logicx" "$T/x/w/$S2.logicx"'
lokalFertig "Helfer-Test-N2 "

print -r -- "T36 Zerlegter Umlaut im Namen (0.6.8)"
merke; lege "Helfer-Test-N3 H${OTREMA}rbuch" n3; S3="Helfer-Test-N3 H${OE}rbuch"
warte '[[ -f "$D/$S3.logicx.zip" ]] && abgelegt' 180
pruefe "Zip trägt den zusammengesetzten Umlaut" 'heisst "$D" "$S3.logicx.zip"'
pruefe "oberster Ordner in der Zip auch" '[[ $(wurzel "$D/$S3.logicx.zip") == "$S3.logicx" ]]'
pruefe "Inhalt des Projekts unverändert" 'gleich "$T/x/n-n3.logicx" "$T/x/w/$S3.logicx"'
pruefe "keine Meldung, nur ein Eintrag im Protokoll" 'seit "nur die Schreibweise der Umlaute" && ! seit "MELDUNG: Name angepasst"'
lokalFertig "Helfer-Test-N3 H${OTREMA}rbuch"

print -r -- "T37 Sehr langer Name (0.6.8)"
R4="Helfer-Test-N4 ${(l:204::sehr langer Name :)}"; R4="${R4% }"; S4="${R4[1,120]}"; S4="${S4% }"
merke; lege "$R4" n4
warte '[[ -f "$D/$S4.logicx.zip" ]] && abgelegt' 180
pruefe "Name der Zip ist auf 120 Byte gekürzt" 'heisst "$D" "$S4.logicx.zip" && (( $(bytes "$S4") <= 120 ))'
pruefe "oberster Ordner in der Zip heißt genauso" '[[ $(wurzel "$D/$S4.logicx.zip") == "$S4.logicx" ]]'
pruefe "Inhalt des Projekts unverändert" 'gleich "$T/x/n-n4.logicx" "$T/x/w/$S4.logicx"'
m4=$(md5 -q "$D/$S4.logicx.zip"); lokalFertig "$R4"
# Dasselbe Projekt noch einmal: Die Zip gibt es schon, also entsteht eine eigene Fassung mit dem längsten Namen.
lege "$R4" n4b
K4=(); warte 'K4=("$D"/Helfer-Test-N4*Stand*.logicx.zip(N)); (( ${#K4} == 1 )) && abgelegt' 180
pruefe "auch die eigene Fassung bleibt unter 200 Byte" '(( ${#K4} == 1 )) && (( $(bytes "${K4[1]:t}") < 200 ))'
pruefe "erste Zip wurde nicht überschrieben" '[[ $(md5 -q "$D/$S4.logicx.zip") == $m4 ]]'
lokalFertig "$R4"

print -r -- "T38 Kollision: Der sichere Name ist schon vergeben (0.6.8)"
S5="Helfer-Test-N5 - A"; alteZip "$S5" fremd; m5=$(md5 -q "$D/$S5.logicx.zip")
merke; lege "Helfer-Test-N5 : A" n5
K5=(); warte 'K5=("$D/$S5"\ –\ Stand*.logicx.zip(N)); (( ${#K5} == 1 )) && abgelegt' 180
pruefe "Zip des anderen Projekts wurde nicht überschrieben" '[[ $(md5 -q "$D/$S5.logicx.zip") == $m5 ]] && drin "$D/$S5.logicx.zip" merkmal-fremd.txt'
pruefe "das neue Projekt liegt als eigene Fassung daneben" '(( ${#K5} == 1 )) && drin "$K5[1]" merkmal-n5.txt'
pruefe "oberster Ordner darin trägt den sicheren Namen" '(( ${#K5} == 1 )) && [[ $(wurzel "$K5[1]") == "$S5.logicx" ]]'
pruefe "Inhalt des Projekts unverändert" 'gleich "$T/x/n-n5.logicx" "$T/x/w/$S5.logicx"'
lokalFertig "Helfer-Test-N5 : A"

print -r -- "T39 Bestehende Zip mit unsicherem Namen wird beim Zurücklegen umbenannt (0.6.8)"
stopp; R6="Helfer-Test-N6 : alt"; S6="Helfer-Test-N6 - alt"; alteZip "$R6" n6
Z6="$D/$R6.logicx.zip"; M6="$D/$R6.logicx.inarbeit"; W6="$T/arbeit/$R6.logicx"; m6=$(md5 -q "$Z6")
id6=""; [[ -n $LOKAL ]] || { warte '[[ -n $(driveID "$Z6") ]]' 120; id6=$(driveID "$Z6"); }
rm -rf -- "$W6"; ditto "$T/x/alt/$R6.logicx" "$W6"; print -r -- "Änderung 39" > "$W6/Resources/test-aenderung-39.txt"
print -r -- "{\"wer\":\"Test\",\"rechner\":\"$ICH\",\"konto\":\"$USER\",\"seit\":\"25.11. 12:00\"}" > "$M6"
# Ein Auftrag, wie ihn Version 0.6.7 hinterlassen hätte: alter Name im Auftrag, in der Arbeitskopie und in der Sperre.
cat > "$DATEN/auftraege.json" <<JSON
[{"art":"arbeit","arbeitsPfad":"$W6","gesehenInLogic":true,"id":"NAME-6","konflikt":false,"markerPfad":"$M6","meldung":"x","name":"$R6","originalZip":"$Z6","phase":"ruhe","quelleZip":"$Z6","ruheSeit":1,"stabil":0,"wurzelName":"$R6.logicx","basisMD5":"$m6","abdruckBeimOeffnen":"x"}]
JSON
merke; neustart
if [[ -n $LOKAL ]]; then warte 'seit "Zurückgelegt: "' 60; else warte 'seit "Zurückgelegt: " && leer' 180; fi
pruefe "Zip trägt jetzt den sicheren Namen" 'heisst "$D" "$S6.logicx.zip" && ! heisst "$D" "$R6.logicx.zip"'
pruefe "oberster Ordner in der Zip heißt genauso" '[[ $(wurzel "$D/$S6.logicx.zip") == "$S6.logicx" ]]'
pruefe "die Änderung steckt darin" 'drin "$D/$S6.logicx.zip" test-aenderung-39.txt'
pruefe "Umbenennung steht im Protokoll" 'seit "Name angepasst: $R6 -> $S6"'
E6=("$T"/sicherung/*/"$R6"\ –\ ersetzt*.logicx.zip(N))
pruefe "bisherige Zip liegt unverändert in der Sicherung" '(( ${#E6} == 1 )) && [[ $(md5 -q "$E6[1]") == $m6 ]]'
if [[ -n $LOKAL ]]; then
  pruefe "die Sperre ist mit umgezogen" '[[ -f "$D/$S6.logicx.inarbeit" ]] && ! heisst "$D" "$R6.logicx.inarbeit"'
else
  pruefe "Sperren sind weg, Arbeitskopie auch" '[[ ! -e "$D/$S6.logicx.inarbeit" && ! -e $M6 && ! -e $W6 ]]'
  pruefe "in Drive ist es dieselbe Datei geblieben (Datei-ID)" '[[ -n $id6 && $(driveID "$D/$S6.logicx.zip") == $id6 ]]'
fi

print -r -- "T40 Umbenennen überschreibt keine Zip, die schon so heißt (0.6.8)"
stopp; R7="Helfer-Test-N7 : alt"; S7="Helfer-Test-N7 - alt"; alteZip "$S7" fremd; mf7=$(md5 -q "$D/$S7.logicx.zip"); alteZip "$R7" n7
Z7N="$D/$R7.logicx.zip"; W7="$T/arbeit/$R7.logicx"; m7=$(md5 -q "$Z7N")
rm -rf -- "$W7"; ditto "$T/x/alt/$R7.logicx" "$W7"; print -r -- "Änderung 40" > "$W7/Resources/test-aenderung-40.txt"
cat > "$DATEN/auftraege.json" <<JSON
[{"art":"arbeit","arbeitsPfad":"$W7","gesehenInLogic":true,"id":"NAME-7","konflikt":false,"meldung":"x","name":"$R7","originalZip":"$Z7N","phase":"ruhe","quelleZip":"$Z7N","ruheSeit":1,"stabil":0,"wurzelName":"$R7.logicx","basisMD5":"$m7","abdruckBeimOeffnen":"x"}]
JSON
merke; neustart
if [[ -n $LOKAL ]]; then warte 'seit "Zurückgelegt: "' 60; else warte 'seit "Zurückgelegt: " && leer' 180; fi
pruefe "die andere Zip blieb unverändert" '[[ $(md5 -q "$D/$S7.logicx.zip") == $mf7 ]] && drin "$D/$S7.logicx.zip" merkmal-fremd.txt'
pruefe "die eigene Zip bekam einen freien sicheren Namen" 'heisst "$D" "$S7 (2).logicx.zip" && ! heisst "$D" "$R7.logicx.zip"'
pruefe "die Änderung steckt darin" 'drin "$D/$S7 (2).logicx.zip" test-aenderung-40.txt'

if [[ -z $LOKAL ]]; then
  print -r -- "T41 Zip mit unsicherem Namen öffnen: Hinweis, Arbeitskopie mit sicherem Namen (0.6.8)"
  R8="Helfer-Test-N8 : offen"; S8="Helfer-Test-N8 - offen"; alteZip "$R8" n8; m8=$(md5 -q "$D/$R8.logicx.zip")
  merke; "$B" --oeffne "$D/$R8.logicx.zip"; warte 'gesehen' 120
  pruefe "Hinweis beim Öffnen, genau einmal" '[[ $(tail -n +$(( zeile + 1 )) "$DATEN/protokoll.log" | grep -cF "MELDUNG: Der Name „$R8“ kommt nicht überall an") == 1 ]]'
  pruefe "Arbeitskopie trägt den sicheren Namen" 'heisst "$T/arbeit" "$S8.logicx"'
  pruefe "im Projekt wurde nichts umbenannt" 'gleich "$T/x/alt/$R8.logicx" "$T/arbeit/$S8.logicx"'
  schliesse "Helfer-Test-N8"; warte 'leer' 90
  pruefe "ohne Änderung bleibt die Zip, wie sie ist" 'heisst "$D" "$R8.logicx.zip" && [[ $(md5 -q "$D/$R8.logicx.zip") == $m8 ]]'
  pruefe "Sperre ist weg" '[[ ! -e "$D/$R8.logicx.inarbeit" ]]'
else
  stopp
  print -r -- "=== Ergebnis (lokal, ohne Drive und Logic): $ok bestanden, $schlecht fehlgeschlagen"
  print -r -- "--- Ordner"; ls -1A "$D"
  print -r -- "--- Protokoll"; cut -c12- "$DATEN/protokoll.log" | tail -30
  (( schlecht == 0 ))
fi
