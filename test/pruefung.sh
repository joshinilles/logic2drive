#!/bin/zsh -f
# Tests zur Bounce-Prüfung (pruefung.swift): Synthetische Dateien mit bekannten Fehlern, erzeugt mit ffmpeg, und
# der Bericht der Prüfung dazu. Läuft ohne Logic und ohne Google Drive.
#
#   zsh -f test/pruefung.sh
#   PRUEF="<programm>" PRUEFMATERIAL=<ordner mit echten Bounces (*.mp3)> zsh -f test/pruefung.sh
#
# PRUEF ist das Prüfkommando, `${=PRUEF} <datei>` gibt den Bericht aus (Vorgabe: die installierte App).
# Knackser in reinem Synthetik-Material sagen wenig: Echte Sprache ist schwerer vorherzusagen. Ist PRUEFMATERIAL
# gesetzt, werden Knackser zusätzlich in Ausschnitte echter Bounces eingebaut; ohne die Variable fallen diese
# Fälle weg („übersprungen“).
emulate -R zsh
setopt null_glob
PRUEF="${PRUEF:-/Applications/Logic2Drive.app/Contents/MacOS/Logic2Drive --pruefe}"
FF="${FFMPEG:-$(whence -p ffmpeg || print -r -- /opt/homebrew/bin/ffmpeg)}"
[[ -x $FF ]] || { print -r -- "STOPP: ffmpeg fehlt (brew install ffmpeg), ohne ffmpeg gibt es keine Testdateien"; exit 1; }
[[ -x ${${=PRUEF}[1]} ]] || { print -r -- "STOPP: Prüfkommando fehlt (${${=PRUEF}[1]})"; exit 1; }
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
ok=0; schlecht=0; weg=0
pruefe() { if eval "$2"; then print -r -- "  ok: $1"; (( ok++ )); else print -r -- "  FEHLER: $1"; (( schlecht++ )); print -r -- "$B" | sed 's/^/      /'; fi; }
ueberspringe() { print -r -- "  übersprungen: $1"; (( weg++ )); }
ff() { "$FF" -v error -nostdin -y "$@" || print -r -- "  ffmpeg scheiterte: $*"; }
bericht() { B=$(${=PRUEF} "$1" 2>&1); }
zeilen() { print -r -- "$B" | grep -c "^$1" ; }
# Liegt eine Zeile der Art $1 mit Anfangszeit zwischen $2 und $3 vor?
bei() { print -r -- "$B" | awk -v a="$1" -v v="$2" -v b="$3" '$1 == a { split($2, z, "-"); if (z[1] + 0 >= v && z[1] + 0 <= b) f = 1 } END { exit !f }'; }
# Wie viele KNACKSER-Zeilen liegen binnen 50 ms an einer der genannten Zeiten?
knacksBei() { print -r -- "$B" | awk -v z="$*" 'BEGIN { n = split(z, s, " ") } $1 == "KNACKSER" { for (i = 1; i <= n; i++) if ($2 - s[i] <= 0.05 && s[i] - $2 <= 0.05) { k++; break } } END { print k + 0 }'; }
gesamt() { print -r -- "$B" | sed -nE '1s/.*Gesamt (-?[0-9.]+) LUFS.*/\1/p'; }
mp3() { ff -i "$1" -c:a libmp3lame -b:a 192k "${1:r}.mp3"; }

# „Sprache“ ohne Mikrofon: vier Harmonische auf 150 Hz mit Silbenhüllkurve und leisem Rauschen, rund -20 LUFS.
# Ein Prädiktor sagt das so gut voraus wie einen Vokal; die Knackser-Fälle mit echtem Material stehen weiter unten.
STIMME='(0.55+0.45*sin(2*PI*3.3*t))*(0.16*sin(2*PI*150*t)+0.10*sin(2*PI*300*t+1)+0.07*sin(2*PI*450*t+2)+0.05*sin(2*PI*600*t+3))+0.004*(random(0)-0.5)'
stimme() { ff -f lavfi -i "aevalsrc='$STIMME':s=${3:-44100}:d=$2" -ac ${4:-2} -c:a pcm_s16le "$1"; }   # $1 Datei, $2 Sekunden

