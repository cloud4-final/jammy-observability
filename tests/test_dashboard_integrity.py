import json
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DASHBOARDS = ROOT / 'hub/grafana/dashboards'


def test_dashboard_integrity():
    paths = sorted(DASHBOARDS.glob('*.json'))
    assert (DASHBOARDS / 'jammy-db.json') in paths
    sources = yaml.safe_load((ROOT / 'hub/grafana/provisioning/datasources/datasources.yaml').read_text(encoding='utf-8'))
    valid_uids = {item['uid'] for item in sources['datasources']}
    for path in paths:
        dashboard = json.loads(path.read_text(encoding='utf-8'))
        variables = {v['name'] for v in dashboard.get('templating', {}).get('list', [])}
        ids = set()
        def check_panels(panels):
            for panel in panels:
                assert panel['id'] not in ids, (path, panel['id'])
                ids.add(panel['id'])
                if panel.get('repeat'):
                    assert panel['repeat'] in variables, (path, panel['repeat'])
                strings = [panel.get('title', '')]
                for target in panel.get('targets', []):
                    datasource = target.get('datasource', panel.get('datasource', {}))
                    assert isinstance(datasource, dict) and datasource.get('uid') in valid_uids, (path, panel['title'])
                    strings.append(target.get('expr', ''))
                for string in strings:
                    for name in re.findall(r'\$([a-zA-Z_][a-zA-Z_0-9]*)', string):
                        assert name.startswith('__') or name in variables, (path, name)
                check_panels(panel.get('panels', []))
        check_panels(dashboard.get('panels', []))


def test_host_node_queries_exclude_data_vm():
    for name in ('jammy-noc', 'jammy-vms', 'jammy-network'):
        dashboard = json.loads((DASHBOARDS / f'{name}.json').read_text(encoding='utf-8'))
        def check(panels):
            for panel in panels:
                for target in panel.get('targets', []):
                    expr = target.get('expr', '')
                    for selector in re.findall(r'\bnode_[a-zA-Z0-9_]+\{([^}]*)\}', expr):
                        # Data VM series are allowed only when selected explicitly.
                        assert re.search(r'(?:^|,)\s*job="(?:node|node_datavm)"\s*(?:,|$)', selector), (name, panel['title'], expr)
                check(panel.get('panels', []))
        check(dashboard['panels'])
