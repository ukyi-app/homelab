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
#        (c) 워크플로는 레인을 **재해석하지 않고** 플래너의 `.action`을 **그대로** 넘긴다(아래 증인).
#      → 승인 레인을 자동 배포로 바꾸려면 플래너를 속여야 하고, 플래너의 레인은 `.bindings.json`의
#        autoDeploy(SSOT)에서 온다(poll-ghcr.ts: `action: s.autoDeploy ? "bump" : "propose-pr"`).
#        즉 **워크플로 편집만으로는 승인 게이트를 넘을 수 없다** — 그게 이 계약의 요점이다.
#
# ── 구현자 가이드(이 파일의 회귀 증인들이 GREEN이 되려면 bump 스텝이 이렇게 생겨야 한다) ────────────
#   git checkout main
#   branch="bump-poll/${app}-${tag}"          # ③ RUN_ID 금지 — tag가 bump의 정체성이다
#   git checkout -b "$branch"                 # ④-1 브랜치 생성(최신 main에서 재구축)
#   bun tools/bump-tag.ts "$app" "$tag" --digest "$digest" --expect-current "$expect" [--pin "$pin"]  # ④-2
#   git add "$writePath" platform/victoria-stack/prod/digest-exporter.yaml
#   git commit -m "chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)"                        # ④-3
#   bun tools/ensure-bump-pr.ts --app "$app" --tag "$tag" --action "$action" \                        # ④-4, ⑤, ⑥
#     --title … --body …
#   # ⑥ `--action "$action"` — 플래너가 준 값 **그대로**. 하드코딩(`--action bump`)도, 재해석
#   #    (`[ "$action" = bump ] && …`)도 금지다. 레인별로 title/body가 다르면 if/else로 그것만 가르고
#   #    `--action "$action"`는 양쪽에 똑같이 넘긴다.
#   # ⑤ `git push`·`gh pr create`·`bash scripts/auto-merge-or-fail.sh`는 이 스텝에 **남지 않는다**.
#
# 회귀(test_tags=regression): 지금은 RED(워크플로가 아직 옛 방식 — 직접 push + 직접 gh pr create + RUN_ID
# + auto-merge 직접 호출, 그리고 ensure-bump-pr 호출 자체가 없다).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]]·중간 `!`는 침묵 통과.
# ⚠️ @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/bump-poll.yaml"
  SWEEPER="$ROOT/.github/workflows/pr-sweeper.yaml"
  EXECUTOR="$ROOT/tools/ensure-bump-pr.ts"
  # 전체-줄 주석을 **빈 줄로 치환**한 뷰(줄 번호는 보존) — 주석 속 설명 문구("…auto-merge-or-fail…",
  # "…bump-tag.ts가 재검증한다" 등)가 순서·금지 증인에 오탐되는 걸 막는다(test_mutation-dispatch의 선례).
  CODE="$BATS_TEST_TMPDIR/bump-poll.code.yaml"
  sed 's/^[[:space:]]*#.*$//' "$F" > "$CODE"

  # ── 실행기의 **소유권 기대값**을 소스에서 뽑아낸다(하드코딩 금지 — structure r6 R-24) ──────────────
  # 왜 실행기 소스에서 뽑는가: 이 게이트가 지키는 불변식은 "워크플로가 **실제로 만드는 커밋**이 실행기가
  # **소유권을 증명하는 형태**와 같다"이다. 기대값을 테스트에 베껴 쓰면 그 순간 **양쪽 다 드리프트해도**
  # 게이트가 GREEN인 세 번째 진실이 생긴다 → 실행기 소스가 SSOT다.
  # 형태(BUMP_COMMIT_MESSAGE / WRITER_BOT_NAME / WRITER_BOT_EMAIL_RE / DEFAULT_WRITER)를 못 찾으면
  # **exit 2로 죽는다** — "찾지 못했으니 통과"는 이 게이트가 막으려는 바로 그 침묵이다.
  EXPECT_PY="$BATS_TEST_TMPDIR/expect.py"
  cat > "$EXPECT_PY" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()


def need(pat, what):
    m = re.search(pat, src)
    if not m:
        sys.stderr.write(
            "expect: 실행기에서 %s를 찾지 못했다(형태 드리프트) — 소유권 기대값을 모르면 게이트는 통과하지 않는다\n"
            % what,
        )
        sys.exit(2)
    return m


writer = need(r'DEFAULT_WRITER\s*=\s*"([^"]+)"', "DEFAULT_WRITER").group(1)
name_tmpl = need(r"WRITER_BOT_NAME\s*=\s*`([^`]*)`", "WRITER_BOT_NAME").group(1)
email_tmpl = need(r"WRITER_BOT_EMAIL_RE\s*=\s*new RegExp\(`([^`]*)`\)", "WRITER_BOT_EMAIL_RE").group(1)
msg_tmpl = need(r"BUMP_COMMIT_MESSAGE\s*=\s*`([^`]*)`", "BUMP_COMMIT_MESSAGE").group(1)

# 템플릿 리터럴의 보간부를 실행기와 **같은 값**으로 채운다(기본 --writer = DEFAULT_WRITER).
bot_name = name_tmpl.replace("${normalizeLogin(args.writer)}", writer)
# TS 소스의 `\\d`는 정규식 `\d`다 → 먼저 언이스케이프한 뒤 escapeRe(WRITER_BOT_NAME)을 채운다.
email_re = email_tmpl.replace("\\\\", "\\").replace("${escapeRe(WRITER_BOT_NAME)}", re.escape(bot_name))

mode = sys.argv[2]
if mode == "name":
    print(bot_name)
elif mode == "email":  # argv[3] = 관측된 effective email
    sys.exit(0 if re.match(email_re, sys.argv[3]) else 1)
