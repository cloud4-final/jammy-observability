#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy.sh [OPTIONS]

Options:
  --host <hostname>       Target host DNS/IP (default: jammy-obs)
  --demo                  Deploy demo backend services
  --collector-src <path>  Path to collector source for local build
  --ssh-user <user>       SSH user for remote connection (default: yang or $SSH_USER)
  --print-plan            Print resolved deployment plan without connecting
  -h, --help              Show this help message
EOF
}

HOST="jammy-obs"
DEMO=false
COLLECTOR_SRC=""
SSH_USER="${SSH_USER:-yang}"
PRINT_PLAN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      if [[ $# -lt 2 ]]; then
        echo "Error: --host requires an argument" >&2
        usage >&2
        exit 2
      fi
      HOST="$2"
      shift 2
      ;;
    --demo)
      DEMO=true
      shift
      ;;
    --collector-src)
      if [[ $# -lt 2 ]]; then
        echo "Error: --collector-src requires an argument" >&2
        usage >&2
        exit 2
      fi
      COLLECTOR_SRC="$2"
      shift 2
      ;;
    --ssh-user)
      if [[ $# -lt 2 ]]; then
        echo "Error: --ssh-user requires an argument" >&2
        usage >&2
        exit 2
      fi
      SSH_USER="$2"
      shift 2
      ;;
    --print-plan)
      PRINT_PLAN=true
      shift
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
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REMOTE_USER="${SSH_USER}"
REMOTE_TARGET="${REMOTE_USER}@${HOST}"
STACK_ROOT="/opt/jammy-obs"
DEPLOY_IMAGE=""

if [[ "${DEMO}" == "true" ]]; then
  if [[ -n "${COLLECTOR_SRC}" ]]; then
    if [[ ! -d "${COLLECTOR_SRC}" ]]; then
      echo "Error: Collector source directory does not exist: ${COLLECTOR_SRC}" >&2
      exit 1
    fi
    COLLECTOR_SRC="$(cd "${COLLECTOR_SRC}" && pwd)"
    DEPLOY_IMAGE="jammy-collector:local"
  elif [[ -n "${COLLECTOR_IMAGE:-}" ]]; then
    DEPLOY_IMAGE="${COLLECTOR_IMAGE}"
  elif [[ -d "${REPO_ROOT}/../jammy-collector" ]]; then
    COLLECTOR_SRC="$(cd "${REPO_ROOT}/../jammy-collector" && pwd)"
    DEPLOY_IMAGE="jammy-collector:local"
  else
    echo "Error: Demo mode requires either --collector-src <path> (or default ${REPO_ROOT}/../jammy-collector) or COLLECTOR_IMAGE environment variable." >&2
    exit 1
  fi

  if [[ -n "${COLLECTOR_SRC}" ]]; then
    echo "Using collector source: ${COLLECTOR_SRC} (deploy image: ${DEPLOY_IMAGE})"
  else
    echo "Using COLLECTOR_IMAGE: ${DEPLOY_IMAGE}"
  fi
fi

if [[ "${PRINT_PLAN}" == "true" ]]; then
  echo "HOST=${HOST}"
  echo "SSH_USER=${SSH_USER}"
  echo "DEMO=${DEMO}"
  echo "COLLECTOR_SRC=${COLLECTOR_SRC}"
  echo "DEPLOY_IMAGE=${DEPLOY_IMAGE}"
  exit 0
fi

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
# Clean up legacy paths from monorepo if present
rm -rf "${target_root}/stack/apps" "${target_root}/apps"
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

webhook_file="${secrets_dir}/slack_webhook_url"
webhook_re='^https://hooks\.slack\.com/services/[A-Za-z0-9]+/[A-Za-z0-9]+/[A-Za-z0-9]+$'
# The whole file must be exactly one URL (one line, optional trailing newline).
if [[ ! -s "${webhook_file}" ]] || [[ "$(wc -l < "${webhook_file}")" -gt 1 ]] || ! [[ "$(cat "${webhook_file}")" =~ ${webhook_re} ]]; then
  echo "ERROR: ${webhook_file} is missing or not a Slack Incoming Webhook URL; alerts would not reach #jammy-alerts." >&2
  echo "Create it on the hub host first (input is hidden):" >&2
  echo "  ssh -t <user>@<hub> 'umask 077; read -rsp \"Slack webhook URL: \" U; echo; printf \"%s\\n\" \"\$U\" > ${webhook_file}'" >&2
  exit 1
fi
chmod 600 "${webhook_file}"
EOF

echo "=== [3/5] Synchronizing stack configs to ${HOST} ==="
rsync -a --delete "${REPO_ROOT}/hub/" "${REMOTE_TARGET}:${STACK_ROOT}/stack/hub/"
rsync -a --delete --exclude='*.test.yml' "${REPO_ROOT}/alerts/" "${REMOTE_TARGET}:${STACK_ROOT}/stack/alerts/"

if [[ "${DEMO}" == "true" ]]; then
  echo "Demo mode requested: preparing demo secrets and backend image..."
  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
secrets_dir="${target_root}/secrets"
if [[ ! -f "${secrets_dir}/demo_pg_password" ]]; then
  openssl rand -base64 16 > "${secrets_dir}/demo_pg_password"
fi
chmod 600 "${secrets_dir}/demo_pg_password"
mkdir -p "${target_root}/data/demo-postgres"
EOF

  if [[ -n "${COLLECTOR_SRC}" ]]; then
    echo "Building collector image from source on ${HOST}..."
    ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
mkdir -p "$1/stack/collector-src"
EOF
    rsync -a --delete \
      --exclude='.git' \
      --exclude='__pycache__' \
      --exclude='.pytest_cache' \
      --exclude='.venv' \
      "${COLLECTOR_SRC}/" "${REMOTE_TARGET}:${STACK_ROOT}/stack/collector-src/"
    ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
docker build -t jammy-collector:local "$1/stack/collector-src"
EOF
  elif [[ -n "${DEPLOY_IMAGE}" ]]; then
    echo "Pulling collector image on ${HOST}: ${DEPLOY_IMAGE}..."
    ssh "${REMOTE_TARGET}" bash -s -- "${DEPLOY_IMAGE}" << 'EOF'
set -euo pipefail
docker pull "$1"
EOF
  fi

  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" << 'EOF'
set -euo pipefail
target_root="$1"
cat << 'YAML' > "${target_root}/stack/hub/prometheus/targets/demo.yml"
- targets:
    - 127.0.0.1:8000
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
cd "${target_root}/stack/hub"
docker compose --profile demo stop
docker compose --profile demo rm -f
EOF
fi

echo "=== [4/5] Deploying Docker Compose stack on ${HOST} ==="
if [[ "${DEMO}" == "true" ]]; then
  ssh "${REMOTE_TARGET}" bash -s -- "${STACK_ROOT}" "${DEPLOY_IMAGE}" << 'EOF'
set -euo pipefail
target_root="$1"
collector_image="$2"
cd "${target_root}/stack/hub"
COLLECTOR_IMAGE="${collector_image}" docker compose --profile demo up -d --remove-orphans
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
  if ssh "${REMOTE_TARGET}" bash -s -- "${DEMO}" << 'EOF'
set -e
demo_mode="$1"
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
check_endpoint "http://127.0.0.1:9115/-/healthy" || exit 1

if [[ "${demo_mode}" == "true" ]]; then
  check_endpoint "http://127.0.0.1:8000/healthz" && \
  check_endpoint "http://127.0.0.1:8000/ready" || exit 1
fi
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
