#!/usr/bin/env bats
# bump-poll **호출부 계약** — 원격 변이(브랜치 push·PR 생성·auto-merge 무장)는 오직 tools/ensure-bump-pr.ts를
# 통해서만.
#
# 왜 이 게이트가 필요한가(plan r2 R-4): ensure-bump-pr가 아무리 옳게 판정해도, 워크플로가 도구를
# 부르기 **전에** 스스로 push/create를 하면 프로덕션은 그대로 중복 PR을 낸다(도구만 GREEN). 순서·부작용
# 계약을 프로덕션 호출부에 못 박아야 그 false-green이 닫힌다.
#   ① `gh pr create` 직접 호출 0 — PR 생성은 도구가 관측(gh pr list + git ls-remote) 뒤에만 한다.
#   ② `git push` 직접 호출 0 — skip 판정이 "아무것도 변이하지 않음"이 되려면 push도 도구 몫이어야 한다.
#      (워크플로가 먼저 push하면: 판정이 skip이어도 원격 브랜치가 갱신되고, `gh pr create` 실패 시엔
#       **고아 원격 브랜치**가 남아 다음 주기 plain push와 non-fast-forward 충돌 → 배포 정지.)
#   ③ 브랜치명에 RUN_ID 없음 — run마다 브랜치가 달라지면 "이 bump의 열린 PR"을 조회할 대상 자체가 없다.
#   ④ **순서**(plan r4 R-8): 브랜치 생성 → bump-tag → commit → ensure-bump-pr. 도구는 "호출부가 브랜치를
#      최신 main에서 재구축해 **로컬 커밋을 얹어 둔** 상태"를 전제로 `HEAD`를 민다(push argv 계약의 소스가
#      HEAD다). 커밋 전에 도구를 부르면 빈 커밋(=main과 동일)을 밀어 PR이 diff 0으로 열리고, bump-tag 전에
#      부르면 갱신 자체가 빠진다 — 둘 다 "테스트는 GREEN, 배포는 무동작"이다. ①②③만으론 순서가 안 잡힌다.
#   ⑤ **auto-merge 독점**(plan r4 R-8): 워크플로는 `scripts/auto-merge-or-fail.sh`를 **직접 부르지 않는다**.
#      auto-merge는 실행기 안에서만 무장한다. 워크플로가 따로 부르면 skip/rebuild 판정(=PR 생성 없음)에도
#      머지가 무장돼, 남의 PR이나 옛 PR을 건드릴 수 있다(이중 auto-merge).
#      ⚠️ 이 금지는 **bump-poll.yaml 파일 안에서만**이다 — 스크립트 자체는 bump.yaml·pr-first-commit
#      composite·ensure-bump-pr.ts가 계속 쓴다(아래 보존 증인이 그걸 고정한다).
#   ⑥ **레인 매핑**(plan r5 R-11): 승인 게이트 우회를 **구조적으로** 불가능하게 만든다.
#      ⚠️ ⑤만으로는 부족하다: "워크플로 어딘가에 `--auto-merge` 토큰이 있으면 통과"하는 게이트는,
#      두 레인 **모두에 무조건** 그 플래그를 넘기는 구현도 GREEN으로 통과시킨다 → `autoDeploy:false`
#      승인 PR이 자동 배포된다(단일 flip 밖의 **두 번째 행위 변경** + 승인 게이트 우회).
#      봉인은 세 겹이고, 셋이 함께여야 성립한다:
#        (a) 실행기에 auto-merge를 켜는 **플래그가 없다** — 레인(`--action`)이 유일한 입력이다.
#            (도구 스위트: "there is no flag that can arm auto-merge outside the bump lane")
#        (b) 실행기는 `--action bump`에서만 무장하고 `propose-pr`에선 **절대** 무장하지 않는다.
#            (도구 스위트: "the propose-pr lane NEVER arms auto-merge")
#        (c) 호출부는 레인을 **재해석하지 않고** 플래너의 `.action`을 **그대로** 넘긴다 — 워크플로는
#            plan.json에 손댈 자리가 없고(bump 스텝 = 러너 호출 한 줄), 러너는 읽은 값을 그대로 실행기에
#            넘긴다(아래 정적 증인 + `tools/tests/test_run-bump-plan.bats`의 실행 증인).
#      → 승인 레인을 자동 배포로 바꾸려면 플래너를 속여야 하고, 플래너의 레인은 `.bindings.json`의
#        autoDeploy(SSOT)에서 온다(poll-ghcr.ts: `action: s.autoDeploy ? "bump" : "propose-pr"`).
#        즉 **워크플로 편집만으로는 승인 게이트를 넘을 수 없다** — 그게 이 계약의 요점이다.
#
# ── ★ 계약의 분할(F-1: 항목 러너 이관) ─────────────────────────────────────────────────────────
# 항목 오케스트레이션(브랜치 생성 → 태그 갱신 → commit → 실행기)은 이제 **인-워크플로 셸 루프가 아니라**
# 테스트된 도구 `tools/run-bump-plan.ts`가 소유한다. 그래서 이 파일의 계약도 둘로 갈린다:
#   · **호출부 경계**(이 파일): 워크플로가 직접 push/PR 생성/auto-merge 하지 않고, bump 스텝의 명령이
#     **러너 호출 하나뿐**이며(= 플래너 출력을 중간에 손댈 자리가 없다), 회수 job이 플래너와 독립이다.
#   · **항목 처리**(`tools/tests/test_run-bump-plan.bats`): 순서·레인 verbatim·격리·소유권(정체성+메시지)·
#     fail-closed 집계. 옛 증인들은 **YAML에서 셸 본문을 뽑아 stub git 아래 돌리는** 하네스였는데, 러너
#     스위트는 **진짜 git worktree**에서 같은 사실을 관측한다(흉내낼 의미가 없으니 실효값이 곧 관측값이다).
#     ⇒ 이관은 **무약화**다: 각 증인이 어디로 갔는지는 아래 각 삭제 지점의 주석이 짚는다.
#
# ── 구현자 가이드(이 파일의 증인들이 GREEN이 되려면 bump 스텝이 이렇게 생겨야 한다) ──────────────────
#   - name: bump → PR …
#     env: { GH_TOKEN: <writer 토큰> }
#     run: |
#       bun tools/run-bump-plan.ts --plan /tmp/plan.json     # ← 주석을 빼면 **이 한 줄이 전부**다
#   # ③ 브랜치명에 RUN_ID 금지·④ 순서·⑥ 레인 verbatim은 전부 러너 안에서 성립하고 러너 스위트가 증명한다.
#   # ⑤ `git push`·`gh pr create`·`bash scripts/auto-merge-or-fail.sh`는 이 파일 어디에도 남지 않는다.
#   # ⑥ 레인을 켜는 **플래그는 워크플로에도 러너에도 없다** — 플래너의 `.action`이 유일한 입력이다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]]·중간 `!`는 침묵 통과.
# ⚠️ @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/bump-poll.yaml"
  SWEEPER="$ROOT/.github/workflows/pr-sweeper.yaml"
  EXECUTOR="$ROOT/tools/ensure-bump-pr.ts"
  # 항목 러너 — bump 레인의 **호출부**가 여기로 옮겨왔다(F-1). 경계 금지(무장 플래그·직접 원격 변이)는
  # 워크플로만이 아니라 이 파일에도 걸린다: 금지를 워크플로에만 걸면 러너가 그 우회로가 된다.
  RUNNER="$ROOT/tools/run-bump-plan.ts"
  # 러너의 주석 제거 뷰(주석이 금지 토큰을 **설명**하므로 산문 오탐을 막는다 — CODE와 같은 이유).
  RCODE="$BATS_TEST_TMPDIR/run-bump-plan.code.ts"
  sed 's#^[[:space:]]*//.*$##' "$RUNNER" > "$RCODE"
  # 전체-줄 주석을 **빈 줄로 치환**한 뷰(줄 번호는 보존) — 주석 속 설명 문구("…auto-merge-or-fail…",
  # "…bump-tag.ts가 재검증한다" 등)가 순서·금지 증인에 오탐되는 걸 막는다(test_mutation-dispatch의 선례).
  CODE="$BATS_TEST_TMPDIR/bump-poll.code.yaml"
  sed 's/^[[:space:]]*#.*$//' "$F" > "$CODE"

  # ⚠️ 실행기-파생 **소유권 기대값** 하네스(EXPECT_PY)는 여기서 사라졌다 — 그 계약(러너가 심는 커밋의
  #    정체성·메시지가 실행기의 proveOurCommit 기대와 글자 그대로 같은가)은 이제 **커밋을 실제로 만드는
  #    곳**에서 검증된다: `tools/tests/test_run-bump-plan.bats`의 "the commit the runner EFFECTIVELY
  #    makes…" 증인이 같은 파생(DEFAULT_WRITER/WRITER_BOT_NAME/WRITER_BOT_EMAIL_RE/bumpCommitMessageOf,
  #    못 찾으면 exit 2)을 그대로 들고 가고, 기대값은 **진짜 git 커밋 오브젝트**와 대조된다.

  # ── GitHub Actions **조건식 평가기**(structure r9 R-31) ────────────────────────────────────────
  # 왜 grep이 아니라 평가인가: 이 게이트가 지켜야 하는 불변식은 "reconcile job의 **본문**이 reader를 쓰지
  # 않는다"가 아니라 "**GitHub이 그 job을 실행한다**"이다. 두 문장 사이엔 `if:`와 `needs:`라는 **선행 의존**이
  # 통째로 들어 있다 — job 본문만 검사하는 증인은 공유 `configured` 출력(READER && WRITER) 하나로 회수가
  # **깨끗하게 skip**되는 그 결함을 그대로 통과시킨다(실제로 통과시켰다: R-31).
  # → 그래서 두 job의 `if`를 **실제 값으로 평가한다**. 값의 출처는 프로덕션 preflight 스텝을 그 자격 조합으로
  #   **직접 실행해** 얻은 GITHUB_OUTPUT이다(테스트가 지어낸 값이 아니다).
  # 이 평가기가 다루는 문맥은 하나다: **취소되지 않았고, needs(preflight)는 성공했다**(라이브의 정상 주기).
  # ⚠️ 해석하지 못한 컨텍스트 참조(needs.*/github.*/…)가 남으면 **평가하지 않고 exit 2로 죽는다** —
  #    "몰라서 false"는 이 게이트가 막으려는 바로 그 침묵이다.
  EVALIF_PY="$BATS_TEST_TMPDIR/eval-if.py"
  cat > "$EVALIF_PY" <<'PY'