print -r -- "Prüfkommando: $PRUEF"
print -r -- "Sauber"
stimme "$T/sauber.wav" 30
bericht "$T/sauber.wav"
pruefe "sauberes Signal (WAV): OK" '[[ $(print -r -- "$B" | sed -n 2p) == OK && $(print -r -- "$B" | wc -l) -eq 2 ]]'
mp3 "$T/sauber.wav"; bericht "$T/sauber.mp3"
pruefe "sauberes Signal (MP3): OK" '[[ $(print -r -- "$B" | sed -n 2p) == OK ]]'
ff -f lavfi -i "sine=f=440:d=20" -af "volume=0.3" -c:a pcm_s16le "$T/ton.wav"
bericht "$T/ton.wav"
pruefe "reiner Ton: OK" '[[ $(print -r -- "$B" | sed -n 2p) == OK ]]'

print -r -- "Lauter und leiser"
stimme "$T/s30.wav" 30
ff -i "$T/s30.wav" -af "volume='if(lt(t,5),2.24,1)':eval=frame" -c:a pcm_s16le "$T/laut7.wav"
bericht "$T/laut7.wav"
pruefe "Anfang +7 dB (5 s): genau eine LAUTER-Zeile am Anfang" '[[ $(zeilen LAUTER) -eq 1 ]] && bei LAUTER 0 1 && print -r -- "$B" | awk "/^LAUTER/ { split(\$2, z, \"-\"); exit !(z[2] >= 3 && z[2] <= 6.5 && \$3 + 0 >= 5.5 && \$3 + 0 <= 8) }"'
ff -i "$T/s30.wav" -af "volume='if(lt(t,5),1.41,1)':eval=frame" -c:a pcm_s16le "$T/laut3.wav"
bericht "$T/laut3.wav"
pruefe "Anfang +3 dB: keine LAUTER-Zeile" '[[ $(zeilen LAUTER) -eq 0 ]]'
ff -i "$T/s30.wav" -af "volume='if(between(t,12,20),0.3,1)':eval=frame" -c:a pcm_s16le "$T/leise.wav"
bericht "$T/leise.wav"
pruefe "Mitte -10,5 dB (8 s): LEISER" '[[ $(zeilen LEISER) -eq 1 ]] && bei LEISER 11 15'
stimme "$T/kurz.wav" 8
ff -i "$T/kurz.wav" -af "volume='if(lt(t,3),2.24,1)':eval=frame" -c:a pcm_s16le "$T/kurzlaut.wav"
bericht "$T/kurzlaut.wav"
pruefe "Datei unter 10 s: keine Lauter-Prüfung" '[[ $(zeilen LAUTER) -eq 0 ]]'

print -r -- "Pausen"
stimme "$T/a.wav" 12; stimme "$T/b.wav" 13
ff -i "$T/a.wav" -af "afade=t=out:st=11.98:d=0.02" "$T/a2.wav"; ff -i "$T/b.wav" -af "afade=t=in:d=0.02" "$T/b2.wav"
for p in 5 3; do
  ff -f lavfi -i "anullsrc=r=44100:cl=stereo:d=$p" -c:a pcm_s16le "$T/still$p.wav"
  ff -i "$T/a2.wav" -i "$T/still$p.wav" -i "$T/b2.wav" -filter_complex "[0][1][2]concat=n=3:v=0:a=1" -c:a pcm_s16le "$T/pause$p.wav"
done
bericht "$T/pause5.wav"
pruefe "Pause 5 s in der Mitte: PAUSE, sonst nichts" '[[ $(zeilen PAUSE) -eq 1 && $(print -r -- "$B" | wc -l) -eq 2 ]] && bei PAUSE 11.5 12.5'
bericht "$T/pause3.wav"
pruefe "Pause 3 s: OK" '[[ $(print -r -- "$B" | sed -n 2p) == OK ]]'
ff -f lavfi -i "anullsrc=r=44100:cl=stereo:d=6" -i "$T/b2.wav" -filter_complex "[0][1]concat=n=2:v=0:a=1" -c:a pcm_s16le "$T/stillanfang.wav"
bericht "$T/stillanfang.wav"
pruefe "6 s Stille am Anfang: PAUSE ab 0" '[[ $(zeilen PAUSE) -eq 1 ]] && bei PAUSE 0 0.1'

