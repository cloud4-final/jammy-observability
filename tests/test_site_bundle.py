import os
import re
import subprocess
from pathlib import Path
import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SITE_DIR = REPO_ROOT / "site"
INSTALL_SH = SITE_DIR / "install.sh"
SYSTEMD_DIR = SITE_DIR / "systemd"
VERSIONS_ENV = SITE_DIR / "versions.env"

UNIT_FILES = [
    "jammy-prometheus.service",
    "jammy-node-exporter.service",
    "jammy-blackbox.service",
    "jammy-alloy.service",
]


@pytest.fixture(scope="module")
def rendered_bundle(tmp_path_factory):
    tmp_dir = tmp_path_factory.mktemp("rendered_site_bundle")
    cmd = [
        "bash",
        str(INSTALL_SH),
        "--render-only",
        str(tmp_dir),
        "--site",
        "jammy-b",
        "--obs-host",
        "jammy-obs",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    assert proc.returncode == 0, (
        f"install.sh --render-only failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
    )
    return tmp_dir


def test_external_label_site(rendered_bundle):
    prom_cfg_path = rendered_bundle / "etc" / "prometheus.yml"
    assert prom_cfg_path.exists(), f"{prom_cfg_path} does not exist"
    with open(prom_cfg_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    assert "global" in cfg, "missing global section in prometheus.yml"
    assert "external_labels" in cfg["global"], (
        "missing external_labels in prometheus.yml"
    )
    assert cfg["global"]["external_labels"] == {"site": "jammy-b"}


def test_remote_write_logical_host(rendered_bundle):
    prom_cfg_path = rendered_bundle / "etc" / "prometheus.yml"
    assert prom_cfg_path.exists()
    with open(prom_cfg_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    assert "remote_write" in cfg, "missing remote_write section in prometheus.yml"
    assert len(cfg["remote_write"]) > 0, "empty remote_write list"
    rw_url = cfg["remote_write"][0].get("url")
    assert rw_url == "http://jammy-obs:9090/api/v1/write"


def test_self_probe_dropped(rendered_bundle):
    prom_cfg_path = rendered_bundle / "etc" / "prometheus.yml"
    assert prom_cfg_path.exists()
    with open(prom_cfg_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    scrape_configs = cfg.get("scrape_configs", [])
    probe_jobs = [sc for sc in scrape_configs if "blackbox" in sc.get("job_name", "")]
    assert len(probe_jobs) > 0, "no blackbox probe jobs found"

    for job in probe_jobs:
        relabel_configs = job.get("relabel_configs", [])
        drop_rules = [
            rc
            for rc in relabel_configs
            if rc.get("action") == "drop"
            and rc.get("source_labels") == ["target_site"]
            and rc.get("regex") == "jammy-b"
        ]
        assert len(drop_rules) >= 1, (
            f"drop rule for target_site==jammy-b missing in job {job.get('job_name')}"
        )


def test_all_listen_loopback(rendered_bundle):
    # Check rendered configuration files
    rendered_alloy = rendered_bundle / "etc" / "config.alloy"
    assert rendered_alloy.exists(), f"{rendered_alloy} does not exist"
    content = rendered_alloy.read_text(encoding="utf-8")
    # otelcol endpoints should only listen on 127.0.0.1
    for match in re.finditer(r'endpoint\s*=\s*"([^"]+)"', content):
        endpoint = match.group(1)
        # remote push is ok, listen endpoints should be 127.0.0.1
        if "jammy-obs" not in endpoint:
            assert endpoint.startswith("127.0.0.1:"), (
                f"Non-loopback listen endpoint in alloy: {endpoint}"
            )

    # Check systemd units
    for unit_name in UNIT_FILES:
        unit_path = SYSTEMD_DIR / unit_name
        assert unit_path.exists(), f"systemd unit {unit_name} does not exist"
        unit_content = unit_path.read_text(encoding="utf-8")

        # Find any listen address flags (--web.listen-address, --server.http.listen-addr)
        for match in re.finditer(
            r'--(?:web\.listen-address|server\.http\.listen-addr)=([^\s"]+)',
            unit_content,
        ):
            listen_addr = match.group(1)
            assert listen_addr.startswith("127.0.0.1:"), (
                f"Non-loopback listen address in {unit_name}: {listen_addr}"
            )


def test_no_ip_literals():
    ipv4_pattern = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
    allowed_ips = {"127.0.0.1", "0.0.0.0"}
    data_vm_ips = {"10.11.0.130", "10.21.0.130", "10.31.0.130"}

    assert SITE_DIR.exists(), f"Site dir {SITE_DIR} does not exist"
    for root, _, files in os.walk(SITE_DIR):
        for fname in files:
            file_path = Path(root) / fname
            # skip hidden files or non-text files if any
            if fname.startswith("."):
                continue
            text = file_path.read_text(encoding="utf-8", errors="ignore")
            for line_no, line in enumerate(text.splitlines(), start=1):
                ips = ipv4_pattern.findall(line)
                for ip in ips:
                    assert ip in allowed_ips or (file_path == INSTALL_SH and ip in data_vm_ips), (
                        f"Forbidden IP literal '{ip}' found in {file_path.relative_to(REPO_ROOT)}:{line_no}: {line}"
                    )


def test_versions_have_sha256():
    assert VERSIONS_ENV.exists(), f"{VERSIONS_ENV} does not exist"
    env_content = VERSIONS_ENV.read_text(encoding="utf-8")

    vars_dict = {}
    for line in env_content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            vars_dict[k.strip()] = v.strip().strip('"').strip("'")

    required_software = [
        ("PROMETHEUS_VERSION", "PROMETHEUS_SHA256"),
        ("NODE_EXPORTER_VERSION", "NODE_EXPORTER_SHA256"),
        ("BLACKBOX_VERSION", "BLACKBOX_SHA256"),
        ("ALLOY_VERSION", "ALLOY_SHA256"),
    ]

    sha_pattern = re.compile(r"^[0-9a-fA-F]{64}$")
    for ver_key, sha_key in required_software:
        assert ver_key in vars_dict, f"Missing {ver_key} in {VERSIONS_ENV}"
        assert sha_key in vars_dict, f"Missing {sha_key} in {VERSIONS_ENV}"
        sha_val = vars_dict[sha_key]
        assert sha_pattern.match(sha_val), f"Invalid sha256 '{sha_val}' for {sha_key}"


def test_invalid_site_rejected(tmp_path):
    cmd = [
        "bash",
        str(INSTALL_SH),
        "--render-only",
        str(tmp_path),
        "--site",
        "jammy-x",
        "--obs-host",
        "jammy-obs",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    assert proc.returncode == 2, (
        f"Expected return code 2 for invalid site, got {proc.returncode}"
    )


def test_units_marked_managed():
    for unit_name in UNIT_FILES:
        unit_path = SYSTEMD_DIR / unit_name
        assert unit_path.exists(), f"systemd unit {unit_name} does not exist"
        with open(unit_path, "r", encoding="utf-8") as f:
            first_line = f.readline().strip()
        assert first_line == "# managed-by: jammy-obs-agent", (
            f"First line of {unit_name} must be '# managed-by: jammy-obs-agent', but got: '{first_line}'"
        )


def test_alloy_journal_relabel(rendered_bundle):
    rendered_alloy = rendered_bundle / "etc" / "config.alloy"
    assert rendered_alloy.exists(), f"{rendered_alloy} does not exist"
    content = rendered_alloy.read_text(encoding="utf-8")

    assert "relabel_rules = loki.relabel.journal.rules" in content, (
        "missing relabel_rules = loki.relabel.journal.rules in config.alloy"
    )

    # loki.relabel "journal" forward_to must be empty
    relabel_match = re.search(
        r'loki\.relabel\s+"journal"\s*\{(?P<body>[\s\S]*?)\n\}', content
    )
    assert relabel_match, 'loki.relabel "journal" block not found'
    relabel_body = relabel_match.group("body")
    assert re.search(r"forward_to\s*=\s*\[\s*\]", relabel_body), (
        f"loki.relabel 'journal' forward_to must be empty '[]', but got:\n{relabel_body}"
    )


def test_libvirt_args_and_precreation():
    content = INSTALL_SH.read_text(encoding="utf-8")
    expected_args = "--web.listen-address=127.0.0.1:9177 --libvirt.uri=qemu:///system?socket=/var/run/libvirt/libvirt-sock-ro"
    assert expected_args in content, (
        f"install.sh missing expected libvirt ARGS: {expected_args}"
    )

    # Dpkg force-confold option must be used
    assert "--force-confold" in content, (
        "install.sh must use -o Dpkg::Options::=--force-confold for apt-get install"
    )

    # Pre-creation check: writing to /etc/default/prometheus-libvirt-exporter must occur before apt-get install of libvirt exporter
    pre_create_pos = content.find("/etc/default/prometheus-libvirt-exporter")
    apt_install_pos = content.find(
        "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::=--force-confold prometheus-libvirt-exporter"
    )
    assert pre_create_pos != -1, (
        "Missing /etc/default/prometheus-libvirt-exporter in install.sh"
    )
    assert apt_install_pos != -1, (
        "Missing apt-get install of libvirt exporter in install.sh"
    )
    assert pre_create_pos < apt_install_pos, (
        "/etc/default/prometheus-libvirt-exporter must be pre-configured before apt-get install"
    )


def test_install_netstat_pid_pattern():
    content = INSTALL_SH.read_text(encoding="utf-8")
    expected_pattern = (
        r'grep -qE "\(pid=\$\{unit_pid\},\|\[\[:space:\]\]\$\{unit_pid\}/\)"'
    )
    assert re.search(expected_pattern, content), (
        'install.sh must use PID matching pattern: grep -qE "(pid=${unit_pid},|[[:space:]]${unit_pid}/)"'
    )


def test_readme_libvirt_guidance():
    readme_path = SITE_DIR / "README.md"
    assert readme_path.exists()
    readme_content = readme_path.read_text(encoding="utf-8")
    assert "curl -s 127.0.0.1:9177/metrics | grep libvirt_up" in readme_content
    assert "libvirt-sock-ro" in readme_content


def test_install_restarts_config_consumers():
    """Re-running install.sh must apply re-rendered configs to already running units."""
    script = (Path(__file__).resolve().parents[1] / "site" / "install.sh").read_text()
    assert "systemctl restart jammy-prometheus jammy-blackbox jammy-alloy" in script