import re
import sys

expr = sys.argv[1]
# `${{ … }}` 래퍼는 있어도 없어도 된다(GHA가 job-level if에서 둘 다 받는다).
expr = re.sub(r"^\s*\$\{\{", "", expr)
expr = re.sub(r"\}\}\s*$", "", expr)

# 이 시나리오의 문맥: 취소 아님 · 선행 job 성공.
for fn, val in (("cancelled()", "False"), ("always()", "True"),
                ("success()", "True"), ("failure()", "False")):
    expr = expr.replace(fn, val)

# needs.preflight.outputs.<name> → preflight이 **실제로 낸** 값(문자열 리터럴)
for kv in sys.argv[2:]:
    name, _, value = kv.partition("=")
    expr = re.sub(r"needs\.preflight\.outputs\." + re.escape(name) + r"\b", repr(value), expr)

if re.search(r"\b(needs|github|env|inputs|secrets|steps|vars|job|runner|matrix)\s*\.", expr):
    sys.stderr.write("eval-if: 해석하지 못한 컨텍스트 참조가 남았다(조용한 false 금지): %s\n" % expr)
    sys.exit(2)

py = expr.replace("&&", " and ").replace("||", " or ")
py = py.replace("!=", "__NE__").replace("!", " not ").replace("__NE__", "!=")
try:
    value = eval(py, {"__builtins__": {}}, {})  # noqa: S307 — 리터럴만 남은 식이다
except Exception as e:  # noqa: BLE001
    sys.stderr.write("eval-if: 조건식 평가 실패(%s): %s\n" % (e, py))
    sys.exit(2)
print("true" if value else "false")
PY
}

# preflight 스텝을 **주어진 자격 조합으로 실제로 실행**하고, 그 job이 선언한 출력들의 값을 계산한다.
# 값은 스텝이 GITHUB_OUTPUT에 쓴 것에서 나온다 — job-level `outputs:`의 `${{ steps.<id>.outputs.<key> }}`
# 배선까지 따라간다(그 배선이 끊기면 라이브에서도 출력이 빈다).
preflight_values() { # $1=READER $2=WRITER → "이름=값" 줄들
  local body="$BATS_TEST_TMPDIR/preflight.sh"
  yq -r '[.jobs.preflight.steps[] | select(.run)] | .[0].run // ""' "$F" > "$body"
  [ -s "$body" ] || { echo "preflight 스텝(.run)을 추출하지 못했다" >&2; return 9; }
  local out="$BATS_TEST_TMPDIR/preflight.out"
  : > "$out"
  READER="$1" WRITER="$2" GITHUB_OUTPUT="$out" bash -e "$body" > "$BATS_TEST_TMPDIR/preflight.log" 2>&1 \
    || { echo "preflight 스텝이 비-0으로 죽었다(READER='$1' WRITER='$2')" >&2; return 9; }
  local name raw key val
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    raw="$(yq -r ".jobs.preflight.outputs.\"$name\"" "$F")"
    case "$raw" in
      *outputs.*) : ;;
      *) echo "preflight.outputs.$name이 스텝 출력 참조가 아니다: '$raw'" >&2; return 9 ;;
    esac
    key="$(printf '%s' "$raw" | sed -E 's/.*outputs\.([A-Za-z0-9_-]+).*/\1/')"
    val="$(awk -F= -v k="$key" '$1 == k { v = $2 } END { print v }' "$out")"
    printf '%s=%s\n' "$name" "$val"
  done < <(yq -r '.jobs.preflight.outputs // {} | keys | .[]' "$F")
}
# 한 job의 `if`를 그 값들로 평가한다(없으면 GHA 기본값 = true).
eval_if() { # $1=job, 나머지=이름=값
  local job="$1"
  shift
  local expr
  expr="$(yq -r ".jobs.\"$job\".if // \"true\"" "$F")"
  python3 "$EVALIF_PY" "$expr" "$@"
}
# 자격 조합 하나에 대해 **두 게이트를 함께** 평가한다 → "reconcile poll"(true/false).
gates_for() { # $1=READER $2=WRITER
  local f="$BATS_TEST_TMPDIR/pf-values.txt"
  preflight_values "$1" "$2" > "$f" || return 9
  local -a kv=()
  local line
  while IFS= read -r line; do
    if [ -n "$line" ]; then kv+=("$line"); fi
  done < "$f"
  local r p
  r="$(eval_if reconcile "${kv[@]}")" || return 8
  p="$(eval_if poll "${kv[@]}")" || return 8
  printf '%s %s\n' "$r" "$p"
}

# bump 스텝의 셸 본문에서 **실제 명령만** 남긴다(전체-줄 주석·빈 줄 제거). F-1 이후 이 스텝의 계약은
# "무슨 순서로 도는가"가 아니라 **"명령이 러너 호출 하나뿐인가"**다 — 그 한 줄이 곧 경계다.
step_commands() { extract_step | sed 's/^[[:space:]]*#.*$//' | sed '/^[[:space:]]*$/d'; }

# ── hermetic 하네스(plan r6 → F-1로 겨냥점 이동) ─────────────────────────────────────────────
# 왜 여전히 **실행**하는가: 정적 grep은 문자열 모양만 본다. 스텝 본문을 stub 아래 실제로 돌리면
# "이 스텝이 무슨 명령을 실행했는가"가 원장에 남는다 — jq로 plan을 고쳐 쓰거나(레인 위조), git으로
# 직접 커밋/푸시하거나, 실행기를 직접 부르는 **어떤 추가 명령도** 여기서 드러난다.
# ⚠️ 항목 처리(레인 verbatim·순서·격리·소유권·집계)는 이제 러너 스위트가 **진짜 git worktree**에서
#    증명한다. 이 하네스에 남은 몫은 **경계**(bump 스텝 = 러너 호출 하나)와 **회수 패스의 독립성**이다.
extract_step() {
  # 스텝 선택자: `.run`에 러너 호출이 있는 스텝(= bump 스텝)의 **셸 본문(.run)**.
  # ⚠️ `.[0]`은 스텝 **맵 전체**를 준다 — 반드시 `.[0].run`이어야 한다
  # (실측: 맵을 그대로 실행하면 `syntax error near unexpected token '('`로 죽는다).
  yq -r '[.jobs.poll.steps[] | select(.run) | select(.run | test("run-bump-plan"))] | .[0].run // ""' "$F"
}
# reconcile 패스(인가 회수)의 셸 본문. ★ **별도 job**이다(R-27) — poll job의 스텝이 아니다:
# 그 안에 있으면 reader 토큰·docker·플래너 스텝의 성공에 묶여, 그것들이 죽는 순간 회수도 죽는다.
extract_reconcile_step() {
  yq -r '[.jobs.reconcile.steps[] | select(.run) | select(.run | test("--reconcile-only"))] | .[0].run // ""' "$F"
}

setup_hermetic() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export CALLS="$BATS_TEST_TMPDIR/calls.nul"   # NUL 구분 argv 원장(인자 경계 보존 — tools 스위트와 동형)
  : > "$CALLS"
  # 스텝이 쓰는 `/tmp/*` 경로를 통째로 하네스 안으로 돌린다(plan·apps·bump-items·mutation-failures) —
  # 진짜 /tmp에 쓰면 테스트끼리 상태가 샌다(특히 스텝 간에 넘기는 실패 파일).
  TMPD="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPD"

  # 두 레인이 **섞인** plan — 이게 이 증인의 핵심이다. 한 레인만 돌리면 "둘 다 bump로 넘기는" 우회가 안 죽는다.
  # ★ 여기에 **noop·refuse 항목도 넣는다**(H-1): bump 루프는 이 둘을 걸러내지만, reconcile 패스는
  #   **전 항목**을 돌아야 한다(해제는 후보 생성에 의존해선 안 된다 — 보안 속성이다).
  PLAN="$TMPD/plan.json"
  cat > "$PLAN" <<'JSON'
