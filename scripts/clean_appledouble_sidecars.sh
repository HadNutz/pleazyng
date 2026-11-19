#!/usr/bin/env bash
set -euo pipefail

readonly NFS_MOUNT="/Volumes/p"
readonly NFS_RUNS_ROOT="$NFS_MOUNT/runs"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <task-owned-apple-workspace>" >&2
  exit 2
fi
if [[ "${RUNNER_OS:-}" != "macOS" ]]; then
  echo "AppleDouble cleanup requires a macOS runner." >&2
  exit 1
fi
if [[ ! "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ || ! "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]]; then
  echo "GitHub run ID and attempt must be numeric." >&2
  exit 1
fi

case "${GITHUB_JOB:-}:${APPLE_SCRATCH_JOB:-}" in
  build-ios:*) scratch_job="ios" ;;
  build-macos:*) scratch_job="macos" ;;
  apple-native-test:ios|apple-native-test:macos|apple-native-test:tvos) scratch_job="$APPLE_SCRATCH_JOB" ;;
  *)
    echo "AppleDouble cleanup is not configured for this job: ${GITHUB_JOB:-unset}" >&2
    exit 1
    ;;
esac

workspace="$1"
if [[ "${RUNNER_ENVIRONMENT:-}" == "github-hosted" ]]; then
  if [[ -z "${RUNNER_TEMP:-}" || ! -d "$RUNNER_TEMP" ]]; then
    echo "Hosted AppleDouble cleanup requires a real RUNNER_TEMP." >&2
    exit 1
  fi
  runner_temp_real="$(cd "$RUNNER_TEMP" && /bin/pwd -P)"
  task_root="$runner_temp_real/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}"
  if [[ "$workspace" != "$task_root" || -L "$workspace" || ! -d "$workspace" || "$(cd "$workspace" && /bin/pwd -P)" != "$task_root" ]]; then
    echo "Refusing to clean an unexpected or redirected hosted Apple workspace: $workspace" >&2
    exit 1
  fi
else
  nfs_task_root="$NFS_RUNS_ROOT/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}"
  owner_file="$NFS_RUNS_ROOT/.plezyng-apple-scratch-p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}.owner"
  if /usr/bin/grep -q '^local_source_root=.' "$owner_file"; then
    local_tmp_real="$(cd /tmp && /bin/pwd -P)"
    local_source_root="$local_tmp_real/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}"
    task_root="$local_source_root"
  else
    task_root="$nfs_task_root"
    local_source_root="$task_root"
  fi
  if [[ "$workspace" != "$local_source_root" || -L "$workspace" || ! -d "$workspace" ]]; then
    echo "Refusing to clean an unexpected or redirected Apple workspace: $workspace" >&2
    exit 1
  fi
  if [[ "$(cd "$workspace" && /bin/pwd -P)" != "$local_source_root" ]]; then
    echo "Refusing to clean an Apple workspace that resolves elsewhere: $workspace" >&2
    exit 1
  fi
  if [[ -L "$owner_file" || ! -f "$owner_file" ]]; then
    echo "Refusing to clean Apple workspace without its task owner record: $owner_file" >&2
    exit 1
  fi

  mount_line="$(/sbin/mount | /usr/bin/awk -v mountpoint="$NFS_MOUNT" '$3 == mountpoint { print; exit }')"
  case "$mount_line" in
    kspld0*:/mnt/disks/gamespool0/plezyng-native-build-*" on $NFS_MOUNT (nfs,"*) ;;
    *)
      echo "Expected the Pleazyng NFS export from kspld0 at $NFS_MOUNT; found: ${mount_line:-no mount}" >&2
      exit 1
      ;;
  esac

  for expected in \
    "run_id=$GITHUB_RUN_ID" \
    "run_attempt=$GITHUB_RUN_ATTEMPT" \
    "job=$GITHUB_JOB" \
    "sha=${GITHUB_SHA:-}" \
    "scratch_mode=local-xcode" \
    "task_root=$nfs_task_root"; do
    if ! /usr/bin/grep -Fqx "$expected" "$owner_file"; then
      echo "Refusing to clean Apple workspace without its matching owner record: $owner_file" >&2
      exit 1
    fi
  done
  if [[ "$local_source_root" != "$nfs_task_root" ]] && ! /usr/bin/grep -Fqx "local_source_root=$local_source_root" "$owner_file"; then
    echo "Refusing to clean local Apple workspace without its task owner record: $owner_file" >&2
    exit 1
  fi
  task_root="$workspace"
fi


# Workflow ownership retains GITHUB_SHA; an approved frozen repair may check out
# a different, independently verified packaging source. Never conflate the two.
source_sha="${COMPILE_SOURCE_SHA:-${GITHUB_SHA:-}}"
if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ || "$(git -C "$workspace" rev-parse HEAD)" != "$source_sha" ]]; then
  echo "Apple workspace does not contain the exact requested source revision." >&2
  exit 1
fi

# Git's object database and administrative files are not compiler inputs.
# Pruning .git avoids walking every object while keeping source trees checked.
before_count="$(/usr/bin/find "$task_root" -type d -name '.git' -prune -o -name '._*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$before_count" != "0" ]]; then
  echo "Deleting $before_count AppleDouble sidecars from task-owned source workspace: $task_root"
  # `-delete` forces depth-first traversal, which disables `-prune` on macOS.
  /usr/bin/find "$task_root" -type d -name '.git' -prune -o -type f -name '._*' -exec /bin/rm -f {} +
fi

remaining="$(/usr/bin/find "$task_root" -type d -name '.git' -prune -o -name '._*' -print -quit)"
if [[ -n "$remaining" ]]; then
  echo "AppleDouble sidecars remain after cleanup; refusing to run Xcode. First remaining paths:" >&2
  /usr/bin/find "$task_root" -type d -name '.git' -prune -o -name '._*' -print | /usr/bin/sed -n '1,20p' >&2
  exit 1
fi

echo "AppleDouble sidecar check passed for task-owned source workspace: $task_root"
