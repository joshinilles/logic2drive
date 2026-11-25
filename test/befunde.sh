# Tests zu den Befunden der Code-Prüfung vom 23.11.2026. Wird von gesamt.sh eingebunden.
merke() { zeile=$(wc -l < "$DATEN/protokoll.log" | tr -d ' '); }
seit() { tail -n +$(( zeile + 1 )) "$DATEN/protokoll.log" | grep -qE "$1"; }
phase() { grep -q "\"phase\" : \"$1\"" "$DATEN/auftraege.json" 2>/dev/null; }
anzahl() { grep -c '"id"' "$DATEN/auftraege.json" 2>/dev/null; }
inLogic() { /usr/bin/timeout 12 osascript -e 'tell application "Logic Pro" to get name of documents' 2>/dev/null | grep -q "$1"; }
gross() { head -c 40000000 /dev/urandom > "$1/Resources/test-gross.bin"; }
neueZip() { rm -rf -- "$T/x/$1.logicx"; ditto "$V" "$T/x/$1.logicx"; ditto -c -k --sequesterRsrc --keepParent "$T/x/$1.logicx" "$D/$1.logicx.zip"; rm -rf -- "$T/x/$1.logicx"; }
stopp() { kill $HP 2>/dev/null; wait $HP 2>/dev/null; }
neustart() { stopp; "$B" --lauf >> "$T/helfer.out" 2>&1 & HP=$!; sleep 1; }
fremdeZip() { rm -rf -- "$T/x/f-$1"; mkdir -p "$T/x/f-$1"; ditto -x -k "$2" "$T/x/f-$1"; print -r -- "Fremde Fassung" > "$T/x/f-$1/$1.logicx/Resources/fremd.txt"; ditto -c -k --sequesterRsrc --keepParent "$T/x/f-$1/$1.logicx" "$T/x/f-$1.zip"; }

print -r -- "T8 Wieder geöffnet während des Uploads"
merke; neueZip Helfer-Test-K; ZK="$D/Helfer-Test-K.logicx.zip"; WK="$T/arbeit/Helfer-Test-K.logicx"
"$B" --oeffne "$ZK"; warte 'gesehen' 120
gross "$WK"; print -r -- "Änderung 8a" > "$WK/Resources/test-aenderung-8a.txt"
schliesse Helfer-Test-K; warte 'seit "Zurückgelegt: Helfer-Test-K"' 90
"$B" --oeffne "$ZK"; warte 'seit "Wieder in Arbeit" && gesehen' 45
pruefe "Arbeitskopie bleibt, solange Logic sie offen hat" '[[ -d $WK ]] && ! leer'
sleep 30
pruefe "auch nach dem Upload nicht weggeräumt" '[[ -d $WK ]] && ! leer && inLogic Helfer-Test-K'
print -r -- "Änderung 8b" > "$WK/Resources/test-aenderung-8b.txt"
schliesse Helfer-Test-K; warte 'leer' 180
pruefe "beide Änderungen stecken in der Zip" 'drin "$ZK" test-aenderung-8a.txt && drin "$ZK" test-aenderung-8b.txt'
pruefe "Sperre und Arbeitskopie sind weg" '[[ ! -e ${ZK%.zip}.inarbeit && ! -e $WK ]]'

print -r -- "T9 Abgelegtes Paket wird während des Uploads geöffnet"
merke; ditto "$V" "$T/x/Helfer-Test-P.logicx"; gross "$T/x/Helfer-Test-P.logicx"; mv "$T/x/Helfer-Test-P.logicx" "$D/"
warte 'seit "Eingepackt: Helfer-Test-P"' 120
P9="$D/Helfer-Test-P.logicx"; [[ -d $P9 ]] || P9="$D/Helfer-Test-P 2.logicx"
open -g -b com.apple.logic10 "$P9"; warte 'inLogic Helfer-Test-P' 45
sleep 30
pruefe "solange offen bleibt das Paket im Drive-Ordner" '[[ -z $(print -l "$T"/sicherung/*/Helfer-Test-P.logicx) ]] && ! leer'
schliesse Helfer-Test-P; warte 'leer' 180
pruefe "nach dem Schließen liegt es in der Sicherung" '[[ -n $(print -l "$T"/sicherung/*/Helfer-Test-P.logicx) ]]'
pruefe "kein Paket mehr im Drive-Ordner" '[[ ! -d $D/Helfer-Test-P.logicx && ! -d "$D/Helfer-Test-P 2.logicx" ]]'

