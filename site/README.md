# 거점 Host 관측 에이전트 번들 (Site Agent Bundle)

거점 Host(`jammy-a`, `jammy-b`, `jammy-c`)에 배포되는 관측 에이전트 번들입니다.
중앙 관측 허브(`jammy-obs`)로 호스트 메트릭, 로그(journald), OTLP 트레이스 데이터를 전송하며, 로컬 48시간 시계열 보관 및 Tailscale 네트워크 장애 시 큐잉을 지원합니다.

---

## 1. 구성 요소 및 포트 구성

모든 서비스는 보안 격리를 위해 기본적으로 `127.0.0.1` 루프백 인터페이스에만 바인드됩니다.

| 구성 요소 | 역할 | 리슨 주소 | 데이터/스토리지 경로 | 비고 |
|---|---|---|---|---|
| **Prometheus** (v3.13.5) | 로컬 메트릭 수집, 48h 보관, 중앙 remote_write | `127.0.0.1:9090` | `/var/lib/jammy-obs-agent/prometheus` (5GB 제한) | `external_labels: {site: <site>}` |
| **node_exporter** (v1.12.1) | 호스트 리소스 메트릭 계측 | `127.0.0.1:9100` | - | CPU, 메모리, 디스크, 네트워크 |
| **libvirt_exporter** (0.2.0) | 호스트 KVM/QEMU 가상머신 메트릭 | `127.0.0.1:9177` | - | Ubuntu apt 패키지 (`/etc/default`) |
| **Blackbox Exporter** (v0.29.1) | 거점 간 ICMP/SSH 연결성 프로브 | `127.0.0.1:9115` | - | `CAP_NET_RAW` 권한 부여 |
| **Grafana Alloy** (v1.21.3) | journald 로그 및 OTLP 트레이스/메트릭 수집·전송 | `127.0.0.1:12345` | `/var/lib/jammy-obs-agent/alloy` | OTLP gRPC `127.0.0.1:4317`, HTTP `127.0.0.1:4318` |

> **중요 안내 (libvirt exporter 권한 및 검증):**
> 패키지 unit은 `User=prometheus`로 구동되므로 Host 그룹 변경 없이 읽기 전용 소켓(`ARGS="--web.listen-address=127.0.0.1:9177 --libvirt.uri=qemu:///system?socket=/var/run/libvirt/libvirt-sock-ro"`)을 사용합니다.
> 설치 후 `curl -s 127.0.0.1:9177/metrics | grep libvirt_up`로 확인하며, 실패 시 libvirt 읽기 전용 소켓 권한을 점검합니다.

> **중요 안내 (OTLP 수신 포트 바인딩):**
> 현재 Alloy의 OTLP 수신 포트(`4317`, `4318`)는 `127.0.0.1` 루프백에만 바인드되어 있습니다.
> 거점 K8s(k3s) Pod에서 발생하는 애플리케이션 트레이스를 호스트 Alloy로 직접 수집하기 위해 `br-vm` 가상 브릿지 인터페이스 바인딩이 필요할 경우 네트워크 보안 정책에 따라 별도로 전환합니다.

---

The site agent also scrapes its local Data VM postgres_exporter on port 9187 using the site-specific address configured by `install.sh`. The `postgres` and `node_datavm` jobs use `layer: vm` and forward metrics through the existing remote write; `node_datavm` scrapes the same Data VM on port 9100. The host `node` job remains separate with `layer: host`.

## 2. 디렉토리 구조 및 설치 경로

```
/opt/jammy-obs-agent/
├── bin/                       # prometheus, node_exporter, blackbox_exporter, alloy
└── etc/                       # prometheus.yml, config.alloy, blackbox.yml, probes.yml

/var/lib/jammy-obs-agent/
├── prometheus/                # Prometheus TSDB 데이터 (obsagent 소유)
└── alloy/                     # Alloy 스토리지 경로 (obsagent 소유)

/etc/systemd/system/
├── jammy-prometheus.service
├── jammy-node-exporter.service
├── jammy-blackbox.service
└── jammy-alloy.service
```

모든 systemd 유닛은 첫 줄에 `# managed-by: jammy-obs-agent` 주석이 표기되며, 보안 강화를 위해 비특권 시스템 사용자 `obsagent`(nologin), `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`가 적용됩니다.

---

## 3. 스크립트 사용법

### 3.1 `install.sh` (설치 스크립트)

```bash
# 설정 파일 템플릿만 렌더링 검증 (비특권 실행 가능)
bash install.sh --render-only /tmp/test-render --site jammy-a --obs-host jammy-obs

# 사전 점검 및 설치 계획 확인 (Dry-Run, 변경 없음)
sudo bash install.sh --site jammy-a --dry-run

# 서비스 자동 기동 없이 설치만 수행
sudo bash install.sh --site jammy-a --no-start

# 실제 설치 및 서비스 기동 (설치 승인 후 실행)
sudo bash install.sh --site jammy-a

# 삭제 (설치 파일 및 유닛 정리)
sudo bash install.sh --site jammy-a --uninstall

# 완전 삭제 (저장된 TSDB 데이터까지 완전 삭제)
sudo bash install.sh --site jammy-a --uninstall --purge
```

**종료 코드(Exit codes):**
- `0`: 성공
- `1`: 권한 부족 (root 필요)
- `2`: 잘못된 파라미터 (유효하지 않은 `--site` 등)
- `3`: 충돌 감지 (이미 사용 중인 포트 또는 비관리 systemd 유닛 존재)
- `4`: SHA256 체크섬 검증 실패

### 3.2 `deploy.sh` (원격 배포 스크립트)

```bash
# 거점 호스트에 Dry-Run 테스트 (--apply가 없으면 기본 dry-run)
./deploy.sh jammy-a

# 거점 호스트에 실제 배포 적용 (사용자 승인 후)
./deploy.sh jammy-a --apply
```
