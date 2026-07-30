# GitHub ruleset 라이브 검증 — bump-poll/** writer-App 예약 (owner-local, tracked)

`infra/github`의 `github_repository_ruleset.bump_poll_writer_only`를 apply한 뒤, **실제 강제가
동작하는지**를 owner가 라이브로 확증하는 절차다. 운영 런북 본체(`docs/runbooks/`)는 gitignored라
CI·에이전트가 못 읽으므로, **이 절차만은 tracked**로 둔다(선례: `docs/runbooks-public/toolchain-setup.md`).

> **왜 라이브 검증이 필수인가**: CI 게이트(`tests/gates/test_bump_poll_ruleset.bats`)는 커밋된 *소스*가
> 리뷰된 정규형인지만 보는 **best-effort 변경 감지기**다. terraform의 resolved 의미는 `terraform plan`
> (GitHub API + 백엔드 자격)이 있어야 검증되는데, 신뢰 앵커 모델이 그 자격을 CI에서 배제한다.
> **게이트 green ≠ 강제 보증** — 강제는 라이브 룰셋 관측과 적대 push 실측으로만 확증된다.
> 룰셋 정의·설계 근거는 `infra/github/rulesets.tf` 헤더 주석이 SSOT다.

**실행 시점**: `infra/github` 루트에 룰셋 관련 apply를 한 직후. (apply는 owner-local 전용 — CI 무인 apply 금지.)

---

## 전제

| 항목 | 값/조건 |
|---|---|
| 셸 | **bash로 실행**(`bash <script>`). 아래 함수 블록을 zsh 프롬프트에 붙여넣으면 parse error가 난다 — 함정 절 참고 |
| 워킹트리 | 클린(프로브가 `HEAD`를 push한다) |
| `gh` | 인증됨(`gh auth status`) |
| apply 토큰 | `TF_VAR_github_token` — Administration write. **현행 설계에선 fine-grained/classic 무관**(룰셋이 App ID를 리터럴 핀해 `data.github_app`이 없다) |
| `OWNER_PAT` | **push 가능한 non-bypass 토큰** — classic `repo` scope. 가장 간단히 `gh auth token` |
| `WRITER_TOKEN` | writer App(`ukyi-homelab-writer`, App ID **4043080**) **설치 토큰**. `.env.secrets`에 없다 — private key(PEM)로 민팅(§토큰 민팅). PEM 미보유면 B3/B4는 실행 불가 → B1+B2까지만 하고 잔여를 정직히 기록 |

⚠️ **두 owner 토큰을 혼동 금지**: apply용 fine-grained `TF_VAR_github_token`은 Contents 권한이 없어
`git push`가 **auth 실패**한다. `OWNER_PAT`에 그걸 넣으면 B2가 "auth?"로 abort된다(거짓 인증은 아니나 진행 불가).

실행 위치는 레포 루트(terraform은 `-chdir=infra/github`). `OWNER`/`REPO`/`RID`는 실행 시 대입한다.

---

## B0. apply (owner-local — 신뢰 앵커)

```bash
# ⚠️ backend 캐시가 R2 자격 회전 前일 수 있다(실측: 캐시 2026-06-10 vs backend.hcl 2026-07-08 → 401).
#    backend.hcl 편집 없이 재초기화만으로 현재 자격을 로드한다(-upgrade 아님 — provider 버전 불변):
terraform -chdir=infra/github init -reconfigure -backend-config=backend.hcl
# ⚠️ `terraform init -upgrade` 금지 — provider lock 상향은 state provider-version 트랩.

set -a; source .env.secrets; set +a

# ⚠️ 룰셋만 -target 한다:
#   (a) telegram 값이 .env.secrets≠state라 전체 apply는 알림 자격을 덮어쓴다(실측),
#   (b) app_template has_issues/description 무관 드리프트도 비접촉.
#   룰셋 리소스는 자기 자신 외 의존이 없어 -target이 안전하다.
terraform -chdir=infra/github plan  -target=github_repository_ruleset.bump_poll_writer_only
terraform -chdir=infra/github apply -target=github_repository_ruleset.bump_poll_writer_only
```

기대 plan(신규 생성 시): `Plan: 1 to add, 0 to change, 0 to destroy` +
`enforcement=active · actor_id=4043080 · actor_type=Integration · bypass_mode=always ·
creation=true · update=true · include=["refs/heads/bump-poll/**"] · exclude=[]`.

⚠️ **`0 to add`가 뜨면 조용한 실패를 의심하라** — App ID 리터럴 핀을 slug data source로 되돌린 경우
fine-grained 토큰에서 `GET /apps/{slug}`가 404가 되어 data source가 죽고 룰셋이 계획에서 사라진다.

---

## B1. 룰셋 라이브 관측 (authoritative)

