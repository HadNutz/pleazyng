#!/usr/bin/env bash
set -euo pipefail
mkdir -p dmg-staging
cp -R build/macos/Build/Products/Release/Pleazyng.app dmg-staging/
ln -s /Applications dmg-staging/Applications
hdiutil create -format ULMO -srcfolder dmg-staging -volname "Pleazyng" pleazyng-macos.dmg
