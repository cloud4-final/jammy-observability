# Jammy Central Observability Hub (`jammy-obs`)

중앙 관측 허브는 `jammy-obs` 호스트에 배포되어 거점(jammy-a, jammy-b, jammy-c)의 메트릭·로그·트레이스를 집약하고, 외부 ICMP 프로브 및 Grafana 대시보드(NOC), Alertmanager 알림을 제공합니다.

---

## 1. 아키텍처 및 서비스 구성

Docker Compose 기반의 단일 노드 스택으로 동작하며, 모든 서비스는 `network_mode: host`로 실행됩니다.

| 서비스 | 리슨 주소 | 외부 노출(tailscale0) | 역할 |
|---|---|---|---|
| **Prometheus** | `0.0.0.0:9090` | 예 | 시계열 수집, remote-write receiver, 알림 평가 |
| **Alertmanager** | `0.0.0.0:9093` | 예 | 알림 라우팅, Slack `#jammy-alerts` Incoming Webhook 전송 (클러스터 비활성화) |
| **Loki** | http `0.0.0.0:3100`<br>grpc `127.0.0.1:9096` | 예 (3100) | 로그 수집 엔진 (v13 tsdb + filesystem) |
| **Tempo** | http `127.0.0.1:3200`<br>grpc `127.0.0.1:9097`<br>OTLP `0.0.0.0:4317`/`0.0.0.0:4318` | 예 (4317/4318) | 분산 추적 백엔드 (OTLP 수신, 72h 보관) |
| **Grafana** | `0.0.0.0:3000` | 예 | NOC 대시보드 및 탐색 UI |
| **Blackbox Exporter** | `127.0.0.1:9115` | 아니오 (내부 전용) | 거점 ICMP Ping 프로브 (SSH 프로브는 제약 참조) |
| **node_exporter** | `127.0.0.1:9100` | 아니오 (내부 전용) | jammy-obs 호스트 리소스 메트릭 |

> **보안 모델 및 방화벽:**
> - 호스트 ufw 정책: 물리 NIC에서는 22/tcp만 허용, `tailscale0` 인터페이스를 통한 Tailnet 내부 트래픽만 스택 포트에 접근 가능합니다.
> - 내부 전용 포트(`3200`, `9096`, `9097`, `9115`, `9100`)는 설정 파일에서 명시적으로 `127.0.0.1`에 바인드되어 외부 네트워크 및 Tailnet에 직접 노출되지 않습니다.
> - **Loki 인증:** `auth_enabled: false`로 설정되어 있으며, 외부 노출 없이 Tailscale WireGuard 암호화 및 Tailnet ACL로 수신 구간을 보호합니다.

---

## 2. 수집 및 연동 엔드포인트

거점 에이전트 및 애플리케이션은 MagicDNS 논리 도메인(`jammy-obs`)을 통해 중앙 허브로 데이터를 전송합니다:

- **Metrics (Remote Write):** `http://jammy-obs:9090/api/v1/write`
- **Logs (Loki Push API):** `http://jammy-obs:3100/loki/api/v1/push`
- **Traces (OTLP gRPC):** `jammy-obs:4317`
- **Traces (OTLP HTTP):** `http://jammy-obs:4318`
- **Grafana Web UI:** `http://jammy-obs:3000`

---

## 3. 디렉터리 레이아웃 및 볼륨

호스트 파일시스템의 `/opt/jammy-obs` 하위에 모든 데이터와 설정, 비밀값이 격리 보관됩니다:

```text
/opt/jammy-obs/
├── stack/              # Compose 및 서비스별 설정 파일 (rsync 배포)
│   ├── hub/
│   │   ├── compose.yaml
│   │   ├── prometheus/
│   │   ├── alertmanager/
│   │   ├── loki/
│   │   ├── tempo/
│   │   └── grafana/
│   └── alerts/         # Prometheus Alert 규칙
├── data/               # 서비스별 영속 데이터 볼륨
│   ├── prometheus/
│   ├── alertmanager/
│   ├── loki/
│   ├── tempo/
│   └── grafana/
└── secrets/            # 권한 700 격리 비밀 파일 (Git 커밋 절대 금지)
    ├── grafana_admin_password
    └── slack_webhook_url
```