print -r -- "T10 Kaltstart per Doppelklick behält alte Aufträge"
stopp
cat > "$DATEN/auftraege.json" <<JSON
[{"art":"arbeit","arbeitsPfad":"$T/arbeit/gibts-nicht.logicx","gesehenInLogic":false,"id":"ALT-1","konflikt":false,"meldung":"alt","name":"Altauftrag","phase":"fehlt","quelleZip":"$D/gibts-nicht.logicx.zip","stabil":0}]
JSON
neueZip Helfer-Test-S
open -n -g -a "${B:h:h:h}" --env LOGIC2DRIVE_DATEN="$DATEN" --env LOGIC2DRIVE_STILL=1 "$D/Helfer-Test-S.logicx.zip"
warte 'gesehen' 120
pruefe "alter Auftrag überlebt den Start" 'grep -q "ALT-1" "$DATEN/auftraege.json"'
pruefe "neuer Auftrag ist dazugekommen" '[[ $(anzahl) == 2 ]]'
schliesse Helfer-Test-S; warte '[[ $(anzahl) == 1 ]]' 60
pkill -f "${B}\$"; sleep 1
rm -f -- "$DATEN/auftraege.json"; neustart

print -r -- "T11 Nach Start oder Aufwachen wird nicht sofort ersetzt"
konfig 60; neustart; neueZip Helfer-Test-W; ZW="$D/Helfer-Test-W.logicx.zip"; m0=$(md5 -q "$ZW")
"$B" --oeffne "$ZW"; warte 'gesehen' 90
print -r -- "Änderung 11" > "$T/arbeit/Helfer-Test-W.logicx/Resources/test-aenderung-11.txt"
schliesse Helfer-Test-W; warte 'grep -q "Drive gleicht noch ab" "$DATEN/auftraege.json"' 35
pruefe "wartet, statt sofort zu ersetzen" '[[ $(md5 -q "$ZW") == $m0 ]] && ! leer'
warte 'leer' 150
pruefe "danach wird ersetzt" 'drin "$ZW" test-aenderung-11.txt'
konfig 0; neustart

print -r -- "T12 Fremde Sperre während der Arbeit"
neueZip Helfer-Test-F; ZF="$D/Helfer-Test-F.logicx.zip"; MF="$D/Helfer-Test-F.logicx.inarbeit"; mf=$(md5 -q "$ZF")
"$B" --oeffne "$ZF"; warte 'gesehen' 90
print -r -- "Änderung 12" > "$T/arbeit/Helfer-Test-F.logicx/Resources/test-aenderung-12.txt"
print -r -- '{"wer":"Testperson","rechner":"Anderer Mac","konto":"test","seit":"23.11. 12:00"}' > "$MF"
schliesse Helfer-Test-F; warte 'leer' 120
KF=("$D"/Helfer-Test-F\ –\ Stand*.logicx.zip)
pruefe "Zip wurde nicht überschrieben" '[[ $(md5 -q "$ZF") == $mf ]]'
pruefe "eigene Fassung liegt daneben" '(( ${#KF} == 1 )) && drin "$KF[1]" test-aenderung-12.txt'
pruefe "fremde Sperre bleibt liegen" '[[ -f $MF ]]'
rm -f -- "$MF"

