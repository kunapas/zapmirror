#!/usr/bin/env bash
# Single place for names and versions.
# shellcheck disable=SC2034

APP_NAME="Zapmirror"
BUNDLE_ID="${ZAPMIRROR_BUNDLE_ID:-app.zapmirror.Zapmirror}"   # change before publishing (needs the domain)
APP_VERSION="1.0.0"
APP_BUILD="1"
MIN_MACOS="14.0"

# Optional "Buy Me a Coffee" link shown in the app menu and on the Connect page. Zapmirror is free; this is only
# for people who want to support the work. Must start with https://. Empty hides it.
SUPPORT_URL="${ZAPMIRROR_SUPPORT_URL-https://buymeacoffee.com/sr48}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

# Building the phone component (Phone/) needs Android's API library and Google's d8. Scripts/fetch-android-tools.sh
# downloads both, checksum-verified, into this folder (outside the repository).
ANDROID_TOOLS_DIR="${ZAPMIRROR_ANDROID_TOOLS:-$HOME/Library/Caches/Zapmirror-build}"
ANDROID_JAR="$ANDROID_TOOLS_DIR/android-35/android.jar"
R8_JAR="$ANDROID_TOOLS_DIR/r8-8.7.18.jar"
