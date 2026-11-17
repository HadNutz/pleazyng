#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
IPK_DIR="$ROOT/build/webos/arm/release/ipk"

: "${FLUTTER_WEBOS_SDK_ROOT:?Set this to the pinned, patched flutter-webos checkout}"
: "${WEBOS_ENGINE_LOCAL_PATH:?Set this to the pinned webos-arm-release.zip}"
: "${WEBOS_NDK_ROOT:?Set this to the pinned LG webOS 26 NDK root}"
: "${PLEZY_WEBOS_VISUALIZER_NATIVE:?Release IPKs must include the pinned MilkRust runtime bundle}"
: "${PLEZY_WEBOS_VISUALIZER_MANIFEST_SHA256:?Release IPKs must pin the generated MilkRust manifest digest}"
: "${WEBOS_PYTHON_BIN:=python3}"
export WEBOS_PYTHON_BIN

PLEZY_WEBOS_BILLING_MODE="${PLEZY_WEBOS_BILLING_MODE:-tester}"
LG_PAYMENTWALL_ENABLED=false
billing_defines=()
case "$PLEZY_WEBOS_BILLING_MODE" in
  tester)
    if [[ -n "${LG_PAYMENTWALL_API_ORIGIN:-}" || -n "${LG_PAYMENTWALL_GRANT_PUBLIC_KEY:-}" ]]; then
      echo "Tester webOS builds cannot receive Paymentwall configuration." >&2
      exit 1
    fi
    SUPPORTER_MODE=off
    PLEZY_WEBOS_BILLING_API_ORIGIN=""
    PLEZY_WEBOS_BILLING_PUBLIC_KEY_SHA256=""
    ;;
  paid)
    : "${LG_PAYMENTWALL_API_ORIGIN:?Paid LG builds require LG_PAYMENTWALL_API_ORIGIN}"
    : "${LG_PAYMENTWALL_GRANT_PUBLIC_KEY:?Paid LG builds require LG_PAYMENTWALL_GRANT_PUBLIC_KEY}"
    if [[ "$LG_PAYMENTWALL_API_ORIGIN" != "https://billing.pleazyng.app" ]]; then
      echo "Paid LG builds must use the fixed dedicated billing origin." >&2
      exit 1
    fi
    SUPPORTER_MODE=iap
    LG_PAYMENTWALL_ENABLED=true
    PLEZY_WEBOS_BILLING_API_ORIGIN="$LG_PAYMENTWALL_API_ORIGIN"
    PLEZY_WEBOS_BILLING_PUBLIC_KEY_SHA256="$(LG_PAYMENTWALL_GRANT_PUBLIC_KEY="$LG_PAYMENTWALL_GRANT_PUBLIC_KEY" "$WEBOS_PYTHON_BIN" - <<'PYKEY'
import base64
import hashlib
import os
import re
import sys

text = os.environ["LG_PAYMENTWALL_GRANT_PUBLIC_KEY"]
if not re.fullmatch(r"[A-Za-z0-9_-]{43}", text):
    raise SystemExit("LG grant public key must be unpadded base64url for exactly 32 bytes")
try:
    raw = base64.urlsafe_b64decode(text + "=")
except ValueError as error:
    raise SystemExit("LG grant public key is invalid base64url") from error
if len(raw) != 32 or base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != text:
    raise SystemExit("LG grant public key is not the canonical encoding of 32 bytes")
print(hashlib.sha256(raw).hexdigest())
PYKEY
)"
    billing_defines=(
      "--dart-define=LG_PAYMENTWALL_API_ORIGIN=$LG_PAYMENTWALL_API_ORIGIN"
      "--dart-define=LG_PAYMENTWALL_GRANT_PUBLIC_KEY=$LG_PAYMENTWALL_GRANT_PUBLIC_KEY"
    )
    ;;
  *)
    echo "PLEZY_WEBOS_BILLING_MODE must be tester or paid." >&2
    exit 1
    ;;
esac
export PLEZY_WEBOS_BILLING_MODE PLEZY_WEBOS_BILLING_API_ORIGIN PLEZY_WEBOS_BILLING_PUBLIC_KEY_SHA256

