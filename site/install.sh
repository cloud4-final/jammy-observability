#!/usr/bin/env bash
# managed-by: jammy-obs-agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="${SCRIPT_DIR}/versions.env"

SITE=""
OBS_HOST="jammy-obs"
DRY_RUN=false
NO_START=false
RENDER_ONLY=""
UNINSTALL=false
PURGE=false

usage() {
  cat <<'EOF'
Usage: install.sh --site <jammy-a|jammy-b|jammy-c> [OPTIONS]

Options:
  --site <name>        Site identifier (jammy-a, jammy-b, jammy-c) [Required]
  --obs-host <host>    OBS central host DNS name (default: jammy-obs)
  --dry-run            Print actions without making changes
  --no-start           Do not enable or start systemd services
  --render-only <dir>  Render configs to <dir>/etc without installing
  --uninstall          Uninstall agent services and remove /opt/jammy-obs-agent
  --purge              Remove /var/lib/jammy-obs-agent during uninstall
  -h, --help           Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --site)
      shift
      [ $# -gt 0 ] || { echo "Error: --site requires an argument" >&2; exit 2; }
      SITE="$1"
      ;;
    --obs-host)
      shift
      [ $# -gt 0 ] || { echo "Error: --obs-host requires an argument" >&2; exit 2; }
      OBS_HOST="$1"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --no-start)
      NO_START=true
      ;;
    --render-only)
      shift
      [ $# -gt 0 ] || { echo "Error: --render-only requires a directory argument" >&2; exit 2; }
      RENDER_ONLY="$1"
      ;;
    --uninstall)
      UNINSTALL=true
      ;;
    --purge)
      PURGE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# Step 1: Validate --site
case "$SITE" in
  jammy-a|jammy-b|jammy-c)
    ;;
  *)
    echo "Error: Invalid site '$SITE'. Allowed values: jammy-a, jammy-b, jammy-c." >&2
    exit 2
    ;;
esac

# Handle --render-only early (does not require root)
if [ -n "$RENDER_ONLY" ]; then
  mkdir -p "${RENDER_ONLY}/etc"
  sed -e "s|@SITE_ID@|${SITE}|g" -e "s|@OBS_HOST@|${OBS_HOST}|g" \
    "${SCRIPT_DIR}/templates/prometheus.yml.tmpl" > "${RENDER_ONLY}/etc/prometheus.yml"
  sed -e "s|@SITE_ID@|${SITE}|g" -e "s|@OBS_HOST@|${OBS_HOST}|g" \
    "${SCRIPT_DIR}/templates/config.alloy.tmpl" > "${RENDER_ONLY}/etc/config.alloy"
  cp "${SCRIPT_DIR}/config/blackbox.yml" "${RENDER_ONLY}/etc/blackbox.yml"
  cp "${SCRIPT_DIR}/config/probes.yml" "${RENDER_ONLY}/etc/probes.yml"
  echo "Render-only complete: configurations written to ${RENDER_ONLY}/etc"
  exit 0
fi

# Root check for installation / uninstallation
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: install.sh requires root privileges." >&2
  exit 1
fi

# Handle --uninstall
if [ "$UNINSTALL" = true ]; then
  echo "Uninstalling jammy-obs-agent..."
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would stop and disable systemd units: jammy-prometheus, jammy-node-exporter, jammy-blackbox, jammy-alloy"
    echo "[dry-run] Would remove unit files from /etc/systemd/system/"
    echo "[dry-run] Would remove /opt/jammy-obs-agent"
    if [ "$PURGE" = true ]; then
      echo "[dry-run] Would remove /var/lib/jammy-obs-agent"
    fi
    exit 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    for unit in jammy-prometheus jammy-node-exporter jammy-blackbox jammy-alloy; do
      systemctl stop "$unit" 2>/dev/null || true
      systemctl disable "$unit" 2>/dev/null || true
      rm -f "/etc/systemd/system/${unit}.service"
    done
    systemctl daemon-reload 2>/dev/null || true
  fi

  rm -rf /opt/jammy-obs-agent
  if [ "$PURGE" = true ]; then
    rm -rf /var/lib/jammy-obs-agent
  fi
  echo "Uninstallation complete."
  exit 0
