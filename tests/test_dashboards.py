import json
import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
HUB_DIR = REPO_ROOT / "hub"
DASHBOARDS_DIR = HUB_DIR / "grafana" / "dashboards"
PROMETHEUS_YML = HUB_DIR / "prometheus" / "prometheus.yml"

EXPECTED_DASHBOARDS = {
    "jammy-noc.json": "jammy-noc",
    "jammy-network.json": "jammy-network",
    "jammy-vms.json": "jammy-vms",
    "jammy-app.json": "jammy-app",
}

ALLOWED_DATASOURCE_UIDS = {"prometheus", "loki", "tempo", "alertmanager"}


def _load_dashboards():
    dashboards = {}
    for filename in EXPECTED_DASHBOARDS:
        path = DASHBOARDS_DIR / filename
        assert path.exists(), f"Dashboard file {filename} does not exist"
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        dashboards[filename] = data
    return dashboards


def test_dashboards_files_exist_and_valid_json():
    dashboards = _load_dashboards()
    assert len(dashboards) == 4
    for filename in EXPECTED_DASHBOARDS:
        assert filename in dashboards
        assert isinstance(dashboards[filename], dict)


def test_dashboards_uids_fixed_and_unique():
    dashboards = _load_dashboards()
    uids = []
    for filename, expected_uid in EXPECTED_DASHBOARDS.items():
        data = dashboards[filename]
        actual_uid = data.get("uid")
        assert actual_uid == expected_uid, (
            f"Expected UID {expected_uid} for {filename}, got {actual_uid}"
        )
        uids.append(actual_uid)
    assert len(uids) == len(set(uids)), f"Duplicate dashboard UIDs found: {uids}"


def test_dashboards_target_datasource_uids():
    dashboards = _load_dashboards()
    for filename, data in dashboards.items():
        panels = data.get("panels", [])
        for panel in panels:
            p_type = panel.get("type")
            if p_type == "row":
                continue
            if p_type == "text":
                continue

            # Check panel datasource if present
            p_ds = panel.get("datasource")
            if isinstance(p_ds, dict):
                p_uid = p_ds.get("uid")
                if p_uid and p_uid != "-- Grafana --":
                    assert p_uid in ALLOWED_DATASOURCE_UIDS, (
                        f"Dashboard {filename} panel '{panel.get('title')}' has invalid datasource uid: {p_uid}"
                    )

            # Check target datasources
            targets = panel.get("targets", [])
            for target in targets:
                t_ds = target.get("datasource")
                if isinstance(t_ds, dict):
                    t_uid = t_ds.get("uid")
                    assert t_uid in ALLOWED_DATASOURCE_UIDS, (
                        f"Dashboard {filename} panel '{panel.get('title')}' target has invalid datasource uid: {t_uid}"
                    )
                elif isinstance(t_ds, str):
                    assert t_ds in ALLOWED_DATASOURCE_UIDS, (
                        f"Dashboard {filename} panel '{panel.get('title')}' target has invalid datasource uid string: {t_ds}"
                    )


def test_dashboards_no_forbidden_ip_literals():
    ipv4_pattern = re.compile(
        r"\b(?!127\.0\.0\.1\b|0\.0\.0\.0\b)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b"
    )
    for filename in EXPECTED_DASHBOARDS:
        path = DASHBOARDS_DIR / filename
        content = path.read_text(encoding="utf-8")
        matches = ipv4_pattern.findall(content)
        assert not matches, (
            f"Dashboard {filename} contains forbidden IP literals: {matches}"
        )


def test_dashboards_site_variable_exists():
    dashboards = _load_dashboards()
    for filename, data in dashboards.items():
        variables = data.get("templating", {}).get("list", [])
        site_var = next((v for v in variables if v.get("name") == "site"), None)
        assert site_var is not None, f"Dashboard {filename} missing '$site' variable"
        query = site_var.get("query", "")
        if isinstance(query, dict):
            query = query.get("query", "")
        assert "site" in str(query), f"Dashboard {filename} '$site' variable query does not reference site: {query}"


