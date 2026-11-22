#!/usr/bin/env bash
set -euo pipefail
umask 077
trap 'rm -f ed25519_key.pem' EXIT
printf -- "-----BEGIN ED25519 PRIVATE KEY-----\n%s\n-----END ED25519 PRIVATE KEY-----\n" "$SPARKLE_PRIVATE_KEY" > ed25519_key.pem
OUTPUT=$(dart run auto_updater:sign_update pleazyng-macos.dmg ed25519_key.pem)
# Extract edSignature value from output like: sparkle:edSignature="..." length="..."
SIGNATURE=$(echo "$OUTPUT" | grep -o 'edSignature="[^"]*"' | sed 's/edSignature="//;s/"//')
echo "MACOS_ED_SIGNATURE=$SIGNATURE" >> $GITHUB_ENV
echo "MACOS_DMG_SIZE=$(stat -f%z pleazyng-macos.dmg)" >> $GITHUB_ENV