elif mode == "msg":  # argv[3] = app, argv[4] = tag
    print(msg_tmpl.replace("${args.app}", sys.argv[3]).replace("${args.tag}", sys.argv[4]))
else:
    sys.exit(2)
PY
}

# 실행기 소스에서 파생한 소유권 기대값(name / email 매칭 / app·tag별 커밋 메시지).
expect_of() { python3 "$EXPECT_PY" "$EXECUTOR" "$@"; }

# 주석 제거 뷰에서 ERE가 처음 등장한 줄 번호(없으면 빈 문자열 → 단언이 [ -n ]로 잡는다).
first_line() { grep -nE "$1" "$CODE" | head -1 | cut -d: -f1; }

# ── 순서 계약은 **bump 스텝 본문 안에서만** 의미가 있다(H-1 이후) ─────────────────────────────────
# 파일 전체를 훑으면 다른 스텝의 실행기 호출(reconcile 패스는 후보가 없어도 매 주기 돌아야 하므로
# bump 스텝보다 **앞에** 있다)이 "커밋 전에 실행기를 불렀다"로 오탐된다. 계약의 대상은 언제나
# "브랜치를 재구축해 커밋을 얹은 그 스텝"이다 → 그 스텝의 `.run` 본문만 뽑아서 순서를 본다.
step_code() {
  local out="$BATS_TEST_TMPDIR/bump-step.code.sh"
  extract_step | sed 's/^[[:space:]]*#.*$//' > "$out"
  printf '%s' "$out"
}
first_line_in() { grep -nE "$2" "$1" | head -1 | cut -d: -f1; }

# ── hermetic 루프 하네스(plan r6) ───────────────────────────────────────────────────────────
# 왜 필요한가: 정적 grep 증인은 **문자열 모양**만 본다. `action=$(… jq -r .action)` … `action=bump` …
# `--action "$action"`처럼 **읽은 뒤 덮어쓰는** 호출부는 모든 grep 증인을 통과하면서 승인 레인(propose-pr)
# 후보를 bump 레인으로 흘려보낸다(= autoDeploy:false 앱 자동 배포). 그런 우회는 "실제로 무슨 argv가
# 실행기에 갔는가"를 봐야만 죽는다 → 워크플로의 bump 스텝 셸 본문을 **그대로 꺼내서** 두 레인이 섞인
# plan.json으로 **실행**하고, 실행기에 전달된 argv를 원장에서 단언한다.
#
# 왜 YAML에서 추출하는가(스텝을 scripts/*.sh로 강제 추출시키지 않고): 게이트가 프로덕션의 **구조**까지
# 지시하면 fix 증분이 "테스트를 만족시키려고" 리팩터를 떠안는다. 스텝 본문은 이미 다른 증인들이 그
# 존재를 요구하는 것(bump-tag·ensure-bump-pr 호출)이라 선택자가 안정적이다 → 프로덕션 무변경으로 실행 가능.
extract_step() {
  # 스텝 선택자: `.run`에 bump-tag가 있는 스텝(= bump 스텝)의 **셸 본문(.run)**. 순서 증인이 이미
  # 그 스텝의 존재를 강제한다. ⚠️ `.[0]`은 스텝 **맵 전체**를 준다 — 반드시 `.[0].run`이어야 한다
  # (실측: 맵을 그대로 실행하면 `syntax error near unexpected token '('`로 죽는다).
  yq -r '[.jobs.poll.steps[] | select(.run) | select(.run | test("bump-tag"))] | .[0].run // ""' "$F"
}
# reconcile 패스(인가 회수)의 셸 본문. ★ 이제 **별도 job**이다(R-27) — poll job의 스텝이 아니다:
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
  # ⚠️ 아래 후보 tag는 소유권 증인(effective 커밋 메시지)의 기대값에도 쓰인다 — plan JSON과 **같은 값**이다.
  PAGE_TAG="sha-2222222222222222222222222222222222222222"
  TRIP_TAG="sha-4444444444444444444444444444444444444444"
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

  # gh stub — argv를 원장에 남기고 성공만 흉내낸다(실제 변이 0).
  cat > "$STUB/gh" <<'GHEOF'
#!/bin/sh
{ printf '%s\0' gh "$@"; printf '\036'; } >> "$CALLS"
exit 0
GHEOF
  chmod +x "$STUB/gh"

  # ── bun stub — 한 앱만 **fail-closed로 죽이는 주입점**을 갖는다(H-2 격리 증인) ─────────────────
  # 라이브의 fail-closed(증명되지 않은 head 등)는 사람이 개입할 때까지 **영구히** 지속된다. 그래서
  # "한 앱의 실패가 뒤따르는 앱들을 굶기는가"가 실제 질문이다 — 그걸 주입해서 실측한다.
  cat > "$STUB/bun" <<'BUNEOF'
#!/bin/sh
{ printf '%s\0' bun "$@"; printf '\036'; } >> "$CALLS"
if [ -n "${STUB_FAIL_APP:-}" ] && [ "$1" = "tools/ensure-bump-pr.ts" ]; then
  take=""
  for a in "$@"; do
    if [ "$take" = "1" ]; then
      if [ "$a" = "$STUB_FAIL_APP" ]; then
        echo "stub bun: ${a} 실행기 fail-closed(주입)" >&2
        exit 1
      fi
      take=""
    fi
    case "$a" in --app) take=1 ;; esac
  done
