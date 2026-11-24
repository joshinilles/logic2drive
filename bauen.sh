#!/bin/zsh -f
# Baut Logic2Drive.app für Apple Silicon und Intel, macOS 13 oder neuer.
emulate -R zsh
setopt err_exit no_unset pipe_fail
Q="${0:A:h}"
# Die Versionsnummer steht in VERSION. LOGIC2DRIVE_VERSION und LOGIC2DRIVE_BUILD sind für die Tests da:
# Sie bauen eine andere Version in einen anderen Ordner, ohne build/ anzufassen.
V="${LOGIC2DRIVE_VERSION:-$(<"$Q/VERSION")}"
B="${LOGIC2DRIVE_BUILD:-$Q/build}"
A="$B/Logic2Drive.app"
rm -rf -- "$B"
mkdir -p -- "$A/Contents/MacOS" "$A/Contents/Resources"
print -r -- "let helferVersion = \"$V\"" > "$B/version.swift"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -sdk "$(xcrun --show-sdk-path)" -o "$B/bin-$arch" "$Q/main.swift" "$Q/willkommen.swift" "$Q/zeichen.swift" "$Q/update.swift" "$Q/texte.swift" "$Q/einstellungen.swift" "$B/version.swift"
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
	<key>CFBundleIdentifier</key><string>de.bibletunes.logic2drive</string>
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
# Veröffentlichen: zsh -f bauen.sh --veroeffentlichen notarisiert die App und legt build/Logic2Drive.zip an.
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
fi
print -r -- "OK: $(lipo -archs "$A/Contents/MacOS/Logic2Drive"), $(du -sh "$A" | cut -f1), Signatur: $SIG"
