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
  # 전체-줄 주석을 **빈 줄로 치환**한 뷰(줄 번호는 보존) — 주석 속 설명 문구("…auto-merge-or-fail…",
  # "…bump-tag.ts가 재검증한다" 등)가 순서·금지 증인에 오탐되는 걸 막는다(test_mutation-dispatch의 선례).
  CODE="$BATS_TEST_TMPDIR/bump-poll.code.yaml"
  sed 's/^[[:space:]]*#.*$//' "$F" > "$CODE"
}

# 주석 제거 뷰에서 ERE가 처음 등장한 줄 번호(없으면 빈 문자열 → 단언이 [ -n ]로 잡는다).
first_line() { grep -nE "$1" "$CODE" | head -1 | cut -d: -f1; }

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

setup_hermetic() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export CALLS="$BATS_TEST_TMPDIR/calls.nul"   # NUL 구분 argv 원장(인자 경계 보존 — tools 스위트와 동형)
  : > "$CALLS"

  # 두 레인이 **섞인** plan — 이게 이 증인의 핵심이다. 한 레인만 돌리면 "둘 다 bump로 넘기는" 우회가 안 죽는다.
  PLAN="$BATS_TEST_TMPDIR/plan.json"
  cat > "$PLAN" <<'JSON'
[
  {"app":"page","action":"bump","writePath":"apps/page/deploy/prod/values.yaml",
   "current":{"tag":"sha-1111111111111111111111111111111111111111"},
   "candidate":{"tag":"sha-2222222222222222222222222222222222222222","digest":"sha256:aaaa"}},
  {"app":"trip-mate","action":"propose-pr","writePath":"apps/trip-mate/deploy/prod/values.yaml",
   "current":{"tag":"sha-3333333333333333333333333333333333333333"},
   "candidate":{"tag":"sha-4444444444444444444444444444444444444444","digest":"sha256:bbbb"}}
]
JSON

  # git/bun/gh stub — argv를 원장에 남기고 성공만 흉내낸다(실제 변이 0).
  for c in git bun gh; do
    cat > "$STUB/$c" <<STUBEOF
#!/bin/sh
{ printf '%s\0' "$c" "\$@"; printf '\036'; } >> "\$CALLS"
exit 0
STUBEOF
    chmod +x "$STUB/$c"
  done

  # 스텝 본문 추출 → /tmp/plan.json(하드코딩 경로)만 픽스처로 치환해 hermetic하게 만든다.
  STEP="$BATS_TEST_TMPDIR/bump-step.sh"
  extract_step > "$STEP.raw"
  [ -s "$STEP.raw" ] || return 9   # 추출 실패는 호출부에서 시끄럽게 잡는다
  sed "s#/tmp/plan.json#$PLAN#g" "$STEP.raw" > "$STEP"

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
dump_calls()    { echo "--- 스텝이 실행한 명령(원장) ---"; python3 "$LEDGER_PY" dump "$CALLS"; }

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
  branch_at="$(first_line 'git (switch -c|checkout -b)')"
  bump_at="$(first_line 'bun tools/bump-tag\.ts')"
  commit_at="$(first_line 'git commit')"
  ensure_at="$(first_line 'bun tools/ensure-bump-pr\.ts')"

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
@test "the commit identity and message the workflow writes match what the executor proves ownership with" {
  # ★ structure r5: 실행기는 force-push 직전에 "덮어쓸 커밋이 우리 것인가"를 **커밋의 정체성 + 메시지**로
  # 증명한다(tools/ensure-bump-pr.ts: WRITER_BOT_NAME / BUMP_COMMIT_MESSAGE). 그 증명은 호출부가 실제로
  # 심는 값과 **글자 그대로** 같아야 한다 — 드리프트하면 라이브에서 **정상 경로가 통째로 fail-closed**된다
  # (우리 브랜치를 우리가 못 알아본다 → adopt·rebuild 영구 실패 → 배포 정지). 두 파일을 여기서 묶는다.
  run grep -qF 'git config user.name "ukyi-homelab-writer[bot]"' "$CODE"
  [ "$status" -eq 0 ] || {
    echo "ownership drift: bump-poll.yaml의 git user.name이 실행기의 기대(ukyi-homelab-writer[bot])와 다르다"
    grep -nE 'git config user\.' "$CODE"; false
  }
  run grep -qE 'git config user\.email "[0-9]+\+ukyi-homelab-writer\[bot\]@users\.noreply\.github\.com"' "$CODE"
  [ "$status" -eq 0 ] || {
    echo "ownership drift: bump-poll.yaml의 git user.email이 실행기의 기대(<id>+ukyi-homelab-writer[bot]@users.noreply.github.com)와 다르다"
    grep -nE 'git config user\.' "$CODE"; false
  }
  # 커밋 메시지 패턴(app·tag가 박히는 자리까지) — 실행기의 BUMP_COMMIT_MESSAGE와 동형이어야 한다.
  run grep -qF 'git commit -m "chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)"' "$CODE"
  [ "$status" -eq 0 ] || {
    echo "ownership drift: bump-poll.yaml의 커밋 메시지가 실행기의 BUMP_COMMIT_MESSAGE와 다르다 —"
    echo "  실행기는 이 메시지로 '우리 커밋'을 증명한다. 드리프트하면 adopt/rebuild가 영구 fail-closed된다."
    grep -nE 'git commit -m' "$CODE"; false
  }
  run grep -qF 'BUMP_COMMIT_MESSAGE' "$ROOT/tools/ensure-bump-pr.ts"
  [ "$status" -eq 0 ]
}