[
  {"app":"page","action":"bump","writePath":"apps/page/deploy/prod/values.yaml",
   "current":{"tag":"sha-1111111111111111111111111111111111111111"},
   "candidate":{"tag":"sha-2222222222222222222222222222222222222222","digest":"sha256:aaaa"}},
  {"app":"trip-mate","action":"propose-pr","writePath":"apps/trip-mate/deploy/prod/values.yaml",
   "current":{"tag":"sha-3333333333333333333333333333333333333333"},
   "candidate":{"tag":"sha-4444444444444444444444444444444444444444","digest":"sha256:bbbb"}},
  {"app":"files","action":"noop","reason":"배포 이후 빌드된 main 커밋 없음",
   "current":{"tag":"sha-5555555555555555555555555555555555555555"},"candidate":null},
  {"app":"broken-api","action":"refuse","reason":"manifest 조회 일시 오류(transient)",
   "current":null,"candidate":null}
]
JSON

  # ── 원장에 잡히는 명령의 **범위**가 곧 실행 증인의 이빨이다 ────────────────────────────────
  # stub되지 않은 명령은 원장에 남지 않는다 → "러너 말고 아무것도 실행하지 않았다"를 실행으로 보려면
  # **plan을 손댈 만한 도구들**이 전부 stub 안에 있어야 한다(실측: jq를 빼면 `jq 'map(.action="bump")'`로
  # 레인을 위조하는 변이가 실행 증인을 조용히 통과했다 — 정적 증인만 잡았다).
  # ★★ `git`은 **아무도 부르지 않아야 하는데도** 반드시 stub해야 한다. 빠뜨리면 두 번 진다:
  #    ① 직접 git 호출이 원장에 안 남아 실행 증인이 침묵하고,
  #    ② 하네스는 cd하지 않으므로 **진짜 git이 이 레포 작업트리에서 실행된다** — 회귀가 RED가 되는 대신
  #       개발자의 트리를 변이한다(게이트가 파괴적이 된다). 기록만 하고 no-op으로 끝낸다.
  for t in git jq sed awk python3 curl; do
    printf '#!/bin/sh\n{ printf %%s\\0 %s "$@"; printf \047\\036\047; } >> "$CALLS"\nexit 0\n' "$t" > "$STUB/$t"
    chmod +x "$STUB/$t"
  done

  # gh stub — argv를 원장에 남기고 성공만 흉내낸다(실제 변이 0).
  cat > "$STUB/gh" <<'GHEOF'
#!/bin/sh
{ printf '%s\0' gh "$@"; printf '\036'; } >> "$CALLS"
exit 0
GHEOF
  chmod +x "$STUB/gh"

  # ── bun stub — 인가 회수 패스를 **fail-closed로 죽이는 주입점**을 갖는다 ────────────────────────
  # ⚠️ 앱별 실패 주입(STUB_FAIL_APP)은 이 파일에서 사라졌다: 항목별 fail-closed·굶김 여부는 러너 안의
  #    사실이라 러너 스위트가 진짜 git 위에서 주입한다("…without starving the other item").
  cat > "$STUB/bun" <<'BUNEOF'
#!/bin/sh
{ printf '%s\0' bun "$@"; printf '\036'; } >> "$CALLS"
# 인가 회수 패스의 실패 주입(R-27) — 이 모드엔 `--app`이 없다(대상은 네임스페이스가 준다).
if [ -n "${STUB_FAIL_RECONCILE:-}" ] && [ "$1" = "tools/ensure-bump-pr.ts" ]; then
  for a in "$@"; do
    if [ "$a" = "--reconcile-only" ]; then
      echo "stub bun: 인가 회수 패스 실패(주입 — 한 앱의 SSOT 파손·API 장애)" >&2
      exit 1
    fi
  done
fi
exit 0
BUNEOF
  chmod +x "$STUB/bun"

  # ⚠️ git stub(last-write-wins config·--amend 의미를 흉내내던 시뮬레이터)은 여기서 사라졌다.
  #    그 시뮬레이터가 필요했던 이유는 계약(커밋의 **실효** 정체성·메시지)이 **YAML에서 뽑은 셸 본문**
  #    위에 있었기 때문이다. 이제 커밋은 러너가 **진짜 git worktree**에서 만들고, 러너 스위트가 그
  #    커밋 오브젝트를 직접 읽는다 — 흉내낼 의미가 없으니 시뮬레이터도, 그 시뮬레이터가 진짜인지
  #    증명하던 이빨 증인도 함께 필요 없어졌다(무약화 이관: 관측 대상이 모형에서 실물로 바뀌었다).
  #    bump 스텝이 git을 **직접 부르지 않는다**는 사실 자체는 아래 "명령이 러너 호출 하나뿐" 증인이 잡는다.

  # 스텝 본문 추출 → 스텝이 쓰는 `/tmp/` 경로를 통째로 하네스 안(TMPD)으로 돌려 hermetic하게 만든다
  # (plan.json 픽스처는 이미 그 안에 있다). 스텝 간에 넘기는 실패 파일도 이 안에 남는다.
  STEP="$BATS_TEST_TMPDIR/bump-step.sh"
  extract_step > "$STEP.raw"
  [ -s "$STEP.raw" ] || return 9   # 추출 실패는 호출부에서 시끄럽게 잡는다
  sed "s#/tmp/#$TMPD/#g" "$STEP.raw" > "$STEP"
  # reconcile 패스 본문(H-1) — 없으면 빈 파일이 되고, 그걸 새 증인이 시끄럽게 잡는다.
  RSTEP="$BATS_TEST_TMPDIR/reconcile-step.sh"
  extract_reconcile_step > "$RSTEP.raw"
  sed "s#/tmp/#$TMPD/#g" "$RSTEP.raw" > "$RSTEP"

  # 실행기에 실제로 간 argv를 원장에서 되읽는 파서(NUL 경계 보존 — 붙여 쓴 인자와 구분된다).
  LEDGER_PY="$BATS_TEST_TMPDIR/ledger.py"
  cat > "$LEDGER_PY" <<'PY'
import sys

mode, path = sys.argv[1], sys.argv[2]
want = sys.argv[3:]
raw = open(path, "rb").read()

records = []
for chunk in raw.split(b"\x1e"):
    if chunk == b"":
        continue
    fields = chunk.split(b"\x00")
    if fields and fields[-1] == b"":
        fields.pop()
    records.append([f.decode("utf-8", "surrogateescape") for f in fields])

def tool(name):
    return [r for r in records if len(r) >= 2 and r[0] == "bun" and r[1] == name]


ensure = tool("tools/ensure-bump-pr.ts")


if mode == "reconciled":  # 인가 회수 패스가 실행기에 **도달한 횟수**(대상 목록은 인자가 아니다 — R-27)
    print(sum(1 for r in ensure if "--reconcile-only" in r))
elif mode == "argcount":  # want[0] 인자를 포함하는 실행기 레코드 수(예: reconcile 패스의 `--action` = 0이어야 한다)
    print(sum(1 for r in ensure if want[0] in r))
elif mode == "cmds":  # 스텝이 **실행한 명령**들(argv[0] argv[1]) — 경계 증인: 러너 호출 하나뿐인가
    for r in records:
        print(" ".join(r[:2]))
elif mode == "dump":
    for i, r in enumerate(records, 1):
        print("%2d) argc=%d  %s" % (i, len(r), " ".join(repr(a) for a in r)))
else:
    sys.exit(2)
PY

  # 워크플로 스텝은 GHA에서 `bash -e {0}`로 돈다(레포 함정 원장) → 같은 셸 의미로 실행한다.
  PATH="$STUB:$PATH" GH_TOKEN=stub-token RUN_ID=999 bash -e "$STEP" > "$BATS_TEST_TMPDIR/step.out" 2>&1 || true
}

# bump 스텝이 **러너를 부른 횟수**(경계 증인 — 항목별 argv는 러너 스위트가 본다).
runner_calls() { python3 "$LEDGER_PY" cmds "$CALLS" | grep -c 'tools/run-bump-plan\.ts' || true; }
# 인가 회수 패스가 실행기에 도달한 **횟수**(앱 목록이 아니다 — 대상은 네임스페이스가 준다: R-27).
reconcile_calls() { python3 "$LEDGER_PY" reconciled "$CALLS"; }
arg_calls()       { python3 "$LEDGER_PY" argcount "$CALLS" "$1"; }
dump_calls()    { echo "--- 스텝이 실행한 명령(원장) ---"; python3 "$LEDGER_PY" dump "$CALLS"; }

# 같은 실행이되 **종료 코드를 삼키지 않는다**(H-2: "run이 여전히 빨간가"가 계약의 절반이다).
# 스텝은 GHA에서 `bash -e {0}`로 돈다(레포 함정 원장) → 같은 셸 의미로 돌린다.
run_step_rc() {
  : > "$CALLS"
  PATH="$STUB:$PATH" GH_TOKEN=stub-token RUN_ID=999 STUB_FAIL_RECONCILE="${STUB_FAIL_RECONCILE:-}" \
    bash -e "$1" > "$BATS_TEST_TMPDIR/step.out" 2>&1
}
step_out() { echo "--- 스텝 출력 ---"; cat "$BATS_TEST_TMPDIR/step.out"; }

