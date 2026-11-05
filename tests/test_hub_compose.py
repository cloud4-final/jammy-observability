import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
COMPOSE_PATH = REPO_ROOT / "observability" / "hub" / "compose.yaml"
HUB_DIR = REPO_ROOT / "observability" / "hub"

EXPECTED_SERVICES = {
    "prometheus",
    "alertmanager",
    "loki",
    "tempo",
    "grafana",
    "blackbox",
    "node-exporter",
}

EXPECTED_IMAGES = {
    "prometheus": "prom/prometheus:v3.13.5",
    "alertmanager": "prom/alertmanager:v0.34.2",
    "blackbox": "prom/blackbox-exporter:v0.29.1",
    "node-exporter": "prom/node-exporter:v1.12.1",
    "loki": "grafana/loki:3.7.7",
    "tempo": "grafana/tempo:3.1.1",
    "grafana": "grafana/grafana:13.2.5",
}


def load_compose():
    assert COMPOSE_PATH.exists(), f"compose file not found at {COMPOSE_PATH}"
    with open(COMPOSE_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def test_required_services():
    compose = load_compose()
    services = compose.get("services", {})
    base_services = {name for name, svc in services.items() if "profiles" not in svc}
    assert base_services == EXPECTED_SERVICES


def test_images_pinned():
    compose = load_compose()
    services = compose.get("services", {})
    for name, expected_image in EXPECTED_IMAGES.items():
        assert name in services, f"Service {name} missing from compose"
        svc = services[name]
        image = svc.get("image", "")
        assert image == expected_image, (
            f"Service {name} image mismatch: {image} != {expected_image}"
        )
        assert not image.endswith(":latest"), f"Service {name} uses :latest"


def test_host_network_and_restart():
    compose = load_compose()
    services = compose.get("services", {})
    for name, svc in services.items():
        assert svc.get("network_mode") == "host", (
            f"{name} does not use network_mode: host"
        )
        assert svc.get("restart") == "unless-stopped", (
            f"{name} does not use restart: unless-stopped"
        )


def test_stateful_volumes():
    compose = load_compose()
    services = compose.get("services", {})
    stateful = ["prometheus", "alertmanager", "loki", "tempo", "grafana"]
    for name in stateful:
        svc = services.get(name, {})
        volumes = svc.get("volumes", [])
        matched = False
        prefix_pattern = re.compile(
            r"(\$\{OBS_ROOT[^}]*\}|/opt/jammy-obs)/data/" + name
        )
        for vol in volumes:
            # Handle split on destination, accounting for ${OBS_ROOT:-/opt/...} colons
            src = (
                vol.rsplit(":", 1)[0] if isinstance(vol, str) else vol.get("source", "")
            )
            if prefix_pattern.search(src):
                matched = True
                break
        assert matched, (
            f"Service {name} missing bind mount under ${{OBS_ROOT:-/opt/jammy-obs}}/data/{name}"
        )


def test_internal_ports_loopback():
    assert HUB_DIR.exists(), f"Hub directory not found at {HUB_DIR}"
    files_to_check = list(HUB_DIR.rglob("*.yaml")) + list(HUB_DIR.rglob("*.yml"))
    assert len(files_to_check) > 0, "No yaml files found in hub dir"

    full_text = "\n".join(f.read_text(encoding="utf-8") for f in files_to_check)
    internal_ports = ["3200", "9096", "9097", "9115", "9100"]

    # 1. Check for host:port format in texts (e.g. 127.0.0.1:9115)
    # 2. Check for yaml blocks with listen_address and listen_port
    for port in internal_ports:
        # direct pattern "IP:PORT"
        colon_matches = re.findall(r"([0-9.]+):" + port, full_text)
        # config pattern "address: IP ... port: PORT"
        addr_port_matches = re.findall(
            r"listen_address:\s*([0-9.]+)\s*\n\s*[a-z_]*listen_port:\s*" + port,
            full_text,
        )
        all_matches = colon_matches + addr_port_matches
        assert all_matches, f"Port {port} not found in configs"
        for ip in all_matches:
            assert ip == "127.0.0.1", (
                f"Internal port {port} bound to {ip} instead of 127.0.0.1"
            )


def test_no_ip_literals():
    assert HUB_DIR.exists(), f"Hub directory not found at {HUB_DIR}"
    files_to_check = [
        f
        for f in HUB_DIR.rglob("*")
        if f.is_file()
        and not f.name.startswith(".")
        and f.suffix in {".yaml", ".yml", ".json", ".sh", ".md"}
    ]
    assert len(files_to_check) > 0, "No files found to inspect in hub dir"

    ipv4_pattern = re.compile(
        r"\b(?!127\.0\.0\.1\b|0\.0\.0\.0\b)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b"
    )
    for f in files_to_check:
        text = f.read_text(encoding="utf-8")
        matches = ipv4_pattern.findall(text)
        assert not matches, f"File {f} contains forbidden IP literals: {matches}"


def test_no_plaintext_secrets():
    compose = load_compose()
    for name, svc in compose.get("services", {}).items():
        env = svc.get("environment", {})
        if isinstance(env, list):
            env_dict = {}
            for item in env:
                if "=" in item:
                    k, v = item.split("=", 1)
                    env_dict[k] = v
            env = env_dict

        for k, v in env.items():
            if "PASSWORD" in k.upper() or "WEBHOOK" in k.upper():
                assert (
                    k.endswith(("__FILE", "_FILE"))
                    or "/secrets/" in str(v)
                    or "/run/secrets/" in str(v)
                ), f"Plaintext secret in service {name} env {k}={v}"
