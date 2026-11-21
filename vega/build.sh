#!/usr/bin/env bash
# Build the experimental direct-play client using the installed Vega 2 SDK.
set -euo pipefail
if [[ $# != 1 || -e $1 || -L $1 ]]; then
  echo 'Usage: vega/build.sh NEW_OUTPUT_DIRECTORY' >&2
  exit 2
fi
output=$(realpath -m -- "$1")
src=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/web" "$work/packages"
cp "$src"/{package.json,package-lock.json} "$work/web/"
cp -r "$src/web" "$work/web/"
(cd "$work/web" && npm ci && npm run bundle)
vega project generate --template vegaWebview --name PleazyngMotion \
  --packageId org.snapetech.pleazyng.motionpreview --outputDir "$work/project"
cp "$src/App.tsx" "$work/project/src/App.tsx"
cp "$work/web/web/"{index.html,bundle.js} "$work/project/assets/"
cp "$work/web/node_modules/mediabunny/LICENSE" "$work/project/assets/Mediabunny-LICENSE.txt"
cp "$src/third-party.html" "$work/project/assets/"
python3 - "$src/../pubspec.yaml" "$work/project/manifest.toml" <<'PY'
import re
import sys
from pathlib import Path
version = re.search(r"^version: (\d+\.\d+\.\d+)\+(\d+)$", Path(sys.argv[1]).read_text(), re.M)
if not version:
    raise SystemExit("Missing application version")
manifest = Path(sys.argv[2])
text = manifest.read_text()
for key, replacement in [('title', '"Pleazyng Motion Preview"'), ('version', f'"{version[1]}"'), ('build-number', version[2])]:
    text, count = re.subn(rf'^{key} = [^\n]+$', f'{key} = {replacement}', text, flags=re.M)
    if count != 1:
        raise SystemExit(f"Unexpected Vega manifest field {key}")
manifest.write_text(text)
PY
(cd "$work/project" && npm install && npm run build:release)
for arch in aarch64 armv7 x86_64; do
  files=("$work/project/build/$arch-release/"*.vpkg)
  [[ ${#files[@]} == 1 && -s ${files[0]} ]]
  cp -- "${files[0]}" "$work/packages/pleazyng-motion-$arch.vpkg"
done
mkdir -p -- "$(dirname -- "$output")"
mkdir -- "$output"
cp "$work/packages/"*.vpkg "$output/"
(cd "$output" && sha256sum -- *.vpkg > SHA256SUMS)