if [[ -n "${PLEZY_WEBOS_VISUALIZER_NATIVE:-}" || -n "${PLEZY_WEBOS_VISUALIZER_MANIFEST_SHA256:-}" ]]; then
  if [[ -z "${PLEZY_WEBOS_VISUALIZER_NATIVE:-}" || -z "${PLEZY_WEBOS_VISUALIZER_MANIFEST_SHA256:-}" ]]; then
    echo "Set both PLEZY_WEBOS_VISUALIZER_NATIVE and PLEZY_WEBOS_VISUALIZER_MANIFEST_SHA256." >&2
    exit 1
  fi
  if [[ "$PLEZY_WEBOS_VISUALIZER_NATIVE" != /* || -L "$PLEZY_WEBOS_VISUALIZER_NATIVE" || ! -d "$PLEZY_WEBOS_VISUALIZER_NATIVE" ]]; then
    echo "The reviewed MilkRust artifact directory must be an absolute, regular directory." >&2
    exit 1
  fi
  if [[ ! "$PLEZY_WEBOS_VISUALIZER_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "The MilkRust manifest digest must be lowercase SHA-256." >&2
    exit 1
  fi
  export PLEZY_WEBOS_VISUALIZER_NATIVE PLEZY_WEBOS_VISUALIZER_MANIFEST_SHA256
fi

SDK_ROOT="$(cd -- "$FLUTTER_WEBOS_SDK_ROOT" && pwd)"
NDK_ROOT="$(cd -- "$WEBOS_NDK_ROOT" && pwd)"
ENGINE_ARCHIVE="$(cd -- "$(dirname -- "$WEBOS_ENGINE_LOCAL_PATH")" && pwd)/$(basename -- "$WEBOS_ENGINE_LOCAL_PATH")"
COMMON_ARCHIVE="$(dirname -- "$ENGINE_ARCHIVE")/webos-common.zip"

for path in "$FLUTTER_WEBOS_SDK_ROOT" "$WEBOS_NDK_ROOT"; do
  if [[ -L "$path" ]]; then
    echo "Pinned toolchain roots must not be symbolic links: $path" >&2
    exit 1
  fi
done

# Never let a stale, linked, or redirected output be mistaken for the result
# of this invocation. Keep old candidates intact and require a fresh output.
for output_path in \
  "$ROOT/build" \
  "$ROOT/build/webos" \
  "$ROOT/build/webos/arm" \
  "$ROOT/build/webos/arm/release" \
  "$IPK_DIR"; do
  if [[ -L "$output_path" ]]; then
    echo "Refusing to build through a symbolic-link output path: $output_path" >&2
    exit 1
  fi
done
shopt -s nullglob
EXISTING_IPKS=("$IPK_DIR"/org.snapetech.pleazyng_*_arm.ipk)
if (( ${#EXISTING_IPKS[@]} != 0 )); then
  echo "Refusing to reuse existing webOS IPKs; use a clean build output tree: ${EXISTING_IPKS[*]}" >&2
  exit 1
fi

"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/verify_package.py" --project-metadata
"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/verify_sdk_checkout.py" "$SDK_ROOT"
"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/ndk_environment.py" --root "$NDK_ROOT" --verify
# Build before sourcing LG's target environment: the recipe creates its own
# compiler wrappers and also runs native host tools.
export PLEAZYNG_TV_MPV_DIR="$ROOT/build/tv-mpv-webos"
"$WEBOS_PYTHON_BIN" "$ROOT/scripts/tv_mpv/build.py" webos armv7l "$PLEAZYNG_TV_MPV_DIR" --webos-ndk "$NDK_ROOT"
NDK_ENVIRONMENT="$(mktemp "${TMPDIR:-/tmp}/pleazyng-webos-ndk-env.XXXXXX")"
trap 'rm -f -- "$NDK_ENVIRONMENT"' EXIT
"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/ndk_environment.py" --root "$NDK_ROOT" --emit-shell > "$NDK_ENVIRONMENT"
source "$ROOT/tools/webos/source_ndk_environment.sh"
pleazyng_source_ndk_environment "$NDK_ENVIRONMENT"
rm -f -- "$NDK_ENVIRONMENT"
trap - EXIT
if [[ "${SDKTARGETSYSROOT:-}" != "$NDK_ROOT/sysroots/ca9v1-webosmllib32-linux-gnueabi" ]]; then
  echo "The verified webOS NDK environment did not load the expected target sysroot." >&2
  exit 1
fi

PACKAGER="$ROOT/tools/webos/bin/ares-package"
if [[ ! -x "$PACKAGER" ]]; then
  echo "The checked-in webOS IPK packager is not executable: $PACKAGER" >&2
  exit 1
fi
if ! "$WEBOS_PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo "The webOS IPK packager requires Python 3.10 or newer." >&2
  exit 1
fi
PACKAGER_VERSION="$("$PACKAGER" --version)"
if [[ "$PACKAGER_VERSION" != "pleazyng-ipk-packager 2" ]]; then
  echo "The webOS IPK packager version is not pinned to version 2." >&2
  exit 1
fi
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

export PATH="$ROOT/tools/webos/bin:$SDK_ROOT/bin:$SDK_ROOT/flutter/bin:$PATH"
export FLUTTER_GIT_URL="https://github.com/lg-flutter-webos/flutter-webos.git"
export WEBOS_ENGINE_LOCAL_PATH="$ENGINE_ARCHIVE"

"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/verify_package.py" \
  --engine-archive "$ENGINE_ARCHIVE" \
  --common-archive "$COMMON_ARCHIVE"

LOCK_BEFORE="$(sha256sum "$ROOT/pubspec.lock" | cut -d' ' -f1)"
# Prepare the webOS plugin registrant with the same locked dependency fetch.
# A second, implicit pub get during build can reserialize pubspec.lock even
# when the dependency graph is unchanged; build must consume these exact inputs.
flutter-webos pub get --enforce-lockfile --no-example
LOCK_AFTER="$(sha256sum "$ROOT/pubspec.lock" | cut -d' ' -f1)"
if [[ "$LOCK_BEFORE" != "$LOCK_AFTER" ]]; then
  echo "flutter pub get changed pubspec.lock despite --enforce-lockfile." >&2
  exit 1
fi

GIT_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [[ ! "$GIT_COMMIT" =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "The WebOS package source commit must be a full hexadecimal Git object ID." >&2
  exit 1
fi
flutter-webos build webos \
  --no-pub \
  --release \
  --target-arch arm \
  --target-backend-type wayland \
  --dart-define=PLEZY_WEBOS=true \
  --dart-define="SUPPORTER_MODE=$SUPPORTER_MODE" \
  --dart-define="LG_PAYMENTWALL_ENABLED=$LG_PAYMENTWALL_ENABLED" \
  --dart-define=ENABLE_UPDATE_CHECK=true \
  --dart-define="GIT_COMMIT=$GIT_COMMIT" \
  "${billing_defines[@]}"

if ! git -C "$ROOT" diff --quiet -- webos/flutter/main.dart pubspec.lock; then
  git -C "$ROOT" diff -- webos/flutter/main.dart pubspec.lock >&2
  echo "The webOS build changed tracked generated or dependency files." >&2
  exit 1
fi

IPKS=("$IPK_DIR"/org.snapetech.pleazyng_*_arm.ipk)
if (( ${#IPKS[@]} != 1 )); then
  echo "Expected one versioned Pleazyng ARM IPK; found ${#IPKS[@]}." >&2
  exit 1
fi
if [[ -L "${IPKS[0]}" || ! -f "${IPKS[0]}" ]]; then
  echo "The webOS build output must be a regular, non-symlink IPK: ${IPKS[0]}" >&2
  exit 1
fi

PACKAGE_REPORT="$("$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/verify_package.py" --ipk "${IPKS[0]}")"
PLEZY_WEBOS_VERIFICATION_REPORT="$PACKAGE_REPORT" "$WEBOS_PYTHON_BIN" - "$IPK_DIR" "${IPKS[0]}" "$GIT_COMMIT" <<'PYPROVENANCE'
import json
import os
import pathlib
import sys
import tempfile

output_dir, ipk, commit = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
report = json.loads(os.environ["PLEZY_WEBOS_VERIFICATION_REPORT"])
profile = report.get("lgPaymentwallBuild")
if not isinstance(profile, dict) or report.get("packageSha256") is None:
    raise ValueError("verified package report is missing billing profile or package digest")
if ipk.name != f"{report.get('appId')}_{report.get('version')}_arm.ipk" or report.get("appId") != "org.snapetech.pleazyng":
    raise ValueError("verified package report does not match the built Pleazyng IPK")
record = {
    "sourceCommit": commit,
    "version": report["version"],
    "package": ipk.name,
    "packageSha256": report["packageSha256"],
    "deviceQualification": "not-established-by-build",
    "lgPaymentwallBuild": profile,
}
destination = output_dir / "webos-app-provenance.json"
if destination.is_symlink():
    raise ValueError("refusing symlink application provenance output")
with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=output_dir, prefix=".webos-app-provenance.", delete=False) as stream:
    temporary = pathlib.Path(stream.name)
    stream.write(json.dumps(record, indent=2) + "\n")
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, destination)
PYPROVENANCE
printf 'Validated release candidate: %s\n' "${IPKS[0]}"
