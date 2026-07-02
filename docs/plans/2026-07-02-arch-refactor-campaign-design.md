# 아키텍처 리팩토링 캠페인 설계 (2026-07-02)

> 15차원 멀티에이전트 감사(에이전트 18 + cross-repo 1, 발견 ~75건, high/critical 전수 적대검증) 결과를
> 기반으로 한 3-웨이브 리팩토링 캠페인. 목표 = 확정 결함 해소 + 4대 페인포인트의 구조적 원인 제거.
> 디렉토리 재배치는 하지 않는다 — 분석 결과 현 구조(배포 패턴 4종·tf 3-루트·테스트 3-도메인)는 건강하며,
> 리팩토링은 계약·파이프라인·가드 수준이다.

## 0. 범위·제약 (owner 확정)

| 항목 | 결정 |
|---|---|
| 목표 | 종합 — 문제 수정 + 구조 리팩토링을 우선순위화해 단일 캠페인으로 |
| 범위 | homelab 레포 + homelab-app-template + 앱 레포(page·trip-mate-api·files) cross-repo 계약 |
| 라이브 영향 | 큰 구조 변경 허용(재싱크·재시작 감수) — 단 실제 설계는 무이동·저영향으로 수렴 |
| 페인포인트 | ① 변이 경로 복잡도 ② tools/scripts 이원화 ③ 시크릿 2원화 ④ 골든패스 한계 (전부 채택) |
| 접근 | A안: 3-웨이브 단일 캠페인 (upgrade-campaign 검증 배치 패턴) |

**성공 기준**: ① 확정 HIGH 2건 해소+재발 가드, ② 변이 1개 추가 터치 파일 7→4, ③ 원장 파서 1개·
seal 도구 1개(일괄 재봉인 모드 확보), ④ files 자동 bump 합류 + 앱 레포 release.yaml thin-caller화,
⑤ 메모리 원장 명목 잔여 196Mi→450Mi+.

## 1. 감사 결과 핵심 (증거 요약)

### 1.1 적대검증 CONFIRMED HIGH — 2건

**H1. R6 ci-staleness 알림 그룹 전체 사문화** (라이브 TSDB 대조로 확정)
- `argocd_app_info`는 어떤 경로로도 수집 불가 — vmagent pod-annotations job은 `prometheus.io/scrape`
  어노테이션 필수인데 argocd ns 파드 6개 전부 어노테이션 없음. `ImageDigestDrift`는 digest-exporter
  APPS 목록에 page·trip-mate-api 부재.
- 수리: argocd-application-controller scrape 배선(bootstrap-values podAnnotations, port 8082) +
  `absent()` 가드, digest-exporter APPS 갱신 + 변이 체인(create-app/teardown-app)이 APPS를 함께
  갱신하도록 배선.

**H2. files 사용자 데이터 삭제 방어가 git 밖 라이브 전용 패치에 단독 의존**
- git SSOT는 `infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml:7-8` `reclaimPolicy: Delete`
  (+"R2에서 재생성 가능" 주석 — files 온보딩 후 거짓 전제). PV Retain은 라이브 kubectl patch뿐,
  드리프트 가드 0. files는 유일한 비재생성 데이터인데 백업 0(미성문)·DR 재결합 절차 0·용량 관측 0.
- "git+R2+age키로 전 스택 재구축"(dr-drill.sh 헤더) 불변식의 유일한 미등록 예외.

### 1.2 주요 MEDIUM (배치로 흡수)

