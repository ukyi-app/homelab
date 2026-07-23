# Verification — bump-poll/** writer App 예약 ruleset (F-0)

이 파일은 두 층의 검증을 담는다:
- **B. owner-local Seam C — resolved 의미의 권위·필수 검증**(아래, 이 티켓 산출): apply 후 owner가 실행한다.
  정적 CI 가드(Seam B)는 커밋 소스가 리뷰된 정규형인지만 보는 **best-effort 변경 감지기**다 — red-team/게이트가
  보였듯 간접화·decoy·meta-arg·주석 wrap·override로 우회 가능하고, terraform resolved 의미는 `terraform plan`
  (신뢰 앵커라 CI에서 배제된 자격)이 필요해 CI에서 검증 불가. **실제 강제는 라이브 룰셋 관측으로만 확증된다.**
- **A. CI 검증(브랜치 HEAD)**: Stage 5에서 전체 스위트 결과·SHA를 아래에 추가한다.

---

## B. owner-local Seam C 절차 (apply 후 owner가 실행 — 결과는 실행 시 기입)

전제: (1) B0 apply용 owner 토큰 = **`data.github_app.writer` slug 해석이 되는 토큰**. ⚠️ **라이브 실측(2026-07-23)**: `.env.secrets`의 fine-grained `TF_VAR_github_token`은 `/repos/../rulesets`엔 200이지만 **`GET /apps/{slug}`엔 404** — GitHub fine-grained PAT는 이 "공개" App 엔드포인트를 못 읽어 data source가 죽고 룰셋이 `0 to add`가 된다(rulesets.tf 주석 "공개라 특수 권한 불요"는 fine-grained엔 틀림). → **apply 시 `TF_VAR_github_token`을 classic 토큰으로 오버라이드**(`gh auth token` = ukkiee, `/apps`·`/rulesets` 둘 다 200 실측). (2) B2/B4 owner push용 `OWNER_PAT` = **push 가능한 non-bypass 토큰**(classic `repo` scope 또는 Contents:write; 예: `gh auth token`). (3) B3/B4 writer push용 `WRITER_TOKEN` = **writer App(ukyi-homelab-writer, App ID 4043080) 설치 토큰** — `.env.secrets`에 없다. 로컬 민팅엔 writer App **private key(PEM)**가 필요(token-inventory 참조). PEM 미보유면 B3/B4는 실행 불가 → B1(config authoritative)+B2(creation live)로 부분 인증(잔여 정직 기입). + `gh` 인증.
환경: 레포 루트에서 실행(terraform은 `-chdir=infra/github`). 실제 값(owner/repo/id/token)은 실행 시 대입.
(Seam C = spec Testing Decisions의 owner-local 적대 라이브 검증 — 정적 Seam B가 못 잡는 resolved 의미의 권위 검증.)

### B0. apply (owner-local — 신뢰 앵커, CI 무인 apply 금지)
```bash
# ⚠️ backend 캐시가 R2 회전 前 자격일 수 있다(실측: 캐시 2026-06-10 vs backend.hcl 2026-07-08 → 401).
#    backend.hcl 편집 없이 재초기화만으로 현재 자격 로드(‑upgrade 아님 — provider 버전 불변):
terraform -chdir=infra/github init -reconfigure -backend-config=backend.hcl
# 시크릿 로드: .env.secrets는 TELEGRAM 값 + fine-grained TF_VAR_github_token.
set -a; source .env.secrets; set +a
# ⚠️⚠️ github_token은 classic으로 오버라이드(위 전제 — fine-grained는 /apps/{slug} 404 → data source 죽음).
# ⚠️ 룰셋만 -target: (a) telegram이 .env.secrets≠state로 update in-place로 떠서 전체 apply는 알림 자격을 덮는다(실측),
#    (b) app_template has_issues/description 무관 드리프트도 비접촉. 룰셋은 자기 data source만 의존.
TF_VAR_github_token="$(gh auth token)" terraform -chdir=infra/github plan \
  -target=github_repository_ruleset.bump_poll_writer_only
# 기대(실측 2026-07-23): "Plan: 1 to add, 0 to change, 0 to destroy" +
#   github_repository_ruleset.bump_poll_writer_only: enforcement=active · actor_id=4043080 ·
#   actor_type=Integration · bypass_mode=always · creation=true · update=true ·
#   include=[refs/heads/bump-poll/**] · exclude=[]
#  ⚠️ `terraform init -upgrade` 금지(lock=6.12.1 — 버전 상향은 state provider-version 트랩).
TF_VAR_github_token="$(gh auth token)" terraform -chdir=infra/github apply \
  -target=github_repository_ruleset.bump_poll_writer_only
# (telegram 드리프트·app_template 재수렴을 별도로 정리하려면 그건 F-0와 분리된 후속 apply로.)
```
결과: **✅ 2026-07-23 apply 성공** — `Apply complete! Resources: 1 added, 0 changed, 0 destroyed`. ruleset id=19598965 · actor_id=4043080 · Plan 1 to add(-target). (fine-grained 404 회피 위해 `TF_VAR_github_token=$(gh auth token)` 오버라이드 + backend `init -reconfigure`로 R2 회전 자격 로드 필요했다.)

