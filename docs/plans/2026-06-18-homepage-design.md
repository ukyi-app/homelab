# Homepage 대시보드 추가 — 설계

- 날짜: 2026-06-18
- 상태: 사용자 승인 완료(브레인스토밍 HARD-GATE 통과)
- 후속: writing-plans → codex 적대적 리뷰(hardened-planning) → executing-plans 핸드오프

## 배경 / 동기

운영자가 홈랩의 모든 서비스를 **한 화면에서** 보는 단일 진입점이 없다. 현재 관측 스택
(victoria-stack)은 화이트박스 메트릭·로그·알림 중심이고, Grafana는 내부 메모리 예산
대시보드뿐이다. "여러 앱을 한 곳에서 보는 카탈로그/런처 + 가벼운 상태"라는 운영자 DX 갭을
Homepage(gethomepage.dev)로 메운다. 업타임 SLA/히스토리(=Gatus류)는 **비목표** — 그건 그대로
vmalert/Grafana 몫이며, Homepage는 진입점·런처·가벼운 상태 표시에 한정한다.

## 승인된 핵심 결정

| 축 | 결정 |
|---|---|
| 기능 범위 | **중간** — 서비스 타일(링크+아이콘) + pod up/down + 인프라 요약 위젯 몇 개 |
| 노출 호스트 | **dash.home.ukyi.app** (`*.home.ukyi.app` 와일드카드 cert에 그대로 포함) |
| 네임스페이스 | **전용 `homepage` ns** (PSA restricted 목표) |
| 발견 모델 | **HTTPRoute annotation 자동발견** (`gateway: true` + 기존 HTTPRoute에 annotation) |
| 배포 메커니즘 | **plain manifest + kustomize** (adguard 동형, platform 표준) |

## §1. 목적 / 범위

- 운영자 단일 진입점 대시보드(내부 전용: tailnet/LAN).
- 모든 서비스를 타일로 표시(아이콘+링크), 가벼운 up/down, 핵심 인프라 요약.
- 비목표: 업타임 SLA·히스토리·알림(기존 스택 담당), 외부 공개, 사용자 대면 상태페이지.

## §2. 배포 메커니즘 (접근법 + 추천)

- A. 공유 차트(`platform/charts/app` kind:service): **기각** — 공유 차트는 외부 앱용으로
  ClusterRole을 만들지 않고, Homepage의 config mount·위젯 구조가 차트 범위 밖.
- B. 공식 Homepage Helm 차트: **기각** — ArgoCD `chart:`/repoURL/semver 규약 함정 +
  netpol/PSA/원장 커스터마이즈를 values로 우회 + 벤더 차트 캐시 관리 부담.
- **C. plain manifest + kustomize (adguard 동형): 채택** — platform 표준. ClusterRole·ConfigMap·
  HTTPRoute를 직접 통제, appset 자동발견, 원장/netpol/PSA를 명시 통제.

## §3. 아키텍처 / 컴포넌트

```
platform/homepage/prod/
├── kustomization.yaml          # namespace: homepage
├── deployment.yaml             # ghcr.io/gethomepage/homepage, digest 핀
├── service.yaml                # ClusterIP :3000
├── httproute.yaml              # dash.home.ukyi.app → :3000 (web-internal-tls)
├── configmap.yaml              # settings.yaml/services.yaml/widgets.yaml/bookmarks.yaml/kubernetes.yaml
├── rbac.yaml                   # ServiceAccount + ClusterRole(read-only) + ClusterRoleBinding
└── test_render.bats
```

- `platform/namespaces/prod/namespaces.yaml`에 `homepage` ns 추가(SSOT). PSA **restricted 목표**.
- ArgoCD `platform-components` appset이 `platform/homepage/prod`를 자동 발견(destination.namespace는
  appset에 없으므로 kustomization.yaml의 `namespace: homepage`와 namespaces SSOT가 권위).

## §4. 서비스 발견 (자동)

- `kubernetes.yaml`: `mode: cluster` + **`gateway: true`**(Gateway API HTTPRoute 발견 활성).
- 기존 **argocd / adguard / grafana HTTPRoute에 `gethomepage.dev/*` annotation 추가**
  (`enabled`/`name`/`group`/`icon` + `pod-selector`로 상태). annotation-only 변경이라 기존 컴포넌트
  sync에 무해(SSA atomic list 미접촉 — metadata만).