# bats test_tags=regression
@test "bump-poll never calls gh pr create directly (PR creation goes through ensure-bump-pr)" {
  run grep -n "gh pr create" "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml still calls 'gh pr create' directly — PR 생성은 tools/ensure-bump-pr.ts(조회→결정→변이)를 통해서만"
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "bump-poll never pushes the bump branch directly (a skip decision must mutate nothing)" {
  run grep -nE '(^|[^-[:alnum:]])git push' "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "orphan bump branch: bump-poll.yaml still runs 'git push' itself — push는 ensure-bump-pr가 관측 뒤에 (lease와 함께) 해야 한다"
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "the runner is bound by the same bans as the workflow (no gh, no git push/fetch — the executor owns the remote)" {
  # ★ F-1 무약화 조항. ①②는 **파일 스코프** 금지였다("bump-poll.yaml 안에 직접 push·gh pr create 0").
  #   호출부가 러너로 옮겨갔는데 금지를 워크플로에만 남기면, 그 순간 러너가 **금지의 우회로**가 된다
  #   (게이트는 GREEN인데 러너가 직접 push하면 skip 판정이 원격을 변이하고 고아 브랜치가 남는다).
  # ⚠️ **실행 증인**은 러너 스위트가 갖는다("the runner performs no direct remote mutation — it runs with
  #    no git remote and still succeeds"): origin이 없는 fixture에서 성공한다 = 원격을 건드리지 않았다.
  #    여기 정적 금지는 그 위에 얹는 두 번째 겹이다(원격이 **있는** 라이브에서 조용히 성공할 형태를 막는다).
  run grep -nE '"gh"|[^A-Za-z0-9_-]gh [a-z]' "$RCODE"
  if [ "$status" -eq 0 ]; then
    echo "single-owner violated: 러너가 gh를 직접 부른다 — PR 생성·무장·해제는 tools/ensure-bump-pr.ts만의 몫이다"
    echo "$output"
    false
  fi
  run grep -nE '"(push|fetch)"' "$RCODE"
  if [ "$status" -eq 0 ]; then
    echo "orphan bump branch: 러너가 git push/fetch를 argv로 넘긴다 —"
    echo "  push는 실행기가 열린 PR·원격 브랜치를 **관측한 뒤에** (lease와 함께) 해야 한다."
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "the bump lane reaches the executor through the tested runner (bump step → run-bump-plan → ensure-bump-pr)" {
  # ⚠️ F-1 이후 이 증인은 **두 홉**을 본다. 옛 형태("파일 어딘가에 tools/ensure-bump-pr.ts 문자열이 있는가")는
  #    이제 **회수 job의 호출만으로도** 통과한다 — bump 레인 배선이 통째로 끊겨도 GREEN인 죽은 텍스트다.
  #    그래서 (a) bump 스텝이 러너를 부르고, (b) 러너의 기본 실행기 경로가 그 실행기임을 각각 못박는다.
  run grep -n 'bun tools/run-bump-plan\.ts' "$CODE"
  [ "$status" -eq 0 ] || {
    echo "unwired bump lane: bump-poll.yaml이 tools/run-bump-plan.ts를 호출하지 않는다 —"
    echo "  항목 오케스트레이션이 배선되지 않으면 러너가 아무리 GREEN이어도 프로덕션은 bump하지 않는다."
    false
  }
  # (b) 러너의 **기본** ensure 경로가 실행기다. 테스트는 `--ensure-script`로 stub을 끼우지만(내부 seam),
  #     프로덕션이 인자 없이 부르는 이상 이 기본값이 곧 "원격 변이는 실행기만" 계약의 배선이다.
  run grep -nE 'DEFAULT_ENSURE_SCRIPT[[:space:]]*=.*ensure-bump-pr\.ts' "$RCODE"
  [ "$status" -eq 0 ] || {
    echo "duplicate bump PR: 러너의 기본 ensure 경로가 tools/ensure-bump-pr.ts가 아니다 —"
    echo "  멱등 실행기(조회 → 결정 → 변이)를 거치지 않으면 매 주기 중복 PR이 열린다."
    false
  }
  # (c) 회수 job은 러너와 무관하게 실행기를 **직접** 부른다(R-27 — 플래너·bump 레인 어디에도 묶이지 않는다).
  run grep -n 'tools/ensure-bump-pr\.ts' "$CODE"
  [ "$status" -eq 0 ]
}

# bats test_tags=regression
@test "the bump branch name carries no RUN_ID (same bump converges to one branch)" {
  run grep -n "RUN_ID" "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml still derives the branch from RUN_ID — 같은 bump가 run마다 다른 브랜치를 만들어 조회 대상이 사라진다"
    echo "$output"
    false
  fi
}

# ── ④ 순서 계약의 **이관**(F-1) ───────────────────────────────────────────────────────────────
# 옛 증인은 bump 스텝 셸 본문에서 `git checkout -b` → `bump-tag` → `git commit` → `ensure-bump-pr`의
# **줄 번호 순서**를 읽었다. 그 순서는 이제 러너 안의 순차 코드이고, 러너 스위트가 **실행으로** 증명한다:
#   · commit이 ensure보다 앞선다 → "the commit the runner EFFECTIVELY makes…"(ensure 호출 시점의 HEAD가
#     bump 커밋이고 main보다 정확히 1커밋 앞선다. ensure가 커밋 전에 불렸다면 HEAD=main, ahead=0이다)
#   · 태그 갱신이 ensure보다 앞선다 → "an item whose bump-tag fails BEFORE staging … never reaches ensure"
#   · 브랜치 생성이 갱신보다 앞선다 → 갱신은 **항목 worktree 안**에서만 일어나고(브랜치 tip), main 트리는
#     불변임을 "each item commits its own writePath…"·"…main is left untouched" 증인이 관측한다.
# 여기 남는 몫은 **경계**다: 그 러너 호출 말고 이 스텝에 **다른 명령이 없다**(아래 두 증인).

# bats test_tags=regression
@test "the bump step's only command is the runner invocation with the planner's plan (static)" {
  # ★ F-1의 새 봉인. 러너로 옮긴 뒤 이 스텝에 남을 수 있는 유일한 위험은 **러너를 부르기 전후로 무언가를
  #   더 하는 것**이다: `jq`로 plan.json을 고쳐 쓰면 레인(승인 게이트)이 위조되고, `git`/`gh`를 직접 부르면
  #   "원격 변이는 실행기만"이 깨진다. 그래서 명령 목록 자체를 계약으로 못박는다 — **정확히 한 줄**.
  cmds="$(step_commands)"
  [ -n "$cmds" ] || {
    echo "boundary: bump 스텝(.run에 run-bump-plan 포함)을 추출하지 못했다 — 러너가 배선되지 않았다"
    false
  }
  n="$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] || {
    echo "boundary violated: bump 스텝의 명령이 ${n}줄이다(기대 1줄 — 러너 호출뿐) —"
    echo "  러너 앞뒤의 추가 명령은 plan 변조(레인 위조)·직접 원격 변이의 자리다. 필요한 로직은 러너 안에서,"
    echo "  러너 스위트의 증인과 함께 산다."
    printf '%s\n' "$cmds"
    false
  }
  # 그 한 줄은 **플래너가 쓴 그 파일**을 넘긴다(다른 경로를 넘기면 계획 자체가 바꿔치기된다).
  printf '%s' "$cmds" | grep -qE '^[[:space:]]*bun tools/run-bump-plan\.ts --plan /tmp/plan\.json[[:space:]]*$' || {
    echo "boundary violated: bump 스텝의 명령이 '플래너 출력(/tmp/plan.json)을 러너에 넘긴다' 형태가 아니다:"
    printf '%s\n' "$cmds"
    echo "  plan 스텝(poll-ghcr → /tmp/plan.json)과 다른 경로를 넘기면 레인의 출처(autoDeploy SSOT)가 끊긴다."
    false
  }
}

# bats test_tags=regression
@test "running the extracted bump step executes the runner and NOTHING else (no jq rewrite, no direct git/gh)" {
  # ★ 위 증인의 **실행판**. 정적 형태 검사는 "한 줄"만 보지만, 그 한 줄이 서브셸·파이프·`&&`로 다른
  #   명령을 품을 수도 있다(`bun … --plan <(jq …)`). 실제로 돌려서 **원장에 남은 명령**을 본다.
  setup_hermetic
  rc=$?
  [ "$rc" -ne 9 ] || { echo "hermetic harness: bump 스텝 추출 실패(선택자: .run에 run-bump-plan)"; false; }
  run bash -c "python3 '$LEDGER_PY' cmds '$CALLS' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "bun tools/run-bump-plan.ts" ] || {
    echo "boundary violated: bump 스텝이 러너 말고 다른 명령을 실행했다 —"
    echo "  실행된 명령: $output"
    echo "  (기대: 'bun tools/run-bump-plan.ts' 하나. git/gh/jq/sed가 보이면 원격 변이·plan 변조 표면이 살아 있다.)"
    dump_calls
    false
  }
}

# bats test_tags=regression
@test "auto-merge is armed only by ensure-bump-pr (bump-poll never runs the shared script itself)" {
  # plan r4 R-8: 워크플로에 직접 호출이 남아 있으면, 도구가 skip/rebuild(=PR 생성 0)를 판정한 주기에도
  # 워크플로가 auto-merge를 무장한다 → 옛 PR/남의 PR에 머지가 걸리는 **이중 auto-merge**. auto-merge는
  # 실행기 안(관측된 사실 + 레인으로 판정)이 유일한 자리다.
  run grep -nE 'auto-merge-or-fail\.sh' "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "double auto-merge: bump-poll.yaml still runs 'scripts/auto-merge-or-fail.sh' itself —"
    echo "  auto-merge는 tools/ensure-bump-pr.ts 안에서만 무장한다(레인=bump일 때, 무장이 없을 때)."
    echo "  skip/rebuild 판정(PR 생성 0)에도 무장되면 옛 PR이 머지될 수 있다."
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "no callsite can arm auto-merge outside the lane (neither the workflow nor the runner has such a flag)" {
  # ★ plan r5 R-11(⑥의 (a)). 옛 게이트는 "워크플로 어딘가에 --auto-merge 토큰이 있으면 통과"였다 —
  # 그 게이트는 두 레인 모두에 무조건 그 플래그를 넘기는 구현도 GREEN으로 통과시킨다(승인 게이트 우회).
  # 새 계약: auto-merge를 켜는 플래그는 **존재하지 않는다**. 레인(--action)이 유일한 입력이다.
  # ⚠️ F-1 이후 이 금지는 **두 파일**에 걸린다. 워크플로에만 걸면 러너가 그대로 우회로가 된다 —
  #    호출부가 옮겨갔으면 금지도 함께 옮겨가야 한다(그게 이관이 약화되지 않았다는 뜻이다).
  for f in "$CODE" "$RCODE"; do
    run grep -nE -- '--auto-merge' "$f"
    if [ "$status" -eq 0 ]; then
      echo "approval gate bypass: $(basename "$f")에 '--auto-merge'가 있다 — 그런 플래그는 존재하지 않는다."
      echo "  무장은 레인(--action bump)만이 켠다. 별도 플래그를 되살리면 두 레인에 무조건 넘기는 것만으로"
      echo "  autoDeploy:false 승인 PR이 자동 배포된다(승인 게이트 우회)."
      echo "$output"
      false
    fi
  done
}

# bats test_tags=regression
@test "the runner forwards the planner's lane verbatim — read once from the plan item, never reassigned or hardcoded" {
  # ★ plan r5 R-11 / r6의 **정적 절반**(⑥의 (c)). 옛 증인은 워크플로 셸(`action=$(jq -r .action)` …
  # `--action "$action"`)을 봤다. 레인을 나르는 코드가 러너로 옮겨갔으니 같은 봉인을 러너 소스에 건다:
  #   · 대입은 **정확히 한 번**이고 그 출처는 **플래너 항목**(`item.action`)이다 — 읽은 뒤 덮어쓰기
  #     (`action = "bump"`)는 승인 레인을 자동 배포로 바꾸면서 다른 정적 증인을 모두 통과한다.
  #   · 실행기에 가는 `--action`은 **전부** 그 변수 그대로다 — 하드코딩(`"--action", "bump"`)이 하나라도
  #     있으면 propose-pr 후보가 bump 레인으로 흐른다.
  # ⚠️ **실행 증인**은 러너 스위트에 있다("each item commits its own writePath… with the planner's lane
  #    verbatim": page→bump / trip-mate→propose-pr가 실제 argv로 실행기에 도달함을 진짜 git 위에서 관측).
  #    정적/실행 두 겹은 그대로 유지된다 — 겨냥하는 파일만 바뀌었다.
  assigns="$(grep -oE '(^|[^A-Za-z0-9_$.])action[[:space:]]*=[^=]' "$RCODE" | wc -l | tr -d ' ')"
  [ "$assigns" -eq 1 ] || {
    echo "lane forgery: 러너에서 'action' 대입이 ${assigns}회다(기대 1회 — 플래너 항목에서 단 한 번)."
    echo "  읽은 뒤 재대입하면 모든 정적 증인을 통과하면서 승인 레인이 자동 배포된다."
    grep -nE '(^|[^A-Za-z0-9_$.])action[[:space:]]*=[^=]' "$RCODE"
    false
  }
  run grep -nE 'action[[:space:]]*=[[:space:]]*item\.action' "$RCODE"
  [ "$status" -eq 0 ] || {
    echo "lane provenance: 그 단 한 번의 대입이 플래너 항목(item.action)이 아니다 —"
    echo "  레인의 출처는 poll-ghcr(.bindings.json / .image-pin.json의 autoDeploy SSOT)여야 한다."
    false
  }
  total="$(grep -oE -- '"--action"' "$RCODE" | wc -l | tr -d ' ')"
  [ "$total" -ge 1 ] || {
    echo "lost auto-merge: 러너가 실행기에 --action을 넘기지 않는다 —"
    echo "  레인이 없으면 실행기가 exit 2로 죽는다(기본값 없음). autoDeploy 레인은 자동 머지가 계약이다."
    false
  }
  good="$(grep -oE -- '"--action",[[:space:]]*action' "$RCODE" | wc -l | tr -d ' ')"
  [ "$good" -eq "$total" ] || {
    echo "approval gate bypass: --action 등장 ${total}회 중 ${good}회만 플래너의 action을 그대로 넘긴다 —"
    echo "  하드코딩(\"--action\", \"bump\")이나 재해석은 금지다. autoDeploy:false 앱이 자동 배포될 수 있다."
    grep -nE -- '"--action"' "$RCODE"
    false
  }
}

# ⚠️ 이관됨(F-1) — "the two lanes reach the executor with their own --action (hermetic run of the real
#    bump step)": 워크플로 셸 본문을 stub 아래 돌려 앱별 --action을 단언하던 증인이다. 레인을 나르는
#    코드가 러너로 옮겨갔으므로 그 실행 증인도 러너 스위트로 갔다 —
#    `tools/tests/test_run-bump-plan.bats`의 "each item commits its own writePath+digest-exporter with
#    writer identity, on its own branch, and calls ensure with the planner's lane verbatim"이 같은 픽스처
#    (page=bump / trip-mate=propose-pr가 섞인 plan)로 **진짜 git worktree** 위에서 같은 사실을 단언한다.
#    워크플로 쪽에 남은 몫(플래너 출력을 손대지 않는다)은 위 "only command is the runner invocation"이 잡는다.

# ── ⑦ `bump-poll/*` 원격 상태의 **소유자는 실행기 하나**다(structure r7 R-25) ────────────────────
# pr-sweeper는 30분 크론으로 "무장 + BEHIND"인 봇 PR을 `gh pr update-branch`로 전진시킨다. 그 선택 접두에
# `bump-poll/`이 있으면 두 가지가 동시에 깨진다:
#   ① **승인 게이트 우회**: 스위퍼는 **레인을 보지 않는다**. autoDeploy가 true→false로 바뀌어도 이미 무장된
#      PR은 무장된 채 남는데, 스위퍼가 브랜치를 갱신해 체크를 재시작시키면 green 시점에 GitHub이 **사람 승인
#      없이 머지**한다. (게다가 실행기의 해제는 (app,tag) 키로만 도니, 더 새 태그가 나오면 옛 armed PR은
#      영영 방문되지 않는다 — 라이브 좀비 #348·#350·#351.)
#   ② **소유권 인터록 파괴**: update-branch는 head에 **머지 커밋**을 얹는다 → 실행기의 proveOurCommit이
#      영구 실패 → 무장 회수 + fail-closed → 그 앱의 bump가 **영원히 멈춘다**. 스위퍼 접두 제거는 선택이
#      아니라 실행기의 **동작 전제조건**이다.
# 계약: 스위퍼의 head 접두 정규식이 `bump-poll/…`를 **선택하지 않는다**. 다른 접두는 그대로 둔다.

# bats test_tags=regression
@test "the pr-sweeper no longer selects bump-poll branches (the executor owns that namespace)" {
  # ★ 문자열 grep이 아니라 **정규식을 실제로 실행**해 판정한다. `^(bump|…)/`의 `bump` 대안이 `bump-poll/`을
  #   접두 매치하지 않는다는 사실에 **의존하지 않고** 실측한다 — 누군가 앵커를 풀거나 `bump.*`로 고치면
  #   문자열 증인은 통과하지만 라이브에선 다시 bump-poll PR을 골라 간다.
  #   워크플로에서 jq 셀렉터의 **그 줄**을 뽑아 실제 브랜치명을 통과시킨다.
  sel="$(grep -oE 'test\("[^"]+"\)' "$SWEEPER" | head -1)"
  [ -n "$sel" ] || { echo "pr-sweeper.yaml에서 head 접두 정규식(test(\"…\"))을 찾지 못했다"; false; }
  re="$(printf '%s' "$sel" | sed -E 's/^test\("//; s/"\)$//')"
  [ -n "$re" ] || { echo "정규식을 추출하지 못했다: $sel"; false; }

  # ① bump-poll 브랜치는 **선택되지 않는다**(실측: 그 정규식에 실제로 통과시켜 본다).
  hit="$(printf '%s' '[{"headRefName":"bump-poll/page-sha-abc1234"}]' \
    | jq -r --arg re "$re" '.[] | select(.headRefName | test($re)) | .headRefName')"
  [ -z "$hit" ] || {
    echo "approval gate bypass: pr-sweeper의 정규식이 여전히 bump-poll 브랜치를 고른다('$hit', 정규식 '$re') —"
    echo "  스위퍼는 레인을 모른다 → autoDeploy:false로 뒤집힌 뒤에도 낡은 무장을 green으로 밀어 **승인 없이 머지**한다."
    echo "  또 update-branch의 머지 커밋이 실행기의 소유권 증명을 영구 파괴해 그 앱의 bump가 멈춘다."
    false
  }

  # ② 다른 봇 접두는 **그대로 골라야** 한다 — 스위퍼를 통째로 죽이면 그 PR들의 BEHIND 수렴이 사라진다.
  for b in bump/pg-tools create-database/foo create-cache/foo create-app/foo update-secrets/foo; do
    keep="$(printf '%s' "[{\"headRefName\":\"$b\"}]" \
      | jq -r --arg re "$re" '.[] | select(.headRefName | test($re)) | .headRefName')"
    [ "$keep" = "$b" ] || {
      echo "over-correction: pr-sweeper가 '$b'를 더 이상 고르지 않는다 — bump-poll만 빼야 한다(정규식 '$re')"
      false
    }
  done
}

# bats test_tags=regression
@test "no workflow advances a bump-poll PR (gh pr update-branch and gh pr merge never see that namespace)" {
  # ★ 호출부 게이트의 확장(전 워크플로). `bump-poll` 브랜치/PR을 `gh pr merge`·`gh pr update-branch`·
  # `auto-merge-or-fail.sh`에 넘기는 워크플로가 **하나도 없어야** 한다 — 있으면 실행기의 단일 소유가 깨지고
  # 승인 게이트가 그 경로로 우회된다. 실행기(tools/ensure-bump-pr.ts)만이 그 네임스페이스를 변이한다.
  bad=""
  for wf in "$ROOT"/.github/workflows/*.yaml; do
    # 주석은 뺀 뷰에서 본다(이 파일들의 주석은 bump-poll을 **설명**한다).
    code="$BATS_TEST_TMPDIR/$(basename "$wf").code"
    sed 's/^[[:space:]]*#.*$//' "$wf" > "$code"
    if grep -qE 'gh pr update-branch' "$code"; then
      if grep -qE 'bump-poll' "$code"; then
        bad="$bad $(basename "$wf")"
      fi
    fi
  done
  [ -z "$bad" ] || {
    echo "single-owner violated: 다음 워크플로가 bump-poll 네임스페이스를 update-branch로 전진시킨다:$bad"
    echo "  전진은 tools/ensure-bump-pr.ts의 leased force-push만이 한다(머지 커밋 0 — 소유권 증명 보존)."
    false
  }

  # 실행기 자신도 `gh pr update-branch`를 **부르지 않는다**(머지 커밋 head = 소유권 증명 영구 파괴).
  # ⚠️ 주석/에러 문구는 그 금지를 **설명**하므로 전체-줄 주석을 지운 뷰에서, **argv 토큰 형태**
  #    (따옴표로 감싼 "update-branch")만 겨냥한다 — 산문이 증인을 오탐시키면 게이트가 죽은 텍스트가 된다.
  #    (실제 이빨은 도구 스위트의 원장 단언이다: W29~W32가 `gh pr update-branch` 실행 0회를 못박는다.)
  ECODE="$BATS_TEST_TMPDIR/executor.code.ts"
  sed 's#^[[:space:]]*//.*$##' "$EXECUTOR" > "$ECODE"
  run grep -nE "[\"']update-branch[\"']" "$ECODE"
  if [ "$status" -eq 0 ]; then
    echo "ownership interlock destroyed: 실행기가 'gh pr update-branch'를 argv로 넘긴다 — head가 머지 커밋이 되어"
    echo "  다음 주기 proveOurCommit이 영구 실패한다(무장 회수 + fail-closed = 그 앱의 bump 영구 정지)."
    echo "$output"
    false
  fi
}

# ── ⑧ **회수는 후보에도, 플래너에도 의존하지 않는다**(H-1 · structure r8 R-27) ────────────────────
# bump 루프는 플래너가 후보를 낸 앱(action = bump | propose-pr)만 돈다. `noop`·`refuse` 주기엔 그 앱의
# 실행기가 **한 번도 호출되지 않는다** → autoDeploy가 true→false로 뒤집혀도 이미 무장된 PR이 낡은 머지
# 인가를 **무기한** 들고 있는다(H-1).
# ★★ R-27이 그 위에 한 겹 더 얹었다: H-1의 첫 수정은 대상 목록을 `/tmp/plan.json`에서 뽑았다 —
#    즉 회수가 여전히 **reader 토큰 + GHCR 플래너의 성공과 완전성**에 묶여 있었다(의존을 `.action` 필터에서
#    plan.json 존재로 한 칸 옮겼을 뿐이다). 플래너가 죽으면? 어떤 앱이 그 출력에서 빠지면? **그 앱은
#    방문되지 않고 낡은 무장이 산다.** 회수는 보안 속성이라 **후보 계획의 가용성에도 완전성에도** 의존해선 안 된다.
# 계약(셋 다 필요하다):
#   ⓐ 회수는 **자기 job**이다 — reader 토큰·docker·플래너 스텝을 하나도 갖지 않는다(그것들이 죽어도 돈다).
#   ⓑ 대상 목록을 **넘기지 않는다**(`--app` 0회) — 실행기가 `bump-poll/*` 네임스페이스에서 직접 열거한다.
#   ⓒ 레인도 넘기지 않는다(`--action` 0회) — autoDeploy SSOT가 유일한 출처다(승인 게이트 우회 방지).

# bats test_tags=regression
@test "the reconcile pass runs with NO planner output at all (no plan.json, no reader token) — its subjects come from the namespace" {
  setup_hermetic
  rc=$?
  [ "$rc" -ne 9 ] || { echo "hermetic harness: bump 스텝 추출 실패"; false; }
  [ -s "$RSTEP" ] || {
    echo "stale authorization survives: bump-poll.yaml에 **인가 회수 패스가 없다**(reconcile job에서"
    echo "  --reconcile-only를 부르는 스텝 0개) — 낡은 무장을 회수하는 경로가 아예 없다."
    false
  }

  # ★ 플래너가 **아무것도 남기지 않은** 세계를 그대로 만든다: plan.json이 없다(reader 토큰 스텝이
  #   실패했거나 플래너가 죽었다). 그 주기에도 회수는 **반드시** 돈다.
  rm -f "$PLAN"
  run run_step_rc "$RSTEP"
  [ "$status" -eq 0 ] || {
    echo "starved revocation: plan.json이 없다는 이유로 reconcile 패스가 죽었다(exit $status) —"
    echo "  reader 토큰/플래너가 죽은 주기가 바로 **회수가 필요한 주기**다(그 앱들은 방문조차 되지 않는다)."
    step_out; dump_calls; false
  }
  n="$(reconcile_calls)"
  [ "$n" -eq 1 ] || {
    echo "starved revocation: plan.json 없이 실행기에 도달한 회수 패스가 ${n}회다(기대 1회) —"
    echo "  대상은 플래너가 아니라 `bump-poll/*` 네임스페이스가 준다(git ls-remote)."
    step_out; dump_calls; false
  }

  # ⓑ **대상 목록을 넘기지 않는다** — 넘기는 순간 회수의 완전성이 호출부의 목록(=플래너 출력)에 의존한다.
  a="$(arg_calls --app)"
  [ "$a" -eq 0 ] || {
    echo "subject injection: reconcile 패스가 실행기에 --app을 넘긴다(${a}회, 기대 0회) —"
    echo "  그 목록의 출처가 플래너면 R-27이 그대로 재발한다(플래너가 죽으면 회수도 죽는다)."
    dump_calls; false
  }
  # ⓒ 레인도 넘기지 않는다(승인 게이트 우회 방지 — 레인은 autoDeploy SSOT에서만 나온다).
  n="$(arg_calls --action)"
  [ "$n" -eq 0 ] || {
    echo "lane injection: reconcile 패스가 실행기에 --action을 넘긴다(${n}회, 기대 0회)"
    dump_calls; false
  }

  # 플래너가 **빈 계획**을 낸 주기도 같다(후보 0 = 회수 0이 아니다).
  printf '[]' > "$PLAN"
  run run_step_rc "$RSTEP"
  [ "$status" -eq 0 ] || { echo "빈 plan.json에서 reconcile 패스가 죽었다"; step_out; dump_calls; false; }
  n="$(reconcile_calls)"
  [ "$n" -eq 1 ] || {
    echo "starved revocation: 빈 plan.json 주기에 회수가 돌지 않았다(${n}회, 기대 1회)"
    step_out; dump_calls; false
  }
}

# bats test_tags=regression
@test "the reconcile job carries no reader token and no planner step (revocation cannot be starved by candidate planning)" {
  # ⓐ **구조**가 이 속성을 준다: 회수가 poll job 안의 스텝이면 reader 토큰·docker·플래너 스텝이 그 앞에
  #    서고, 그중 하나만 실패해도 GHA는 뒤 스텝을 **건너뛴다** → 그 주기의 회수는 0이 된다.
  #    그래서 회수는 **자기 job**이고, 그 job엔 writer 토큰 말고는 아무 자격도 없다.
  yq -e '.jobs.reconcile' "$F" > /dev/null 2>&1 || {
    echo "structure: reconcile이 별도 job이 아니다 — poll job 안의 스텝이면 reader/플래너 실패에 함께 죽는다"
    false
  }
  # 이 job의 스텝 어디에도 플래너·reader·docker가 없다(= 그것들의 실패에 묶일 수 없다).
  # ⚠️ `grep -q … && { …; false; }`는 **쓰지 않는다** — 매치 0(정상)일 때 그 리스트가 비-0을 돌려줘
  #    bats의 errexit가 테스트를 죽인다(중간 복합 단언 금지 규칙 그대로다). 조건 문맥(`if`)으로만 쓴다.
  body="$(yq -o=json '.jobs.reconcile' "$F")"
  for forbidden in poll-ghcr plan.json docker/login-action ukyi-app; do
    if printf '%s' "$body" | grep -qF -- "$forbidden"; then
      echo "coupled revocation: reconcile job이 '$forbidden'에 의존한다 —"
      echo "  회수는 후보 계획(planning)의 가용성·완전성에 의존해선 안 된다(R-27)."
      printf '%s\n' "$body"
      false
    fi
  done
  # reader App 토큰 스텝(permission-contents: read + owner)이 이 job에 없어야 한다.
  n="$(yq -r '[.jobs.reconcile.steps[] | select(.with."permission-contents" == "read")] | length' "$F")"
  [ "$n" -eq 0 ] || {
    echo "coupled revocation: reconcile job이 reader App 토큰 스텝을 갖는다(${n}개) — 그 스텝이 실패하면 회수가 굶는다"
    false
  }
  # 그런데 writer 자격은 **있어야** 한다(회수 = gh pr merge --disable-auto = PR write).
  w="$(yq -r '[.jobs.reconcile.steps[] | select(.with."permission-pull-requests" == "write")] | length' "$F")"
  [ "$w" -eq 1 ] || {
    echo "reconcile job에 writer App 토큰 스텝이 없다(${w}개, 기대 1개) — 무장을 회수할 자격이 없다"
    false
  }
}

# ── R-38/R-39 항목 격리의 **이관**(F-1) ─────────────────────────────────────────────────────
# 여기 있던 것: 실제 git repo를 만들어 추출한 bump 스텝을 돌리고, (a) 태그 갱신 **쓰기 후** 실패와
# (b) `git add` **후** 실패(=commit 실패)를 주입해 **다음 항목의 커밋에 앞 항목 경로가 0**임을 단언하던
# 증인 + 그 격리가 `git checkout -f main` 정리 **덕분**임을 재현하던 이빨 증인.
#
# 왜 옮겼나(무약화): 그 결함(R-38/H-2)의 원인은 항목들이 **하나의 worktree/index를 공유**한다는 것이었고,
# 옛 수정은 그 공유 위에서 매 항목 `-f` **강제 정리**로 되돌리는 것이었다 — 그래서 "정리가 정말 그 일을
# 하는가"를 증명하는 이빨 증인이 필요했다. 러너는 **항목마다 worktree를 새로 떼어** 그 공유 표면 자체를
# 없앤다: 되돌릴 상태가 애초에 공유되지 않으니, 격리를 지탱하는 **플래그 하나**도 존재하지 않는다.
# 같은 두 시나리오는 `tools/tests/test_run-bump-plan.bats`가 **진짜 git**으로 그대로 태운다:
#   · "H-2: an item that fails AFTER git add leaves no residue in the next item's commit" (staged 잔여)
#   · "an item whose bump-tag fails BEFORE staging is fail-closed and never reaches ensure" (쓰기 전 실패)
#   둘 다 뒤따르는 항목의 커밋 경로에 앞 항목이 0임 + run이 여전히 비-0임(집계)을 단언한다.
# 워크플로 쪽에 남은 몫은 "그 러너 말고 아무 명령도 없다"뿐이고, 위 경계 증인 두 개가 그걸 잡는다.

# bats test_tags=regression
@test "a failing reconcile job never starves the bump loop, and a failing bump loop never starves revocation (and both still turn the run red)" {
  # ★ 두 방향의 균형이 **job 구조**로 성립한다(R-27):
  #   · 회수가 poll의 스텝이면: 그 스텝이 비-0으로 끝나는 순간 GHA가 bump 스텝을 건너뛴다 → 앱 하나의
  #     SSOT 파손이 **모든 배포를 정지**시킨다(억제 = 공격 표면). 그래서 poll은 reconcile의 **성공을 요구하지
  #     않는다**(`if: !cancelled()`).
  #   · bump 루프가 죽어도 회수는 **이미 돌았다**(별도 job, 앞선다).
  #   · 그런데 회수 실패는 **묻히지 않는다**: 그 job이 비-0으로 끝나 run이 빨개진다(telegram 발화).
  setup_hermetic
  rc=$?
  [ "$rc" -ne 9 ] || { echo "hermetic harness: bump 스텝 추출 실패"; false; }
  [ -s "$RSTEP" ] || { echo "reconcile 패스가 없다"; false; }

  # ① poll은 reconcile의 **성공에 묶이지 않는다** — needs는 순서일 뿐이고 if가 그 성공 요구를 푼다.
  cond="$(yq -r '.jobs.poll.if // ""' "$F")"
  case "$cond" in
    *'!cancelled()'*|*'always()'*) : ;;
    *)
      echo "deployment suppressed: poll job이 reconcile의 **성공**을 요구한다(if='$cond') —"
      echo "  회수 실패(앱 하나의 SSOT 파손·API 장애) 하나로 **모든 앱의 배포가 정지**한다(억제 = 공격 표면)."
      echo "  needs는 순서를 위한 것이고, 성공 요구는 !cancelled()로 풀어야 한다."
      false
      ;;
  esac
  # 그리고 reconcile은 poll을 기다리지 않는다(bump 루프의 실패가 회수를 굶길 수 없다).
  rneeds="$(yq -r '[.jobs.reconcile.needs] | flatten | join(" ")' "$F")"
  case "$rneeds" in
    *poll*)
      echo "starved revocation: reconcile job이 poll을 needs로 기다린다('$rneeds') — bump 루프가 죽으면 회수도 죽는다"
      false
      ;;
    *) : ;;
  esac

  # ② 회수 실패는 **묻히지 않는다**: 그 스텝은 실패를 삼키지 않고 비-0으로 끝난다.
  export STUB_FAIL_RECONCILE=1
  run run_step_rc "$RSTEP"
  unset STUB_FAIL_RECONCILE
  [ "$status" -ne 0 ] || {
    echo "silent failure: 인가 회수가 실패했는데 스텝이 성공(exit 0)으로 끝났다 —"
    echo "  낡은 무장을 회수하지 못했는데 아무도 모르는 상태가 된다(telegram 무발화)."
    step_out; dump_calls; false
  }

  # ③ 그런데 그 실패가 bump 경로를 굶기지는 않는다 — bump 스텝은 회수가 남긴 어떤 파일/스텝에도
  #    **의존하지 않는다**(예전엔 reconcile이 실패 파일을 남기고 bump 스텝이 그걸 읽었다 → 두 경로가
  #    한 job에 엮여 있었다). ⚠️ F-1 이후 "후보 앱에 도달했는가"는 러너 안의 사실이라 러너 스위트가
  #    본다("…without starving the other item"). 여기서 보는 건 **경로가 살아 있는가**다: 회수가 죽은
  #    주기에도 bump 스텝이 깨끗하게 끝나고 러너를 **실제로 부른다**.
  run run_step_rc "$STEP"
  [ "$status" -eq 0 ] || {
    echo "coupled failure: 회수 실패와 무관하게 bump 스텝은 자기 일만 하고 끝나야 한다(exit $status)"
    step_out; dump_calls; false
  }
  n="$(runner_calls)"
  [ "$n" -eq 1 ] || {
    echo "starved bump: 회수가 실패한 주기에 bump 스텝이 러너를 ${n}회 불렀다(기대 1회) —"
    echo "  회수 실패가 bump 경로를 굶기면 억제가 곧 공격 표면이 된다(배포 정지)."
    step_out; dump_calls; false
  }
}

