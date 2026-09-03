# AGENTS.md — 에이전트/개발자 작업 가이드

k3s 단일 노드(**Intel NUC 베어메탈** · Ubuntu 26.04 LTS · amd64) 홈랩의 GitOps 모노레포. ArgoCD가 이 레포의 `main`을
싱크해 전 스택을 운영한다. 앱 코드는 **별도 레포**(`ukyi-app/<app>`, 템플릿:
`ukyi-app/homelab-app-template`)에 살고, 이 레포에는 배포 설정만 둔다.

## 디렉토리 지도

| 경로 | 역할 |
|---|---|
| `infra/` | Terraform 3 루트(cloudflare/tailscale/github) + `k3s-bootstrap/`(VM·k3s·스토리지) |
| `platform/` | ArgoCD가 싱크하는 GitOps 컴포넌트 — **전체 목록은 README 디렉토리 지도**(check-skeleton 강제) |
| `platform/charts/app` | 모든 앱이 쓰는 공유 Helm 차트 (SSOT) |
| `apps/<name>/deploy/prod/` | 앱별 values + SealedSecret + `.bindings.json`(db/redis·autoDeploy SSOT) + `source-repo`(외부 레포 바인딩) |
| `tools/` | 앱 플랫폼 DX **Bun/TS CLI** (`create-app`/`activate-app`·`audit-orphans` 등 — 변이 디스패처·`bump-poll`이 호출, `homelab` 통합 CLI 진입점 `homelab.ts` 포함) + 단위 테스트(`tools/tests/`). top-level·`lib/`는 `.ts`(bun 전용), app-shared는 `.mts`(bun + node≥22.18 strip-types 양립) — 산출물 로스터는 `tools/README.md`(check-doc-index 강제) |
| `scripts/` | 클러스터/DR 운영·시크릿 **셸 스크립트** (bootstrap·seed/seal·dr-drill·`check-*` 게이트·run-bats — `make`/CI 게이트가 호출). cf. `infra/k3s-bootstrap/*.sh` = VM·k3s·스토리지 substrate 부트스트랩 |
| `policy/` | 메모리 원장 OPA 정책 (`bun run verify:ledger` 게이트) |
| `docs/memory-ledger.md` | 메모리 예산 SSOT — limit 합계 ≤ 10240Mi, CI 강제 |
| `docs/runbooks/` | **로컬 전용**(gitignored) 운영 런북 — 아래 인덱스 참고 |
| `tests/` | 전역 테스트 (sops 라운드트립, posture 라이브 스위트) |

## 핵심 명령

```bash
make verify        # 기반 게이트: skeleton + 원장(conftest) + sops 라운드트립
make chart-test    # 공유 차트: 3 kind(web/worker/site) 렌더 + kubeconform + bats
make tf-validate   # terraform fmt+validate (3 루트)
bats tools/tests/ infra/k3s-bootstrap/tests/ </dev/null   # 툴링/부트스트랩 테스트(fd 0 격리 — 스텁 hang 방지)
make verify-posture   # [live] posture 스위트(internal-by-default·netpol·e2e) — KUBECONFIG 필요(부재=SKIP 신호·비-0)
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/<comp>/prod  # KSOPS 풀 렌더
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig   # 라이브 클러스터 접근
```

## 컨벤션 (필수)

- **커밋**: 한국어 conventional(`feat:`/`fix:`/…), AI 마커 금지. Claude는 `/commit` 스킬 사용.
- **주석**: 한국어로 통일. 기술 고유명사(ArgoCD, KSOPS, sync-wave, Deployment 등)는 영문 유지.
- **bats `@test` 이름은 영어** — 디렉토리 단위 실행 시 한글 이름이 인코딩 깨짐(검증된 버그).
- **`*.enc.yaml`은 직접 수정 금지** — 평문 메타데이터도 SOPS MAC에 포함된다. 수정은
  복호화→편집→재암호화(`sops`)로만. 시크릿 값은 채팅/로그에 절대 출력하지 않는다.
- 시크릿 공급: 로컬 `.env.secrets`(gitignored, 템플릿 `.env.secrets.example`) + SOPS 시드만.
- 내부 호스트 접미사는 `home.<도메인>` (Gateway `web-internal-tls` 리스너 규약 — 내부 인입은 tailscale passthrough→:8443뿐).
- 벤더 파일 수정 금지: `platform/*/prod/charts/`(helm 캐시, untracked), barman-plugin manifest,
  gateway-api CRD. `Chart.yaml`의 파스칼케이스는 Helm 고정 규약이다.