### B1. 룰셋 라이브 관측 — 정적 가드가 못 잡는 것을 잡는 authoritative 체크
HCL 구조(주석 wrap·override·removed·resolved 값)와 무관하게 **실제 생성된 룰셋**을 본다.
```bash
OWNER=<owner>; REPO=homelab
gh api "/repos/$OWNER/$REPO/rulesets" --jq '.[] | {id, name, enforcement, target}'
# → bump-poll-writer-only / enforcement=active / target=branch 확인
RID=<위 id>
gh api "/repos/$OWNER/$REPO/rulesets/$RID" --jq \
  '{target, conditions: .conditions.ref_name, rules: [.rules[].type], bypass: .bypass_actors}'
# 기대: conditions.ref_name.include=["refs/heads/bump-poll/**"], exclude=[]
#       rules ⊇ {creation, update}
#       bypass_actors = [ {actor_type:"Integration", actor_id:<writer App ID>, bypass_mode:"always"} ] — 정확히 1개
```
결과: **✅ 2026-07-23 boolean assert = true** (RID=19598965) — target=branch · enforcement=active · include=["refs/heads/bump-poll/**"] · exclude=[] · rules=[creation,update] · bypass=[{Integration, actor_id=**4043080**, always}] 정확히 1개. **bypass actor_id = writer App ID = 4043080** 확증(질문 ④: data source가 준 id가 실제 Integration bypass로 저장됨).
★ ④ App 능력 실측: data source가 준 id가 Integration bypass로 실제 동작함이 여기서 확증된다(fine-grained App 능력은 실제 시도로만).

### 안전 인증 헬퍼 (토큰은 argv·URL·shell history 어디에도 안 남긴다)
push 거부가 **auth 실패**가 아니라 **ruleset 위반**임을 반드시 구분한다(안 그러면 auth 실패를 강제로 오인해 거짓
인증). 토큰은 **`read -s`로 env에 로드**(입력값은 에코·history 미기록)하고, 명령엔 **역할 이름만** 쓴다 — 리터럴
토큰을 타이핑하지 않으므로 shell history 유출 0(RL-1a). `GIT_ASKPASS`가 env 토큰을 password로 공급,
`GIT_TERMINAL_PROMPT=0` + credential.helper 비활성으로 프롬프트·캐시 신원 재사용 차단. (전제: 워킹트리 클린.)
⚠️ **두 owner 토큰을 혼동 금지**: B0 apply에 쓴 `TF_VAR_github_token`(fine-grained Administration)은 **Contents 권한이
없어 git push가 auth 실패**한다 → 아래 `OWNER_PAT`에 그걸 쓰면 B2가 "auth?"로 abort(거짓 인증은 아니나 진행 불가).
`OWNER_PAT`엔 **push 가능한 non-bypass 토큰**(classic `repo` scope)을 넣어라 — 가장 간단히 `gh auth token`.
`WRITER_TOKEN`은 writer App 설치 토큰(bypass) — PEM으로 민팅(전제 참조·~1h 만료). PEM 미보유면 B2까지만.
⚠️ **셸=zsh 함정(실측 2026-07-23)**: `read -rs -p "..."`는 **bash 전용** — zsh에선 `-p`가 coprocess라 `read: -p: no coprocess`로
실패하고 변수가 **빈 채** 남아 빈 토큰 push→auth 실패로 B2가 abort된다(거짓 인증은 아니나 진행 불가). 두 토큰 다 **명령 치환**으로
오니(리터럴 타이핑 0 = history 유출 0, RL-1a 유지) `read` 자체가 불요 — 직접 대입한다:
```bash
export OWNER_PAT="$(gh auth token)"                         # classic repo scope, push 가능·non-bypass
# WRITER_TOKEN: 위 "writer 설치 토큰 민팅" 블록으로 세팅(iss=4043080, PEM 서명). 리터럴을 붙여야 하면 zsh는 read "VAR?prompt".
printf '#!/usr/bin/env bash\necho "$GIT_TOKEN"\n' > /tmp/askpass.sh && chmod +x /tmp/askpass.sh
gpush() { # $1=역할(owner|writer)  $2=refspec  [$3=--force] — 시크릿-값 인자 없음(역할→env 해석)
  case "$1" in owner) t="$OWNER_PAT";; writer) t="$WRITER_TOKEN";; *) echo "역할?"; return 2;; esac
  GIT_TOKEN="$t" GIT_ASKPASS=/tmp/askpass.sh GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= push ${3:-} "https://x-access-token@github.com/$OWNER/$REPO.git" "$2" 2>&1
}
# 실패가 ruleset 위반인지(auth 실패 아님) — auth 실패("Authentication failed"/"could not read Username"/403)는 매치 안 됨.
is_ruleset_reject() { grep -qiE 'GH006|protected by (a )?rule|repository rule|ruleset|(creation|update).*not allowed|cannot create'; }
```

