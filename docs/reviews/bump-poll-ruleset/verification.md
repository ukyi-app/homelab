# Verification — bump-poll/** writer App 예약 ruleset (F-0)

이 파일은 두 층의 검증을 담는다:
- **B. owner-local Seam C — resolved 의미의 권위·필수 검증**(아래, 이 티켓 산출): apply 후 owner가 실행한다.
  정적 CI 가드(Seam B)는 커밋 소스가 리뷰된 정규형인지만 보는 **best-effort 변경 감지기**다 — red-team/게이트가
  보였듯 간접화·decoy·meta-arg·주석 wrap·override로 우회 가능하고, terraform resolved 의미는 `terraform plan`
  (신뢰 앵커라 CI에서 배제된 자격)이 필요해 CI에서 검증 불가. **실제 강제는 라이브 룰셋 관측으로만 확증된다.**
- **A. CI 검증(브랜치 HEAD)**: Stage 5에서 전체 스위트 결과·SHA를 아래에 추가한다.

---

## B. owner-local Seam C 절차 (apply 후 owner가 실행 — 결과는 실행 시 기입)

전제: owner admin PAT(`TF_VAR_github_token`, rulesets 관리 권한) + writer App 설치 확인 + `gh` 인증.
환경: 레포 루트에서 실행(terraform은 `-chdir=infra/github`). 실제 값(owner/repo/id/token)은 실행 시 대입.
(Seam C = spec Testing Decisions의 owner-local 적대 라이브 검증 — 정적 Seam B가 못 잡는 resolved 의미의 권위 검증.)

### B0. apply (owner-local — 신뢰 앵커, CI 무인 apply 금지)
```bash
# .env.secrets의 TF_VAR_github_* 로드 후
terraform -chdir=infra/github plan    # bump_poll_writer_only 생성 1건 확인(다른 변경 0)
terraform -chdir=infra/github apply   # data.github_app.writer가 App ID로 해석되는지 이 시점에 실측
```
결과: __(apply 성공 / add=1 change=0 destroy=0)__

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
결과: __(target/include/exclude/rules/bypass 일치 · bypass actor_id = writer App ID = ____)__
★ ④ App 능력 실측: data source가 준 id가 Integration bypass로 실제 동작함이 여기서 확증된다(fine-grained App 능력은 실제 시도로만).

### 안전 인증 헬퍼 (토큰은 argv·URL·shell history 어디에도 안 남긴다)
push 거부가 **auth 실패**가 아니라 **ruleset 위반**임을 반드시 구분한다(안 그러면 auth 실패를 강제로 오인해 거짓
인증). 토큰은 **`read -s`로 env에 로드**(입력값은 에코·history 미기록)하고, 명령엔 **역할 이름만** 쓴다 — 리터럴
토큰을 타이핑하지 않으므로 shell history 유출 0(RL-1a). `GIT_ASKPASS`가 env 토큰을 password로 공급,
`GIT_TERMINAL_PROMPT=0` + credential.helper 비활성으로 프롬프트·캐시 신원 재사용 차단. (전제: 워킹트리 클린.)
```bash
read -rs -p "owner PAT (bypass 아님): " OWNER_PAT; echo
read -rs -p "writer App 설치 토큰 (bypass): " WRITER_TOKEN; echo
printf '#!/usr/bin/env bash\necho "$GIT_TOKEN"\n' > /tmp/askpass.sh && chmod +x /tmp/askpass.sh
gpush() { # $1=역할(owner|writer)  $2=refspec  [$3=--force] — 시크릿-값 인자 없음(역할→env 해석)
  case "$1" in owner) t="$OWNER_PAT";; writer) t="$WRITER_TOKEN";; *) echo "역할?"; return 2;; esac
  GIT_TOKEN="$t" GIT_ASKPASS=/tmp/askpass.sh GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= push ${3:-} "https://x-access-token@github.com/$OWNER/$REPO.git" "$2" 2>&1
}
# 실패가 ruleset 위반인지(auth 실패 아님) — auth 실패("Authentication failed"/"could not read Username"/403)는 매치 안 됨.
is_ruleset_reject() { grep -qiE 'GH006|protected by (a )?rule|repository rule|ruleset|(creation|update).*not allowed|cannot create'; }
```