fi
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

  # ── git stub — argv 원장에 더해 **effective 상태**를 기록한다(structure r6 R-24) ────────────────
  # 왜 argv 원장만으론 부족한가: 소유권 계약이 걸린 값은 "워크플로 어딘가에 이런 줄이 있다"가 아니라
  # **커밋이 실제로 갖게 될 값**이다. `git config user.name`은 **마지막 쓰기가 이기고**, 커밋 메시지는
  # `--amend`가 **덮어쓴다** → 뒤에 오는 한 줄이 앞의 모든 문자열 증인을 무력화하면서 라이브의 실효값을
  # 바꿀 수 있다(그러면 실행기의 adopt/rebuild가 **영구 fail-closed** = 조용한 배포 정지).
  # 그래서 stub이 git의 의미를 흉내낸다:
  #   config <key> <val>  → GIT_CONFIG_LOG에 append (질의 시 **마지막 값**을 취한다 = last-write-wins)
  #   commit -m <msg>     → GIT_COMMIT_LOG에 append (HEAD가 갖게 될 메시지)
  #   commit --amend -m … → 마지막 항목을 **교체**(커밋을 늘리지 않는다)
  #   commit --amend      → (메시지 없음) 그대로 둔다
  export GIT_CONFIG_LOG="$BATS_TEST_TMPDIR/git-config.tsv"
  export GIT_COMMIT_LOG="$BATS_TEST_TMPDIR/git-commit.log"
  : > "$GIT_CONFIG_LOG"
  : > "$GIT_COMMIT_LOG"

  cat > "$STUB/git" <<'GITEOF'
#!/bin/sh
{ printf '%s\0' git "$@"; printf '\036'; } >> "$CALLS"
sub="$1"
shift
case "$sub" in
  config)
    # `--global` 같은 옵션은 건너뛰고 첫 두 위치 인자를 key/value로 읽는다.
    key=""
    val=""
    for a in "$@"; do
      case "$a" in --*) continue ;; esac
      if [ -z "$key" ]; then key="$a"; continue; fi
      if [ -z "$val" ]; then val="$a"; fi
    done
    [ -z "$key" ] || printf '%s\t%s\n' "$key" "$val" >> "$GIT_CONFIG_LOG"
    ;;
  commit)
    amend=""
    msg=""
    msg_set=""
    take=""
    for a in "$@"; do
      if [ -n "$take" ]; then msg="$a"; msg_set=1; take=""; continue; fi
      case "$a" in
        --amend) amend=1 ;;
        -m|--message) take=1 ;;
        -m*) msg="${a#-m}"; msg_set=1 ;;
      esac
    done
    if [ -n "$amend" ]; then
      # 메시지 없는 --amend(--no-edit)는 HEAD 메시지를 바꾸지 않는다.
      [ -n "$msg_set" ] || exit 0
      # 마지막 커밋의 메시지를 **교체**한다(새 커밋이 아니다).
      if [ -s "$GIT_COMMIT_LOG" ]; then
        sed '$d' "$GIT_COMMIT_LOG" > "$GIT_COMMIT_LOG.t"
        mv "$GIT_COMMIT_LOG.t" "$GIT_COMMIT_LOG"
      fi
    fi
    printf '%s\n' "$msg" >> "$GIT_COMMIT_LOG"
    ;;
esac
exit 0
GITEOF
  chmod +x "$STUB/git"

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


def opt(rec, name):
    for i, a in enumerate(rec):
        if a == name and i + 1 < len(rec):
            return rec[i + 1]
    return ""


if mode == "count":
    print(len(ensure))
elif mode == "bumptag":  # 하네스 자체의 증명: 루프가 두 후보를 **실제로** 돌았는가
    print(len(tool("tools/bump-tag.ts")))
elif mode == "lane":  # want[0] = app 이름 → 그 앱의 --action 값(정확히 1건이 아니면 빈 문자열)
    hits = [r for r in ensure if opt(r, "--app") == want[0]]
    print(opt(hits[0], "--action") if len(hits) == 1 else "")
elif mode == "reconciled":  # 인가 회수 패스가 실행기에 **도달한 횟수**(대상 목록은 인자가 아니다 — R-27)
    print(sum(1 for r in ensure if "--reconcile-only" in r))
elif mode == "bumped":  # `--reconcile-only` **없이**(= bump 경로) 실행기에 도달한 앱들
    print(" ".join(sorted({opt(r, "--app") for r in ensure if "--reconcile-only" not in r} - {""})))
elif mode == "argcount":  # want[0] 인자를 포함하는 실행기 레코드 수(예: reconcile 패스의 `--action` = 0이어야 한다)
    print(sum(1 for r in ensure if want[0] in r))
elif mode == "dump":
    for i, r in enumerate(records, 1):
        print("%2d) argc=%d  %s" % (i, len(r), " ".join(repr(a) for a in r)))
else:
    sys.exit(2)
PY

  # 워크플로 스텝은 GHA에서 `bash -e {0}`로 돈다(레포 함정 원장) → 같은 셸 의미로 실행한다.
  PATH="$STUB:$PATH" GH_TOKEN=stub-token RUN_ID=999 bash -e "$STEP" > "$BATS_TEST_TMPDIR/step.out" 2>&1 || true
}

ensure_calls()  { python3 "$LEDGER_PY" count "$CALLS"; }
bumptag_calls() { python3 "$LEDGER_PY" bumptag "$CALLS"; }
lane_of()       { python3 "$LEDGER_PY" lane "$CALLS" "$1"; }
# 인가 회수 패스가 실행기에 도달한 **횟수**(앱 목록이 아니다 — 대상은 네임스페이스가 준다: R-27).
reconcile_calls() { python3 "$LEDGER_PY" reconciled "$CALLS"; }
bumped_apps()     { python3 "$LEDGER_PY" bumped "$CALLS"; }
arg_calls()       { python3 "$LEDGER_PY" argcount "$CALLS" "$1"; }
dump_calls()    { echo "--- 스텝이 실행한 명령(원장) ---"; python3 "$LEDGER_PY" dump "$CALLS"; }