# ── ⑨ **회수의 게이트는 writer 하나뿐이다**(structure r9 R-31) ────────────────────────────────────
# ⑧은 reconcile을 **자기 job**으로 떼어내 reader 토큰·docker·플래너 **스텝**에서 풀었다. 그런데 그 job의
# **선행 의존**(`needs: preflight` + `if:`)은 그대로 남아 있었다: preflight의 공유 출력 `configured`가
# `READER && WRITER`였고 reconcile이 거기 걸려 있었다 → **reader App ID가 없거나 회전 중이기만 해도**
# GitHub이 회수 job을 **깨끗하게 skip**한다(그 job은 writer 자격만 쓰는데도). 무장된 PR은 바로 그
# reader/planning 열화 구간에서 **낡은 인가를 그대로 유지**한다 — R-27이 떼어내려던 그 구간이다.
# 계약: **writer 자격만 있으면 reconcile은 돈다.** 두 자격을 다 요구하는 건 **poll뿐**이다.
# ⚠️ 증인은 문자열 grep이 아니라 **조건식을 실제로 평가**한다 — job 본문만 보는 증인이 이 선행 의존을
#    놓쳤다는 게 R-31의 요지다.

# bats test_tags=regression
@test "a missing reader skips ONLY the poll job — revocation runs on writer credentials alone (both job gates evaluated for real)" {
  # ⓪ reconcile job이 **존재한다**(없으면 게이트를 논할 대상 자체가 없다 — 회수 0).
  yq -e '.jobs.reconcile' "$F" > /dev/null 2>&1 || {
    echo "stale authorization survives: reconcile job이 없다 — 회수 경로 자체가 존재하지 않는다"
    false
  }
  # ⓪-b 준비상태가 **둘로 갈려 있다**. 하나(configured)로 합쳐 두면 reader 부재가 회수를 막는다 —
  #     그 구조에선 조건식을 어떻게 써도 두 게이트를 독립시킬 수 없다(같은 값을 보기 때문이다).
  nk="$(yq -r '.jobs.preflight.outputs // {} | keys | length' "$F")"
  [ "$nk" -ge 2 ] || {
    echo "coupled readiness: preflight이 준비상태를 ${nk}개만 낸다(기대 2개 이상: writer / reader) —"
    echo "  writer·reader를 한 출력으로 AND하면 **reader 부재가 회수를 skip시킨다**(R-31)."
    yq -r '.jobs.preflight.outputs' "$F"
    false
  }

  # ① ★ 핵심 시나리오: **reader 없음 + writer 있음**(키 회전 중·Phase 0 부분 완료).
  #    → reconcile은 **돈다**(회수는 writer 자격만 쓴다), poll은 **skip**된다(플래너가 reader를 쓴다).
  run gates_for "" "writer-app-id"
  [ "$status" -eq 0 ] || { echo "harness: 게이트 평가가 실패했다"; echo "$output"; false; }
  [ "$output" = "true false" ] || {
    echo "starved revocation: reader가 없을 때 두 job의 게이트가 '(reconcile poll) = $output'이다(기대 'true false') —"
    echo "  reader App ID가 비었거나 회전 중이기만 해도 GitHub이 **회수 job을 통째로 skip**한다."
    echo "  그 job은 writer 자격만 쓴다 — reader 준비상태에 걸릴 이유가 없다. 무장된 PR이 낡은 인가를 유지한다."
    echo "  reconcile.if = $(yq -r '.jobs.reconcile.if // "(없음)"' "$F")"
    echo "  poll.if      = $(yq -r '.jobs.poll.if // "(없음)"' "$F")"
    echo "  preflight.outputs = $(yq -o=json -I=0 '.jobs.preflight.outputs' "$F")"
    false
  }

  # ② 둘 다 있으면 둘 다 돈다(정상 주기 — 과잉 교정으로 poll을 죽이지 않았는가).
  run gates_for "reader-app-id" "writer-app-id"
  [ "$status" -eq 0 ] || { echo "harness: 게이트 평가가 실패했다"; echo "$output"; false; }
  [ "$output" = "true true" ] || {
    echo "over-correction: 자격이 모두 있는 정상 주기에 '(reconcile poll) = $output'이다(기대 'true true')"
    false
  }

  # ③ **writer가 없으면 회수도 못 한다**(`gh pr merge --disable-auto`가 PR write다) → reconcile도 skip.
  #    ⚠️ 이 단언이 없으면 "reconcile.if를 아예 없앤다(항상 true)"는 구현이 ①②를 통과한다 —
  #    그건 Phase 0 미완 주기에 매 10분 토큰 민팅 실패 + telegram 스팸이 된다(preflight의 존재 이유).
  run gates_for "reader-app-id" ""
  [ "$status" -eq 0 ] || { echo "harness: 게이트 평가가 실패했다"; echo "$output"; false; }
  [ "$output" = "false false" ] || {
    echo "phase-0 spam: writer 자격이 없는데 '(reconcile poll) = $output'이다(기대 'false false') —"
    echo "  회수는 writer(PR write) 없이는 불가능하다. 게이트가 없으면 매 10분 토큰 민팅이 실패한다."
    false
  }

  # ④ 아무것도 없으면 둘 다 skip — run은 **깨끗한 성공**이다(Phase 0 계약, 지금도 유효하다).
  run gates_for "" ""
  [ "$status" -eq 0 ] || { echo "harness: 게이트 평가가 실패했다"; echo "$output"; false; }
  [ "$output" = "false false" ] || {
    echo "phase-0 계약 위반: 자격이 하나도 없는데 '(reconcile poll) = $output'이다(기대 'false false')"
    false
  }
}

