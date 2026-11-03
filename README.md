# Observability Architecture & Metrics Taxonomy

3거점 하이브리드 모빌리티 데이터 플랫폼의 관측성(Metrics, Logs, Alerts) 표준 및 자동 발견 설계입니다.

---

## 1. 관측 계층 및 수집 구조

```text
[ Physical Host ]
  ├── node_exporter (Host CPU, RAM, Disk, NIC)
  └── libvirt_exporter (KVM 통신: VM 생성·삭제·자원 사용량 자동 감지)
        │
        ├── [ Control Plane VM ] ── node_exporter
        ├── [ Application VM ]   ── node_exporter + k3s (kubelet/cAdvisor)
        │                             └── Application Pods (/metrics)
        └── [ Data VM ]          ── node_exporter + postgres_exporter
                                      │
                                      ▼
                      [ Site Collector (Alloy / Prometheus Agent) ]
                             (로컬 디스크 버퍼 / WAL 보존)
                                      │
                            Tailscale Mesh VPN
                                      │
                                      ▼
                      [ Central Hub (32GB Observability PC) ]
                         - Prometheus (Metrics Storage & Alerting)
                         - Loki (Log Aggregation)
                         - Grafana (Integrated Dashboard)
                         - Alertmanager -> Discord
```

---

## 2. 자동 발견 (Auto-Discovery) 전략

수동 대상 등록을 완전히 제거하기 위해 3개 레벨에서 자동 발견을 수행합니다.

### A. KVM VM 레벨 (libvirt_exporter)
- 호스트의 `/var/run/libvirt/libvirt-sock`을 마운트하여 실행.
- 신규 VM이 생성되거나 삭제될 때 별도 설정 변경 없이 `libvirt_domain_info_virtual_cpus`, `libvirt_domain_block_stats_*` 메트릭이 동적으로 수집됩니다.

### B. VM OS 레벨 (file_sd / Consul / Tailscale DNS)
- 각 VM 프로비저닝 시 cloud-init / Ansible을 통해 `node_exporter`를 9100 포트로 자동 기동.
- Site Collector는 `file_sd_configs` 또는 거점 내부 DNS/DHCP 리스트를 통해 신규 VM을 탐지합니다.

### C. Kubernetes & Container 레벨 (k8s Service Discovery)
- k3s 클러스터 내부에서는 Prometheus의 `kubernetes_sd_configs`를 활용합니다.
- `role: pod`를 설정하여 Pod 어노테이션 기반 자동 수집:
  ```yaml
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8000"
    prometheus.io/path: "/metrics"
  ```
- Deployment 파드가 스케일 아웃되거나 재시작되어도 즉시 자동 수집됩니다.

---

## 3. 메트릭 레이블 표준 (Label Governance)

카디널리티 폭증 방지 및 다차원 필터링을 위한 공통 레이블 규약입니다.

| Label 키 | 허용 값 예시 | 설명 |
|---|---|---|
| `site` | `site-a`, `site-b`, `site-c`, `aws`, `central` | 거점 식별자 |
| `layer` | `host`, `vm`, `k8s-node`, `pod`, `app` | 인프라 계층 구분 |
| `role` | `control-plane`, `app`, `db`, `edge`, `collector` | 노드 역할 |
| `service` | `mobility-collector`, `snapshot-query`, `haproxy` | 서비스 식별자 |

> **⚠️ 카디널리티 주의 규칙**:
> `event_id`, `vehicle_id`, 사용자 세션 ID 등 고유 식별자는 Prometheus 메트릭 Label에 절대 포함하지 않습니다. (고유 식별자는 Loki 구조화 로그로만 추적)

---

## 4. 거점 단절 vs 서버 장애 감지 규칙

거점 회선 단절(Tailscale 또는 인터넷 장애)과 개별 서버 하드웨어 장애를 분리 감지합니다.

1. **거점 회선 단절 (`SitePartition`)**:
   - 중앙 허브에서 특정 거점의 Site Collector 및 모든 타겟이 동시에 응답하지 않을 때 발생.
   - 조치: Tailscale 터널 및 회선 점검.
2. **개별 서버 장애 (`TargetDown`)**:
   - 거점 Site Collector는 정상 통신 중이나, 특정 VM의 `up == 0` 상태가 1분 이상 지속될 때 발생.
   - 조치: KVM 도메인 및 해당 VM 프로세스 점검.
3. **단절 시 데이터 보존 (Local WAL Buffer)**:
   - 각 거점의 Site Collector는 최소 4시간 분량의 WAL을 로컬 디스크에 버퍼링합니다.
   - 회선 복구 시 누락된 메트릭을 중앙 Prometheus에 `remote_write`로 안전하게 백필합니다.
