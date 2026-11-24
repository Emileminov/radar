#!/bin/bash
# Сборка «Радара» (подпись ad-hoc). ./build.sh install - собрать и поставить в /Applications
set -e
cd "$(dirname "$0")"
APP="build/Radar.app"; rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
SDK="${SDK:-$(xcrun --show-sdk-path 2>/dev/null)}"
swiftc -sdk "$SDK" -O -swift-version 5 -o "$APP/Contents/MacOS/Radar" main.swift
codesign --force -r='designated => identifier "com.emil.radar"' --sign - "$APP"
echo "Готово: $(pwd)/$APP"
if [ "$1" = "install" ]; then
  osascript -e 'tell application id "com.emil.radar" to quit' 2>/dev/null || true; sleep 1
  rm -rf /Applications/Radar.app && ditto "$APP" /Applications/Radar.app && open /Applications/Radar.app
  echo "Установлено в /Applications/Radar.app"
fi