print -r -- "T13 Eigenständiges „Name 7“ wird nicht verwechselt"
merke; ditto "$V" "$T/x/Helfer-Test-G.logicx"; gross "$T/x/Helfer-Test-G.logicx"; mv "$T/x/Helfer-Test-G.logicx" "$D/"
warte 'seit "Eingepackt: Helfer-Test-G"' 120
ZG="$D/Helfer-Test-G.logicx.zip"; mg=$(md5 -q "$ZG")
ditto "$V" "$T/x/Helfer-Test-G 7.logicx"; print -r -- "Eigenständig" > "$T/x/Helfer-Test-G 7.logicx/Resources/eigenstaendig.txt"; mv "$T/x/Helfer-Test-G 7.logicx" "$D/"
if [[ -d $D/Helfer-Test-G.logicx ]]; then mv "$D/Helfer-Test-G.logicx" "$T/x/g-weg.logicx"; elif [[ -d "$D/Helfer-Test-G 2.logicx" ]]; then mv "$D/Helfer-Test-G 2.logicx" "$T/x/g-weg.logicx"; fi
g7offen() { local a=("$D"/Helfer-Test-G\ *.logicx(/)); (( ${#a} > 0 )); }
Z7="$D/Helfer-Test-G 7.logicx.zip"
warte '[[ -f $Z7 ]] && ! g7offen && leer' 200
pruefe "Zip des ersten Projekts blieb unverändert" '[[ $(md5 -q "$ZG") == $mg ]] && ! drin "$ZG" eigenstaendig.txt'
pruefe "das eigenständige Projekt hat eine eigene Zip" '[[ -f $Z7 ]] && drin "$Z7" eigenstaendig.txt'
pruefe "und behält seinen Namen" '[[ $(unzip -Z1 "$Z7" | head -1) == "Helfer-Test-G 7.logicx/" ]]'

print -r -- "T14 Zip wird während des Uploads ersetzt"
merke; neueZip Helfer-Test-H; ZH="$D/Helfer-Test-H.logicx.zip"; WH="$T/arbeit/Helfer-Test-H.logicx"
fremdeZip Helfer-Test-H "$ZH"; mh=$(md5 -q "$T/x/f-Helfer-Test-H.zip")
"$B" --oeffne "$ZH"; warte 'gesehen' 90
gross "$WH"; print -r -- "Änderung 14" > "$WH/Resources/test-aenderung-14.txt"
schliesse Helfer-Test-H; warte 'seit "Zurückgelegt: Helfer-Test-H"' 90
"$S/e3/ersetze" "$ZH" "$T/x/f-Helfer-Test-H.zip" >/dev/null
warte 'leer' 200
KH=("$D"/Helfer-Test-H\ –\ Stand*.logicx.zip)
pruefe "fremde Fassung bleibt die Zip" '[[ $(md5 -q "$ZH") == $mh ]]'
pruefe "eigener Stand liegt daneben" '(( ${#KH} == 1 )) && drin "$KH[1]" test-aenderung-14.txt'
pruefe "Auftrag hängt nicht" 'leer && [[ ! -e $WH ]]'

print -r -- "T15 Arbeitskopie fehlt"
stopp; neueZip Helfer-Test-J; ZJ="$D/Helfer-Test-J.logicx.zip"; MJ="$D/Helfer-Test-J.logicx.inarbeit"
print -r -- "{\"wer\":\"Test\",\"rechner\":\"$(scutil --get ComputerName)\",\"konto\":\"$USER\",\"seit\":\"23.11. 12:00\"}" > "$MJ"
cat > "$DATEN/auftraege.json" <<JSON
[{"art":"arbeit","arbeitsPfad":"$T/arbeit/gibts-nicht-j.logicx","gesehenInLogic":true,"id":"FEHLT-1","konflikt":false,"markerPfad":"$MJ","meldung":"x","name":"Helfer-Test-J","phase":"ruhe","quelleZip":"$ZJ","ruheSeit":1,"stabil":0,"wurzelName":"Helfer-Test-J.logicx"}]
JSON
neustart; warte 'phase fehlt' 15
pruefe "Zustand wird als fehlend erkannt" 'phase fehlt && grep -q "\"problem\" : \"Arbeitskopie fehlt\"" "$DATEN/auftraege.json"'
"$B" --oeffne "$ZJ"; warte '! grep -q FEHLT-1 "$DATEN/auftraege.json" && gesehen' 90
pruefe "neues Öffnen ersetzt den alten Auftrag" '[[ $(anzahl) == 1 ]] && ! grep -q FEHLT-1 "$DATEN/auftraege.json"'
schliesse Helfer-Test-J; warte 'leer' 60
pruefe "Sperre ist danach weg" '[[ ! -e $MJ ]]'

print -r -- "T16 Arbeitskopie umbenannt"
merke; neueZip Helfer-Test-M; ZM="$D/Helfer-Test-M.logicx.zip"
"$B" --oeffne "$ZM"; warte 'gesehen' 90
schliesse Helfer-Test-M; mv "$T/arbeit/Helfer-Test-M.logicx" "$T/arbeit/Helfer-Test-M umbenannt.logicx"
warte 'seit "wurde umbenannt"' 15; warte 'leer' 45
pruefe "Helfer folgt der Umbenennung" 'seit "wurde umbenannt"'
pruefe "Auftrag wird abgeschlossen" 'leer && [[ ! -e ${ZM%.zip}.inarbeit ]]'

print -r -- "T17 Datei mit Zukunftsdatum"
ditto "$V" "$T/x/Helfer-Test-U.logicx"; print -r -- zukunft > "$T/x/Helfer-Test-U.logicx/Resources/zukunft.txt"
touch -t 209901010000 "$T/x/Helfer-Test-U.logicx/Resources/zukunft.txt"; mv "$T/x/Helfer-Test-U.logicx" "$D/"
warte '[[ -f $D/Helfer-Test-U.logicx.zip && ! -d $D/Helfer-Test-U.logicx && ! -d "$D/Helfer-Test-U 2.logicx" ]] && leer' 180
pruefe "Paket wird trotzdem eingepackt" 'drin "$D/Helfer-Test-U.logicx.zip" zukunft.txt'

print -r -- "T18 Dauerfehler wird gemeldet"
merke; ditto "$V" "$T/x/Helfer-Test-L.logicx"; ln -s ProjectInformation.plist "$T/x/Helfer-Test-L.logicx/Resources/verknuepfung"; mv "$T/x/Helfer-Test-L.logicx" "$D/"
warte 'seit "MELDUNG: .*Verknüpfungen"' 45
pruefe "Meldung steht im Protokoll" 'seit "MELDUNG: .*Verknüpfungen"'
pruefe "Paket wurde nicht eingepackt" '[[ ! -e $D/Helfer-Test-L.logicx.zip ]]'
mkdir -p "$A/T18"; for f in "$D"/Helfer-Test-L*(D); do mv "$f" "$A/T18/"; done

print -r -- "T19 Volle Platte beendet den Helfer nicht"
IMG="$T/x/voll.dmg"; VD="$T/x/voll"; mkdir -p "$VD"
if hdiutil create -quiet -size 2m -fs HFS+ -volname LHTest "$IMG" && hdiutil attach -quiet -nobrowse -mountpoint "$VD" "$IMG"; then
  mkdir -p "$VD/daten"; : > "$VD/daten/protokoll.log"; : > "$VD/daten/sperre"; print -r -- '[]' > "$VD/daten/auftraege.json"
  print -r -- "{\"ordner\":[],\"arbeitsordner\":\"$T/x/leer\",\"sicherungsordner\":\"$T/x/leer2\",\"ruheSekunden\":6,\"stabilSekunden\":6}" > "$VD/daten/einstellungen.json"
  dd if=/dev/zero of="$VD/fuell" bs=1024 2>/dev/null
  LOGIC2DRIVE_DATEN="$VD/daten" "$B" --lauf >/dev/null 2>&1 &
  VP=$!; sleep 8
  pruefe "Helfer lebt bei voller Platte weiter" 'kill -0 $VP 2>/dev/null'
  kill $VP 2>/dev/null; wait $VP 2>/dev/null; hdiutil detach -quiet "$VD"
else
  pruefe "Testplatte ließ sich anlegen" 'false'
fi

print -r -- "T20 Unlesbare Auftragsliste"
stopp; print -r -- 'kaputt{' > "$DATEN/auftraege.json"; neustart
warte '[[ -n $(print -l "$DATEN"/auftraege.unlesbar-*.json) ]]' 10
pruefe "kaputte Liste wurde beiseitegelegt" '[[ -n $(print -l "$DATEN"/auftraege.unlesbar-*.json) ]]'
pruefe "Helfer läuft weiter" 'kill -0 $HP 2>/dev/null'

print -r -- "T21 Drive vergibt die nächste freie Nummer"
: > "$D/Helfer-Test-N 6.logicx"
ditto "$V" "$T/x/Helfer-Test-N 5.logicx"; print -r -- "Folge 5" > "$T/x/Helfer-Test-N 5.logicx/Resources/folge-5.txt"; mv "$T/x/Helfer-Test-N 5.logicx" "$D/"
Z5="$D/Helfer-Test-N 5.logicx.zip"
n5offen() { local a=("$D"/Helfer-Test-N\ *.logicx(/)); (( ${#a} > 0 )); }
warte '[[ -f $Z5 ]] && ! n5offen && leer' 180
pruefe "Zip trägt den ursprünglichen Namen" '[[ -f $Z5 ]] && drin "$Z5" folge-5.txt'
pruefe "oberster Ordner heißt richtig" '[[ $(unzip -Z1 "$Z5" | head -1) == "Helfer-Test-N 5.logicx/" ]]'
pruefe "keine Zip unter der falschen Nummer" '[[ ! -e "$D/Helfer-Test-N 7.logicx.zip" ]]'
pruefe "leere Datei ist weg, fremde Nummer 6 bleibt" '[[ ! -e "$D/Helfer-Test-N 5.logicx" && -f "$D/Helfer-Test-N 6.logicx" ]]'

print -r -- "T22 AppleDouble-Rest im Projekt"
ditto "$V" "$T/x/Helfer-Test-D.logicx"; print -r -- audio > "$T/x/Helfer-Test-D.logicx/Resources/test.wav"; print -r -- rest > "$T/x/Helfer-Test-D.logicx/Resources/._test.wav"; mv "$T/x/Helfer-Test-D.logicx" "$D/"
ZD="$D/Helfer-Test-D.logicx.zip"
warte '[[ -f $ZD && ! -d $D/Helfer-Test-D.logicx && ! -d "$D/Helfer-Test-D 2.logicx" ]] && leer' 180
pruefe "Projekt wird eingepackt" '[[ -f $ZD ]] && drin "$ZD" Resources/test.wav'
SD=("$T"/sicherung/*/Helfer-Test-D.logicx)
pruefe "Original mit Rest liegt in der Sicherung" '(( ${#SD} == 1 )) && [[ -f $SD[1]/Resources/._test.wav ]]'

print -r -- "T23 Drive meldet eine falsche Größe"
stopp; neueZip Helfer-Test-B; ZB="$D/Helfer-Test-B.logicx.zip"; WB="$T/arbeit/Helfer-Test-B.logicx"; ditto "$V" "$WB"
mb=$(md5 -q "$ZB"); fg=$(( $(stat -f %z "$ZB") + 4398046511104 ))
cat > "$DATEN/auftraege.json" <<JSON
[{"art":"arbeit","arbeitsPfad":"$WB","gesehenInLogic":false,"id":"GROESSE-1","konflikt":false,"meldung":"x","name":"Helfer-Test-B","originalZip":"$ZB","phase":"hochladen","quelleZip":"$ZB","stabil":0,"uploadSeit":1,"wurzelName":"Helfer-Test-B.logicx","zielGroesse":$fg,"zielMD5":"$mb","zielZip":"$ZB"}]
JSON
merke; neustart; warte 'seit "falsche Größe"' 40; warte 'leer' 120
KB=("$D"/Helfer-Test-B\ –\ Stand*.logicx.zip)
pruefe "falsche Größe wird als solche erkannt" 'seit "falsche Größe"'
pruefe "keine zusätzliche Fassung" '(( ${#KB} == 0 ))'
pruefe "Zip bleibt, Auftrag endet" '[[ $(md5 -q "$ZB") == $mb ]] && leer'

print -r -- "T24 Umbenannt und wieder geöffnet während des Uploads"
merke; neueZip Helfer-Test-V; ZV="$D/Helfer-Test-V.logicx.zip"; WV="$T/arbeit/Helfer-Test-V.logicx"; WV2="$T/arbeit/Helfer-Test-V neu.logicx"
"$B" --oeffne "$ZV"; warte 'gesehen' 90
gross "$WV"; print -r -- "Änderung 24a" > "$WV/Resources/test-aenderung-24a.txt"
schliesse Helfer-Test-V; warte 'seit "Zurückgelegt: Helfer-Test-V"' 90
mv "$WV" "$WV2"; open -g -b com.apple.logic10 "$WV2"; warte 'inLogic "Helfer-Test-V neu"' 30
sleep 25
pruefe "umbenannte Kopie bleibt, solange sie offen ist" '[[ -d $WV2 ]] && ! leer'
print -r -- "Änderung 24b" > "$WV2/Resources/test-aenderung-24b.txt"
schliesse "Helfer-Test-V neu"; warte 'leer' 180
pruefe "beide Änderungen stecken in der Zip" 'drin "$ZV" test-aenderung-24a.txt && drin "$ZV" test-aenderung-24b.txt'
pruefe "Sperre ist weg" '[[ ! -e ${ZV%.zip}.inarbeit ]]'

print -r -- "T25 Nie erkanntes, unverändertes Projekt gibt die Sperre frei"
neueZip Helfer-Test-O; ZO="$D/Helfer-Test-O.logicx.zip"; MO="$D/Helfer-Test-O.logicx.inarbeit"; mo=$(md5 -q "$ZO")
"$B" --oeffne "$ZO"; warte 'gesehen' 90; stopp
schliesse Helfer-Test-O
/usr/bin/timeout 25 osascript -e 'with timeout of 20 seconds' -e 'tell application "Logic Pro" to quit saving no' -e 'end timeout' >/dev/null 2>&1
warte '! pgrep -x "Logic Pro" >/dev/null' 40
sed -i '' -e 's/"gesehenInLogic" : true/"gesehenInLogic" : false/' -e 's/"geoeffnetAm" : [0-9.e+]*/"geoeffnetAm" : 1/' "$DATEN/auftraege.json"
neustart; warte 'leer' 45
pruefe "Auftrag löst sich, obwohl Logic ihn nie gemeldet hat" 'leer'
pruefe "Sperre ist weg" '[[ ! -e $MO ]]'
pruefe "Zip blieb unverändert" '[[ $(md5 -q "$ZO") == $mo ]]'

print -r -- "T26 Anderes Paket am Platz der Arbeitskopie"
neueZip Helfer-Test-I; ZI="$D/Helfer-Test-I.logicx.zip"; WI="$T/arbeit/Helfer-Test-I.logicx"; mi=$(md5 -q "$ZI")
ditto "$V" "$T/x/i-fremd.logicx"; print -r -- "Fremdes Paket" > "$T/x/i-fremd.logicx/Resources/fremd.txt"
"$B" --oeffne "$ZI"; warte 'gesehen' 90
pruefe "Logic wird auch über die Bundle-ID gefunden" '[[ -n $(lsappinfo find bundleid=com.apple.logic10) ]]'
schliesse Helfer-Test-I; mv "$WI" "$T/x/i-original.logicx"; mv "$T/x/i-fremd.logicx" "$WI"
warte 'phase fehlt' 20; sleep 14
pruefe "Auftrag hält an, statt das fremde Paket einzupacken" 'phase fehlt && [[ $(md5 -q "$ZI") == $mi ]]'
pruefe "fremdes Paket bleibt unangetastet" '[[ -f $WI/Resources/fremd.txt ]]'
mv "$WI" "$T/x/i-fremd.logicx"; mv "$T/x/i-original.logicx" "$WI"; warte 'leer' 45
pruefe "mit dem ursprünglichen Paket geht es weiter" 'leer && [[ ! -e ${ZI%.zip}.inarbeit ]]'

print -r -- "T27 Sperre lässt sich nicht anlegen"
merke; neueZip Helfer-Test-A; ZA="$D/Helfer-Test-A.logicx.zip"; MA="$D/Helfer-Test-A.logicx.inarbeit"
mkdir -p "$MA"; print -r -- belegt > "$MA/belegt"
"$B" --oeffne "$ZA"; warte 'seit "MELDUNG: .*Sperre"' 30
pruefe "Öffnen wird mit Meldung abgebrochen" 'seit "MELDUNG: .*Sperre"'
pruefe "kein Auftrag und keine Arbeitskopie" 'leer && [[ ! -e $T/arbeit/Helfer-Test-A.logicx ]]'
mkdir -p "$A/T27"; mv "$MA" "$A/T27/"

print -r -- "T28 Kaputte Einstellungen"
stopp; print -r -- 'kaputt{' > "$DATEN/einstellungen.json"; merke; neustart
warte 'seit "MELDUNG: .*Einstellungen"' 15
pruefe "wird sichtbar gemeldet" 'seit "MELDUNG: .*Einstellungen"'
pruefe "beobachtet keinen Ordner statt des Testordners" 'seit "gestartet. Beobachtet: $"'
pruefe "Datei wird nicht überschrieben" '[[ $(<"$DATEN/einstellungen.json") == "kaputt{" ]]'
konfig 0; neustart

print -r -- "T29 Sicherung wird nach der Frist geräumt (0.4)"
stopp; HEUTE=$(date +%Y-%m-%d); mkdir -p "$T/sicherung/2020-01-01/Alt-Test.logicx" "$T/sicherung/$HEUTE/Neu-Test.logicx"
print -r -- alt > "$T/sicherung/2020-01-01/Alt-Test.logicx/datei.txt"
merke; neustart; warte 'seit "Sicherung nach 90 Tagen"' 15
pruefe "alte Sicherung liegt im Papierkorb" 'seit "Sicherung nach 90 Tagen" && [[ ! -e $T/sicherung/2020-01-01 ]]'
pruefe "frische Sicherung bleibt" '[[ -d $T/sicherung/$HEUTE/Neu-Test.logicx ]]'

print -r -- "T32 Ersetzte Zips bleiben nur 14 Tage (0.4.2)"
stopp; VOR20=$(date -v-20d +%Y-%m-%d); mkdir -p "$T/sicherung/$VOR20/Paket-Test.logicx"
print -r -- zip > "$T/sicherung/$VOR20/Zip-Test – ersetzt 04.11. 10.00.logicx.zip"; print -r -- zip > "$T/sicherung/$HEUTE/Zip-Test – ersetzt $(date +%d.%m.) 10.00.logicx.zip"
merke; neustart; warte 'seit "Sicherung nach 14 Tagen"' 15
pruefe "ersetzte Zip von vor 20 Tagen liegt im Papierkorb" 'seit "Sicherung nach 14 Tagen" && [[ -z $(print -l "$T/sicherung/$VOR20"/*ersetzt*(N)) ]]'
pruefe "Paket vom selben Tag bleibt" '[[ -d $T/sicherung/$VOR20/Paket-Test.logicx ]]'
pruefe "ersetzte Zip von heute bleibt" '[[ -n $(print -l "$T/sicherung/$HEUTE"/*ersetzt*(N)) ]]'

print -r -- "T30 Projekt, das die Cloud normal hochlädt, wird nach der Arbeit in Logic eingepackt (0.4)"
IC="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Logic2Drive-Test"
if [[ -d ${IC:h} ]]; then
  stopp; mkdir -p "$IC"; ORDNER="\"$D\",\"$IC\""; konfig 0
  ditto "$V" "$T/x/Helfer-Test-Z.logicx"; mv "$T/x/Helfer-Test-Z.logicx" "$IC/"; sleep 40
  merke; neustart; sleep 20
  pruefe "unberührtes Projekt in der Cloud bleibt liegen" '[[ -d $IC/Helfer-Test-Z.logicx && ! -e $IC/Helfer-Test-Z.logicx.zip ]] && leer'
  open -g -b com.apple.logic10 "$IC/Helfer-Test-Z.logicx"; warte 'inLogic Helfer-Test-Z' 60
  print -r -- "Änderung 30" > "$IC/Helfer-Test-Z.logicx/Resources/test-aenderung-30.txt"; sleep 25
  pruefe "solange offen entsteht keine Zip" '[[ ! -e $IC/Helfer-Test-Z.logicx.zip ]]'
  schliesse Helfer-Test-Z
  warte '[[ -f $IC/Helfer-Test-Z.logicx.zip && ! -d $IC/Helfer-Test-Z.logicx ]] && leer' 200
  pruefe "nach dem Schließen wird es eingepackt" '[[ -f $IC/Helfer-Test-Z.logicx.zip ]] && drin "$IC/Helfer-Test-Z.logicx.zip" test-aenderung-30.txt'
  pruefe "obwohl es schon in der Cloud lag" 'seit "liegt schon in der Cloud und wird trotzdem eingepackt"'
  pruefe "Paket liegt in der Sicherung, nicht mehr in der Cloud" '[[ ! -d $IC/Helfer-Test-Z.logicx && -n $(print -l "$T"/sicherung/*/Helfer-Test-Z.logicx) ]]'
  mkdir -p "$A/T30"; for f in "$IC"/*(DN); do mv "$f" "$A/T30/"; done; rmdir "$IC" 2>/dev/null
  stopp; ORDNER="\"$D\""; konfig 0; neustart
else
  print -r -- "  übersprungen: iCloud Drive ist auf diesem Mac nicht eingerichtet"
fi

print -r -- "T31 Zeile „Zuletzt“ im Menü (0.4.1)"
ZD="$T/x/zuletzt"; mkdir -p "$ZD"; zuletzt() { LOGIC2DRIVE_DATEN="$ZD" "$B" --zuletzt; }
pruefe "ohne Protokoll keine Zeile" '[[ -z $(zuletzt) ]]'
print -r -- "2026-01-02 08:00:00  MELDUNG: alte Meldung" > "$ZD/protokoll.log"
pruefe "ältere Meldung mit Datum" '[[ $(zuletzt) == "Zuletzt, 02.01. 08:00: alte Meldung" ]]'
print -r -- "$(date +%Y-%m-%d) 09:05:00  MELDUNG: „A“ liegt jetzt als Zip in Google Drive." >> "$ZD/protokoll.log"
print -r -- "$(date +%Y-%m-%d) 09:06:00  Abgelegt: B" >> "$ZD/protokoll.log"
pruefe "letzte Meldung von heute, andere Zeilen zählen nicht" '[[ $(zuletzt) == "Zuletzt, heute 09:05: „A“ liegt jetzt als Zip in Google Drive." ]]'

# Namensregel (0.6.8): eigene Datei, weil sie auch allein läuft, lokal und ohne Drive und Logic.
source "${0:A:h}/namen.sh"
