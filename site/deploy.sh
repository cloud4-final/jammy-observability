#!/usr/bin/env bash
# managed-by: jammy-obs-agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: deploy.sh <jammy-a|jammy-b|jammy-c> [--apply]

Arguments:
  <site>     Target site host name (jammy-a, jammy-b, or jammy-c) [Required]
  --apply    Apply installation on target host (defaults to --dry-run without this flag)
EOF
}

if [ $# -lt 1 ]; then
  echo "Error: Target site argument is required." >&2
  usage >&2
  exit 2
fi

TARGET_SITE="$1"
shift

case "$TARGET_SITE" in
  jammy-a|jammy-b|jammy-c)
    ;;
  *)
    echo "Error: Invalid site '$TARGET_SITE'. Must be one of jammy-a, jammy-b, jammy-c." >&2
    usage >&2
    exit 2
    ;;
esac

APPLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

INSTALL_OPTS=("--site" "$TARGET_SITE")
if [ "$APPLY" = false ]; then
  INSTALL_OPTS+=("--dry-run")
  echo "Notice: Running in dry-run mode. Pass --apply to execute actual installation on ${TARGET_SITE}."
fi

# Package agent bundle
BUNDLE_TAR=$(mktemp /tmp/jammy-obs-agent-bundle.XXXXXX.tar.gz)
trap 'rm -f "$BUNDLE_TAR"' EXIT

echo "Archiving site bundle from ${SCRIPT_DIR}..."
tar -czf "$BUNDLE_TAR" -C "$SCRIPT_DIR" .

REMOTE_ARCHIVE="/tmp/jammy-obs-agent-bundle.tar.gz"
REMOTE_EXTRACT_DIR="/tmp/jammy-obs-agent"

echo "Copying bundle to ${TARGET_SITE}:${REMOTE_ARCHIVE}..."
scp "$BUNDLE_TAR" "${TARGET_SITE}:${REMOTE_ARCHIVE}"

echo "Executing install.sh on ${TARGET_SITE}..."
# shellcheck disable=SC2029
ssh "$TARGET_SITE" "mkdir -p '${REMOTE_EXTRACT_DIR}' && tar -xzf '${REMOTE_ARCHIVE}' -C '${REMOTE_EXTRACT_DIR}' && sudo bash '${REMOTE_EXTRACT_DIR}/install.sh' ${INSTALL_OPTS[*]} && rm -rf '${REMOTE_EXTRACT_DIR}' '${REMOTE_ARCHIVE}'"

echo "Deploy command finished for ${TARGET_SITE}."
