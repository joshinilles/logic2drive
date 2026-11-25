#!/bin/zsh -f
# Baut Logic2Drive.app für Apple Silicon und Intel, macOS 13 oder neuer.
emulate -R zsh
setopt err_exit no_unset pipe_fail
Q="${0:A:h}"
# Die Versionsnummer steht in VERSION. LOGIC2DRIVE_VERSION und LOGIC2DRIVE_BUILD sind für die Tests da:
# Sie bauen eine andere Version in einen anderen Ordner, ohne build/ anzufassen.
V="${LOGIC2DRIVE_VERSION:-$(<"$Q/VERSION")}"
B="${LOGIC2DRIVE_BUILD:-$Q/build}"
# LOGIC2DRIVE_KENNUNG ist nur für Tests der Oberfläche da: Eine Testversion mit der echten Kennung teilt sich
# Einstellungen und Autostart mit der installierten App.
K="${LOGIC2DRIVE_KENNUNG:-de.bibletunes.logic2drive}"
A="$B/Logic2Drive.app"
rm -rf -- "$B"
mkdir -p -- "$A/Contents/MacOS" "$A/Contents/Resources"
print -r -- "let helferVersion = \"$V\"" > "$B/version.swift"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -sdk "$(xcrun --show-sdk-path)" -o "$B/bin-$arch" "$Q/main.swift" "$Q/willkommen.swift" "$Q/zeichen.swift" "$Q/update.swift" "$Q/texte.swift" "$Q/einstellungen.swift" "$Q/varispeed.swift" "$B/version.swift"
done
lipo -create -output "$A/Contents/MacOS/Logic2Drive" "$B/bin-arm64" "$B/bin-x86_64"
rm -f -- "$B/bin-arm64" "$B/bin-x86_64" "$B/version.swift"
cp -- "$Q/NEUES.json" "$A/Contents/Resources/"      # „Was ist neu“ im Einstellungsfenster
# Übersetzungen. Die deutschen Texte der App stehen im Quelltext, de.lproj enthält nur, was macOS selbst
# anzeigt (InfoPlist.strings), und sagt macOS, dass die App Deutsch kann.
mkdir -p -- "$A/Contents/Resources/de.lproj"
for l in "$Q"/sprachen/*.lproj(N); do cp -R -- "$l" "$A/Contents/Resources/"; done
# Das App-Symbol zeichnet der Helfer selbst (zeichen.swift), iconutil macht daraus die .icns-Datei.
LOGIC2DRIVE_DATEN="$B/symbol-daten" "$A/Contents/MacOS/Logic2Drive" --app-symbol "$B/AppIcon.iconset"
iconutil -c icns -o "$A/Contents/Resources/AppIcon.icns" "$B/AppIcon.iconset"
rm -rf -- "$B/AppIcon.iconset" "$B/symbol-daten"
cat > "$A/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Logic2Drive</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$K</string>
	<key>CFBundleName</key><string>Logic2Drive</string>
	<key>CFBundleDisplayName</key><string>Logic2Drive</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$V</string>
	<key>CFBundleVersion</key><string>$V</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key>
	<array><string>de</string><string>en</string><string>fr</string><string>ar</string><string>fa</string></array>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>© 2026 bibletunes gGmbH</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppleEventsUsageDescription</key><string>Logic2Drive asks Logic Pro which projects are open, so that a project is only put back into Google Drive after you have closed it.</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>Logic-Projekt als Zip</string>
			<key>CFBundleTypeRole</key><string>Editor</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array><string>public.zip-archive</string></array>
		</dict>
	</array>
</dict>
</plist>
EOF
plutil -lint -s "$A/Contents/Info.plist"
# Signieren: mit einer Developer ID, wenn eine im Schlüsselbund liegt, sonst ad hoc.
# LOGIC2DRIVE_SIGNATUR wählt eine bestimmte Identität, "-" erzwingt ad hoc.
SIG="${LOGIC2DRIVE_SIGNATUR:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -n $SIG && $SIG != "-" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$Q/rechte.plist" --sign "$SIG" "$A"
else
  SIG="-"
  codesign --force --deep --sign - "$A"
fi
codesign --verify --deep --strict "$A"
# Die Installationsdatei: ein DMG mit dem klassischen Fenster, App links, Ordner „Programme“ rechts.
# Symbole und Hintergrund richtet der Finder ein (dazu geht dort kurz ein Fenster oder Tab auf). Größe und
# Aussehen des Fensters trägt dmg-fenster.py selbst ein: Der Finder schriebe sonst den Zustand des Fensters
# hinein, in dem er das Volume gerade zeigt, bei „Tabs bevorzugen: immer“ also ein fremdes samt Seitenleiste.
# Die Maße stehen auch in zeichen.swift (dmgBreite, dmgLinks …).
baue_dmg() {
  local ziel="$1" W="$B/dmg" name="Logic2Drive"
  [[ ! -e /Volumes/$name ]] || { print -r -- "Ein Volume „$name“ ist eingehängt. Bitte erst auswerfen."; exit 1 }
  rm -rf -- "$W"; mkdir -p -- "$W/inhalt/.hintergrund" "$W/einhang"
  ditto "$A" "$W/inhalt/Logic2Drive.app"
  ln -s /Applications "$W/inhalt/Applications"
  LOGIC2DRIVE_DATEN="$B/symbol-daten" "$A/Contents/MacOS/Logic2Drive" --dmg-bild "$W"
  tiffutil -cathidpicheck "$W/dmg-1x.png" "$W/dmg-2x.png" -out "$W/inhalt/.hintergrund/hintergrund.tiff" >/dev/null
  rm -rf -- "$B/symbol-daten"
  hdiutil create -quiet -volname "$name" -srcfolder "$W/inhalt" -fs HFS+ -format UDRW "$W/roh.dmg"
  hdiutil attach "$W/roh.dmg" -readwrite -noverify -noautoopen >/dev/null 2>&1
  osascript <<SKRIPT >/dev/null
tell application "Finder"
  tell disk "$name"
    open
    set f to container window
    set current view of f to icon view
    set optionen to icon view options of f
    set arrangement of optionen to not arranged
    set icon size of optionen to 112
    set text size of optionen to 13
    set background picture of optionen to file ".hintergrund:hintergrund.tiff"
    set position of item "Logic2Drive.app" to {165, 205}
    set position of item "Applications" to {435, 205}
    update without registering applications
    delay 2
    close f
  end tell
end tell
SKRIPT
  sync; sleep 1
  cp "/Volumes/$name/.DS_Store" "$W/DS_Store"
  hdiutil detach "/Volumes/$name" -quiet 2>/dev/null
  python3 "$Q/dmg-fenster.py" "$W/DS_Store" 600 428 Logic2Drive.app Applications
  # Die geprüfte Datei kommt am Finder vorbei zurück: Beim Auswerfen schreibt er sie mitunter mit dem Zustand
  # eines früheren Fensters neu (gemessen 25.11.2026, dabei gingen Hintergrund und Symbolgröße verloren).
  hdiutil attach "$W/roh.dmg" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$W/einhang" >/dev/null 2>&1
  cp "$W/DS_Store" "$W/einhang/.DS_Store"
  rm -rf -- "$W/einhang/.fseventsd"
  sync
  hdiutil detach "$W/einhang" -quiet 2>/dev/null
  rm -f -- "$ziel"
  hdiutil convert "$W/roh.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$ziel" 2>/dev/null
  # Gegenprobe am fertigen Image
  hdiutil attach "$ziel" -noverify -noautoopen -nobrowse -mountpoint "$W/einhang" >/dev/null 2>&1
  cmp -s "$W/DS_Store" "$W/einhang/.DS_Store" || { hdiutil detach "$W/einhang" -quiet; print -r -- "Die Fensterangaben im DMG stimmen nicht."; exit 1 }
  codesign --verify --deep --strict "$W/einhang/Logic2Drive.app"
  hdiutil detach "$W/einhang" -quiet 2>/dev/null
  rm -rf -- "$W"
}
# zsh -f bauen.sh --dmg legt build/Logic2Drive.dmg an, ohne Notarisierung: zum Ansehen des Installationsfensters.
if [[ ${1:-} == --dmg ]]; then
  baue_dmg "$B/Logic2Drive.dmg"
fi
# Veröffentlichen: zsh -f bauen.sh --veroeffentlichen notarisiert die App und legt build/Logic2Drive.zip
# (für den Updater) und build/Logic2Drive.dmg (zum Installieren) an.
# Der Zugang liegt als Profil im Schlüsselbund (xcrun notarytool store-credentials logic-helfer-notar …).
if [[ ${1:-} == --veroeffentlichen ]]; then
  [[ $SIG != "-" ]] || { print -r -- "Ohne Developer ID lässt sich nichts veröffentlichen."; exit 1 }
  Z="$B/Logic2Drive.zip"
  ditto -c -k --sequesterRsrc --keepParent "$A" "$Z"
  xcrun notarytool submit "$Z" --keychain-profile "${LOGIC2DRIVE_NOTAR:-logic-helfer-notar}" --wait
  xcrun stapler staple "$A"
  rm -f -- "$Z"
  ditto -c -k --sequesterRsrc --keepParent "$A" "$Z"      # noch einmal packen, jetzt mit dem Ticket von Apple
  spctl -a -vv "$A"
  # Das DMG enthält die App mit Ticket und bekommt selbst Signatur und Ticket, damit schon das Öffnen ohne Warnung geht.
  D="$B/Logic2Drive.dmg"
  baue_dmg "$D"
  codesign --force --timestamp --sign "$SIG" "$D"
  xcrun notarytool submit "$D" --keychain-profile "${LOGIC2DRIVE_NOTAR:-logic-helfer-notar}" --wait
  xcrun stapler staple "$D"
  spctl -a -vv -t open --context context:primary-signature "$D"
fi
print -r -- "OK: $(lipo -archs "$A/Contents/MacOS/Logic2Drive"), $(du -sh "$A" | cut -f1), Signatur: $SIG"