### B2–B4. 적대 프로브 — **함수로 실행**(최상위 스니펫에선 `return`이 무효라 abort 안 됨 — RL-1b)
B2(non-writer creation 거부) → B3(writer 성공, 실패 시 abort) → B4(update 거부, ref 실재 확인 후에만) 순서를
**하나의 함수** `probe_enforcement`에 담는다. 함수 안에서만 `return`이 실제로 실행을 종료하므로, B3 실패나 ref
부재가 **owner push·성공 메시지에 도달하지 못한다**(거짓 인증 차단). 각 단계는 실패 시 즉시 return.
```bash
probe_enforcement() {
  local probe="bump-poll/probe-$(date +%s)" wprobe="bump-poll/probe-writer-$(date +%s)" out oid upd rc
  echo "== B2: non-writer creation → 거부 기대 =="
  out="$(gpush owner "HEAD:refs/heads/$probe")"; echo "$out"
  printf '%s' "$out" | is_ruleset_reject || { echo "⚠️ B2 ruleset 위반 아님(auth?) — 중단"; return 1; }
  echo "✓ B2 creation 거부 = ruleset 위반"

  echo "== B3: writer push → 성공 기대 =="
  gpush writer "HEAD:refs/heads/$wprobe" || { echo "✗ B3 writer push 실패 — 중단(B4 update 검증 불가·bypass 미동작?)"; return 1; }
  echo "✓ B3 writer push 성공(bypass)"

  echo "== B4: non-writer update → 거부 기대 (ref 실재 확인 후에만) =="
  oid="$(git ls-remote "https://github.com/$OWNER/$REPO.git" "refs/heads/$wprobe" | cut -f1)"
  [ -n "$oid" ] || { echo "✗ writer ref 원격 부재 — B4는 update 아님, 중단(creation 재시험 방지)"; return 1; }
  echo "  update 대상: refs/heads/$wprobe @ $oid"
  upd="$(git commit-tree "HEAD^{tree}" -p HEAD -m probe-update)"   # HEAD와 다른 OID, 워킹트리·HEAD 무변경
  out="$(gpush owner "$upd:refs/heads/$wprobe" --force)"; rc=$?; echo "$out"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | is_ruleset_reject; then
    echo "✓ B4 update 거부 = ruleset 위반(nonzero+ruleset)"
  else
    echo "⚠️ B4 update가 안 막혔거나 ruleset 위반 아님 — false-certify 위험"
    gpush writer ":refs/heads/$wprobe" 2>/dev/null; return 1
  fi
  gpush writer ":refs/heads/$wprobe" 2>/dev/null || true   # 정리(삭제는 무제약)
  echo "✓ B2–B4 전부 통과 · probe ref 정리"
}
probe_enforcement; echo "probe_enforcement exit=$?"   # exit 0만 = 세 컨트롤 전부 실증
```
결과: **✅ 2026-07-23 probe exit=0** — 세 컨트롤 전부 라이브 실증:
- **B2** owner(ukkiee, non-bypass) creation → `GH013: Repository rule violations … Cannot create ref due to creations being restricted` → 거부 ✓ (org owner/repo admin도 암묵 bypass 없음 확인 — bypass는 actor 리스트가 유일).
- **B3** writer App(4043080) 설치 토큰 push → `Bypassed rule violations …` → 성공(bypass 동작) ✓.
- **B4** owner force-push(commit-tree 다른 OID → 기존 writer ref) → `GH013: … Cannot update this protected ref` → 거부 ✓.
- `is_ruleset_reject`가 GH013을 커버(GH006 아닌 GH013로 옴 — 하드닝 패턴이 "repository rule"/"cannot create"/"creations…restricted"로 포착). probe ref 정리 완료.
- ⚠️ 실행 함정 실측: **셸=zsh라 `read -rs -p`가 깨짐**(no coprocess) → 토큰 미설정 → 빈 push auth 실패로 fail-closed(거짓 인증 아님). **다중행 함수 붙여넣기도 zsh parse error** → **스크립트 파일+bash 실행**으로 우회(위 헬퍼 절 정정). 토큰은 `gh auth token`/PEM 민팅(명령 치환)으로 env 주입 — 리터럴 0.