fi

# Step 2: Pre-flight checks (conflict detection)
# Check unit conflicts
UNIT_NAMES=("jammy-prometheus.service" "jammy-node-exporter.service" "jammy-blackbox.service" "jammy-alloy.service")
for u in "${UNIT_NAMES[@]}"; do
  unit_file="/etc/systemd/system/${u}"
  if [ -f "$unit_file" ]; then
    first_line="$(head -n 1 "$unit_file" 2>/dev/null || true)"
    if [ "$first_line" != "# managed-by: jammy-obs-agent" ]; then
      echo "Error: Conflict detected. Unit $unit_file exists and is not managed by jammy-obs-agent." >&2
      exit 3
    fi
  fi
done

# Check port conflicts on 127.0.0.1: 9090, 9100, 9115, 9177, 12345, 4317, 4318
CHECK_PORTS=(9090 9100 9115 9177 12345 4317 4318)
for port in "${CHECK_PORTS[@]}"; do
  # Determine expected unit
  expected_unit=""
  case "$port" in
    9090) expected_unit="jammy-prometheus.service" ;;
    9100) expected_unit="jammy-node-exporter.service" ;;
    9115) expected_unit="jammy-blackbox.service" ;;
    9177) expected_unit="prometheus-libvirt-exporter.service" ;;
    12345|4317|4318) expected_unit="jammy-alloy.service" ;;
  esac

  port_in_use=false
  listener_info=""

  if command -v ss >/dev/null 2>&1; then
    listener_info=$(ss -ltnp 2>/dev/null | grep -E "(:|\])${port}\s+" || true)
    if [ -n "$listener_info" ]; then
      port_in_use=true
    fi
  elif command -v netstat >/dev/null 2>&1; then
    listener_info=$(netstat -ltnp 2>/dev/null | grep -E "(:|\])${port}\s+" || true)
    if [ -n "$listener_info" ]; then
      port_in_use=true
    fi
  elif [ -r /proc/net/tcp ]; then
    hex_port=$(printf '%04X' "$port")
    if grep -q -E ":${hex_port}\s+[0-9A-Fa-f:]+\s+0A" /proc/net/tcp 2>/dev/null; then
      port_in_use=true
      listener_info="proc/net/tcp port $port in LISTEN state"
    fi
  fi

  if [ "$port_in_use" = true ]; then
    # Verify if listener belongs to our expected unit
    is_ours=false
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active "$expected_unit" >/dev/null 2>&1; then
      unit_pid=$(systemctl show -p MainPID --value "$expected_unit" 2>/dev/null || true)
      if [ -n "$unit_pid" ] && [ "$unit_pid" != "0" ] && echo "$listener_info" | grep -q "pid=${unit_pid},"; then
        is_ours=true
      fi
    fi
    if [ "$is_ours" = false ]; then
      echo "Error: Conflict detected. Port $port is already listening and not owned by $expected_unit." >&2
      echo "Listener: $listener_info" >&2
      exit 3
    fi
  fi
done

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] Pre-flight checks passed."
  echo "[dry-run] Would create system user obsagent and add to systemd-journal."
  echo "[dry-run] Would create /opt/jammy-obs-agent/{bin,etc} and /var/lib/jammy-obs-agent/{prometheus,alloy}."
  echo "[dry-run] Would download and install Prometheus, Node Exporter, Blackbox Exporter, Alloy."
  echo "[dry-run] Would apt-get install prometheus-libvirt-exporter and configure 127.0.0.1:9177."
  echo "[dry-run] Would render configuration templates to /opt/jammy-obs-agent/etc/."
  echo "[dry-run] Would install systemd service units."
  if [ "$NO_START" = false ]; then
    echo "[dry-run] Would enable and start services via systemctl."
  fi
  exit 0
fi

# Step 3: Create system user obsagent and add to systemd-journal group
if ! id -u obsagent >/dev/null 2>&1; then
  NOLOGIN="/usr/sbin/nologin"
  if [ ! -x "$NOLOGIN" ]; then
    NOLOGIN="/bin/false"
  fi
  useradd --system --no-create-home --shell "$NOLOGIN" obsagent
