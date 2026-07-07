# RBAC / SA automount 전수 감사 리포트 (메타갭 ⑤ W1-C)

**작성일:** 2026-07-06 · **목적:** 최소권한(⑤) 조치의 SSOT. Task 11(W2-C)이 이 리포트의 A/B 목록을 근거로
워크로드별 소커밋을 만든다. 정적(git grep) + 라이브(kubectl, read-only) 교차 수집.

## 요약

- 관측 스택 8개 컴포넌트가 **k8s API를 쓰지 않으면서 default SA 토큰을 마운트**한다(라이브 `tokenVol=yes` 확인).
  → **Category A**: `automountServiceAccountToken: false`로 토큰 탈취 표면 제거(무위험 — API 미사용).
- homepage만 verb 축소 여지가 있으나 이미 read-only(get/list) → **Category B**: 한계효용 낮음, 라이브 검증 후 판단.
- API 사용 워크로드(ksm/vmagent/vector/traefik/CNPG/컨트롤러류)는 automount 정당 → **Category C**: 존치.
- 공유 차트는 **이미 기본 false**(Task 10 사실상 완료 — 아래 §완료분).

## Category A — automount:false 후보 (저위험, Task 11 대상)

라이브 증거: 각 파드가 `spec.serviceAccountName=default`, `automountServiceAccountToken` 미설정(→기본 true),
projected SA 토큰 볼륨 마운트됨(`tokenVol=yes`). 정적 증거: 매니페스트에 `serviceAccountName`·API 참조 0건.

| 컴포넌트 | 파일 | kind | API 사용 | 근거 |
|---|---|---|---|---|
| grafana | `platform/victoria-stack/prod/grafana.yaml` | Deployment | 없음 | 대시보드(TSDB 질의만) — 라이브 tokenVol=yes |
| vmsingle | `platform/victoria-stack/prod/vmsingle.yaml` | StatefulSet | 없음 | TSDB — 라이브 tokenVol=yes |
| victorialogs | `platform/victoria-stack/prod/victorialogs.yaml` | StatefulSet | 없음 | 로그 저장 — 라이브 tokenVol=yes |
| vmalert | `platform/victoria-stack/prod/vmalert.yaml` | Deployment | 없음 | 룰=ConfigMap 마운트, 질의=vmsingle svc, 전송=am svc |
| alertmanager | `platform/victoria-stack/prod/alertmanager.yaml` | Deployment | 없음 | 라이브 tokenVol=yes |
| node-exporter | `platform/victoria-stack/prod/node-exporter.yaml` | DaemonSet | 없음 | hostPID·host fs만(스크레이프는 네트워크) |
| deadmanswitch-relay | `platform/victoria-stack/prod/deadmanswitch-relay.yaml` | Deployment | 없음 | busybox nc relay |
| digest-exporter | `platform/victoria-stack/prod/digest-exporter.yaml` | CronJob | 없음 | skopeo(ghcr)+curl(vmsingle) — 라이브 tokenVol=yes |

**조치(Task 11):** 각 pod spec에 `automountServiceAccountToken: false` 추가. 무해 변경(API 미사용)이라
라이브 재시작 후 Ready+기능(그라파나 대시보드 로드·알림 발송·디지트 push) 확인으로 충분.
> ⚠️ 플랜 Task 11이 명시한 5개(grafana/vmsingle/victorialogs/vmalert/alertmanager)에 더해, 라이브 감사가
> node-exporter/deadmanswitch-relay/digest-exporter 3개도 동일 무위험 후보임을 확인 — Task 11에 포함 권장.

## Category B — verb 축소 후보

| 컴포넌트 | 파일 | 현재 verbs | 판정 |
|---|---|---|---|
| homepage | `platform/homepage/prod/rbac.yaml` | `httproutes,gateways [get,list]` + `namespaces,pods,nodes [get,list]` | 이미 read-only. 축소 여지=미사용 verb(`get`) 제거 또는 resources 축소인데 위젯 실사용 verb 확인 없이는 위험. |

**조치(Task 11):** homepage는 automount:true가 정당(API 위젯 사용, CRB로 cluster-wide read). 현 verbs가 이미
get/list(변이 0)라 한계효용 낮음. Task 11에서 위젯 동작을 라이브로 확인하며 `get` 실사용 여부를 보고 **`get`
드롭 가능 시에만** 축소(불가하면 현행 유지 + 사유 기록). resources(nodes) 필요성도 위젯 라이브로 확인.

## Category C — API 사용, automount 정당 (존치 / 보고-only)

| 컴포넌트 | SA/RBAC | API 사용 사유 |
|---|---|---|
| kube-state-metrics | `victoria-stack/prod/kube-state-metrics.yaml`(CRB) | 전 리소스 watch/list(메트릭 생성) |
| vmagent | `victoria-stack/prod/vmagent.yaml`(CRB) | role:pod SD — 파드/엔드포인트 watch |
| vector | `victoria-stack/prod/vector.yaml`(CRB) | kubernetes_logs — 파드 메타 enrich |
| traefik | `traefik/prod/rbac-gateway.yaml`(CRB) | Gateway API(HTTPRoute/Gateway) watch |
| homepage | `homepage/prod/rbac.yaml`(CRB) | 위젯 발견(§B에서 verb만 재검토) |
| cache-backup | `cache/prod/backup-rbac.yaml`(Role) | valkey 인스턴스 발견/백업 오케스트레이션 |
| ensure-role-password | `cnpg/prod/ensure-role-password-rbac.yaml`(Role) | Secret 참조 검증 PostSync Job(#3 재발방지) |
| restore-drill | `cnpg/prod/restore-drill-rbac.yaml`(Role) | 복원 drill Job 오케스트레이션 |
| plugin-barman-cloud | `cnpg/barman-plugin/manifest.yaml` | **벤더 — 수정 금지**(barman-plugin manifest) |
| CNPG instance 파드(pg-1) | operator-managed | CNPG operator가 SA/토큰 관리 — 매니페스트 밖 |
| 플랫폼 컨트롤러(cnpg-operator/sealed-secrets/argocd/tailscale-operator/cert-manager) | 각 차트/매니페스트 | 컨트롤러 본질상 API watch — automount 필수 |

## 완료분 (이미 automount:false — 회귀 감시만)

`adguard`(SA-2)·`cloudflared`(SA-1)·`files`·`whoami-smoke`(SA-2)·`glances`(라이브 tokenVol 없음 확인)·
`pvc-du-exporter`(Task 2 신규) + **공유 차트 기본값**(`platform/charts/app/values.yaml:72` = false,
`test_defense.bats`가 기본 false·opt-in true 강제) → **Task 10(공유 차트 기본 false)은 사실상 완료** —
Task 11 착수 시 재확인만.

## 라이브 수집 원본(재현)

```
# Category A 토큰 마운트 증거
kubectl get pods -n observability -o json | jq '.items[] | {p:.metadata.name, sa:.spec.serviceAccountName, amt:.spec.automountServiceAccountToken}'
# CRB cluster-wide reach
kubectl get clusterrolebinding -o json | jq '.items[].subjects[]? | select(.kind=="ServiceAccount")'
```
결과(2026-07-06): observability의 grafana/vmsingle/victorialogs/vmalert/alertmanager/node-exporter/
deadmanswitch-relay/digest-exporter = `automount 미설정 + tokenVol=yes`(마운트됨). glances = tokenVol 없음.
CRB 보유 = gateway/traefik·homepage/homepage·observability/{kube-state-metrics,vector,vmagent}.
