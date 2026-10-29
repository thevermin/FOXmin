#!/bin/bash
# Compila FOXmin y arma FOXmin.app en ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FOXmin.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FOXmin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FOXmin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/MenuBarIcon*.png "$APP/Contents/Resources/"

# Ícono de la app (.icns) armado desde Resources/AppIcon.png
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "Aviso: no se pudo armar el ícono"

# Firma ad-hoc por defecto. Para no tener que volver a dar el permiso de Accesibilidad
# en cada build, firmá con un certificado fijo: SIGN_IDENTITY="Mi Certificado" ./build.sh
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

# --zip: deja también el .zip listo para subir a GitHub Releases
if [ "${1:-}" = "--zip" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  ditto -c -k --keepParent "$APP" "build/FOXmin-$VERSION.zip"
  echo "Zip: build/FOXmin-$VERSION.zip"
fi

echo "Listo: $APP"
echo "Para instalarla: cp -R \"$APP\" /Applications/ && open /Applications/FOXmin.app"
