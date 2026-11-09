import json
from pathlib import Path


def test_network_rows_and_repeats():
    dashboard = json.loads((Path(__file__).resolve().parents[1] / 'hub/grafana/dashboards/jammy-network.json').read_text())
    rows = [panel for panel in dashboard['panels'] if panel['type'] == 'row']
    assert [r['title'] for r in rows] == ['Probe matrices', 'Site → Site RTT', 'Uplink (Wi-Fi / internet)', 'Tailscale (tailscale0)', 'VM bridges (br-vm, br-data)', 'Wired NIC (eno1 / enp2s0)', 'Errors & drops', 'TCP retransmits']
    assert [r['collapsed'] for r in rows] == [False, False, False, False, True, True, True, True]
    panels = dashboard['panels'] + [p for row in rows for p in row.get('panels', [])]
    assert any(p.get('repeat') == 'vantage' and 'vantage=~"$vantage"' in p['targets'][0]['expr'] for p in panels)
    assert sum(p.get('repeat') == 'site' for p in panels) >= 5