HCL 구조(주석 wrap·override·간접화·resolved 값)와 **무관하게** 실제 생성된 오브젝트를 본다.

```bash
OWNER=<owner>; REPO=homelab
gh api "/repos/$OWNER/$REPO/rulesets" --jq '.[] | {id, name, enforcement, target}'
# → bump-poll-writer-only / enforcement=active / target=branch

RID=<위 id>
gh api "/repos/$OWNER/$REPO/rulesets/$RID" --jq \
  '{target, conditions: .conditions.ref_name, rules: [.rules[].type], bypass: .bypass_actors}'
```

boolean assert(전부 참이어야 한다):

- `target == "branch"` · `enforcement == "active"`
- `conditions.ref_name.include == ["refs/heads/bump-poll/**"]` · `exclude == []`
- `rules ⊇ {creation, update}`
- `bypass_actors == [{actor_type:"Integration", actor_id:4043080, bypass_mode:"always"}]` — **정확히 1개**

`actor_id`가 writer App ID와 같은지가 핵심이다: 선언한 ID가 실제 Integration bypass로 저장돼야 강제가 성립한다.

---

## 토큰 민팅 — writer App 설치 토큰

PEM 보관 위치·회전 이력은 `docs/runbooks/token-inventory.md`(로컬 전용). 설치 토큰은 **약 1시간 만료**다.

```bash
APP_ID=4043080
PEM=<writer App private key .pem 경로>
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
pl=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$APP_ID" | b64url)
sig=$(printf '%s.%s' "$hdr" "$pl" | openssl dgst -sha256 -sign "$PEM" | b64url)
JWT="$hdr.$pl.$sig"

INST=$(curl -sS -H "Authorization: Bearer $JWT" -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$OWNER/$REPO/installation" | jq -r .id)
export WRITER_TOKEN=$(curl -sS -X POST -H "Authorization: Bearer $JWT" \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/app/installations/$INST/access_tokens" | jq -r .token)
```

---

## 안전 인증 헬퍼

push 거부가 **auth 실패**가 아니라 **ruleset 위반**임을 반드시 구분한다 — 안 그러면 auth 실패를
강제 성립으로 오인해 거짓 인증한다.

토큰은 **명령 치환으로 env에 주입**한다(리터럴 타이핑 0 = shell history 유출 0). `gpush`는 **역할 이름만**
받고 값은 env에서 해석하므로 시크릿-값 인자가 없다. `GIT_ASKPASS`가 env 토큰을 password로 공급하고,
`GIT_TERMINAL_PROMPT=0` + `credential.helper=`(비활성)로 프롬프트·캐시 신원 재사용을 차단한다.

```bash
export OWNER_PAT="$(gh auth token)"     # classic repo scope — push 가능·non-bypass
# WRITER_TOKEN은 위 "토큰 민팅" 절에서 export 됨.

printf '#!/usr/bin/env bash\necho "$GIT_TOKEN"\n' > /tmp/askpass.sh && chmod +x /tmp/askpass.sh

gpush() {   # $1=역할(owner|writer)  $2=refspec  [$3=--force]
  case "$1" in owner) t="$OWNER_PAT";; writer) t="$WRITER_TOKEN";; *) echo "역할?"; return 2;; esac
  GIT_TOKEN="$t" GIT_ASKPASS=/tmp/askpass.sh GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= push ${3:-} "https://x-access-token@github.com/$OWNER/$REPO.git" "$2" 2>&1
}

# 실패가 ruleset 위반인지 판정. auth 실패("Authentication failed"/"could not read Username"/403)는 매치 안 됨.
is_ruleset_reject() {
  grep -qiE 'GH006|GH013|protected by (a )?rule|repository rule|ruleset|(creation|update).*not allowed|cannot create'
}
```

---

## B2–B4. 적대 프로브 — **반드시 함수로 실행**

최상위 스니펫의 `return`은 무효라 abort되지 않는다. B3(writer push)가 실패했는데 B4가 계속 돌면
없는 ref에 creation을 재시험하고 그 거부를 "update 거부"로 오인해 **거짓 인증**한다.
그래서 B2→B3→B4를 하나의 함수에 담고, 각 단계는 실패 시 즉시 `return`한다.