@test "the gate evaluator has teeth (a shared writer&&reader readiness output flips the reader-absent scenario RED)" {
  # ★ 하네스 자기증명. 평가기가 `if`를 **실제로** 계산한다는 걸 재현으로 못박는다 — 이게 없으면 평가기가
  #   조용히 언제나 "true false"를 뱉어도(예: 컨텍스트 치환이 깨져 false로 접혀도) 위 증인은 GREEN이고
  #   아무것도 증명하지 못한다.
  # ⚠️ baseline에서도 GREEN이다(평가기는 이 커밋이 새로 넣은 하네스다) → characterization.
  #
  # ── 변이: 옛 구조(공유 `configured` = READER && WRITER)를 그대로 재현한 워크플로 사본 ─────────────
  MUT="$BATS_TEST_TMPDIR/bump-poll.mut.yaml"
  yq '
    .jobs.preflight.outputs = {"configured": "${{ steps.check.outputs.configured }}"} |
    .jobs.preflight.steps[0].run = "if [ -n \"$READER\" ] && [ -n \"$WRITER\" ]; then\n  echo \"configured=true\" >> \"$GITHUB_OUTPUT\"\nelse\n  echo \"configured=false\" >> \"$GITHUB_OUTPUT\"\nfi\n" |
    .jobs.reconcile.if = "needs.preflight.outputs.configured == '"'"'true'"'"'" |
    .jobs.poll.if = "${{ !cancelled() && needs.preflight.outputs.configured == '"'"'true'"'"' }}"
  ' "$F" > "$MUT"

  # 그 사본으로 같은 시나리오(reader 없음 + writer 있음)를 평가한다 → 회수가 **skip된다**(= 결함 재현).
  F="$MUT"
  run gates_for "" "writer-app-id"
  [ "$status" -eq 0 ] || { echo "harness: 변이본 평가가 실패했다"; echo "$output"; false; }
  [ "$output" = "false false" ] || {
    echo "toothless witness: 공유 configured 구조에서도 게이트가 '(reconcile poll) = $output'로 나왔다 —"
    echo "  평가기가 조건식을 실제로 계산하지 않는다(기대 'false false' — reader 부재가 회수를 skip시킨다)."
    false
  }
  # 그리고 정상 주기(둘 다 있음)에선 그 사본도 둘 다 돈다 — 즉 위 결과는 **reader 부재 때문**이다.
  run gates_for "reader-app-id" "writer-app-id"
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

# ---------------------------------------------------------------------------
# 보존 — 재작성이 기존 계약(플래너·TOCTOU 가드·공유 auto-merge 스크립트)을 깨지 않았음을 확인(지금도 GREEN)
# ---------------------------------------------------------------------------

@test "bump-poll still plans with poll-ghcr, and the runner still re-proves the from-tag via --expect-current" {
  # ★ 이 증인은 F-1로 **둘로 갈렸다**(무약화 분할):
  #   · 계획(플래너)은 여전히 워크플로의 일이다 — poll-ghcr가 /tmp/plan.json을 쓴다.
  #   · races-4 TOCTOU 재증명(`--expect-current`)은 갱신을 실행하는 쪽, 즉 **러너**의 일이 됐다.
  # ⚠️ 두 번째 절반을 그냥 지우면(워크플로에 그 문자열이 없으니) 계약이 조용히 사라진다 — 그래서
  #    같은 문장을 러너 소스에 다시 건다. **실행 증인**은 `tools/tests/test_run-bump-plan.bats`의
  #    "an item whose bump-tag fails BEFORE staging is fail-closed…"이다: plan 스냅샷의 current.tag를
  #    실제 파일과 어긋나게 주면 그 항목이 fail-closed로 죽고 실행기에 도달하지 못한다(= 가드가 산다.
  #    러너가 스냅샷 대신 라이브 파일을 다시 읽었다면 자기비교가 돼 그 증인이 GREEN으로 통과했을 것이다).
  run grep -q "tools/poll-ghcr.ts" "$F"
  [ "$status" -eq 0 ]
  # ⚠️ expect-current 절반의 **소유자는 `tools/tests/test_bump-poll-toctou.bats`**다(races-4 파일).
  #    여기에 사본을 두면 같은 문장이 두 게이트에 갈라져 드리프트한다 — 존재만 확인하고 소유는 넘긴다.
  run grep -q -- '"--expect-current"' "$ROOT/tools/tests/test_bump-poll-toctou.bats"
  [ "$status" -eq 0 ]
}

@test "the auto-merge ban is scoped to bump-poll.yaml (the shared script keeps its other callers)" {
  # ⑤의 금지는 **파일 스코프**다 — scripts/auto-merge-or-fail.sh는 삭제 대상이 아니다.
  # bump-poll 레인의 auto-merge는 사라지는 게 아니라 **실행기 안으로 옮겨간다**(PR 생성 직후 1회).
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/scripts/auto-merge-or-fail.sh"
  [ "$status" -eq 0 ]
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/.github/workflows/bump.yaml"
  [ "$status" -eq 0 ]
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/.github/actions/pr-first-commit/action.yml"
  [ "$status" -eq 0 ]
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/tools/ensure-bump-pr.ts"
  [ "$status" -eq 0 ]
}

# ⚠️ 이관됨(F-1) — "the commit the workflow EFFECTIVELY makes carries the identity and message the
#    executor proves ownership with" + 그 이빨 증인("a later git config override and a --amend both flip
#    it RED"). 커밋을 만드는 코드가 러너로 옮겨갔으므로 계약도 함께 갔다:
#    `tools/tests/test_run-bump-plan.bats`의 "the commit the runner EFFECTIVELY makes…"가 같은 파생
#    (실행기 소스의 DEFAULT_WRITER/WRITER_BOT_NAME/WRITER_BOT_EMAIL_RE/bumpCommitMessageOf — 못 찾으면
#    exit 2)을 들고 **진짜 git 커밋 오브젝트**와 대조한다(정체성·메시지·항목당 1커밋).
#    이빨 증인이 함께 사라진 이유: 그건 stub git이 last-write-wins/--amend **의미를 흉내내는지**를
#    증명하는 하네스 자기증명이었다. 관측 대상이 모형에서 실물로 바뀌면 흉내낼 의미가 없다 —
#    대신 러너 스위트 쪽에서 정체성·메시지·커밋 수 세 변이가 각각 RED가 됨을 확인했다(무약화).
#    그리고 워크플로가 git을 **직접 부르지 않는다**는 사실은 위 "…executes the runner and NOTHING else"가 잡는다.
