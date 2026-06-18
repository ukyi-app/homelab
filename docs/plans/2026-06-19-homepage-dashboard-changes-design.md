# 설계: Homepage 대시보드 변경 (설정 개선 + Glances 배포)

- 날짜: 2026-06-19
- base: `f84fd87` (#67 — homepage Ops 북마크 제거 + argocd 아이콘)
- 대상: `platform/homepage/prod/**`, `platform/victoria-stack/prod/**`(Glances 동거), `docs/memory-ledger.md`
- 스택: gethomepage **v1.13.2**, k3s 단일 노드(OrbStack VM), ArgoCD GitOps
- 상태: **승인됨** (brainstorming HARD-GATE 통과, 2026-06-19)

## 1. 배경 / 목표

라이브로 운영 중인 운영자 대시보드(`dash.home.ukyi.app`, gethomepage)에 사용자 요청 변경
9건 + 추천을 반영한다. 대부분 config-only(자동 rollout)이며, **Glances 호스트 메트릭 위젯**은
신규 워크로드 배포가 필요한 가장 큰 워크스트림이다.

## 2. 현재 상태 (base #67)

| 파일 | 내용 |
|---|---|
| `config/settings.yaml` | `title: Homelab`, `headerStyle: clean`, `layout`(Infra/Platform/Apps) |
| `config/services.yaml` | Infra 그룹 — Cluster `prometheusmetric` 위젯(vmsingle:8428) |
| `config/widgets.yaml` | `greeting`(text: Homelab) + `datetime`(format.timeStyle: short) |
| `config/kubernetes.yaml` | cluster 모드 + gateway 자동발견 |
| `bookmarks.yaml` | **#67에서 삭제됨**(Ops 북마크가 Platform 자동발견 타일과 중복이라 제거) |
| `deployment.yaml` | gethomepage v1.13.2, initContainer `seed-config`가 ConfigMap→writable emptyDir(`/app/config`) seed |
| `kustomization.yaml` | `configMapGenerator`(name=homepage) 4파일 — bookmarks 제외 |
| `networkpolicy.yaml` | default-deny + scoped egress(DNS, observability:8428, **노드서브넷 192.168.139.0/24:6443**) |

핵심 제약(라이브 검증된 함정 — `AGENTS.md`):
- **default-deny egress** — 외부 인터넷 egress 없음. 신규 egress는 scoped로만.
- ConfigMap 변경 → configMapGenerator 해시 → Deployment rollout → initContainer 재seed(F3).
- apiserver egress는 ClusterIP가 아니라 **노드 서브넷:6443**(kube-router DNAT 후 평가).
- selfHeal Application — 임시 patch는 reconcile에 원복 → **PR로만**.
- observability ns는 **PSA privileged**(node-exporter hostPID/hostPath용)이며 **default-deny ingress가 없다**
  (victoria-stack에 NetworkPolicy 0개; network-policies 컴포넌트는 prod/database/cache만 커버).

## 3. 결정 요약

| # | 요청 | 결정 |
|---|---|---|
| 1 | 배경화면 변경 | **레포 번들 로컬 이미지** (`/app/public/images`), ≤700KiB 최적화 |
| 2 | headerStyle: boxedWidgets | settings 1줄 |
| 3 | target: _blank | settings 1줄 (전역 — 외부 링크 새 탭) |
| 4 | searchDescriptions on | `quicklaunch.searchDescriptions: true` |
| 5 | 로고 추가 | **아이콘만**(클릭 링크 철회). `logo` info 위젯, icon=github 아바타 |
| 6 | healthchecks | **보류** — 외부 egress(SaaS, CDN이라 ipBlock 불가)·신규 시크릿 도입 안 함 |
| 7 | time format | `datetime.format`에 `hourCycle: h23` 추가(`timeStyle: short` 유지) |
| 8 | Glances 추가 | **신규 배포** + 위젯. observability(victoria-stack) **동거**(node-exporter 패턴) |
| 9 | 추가 추천 | `hideVersion`, `statusStyle: dot`, `useEqualHeights` (no-egress 자세 유지) |
| 10 | title → ukyi | settings + bats 단언 동반 수정 |
| 11 | 북마크 추가 | **bookmarks.yaml 재도입** — GitHub(ukkiee) + Instagram(ukyi_) |

확정 입력: github=`ukkiee`(https://github.com/ukkiee), instagram=`ukyi_`(https://instagram.com/ukyi_).

## 4. 상세 설계

### A. `config/settings.yaml`

```yaml
title: ukyi                    # Homelab → ukyi
headerStyle: boxedWidgets      # clean → boxedWidgets
target: _blank                 # 전역: 외부 링크 새 탭
quicklaunch:
  searchDescriptions: true     # 설명까지 검색
background:                    # §C 로컬 번들
  image: /images/<bg-file>     # /app/public/images/<bg-file>
  blur: sm
  brightness: 75
  opacity: 50
# 추천(9번)
hideVersion: true
statusStyle: dot
useEqualHeights: true
layout:                        # 기존 유지
  Infra:    { style: row, columns: 4 }
  Platform: { style: row, columns: 4 }
  Apps:     { style: row, columns: 4 }
```

doc 검증: `boxedWidgets`/`target`/`quicklaunch.searchDescriptions`/`hideVersion`/`statusStyle`/
`useEqualHeights` 모두 gethomepage.dev 공식 문서로 확인됨.

### B. `config/widgets.yaml`

```yaml
- logo:
    icon: https://github.com/ukkiee.png   # github 아바타(클라이언트 로드, href 없음). 대안: si-github
- greeting:
    text_size: xl
    text: Homelab                          # (선택) ukyi로 변경 검토 — 실행 시 확정
- datetime:
    format:
      timeStyle: short
      hourCycle: h23
```

`logo` info 위젯은 **아이콘만 표시(클릭 링크 미지원)** — 요구(아이콘만)에 부합. 이미지는
브라우저가 클라이언트로 로드하므로 pod egress 불필요.

### C. 배경 이미지 번들 plumbing  ★ 1MiB 제약

gethomepage는 로컬 배경 이미지를 `/app/public/images/`에서 찾는다(브라우저 클라이언트 로드).
현재 config는 `/app/config`만 writable emptyDir로 seed하므로, `/app/public/images`용 경로를 추가한다.

- 별도 `configMapGenerator`(예: `homepage-bg`)에 이미지 파일을 binaryData로 담는다.
- `/app/public/images`를 writable emptyDir로 마운트하고, **두 번째 initContainer**(또는 기존
  `seed-config` 확장)가 이미지를 복사 seed한다.
  - `/app/public/images`는 gethomepage **사용자 이미지 디렉토리**라 emptyDir 마운트가 안전
    (UI 필수 자산을 가리지 않음).
- **★ ConfigMap 1MiB 한도**: binaryData는 base64라 ~33% 인플레이션 → **원본 이미지 ≤ ~700KiB**로
  최적화(WebP/리사이즈) 필요. 초과 시 더 압축하거나 (no-egress 자세를 깨는) 외부 URL로 폴백.
- 사용자가 최적화 이미지를 제공한다(실행 입력).

대안(기록): hostPath(노드에 이미지 배치) = DR-fragile/수동이라 비채택. 커스텀 이미지 빌드 = 과함.

### D. Glances 배포 — observability(victoria-stack) 동거

**추천안 채택**: Glances를 `platform/victoria-stack/prod/`에 추가(별도 컴포넌트/네임스페이스 불요).

근거:
- observability ns는 **이미 PSA privileged**(node-exporter가 hostPID/hostPath로 증명).
- Glances = 호스트 메트릭 → node-exporter와 동류. 같은 ns 동거가 일관적.
- appset은 `platform/*/prod`를 자동 Application화하지만 **victoria-stack은 제외**(수동 Application)
  → 동거 시 새 Application/ns/`platform/namespaces` 변경 모두 불요.

구성:
```yaml
# platform/victoria-stack/prod/glances.yaml (신규)
apiVersion: apps/v1
kind: Deployment            # 단일 노드라 replicas:1 (DaemonSet 불요)
metadata: { name: glances, namespace: observability }
spec:
  replicas: 1
  template:
    spec:
      hostPID: true         # 호스트 프로세스/CPU/mem 가시성 (docker --pid host 패턴)
      securityContext:
        runAsNonRoot: true  # ★ 하드 요구 — root fallback 금지(A.5#2). node-exporter는 65534로 동작
        runAsUser: 65534    # nonroot uid (node-exporter 패턴). Glances가 이 uid로 호스트 /proc 읽기 가능해야
      containers:
        - name: glances
          image: nicolargo/glances:<tag>     # 태그 핀(digest는 Renovate 후속)
          args/env: ["-w"]   # 웹서버+API 모드, 포트 61208 (--disable-webui 검토)
          ports: [{ containerPort: 61208 }]
          resources: { requests: {memory: 64Mi}, limits: {memory: 192Mi} }  # 원장 여유 856Mi 내
          securityContext:   # ★ 최소 권한 하드 경계(A.5#2)
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true       # 가능 시(불가하면 escalate, root 전환 금지)
            capabilities: { drop: [ALL] }
          volumeMounts:      # ★ 선택 metric에 필요한 최소 마운트만(A.5#2)
            - /host/proc (RO), /host/sys (RO), /etc/os-release (RO)
            # host `/`(/host/root)는 fs:/ metric을 쓸 때만 RO로 추가 + 정당화. 기본 미마운트.
      volumes: [ hostPath /proc, /sys ]   # / 는 fs metric 채택 시에만
---
apiVersion: v1
kind: Service
metadata: { name: glances, namespace: observability }
spec: { selector: {app: glances}, ports: [{ port: 61208, targetPort: 61208 }] }
```

검증 필요(plan에서 TDD/live-proof): nicolargo/glances가 **nonroot(65534)로 실행 + hostPID로 호스트
/proc 가시성** 확보 가능한지 / `-w` 활성화 방식(`GLANCES_OPT` env vs command) / fs metric 채택 시
host `/` RO 마운트 필요 여부. **★ root fallback 금지(A.5#2)** — nonroot로 필요한 metric을 못 얻으면
fallback이 아니라 설계 escalate(사용자에게 보고 후 metric 축소 또는 대안). 노출 API라 node-exporter
(비노출 scrape)보다 엄격한 경계 적용.

**netpol — egress + ingress 둘 다(A.5#1)**:
- egress: `platform/homepage/prod/networkpolicy.yaml`에 homepage→observability:61208 허용 1줄
  추가(기존 `allow-egress-to-vmsingle`는 8428 전용 — 포트 추가 또는 별도 rule).
- **★ ingress: glances pod를 선택하는 NetworkPolicy를 victoria-stack에 추가** — `:61208`을
  **homepage ns(podSelector)에서만** 허용. observability엔 ns-wide default-deny가 없어 glances :61208이
  egress 가진 모든 워크로드에 노출되므로(A.5#1), glances pod 자체에 ingress NP를 걸어 차단한다
  (NP가 glances pod를 선택하면 그 pod ingress는 명시 allow 외 default-deny가 됨). 호스트 텔레메트리
  blast radius 축소.

**메모리 원장**: `docs/memory-ledger.md`의 observability 행 증액(req +64 / limit +192) 또는 glances
전용 행 추가 → `bun run verify:ledger` GREEN(현재 limit 7848/8704, 여유 856Mi).

### E. Glances 위젯 — `config/services.yaml`

Infra 그룹에 Glances 서비스 위젯 카드 추가(metric별 1카드):
```yaml
- Infra:
    - Host:
        widget:
          type: glances
          url: http://glances.observability.svc.cluster.local:61208
          version: 4         # Glances v4 API
          metric: cpu        # 카드별: cpu / memory / fs:/ / sensor:... — 라이브 미세조정
```
(또는 `widgets.yaml` 상단 info `glances` 위젯 형태 — 실행 시 카드/info 중 택1.) homepage pod가
서버사이드로 API 호출 → §D netpol egress 필요.

### F. `config/bookmarks.yaml` 재도입 + kustomization

```yaml
# platform/homepage/prod/config/bookmarks.yaml (신규)
- Links:
    - GitHub:
        - abbr: GH
          icon: si-github
          href: https://github.com/ukkiee
    - Instagram:
        - abbr: IG
          icon: si-instagram
          href: https://instagram.com/ukyi_
```
- `kustomization.yaml` `configMapGenerator.files`에 `config/bookmarks.yaml` 추가 + #67 주석 갱신
  (외부 소셜 링크라 자동발견 Platform 타일과 **중복 아님** — #67이 제거한 사유와 무관).
- `target: _blank`(§A)로 새 탭. 외부 링크는 브라우저 클라이언트 이동이라 pod egress 무관.

## 5. 의식적 제외

- **healthchecks 위젯** — healthchecks.io(외부 SaaS) API 서버사이드 호출 = 외부 egress(CDN이라
  ipBlock 불가 → 광역 443) + 신규 read-only key SealedSecret. no-external-egress 자세 유지 위해 보류.
- **클릭형 헤더 로고**(custom.js) — gethomepage 미지원이라 community 패턴/버전 취약 → 아이콘만으로 축소.
- **weather/외부 검색 위젯** — 외부 egress 유발 → 제외.

## 6. 테스트 전략

- `platform/homepage/prod/test_homepage_config.bats`:
  - `title: Homelab` → `title: ukyi` 단언 수정.
  - 신규 가드: `headerStyle: boxedWidgets`, `target: _blank`, `searchDescriptions: true`,
    `background`(image), `hourCycle: h23`, `logo` 위젯, bookmarks의 github/instagram href.
  - **@test 이름 영어 유지**(한글 인코딩 깨짐 — 검증된 버그).
- Glances: `platform/victoria-stack/prod/`에 deployment/service 가드 bats(hostPID, ns=observability,
  포트 61208, **runAsNonRoot/65534 + capabilities drop ALL + host `/` 미마운트** — A.5#2) +
  **glances ingress NP 가드(61208을 homepage ns에서만 — A.5#1)** + homepage netpol 가드(egress 61208).
- `make verify`(원장 conftest) GREEN.
- 렌더 검증: `kustomize build platform/homepage/prod`, `kustomize build platform/victoria-stack/prod`
  (KSOPS 풀 렌더는 victoria-stack 시크릿 generator 때문에 SOPS 키 필요 — 워크트리에서 확인).

## 7. 라이브 검증 / 롤아웃 (#64·#65·#66 인시던트 교훈)

- config 변경 → configMapGenerator 해시 → Deployment rollout → initContainer 재seed로 반영.
- ★ **검증은 Ready 윈도가 아니라**: restart count 0 유지 + 시간 경과 + **실제 기능**
  (자동발견 로그 정상, Glances 위젯 데이터 표시, 배경/북마크 렌더)까지 확인.
- selfHeal Application — 라이브 임시 patch 금지, PR 머지로만 반영.
- 배경 이미지: gethomepage는 새 이미지 추가 시 컨테이너 재시작 필요(Next.js static) — rollout이 커버.

## 8. 미해결 입력 (실행 시 사용자 제공)

- 배경 이미지 파일(≤700KiB 최적화).
- greeting text(Homelab 유지 vs ukyi) — 기본 유지.
- Glances 위젯 metric 카드 구성(cpu/memory/fs 등) — 라이브 미세조정.

## 9. A.5 설계 리뷰 반영 (codex, needs-attention, 2 high — 둘 다 Accept)

- **A.5#1 (high, Accept)** Glances 호스트 API ingress 미격리 → §D에 **glances pod 선택 ingress
  NetworkPolicy(61208을 homepage ns에서만)** 추가, §F에 가드 추가. (observability ns-wide
  default-deny 부재로 인한 호스트 텔레메트리 노출 차단.)
- **A.5#2 (high, Accept·정제)** 호스트 root 마운트 + root fallback 과다 권한 → §D를 **strict
  nonroot(65534) 하드 요구(root fallback 금지)** + **선택 metric 최소 마운트(host `/`는 fs metric
  시에만 RO)**로 정정.
