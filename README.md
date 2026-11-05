# Jammy Observability Stack

3거점 하이브리드 모빌리티 데이터 플랫폼을 위한 중앙 집중식 관측성(Metrics, Logs, Traces, Alerts) 스택입니다.

---

## 1. 저장소 구성

- `hub/`: 중앙 관측 허브 (`jammy-obs` 호스트 배포 스택: Prometheus, Alertmanager, Loki, Tempo, Grafana, Blackbox Exporter, Node Exporter, Demo Collector)
- `site/`: 물리 거점 호스트(`jammy-a`, `jammy-b`, `jammy-c`) 에이전트 번들 (Prometheus Agent, Grafana Alloy, Node Exporter, Blackbox Exporter)
- `alerts/`: Prometheus 경보 및 레코딩 규칙 정의와 단위 테스트 (`rules.yml`, `rules.test.yml`)
- `tests/`: 관측 스택 설정, Docker Compose 명세, 거점 에이전트 렌더링 검증 자동화 테스트 (`pytest`)

---

## 2. 메트릭 레이블 규약 (Label Governance)

카디널리티 폭증 방지 및 다차원 필터링을 위한 공통 레이블 규약입니다.

| Label 키 | 허용 값 예시 | 설명 |
|---|---|---|
| `site` | `jammy-a`, `jammy-b`, `jammy-c`, `jammy-obs` | 호스트 및 거점 식별자 |
| `layer` | `host`, `vm`, `k8s-node`, `pod`, `app` | 인프라 및 애플리케이션 계층 구분 |
| `vantage` | `jammy-obs`, `jammy-a`, `jammy-b`, `jammy-c` (또는 빈 문자열 `""`) | 외부 프로브 관측 시점 (vantage=""는 로컬/거점 수집 메트릭) |
| `target_site` | `jammy-a`, `jammy-b`, `jammy-c` | 블랙박스 프로브 대상 거점 식별자 |

> **⚠️ 카디널리티 주의 규칙**:
> `event_id`, `vehicle_id`, `trace_id` 등 고유 식별자는 Prometheus 메트릭 레이블에 절대 포함하지 않습니다. (고유 식별자는 Loki 구조화 로그 및 Tempo 분산 추적으로만 추적)

---

## 3. 빠른 시작 (Quick Start)

### 3.1 중앙 허브 배포
SSH 접속 기본 사용자는 `yang`이며, 환경변수 `SSH_USER` 또는 `--ssh-user <user>` 옵션으로 변경할 수 있습니다.

```bash
# 기본 중앙 허브 배포
./hub/deploy.sh

# 데모 백엔드 포함 배포 (로컬 체크아웃 소스 기반)
./hub/deploy.sh --demo --collector-src ../jammy-collector

# 데모 백엔드 원격 이미지 지정 배포 (COLLECTOR_IMAGE 환경변수 활용)
COLLECTOR_IMAGE="myregistry/jammy-collector:v1.0" ./hub/deploy.sh --demo
```

### 3.2 Smoke E2E 검증
```bash
# 중앙 허브에서 메트릭, 로그, 트레이스 4종 왕복 검증
ssh yang@jammy-obs bash /opt/jammy-obs/stack/hub/smoke.sh
```

### 3.3 Grafana 대시보드 터널링
Tailnet 보안 정책(스택 포트 직접 노출 차단)에 따라 SSH 로컬 포트 포워딩으로 접근합니다:
```bash
ssh -L 3000:127.0.0.1:3000 yang@jammy-obs
```
터널 수립 후 웹 브라우저에서 `http://localhost:3000`에 접속합니다.
(초기 관리자 계정: `admin`, 암호: `jammy-obs` 호스트의 `/opt/jammy-obs/secrets/grafana_admin_password`)

---

## 4. 관련 저장소 (Related Repositories)

- 모빌리티 이벤트 수집 백엔드: [cloud4-final/jammy-collector](https://github.com/cloud4-final/jammy-collector)
- 상위 모노레포: [cloud4-final/hybrid-5th](https://github.com/cloud4-final/hybrid-5th)