# git stub이 기록한 **effective** 값 — "워크플로 어딘가에 그런 줄이 있다"가 아니라 "커밋이 실제로 갖는 값".
effective_config()  { awk -F '\t' -v k="$1" '$1 == k { v = $2 } END { print v }' "$GIT_CONFIG_LOG"; }
effective_commit()  { sed -n "$1p" "$GIT_COMMIT_LOG"; }
effective_commits() { wc -l < "$GIT_COMMIT_LOG" | tr -d ' '; }
dump_effective() {
  echo "--- effective git 상태(마지막 쓰기가 이긴다) ---"
  echo "user.name  = '$(effective_config user.name)'"
  echo "user.email = '$(effective_config user.email)'"
  echo "--- HEAD가 갖게 될 커밋 메시지(--amend 반영) ---"
  cat -n "$GIT_COMMIT_LOG"
}
# 스텝 본문(원본 또는 변이본)을 같은 stub 아래에서 다시 돌린다 — 하네스 이빨 증명용.
run_step() {
  : > "$CALLS"
  : > "$GIT_CONFIG_LOG"
  : > "$GIT_COMMIT_LOG"
  PATH="$STUB:$PATH" GH_TOKEN=stub-token RUN_ID=999 bash -e "$1" > "$BATS_TEST_TMPDIR/step.out" 2>&1 || true
}
# 같은 실행이되 **종료 코드를 삼키지 않는다**(H-2: "run이 여전히 빨간가"가 계약의 절반이다).
# 스텝은 GHA에서 `bash -e {0}`로 돈다(레포 함정 원장) → 같은 셸 의미로 돌린다.
run_step_rc() {
  : > "$CALLS"
  : > "$GIT_CONFIG_LOG"
  : > "$GIT_COMMIT_LOG"
  PATH="$STUB:$PATH" GH_TOKEN=stub-token RUN_ID=999 STUB_FAIL_APP="${STUB_FAIL_APP:-}" \
    STUB_FAIL_RECONCILE="${STUB_FAIL_RECONCILE:-}" \
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
@test "bump-poll drives the PR step through tools/ensure-bump-pr.ts" {
  run grep -n "tools/ensure-bump-pr.ts" "$CODE"
  if [ "$status" -ne 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml이 tools/ensure-bump-pr.ts를 호출하지 않는다 — 멱등 실행기가 배선되지 않으면 도구 GREEN이 프로덕션을 고치지 못한다"
    false
  fi
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

# bats test_tags=regression
@test "the bump step creates the branch, bumps the tag, commits, and only then calls ensure-bump-pr (in that order)" {
  # plan r4 R-8: ①②③은 "도구를 부른다"까지만 본다 — **언제** 부르는지는 안 본다. 그래서 커밋 전에(또는
  # bump-tag 전에) 도구를 부르는 구현도 GREEN이 된다. 그런 호출부는 라이브에서 diff 0짜리 PR을 열거나
  # (빈 커밋) 갱신을 통째로 빠뜨린다 — 도구의 push argv 계약이 `HEAD:refs/heads/<b>`(=로컬 커밋)이기 때문.
  # ⚠️ 대상은 **bump 스텝 본문**이다(파일 전체가 아니다) — reconcile 패스는 후보 없이도 매 주기 돌아야 해서
  #    이 스텝보다 앞에 있고, 파일 전체를 훑으면 그 실행기 호출이 "커밋보다 앞"으로 오탐된다.
  SC="$(step_code)"
  [ -s "$SC" ] || { echo "호출부 순서 계약: bump 스텝(.run에 bump-tag 포함)을 추출하지 못했다"; false; }
  branch_at="$(first_line_in "$SC" 'git (switch -c|checkout -b)')"
  bump_at="$(first_line_in "$SC" 'bun tools/bump-tag\.ts')"
  commit_at="$(first_line_in "$SC" 'git commit')"
  ensure_at="$(first_line_in "$SC" 'bun tools/ensure-bump-pr\.ts')"

  [ -n "$branch_at" ] || { echo "호출부 순서 계약: 브랜치 생성(git switch -c | git checkout -b)이 없다"; false; }
  [ -n "$bump_at" ]   || { echo "호출부 순서 계약: bun tools/bump-tag.ts 호출이 없다"; false; }
  [ -n "$commit_at" ] || { echo "호출부 순서 계약: git commit이 없다"; false; }
  [ -n "$ensure_at" ] || {
    echo "호출부 순서 계약: bun tools/ensure-bump-pr.ts 호출이 없다 — 실행기가 배선돼야 순서를 증명할 수 있다"
    echo "  기대 순서: git checkout -b → bun tools/bump-tag.ts → git commit → bun tools/ensure-bump-pr.ts"
    false
  }

  [ "$branch_at" -lt "$bump_at" ] || {
    echo "호출부 순서 계약 위반: bump-tag(줄 $bump_at)가 브랜치 생성(줄 $branch_at)보다 앞선다 — main 위에서 값이 바뀐다"
    false
  }
  [ "$bump_at" -lt "$commit_at" ] || {
    echo "호출부 순서 계약 위반: git commit(줄 $commit_at)이 bump-tag(줄 $bump_at)보다 앞선다 — 갱신 없는 빈 커밋"
    false
  }
  [ "$commit_at" -lt "$ensure_at" ] || {
    echo "호출부 순서 계약 위반: ensure-bump-pr(줄 $ensure_at)가 git commit(줄 $commit_at)보다 앞선다 —"
    echo "  도구는 HEAD(=로컬 커밋)를 민다. 커밋 전에 부르면 main과 동일한 HEAD를 밀어 diff 0짜리 PR이 열린다."
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
@test "the lane is forwarded verbatim from the planner (only autoDeploy can arm auto-merge)" {
  # ★ plan r5 R-11. 승인 게이트 우회를 **구조적으로** 막는 호출부 절반(⑥의 (c)).
  #
  # 옛 게이트는 "워크플로 어딘가에 --auto-merge 토큰이 있으면 통과"였다. 그 게이트는 두 레인 모두에
  # 무조건 --auto-merge를 넘기는 구현도 GREEN으로 통과시킨다 → autoDeploy:false 승인 PR이 자동 배포된다.
  # 새 계약: auto-merge를 켜는 플래그는 **존재하지 않고**(도구 스위트가 그걸 고정), 레인이 유일한 입력이며,
  # 워크플로는 그 레인을 **플래너가 준 그대로** 넘긴다.

  # ① 무장 플래그는 워크플로 어디에도 없다 — 도구가 그런 옵션을 받지 않는다(exit 2). 남아 있다면
  #    누군가 "레인 밖에서 무장하는 길"을 되살리려 한 것이다.
  run grep -nE -- '--auto-merge' "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "approval gate bypass: bump-poll.yaml에 '--auto-merge'가 있다 — 그런 플래그는 존재하지 않는다."
    echo "  무장은 레인(--action bump)만이 켠다. 별도 플래그를 되살리면 두 레인에 무조건 넘기는 것만으로"
    echo "  autoDeploy:false 승인 PR이 자동 배포된다(승인 게이트 우회)."
    echo "$output"
    false
  fi

  # ② 레인은 플래너의 `.action`에서 온다(= .bindings.json의 autoDeploy SSOT). 이 배선이 끊기면
  #    워크플로가 레인을 스스로 지어내게 되고, 그 순간 승인 게이트는 워크플로 편집만으로 뚫린다.
  run grep -nE 'action=\$\(.*jq -r [.]action' "$CODE"
  if [ "$status" -ne 0 ]; then
    echo "lane provenance: bump-poll.yaml이 플래너의 .action을 \$action으로 읽지 않는다 —"
    echo "  레인의 출처는 poll-ghcr(.bindings.json의 autoDeploy)여야 한다: action=\$(echo \"\$item\" | jq -r .action)"
    false
  fi

  # ③ 실행기에 --action이 최소 1회 넘어간다(무장 자체가 사라지면 autoDeploy 배포가 멈춘다).
  total="$(grep -oE -- '--action' "$CODE" | wc -l | tr -d ' ')"
  [ "$total" -ge 1 ] || {
    echo "lost auto-merge: bump-poll.yaml이 ensure-bump-pr에 --action을 넘기지 않는다 —"
    echo "  레인이 없으면 도구가 exit 2로 죽는다(기본값 없음). autoDeploy 레인은 자동 머지가 계약이다."
    false
  }

  # ④ ★ 봉인: **모든** --action 등장이 `$action` 변수 **그대로**여야 한다. 하드코딩된 `--action bump`가
  #    하나라도 있으면 propose-pr 후보가 bump 레인으로 흘러 자동 배포된다 — 그리고 ①②③은 다 통과한다.
  #    허용 표기: `--action "$action"` / `--action $action` / `--action "${action}"` — **공백 구분만**이다.
  #    ⚠️ `--action="$action"`(등호 결합)은 허용하지 않는다: 도구의 argv 파서는 `--action` 다음 **인자**를
  #       값으로 읽는다(`a === "--action"`) → 등호 결합은 "알 수 없는 옵션"으로 exit 2다. 게이트가 이걸
  #       통과시키면 라이브에서만 죽는 형태를 GREEN으로 눈감아주는 셈이다(실측 확인).
  good="$(grep -oE -- '--action[[:space:]]+"?\$\{?action\}?"?' "$CODE" | wc -l | tr -d ' ')"
  [ "$good" -eq "$total" ] || {
    echo "approval gate bypass: --action 등장 ${total}회 중 ${good}회만 플래너의 \$action을 그대로 넘긴다 —"
    echo "  하드코딩(--action bump)이나 재해석은 금지다. autoDeploy:false 앱이 자동 배포될 수 있다."
    echo "  레인별로 title/body가 다르면 if/else로 **그것만** 가르고, --action \"\$action\"은 양쪽에 똑같이 넘긴다."
    grep -nE -- '--action' "$CODE"
    false
  }
}

# bats test_tags=regression
@test "the two lanes reach the executor with their own --action (hermetic run of the real bump step)" {
  # ★★ plan r6. 정적 grep 증인의 **거짓 GREEN 경로**를 닫는다.
  #   `action=$(… jq -r .action)`  ← 플래너에서 읽고 (증인 ② 통과)
  #   `action=bump`                 ← 읽은 뒤 덮어쓰고
  #   `--action "$action"`          ← verbatim으로 넘긴다 (증인 ④ 통과)
  # 이 호출부는 모든 문자열 증인을 통과하면서 propose-pr(autoDeploy:false) 후보를 bump 레인으로 흘린다.
  # 문자열이 아니라 **실행된 argv**를 봐야만 죽는다: 워크플로의 bump 스텝 본문을 그대로 꺼내, 두 레인이
  # 섞인 plan.json으로 stub 아래에서 **실제로 돌리고**, 실행기가 받은 --action을 앱별로 단언한다.
  setup_hermetic
  rc=$?
  [ "$rc" -ne 9 ] || {
    echo "hermetic harness: bump-poll.yaml에서 bump 스텝(.run에 bump-tag 포함)을 추출하지 못했다"
    echo "  선택자: .jobs.poll.steps[] | select(.run | test(\"bump-tag\"))"
    false
  }

  # ⓪ 하네스 자체의 증명 — 추출한 본문이 **실제로 두 후보를 돌았는가**. 이게 없으면 추출이 조용히
  #    깨졌을 때(빈 스크립트·early exit) "실행기 0회"라는 **엉뚱한 이유의 RED**가 진짜 RED로 위장한다.
  bt="$(bumptag_calls)"
  [ "$bt" -eq 2 ] || {
    echo "harness: 추출한 bump 스텝이 두 후보를 돌지 않았다(bump-tag 호출 ${bt}회, 기대 2회) —"
    echo "  yq 추출(.run) 또는 plan.json 픽스처 배선이 깨졌다. 이건 프로덕션 결함이 아니라 하네스 결함이다."
    cat "$BATS_TEST_TMPDIR/step.out"
    dump_calls
    false
  }

  # ① 실행기가 두 후보 **각각에** 대해 정확히 1회씩 호출됐는가(루프가 레인을 건너뛰지 않았는가).
  n="$(ensure_calls)"
  [ "$n" -eq 2 ] || {
    echo "duplicate bump PR: bump 스텝이 tools/ensure-bump-pr.ts를 후보당 1회 부르지 않았다(호출 ${n}회, 기대 2회) —"
    echo "  원격 변이(push·PR·auto-merge)는 전부 실행기를 통해야 한다. 지금은 워크플로가 직접 push/create한다."
    cat "$BATS_TEST_TMPDIR/step.out"
    dump_calls
    false
  }

  # ② ★ 봉인: **각 앱이 자기 레인 그대로** 실행기에 도달했는가. 읽은 뒤 덮어쓰기(action=bump)는
  #    여기서 trip-mate의 --action이 bump로 나오며 죽는다 — 정적 증인으로는 절대 잡히지 않는 우회다.
  page_lane="$(lane_of page)"
  [ "$page_lane" = "bump" ] || {
    echo "lane drift: autoDeploy 앱 page가 --action '${page_lane}'로 실행기에 갔다(기대 bump) — 자동 배포가 멈춘다"
    dump_calls; false
  }
  trip_lane="$(lane_of trip-mate)"
  [ "$trip_lane" = "propose-pr" ] || {
    echo "approval gate bypass: 승인 앱 trip-mate(autoDeploy:false)가 --action '${trip_lane}'로 실행기에 갔다(기대 propose-pr) —"
    echo "  플래너의 레인이 호출부에서 갈아치워졌다(읽은 뒤 덮어쓰기?). 승인 PR이 자동 배포된다."
    dump_calls; false
  }
}

@test "the planner's action is never reassigned after it is read (a post-read overwrite forges the lane)" {
  # plan r6의 정적 절반 — hermetic 증인(위)의 빠른 진단판. `action`은 **정확히 한 번** 대입되고,
  # 그 대입은 플래너의 `.action`이어야 한다. 두 번째 대입이 있으면 레인을 위조할 수 있다.
  # ⚠️ baseline에서도 GREEN이다(지금은 대입이 1회뿐) → regression 태그를 붙이지 않는다.
  #    fix가 레인을 넘기면서 덮어쓰기를 끼워 넣는 회귀를 잡는 게 목적이다.
  # `--action="$action"`(앞 글자가 `-`)·`"$action" = "bump"`(등호 앞 공백)·`jq -r .action`(등호 없음)은
  # 대입이 아니므로 세지 않는다 — 대입만 겨냥한다.
  assigns="$(grep -oE '(^|[[:space:];&|(])action=' "$CODE" | wc -l | tr -d ' ')"
  [ "$assigns" -eq 1 ] || {
    echo "lane forgery: bump 스텝에서 'action' 대입이 ${assigns}회다(기대 1회 — 플래너 읽기 단 한 번)."
    echo "  읽은 뒤 재대입(action=bump)하면 모든 정적 증인을 통과하면서 승인 레인이 자동 배포된다."
    grep -nE '(^|[[:space:];&|(])action=' "$CODE"
    false
  }
  run grep -nE 'action=\$\(.*jq -r [.]action' "$CODE"
  [ "$status" -eq 0 ] || {
    echo "lane provenance: 그 단 한 번의 대입이 플래너의 .action이 아니다 —"
    echo "  레인의 출처는 poll-ghcr(.bindings.json의 autoDeploy)여야 한다."
    false
  }
}

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

# bats test_tags=regression
@test "one app's fail-closed never starves the apps after it (each bump item is isolated, the run still goes red)" {
  # ★★ H-2. 옛 루프는 `jq … | while read`를 `bash -e` 아래서 돌렸다 → 한 앱이 fail-closed로 죽으면
  # (예: 증명되지 않은 head — 사람이 개입할 때까지 **영구히** 그 상태다) 파이프라인이 통째로 죽어
  # **그 뒤의 모든 앱이 매 주기 실행기에 도달조차 못 했다**. pr-sweeper가 이 네임스페이스에서 빠진 지금,
  # 이 루프의 생존성은 가용성이 아니라 **인가 회수의 전제조건**이다(낡은 무장은 방문해야만 회수된다).
  setup_hermetic
  rc=$?
  [ "$rc" -ne 9 ] || { echo "hermetic harness: bump 스텝 추출 실패"; false; }

  # plan의 **첫** 항목(page)의 실행기를 fail-closed 시킨다 — 그 뒤의 trip-mate가 굶는지가 질문이다.
  export STUB_FAIL_APP=page
  run run_step_rc "$STEP"
  unset STUB_FAIL_APP

  # ① 뒤따르는 앱이 **여전히 실행기에 도달했다**(굶기지 않았다).
  got="$(bumped_apps)"
  [ "$got" = "page trip-mate" ] || {
    echo "starvation: page의 fail-closed가 뒤따르는 앱을 굶겼다 — 실행기에 도달한 앱: '$got'(기대 'page trip-mate')"
    echo "  그 앱들은 **매 주기** 실행기에 도달하지 못한다(page의 fail-closed는 사람이 고칠 때까지 지속된다)"
    echo "  → 낡은 무장 회수도, DIRTY/BEHIND 수렴도, 중복 PR 억제도 전부 멈춘다."
    step_out; dump_calls; false
  }

  # ② 그래도 run은 **빨갛다** — 실패를 삼키면 telegram 알림이 안 가고 fail-closed가 조용히 묻힌다.
  [ "$status" -ne 0 ] || {
    echo "silent failure: 한 앱이 fail-closed로 죽었는데 스텝이 성공(exit 0)으로 끝났다 —"
    echo "  실패는 모아서 **맨 끝에서** 비-0으로 내야 한다(그래야 failure() telegram이 발화한다)."
    step_out; dump_calls; false
  }
}

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

  # ③ 그런데 그 실패가 bump 루프를 굶기지는 않는다 — bump 스텝은 그 파일/스텝에 **의존하지 않는다**
  #    (예전엔 reconcile이 실패 파일을 남기고 bump 스텝이 그걸 읽었다 → 두 경로가 한 job에 엮여 있었다).
  run run_step_rc "$STEP"
  [ "$status" -eq 0 ] || {
    echo "coupled failure: 회수 실패와 무관하게 bump 루프는 자기 앱들만 보고 판정해야 한다(exit $status)"
    step_out; dump_calls; false
  }
  bumped="$(bumped_apps)"
  [ "$bumped" = "page trip-mate" ] || {
    echo "over-correction: bump 루프가 후보 앱에 도달하지 못했다 — bump 도달: '$bumped'(기대 'page trip-mate')"
    step_out; dump_calls; false
  }
}

# ---------------------------------------------------------------------------
# 보존 — 재작성이 기존 계약(플래너·TOCTOU 가드·공유 auto-merge 스크립트)을 깨지 않았음을 확인(지금도 GREEN)
# ---------------------------------------------------------------------------

@test "bump-poll still plans with poll-ghcr and re-proves the from-tag via bump-tag --expect-current" {
  run grep -q "tools/poll-ghcr.ts" "$F"
  [ "$status" -eq 0 ]
  run grep -qE 'bump-tag\.ts .*--expect-current' "$F"
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

# bats test_tags=regression
@test "the commit the workflow EFFECTIVELY makes carries the identity and message the executor proves ownership with" {
  # ★ structure r5: 실행기는 force-push/무장 전에 "그 head 커밋이 우리 것인가"를 **정체성 + 메시지**로
  # 증명한다(tools/ensure-bump-pr.ts: WRITER_BOT_NAME / WRITER_BOT_EMAIL_RE / BUMP_COMMIT_MESSAGE).
  # 그 증명은 호출부가 실제로 심는 값과 **글자 그대로** 같아야 한다 — 드리프트하면 라이브에서 **정상 경로가
  # 통째로 fail-closed**된다(우리 브랜치를 우리가 못 알아본다 → adopt·rebuild 영구 실패 → 조용한 배포 정지).
  #
  # ★★ structure r6 R-24: 옛 증인은 `git config` / `git commit` **문자열이 파일에 있는지**만 grep했다.
  # 그건 죽은 텍스트 매칭이다 — 뒤따르는 **config 덮어쓰기**나 `git commit --amend`, 또는 env 오버라이드가
  # **원격에 실제로 올라가는 커밋**을 바꾸면서도 모든 grep 단언을 GREEN으로 통과시킨다.
  # 그래서 계약을 **실효값(effective)** 위로 옮긴다: 워크플로의 bump 스텝을 stub 아래에서 **실제로 실행**하고,
  #   · `git config`의 **마지막 쓰기**(last-write-wins)로 정해지는 실효 user.name/user.email
  #   · `--amend`까지 반영해 **HEAD가 실제로 갖게 될** 커밋 메시지
  # 를 관측해, **실행기 소스에서 파생한 기대값**과 비교한다(기대값도 테스트에 베껴 쓰지 않는다 — EXPECT_PY).
  setup_hermetic
  rc=$?
  [ "$rc" -ne 9 ] || {
    echo "hermetic harness: bump-poll.yaml에서 bump 스텝(.run에 bump-tag 포함)을 추출하지 못했다"
    false
  }

  # ⓪ 하네스 자체의 증명 — 추출한 본문이 실제로 두 후보를 돌았는가(빈 스크립트가 "커밋 0건"으로 위장하는 걸 막는다).
  bt="$(bumptag_calls)"
  [ "$bt" -eq 2 ] || {
    echo "harness: 추출한 bump 스텝이 두 후보를 돌지 않았다(bump-tag 호출 ${bt}회, 기대 2회)"
    cat "$BATS_TEST_TMPDIR/step.out"; dump_calls; false
  }

  # ① 실효 정체성 = 실행기의 WRITER_BOT_NAME / WRITER_BOT_EMAIL_RE(둘 다 실행기 소스에서 파생).
  exp_name="$(expect_of name)"
  [ -n "$exp_name" ] || { echo "expect: 실행기에서 writer bot 이름을 파생하지 못했다"; false; }
  got_name="$(effective_config user.name)"
  [ "$got_name" = "$exp_name" ] || {
    echo "ownership drift: 워크플로가 **실제로 심는** git user.name('$got_name')이 실행기의 기대('$exp_name')와 다르다 —"
    echo "  실행기는 이 정체성으로 '우리 커밋'을 증명한다. 드리프트하면 adopt/rebuild/무장이 영구 fail-closed된다."
    dump_effective; false
  }
  got_email="$(effective_config user.email)"
  run expect_of email "$got_email"
  [ "$status" -eq 0 ] || {
    echo "ownership drift: 워크플로가 **실제로 심는** git user.email('$got_email')이 실행기의 WRITER_BOT_EMAIL_RE와 맞지 않는다"
    dump_effective; false
  }

  # ② 실효 커밋 메시지 = 실행기의 BUMP_COMMIT_MESSAGE(app·tag를 채운 값). `--amend`·후속 커밋까지 반영된다.
  n="$(effective_commits)"
  [ "$n" -eq 2 ] || {
    echo "ownership drift: 후보 2건인데 HEAD가 갖게 될 커밋이 ${n}건이다(기대 2건 — 후보당 1커밋)"
    dump_effective; false
  }
  exp_page="$(expect_of msg page "$PAGE_TAG")"
  got_page="$(effective_commit 1)"
  [ "$got_page" = "$exp_page" ] || {
    echo "ownership drift: page 커밋의 **실효 메시지**가 실행기의 BUMP_COMMIT_MESSAGE와 다르다"
    echo "  기대: $exp_page"
    echo "  관측: $got_page"
    dump_effective; false
  }
  exp_trip="$(expect_of msg trip-mate "$TRIP_TAG")"
  got_trip="$(effective_commit 2)"
  [ "$got_trip" = "$exp_trip" ] || {
    echo "ownership drift: trip-mate 커밋의 **실효 메시지**가 실행기의 BUMP_COMMIT_MESSAGE와 다르다"
    echo "  기대: $exp_trip"
    echo "  관측: $got_trip"
    dump_effective; false
  }
}

# ⚠️ 하네스 자기증명이지만 **baseline에서 RED**다(회귀): 기대값을 실행기 소스에서 파생하는데(EXPECT_PY),
#    동결된 실행기엔 WRITER_BOT_NAME/BUMP_COMMIT_MESSAGE 자체가 없다(소유권 증명이 픽스의 산물이다) →
#    expect가 exit 2로 죽는다. "찾지 못했으니 통과"를 허용하지 않는 게 이 게이트의 설계다.
# bats test_tags=regression
@test "the effective-ownership witness has teeth (a later git config override and a --amend both flip it RED)" {
  # ★ 하네스 자기증명(R-24). 위 증인이 **실효값**을 본다는 걸 재현으로 못박는다 — 그리고 같은 변이가
  # **옛 문자열 grep 증인은 그대로 통과**한다는 것도 함께 보인다(그게 R-24가 지적한 사각지대다).
  # 이 증인이 없으면 stub이 조용히 last-write-wins/--amend를 놓쳐도(= 실효값이 항상 첫 값) 위 증인은
  # 여전히 GREEN이고, 아무것도 증명하지 못한다.
  setup_hermetic
  rc=$?
  [ "$rc" -ne 9 ] || { echo "hermetic harness: bump 스텝 추출 실패"; false; }
  exp_name="$(expect_of name)"

  # ── 변이 ①: **뒤따르는 config 덮어쓰기**. 라이브 git은 마지막 쓰기를 쓴다 → 커밋의 실제 정체성이 바뀐다.
  cp "$STEP" "$STEP.mut-config"
  printf '\ngit config user.name "drive-by"\n' >> "$STEP.mut-config"
  run_step "$STEP.mut-config"
  got_name="$(effective_config user.name)"
  [ "$got_name" = "drive-by" ] || {
    echo "toothless witness: 뒤따르는 'git config user.name' 덮어쓰기가 실효 정체성에 반영되지 않았다"
    echo "  stub이 last-write-wins를 기록하지 않으면 위 증인은 죽은 텍스트를 보는 것과 같다(관측: '$got_name')"
    dump_effective; false
  }
  [ "$got_name" != "$exp_name" ]
  # 그런데 **옛 문자열 증인은 여전히 통과한다** — 원래 줄이 파일에 그대로 남아 있기 때문이다.
  run grep -qF 'git config user.name "ukyi-homelab-writer[bot]"' "$STEP.mut-config"
  [ "$status" -eq 0 ] || {
    echo "harness: 변이본에 원래 config 줄이 남아 있지 않다 — 이 증인은 grep 사각지대를 재현하지 못한다"
    false
  }

  # ── 변이 ②: **--amend로 메시지 교체**. HEAD가 갖는 메시지가 바뀐다(커밋 수는 그대로).
  cp "$STEP" "$STEP.mut-amend"
  printf '\ngit commit --amend -m "chore: 전혀 다른 커밋"\n' >> "$STEP.mut-amend"
  run_step "$STEP.mut-amend"
  n="$(effective_commits)"
  [ "$n" -eq 2 ] || {
    echo "toothless witness: --amend가 커밋을 **추가**했다(교체가 아니라) — stub이 git 의미를 흉내내지 못한다"
    dump_effective; false
  }
  last="$(effective_commit 2)"
  [ "$last" = "chore: 전혀 다른 커밋" ] || {
    echo "toothless witness: --amend가 HEAD의 실효 커밋 메시지를 교체하지 않았다(관측: '$last')"
    dump_effective; false
  }
  exp_trip="$(expect_of msg trip-mate "$TRIP_TAG")"
  [ "$last" != "$exp_trip" ]
  # 여기서도 옛 문자열 증인은 통과한다(원래 `git commit -m …` 줄이 그대로다).
  run grep -qF 'git commit -m "chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)"' "$STEP.mut-amend"
  [ "$status" -eq 0 ]
}
