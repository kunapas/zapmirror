#!/usr/bin/env bash
# Downloads what Scripts/build-phone.sh needs, from Google, about 82 MB, and checks the SHA-1 sums Google publishes
# plus our own SHA-256 of the same files:
#   platform-35_r02.zip   Android 15's API library (android.jar), to compile against
#   r8-8.7.18.jar         d8, which turns Java classes into Android's dex format
set -euo pipefail
source "$(dirname "$0")/config.sh"

downloads="$ANDROID_TOOLS_DIR/downloads"
mkdir -p "$downloads"

fetch() { # url sha1 file sha256
  local file="$downloads/$3"
  if [[ ! -f "$file" ]] || [[ "$(shasum "$file" | cut -d' ' -f1)" != "$2" ]]; then
    echo "==> downloading $1"
    curl -fSL --progress-bar "$1" -o "$file.part"
    mv "$file.part" "$file"
  fi
  local sum
  sum="$(shasum "$file" | cut -d' ' -f1)"
  [[ "$sum" == "$2" ]] || { echo "$3: SHA-1 is $sum, expected $2" >&2; rm -f "$file"; exit 1; }
  sum="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  [[ "$sum" == "$4" ]] || { echo "$3: SHA-256 is $sum, expected $4" >&2; rm -f "$file"; exit 1; }
}

fetch https://dl.google.com/android/repository/platform-35_r02.zip \
  0bb560a90a7a2cbd0dd8348224d518b638fe7949 platform-35_r02.zip \
  0988cacad01b38a18a47bac14a0695f246bc76c1b06c0eeb8eb0dc825ab0c8e0
fetch https://dl.google.com/dl/android/maven2/com/android/tools/r8/8.7.18/r8-8.7.18.jar \
  c005831622e05397a450d640a016ab66c0c64342 r8-8.7.18.jar \
  58366f77067207c39a17d469de7b05701d2877212a9c55201bcb0af43e59e903

mkdir -p "$(dirname "$ANDROID_JAR")"
unzip -o -q -j "$downloads/platform-35_r02.zip" android-35/android.jar -d "$(dirname "$ANDROID_JAR")"
cp "$downloads/r8-8.7.18.jar" "$R8_JAR"
echo "Android build tools ready in $ANDROID_TOOLS_DIR"