def test_dashboards_variables_validity():
    """모든 대시보드의 query 변수에 빈 정규식(=~"") 금지, current.value 비어있지 않음 검증."""
    dashboards = _load_dashboards()
    for filename, data in dashboards.items():
        variables = data.get("templating", {}).get("list", [])
        for v in variables:
            v_name = v.get("name")
            current = v.get("current", {})
            val = current.get("value")
            assert val not in (None, ""), (
                f"Dashboard {filename} variable '${v_name}' has empty current.value"
            )
            if v.get("includeAll") and current.get("text") == "All":
                assert val == "$__all", (
                    f"Dashboard {filename} variable '${v_name}' with 'All' must have current.value '$__all', got {val!r}"
                )

            if v.get("type") == "query":
                q_raw = v.get("query", "")
                q_str = q_raw.get("query", "") if isinstance(q_raw, dict) else str(q_raw)
                assert not re.search(r'=~""|!~""', q_str), (
                    f"Dashboard {filename} variable '${v_name}' query contains empty regex: {q_str}"
                )
                definition = str(v.get("definition", ""))
                assert not re.search(r'=~""|!~""', definition), (
                    f"Dashboard {filename} variable '${v_name}' definition contains empty regex: {definition}"
                )


def test_jammy_vms_domain_variable_and_site_dependency():
    """jammy-vms의 $domain 변수 검증 및 $site 의존 변수의 $site 참조 검증."""
    dashboards = _load_dashboards()
    vms_data = dashboards["jammy-vms.json"]
    variables = vms_data.get("templating", {}).get("list", [])
    domain_var = next((v for v in variables if v.get("name") == "domain"), None)
    assert domain_var is not None, "jammy-vms.json missing '$domain' variable"

    q_raw = domain_var.get("query", "")
    q_str = q_raw.get("query", "") if isinstance(q_raw, dict) else str(q_raw)
    definition = str(domain_var.get("definition", ""))

    assert 'site=~"$site"' in q_str, (
        f"jammy-vms $domain query must reference $site via site=~\"$site\": {q_str}"
    )
    assert 'site=~"$site"' in definition, (
        f"jammy-vms $domain definition must reference $site via site=~\"$site\": {definition}"
    )


def test_jammy_vms_disk_throughput_legend_device():
    """jammy-vms 디스크 I/O 패널 범례에 {{target_device}} 포함 검증."""
    dashboards = _load_dashboards()
    vms_data = dashboards["jammy-vms.json"]
    disk_panels = [
        p for p in vms_data.get("panels", [])
        if "disk throughput" in p.get("title", "").lower()
    ]
    assert len(disk_panels) >= 1, "VM Disk Throughput panel not found in jammy-vms.json"
    for p in disk_panels:
        for t in p.get("targets", []):
            legend = t.get("legendFormat", "")
            assert "{{target_device}}" in legend, (
                f"Panel '{p.get('title')}' target legendFormat missing '{{{{target_device}}}}': {legend}"
            )


def test_jammy_network_matrix_uses_vantage_and_target_site():
    dashboards = _load_dashboards()
    network_db = dashboards["jammy-network.json"]
    panels = network_db.get("panels", [])
    matrix_panels = [
        p for p in panels
        if p.get("type") == "table" and "matrix" in p.get("title", "").lower()
    ]
    assert len(matrix_panels) >= 1, "No matrix table panel found in jammy-network.json"

    exprs = [
        t.get("expr", "")
        for p in matrix_panels
        for t in p.get("targets", [])
    ]
    assert any("vantage" in expr and "target_site" in expr for expr in exprs), (
        f"jammy-network matrix panel expr does not use vantage and target_site: {exprs}"
    )


def test_prometheus_blackbox_job_has_target_site_relabel():
    assert PROMETHEUS_YML.exists(), "prometheus.yml does not exist"
    with open(PROMETHEUS_YML, "r", encoding="utf-8") as f:
        prom_cfg = yaml.safe_load(f)

    scrape_configs = {
        job["job_name"]: job for job in prom_cfg.get("scrape_configs", [])
    }
    assert "blackbox_icmp" in scrape_configs, "blackbox_icmp missing in prometheus.yml"

    relabel_configs = scrape_configs["blackbox_icmp"].get("relabel_configs", [])
    has_target_site = any(
        r.get("target_label") == "target_site" for r in relabel_configs
    )
    assert has_target_site, (
        f"blackbox_icmp relabel_configs does not contain target_site: {relabel_configs}"
    )