### B4b. 시크릿 해제 (probe ref는 probe_enforcement가 이미 정리)
```bash
unset OWNER_PAT WRITER_TOKEN; rm -f /tmp/askpass.sh
```

### B5. auto-delete-on-merge 무영향(회귀 가드)
creation/update만 제약하므로 삭제는 무제약 → `delete_branch_on_merge`가 평소대로 동작.
실제 bump PR auto-merge 후 head 브랜치가 정상 자동 삭제되는지(고아 없음) 확인.
```bash
# 다음 bump-poll PR auto-merge 후:
gh api "/repos/$OWNER/$REPO/branches" --jq '.[].name' | grep '^bump-poll/' || echo "잔존 bump-poll 브랜치 없음(정상)"
```
결과: **✅ 2026-07-23 무영향 확인(구조)** — 룰셋 rules=[creation, update]만(deletion 미설정) + 라이브 `delete_branch_on_merge:true` → auto-delete 경로 무제약. probe ref(bump-poll/probe-*)는 삭제 성공(정리됨 = 삭제가 막히지 않음 실증). **full B5**(실제 bump PR auto-merge 후 head 자동 삭제)는 다음 bump-poll 주기에 자연 확인.
⚠️ **별건 관측(F-0 아님)**: 잔존 `bump-poll/*` 브랜치 5개 = **#364 결정적 브랜치명 이전의 옛 좀비**(RUN_ID 접미사·writer[bot] 커밋 2026-07-09/13·**autoMerge:false=무장 안 됨·inert**): PR #331·#332·#348·#350·#351. 이건 **F-2(superseded 형제 PR 자동 close)** 대상이지 룰셋/probe 산물이 아니다. 룰셋 deletion 무제약이라 정리는 언제든 가능(F-2에서).

### 롤백 (B2~B4가 writer 정상 경로까지 막는 등 이상 시)
```bash
# 즉시 완화: enforcement=disabled 로 토글(UI 또는)
gh api --method PUT "/repos/$OWNER/$REPO/rulesets/$RID" -f enforcement=disabled ...
# 또는 terraform으로 enforcement="disabled" 후 apply, 또는 룰셋 삭제 후 재설계.
```

> 주의: 이 절차의 어떤 토큰/시크릿 값도 이 파일에 기입하지 않는다(placeholder만). 결과는 성공/거부 여부와 관측된
> 비밀 아닌 식별자(룰셋 id, App id)만 기록한다.

---

## A. CI 검증(브랜치 HEAD) — Stage 5 (2026-07-22)

verified SHA: `0cd1e3b` · tree: `ec9f78a` · 작업트리 클린.

| 검사 | 명령 | 결과 |
|---|---|---|
| 전체 bats 게이트 | `./scripts/run-bats.sh` | exit 0 · **1368 ok / 0 not-ok** (canonical 3층 가드 16 + traps-sync 3 포함) |
| terraform validate(3 루트) | `make tf-validate` | cloudflare·tailscale·**github** 전부 validated |
| 타입체크 | `bun run typecheck` (tsc --noEmit) | exit 0 |
| 기반 게이트 | `make verify` | skeleton·doc-index·bats-accounting·resource-limits·alert-rules·netpol·image-pins·sops 왕복 전부 OK |
| traps 원장 | `bash scripts/verify-traps.sh` · `bats tests/gates/test_traps-sync.bats` | 양방향 tie OK · 3/3 |

랜딩 판정: 브랜치 자체 표면 green(위). required check `gate`는 정상 CI 환경에서 전량 재실행한다.
(참고: `make ci` 전체는 환경 행 2건 — `test_sealed-secrets-restore.bats`(docker)·`test_dev-postgres.bats`(라이브 postgres) —
이 브랜치 diff와 무관한 로컬 환경 결손이라 위 개별 게이트로 대체 확인.)