- 향후 공유 차트가 만드는 앱 HTTPRoute에 annotation만 넣으면 카탈로그 자동 확장.

## §5. 기능 범위 (중간)

- 서비스 타일 + 링크 + **pod up/down**(pod-selector, metrics 불요).
- **인프라 요약 위젯은 VictoriaMetrics 쿼리(customapi/prometheusmetric)로** 구현 —
  `metrics-server` 의존을 회피한다. 이유: 이미 node-exporter/kube-state-metrics가 vmsingle에
  적재되어 PromQL로 동일 숫자를 산출할 수 있고, 이 스택에 더 정합적이다.
- 위젯 2~4개(예): 노드 CPU/메모리 사용률, **메모리 예산 사용**(원장 8704Mi 대비 limit 합계),
  CNPG/핵심 헬스 1~2개. (정확한 PromQL은 plan에서 확정.)

## §6. 보안 / 경계

- **ClusterRole 최소권한(read-only)**: `gateway.networking.k8s.io/httproutes` + core
  `pods,namespaces,nodes`(list/watch)만. 전-ns 발견 때문에 ClusterRole은 불가피하나 read 전용.
- **신규 homepage NetworkPolicy**(default-deny + 명시 egress): DNS(kube-system:53),
  kube-apiserver(발견), vmsingle(observability HTTP read). ingress: gateway ns → :3000.
  (AGENTS.md `ipBlock`에 pod CIDR 금지 함정 준수 — 노드/특정 대상만 좁혀 허용.)
- **시크릿: 0개 예상** — 중간 범위는 전부 내부 read-only(VM 무인증·k8s는 SA 토큰)라
  SealedSecret 불필요. 외부 인증 위젯 도입 시에만 추가.
- DNS: `*.home.ukyi.app` 와일드카드 cert + AdGuard split-horizon rewrite가 `dash`를 자동 커버 →
  별도 cert SAN/DNS 작업 불요.

## §7. 메모리 예산 / sync-wave

- Homepage ~64–128Mi → **docs/memory-ledger.md에 homepage 행 추가**(CI 게이트 필수, limit 합계
  ≤ 8704Mi 유지). 현재 여유 984Mi 내.
- sync-wave **기본 0**(Gateway는 wave -8에 이미 Programmed). 단일 Application이라 내부 wave 불필요
  (AGENTS.md: 내부 wave는 꼭 필요할 때만).

## §8. 에러처리 / 엣지케이스 / 리스크

- **PSA restricted 이미지 비호환 가능** — gethomepage가 non-root/read-only-rootfs를 거부하면
  baseline ns로 fallback. plan에서 이미지 라이브 검증으로 확정.
- VM 위젯 쿼리 실패 → 해당 위젯만 빈 값(대시보드 본체는 동작).
- 기존 HTTPRoute annotation 추가가 SSA atomic list를 안 건드림(metadata-only) 확인.

## §9. 테스트 전략

- **렌더 게이트**: `kustomize build` → kubeconform(test_render.bats), `make verify`(원장 conftest).
- **라이브**(plan 실행 후): dash.home.ukyi.app 200 · 타일 렌더 · 위젯 데이터 · pod 상태 ·
  netpol(homepage→vmsingle/apiserver 허용, 그 외 deny).

## 미해결 항목 (plan에서 정밀화)

1. gethomepage 이미지의 PSA restricted 호환(runAsNonRoot/read-only-rootfs/포트<1024 여부).
2. ClusterRole 정확한 apiGroups/resources/verbs(HTTPRoute 발견 + pod-selector 상태에 필요한 최소).
3. 인프라 요약 위젯의 구체 PromQL 쿼리 + vmsingle service DNS/포트.
4. homepage NetworkPolicy egress 대상(kube-apiserver 주소·vmsingle 포트) 정밀화.
5. 기존 argocd/adguard/grafana HTTPRoute 파일에 annotation 추가 시 그룹/아이콘/pod-selector 스킴.
