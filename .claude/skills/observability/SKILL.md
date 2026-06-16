---
name: observability
description: 이 홈랩 레포의 관측 스택(victoria-stack)을 디버그할 때 사용. 메트릭/로그/알림이 안 흐를 때, telegram 알림 검증, PVC 포화 판단, vmalert 룰 확인. distroless·service DNS 질의 함정 포함. read-only. VictoriaLogs·vmalert·Alertmanager·메트릭 누락·로그 수집 키워드에 반응.
---

# 관측성 디버그 (victoria-stack)

라이브 read-only 진단. `eval "$(make kubeconfig)"`로 KUBECONFIG 설정. 알림 자체(victoria-stack 룰)는 운영 중이므로, 이 스킬은 **임시 질의·경로 단절 진단**에 집중한다.

## distroless 함정 (핵심)
- `vmsingle`(메트릭 :8428)·`victorialogs`(로그 :9428)는 **StatefulSet + distroless** — `sh`/`wget`이 없어 그 파드 안에서 질의 불가.
- 질의는 **`vmagent`(Deployment, 셸 있음) 파드에서 service DNS로**:
  ```bash
  kubectl -n observability exec deploy/vmagent -- wget -qO- 'http://vmsingle:8428/api/v1/query?query=up'
  ```
- exec 가능 파드(Deployment): vmagent · vmalert · alertmanager · grafana.

## 증상 → 질의
- **로그가 안 쌓임(수집 0)** → VL `vl_rows_ingested_total{type="elasticsearch_bulk"}`. 0이면 vector→VL 경로 단절. **vector는 root로 실행해야** `/var/log/pods/**/*.log`(root:root 0640)를 읽는다 — nobody면 조용히 0(healthcheck disabled라 에러도 안 뜸).
  ```bash
  kubectl -n observability exec deploy/vmagent -- wget -qO- 'http://victorialogs:9428/select/logsql/...'  # 또는 vmsingle에서 vl_rows_ingested_total
  ```
- **vmalert 룰/알림 상태** → `http://vmalert:8880/api/v1/rules` (신버전 경로. `/api/v1/groups`는 400).
- **telegram 알림 전송 검증** → 로그가 아니라 메트릭으로:
  `alertmanager_notifications_total{integration="telegram"}` 와 `alertmanager_notifications_failed_total{integration="telegram"}`. 봇 토큰은 메인 컨테이너 env가 아니라 **init이 렌더한 alertmanager.yml의 `bot_token_file`**에 있다(직접 전송 테스트는 secret을 envFrom한 임시 파드로). AM은 동적값을 자동 HTML-escape하므로 템플릿에서 수동 escape 금지(이중 escape 버그).
- **PVC/디스크 포화** → **모든 PV가 hostPath라 `kubelet_volume_stats_*`는 영구 부재**. 대신 `node_filesystem_avail_bytes{mountpoint="/"}`(루트 fs) + CNPG `cnpg_collector_pg_wal`(WAL 볼륨 충전율). 외장 SSD는 virtiofs라 VM에서 측정 불가.
- **CPU/메모리 사용량** → hostPath라 `kubectl top`이 신뢰 불가 → Grafana 대시보드 `uid=homelab-resources`.

## 진단 후
- ConfigMap(relay 스크립트 등) 변경은 파드 자동 재시작이 없다 → `kubectl rollout restart`.
- `envFrom` 시크릿 변경도 파드 재시작이 있어야 반영.
- 매니페스트 확인은 `make render COMP=victoria-stack`(= `kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/victoria-stack/prod`, SOPS_AGE_KEY_FILE 설정 후). victoria-stack도 이제 `<comp>/prod/` 규약을 따른다(W2에서 flat→prod/ 표준화 — `make render COMP=`의 `/prod` 가정과 일치).
- 시크릿 값/`*.enc.yaml` 평문은 출력하지 않는다.