- **네이밍 규약**: 워크플로는 전부 `.yaml`(reusable 포함). `_*.yaml`=내부 reusable(동명 변이 디스패처가
  호출) vs `<action>.yaml`=공개 변이 디스패처(workflow_dispatch) vs `reusable-*.yaml`=cross-repo 공개 계약(외부 앱 레포가 `@main`으로 호출 — 파일명·입력이 계약).
  스키마 `*-schema.json`=tools 계약(`app-config`/`app-deploy`) vs `values.schema.json`=Helm 고정.
  bats는 `test_` 접두 통일, SealedSecret은 `*.sealed.yaml`.

## 라이브에서 검증된 함정 (재발 주의)

> 전문·근거는 **`docs/traps-detail.md`(SSOT)** — 컴포넌트 작업 전 해당 항목 확인. enforced 가드 현황은
> `docs/traps.md` 원장(`make verify-traps`). 아래는 한줄 인덱스(헤드라인 = traps-detail.md 섹션과 동일).

- ArgoCD sync-wave 순서/교착
- ArgoCD retry 소진 후 명시 sync
- k8s SSA 중복 env 키/스키마 밖 필드 거부
- ArgoCD chart: 필드 repoURL/targetRevision
- Traefik serviceAccount.name 지정 시 SA 미생성
- appset 대상 네임스페이스는 platform/namespaces 소유
- R2 Object R&W 토큰 ListBuckets 불가
- GHCR org 패키지 첫 push private
- fine-grained PAT 능력은 실제 push 테스트로만
- runAsUser /etc/passwd 부재 시 libpq PGUSER
- AdGuard setcap ↔ allowPrivilegeEscalation 양립불가
- VictoriaMetrics retention.maxDiskSpaceUsageBytes 엔터프라이즈
- envFrom 시크릿 변경은 파드 재시작 필요
- build 워크플로 paths/diff 신규 브랜치 무력
- GitHub Actions client_payload 비신뢰 입력
- CNPG Pooler 예약 파라미터 pool_mode → poolMode
- SSA atomic 리스트 영구 OutOfSync
- Application zero-value selfHeal 플립플롭
- selfHeal이 라이브 실험을 무력화한다 — 끄는 레버는 git뿐
- PSA baseline hostPath/hostPID 금지
- CNPG pg_hba replication pg_basebackup
- CronJob k3s VM TZ(Asia/Seoul)
- NetworkPolicy ipBlock pod-CIDR → 전체 허용
- kube-router 룰 설치 갭/v2 체인명 변경
- NetworkPolicy egress apiserver ClusterIP 불가
- OrbStack LISTEN 포트만 포워딩
- AdGuard ConfigMap 첫 부팅 시드 전용
- AdGuard split-horizon rewrite DR stale
- tailscale operator Ingress reconcile metadata-only 무시
- vector는 root로 실행
- busybox nc -q 없음
- VictoriaLogs distroless 라이브 질의
- VM 질의 URL에서 `[...]`를 인코딩하지 않으면 조용히 빈 결과가 온다
- Alertmanager telegram 전송 검증 메트릭
- ConfigMap 변경 파드 자동 재시작 없음
- bats bash 3.2 중간 [[ ]] 침묵 통과
- 셸 문자열의 `$VAR한글` — bash 3.2가 멀티바이트를 변수명에 삼킨다
- helm 차트 CRD includeCRDs
- sealed-secrets patch-mode 대상 Secret 어노테이션
- gh pr merge --auto clean PR 에러
- create-github-app-token repositories owner 없는 레포명
- concurrency.queue: max ↔ cancel-in-progress 병용 불가
- terraform provider lock 첫 커밋 라이브 state writer 이상
- tf 루트 관리 모델 CI vs 로컬
- 상주 워크로드 자원 limit 블라인드스팟
- GHA run 기본 셸 pipefail 부재(bash -e {0})
- GNU make가 recipe 종료코드를 자기 Error 2로 뭉갠다
- ArgoCD Notifications telegram native 함정
- PG 메이저 업그레이드 3-이미지 동시 갱신
- 베스포크 공개 노출은 platform_hosts
- 로컬 자산 백업 체인
- 재부팅 IP churn — instance 라벨 불안정
- push 주기 > instant 룩백 → 룰 시리즈 구멍 → 무발화
- rollup 윈도 상한 — 상태 게이지 vs 하트비트 비대칭
- bump-poll/** 예약 룰셋 — 인터록≠인증·정적 가드는 변경 감지기
- emptyDir sizeLimit vs 런타임 다운로드 페이로드
- 열거 붕괴 → vacuous green (프로세스 치환·커맨드 치환·부정 카운트)
- `grep -qv`는 부재를 재지 않는다 — 줄 단위 반전이 전칭을 존재로 바꾼다
- PreToolUse 훅 종료코드 — fail-closed는 exit 2뿐
- vmalert replay rulesDelay — 비율 아닌 절대 지연·체인 없으면 순수 낭비
- make -n은 드라이런이 아니다 — 레시피의 $(MAKE)는 -n에서도 실행된다
- tracked 열거 게이트는 untracked 파일을 아예 안 본다 — 로컬 초록이 CI를 예고하지 못한다
- 체이닝 레이스의 두 번째 얼굴 — record는 있는데 ALERTS가 전무(병렬화가 깨운 flake)
- 소스의 리터럴 NUL 한 바이트가 그 파일을 모든 grep 가드에게 투명하게 만든다
- 디스크 자기-상한이 자기 볼륨 선언보다 크다 — GB(10⁹) vs Gi(2³⁰)
- 고아 PVC는 Bound다 — `phase == Released`만 보는 감사는 원리적으로 못 잡는다
- GHA job-level skip은 run conclusion에 안 보인다 — 스텝 전부 skip이어도 job은 success
- 이미지 핀의 *존재* ≠ *일치* ≠ *소유자* — 하드코딩 소비처 목록은 자기 자신에게만 정확하다
- sshd_config.d는 먼저 읽힌 값이 이긴다 — systemd 드롭인과 정반대다
- Ubuntu 26.04에 /etc/timezone이 없다 — 그 파일을 읽는 게이트는 출구가 없다
- tailscale의 ~. 라우팅 도메인 — 노드 이름해석이 조용히 클러스터 의존이 된다
- findmnt -T는 마운트 여부를 증명하지 못한다 — 그리고 bind 마운트의 SOURCE엔 대괄호가 붙는다
- 상주 워크로드 OOM 진단 — 코어 수는 그럴듯한 오답이다 (D-e) · 처방 후 같은 지표를 다시 재라
- PCIe correctable RxErr 폭주는 ASPM L1이다 — 유휴에서만 나고, 하드웨어 열화가 아니다
- hostPath 백엔드 PV에는 fsGroup이 적용되지 않는다 — root가 만든 파일을 non-root가 못 연다(빈 PVC 전용)
- yq -e는 값이 false면 exit 1이다 — 키 부재(null)와 구별하지 않아 올바른 매니페스트에서 red가 난다
- 한시 억제는 자기 만료를 품어야 한다 — 그리고 억제한 알림을 vacuity 대조군으로 쓰던 e2e가 함께 죽는다
- 드릴의 정리가 EXIT trap뿐이면 고아가 남고, pre-flight 없는 apply가 그 고아를 재사용해 '검증된 복원'이 거짓말한다
- `kubectl apply --dry-run=server`는 ArgoCD가 SSA로 관리하는 오브젝트에 대해 거짓 실패를 낸다
- 권한 부족은 에러가 아니라 드리프트로 위장한다 — terraform은 못 읽은 리소스를 "삭제됨"으로 읽는다
- owner 로컬 apply 루트는 CI가 plan만 해도 terraform 코어 버전이 state writer 이상이어야 한다
- GitHub API는 낡은 스냅샷을 200으로 돌려준다 — `last_over_time`은 그 역행 샘플 하나를 그대로 페이지로 바꾼다
- 로케일 콜레이션이 게이트를 뒤집는다 — en_US의 `sort -u`는 `-1`과 `1`을 같다고 보고 하나를 버린다
- systemd 유닛 파일은 push 생산자 열거 밖이다 — 유닛에 인라인한 curl은 완전성 가드를 통째로 지나간다
- bats는 stdin을 만지지 않는다 — 스텁이 피연산자 없이 `cat`을 부르면 호출자의 fd 0에서 영구 블록한다
- 호스트 포트 밴드는 ephemeral뿐 아니라 NodePort도 피해야 한다 — NodePort는 리스너가 아니라 nat 규칙이라 어떤 bind 프로브로도 안 보인다
- `Restart=always` 유닛은 failed 상태에 진입하지 않는다 — 시작 rate limit에 못 닿으면 영원히 activating이다
- `&`로 띄운 헬퍼의 바인드 실패는 `set -e`에 안 걸린다 — readiness 줄이 없으면 30초 뒤 엉뚱한 곳을 가리키는 오진이 된다
- ERE의 leftmost-longest가 `^A|B.*$` 한 방을 토큰 전체 삭제로 바꾼다 — 검출기가 자기 도메인의 표기법에 눈이 먼다
- heredoc 상태 기계가 주석 규칙보다 먼저 돌면, `<<PY`를 인용한 주석 한 줄이 파일의 나머지를 통째로 지운다
- 면제 판정이 주석보다 먼저 돌면, 규약을 *설명한* 파일이 그 규약에서 면제된다 — 가드 자신부터
- SKIP(exit 4)을 모르는 대조는 gitignored 자산이 있는 로컬에서만 초록이다 — venue가 갈리면 로컬은 CI를 예고하지 못한다
- `findings="$(awk … || true)"` — 검출기가 죽어도 "0곳 OK"를 내는 가드 본체의 fail-open
- vmalert에 configCheckInterval이 없으면 룰 파일 변경을 감시하지 않는다 — ArgoCD가 갱신해도 옛 룰을 계속 평가한다
- 워크플로 YAML의 따옴표 없는 스텝 이름에 콜론이 들어가면 매핑으로 파싱돼 파일이 조용히 깨진다
- bats @test 이름에 한글/CJK가 있으면 디렉토리 단위 실행에서 침묵 스킵된다
- homepage: config 마운트를 readOnly로 두면 EROFS · apiserver egress는 노드 CIDR:6443이지 ClusterIP가 아니다
- 상류 레지스트리의 릴리스 태그가 불변이 아니다 — 재푸시가 옛 매니페스트를 GC해 모든 PR gate를 red로 만든다
- TS 바닥값은 coercion 뒤에서 조용히 꺼진다 — Number("abc")는 NaN이라 n < NaN이 항상 false이고, Number("")는 0이라 빈 입력과 의도적 0을 구별할 수 없다
- 스캔 신호를 콜사이트가 손으로 내면 순서가 드리프트한다 — 위반 exit이 신호보다 앞이면 마커 0건이 '미실행'으로 읽히고, 로스터 등식은 우회를 못 잡는다
- 테스트 이름은 인터페이스가 아니다 — 뮤테이션이 전건 red여도 픽스처가 밟지 않는 판정 조건은 무증인이다
- 정적 증인의 두 함정 — `^[^/]*`는 `//`만 제외하고(JSDoc ` * ` 줄이 코드가 된다), `run bash -c` 안의 bats 지역 변수는 빈 문자열이라 grep이 0건으로 항상 통과한다
- QEMU amd64 leg의 bun 1.4는 RSS 24MB에서 "메모리 고갈"로 죽는다 — Dockerfile을 안 돌리는 CI는 그 6시간을 초록으로 지나친다
- `github.actor`는 재실행에서 보존된다 — 개시자는 `triggering_actor`이고, `actions:write`는 재실행 동사를 포함한다
- 인용하지 않은 heredoc 안의 주석에 백틱을 쓰면 그 명령이 **실행되고** 주석이 잘려 나간다 — shellcheck는 그걸 "style"로 부른다
- 프로브는 호출이 아니다 — `command -v X`와 미평가 라벨이 X의 증인 노릇을 해서 mirrored 선언이 자기 자신을 증명한다
- actor 가드는 대소문자를 구별한다 — GitHub login은 구별하지 않는데, 그 어긋남을 밟는 테스트가 0건이다
- `grep -q`의 조기 종료가 pipefail 아래에서 writer를 SIGPIPE로 죽인다 — 매치가 있었는데 141이 거짓 FAIL이 된다
- 서브쿼리 step이 스크레이프 간격보다 크면 peak가 조용히 과소평가된다 — 그 위에서 깎은 limit이 회귀가 된다
- 네이티브 사이드카의 limit은 KSM이 `init_container` 계열로 내보낸다 — 캡을 씌워도 near-limit 알림은 무성이다
- `Container.args`는 patchMergeKey 없는 atomic 리스트다 — strategic-merge patch가 통째로 교체한다
- 파일 프리필터를 함께 넓히지 않으면 kind 추가가 vacuous green으로 착지한다
- A′는 회수 가능한 커널 slab을 분자에 싣는다 — 그 비중이 워크로드마다 100배 갈리고 peak 시점 값은 소급 측정이 불가능하다
- 자기조절 워크로드의 자기참조는 두 경로로 산다 — GOMEMLIMIT(힙)과 allowedPercent(캐시), 하나만 끊으면 되살아난다
- 측정 창이 기판 변경을 가로지르면 두 체제가 한 숫자에 섞인다
- sed 주소 범위는 시작 줄에서 끝나지 않는다 — 한 줄짜리 `{{- /* … */ -}}` 주석이 그 뒤를 통째로 지운다

## 멀티레포 앱 플로우 (App Platform DX — 요약)

**트리거 경계:** 앱 레포는 homelab-write 자격 0 (자기 `GITHUB_TOKEN`으로 GHCR push만).
인증은 GitHub App **3개**(2026-08-20 실측 `gh api /orgs/ukyi-app/installations`) —
reader `contents:read`(4043034) / writer `contents:write`+`pull_requests:write`+`issues:write`(4043080) /
dispatch `actions:write`(4178609, **키는 homelab이 아니라 앱 레포에** — `reusable-app-build.yaml`이
`workflow_call` 입력으로 받는다). reader/writer 키만 homelab Actions secret에 있다.
⚠️ **셋 다 설치 범위는 org 전체**(`repository_selection: all`)다 — "앱 레포 전용"·"homelab 전용"은
설치가 아니라 **발급 시점 `repositories:`/`owner` 파라미터**로만 성립한다(호출부 14곳 중 9곳은 둘 다
생략해 현재 레포로 기본 한정, 3곳은 명시, 2곳은 `owner`만 줘 org 범위 — 후자 둘은 의도적이고
호출부 주석이 근거를 담는다). **모든 homelab main 쓰기는 PR-first + auto-merge**
(App 토큰은 branch protection 우회 불가; required check `gate` 통과 시 자동 머지).

- **빌드:** 템플릿으로 레포 생성 → `.app-config.yml` 작성(계약: `tools/app-config-schema.json`)
  → main push → `reusable-app-build.yaml`(amd64+arm64 멀티아치→GHCR push + deploy-trigger 잡: `HOMELAB_DISPATCH_APP`
    시크릿 쌍 전달 시 homelab bump-poll 1회 디스패치로 크론 지연 제거, 미전달=clean skip·크론 백스톱).
- **생성 변이:** owner가 homelab에서 액션별 디스패처(workflow_dispatch) 실행 (변이 디스패처는 `vars.HOMELAB_OWNER` actor 가드로 owner 전용 — bump-poll/audit reconciler는 비대상) —
  `create-app`/`update-secrets`/`create-database`/`create-cache`/`teardown-app`(각 전용 워크플로). **파괴: `teardown-app`은
  디스패처(`🗑️ teardown-app` — confirm===app 가드 + **수동 머지**, reusable이 파괴 경계에서 confirm 재검증) + owner-local CLI(`make teardown-app`) 공존.
  `teardown-resource`·`activate-app`은 owner-local**(`make teardown-resource`·런북 — 데이터 파괴·attestation·purge 상태머신), **audit은 스케줄 reconciler**(`audit.yaml`).
  validator(`tools/validate-mutation.ts`)가 계약표 강제. 전역 직렬화: `concurrency: homelab-mutation` + `queue: max`.
- **update-image:** `bump-poll.yaml`(10분 주기 GHCR 폴링)이 권위 — main reachable + 배포 SHA
  descendant + digest 핀 검증 후 autoDeploy면 자동 PR+머지, 아니면 승인 PR(.bindings.json이
  autoDeploy SSOT, 누락=fail-closed). (인-레포 **앱 이미지** 전용.)
- **인프라/플랫폼 의존:** self-hosted Renovate(`renovate.json` + `renovate.yaml`, 주 1회, writer App
  토큰 PR-first, automerge 금지 → 리뷰 후 머지)가 서드파티 이미지 digest·terraform provider·
  k3s/local-path(versions.env)·helm 차트(Chart.yaml/CHART_VERSION/helmrelease)·npm을 갱신. **github-actions
  manager는 비활성** — `uses:` 핀 갱신은 토큰에 `workflows: write`가 필요한데 writer App은 Contents+PR
  write 전용이다. 켜려면: writer App에 workflows:write 부여 → renovate.yaml 토큰에 `permission-workflows: write`
  추가 → `renovate.json`의 `"github-actions".enabled=true`. (벤더 `charts/`·barman-plugin은 ignorePaths.)
- **공개(DNS):** create-app은 `infra/cloudflare/apps.json`에 `active:true`로 등록(PR 머지가 곧 공개 승인)
  → `iac.yaml`(push apply)/`tf-reconcile.yaml`(30분 드리프트 수렴)이 DNS/tunnel 노출.
  `tools/activate-app.ts` 게이트(descendant+표면 무변경+행 고정)는 host/public 변경 시 재노출 재승인 전용(owner-local CLI).
- **시크릿:** SealedSecrets(컨트롤러 `platform/sealed-secrets`, cert 공개) — 앱 레포에서
  `bun run secret:seal`(.env→`<app>-secrets.sealed.yaml`) → create-app/update-secrets가 봉인본 키를 검증·배선.
  sealing key는 `scripts/backup-sealed-secrets-key.sh`로 out-of-band 백업(복구 드릴 게이트).
- **teardown:** 앱(`teardown-app`)과 리소스(`teardown-resource`)는 분리 — 리소스는
  `.bindings.json` 참조 0 강제, retain(보존+tombstone) 기본, purge(--delete-data)는
  백업 검증 ID + 4단계 상태머신(owner 로컬 전용). `audit-orphans`가 드리프트 감시.

## 런북 (로컬 전용 — `docs/runbooks/`, git에 없음)

운영 절차 상세는 비공개 유지를 위해 로컬에만 둔다. 디스크 유실 대비 별도 백업 권장.

| 런북 | 내용 |
|---|---|
| `02-cloud-iac-bootstrap.md` | R2 상태 버킷·terraform·bootstrap 절차 |
| `age-keys.md` | age 2-recipient 키 모델/보관 |
| `app-platform.md` | App Platform 트리거 경계·Phase 0 체크리스트·activate-app/purge 절차 |
| `app-onboarding.md` | 앱 온보딩 체인(외부 레포 + 인레포) |
| `external-ssd.md` | `bulk-ssd` 티어 매체 배치 + DR 재결합(베어메탈 — 2026-08-17 재작성) |
| `host-substrate.md` | 베어메탈 NUC/k3s 호스트 계층 — 계층 경계·재구축 프리미티브·수용 증거 |
| `lan-dns.md` | AdGuard split-horizon + 라우터 DNS(R7) |
| `observability-bootstrap.md` / `observability-verify.md` | 관측성 셋업/검증 스윕 |
| `restore.md` | CNPG 복구(R1) — DR 핵심 |
| `storage-verify.md` | 스토리지 라이브 e2e 검증 |
| `teardown-resource.md` | DB/캐시 리소스 철거 — `--refs-verified` attestation·삭제 전 수동 확인·purge 상태머신(F1) |
| `db-cache-access.md` | DB/캐시 로컬·GUI 접속 — tailscale 직결·admin superuser·port-forward·롤백/자격 회수(F3) |
| `token-inventory.md` | 전 자격증명 인벤토리 — 만료 원장(`credential-expiry.json`) 동기화·회전 절차(메타갭 ④) |
| `toolchain.md` | 호스트 도구 핀 |

## Agent skills

### Issue tracker

이슈·스펙은 `.scratch/<feature-slug>/` 아래 로컬 마크다운 파일로 관리한다. See `docs/agents/issue-tracker.md`.

### Triage labels

기본 5종 라벨(needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix)을 그대로 사용한다. See `docs/agents/triage-labels.md`.

### Domain docs

단일 컨텍스트 — 루트 `CONTEXT.md` + 결정 기록 `docs/decisions/`(맨 번호 `ADR-NNNN`은 이 시리즈 전용)
+ 아키텍처 리뷰의 기각·유보 기록 `docs/adr/`(번호 독립 — 항상 경로로 인용: `docs/adr/0005`).
See `docs/agents/domain.md`.