fi
if getent group systemd-journal >/dev/null 2>&1; then
  usermod -a -G systemd-journal obsagent || true
fi

# Step 4: Create directories
mkdir -p /opt/jammy-obs-agent/bin /opt/jammy-obs-agent/etc
mkdir -p /var/lib/jammy-obs-agent/prometheus /var/lib/jammy-obs-agent/alloy
chown -R obsagent:obsagent /var/lib/jammy-obs-agent
chmod 750 /var/lib/jammy-obs-agent /var/lib/jammy-obs-agent/prometheus /var/lib/jammy-obs-agent/alloy

# Load versions
if [ ! -f "$VERSIONS_FILE" ]; then
  echo "Error: $VERSIONS_FILE not found" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$VERSIONS_FILE"

# Step 5: Download and install binaries
DL_TMP=$(mktemp -d /tmp/jammy-agent-dl.XXXXXX)
trap 'rm -rf "$DL_TMP"' EXIT

# Helper for downloading and verifying sha256
download_and_verify() {
  local url="$1"
  local dest="$2"
  local expected_sha="$3"

  curl -sSL "$url" -o "$dest"
  local actual_sha
  actual_sha=$(sha256sum "$dest" | awk '{print $1}')
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "Error: SHA256 checksum mismatch for $dest!" >&2
    echo "Expected: $expected_sha" >&2
    echo "Actual:   $actual_sha" >&2
    exit 4
  fi
}

# 5.1 Prometheus
if [ -x /opt/jammy-obs-agent/bin/prometheus ] && /opt/jammy-obs-agent/bin/prometheus --version 2>&1 | grep -q "${PROMETHEUS_VERSION}"; then
  echo "Prometheus ${PROMETHEUS_VERSION} already installed. Skipping download."
else
  echo "Downloading Prometheus ${PROMETHEUS_VERSION}..."
  PROM_ARCHIVE="${DL_TMP}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
  download_and_verify \
    "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
    "$PROM_ARCHIVE" \
    "$PROMETHEUS_SHA256"
  tar -xzf "$PROM_ARCHIVE" -C "$DL_TMP"
  cp "${DL_TMP}/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /opt/jammy-obs-agent/bin/prometheus
  cp "${DL_TMP}/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" /opt/jammy-obs-agent/bin/promtool 2>/dev/null || true
  chmod 755 /opt/jammy-obs-agent/bin/prometheus /opt/jammy-obs-agent/bin/promtool 2>/dev/null || chmod 755 /opt/jammy-obs-agent/bin/prometheus
fi

# 5.2 Node Exporter
if [ -x /opt/jammy-obs-agent/bin/node_exporter ] && /opt/jammy-obs-agent/bin/node_exporter --version 2>&1 | grep -q "${NODE_EXPORTER_VERSION}"; then
  echo "Node Exporter ${NODE_EXPORTER_VERSION} already installed. Skipping download."
else
  echo "Downloading Node Exporter ${NODE_EXPORTER_VERSION}..."
  NODE_ARCHIVE="${DL_TMP}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  download_and_verify \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
    "$NODE_ARCHIVE" \
    "$NODE_EXPORTER_SHA256"
  tar -xzf "$NODE_ARCHIVE" -C "$DL_TMP"
  cp "${DL_TMP}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /opt/jammy-obs-agent/bin/node_exporter
  chmod 755 /opt/jammy-obs-agent/bin/node_exporter
fi

# 5.3 Blackbox Exporter
if [ -x /opt/jammy-obs-agent/bin/blackbox_exporter ] && /opt/jammy-obs-agent/bin/blackbox_exporter --version 2>&1 | grep -q "${BLACKBOX_VERSION}"; then
  echo "Blackbox Exporter ${BLACKBOX_VERSION} already installed. Skipping download."