```bash
probe_enforcement() {
  local probe="bump-poll/probe-$(date +%s)" wprobe="bump-poll/probe-writer-$(date +%s)" out oid upd rc

  echo "== B2: non-writer creation → 거부 기대 =="
  out="$(gpush owner "HEAD:refs/heads/$probe")"; echo "$out"
  printf '%s' "$out" | is_ruleset_reject || { echo "⚠️ B2 ruleset 위반 아님(auth?) — 중단"; return 1; }
  echo "✓ B2 creation 거부 = ruleset 위반"

  echo "== B3: writer push → 성공 기대 =="
  gpush writer "HEAD:refs/heads/$wprobe" || { echo "✗ B3 writer push 실패 — 중단(bypass 미동작?)"; return 1; }
  echo "✓ B3 writer push 성공(bypass)"

  echo "== B4: non-writer update → 거부 기대 (ref 실재 확인 후에만) =="
  oid="$(git ls-remote "https://github.com/$OWNER/$REPO.git" "refs/heads/$wprobe" | cut -f1)"
  [ -n "$oid" ] || { echo "✗ writer ref 원격 부재 — B4는 update가 아님, 중단"; return 1; }
  echo "  update 대상: refs/heads/$wprobe @ $oid"
  upd="$(git commit-tree "HEAD^{tree}" -p HEAD -m probe-update)"   # HEAD와 다른 OID, 워킹트리·HEAD 무변경
  out="$(gpush owner "$upd:refs/heads/$wprobe" --force)"; rc=$?; echo "$out"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | is_ruleset_reject; then
    echo "✓ B4 update 거부 = ruleset 위반(nonzero AND ruleset)"
  else
    echo "⚠️ B4 update가 안 막혔거나 ruleset 위반 아님 — false-certify 위험"
    gpush writer ":refs/heads/$wprobe" 2>/dev/null; return 1
  fi
  gpush writer ":refs/heads/$wprobe" 2>/dev/null || true   # 정리(삭제는 무제약)
  echo "✓ B2–B4 전부 통과 · probe ref 정리"
}
probe_enforcement; echo "probe_enforcement exit=$?"   # exit 0만 = 세 컨트롤 전부 실증
```

기대 관측:

- **B2** owner(non-bypass) creation → `GH013: Repository rule violations … Cannot create ref due to creations being restricted`
- **B3** writer App 설치 토큰 push → `Bypassed rule violations …` → 성공
- **B4** owner force-push(다른 OID) → `GH013: … Cannot update this protected ref`

### 실행 함정 (실측)

- **셸=zsh**: `read -rs -p "..."`는 bash 전용 — zsh에선 `read: -p: no coprocess`로 실패하고 변수가 **빈 채**
  남아 빈 토큰 push→auth 실패로 abort된다(fail-closed라 거짓 인증은 아니지만 진행 불가).
  위 절차는 `read`를 아예 안 쓰고 명령 치환으로 주입한다.
- **다중행 함수 붙여넣기도 zsh에서 parse error** → 헬퍼+프로브를 **스크립트 파일에 쓰고 `bash <file>`로 실행**한다.

## B4b. 시크릿 해제

```bash
unset OWNER_PAT WRITER_TOKEN; rm -f /tmp/askpass.sh
```

---

## B5. auto-delete-on-merge 무영향 (회귀 가드)

룰셋이 `creation`/`update`만 제약하므로 삭제는 무제약 → `delete_branch_on_merge`가 평소대로 동작해야 한다.
(B2–B4에서 probe ref가 정상 삭제됐다면 구조적으로는 이미 확인된 것이다.)

```bash
gh api "/repos/$OWNER/$REPO" --jq '.delete_branch_on_merge'      # true 기대
# 다음 bump-poll PR auto-merge 후:
gh api "/repos/$OWNER/$REPO/branches" --jq '.[].name' | grep '^bump-poll/' \
  || echo "잔존 bump-poll 브랜치 없음(정상)"
```

⚠️ 잔존 `bump-poll/*` 브랜치가 보여도 곧바로 룰셋 회귀로 단정하지 마라 — 결정적 브랜치명 도입(#364) 이전의
옛 좀비 브랜치(`autoMerge:false`라 inert)가 섞여 있을 수 있다. 커밋 날짜·PR 번호로 구분한다.

---

## 롤백

writer 정상 경로까지 막히는 등 이상 시:

```bash
# 즉시 완화 — enforcement=disabled 토글(UI 또는 API)
gh api --method PUT "/repos/$OWNER/$REPO/rulesets/$RID" -f enforcement=disabled
```

또는 `infra/github/rulesets.tf`에서 `enforcement = "disabled"`로 바꿔 apply(선호 — 드리프트 미발생),
그래도 안 되면 룰셋 삭제 후 재설계. 삭제는 룰셋 자체로 제약되지 않으므로 bump-poll 브랜치 정리는 언제든 가능하다.

---

## 기록 규칙

- 이 절차의 **어떤 토큰/시크릿 값도 문서·로그·채팅에 기입하지 않는다**(placeholder만).
- 기록하는 것은 성공/거부 여부와 **비밀이 아닌 식별자**(ruleset id, App id)뿐이다.
- PEM 미보유로 B3/B4를 못 돌렸다면 "B1+B2 부분 인증, B3/B4 미실행"이라고 **정직하게** 남긴다 —
  부분 실행을 전체 통과로 기록하는 것이 이 절차 전체를 무의미하게 만드는 유일한 실패 모드다.
