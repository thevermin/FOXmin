#!/bin/bash
# Compila FOXmin y arma FOXmin.app en ./build
#   ./build.sh          compila la app
#   ./build.sh --zip    además arma build/FOXmin-<versión>.zip para GitHub Releases
#                       (exige la firma con el certificado fijo: un release nunca sale firmado ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FOXmin.app"

# Firma: el certificado fijo de thevermin (el mismo de VRmin) si está en el llavero de esta Mac.
# Con la misma firma, macOS no vuelve a pedir el permiso de Accesibilidad al actualizar.
# Se puede elegir otro con SIGN_IDENTITY="Nombre del certificado" ./build.sh
CERT="${SIGN_IDENTITY:-QuestVRBridge Local}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT\""; then
  IDENTITY="$CERT"
else
  IDENTITY="-"
fi
if [ "${1:-}" = "--zip" ] && [ "$IDENTITY" = "-" ]; then
  echo "Error: para armar el zip de un release hace falta el certificado \"$CERT\" en el llavero." >&2
  exit 1
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FOXmin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FOXmin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/MenuBarIcon*.png "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Ícono de la app (.icns) armado desde Resources/AppIcon.png
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "Aviso: no se pudo armar el ícono"

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
if [ "$IDENTITY" = "-" ]; then
  echo "Firma: ad-hoc (no se encontró el certificado \"$CERT\")"
else
  # Se guarda la salida antes de buscar: con «| grep -q» y pipefail, codesign puede cortarse a mitad
  # de la salida y el chequeo falla aunque la firma esté bien.
  INFO=$(codesign -dvv "$APP" 2>&1)
  if ! grep -q "Authority=$IDENTITY" <<<"$INFO"; then
    echo "Error: falló la firma con \"$IDENTITY\"" >&2
    grep "Authority" <<<"$INFO" >&2 || true
    exit 1
  fi
  echo "Firma: $IDENTITY"
fi

if [ "${1:-}" = "--zip" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  ZIP="build/FOXmin-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Zip: $ZIP"
fi

echo "Listo: $APP"
echo "Para instalarla: cp -R \"$APP\" /Applications/ && open /Applications/FOXmin.app"
