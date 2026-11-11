#!/usr/bin/env bash
# Builds a universal Zapmirror.app with SwiftPM: the Command Line Tools are enough (no Xcode needed).
#   Scripts/build-app.sh                       ad-hoc signed app in dist/ (runs on this Mac)
#   ZAPMIRROR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/build-app.sh   release signing
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$ROOT_DIR"

IDENTITY="${ZAPMIRROR_SIGN_IDENTITY:--}"
APP="$DIST_DIR/$APP_NAME.app"
ARCHS="${ZAPMIRROR_ARCHS:-arm64 x86_64}"

binaries=()
for arch in $ARCHS; do
  echo "==> swift build ($arch)"
  swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" --product ZapmirrorApp
  binaries+=("$ROOT_DIR/.build/$arch-apple-macosx/release/ZapmirrorApp")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(MARKETING_VERSION)/$APP_VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$APP_BUILD/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/g" \
    -e "s|\$(ZAPMIRROR_SUPPORT_URL)|${SUPPORT_URL//&/\\&amp;}|g" \
    "$ROOT_DIR/App/Support/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp "$ROOT_DIR/App/Zapmirror/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" # made by Scripts/make-icon.sh
# The phone side of mirroring (Phone/), which the app installs on the phone for each session.
"$ROOT_DIR/Scripts/build-phone.sh"
cp "$ROOT_DIR/.build/phone/zapmirror-phone.jar" "$APP/Contents/Resources/zapmirror-phone.jar"

signing=(--options runtime --timestamp)
[[ "$IDENTITY" == "-" ]] && signing=(--options runtime --timestamp=none)
codesign --force "${signing[@]}" --entitlements "$ROOT_DIR/App/Support/Zapmirror.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP"
if [[ "$IDENTITY" == "-" ]]; then echo "Ad-hoc signed: fine on this Mac."; fi
