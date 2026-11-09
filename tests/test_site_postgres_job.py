import subprocess
from pathlib import Path

import pytest
import yaml

INSTALL = Path(__file__).resolve().parents[1] / 'site/install.sh'


@pytest.mark.parametrize(('site', 'address'), [
    ('jammy-a', '10.11.0.130:9187'),
    ('jammy-b', '10.21.0.130:9187'),
    ('jammy-c', '10.31.0.130:9187'),
])
def test_postgres_job_rendered_per_site(tmp_path, site, address):
    subprocess.run(['bash', str(INSTALL), '--render-only', str(tmp_path), '--site', site], check=True)
    config = yaml.safe_load((tmp_path / 'etc/prometheus.yml').read_text())
    job = next(j for j in config['scrape_configs'] if j['job_name'] == 'postgres')
    assert job['static_configs'] == [{'targets': [address], 'labels': {'layer': 'vm'}}]


def test_unknown_site_rejected(tmp_path):
    result = subprocess.run(['bash', str(INSTALL), '--render-only', str(tmp_path), '--site', 'jammy-x'])
    assert result.returncode == 2


@pytest.mark.parametrize(('site', 'address'), [
    ('jammy-a', '10.11.0.130:9100'),
    ('jammy-b', '10.21.0.130:9100'),
    ('jammy-c', '10.31.0.130:9100'),
])
def test_data_vm_node_job(tmp_path, site, address):
    subprocess.run(['bash', str(INSTALL), '--render-only', str(tmp_path), '--site', site], check=True)
    config = yaml.safe_load((tmp_path / 'etc/prometheus.yml').read_text())
    jobs = {job['job_name']: job for job in config['scrape_configs']}
    assert jobs['node_datavm']['static_configs'] == [{'targets': [address], 'labels': {'layer': 'vm'}}]
    assert jobs['node']['static_configs'] == [{'targets': ['127.0.0.1:9100'], 'labels': {'layer': 'host'}}]


def test_host_dashboards_select_host_node_job_only():
    """Data VM node_exporter series (job=node_datavm) must not leak into host panels."""
    import json
    import re
    from pathlib import Path

    dashboards = Path(__file__).resolve().parents[1] / "hub" / "grafana" / "dashboards"
    for name in ("jammy-noc", "jammy-vms", "jammy-network"):
        text = json.dumps(json.loads((dashboards / f"{name}.json").read_text(encoding="utf-8")))
        for selector in re.findall(r"\bnode_[a-zA-Z0-9_]+\{([^}]*)\}", text):
            assert 'job=\\"node\\"' in selector or 'job=\\"node_datavm\\"' in selector, (name, selector)