else
  echo "Downloading Blackbox Exporter ${BLACKBOX_VERSION}..."
  BLACKBOX_ARCHIVE="${DL_TMP}/blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz"
  download_and_verify \
    "https://github.com/prometheus/blackbox_exporter/releases/download/v${BLACKBOX_VERSION}/blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz" \
    "$BLACKBOX_ARCHIVE" \
    "$BLACKBOX_SHA256"
  tar -xzf "$BLACKBOX_ARCHIVE" -C "$DL_TMP"
  cp "${DL_TMP}/blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64/blackbox_exporter" /opt/jammy-obs-agent/bin/blackbox_exporter
  chmod 755 /opt/jammy-obs-agent/bin/blackbox_exporter
fi

# 5.4 Grafana Alloy
if [ -x /opt/jammy-obs-agent/bin/alloy ] && /opt/jammy-obs-agent/bin/alloy --version 2>&1 | grep -q "${ALLOY_VERSION}"; then
  echo "Grafana Alloy ${ALLOY_VERSION} already installed. Skipping download."
else
  echo "Downloading Grafana Alloy ${ALLOY_VERSION}..."
  ALLOY_ARCHIVE="${DL_TMP}/alloy-linux-amd64.zip"
  download_and_verify \
    "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-linux-amd64.zip" \
    "$ALLOY_ARCHIVE" \
    "$ALLOY_SHA256"

  if ! command -v unzip >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip
  fi
  unzip -q -o "$ALLOY_ARCHIVE" -d "${DL_TMP}/alloy_unpack"
  cp "${DL_TMP}/alloy_unpack/alloy-linux-amd64" /opt/jammy-obs-agent/bin/alloy
  chmod 755 /opt/jammy-obs-agent/bin/alloy
fi

# Step 6: Install and configure prometheus-libvirt-exporter
echo "Configuring prometheus-libvirt-exporter..."
if ! dpkg -s prometheus-libvirt-exporter >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-libvirt-exporter
fi

LIBVIRT_CONF="/etc/default/prometheus-libvirt-exporter"
if [ -f "$LIBVIRT_CONF" ]; then
  if grep -q "^ARGS=" "$LIBVIRT_CONF"; then
    sed -i 's|^ARGS=.*|ARGS="--web.listen-address=127.0.0.1:9177"|' "$LIBVIRT_CONF"
  else
    echo 'ARGS="--web.listen-address=127.0.0.1:9177"' >> "$LIBVIRT_CONF"
  fi
fi

# Step 7: Render configuration templates
echo "Rendering configuration templates to /opt/jammy-obs-agent/etc/..."
sed -e "s|@SITE_ID@|${SITE}|g" -e "s|@OBS_HOST@|${OBS_HOST}|g" \
  "${SCRIPT_DIR}/templates/prometheus.yml.tmpl" > /opt/jammy-obs-agent/etc/prometheus.yml
sed -e "s|@SITE_ID@|${SITE}|g" -e "s|@OBS_HOST@|${OBS_HOST}|g" \
  "${SCRIPT_DIR}/templates/config.alloy.tmpl" > /opt/jammy-obs-agent/etc/config.alloy
cp "${SCRIPT_DIR}/config/blackbox.yml" /opt/jammy-obs-agent/etc/blackbox.yml
cp "${SCRIPT_DIR}/config/probes.yml" /opt/jammy-obs-agent/etc/probes.yml
chown -R obsagent:obsagent /opt/jammy-obs-agent/etc
chmod 644 /opt/jammy-obs-agent/etc/*

# Step 8: Install systemd units and optionally start services
echo "Installing systemd service units..."
for unit in "${UNIT_NAMES[@]}"; do
  cp "${SCRIPT_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
  chmod 644 "/etc/systemd/system/${unit}"
done

if [ "$NO_START" = false ]; then
  if command -v systemctl >/dev/null 2>&1; then
    echo "Reloading systemd and enabling services..."
    systemctl daemon-reload
    systemctl enable --now jammy-prometheus jammy-node-exporter jammy-blackbox jammy-alloy prometheus-libvirt-exporter
  fi
else
  echo "--no-start specified: Skipping service activation."
fi

echo "Site agent installation completed successfully for site: ${SITE}"