---

## 4. 배포 및 운영

### 배포 스크립트 실행
SSH 기본 접속 사용자는 `yang`이며, 환경변수 `SSH_USER` 또는 `--ssh-user <user>` 옵션으로 변경할 수 있습니다.

```bash
# 기본 배포 (jammy-obs 호스트로 rsync 및 compose up)
./hub/deploy.sh

# 대상 호스트 지정 배포
./hub/deploy.sh --host jammy-obs

# SSH 사용자 지정 배포
./hub/deploy.sh --ssh-user yang

# 데모 백엔드 및 모빌리티 수집기 포함 배포 (로컬 소스 지정)
./hub/deploy.sh --demo --collector-src ../jammy-collector

# 데모 백엔드 원격 이미지 지정 배포 (COLLECTOR_IMAGE 환경변수 사용 시 docker pull)
COLLECTOR_IMAGE="myregistry/jammy-collector:v1.0" ./hub/deploy.sh --demo
```

### 배포 후 상태 점검 및 검증
배포 스크립트는 기동 후 120초 동안 다음 엔드포인트의 정상 응답(HTTP 200)을 검증합니다:
- `http://127.0.0.1:9090/-/ready`
- `http://127.0.0.1:9093/-/ready`
- `http://127.0.0.1:3100/ready`
- `http://127.0.0.1:3200/ready`
- `http://127.0.0.1:3000/api/health`
- `http://127.0.0.1:9115/-/healthy`

#### Alertmanager Datasource 상태 검증
Grafana 내부에서 Alertmanager datasource `/health` 테스트 시 500(`plugin.unavailable`) 오류가 발생하는 것은 플러그인 헬스체크 구현상의 제한입니다. Alertmanager 연동 상태는 프록시 엔드포인트로 확인합니다:
```bash
curl -s -u admin:<password> http://127.0.0.1:3000/api/datasources/proxy/uid/alertmanager/api/v2/status
```
또는 Grafana UI에서 `/api/datasources/proxy/uid/alertmanager/api/v2/status` 경로를 통해 HTTP 200과 Alertmanager 클러스터 상태를 확인합니다.

#### Grafana 대시보드 실데이터 검증 (check_dashboards.sh)
배포된 대시보드 4종(`jammy-noc`, `jammy-network`, `jammy-vms`, `jammy-app`)의 템플릿 변수 기본값(`current.value`), 변수 쿼리 실행 결과 및 모든 패널의 PromQL/LogQL 시계열 수신 상태를 검증합니다:
```bash
# jammy-obs 호스트에서 직접 실행
bash /opt/jammy-obs/stack/hub/check_dashboards.sh

# 또는 로컬에서 SSH로 원격 실행
ssh yang@jammy-obs bash /opt/jammy-obs/stack/hub/check_dashboards.sh
```

### Grafana 접속법
현재 Tailscale ACL이 팀원 기기→obs를 22/ICMP만 허용하므로, 브라우저 직접 접근이 차단됩니다. 아래와 같이 SSH 로컬 포트 포워딩을 수행한 후 접속합니다:
```bash
ssh -L 3000:127.0.0.1:3000 yang@jammy-obs
```
터널링 수립 후 웹 브라우저에서 `http://localhost:3000`에 접속합니다.

---

## 5. 제약 및 주의사항

- **obs→거점 TCP 프로브는 ACL 허용 후 추가**: Tailscale ACL이 `tag:obs` → 거점(jammy-a, jammy-b, jammy-c) TCP 22를 차단(obs에서 `dial tcp4 ...:22: i/o timeout` 발생, 반면 ICMP는 0% 패킷 손실로 정상)하므로 `blackbox_ssh` job은 상시 Down 경보를 유발하여 제거되었습니다. obs→거점 TCP 프로브는 ACL 허용 후 추가해야 합니다.

