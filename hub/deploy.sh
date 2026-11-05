#!/usr/bin/env bash
set -euo pipefail

HOST="jammy-obs"
DEMO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"
      shift 2
      ;;
    --demo)
      DEMO=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--host <hostname>] [--demo]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REMOTE_USER="yang"
REMOTE_TARGET="${REMOTE_USER}@${HOST}"
STACK_ROOT="/opt/jammy-obs"

echo "=== [1/5] Preparing remote directories on ${HOST} ==="
ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
mkdir -p "${target_root}/stack/hub" \
         "${target_root}/stack/alerts" \
         "${target_root}/secrets" \
         "${target_root}/data/prometheus" \
         "${target_root}/data/alertmanager" \
         "${target_root}/data/loki" \
         "${target_root}/data/tempo" \
         "${target_root}/data/grafana"
EOF

echo "=== [2/5] Checking secrets on ${HOST} ==="
ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
secrets_dir="${target_root}/secrets"
chmod 700 "${secrets_dir}"

if [[ ! -f "${secrets_dir}/grafana_admin_password" ]]; then
  echo "Generating initial Grafana admin password..."
  openssl rand -base64 24 > "${secrets_dir}/grafana_admin_password"
  chmod 600 "${secrets_dir}/grafana_admin_password"
fi

if [[ ! -f "${secrets_dir}/discord_webhook_url" ]]; then
  echo "WARN: ${secrets_dir}/discord_webhook_url missing; setting placeholder." >&2
  echo "https://discord.com/api/webhooks/0/placeholder" > "${secrets_dir}/discord_webhook_url"
  chmod 600 "${secrets_dir}/discord_webhook_url"
fi
EOF

echo "=== [3/5] Synchronizing stack configs to ${HOST} ==="
rsync -a --delete "${REPO_ROOT}/observability/hub/" "${REMOTE_TARGET}:${STACK_ROOT}/stack/hub/"
rsync -a --delete --exclude='*.test.yml' "${REPO_ROOT}/observability/alerts/" "${REMOTE_TARGET}:${STACK_ROOT}/stack/alerts/"

if [[ "${DEMO}" == "true" ]]; then
  echo "Demo mode requested: preparing demo secrets and backend source..."
  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
secrets_dir="${target_root}/secrets"
if [[ ! -f "${secrets_dir}/demo_pg_password" ]]; then
  openssl rand -base64 16 > "${secrets_dir}/demo_pg_password"
  chmod 600 "${secrets_dir}/demo_pg_password"
fi
mkdir -p "${target_root}/data/demo-postgres"
EOF
  if [[ -d "${REPO_ROOT}/apps/collector" ]]; then
    ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
mkdir -p "${target_root}/stack/apps/collector"
EOF
    rsync -a --delete "${REPO_ROOT}/apps/collector/" "${REMOTE_TARGET}:${STACK_ROOT}/stack/apps/collector/"
  fi
  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
cat << 'YAML' > "${target_root}/stack/hub/prometheus/targets/demo.yml"
- targets:
    - localhost:8000
  labels:
    site: jammy-obs
    layer: app
    service: mobility-collector
YAML
EOF
else
  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
echo '[]' > "${target_root}/stack/hub/prometheus/targets/demo.yml"
EOF
fi

echo "=== [4/5] Deploying Docker Compose stack on ${HOST} ==="
if [[ "${DEMO}" == "true" ]]; then
  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
cd "${target_root}/stack/hub"
docker compose --profile demo up -d --remove-orphans --build
EOF
else
  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
cd "${target_root}/stack/hub"
docker compose -f compose.yaml up -d --remove-orphans
EOF
fi

echo "=== [5/5] Waiting for services to become healthy (up to 120s) ==="
DEADLINE=$((SECONDS + 120))
ALL_HEALTHY=false

while [[ ${SECONDS} -lt ${DEADLINE} ]]; do
  if ssh "${REMOTE_TARGET}" bash -s << 'EOF'
set -e
check_endpoint() {
  local url="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "$url" || echo "000")
  if [[ "$code" != "200" ]]; then
    return 1
  fi
  return 0
}

check_endpoint "http://127.0.0.1:9090/-/ready" && \
check_endpoint "http://127.0.0.1:9093/-/ready" && \
check_endpoint "http://127.0.0.1:3100/ready" && \
check_endpoint "http://127.0.0.1:3200/ready" && \
check_endpoint "http://127.0.0.1:3000/api/health" && \
check_endpoint "http://127.0.0.1:9115/-/healthy"
EOF
  then
    ALL_HEALTHY=true
    break
  fi
  echo "Waiting for services... (${SECONDS}s elapsed)"
  sleep 3
done

if [[ "${ALL_HEALTHY}" != "true" ]]; then
  echo "ERROR: Stack health check timed out after 120 seconds." >&2
  exit 1
fi

echo "✅ Central Observability Hub deployed and verified healthy on ${HOST}."
