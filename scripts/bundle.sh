#!/bin/zsh
# Build Keybinds.app: swift build → bundle layout → icon → codesign with the stable dev identity.
# Usage: scripts/bundle.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
RUN=false
for arg in "$@"; do
  case $arg in
    debug|release) CONFIG=$arg ;;
    --run) RUN=true ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

IDENTITY="Keybinds Dev"
APP=build/Keybinds.app

if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Signing identity \"$IDENTITY\" not found. Run scripts/make-dev-cert.sh once." >&2
  exit 1
fi

swift build -c "$CONFIG" --product Keybinds
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Keybinds"

# Icon: rendered from assets/icon.svg once, then cached.
ICNS=build/AppIcon.icns
if [[ ! -f $ICNS || assets/icon.svg -nt $ICNS ]]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -s format png -z $size $size assets/icon.svg --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z $((size * 2)) $((size * 2)) assets/icon.svg --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
fi

if $RUN; then pkill -x Keybinds 2>/dev/null || true; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keybinds"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Same identity every build → same designated requirement → macOS keeps the Accessibility grant.
codesign --force --sign "$IDENTITY" --entitlements Resources/Keybinds.entitlements "$APP"
echo "Built $APP ($CONFIG)"

if $RUN; then open "$APP"; fi
