import json
import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
HUB_DIR = REPO_ROOT / "hub"
COMPOSE_PATH = HUB_DIR / "compose.yaml"
PROMETHEUS_YML = HUB_DIR / "prometheus" / "prometheus.yml"
SITES_YML = HUB_DIR / "prometheus" / "targets" / "sites.yml"
ALERTMANAGER_YML = HUB_DIR / "alertmanager" / "alertmanager.yml"
DATASOURCES_YAML = (
    HUB_DIR / "grafana" / "provisioning" / "datasources" / "datasources.yaml"
)
DASHBOARD_JSON = HUB_DIR / "grafana" / "dashboards" / "jammy-noc.json"


def test_remote_write_receiver_enabled():
    assert COMPOSE_PATH.exists()
    with open(COMPOSE_PATH, "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)
    prom_svc = compose.get("services", {}).get("prometheus", {})
    command = prom_svc.get("command", [])
    if isinstance(command, str):
        command = command.split()
    assert any("--web.enable-remote-write-receiver" in arg for arg in command), (
        "Prometheus command does not enable remote write receiver"
    )


def test_blackbox_jobs_use_file_sd_with_vantage():
    assert PROMETHEUS_YML.exists()
    with open(PROMETHEUS_YML, "r", encoding="utf-8") as f:
        prom_cfg = yaml.safe_load(f)
    scrape_configs = {
        job["job_name"]: job for job in prom_cfg.get("scrape_configs", [])
    }
    assert "blackbox_icmp" in scrape_configs, (
        "blackbox_icmp job missing in prometheus.yml"
    )
    assert "blackbox_ssh" not in scrape_configs, (
        "blackbox_ssh job should be removed from prometheus.yml"
    )

    job = scrape_configs["blackbox_icmp"]
    file_sds = job.get("file_sd_configs", [])
    files = [f for sd in file_sds for f in sd.get("files", [])]
    assert any("targets/sites.yml" in f for f in files), (
        "blackbox_icmp does not reference targets/sites.yml in file_sd_configs"
    )
    relabel = job.get("relabel_configs", [])
    vantage_set = any(
        r.get("target_label") == "vantage" and r.get("replacement") == "jammy-obs"
        for r in relabel
    )
    assert vantage_set, "blackbox_icmp relabel_configs does not set vantage=jammy-obs"
    target_site_set = any(
        r.get("target_label") == "target_site"
        for r in relabel
    )
    assert target_site_set, "blackbox_icmp relabel_configs does not set target_site"


def test_prometheus_internal_targets_no_localhost():
    assert PROMETHEUS_YML.exists()
    content = PROMETHEUS_YML.read_text(encoding="utf-8")
    assert "localhost" not in content, (
        "prometheus.yml should use '127.0.0.1' instead of 'localhost' for all internal targets"
    )


def test_readme_requirements():
    readme_path = HUB_DIR / "README.md"
    assert readme_path.exists()
    readme_text = readme_path.read_text(encoding="utf-8")

    # Item 3: 제약 절에 obs->거점 TCP 프로브 관련 기록
    assert "obs→거점 TCP 프로브는 ACL 허용 후 추가" in readme_text, (
        "README missing constraint: 'obs→거점 TCP 프로브는 ACL 허용 후 추가'"
    )

    # Item 4: Alertmanager proxy status endpoint
    assert "/api/datasources/proxy/uid/alertmanager/api/v2/status" in readme_text, (
        "README missing Alertmanager proxy endpoint: '/api/datasources/proxy/uid/alertmanager/api/v2/status'"
    )

    # Item 7: Grafana SSH tunneling
    assert "ssh -L 3000:127.0.0.1:3000 yang@jammy-obs" in readme_text, (
        "README missing Grafana SSH tunnel command: 'ssh -L 3000:127.0.0.1:3000 yang@jammy-obs'"
    )
    assert "http://localhost:3000" in readme_text, (
        "README missing 'http://localhost:3000'"
    )




def test_sites_targets_exact():
    assert SITES_YML.exists()
    with open(SITES_YML, "r", encoding="utf-8") as f:
        sites_cfg = yaml.safe_load(f)
    assert isinstance(sites_cfg, list)

    sites_found = set()
    targets_found = set()
    for entry in sites_cfg:
        labels = entry.get("labels", {})
        if "site" in labels:
            sites_found.add(labels["site"])
        for t in entry.get("targets", []):
            targets_found.add(t)

    assert sites_found == {"jammy-a", "jammy-b", "jammy-c"}, (
        f"Sites mismatch: {sites_found}"
    )
    assert "jammy-a" in str(targets_found)
    assert "jammy-b" in str(targets_found)
    assert "jammy-c" in str(targets_found)


def test_alertmanager_slack_uses_file():
    with open(ALERTMANAGER_YML, "r", encoding="utf-8") as f:
        am_cfg = yaml.safe_load(f)
    receivers = {r["name"]: r for r in am_cfg.get("receivers", [])}
    assert am_cfg["route"]["receiver"] == "slack-jammy-alerts"
    for name in ("slack-jammy-alerts", "slack-jammy-alerts-critical"):
        cfgs = receivers[name].get("slack_configs", [])
        assert cfgs, f"{name} has no slack_configs"
        for cfg in cfgs:
            assert cfg.get("api_url_file") == "/etc/alertmanager/secrets/slack_webhook_url"
            assert "api_url" not in cfg, "webhook URL must not be inlined"
            assert cfg.get("send_resolved") is True
    critical = [r for r in am_cfg["route"]["routes"] if "severity = critical" in r.get("matchers", [])]
    assert critical and critical[0]["receiver"] == "slack-jammy-alerts-critical"
    assert "discord" not in open(ALERTMANAGER_YML, encoding="utf-8").read()


def test_datasource_uids():
    assert DATASOURCES_YAML.exists()
    with open(DATASOURCES_YAML, "r", encoding="utf-8") as f:
        ds_cfg = yaml.safe_load(f)
    datasources = ds_cfg.get("datasources", [])
    uids = {ds.get("uid") for ds in datasources}
    expected_uids = {"prometheus", "loki", "tempo", "alertmanager"}
    assert expected_uids.issubset(uids), f"Missing datasources: {expected_uids - uids}"


def test_dashboard_has_site_variable_and_no_ips():
    assert DASHBOARD_JSON.exists()
    with open(DASHBOARD_JSON, "r", encoding="utf-8") as f:
        dashboard = json.load(f)

    assert dashboard.get("uid") == "jammy-noc", (
        f"Dashboard uid is {dashboard.get('uid')}, expected jammy-noc"
    )

    variables = dashboard.get("templating", {}).get("list", [])
    site_var = next((v for v in variables if v.get("name") == "site"), None)
    assert site_var is not None, "Dashboard missing 'site' variable"
    query = site_var.get("query", "")
    if isinstance(query, dict):
        query = query.get("query", "")
    assert "label_values" in query and "site" in query, (
        f"Unexpected site query: {query}"
    )

    dashboard_text = json.dumps(dashboard)
    ipv4_pattern = re.compile(
        r"\b(?!127\.0\.0\.1\b|0\.0\.0\.0\b)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b"
    )
    matches = ipv4_pattern.findall(dashboard_text)
    assert not matches, f"Dashboard contains forbidden IP literals: {matches}"


def test_rules_and_dashboard_use_vantage_filter():
    rules_file = REPO_ROOT / "alerts" / "rules.yml"
    assert rules_file.exists()
    with open(rules_file, "r", encoding="utf-8") as f:
        rules_cfg = yaml.safe_load(f)

    alerts = {}
    for group in rules_cfg.get("groups", []):
        for r in group.get("rules", []):
            if "alert" in r:
                alerts[r["alert"]] = r.get("expr", "").strip()

    assert 'up{vantage=""} == 0' in alerts.get("InstanceDown", ""), (
        f"InstanceDown expr missing vantage=\"\": {alerts.get('InstanceDown')}"
    )
    assert 'sum by (site) (up{vantage=""}) == 0' in alerts.get(
        "SiteNetworkPartition", ""
    ), f"SiteNetworkPartition expr missing vantage=\"\": {alerts.get('SiteNetworkPartition')}"
    assert (
        'up{site=~"jammy-[abc]",vantage=""}'
        in alerts.get("SiteTelemetryMissing", "")
    ), f"SiteTelemetryMissing expr missing vantage=\"\": {alerts.get('SiteTelemetryMissing')}"

    with open(DASHBOARD_JSON, "r", encoding="utf-8") as f:
        dashboard = json.load(f)

    freshness_panels = [
        p
        for p in dashboard.get("panels", [])
        if "freshness" in p.get("title", "").lower() or "lag" in p.get("title", "").lower()
    ]
    assert len(freshness_panels) > 0, "Freshness panel not found in dashboard"
    for p in freshness_panels:
        exprs = [t.get("expr", "") for t in p.get("targets", [])]
        assert any('timestamp(up{' in expr and 'vantage=""' in expr for expr in exprs), (
            f"Freshness panel target expr missing timestamp(up{{...,vantage=\"\"}}): {exprs}"
        )



def test_alertmanager_groups_by_severity():
    with open(ALERTMANAGER_YML, "r", encoding="utf-8") as f:
        am_cfg = yaml.safe_load(f)
    assert "severity" in am_cfg["route"]["group_by"]


def test_deploy_refuses_missing_slack_webhook():
    script = (Path(__file__).resolve().parents[1] / "hub" / "deploy.sh").read_text(encoding="utf-8")
    assert "PLACEHOLDER" not in script, "deploy must not write a placeholder webhook"
    assert "hooks\\.slack\\.com/services/" in script