print -r -- "Übersteuerung"
ff -i "$T/s30.wav" -af "volume=12dB" -c:a pcm_s16le "$T/kapp.wav"
bericht "$T/kapp.wav"
pruefe "+12 dB hart gekappt (WAV): UEBERSTEUERT" '[[ $(zeilen UEBERSTEUERT) -ge 1 ]]'
# In MP3 zeigt sich Übersteuerung nur, wo der Kodierer überschwingt (Apples Dekoder kappt dann bei 1.0). Bei der
# tieffrequenten Synthetik tut er das nicht, deshalb hier echtes Material.
q1=(${PRUEFMATERIAL:+$PRUEFMATERIAL/*.mp3(N[1])})
if (( $#q1 )); then
  ff -ss 8 -t 20 -i "$q1" -af "volume=12dB" -c:a pcm_s16le "$T/kappecht.wav"; mp3 "$T/kappecht.wav"; bericht "$T/kappecht.mp3"
  pruefe "echtes Material +12 dB hart gekappt (MP3): UEBERSTEUERT" '[[ $(zeilen UEBERSTEUERT) -ge 1 ]]'
else ueberspringe "Übersteuerung in MP3 (braucht PRUEFMATERIAL)"; fi
ff -i "$T/s30.wav" -af "volume=8dB,alimiter=limit=0.9886:level=false:attack=1:release=50" -c:a pcm_s16le "$T/limit.wav"
bericht "$T/limit.wav"
pruefe "Limiter bei -0,1 dBFS (WAV): kein UEBERSTEUERT" '[[ $(zeilen UEBERSTEUERT) -eq 0 ]]'
# Der MP3-Kodierer überschwingt hier, Apples Dekoder kappt das bei 1.0: einzelne Samples genau auf 1.0.
mp3 "$T/limit.wav"; bericht "$T/limit.mp3"
pruefe "Limiter bei -0,1 dBFS (MP3): kein UEBERSTEUERT" '[[ $(zeilen UEBERSTEUERT) -eq 0 ]]'
ff -f lavfi -i "aevalsrc='1.3*sin(2*PI*200*t)':s=44100:d=3" -c:a pcm_f32le "$T/float.wav"
bericht "$T/float.wav"
pruefe "Float-WAV über 0 dBFS: UEBERSTEUERT" '[[ $(zeilen UEBERSTEUERT) -ge 1 ]]'

print -r -- "Aussetzer"
ff -i "$T/s30.wav" -af "aeval='val(ch)*not(between(t,10.003,10.053))':c=same" -c:a pcm_s16le "$T/loch.wav"
bericht "$T/loch.wav"
pruefe "Loch 50 ms mitten im Klang: AUSSETZER, sonst nichts" '[[ $(zeilen AUSSETZER) -eq 1 && $(print -r -- "$B" | wc -l) -eq 2 ]] && bei AUSSETZER 9.99 10.02'

print -r -- "Knackser in Synthetik"
# Impuls (2 Samples, 0,5) bei 7 s und Sprung um 0,25 mit 25 ms Abklingen bei 17 s.
KN="0.5*between(n,308700,308701)+0.25*gte(t,17)*exp(-max(t-17,0)*40)"
ff -i "$T/s30.wav" -f lavfi -i "aevalsrc='$KN':s=44100:d=30" -filter_complex "[0][1]amix=inputs=2:normalize=0:duration=first" -c:a pcm_s16le "$T/knack.wav"
bericht "$T/knack.wav"
pruefe "Impuls und Sprung (WAV): zwei KNACKSER an der richtigen Stelle" '[[ $(zeilen KNACKSER) -eq 2 ]] && bei KNACKSER 6.97 7.03 && bei KNACKSER 16.97 17.03'
mp3 "$T/knack.wav"; bericht "$T/knack.mp3"
# Seit dem Nachbessern am 26.11.2026 ist die Suche vorsichtiger (nur 1 ms breite Impulse, keine Wort-Einsätze): In MP3 geht einer der beiden
# unter, verlangt wird mindestens einer und nichts woanders.
pruefe "Impuls und Sprung (MP3): mindestens ein KNACKSER an der richtigen Stelle, nichts woanders" '(( $(knacksBei 7 17) >= 1 && $(zeilen KNACKSER) - $(knacksBei 7 17) == 0 ))'

print -r -- "Knackser in echtem Material"
quellen=(${PRUEFMATERIAL:+$PRUEFMATERIAL/*.(mp3|wav|m4a|aif|aiff)(N)})
if (( ! $#quellen )); then
  ueberspringe "echtes Material (PRUEFMATERIAL nicht gesetzt oder leer)"
else
  # Je Ausschnitt drei Fehler: Impulse (3 Samples, 0,45) bei 6 und 18 s, ein Sprung um 0,3 bei 12 s. Gemessen
  # erkennt die Prüfung in echter Sprache gut 90 % solcher Knackser in WAV und gut 70 % in MP3; ein Sprung mitten in
  # einem lauten Vokal geht am ehesten unter. Verlangt wurde zuerst: in WAV beide Impulse, in MP3 zwei der drei.
  # Seit dem Nachbessern am 26.11.2026 (null Fehlalarme in 115 echten Dateien, dafür 85 % Treffer in WAV und 54 % in MP3) nur noch je einer
  # Stellen, und nie ein KNACKSER woanders.
  KE="0.45*between(n,264600,264602)+0.45*between(n,793800,793802)+0.3*gte(t,12)*exp(-max(t-12,0)*40)"
  for q in $quellen[1,4]; do
    n=${q:t:r}
    # 30 s ab Sekunde 8: Dort ist bei den Bounces schon Sprache.
    ff -ss 8 -t 30 -i "$q" -ac 2 -ar 44100 -c:a pcm_f32le "$T/m-$n.wav"
    ff -i "$T/m-$n.wav" -f lavfi -i "aevalsrc='$KE':s=44100:d=30" \
      -filter_complex "[0][1]amix=inputs=2:normalize=0:duration=first" -c:a pcm_f32le "$T/mk-$n.wav"
    mp3 "$T/mk-$n.wav"
    bericht "$T/m-$n.wav"
    pruefe "$n unverändert: kein KNACKSER, kein AUSSETZER" '[[ $(zeilen KNACKSER) -eq 0 && $(zeilen AUSSETZER) -eq 0 ]]'
    bericht "$T/mk-$n.wav"
    pruefe "$n mit Knacksern (WAV): mindestens einer der beiden Impulse, nichts woanders" '(( $(knacksBei 6 18) >= 1 && $(zeilen KNACKSER) - $(knacksBei 6 12 18) == 0 ))'
    bericht "$T/mk-$n.mp3"
    pruefe "$n mit Knacksern (MP3): mindestens einer der drei, nichts woanders" '(( $(knacksBei 6 12 18) >= 1 && $(zeilen KNACKSER) - $(knacksBei 6 12 18) == 0 ))'
  done
fi

print -r -- "Lautheit gegen ffmpeg (±0,3 LU)"
ff -f lavfi -i "aevalsrc='$STIMME|0.5*($STIMME)':s=48000:d=20" -c:a pcm_s16le "$T/l48.wav"
ff -f lavfi -i "aevalsrc='$STIMME':s=44100:d=20" -ac 1 -c:a pcm_s16le "$T/lmono.wav"
ff -f lavfi -i "anoisesrc=c=pink:r=44100:a=0.2:d=20" -ac 2 -c:a pcm_s16le "$T/lrauschen.wav"
quellen2=("$T/laut7.wav" "$T/l48.wav" "$T/lmono.wav" "$T/lrauschen.wav" "$T/knack.mp3" ${PRUEFMATERIAL:+$PRUEFMATERIAL/*.mp3(N[1,3])})
for f in $quellen2; do
  soll=$("$FF" -hide_banner -nostats -nostdin -i "$f" -af ebur128 -f null - 2>&1 | grep -A2 "Integrated loudness" | sed -nE 's/.*I: *(-?[0-9.]+) LUFS.*/\1/p')
  bericht "$f"; ist=$(gesamt)
  pruefe "${f:t}: $ist LUFS, ffmpeg $soll LUFS" '[[ -n $ist && -n $soll ]] && (( ist - soll <= 0.3 && soll - ist <= 0.3 ))'
done

print -r -- ""
if (( weg )); then print -r -- "$ok/$(( ok + schlecht )) bestanden, $weg übersprungen"; else print -r -- "$ok/$(( ok + schlecht )) bestanden"; fi
(( schlecht == 0 ))