### B2. 적대 push — non-writer 거부(creation)
owner PAT는 bypass가 아니므로 bump-poll/* 생성이 거부돼야 한다(네임스페이스 머신 전용). 거부가 **ruleset 위반**임을 확인.
```bash
probe="bump-poll/probe-$(date +%s)"
out="$(gpush owner "HEAD:refs/heads/$probe")"; echo "$out"
printf '%s' "$out" | is_ruleset_reject && echo "✓ creation 거부 = ruleset 위반" || echo "⚠️ ruleset 위반 아님(auth?) — 위 out 조사"
```
결과: __(ruleset 위반으로 거부 확인 — 마커: ______)__

### B3. writer push — 성공(bypass) · 실패 시 중단
writer App 토큰으로 동일 네임스페이스 push는 성공해야 한다. **실패하면 B4가 update를 시험할 수 없으므로 즉시 중단**(RL-1b).
```bash
wprobe="bump-poll/probe-writer-$(date +%s)"
gpush writer "HEAD:refs/heads/$wprobe" || { echo "✗ B3 writer push 실패 — 중단(B4 update 검증 불가). bypass 미동작?"; return 1; }
echo "✓ writer push 성공(bypass)"
```
결과: __(성공 확인)__

### B4. 적대 force-push — non-writer 거부(update)
**먼저** writer-생성 ref가 원격에 실재함을 확인한다(없으면 B4는 update가 아니라 creation을 시험하게 되어 거짓 인증 —
RL-1b). 그다음 **다른 커밋**(commit-tree — HEAD·워킹트리 무변경)을 owner PAT로 force-push → **nonzero + ruleset
위반** 둘 다여야 update 강제로 인정.
```bash
oid="$(git ls-remote "https://github.com/$OWNER/$REPO.git" "refs/heads/$wprobe" | cut -f1)"
[ -n "$oid" ] || { echo "✗ writer ref 원격 부재 — B4는 update가 아님, 중단"; return 1; }
echo "update 대상 확인: refs/heads/$wprobe @ $oid"
upd="$(git commit-tree "HEAD^{tree}" -p HEAD -m probe-update)"   # HEAD와 다른 OID, 워킹트리·HEAD 무변경
out="$(gpush owner "$upd:refs/heads/$wprobe" --force)"; rc=$?
echo "$out"
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | is_ruleset_reject; } && echo "✓ update 거부 = ruleset 위반(nonzero+ruleset)" || echo "⚠️ update가 안 막혔거나 ruleset 위반 아님 — 조사(false-certify 위험)"
```
결과: __(update가 ruleset 위반으로 거부 확인 — nonzero+마커)__

### B4b. 정리 + 시크릿 해제
```bash
gpush writer ":refs/heads/$wprobe" 2>/dev/null || true   # probe ref 삭제(삭제는 무제약)
unset OWNER_PAT WRITER_TOKEN; rm -f /tmp/askpass.sh
```

### B5. auto-delete-on-merge 무영향(회귀 가드)
creation/update만 제약하므로 삭제는 무제약 → `delete_branch_on_merge`가 평소대로 동작.
실제 bump PR auto-merge 후 head 브랜치가 정상 자동 삭제되는지(고아 없음) 확인.
```bash
# 다음 bump-poll PR auto-merge 후:
gh api "/repos/$OWNER/$REPO/branches" --jq '.[].name' | grep '^bump-poll/' || echo "잔존 bump-poll 브랜치 없음(정상)"
```
결과: __(머지 후 head 자동 삭제 확인 — 고아 0)__

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
