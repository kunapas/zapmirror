#!/usr/bin/env bash
# Builds Zapmirror's phone component (Phone/src) into .build/phone/zapmirror-phone.jar: Java compiled against
# android.jar, then converted to dex with d8. Needs a JDK (11 or later; the classes target Java 8, the newest javac allows with a custom boot class path) and Scripts/fetch-android-tools.sh.
set -euo pipefail
source "$(dirname "$0")/config.sh"

for file in "$ANDROID_JAR" "$R8_JAR"; do
  [[ -f "$file" ]] || { echo "Missing $file: run Scripts/fetch-android-tools.sh first." >&2; exit 1; }
done

# Build in a local temporary folder: javac and d8 are happier off the network share.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/classes"
# Quoted: the repository path may contain spaces.
find "$ROOT_DIR/Phone/src" -name '*.java' | sed 's/.*/"&"/' > "$work/sources"
javac -source 8 -target 8 -Xlint:-options -encoding UTF-8 -bootclasspath "$ANDROID_JAR" \
  -d "$work/classes" @"$work/sources"
find "$work/classes" -name '*.class' > "$work/classlist"
java -cp "$R8_JAR" com.android.tools.r8.D8 --release --min-api 30 --lib "$ANDROID_JAR" \
  --output "$work/zapmirror-phone.jar" @"$work/classlist"

mkdir -p "$ROOT_DIR/.build/phone"
cp "$work/zapmirror-phone.jar" "$ROOT_DIR/.build/phone/zapmirror-phone.jar"
# The app installs only the jar whose hash is compiled into it (PhoneServer.sha256).
hash="$(shasum -a 256 "$ROOT_DIR/.build/phone/zapmirror-phone.jar" | cut -d' ' -f1)"
swift_file="$ROOT_DIR/Sources/ZapmirrorPhone/PhoneServer.swift"
if ! grep -q "sha256 = \"$hash\"" "$swift_file"; then
  if [[ "${ZAPMIRROR_UPDATE_PHONE_HASH:-0}" == "1" ]]; then
    sed -i '' -E "s/(sha256 = \")[0-9a-f]{64}/\\1$hash/" "$swift_file"
    echo "Updated PhoneServer.sha256 to $hash"
  else
    echo "The phone component changed (or was built with a different JDK): its SHA-256 is now" >&2
    echo "  $hash" >&2
    echo "Run ZAPMIRROR_UPDATE_PHONE_HASH=1 Scripts/build-phone.sh to record it in PhoneServer.swift, then rebuild." >&2
    exit 1
  fi
fi
echo "Built .build/phone/zapmirror-phone.jar ($(wc -c < "$ROOT_DIR/.build/phone/zapmirror-phone.jar" | tr -d ' ') bytes)"