| # | 발견 | 핵심 증거 |
|---|---|---|
| M1 | 변이 reusable `bun 도구 \| tee` pipefail 부재 fail-open — 부분 변이가 auto-merge로 샐 수 있음 | `_create-database.yaml:61,63`·`_create-cache.yaml:61`·`_create-app.yaml:70-72,96-98`·`audit.yaml:24`. GHA는 `shell:` 미지정 시 `bash -e {0}`(pipefail 없음). `_teardown-app.yaml:47` 주석이 "GHA 기본 -eo pipefail" **오해를 기록** — 재발 근원 |
| M2 | posture '공개 HTTPRoute 금지' 가드 vacuous — 존재하지 않는 jq 경로 조회로 항상 통과 | internal-by-default의 유일한 자동 검증이 false-green. argocd-webhook(/api/webhook)은 allowlist 필요 |
| M3 | seed-secrets가 operator-oauth를 구 ns(edge)로 생성 — 재시드/DR 시 tailnet 인증 회귀 | tailscale ns 분리(#102) 미반영. seed 산출물↔커밋본 metadata 정합 검사 부재 |
| M4 | bats 중간 `! cmd` 부정 단언 6곳 침묵 통과 — 시크릿 유출 가드 일부 사문 | bash 버전 무관, CI·로컬 공통. '(set-e safe negate)' 주석이 오해 |
| M5 | create-database/cache가 앱 values envFrom 배선을 안내·감지 안 함 | trip-mate 실재발(#211). plan.checklist 항목 + audit-orphans `unreferenced-conn` 유형 부재 |
| M6 | dr-drill.sh PG 이미지 태그 하드코딩 — 다음 PG 메이저에서 DR 드릴 차단 | cluster.yaml과 4핀 불일치 가드 0, renovate 사각 |
| M7 | vmalert GOMEMLIMIT(115MiB) > limit(64Mi) 역전 | right-size 시 GOMEMLIMIT 미동반 갱신. 나머지 4개 워크로드는 정합 확인됨 |
| M8 | KSOPS 의존 bats 4개 어느 harness에도 미배선 + 주석의 실행처 주장 허위 | verify-posture 패턴(`Makefile:120-124`)으로 `make verify-ksops` 신설 필요 |
| M9 | traps SSOT 갭 — 6/22 이후 라이브 함정 3계열이 traps-detail 미반영 | ArgoCD Notifications telegram(토큰 로그 유출), PG 메이저 3-이미지 동시 갱신, 베스포크 공개=platform_hosts |
| M10 | scripts/README 11/27·tools/README 3/18 미등재 — 가드 없는 인덱스만 드리프트 | 가드 있는 인덱스는 전부 신선(패턴 입증) — check-doc-index 일반화 근거 |
| M11 | 예약 host 가드가 platform_hosts(files/argocd-webhook)를 모름 | create-app 예약어 검사·bats·dns-drift 모두 apps.json만 인지 |
| M12 | LOCAL_PATH_PROVISIONER_VERSION 소비자 0 — Renovate bump가 silent no-op | manifest 이미지 태그 플레이스홀더 배선 또는 일치 bats 필요 |
| M13 | files-prod 감시 공백 — NotReady가 어떤 채널로도 페이징 안 됨 | adguard·homepage도 동일 공백. `kube_deployment_status_condition` 룰 1개로 일괄 커버 가능 |
| M14 | files DR 재결합 경로 전무 — 빈 데이터로 '정상' 복귀하는 침묵 유실 모드 | H2와 동일 체인 |
| M15 | 런북 13종 단일 Mac 디스크 단일 사본 — 백업 자동화·검증 0 | sealing key 백업(backup-sealed-secrets-key.sh --verify)과 비대칭. age-keys.md는 recovery 키 보관처 포인터인데 그 문서가 로컬 전용(순환 의존) |
| M16 | 3rd-party 이미지 ~20개 tag-only — renovate pinDigests 설정과 실상 불일치 | Dependency Dashboard 확인 + 첫 digest 그룹 PR 처리 필요 |
| M17 | (cross-repo) release.yaml 복사-시점 스냅샷 — deploy-trigger 미전파 실증 | trip-mate는 build-only 구버전(머지→배포 크론 ~60-90분 의존), page는 수동 동기+불필요 가드 잔존 |
| M18 | (cross-repo) 템플릿↔homelab 계약 테스트 단방향·push-트리거 전용(휴면) | homelab 쪽 변경은 무신호. 현재 실드리프트 0 확인 |
| M19 | (cross-repo) bun·베이스이미지·액션 핀 정합 붕괴 | homelab 1.3.14 / template-ci 1.3.10 / trip-mate `latest`+`oven/bun:1` / 아키타입 `oven/bun:1`. Renovate는 homelab 자신만 |
| M20 | (cross-repo) files 베스포크: 릴리스마다 수동 이미지 bump PR | `platform/files/prod/kustomization.yaml` 자가 문서화 + #223 실증. bump-tag.ts는 values.yaml 전제 — 인라인 핀 편집 모드 필요 |

### 1.3 안심 확인 (재보고 아님 — 리팩토링에서 건드리지 않을 근거)

- 워크플로 토큰 최소성·SHA 핀·gitleaks 2중 배선·데드맨 스위치·tailscale ACL·cert 만료 감시: 전부 양호 확인.
- merge_group(#193) 잔재: #206이 의도적 제거 — 정합 상태.
- tools/ lib 6종 전부 실소비·데드 lib 없음. 의도적 비-DRY 2곳(provision-db addResource,
  seal-secret.mts 자기완결)은 코드에 근거 주석 존재 — **합치면 회귀**.
- 업그레이드 캠페인발 죽은 메트릭 0건(r6 제외 전 룰 라이브 TSDB 생존 확인).
- example-api 잔재: 레포 내 사실상 청정(tombstone은 의도적 증적). 원격 레포·GHCR 완전 소거.
  로컬 `~/workspace/example-api` 체크아웃만 고아.

## 2. 구조 결정 (아키텍처)

1. **디렉토리 재배치 없음.** platform 4-패턴·tf 3-루트·테스트 3-도메인 구조는 예외까지 가드로
   통제되고 있음이 확인됨. 이동을 위한 이동은 하지 않는다.
2. **골든패스 rule-of-two.** 공유차트 5축 확장(stateful PVC·복수 리스너·method 매치·시크릿 파일
   마운트·평문 env)은 **하지 않는다** — 소비자 n=1. files는 platform/ 유지. 대신 베스포크의 실비용
   2가지(수동 bump, 규약 재발견)를 구조적으로 제거: bump-poll 베스포크 핀 레인 + ADR-0004 성문화 +
   베스포크 체크리스트. 두 번째 stateful 수요 발생 시 흡수 우선순위는 ⑤env > ④파일마운트 > ③method
   (①stateful·②복수 리스너는 별도 차트/베스포크 유지)로 기록해 둔다.
3. **cross-repo 계약은 경계 이동이 아니라 전파·검증 수선.** 앱 레포가 아는 것 4가지(.app-config.yml,
   sealed 봉인본 경로, reusable-app-build@main 호출, GHCR push)는 보존 가치가 높은 경계. deploy-trigger를
   reusable 안으로 흡수하면 전파 대상이 vendored 2파일(seal-secret.mts·cert)로 축소 — 이 2파일은
   드리프트 체크(스케줄)로 커버.
4. **시크릿 하이브리드는 유지**(SOPS=부트스트랩 임계·DR 생존 / SealedSecrets=자동화 산출물 —
   기존 하이브리드 결정 존중). 고치는 것은 채널이 아니라 도구·문서: 채널 선택 기준 ADR 명문화,
   크리덴셜→평면 매트릭스, seal 도구 테이블 기반 단일화(일괄 재봉인 = sealing key 회전 드릴 확보).
5. **데이터 등급(재생성 가능/불가)을 스토리지 계층의 1급 개념으로 승격.** bulk-ssd Retain을 git으로,
   비재생성 등급의 백업·관측·DR 요구를 성문화. 정적/결정론적 PV 전환은 보류(라이브 재바인딩 리스크 —
   계획 단계 재평가 항목).
6. **원장 파이프라인은 bun 단일 파서로 수렴**(markdown→awk→JSON→rego 4-기술 관통 해소).
   check-resource-limits의 내장 python도 bun 이관 — 게이트 언어를 셸(grep/yq/jq 라인 지향)과
   TS(계약·계산)로 2원화하고 배치 규칙을 성문화.

## 3. Wave 1 — 정지혈 + 내구성

> 결함 수리 우선. 구조 변화 최소. 배치 순서 = 위험 노출 순.

### B1. 변이 파이프라인 fail-closed (M1)
- 4개 reusable(_create-app/_create-database/_create-cache/_update-secrets)+audit.yaml의 파이프 사용
  run 스텝에 `set -euo pipefail` (일괄 대안: `defaults: run: shell: bash` — 명시 bash는 `-eo pipefail` 포함).
- `_teardown-app.yaml:47` 오해 주석 정정(잘못된 전제가 신규 워크플로의 오판 근거가 됨).
- `_create-app.yaml:70` digest 가드 파이프 분리(`out=$(docker …) || exit 1; digest=$(jq … <<<"$out")`).
- 재발 가드: `| tee`/파이프 사용 워크플로 스텝의 pipefail 존재 bats + docs/traps.md 원장 등재.

### B2. 감시 소생 (H1·M7·M13 + CacheBackupStale)
- H1 수리(§1.1). argocd 파드 재시작 수반 — 배포 후 `argocd_app_info` 수집·룰 발화 라이브 확인.
- 플랫폼 NotReady 룰: `kube_deployment_status_condition{condition="Available",status="false"}` 기반
  워크로드-불가용 vmalert 룰 1개(core) — files·adguard·homepage 공백 일괄 커버. + ArgoCD notifications
  templatePatch 컴포넌트 목록에 files 추가.
- vmalert GOMEMLIMIT 57MiB 정정 + check-resource-limits.sh에 `GOMEMLIMIT ≤ limit×0.95` 검사 추가.
- CacheBackupStale 룰(r4, pg 패턴 복제 — 캐시 인스턴스 0개 시 absent 오발화 여부 설계 포함).

### B3. 가드 소생 (M2·M4·M8)
- posture vacuous jq 교정: `.spec.rules[].backendRefs[]?.name` + argocd-webhook allowlist(경로
  /api/webhook 한정 단언). grafana 테스트 동일 교정.
- bats 중간 `! cmd` 6곳 → `run bash -c '…'; [ "$status" -ne 0 ]` 재작성 + 오해 주석 정정.
- bats 단언 스타일 lint 신설: 마지막 명령이 아닌 `^\s*! ` 라인 + 중간 `[[ ]]` 탐지(gate bats,
  test_bats-naming.bats 선례).
- `make verify-ksops`: age 키 존재 시 실행/부재 시 skip — KSOPS bats 4종 배선 + .ci-exclude 그룹
  주석에 실행처 기재.

### B4. 시크릿/DR 결함 (M3·M5·M6)
- seed-secrets.sh operator-oauth ns를 tailscale로 교정 + 재발 가드(seed heredoc 산출물 metadata ↔
  커밋본 *.enc.yaml metadata 일치 정적 검사).
- envFrom 배선 갭: provision-db/cache plan.checklist에 'values.yaml envFrom에 <handle>-conn secretRef
  추가' 명시 항목 + audit-orphans에 `unreferenced-conn` 정보성 유형.
- dr-drill.sh PG 이미지를 cluster.yaml에서 yq 파생(또는 4핀 일치 bats — gate 수집 대상).

### B5. files 데이터 내구성 체인 (H2·M14 + 등급 승격)
- bulk-ssd SC `reclaimPolicy: Retain` git 승격(소비자 2: files-data는 Retain 필수,
  pg-basebackup-local은 무해 — Released 잔존은 기존 audit-orphan-pv.sh가 나열). stale 주석 교체.
- posture 스위트에 라이브 reclaim 단언(git↔라이브 드리프트 가드).
- **호스트 rsync 백업 필수화** (A.5 리뷰 F3 수용 — Retain·관측·카탈로그 검증은 오삭제·침묵 유실
  방어일 뿐 매체 유실 무방비): 주기 rsync(외장 SSD files-data → Mac 내장 디스크 또는 별도 매체,
  호스트 launchd) + **복원 검증 스모크**(백업에서 파일 1개 복원+체크섬 대조) + RPO 명시(일 1회).
  R2 미사용 결정(무료티어)은 pvc.yaml 헤더에 성문화하되 '백업 없음'이 아니라 '백업=호스트
  오프-SSD 사본'으로 기록.
- bulk-ssd 용량 관측: files `/readyz` free-space를 메트릭 export(앱 레포 1엔드포인트) 또는 호스트
  launchd→vmsingle push(restore_drill push 패턴 재사용) — 계획 단계에서 택1.
- dr-drill 체크리스트에 'files 카탈로그 비어있지 않음' 검증 1줄.
- DR 재결합 절차 런북화(external-ssd.md 또는 restore.md — owner-local).
- **보류**: files-data 정적/결정론적 PV 전환(라이브 재바인딩 리스크 — 계획 단계 재평가).

## 4. Wave 2 — 구조 리팩토링 4테마 + 성장 병목

### B6. 변이 프레임 composite화 (페인포인트①)
- composite 2개: `.github/actions/mutation-notify`(needs JSON 정규화+telegram — 5중 사본 제거),
  `.github/actions/pr-first-commit`(writer 자격→branch→commit→PR→선택적 auto-merge — 5곳 시퀀스 수렴).
- 경계 재검증 단일화: _create-cache 인라인 regex → `validate-mutation.ts --action create-cache`
  재호출(_create-database 방식) 통일, _create-app/_update-secrets에도 동일 1스텝(대칭 defense-in-depth).
  `identity.ts:10-11` SSOT 선언 위반(워크플로 인라인 사본 2곳) 소멸.
- test_mutation-dispatch DISPATCHERS 하드코딩 열거 → 동적 파생(glob: workflow_dispatch + `uses: ./.github/workflows/_*` — fail-open 해소).
- **변이 디스패처 actor 가드** (A.5 리뷰 F1 수용): 5개 변이 디스패처 validate 잡 선두에 owner-only
  actor 검증(`github.actor` allowlist). 근거: 앱 레포의 HOMELAB_DISPATCH_APP_*(actions:write)는
  bump-poll 트리거용이지만 actions:write는 변이 디스패처까지 트리거 가능 — actor 가드로 디스패치
  자격의 유용성을 bump-poll(자체 fail-closed 검증기)로 한정. bump-poll·audit(비변이 reconciler)는
  가드 비대상. B11 deploy-trigger 흡수의 선행 조건.
- validate-mutation CONTRACT 사문행(activate-app·audit) 처분 + tf-reconcile plan-only 2잡 matrix화는
  계획 단계에서 이득/가드갱신 비용 재평가(우선순위 낮음 — 명시적 선택 항목).
- 검증: 전환 후 카나리 변이 1회(update-secrets 등 비파괴) 라이브 실행.

### B7. 실행 체계 경계 (페인포인트②)
- `scripts/ledger-to-json.sh` → bun 이관: `tools/lib/ledger-totals.ts` parseLedgerRows 단일 파서
  SSOT(verify:ledger는 bun 산출→conftest 유지). LEDGER_ROW_RE env 클래스 `[a-z0-9-]+` 확장 포함.
- `tools/lib/ledger-budget.ts` 추출: create-app.ts:100-110 ≒ provision-cache.ts:61-73 12줄 사본 +
  쓰기 측 addRow+replaceTotals 수렴. teardown-app.ts 인라인 파서(빈 줄 잔류 버그 재현됨) lib 교체.
- check-resource-limits.sh 내장 python3 35줄 → bun/TS(3언어 게이트 해소, typecheck 편입).
- lib/cli.ts parseFlags typed accessor(`{str(k,d), bool(k)}`) + activate-app·verify-db-marker 이주
  (미지 플래그 침묵 수용 해소). 종료코드 규약(2=사용법/파싱, 1=검증/게이트, 3=race) lib 주석 명문화.
- '새 코드 배치 규칙' 성문화(CONTRIBUTING 또는 scripts/README): 셸=라인 지향 게이트·라이브 운영·
  봉인 파이프 / TS=계약·계산·레지스트리 / 워크플로 인라인 셸 최소화(bump-poll while-loop이 제4계층으로
  자라는 중 — 경계 기록).

### B8. 시크릿 채널 (페인포인트③)
- ADR-0001 개정(append): de-facto 채널 선택 기준="부트스트랩 임계성"(enc 10 vs sealed 19 실태) 명문화.
- 크리덴셜→소비자 평면 매트릭스(예: telegram = SOPS 2 + SealedSecret 1 + Actions 1) — 회전 런북
  (owner-local) + 회전 PR 체크리스트에 owner-local 평면 확인 항목.
- seal-* 4종(adguard/argocd-notify/files/ghcr-pull) → 선언 테이블(secret 이름/NS/키↔env/변환 유형)
  기반 단일 seal 도구. **일괄 재봉인 모드 = sealing key 회전 드릴** (19개 봉인본 일괄 재봉인 도구
  부재 해소). 변환부(bcrypt/dockerconfig/literal/파일마운트) 차이는 유형 플러그인으로.
- Makefile seal 타겟 소싱 규약 통일(seed-secrets 패턴) + secret-cert-check preflight 배선 —
  **fail-closed** (A.5 리뷰 F2 수용): stale(1)·검증불가(2) 모두 기본 실패, 명시적 break-glass
  (`--offline-ok` 또는 `SEAL_OFFLINE=1`)로만 진행, dry-run은 preflight 비대상. GHCR_PULL_TOKEN
  회전 단일 타겟(prod+files 두 봉인본 동시).

### B9. 골든패스/베스포크 (페인포인트④)
- ADR-0004: 분기 5축 + 노출 레지스트리 이원화(apps.json=데이터 합류·자동 회수 vs platform_hosts=코드
  고정·보호) + 재평가 트리거(두 번째 stateful 수요) — 현재 dns.tf 주석·immutable plan에만 있는 근거를
  living doc으로.
- bump-poll 베스포크 핀 레인: `platform/<comp>/prod/source-repo` + 인라인 핀 위치 디스크립터,
  bump-tag.ts에 인라인 핀 편집 모드 — files가 자동 bump 합류(M20). autoDeploy 게이트는 apps/ 레인과
  동일 fail-closed.
- 예약 host JSON SSOT(예: infra/cloudflare/reserved-hosts.json): dns.tf locals·create-app.ts 예약어
  검사·test_apps_structure.bats·dns-drift-check.ts 4소비자 공유(M11 + dns-drift의 platform_hosts
  미감시 해소).
- 베스포크 컴포넌트 체크리스트 문서(NS+PSA+Prune=false, netpol 트리오, platform_hosts 등록, bats
  최소셋, 원장 행, 알림 구독 라벨) — files가 4번째 손복제(계보: adguard→homepage→cache→files)임이
  확인됨; 5번째부터는 체크리스트 기반.

### B10. 메모리 헤드룸 캠페인 (성장 병목 1위)
- 원장 잔여 196Mi — 현행 앱 프로필(256Mi)로는 다음 앱 온보딩부터 게이트 차단. 원장 식별 medium-risk
  회수분 ~288Mi(vmsingle·argocd repo-server·sealed-secrets) 회수.
- 워크로드당 1 PR + GOMEMLIMIT 동반 조정(Go 워크로드 limit의 90% — B2의 게이트 검사가 역전 방지) +
  PR별 라이브 모니터링 기간(working_set 관찰) 후 다음 워크로드.

## 5. Wave 3 — cross-repo 계약 + 하드닝/문서

### B11. cross-repo 계약 (M17·M18·M19 + 계약 가드)
- **deploy-trigger를 reusable-app-build.yaml 안으로 흡수**(시크릿 부재 시 preflight-skip 패턴) —
  앱 레포 release.yaml은 영구 불변 thin-caller로. 디스패치 시크릿은 **per-repo 유지**(owner 수동
  설정 — 템플릿 f59453e 현상태와 동일. workflow_call은 caller 컨텍스트 실행이라 흡수는 시크릿
  노출면 불변=보안 중립 이동). **org-level secret 비채택** (A.5 리뷰 F1 — 노출면 확대라 폐기.
  잔존 권한 상승 리스크는 B6 actor 가드가 차단 — B6이 본 항목 선행 조건).
  trip-mate release.yaml 동기 + page 잔존 가드 제거.
- reusable inputs 계약 bats 고정: `.on.workflow_call.inputs.app.required==true` + inputs 키 집합
  정확히 [app].
- '동봉 계약 매니페스트'(vendored 사본 목록: seal-secret.mts·sealed-secrets-cert.pem × 4레포) 선언
  + dns-drift 패턴의 스케줄 드리프트 체크(정규화 diff — trip-mate 포매터 재포맷 대응).
- 계약 왕복 스모크 채택 검토: homelab gate에서 템플릿 scaffold→`create-app --dry-run`→helm render
  (스키마·비즈니스 규칙·차트 3층 검증 — template-ci ajv보다 강함). 최소안: template-ci에 주1회 cron.
- bun 버전 정합: 템플릿 1.3.14 정렬, trip-mate `latest`→핀, 아키타입 `oven/bun:1` 부동 태그 처분
  결정(재현성 vs 유지비 — 계획 단계 확정), RENOVATE_REPOSITORIES에 템플릿 추가(writer App 설치 범위
  확장 수반).
- 잔손: page 죽은 도구(scaffold-kind.mts+test — 폐기 v1 어휘) 삭제, env-example.mts 의도 확정
  (앱 DX 배포 vs homelab 전용), app-deploy-schema required에 kustomization.yaml 추가,
  AGENTS.md 'pnpm secret:seal'→'bun run secret:seal' 표기 정정.
- 사전 조건: 템플릿 로컬 체크아웃 pull(2커밋 뒤 — release.yaml 계약 표면 변경분).

### B12. 게이트/문서 하드닝 (M9·M10·M12·M15·M16 + bump.yaml 처분)
- check-doc-index 일반화: `ls scripts/*.sh`·`tools/*.ts`·workflows ↔ 해당 README 문자열 존재 검사
  (check-skeleton·verify-runbook-index 패턴) — 가드 없는 인덱스 드리프트 클래스 소멸. 누락분 등재
  (scripts 11건 — 특히 파괴적 teardown.sh·seal-* 파괴성 표기, tools 3건, workflows build.yaml).
- check-skeleton dirs 배열 → README 표↔디렉토리 양방향 검사(신규 컴포넌트 자동 편입).
- traps-detail 3계열 추가(M9) + AGENTS 한줄 인덱스 동기화. SYNC-WAVES.md 현행화(-7 포함).
  memory-ledger 산문 수치 정합(+산문 수치==표 합 검사 검토).
- LOCAL_PATH_PROVISIONER_VERSION 배선(manifest 태그 플레이스홀더 또는 일치 bats).
  verify-cluster.sh에 라이브 k3s 버전==K3S_VERSION 핀 단언.
- 런북 백업 일반화: backup-sealed-secrets-key.sh 패턴 미러 `backup-local-asset.sh`(runbooks tarball
  age 암호화→git 밖 매체, `--verify` 신선도 게이트) + verify-runbook-index를 owner 머신에서
  fail-closed(양방향)로 + traps 원장 '로컬 자산 백업 체인' 행.
- 3rd-party digest 핀: Renovate Dependency Dashboard 확인 + 첫 'image digests' 그룹 PR 처리(M16).
- bump.yaml 재목적화: pg-tools digest 소비자 5-manifest 재핀 배선(PgDumpHedgeStale 재발 방지) —
  A안 채택.
- docs/plans 검색 노이즈: .rgignore(또는 동등 관례)로 에이전트/도구 검색 기본 제외 + 신규 계획 문서
  크기 상한 관례. 히스토리 재작성은 하지 않음.

### B13. 잔손질 스윕 (선별 low)
차트: cpu limit 스키마 정렬(check-resource-limits 정책과 — cpu limit 필수 여부 의도 확정 포함),
app.validate에 host↔public `.home.` 접미사 규칙, values.yaml sectionName 주석 교정, 구본 bats
`[[ ]]` 정비. 플랫폼: files 렌더 bats(homepage 패턴), #224 회귀 단언, ghcr-pull 회전 상호참조.
tools: create-app 미니 검증기 미지 키워드 fail 화이트리스트, 내부 host 유일성 검사, db-url/cache-url
라이브 경로 스텁 테스트, DB_RESERVED_NAMES export 정리. infra: destroy-guard 주석 오기,
internal_suffix 미사용 정리, k3s-install 무효 플래그, dns-drift --extra-hosts(예약 host SSOT 소비).
scripts: netpol-rehearsal 처분(인자화 또는 완료 명시), audit-orphan-pv make 타겟 노출, sops-guard↔
verify-secrets recipient 추출 일원화. 로컬: ~/workspace/example-api 고아 체크아웃 처분 결정.
(확정 목록·순서는 구현 계획에서 항목별 명시.)

## 6. 의도적 제외 (근거 포함)

| 항목 | 근거 |
|---|---|
| 공유차트 5축 확장 | rule-of-two — 소비자 n=1, 닫힌 스키마 표면 확대 비용 > 이득. 재평가 트리거는 ADR-0004에 |
| files의 apps/ 편입 | appset destination.namespace=prod 하드코딩 + 차트 백도어 재개방 필요 — 역행 |
| .bindings.json 리네임 | 소비자 3곳+가드 갱신 비용 > 이득 — 문서 정렬만(B13) |
| docs/plans 히스토리 재작성 | .git 무게 잔존 + protected main force-push 함정 이력 — 검색 제외로 갈음 |
| tf 모듈화 | 루트당 리소스 소수·단일 zone/tunnel — 모듈은 간접화 비용만 추가 |
| victoria-stack Application 분할 | 현 스케일에서 문제없음 — flat 24리소스는 관찰만 |
| merge queue 도입 | 실모델=auto-merge로 정합 확인(#206) |
| tf-reconcile drift 잡 matrix화 | 가드 테스트(grep 기반) 동반 갱신 리스크 대비 이득 소 — B6에서 선택 항목으로만 |
| 나머지 low ~40건 | 테마 무관·비용>이득 — 감사 결과 파일에 기록 보존 |

## 7. 리스크 매트릭스

| 배치 | 라이브 리스크 | 완화 |
|---|---|---|
| B2 | argocd 파드 재시작(scrape 어노테이션) | selfHeal 수렴 확인 + 룰 발화 라이브 검증 |
| B5 | SC 변경 | 기존 PV는 이미 라이브 Retain — git 정합화일 뿐 무영향. 신규 PV부터 Retain 적용 |
| B6 | 변이 경로 전환 | grep bats→구조 보장 이행 + 카나리 변이 1회 라이브 |
| B8 | seal 도구 교체 | 신구 산출물 diff 검증(동일 cert·scope) 후 구 스크립트 제거 |
| B10 | right-size OOM | 워크로드당 1 PR·GOMEMLIMIT 동반·모니터링 기간·즉시 롤백 가능 |
| B11 | 앱 레포 3곳 빌드 경로 | reusable 흡수는 additive(preflight-skip) — 앱별 1회 빌드 검증 |

공통: 각 배치 PR은 required check `gate` 통과 + 배치별 명시 라이브 검증 후 다음 배치.
스택 PR squash 함정(base --delete-branch 머지=의존 PR 자동 CLOSE) 주의 — 배치 내 PR은 직렬 머지.

## 8. 설계 적대 리뷰 (Phase A.5) dispositions

codex 설계 리뷰 1회(2026-07-02, verdict=needs-attention, high 3) — 전건 수용, owner 승인:

| 발견 | 판정 | 반영 |
|---|---|---|
| F1 즉시 배포 디스패치의 앱 레포 자격 노출 | 수용(수정) | org-secret 폐기·per-repo 유지(보안 중립 명시), B6에 변이 디스패처 actor 가드 신설(권한 상승 차단), B6→B11 선행 조건화 |
| F2 seal preflight exit 2 경고-진행 fail-open | 수용 | B8 preflight fail-closed + 명시적 break-glass로 전환 |
| F3 files 백업이 결정 기록에 그침 — 매체 유실 전손 | 수용(수정) | B5에 호스트 rsync 백업 필수화 + 복원 검증 스모크 + RPO(일 1회) |

## 9. 부록 — 감사 산출물 위치

- 12차원+3추가 전체 결과(발견 65+10건 원문·verdict 포함): 세션 산출물
  `tasks/wrncxppzd.output`(190KB JSON — 세션 종료 후 소실 가능, 본 문서가 요약 SSOT).
- cross-repo 계약 분석: 동 세션 에이전트 결과(§1.2 M17-M20에 흡수).
- 적대검증: high/critical 전수 검증 — CONFIRMED 2(H1·H2), 나머지 상당수 DOWNGRADE→low 반영됨.
