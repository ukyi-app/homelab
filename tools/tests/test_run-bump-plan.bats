#!/usr/bin/env bats
# run-bump-plan.ts(F-1 항목 러너)의 실행 테스트 — **진짜 git worktree fixture** + ensure-bump-pr **stub**.
# 러너의 유일 주장(worktree 공간 격리로 R-38·H-2 누출 소멸)을 실제 git으로 태운다. 원격(ensure-bump-pr)만 stub한다.
# stub은 cwd=worktree(HEAD=bump 커밋)에서 돌며 argv + 브랜치/author/커밋파일을 원장에 기록 → 러너의 per-item 결과를 증인화.
# ⚠️ 중간 단언은 `[ ]`만(bash 3.2 set -e가 `[[ ]]` 실패를 침묵 통과) · 중간 부정은 `run …; [ "$status" -ne 0 ]`.

DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"

seed_repo() {  # 2앱(page·trip-mate) values + digest-exporter를 가진 진짜 git repo(main)
  REPO="$(mktemp -d)"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name seed
  git -C "$REPO" config user.email seed@t
  for app in page trip-mate; do
    mkdir -p "$REPO/apps/$app/deploy/prod"
    printf 'image:\n  repo: ghcr.io/ukyi-app/%s\n  tag: sha-0000000\nkind: web\n' "$app" > "$REPO/apps/$app/deploy/prod/values.yaml"
  done
  mkdir -p "$REPO/platform/victoria-stack/prod"
  printf 'apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: digest-exporter\n          env:\n            - name: APPS\n              value: "page=ghcr.io/ukyi-app/page:sha-0000000 trip-mate=ghcr.io/ukyi-app/trip-mate:sha-0000000"\n' > "$REPO/platform/victoria-stack/prod/digest-exporter.yaml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
  # ensure-bump-pr stub: cwd=worktree(HEAD=bump 커밋). argv + 커밋 상태(브랜치·author·파일)를 원장에 기록.
  LEDGER="$REPO/ensure-ledger"; : > "$LEDGER"; export LEDGER
  cat > "$REPO/ensure-stub.sh" <<'EOF'
{ echo "=== call ==="
  echo "argv: $*"
  echo "branch: $(git rev-parse --abbrev-ref HEAD 2>&1)"
  echo "author: $(git log -1 --format='%an <%ae>' 2>&1)"
  echo "files: $(git show --name-only --format= HEAD 2>&1 | tr '\n' ' ')"
  echo "msg: $(git log -1 --format=%s 2>&1)"
  echo "ahead: $(git rev-list --count main..HEAD 2>&1)"
  # RECORD_PATH가 있을 때만 커밋된 **내용**까지 남긴다(베스포크 핀 증인 전용 — 다른 테스트의 원장 형태는 불변).
  [ -z "${RECORD_PATH:-}" ] || echo "content: $(git show "HEAD:$RECORD_PATH" 2>&1 | tr '\n' ' ')"
} >> "$LEDGER"
exit "${ENSURE_EXIT:-0}"
EOF
}

# 베스포크 핀 레인 픽스처(platform 컴포넌트): 디스크립터 + 인라인 핀 스칼라를 가진 deployment.yaml.
# apps 레인(values.yaml의 image.tag/digest 분리 키)과 달리 `<repo>:<tag>@<digest>` 단일 스칼라다.
OLD_DIG="sha256:1111111111111111111111111111111111111111111111111111111111111111"
seed_pin_component() {
  mkdir -p "$REPO/platform/files/prod"
  printf '{\n  "file": "deployment.yaml",\n  "path": ["spec","template","spec","containers",0,"image"],\n  "autoDeploy": true\n}\n' \
    > "$REPO/platform/files/prod/.image-pin.json"
  printf 'apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: files\n          image: ghcr.io/ukyi-app/files:sha-0000000@%s\n' \
    "$OLD_DIG" > "$REPO/platform/files/prod/deployment.yaml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m pin
}

teardown() { [ -n "${REPO:-}" ] && rm -rf "$REPO"; }

plan_json() {  # $1=page action, $2=trip-mate action, [$3=page current.tag override]
  # 와이어는 bump-plan 계약 형식이다(decodePlan이 러너의 입구다) — target 신원·reason·src 필수.
  local pc="${3:-sha-0000000}"
  cat > "$REPO/plan.json" <<EOF
[
 {"target":{"kind":"app","name":"page"},"action":"$1","reason":"","src":"ukyi-app/page","candidate":{"gitsha":"deadbee","tag":"sha-deadbee","digest":"$DIG"},"current":{"tag":"$pc"},"writePath":"apps/page/deploy/prod/values.yaml"},
 {"target":{"kind":"app","name":"trip-mate"},"action":"$2","reason":"","src":"ukyi-app/trip-mate","candidate":{"gitsha":"feedbee","tag":"sha-feedbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/trip-mate/deploy/prod/values.yaml"}
]
EOF
}

run_runner() {  # $1=ENSURE_EXIT(기본 0) · RECORD_PATH(선택)는 환경에서 그대로 전달
  run env ENSURE_EXIT="${1:-0}" LEDGER="$REPO/ensure-ledger" RECORD_PATH="${RECORD_PATH:-}" \
    bun tools/run-bump-plan.ts --plan "$REPO/plan.json" --repo-root "$REPO" \
      --ensure-bin bash --ensure-script "$REPO/ensure-stub.sh"
}

# 원장에서 그 target의 ensure 호출 **블록 하나**(argv 줄 ~ 다음 '=== call ===' 전까지)를 뽑는다 —
# `grep -A<n>` 창은 원장에 필드가 늘면 조용히 어긋난다(다음 블록으로 새거나 잘린다).
block_for() { sed -n "/^argv: --kind [a-z]* --name $1 /,/^=== call ===$/p" "$LEDGER"; }

# ── 소유권 기대값은 **실행기·계약 module 소스에서 파생한다**(테스트에 베껴 쓰기 금지) ──────────────
# 실행기(tools/ensure-bump-pr.ts)는 force-push·무장 전에 "이 head가 우리 커밋인가"를 **정체성 + 커밋
# 메시지**로 증명한다(proveOurCommit). 그 기대는 러너가 실제로 심는 값과 **글자 그대로** 같아야 한다 —
# 드리프트하면 라이브에서 우리 브랜치를 우리가 못 알아봐 adopt/rebuild/무장이 **영구 fail-closed**된다
# (조용한 배포 정지). 기대값을 여기 하드코딩하면 양쪽이 함께 드리프트해도 GREEN인 세 번째 진실이 생긴다.
# 커밋 문구 계약은 08부터 module(tools/lib/bump-plan.ts commitMessage) 한 곳이 소유한다 — 기대도 거기서
# 파생한다. 형태(DEFAULT_WRITER/WRITER_BOT_NAME/WRITER_BOT_EMAIL_RE/commitMessage)를 못 찾으면 **exit 2로 죽는다**.
expect_of() {
  local root py
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  py="$BATS_TEST_TMPDIR/expect.py"
  if [ ! -f "$py" ]; then
    cat > "$py" <<'PY'
import re
import sys

exec_src = open(sys.argv[1], encoding="utf-8").read()
plan_src = open(sys.argv[2], encoding="utf-8").read()


def need(src, pat, what):
    m = re.search(pat, src)
    if not m:
        sys.stderr.write(
            "expect: 소스에서 %s를 찾지 못했다(형태 드리프트) — 소유권 기대값을 모르면 통과시키지 않는다\n" % what,
        )
        sys.exit(2)
    return m


writer = need(exec_src, r'DEFAULT_WRITER\s*=\s*"([^"]+)"', "DEFAULT_WRITER").group(1)
name_tmpl = need(exec_src, r"WRITER_BOT_NAME\s*=\s*`([^`]*)`", "WRITER_BOT_NAME").group(1)
email_tmpl = need(exec_src, r"WRITER_BOT_EMAIL_RE\s*=\s*new RegExp\(`([^`]*)`\)", "WRITER_BOT_EMAIL_RE").group(1)
msg_tmpl = need(
    plan_src,
    r"function commitMessage\([^)]*\)[^{]*\{[^`]*return\s*`([^`]*)`",
    "commitMessage의 커밋 메시지 템플릿(bump-plan)",
).group(1)

bot_name = name_tmpl.replace("${normalizeLogin(args.writer)}", writer)
# TS 소스의 `\\d`는 정규식 `\d`다 → 언이스케이프 후 escapeRe(WRITER_BOT_NAME)을 채운다.
email_re = email_tmpl.replace("\\\\", "\\").replace("${escapeRe(WRITER_BOT_NAME)}", re.escape(bot_name))

mode = sys.argv[3]
if mode == "ident":  # argv[4] = 관측된 "name <email>"(git log %an <%ae>)
    m = re.match(r"^(.*) <(.*)>$", sys.argv[4])
    if not m:
        sys.stderr.write("ident 형식 불량: %s\n" % sys.argv[4])
        sys.exit(1)
    sys.exit(0 if m.group(1) == bot_name and re.match(email_re, m.group(2)) else 1)
elif mode == "msg":  # argv[4] = target name, argv[5] = tag
    print(msg_tmpl.replace("${target.name}", sys.argv[4]).replace("${tag}", sys.argv[5]))
else:
    sys.exit(2)
PY
  fi
  python3 "$py" "$root/tools/ensure-bump-pr.ts" "$root/tools/lib/bump-plan.ts" "$@"
}

# 한 항목의 커밋이 실행기의 소유권 증명과 **실효로** 일치하는가(정체성·메시지·main 대비 1커밋).
assert_ownership() {  # $1=app $2=tag
  local blk got_ident exp_msg got_msg ahead
  blk="$(block_for "$1")"
  got_ident="$(sed -n 's/^author: //p' <<<"$blk")"
  expect_of ident "$got_ident" || {
    echo "ownership drift: $1 커밋의 실효 정체성('$got_ident')이 실행기의 WRITER_BOT_NAME/EMAIL_RE와 다르다 —"
    echo "  실행기는 이 정체성으로 '우리 커밋'을 증명한다. 드리프트하면 adopt/rebuild/무장이 영구 fail-closed된다."
    return 1
  }
  exp_msg="$(expect_of msg "$1" "$2")"
  got_msg="$(sed -n 's/^msg: //p' <<<"$blk")"
  [ "$got_msg" = "$exp_msg" ] || {
    echo "ownership drift: $1 커밋의 실효 메시지가 계약 module의 commitMessage와 다르다"
    echo "  기대: $exp_msg"
    echo "  관측: $got_msg"
    return 1
  }
  ahead="$(sed -n 's/^ahead: //p' <<<"$blk")"
  [ "$ahead" = "1" ] || {
    echo "ownership drift: $1 브랜치가 main보다 ${ahead}커밋 앞선다(기대 1 — 항목당 정확히 1커밋)"
    return 1
  }
}

no_leftover() {  # 정리 teeth: main worktree만 남고 bump-poll 로컬 브랜치 0
  run bash -c "git -C '$REPO' worktree list | wc -l | tr -d ' '"
  [ "$output" = "1" ]
  run bash -c "git -C '$REPO' branch --list 'bump-poll/*'"
  [ -z "$output" ]
}

@test "each item commits its own writePath+digest-exporter with writer identity, on its own branch, and calls ensure with the planner's lane verbatim" {
  seed_repo; plan_json bump propose-pr; run_runner 0
  [ "$status" -eq 0 ]
  # page: bump 레인 · kind 인코딩 브랜치 · writer identity · 자기 파일만 (grep -qF 중간 단언 = ERR-trap이 실패를 잡는다)
  page="$(grep -A4 'argv: --kind app --name page --tag sha-deadbee' "$LEDGER")"
  grep -qF -- "--action bump" <<<"$page"
  grep -qF "branch: bump-poll/app/page-sha-deadbee" <<<"$page"
  grep -qF "ukyi-homelab-writer[bot]" <<<"$page"
  grep -qF "apps/page/deploy/prod/values.yaml" <<<"$page"
  grep -qF "platform/victoria-stack/prod/digest-exporter.yaml" <<<"$page"
  # trip-mate: propose-pr 레인 verbatim(재해석 없음)
  tm="$(grep -A1 'argv: --kind app --name trip-mate' "$LEDGER")"
  grep -qF -- "--action propose-pr" <<<"$tm"
  no_leftover
}

@test "the commit the runner EFFECTIVELY makes carries the identity and message the executor proves ownership with" {
  # ★ 이 계약은 워크플로 호출부에서 러너로 **이관**된 것이다(옛 tests/gates/test_bump-poll-callsite.bats의
  # effective-ownership 증인). 옛 증인은 워크플로 셸 본문을 git **stub** 아래 돌려 last-write-wins·--amend
  # 의미를 흉내내야 했다(그래서 stub이 그 의미를 정말 흉내내는지 증명하는 이빨 증인이 또 필요했다).
  # 러너는 커밋마다 `git -c user.name/user.email`로 신원을 **명시**하고, 여기선 **진짜 git**이 만든 커밋
  # 오브젝트를 그대로 읽는다 — 흉내낼 의미가 없으니 실효값이 곧 관측값이다(옛 이빨 증인의 존재 이유가 소멸).
  # 남은 계약은 하나: 그 실효값이 **실행기 소스에서 파생한 기대**와 같은가.
  seed_repo; plan_json bump propose-pr; run_runner 0
  [ "$status" -eq 0 ]
  assert_ownership page sha-deadbee
  assert_ownership trip-mate sha-feedbee
}

@test "the base main worktree is left untouched — updates happen only inside each item's worktree" {
  # ★ 옛 호출부 순서 계약의 첫 절(브랜치 생성 → 태그 갱신)의 **실행판**이다. 갱신이 브랜치를 떼기 전에
  # 일어나면 main 위에서 값이 바뀐다 — 그러면 main 작업트리가 더러워지고, 다음 주기의 plan(=live 값)이
  # 오염된 상태를 스냅샷으로 잡는다. 공간 격리의 정의상 그럴 수 없어야 한다.
  seed_repo
  before="$(git -C "$REPO" rev-parse main)"
  plan_json bump propose-pr; run_runner 0
  [ "$status" -eq 0 ]
  run bash -c "git -C '$REPO' rev-parse main"          # ① main tip 불변(러너는 main에 커밋하지 않는다)
  [ "$output" = "$before" ]
  run bash -c "git -C '$REPO' status --porcelain --untracked-files=no"  # ② tracked 변경 0
  [ -z "$output" ]
  grep -q 'sha-0000000' "$REPO/apps/page/deploy/prod/values.yaml"       # ③ 값도 옛 tag 그대로
  grep -q 'sha-0000000' "$REPO/apps/trip-mate/deploy/prod/values.yaml"
  no_leftover
}

@test "H-2: an item that fails AFTER git add leaves no residue in the next item's commit (spatial isolation contains staged residue)" {
  seed_repo
  # pre-commit 훅: staged에 apps/page/가 있으면 실패(= page는 git add 후 commit에서 실패, staged 잔여 남김)
  printf '#!/usr/bin/env bash\ngit diff --cached --name-only | grep -q "^apps/page/" && { echo "hook: page commit 차단"; exit 1; }\nexit 0\n' > "$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  plan_json bump bump; run_runner 0
  [ "$status" -ne 0 ]                       # page 실패 → run 비-0
  run grep -c "argv: --kind app --name page" "$LEDGER"  # page는 commit 실패로 ensure 미도달
  [ "$output" = "0" ]
  # trip-mate의 commit은 자기 파일만 — page의 staged writePath·digest-exporter 잔여가 **누출되지 않음**(격리 teeth)
  tm="$(grep -A4 'argv: --kind app --name trip-mate' "$LEDGER")"
  grep -qF "apps/trip-mate/deploy/prod/values.yaml" <<<"$tm"
  run grep -qF "apps/page/" <<<"$tm"        # 누출됐다면 여기서 status 0 → 아래 -ne 0이 RED(격리 teeth)
  [ "$status" -ne 0 ]
  no_leftover                               # 실패 경로에서도 worktree/브랜치 누적 0
}

@test "an item whose bump-tag fails BEFORE staging is fail-closed and never reaches ensure; other items continue" {
  seed_repo; plan_json bump bump sha-WRONGXX   # page expect-current 불일치 → bump-tag fail-closed(add 전)
  run_runner 0
  [ "$status" -ne 0 ]
  run grep -c "argv: --kind app --name page" "$LEDGER"     # 순서 계약: bump-tag 실패 시 ensure 미호출
  [ "$output" = "0" ]
  run grep -c "argv: --kind app --name trip-mate" "$LEDGER" # 나머지는 계속(굶김 없음)
  [ "$output" = "1" ]
  no_leftover
}

@test "a stubbed ensure-bump-pr failure is aggregated fail-closed (run red) without starving the other item" {
  seed_repo; plan_json bump bump; run_runner 1   # 모든 ensure 실패
  [ "$status" -ne 0 ]
  run grep -c "=== call ===" "$LEDGER"           # 두 항목 모두 ensure까지 도달(굶김 없음)
  [ "$output" = "2" ]
  no_leftover
}

@test "the runner performs no direct remote mutation — it runs with no git remote and still succeeds (push/PR is ensure-bump-pr's alone)" {
  seed_repo   # fixture에 origin 없음 — 러너가 직접 push하면 실패했을 것
  plan_json bump bump; run_runner 0
  [ "$status" -eq 0 ]   # ensure(stub)만이 원격 경로 → 러너 직접 push 0
  no_leftover
}

@test "a bespoke pin item forwards --pin to bump-tag and commits the rewritten inline pin (both lanes in one plan)" {
  # 러너는 플래너의 `.pin`(디스크립터 경로) 유무로 레인을 가른다 — apps는 values.yaml의 분리 키,
  # 베스포크는 deployment.yaml의 인라인 핀 스칼라다. `--pin`을 넘기지 않으면 bump-tag가 apps 모드로
  # 떨어져 `apps/files/…/values.yaml`(존재하지 않음)을 읽고 죽는다 → 이 증인이 RED가 된다(이빨).
  # 디스크립터 경로는 **레포 상대**라 bump-tag가 --repo-root(=격리 worktree) 기준으로 풀어야 맞는다.
  seed_repo; seed_pin_component
  cat > "$REPO/plan.json" <<EOF
[
 {"target":{"kind":"app","name":"page"},"action":"bump","reason":"","src":"ukyi-app/page","candidate":{"gitsha":"deadbee","tag":"sha-deadbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/page/deploy/prod/values.yaml"},
 {"target":{"kind":"bespoke","name":"files"},"action":"bump","reason":"","src":"ukyi-app/files","candidate":{"gitsha":"feedbee","tag":"sha-feedbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"platform/files/prod/deployment.yaml","pin":"platform/files/prod/.image-pin.json"}
]
EOF
  RECORD_PATH=platform/files/prod/deployment.yaml run_runner 0
  [ "$status" -eq 0 ]
  files="$(block_for files)"
  grep -qF "branch: bump-poll/bespoke/files-sha-feedbee" <<<"$files"
  grep -qF "platform/files/prod/deployment.yaml" <<<"$files"
  # ★ 커밋된 **내용**: 인라인 핀 스칼라가 제자리에서 새 tag+digest로 교체됐다(핀 모드가 실제로 돌았다).
  grep -qF "ghcr.io/ukyi-app/files:sha-feedbee@$DIG" <<<"$files"
  # apps 레인은 같은 plan 안에서도 자기 경로만 커밋한다(레인 분기가 서로를 오염시키지 않는다).
  page="$(block_for page)"
  grep -qF "apps/page/deploy/prod/values.yaml" <<<"$page"
  run grep -qF "platform/files/prod/deployment.yaml" <<<"$page"
  [ "$status" -ne 0 ]
  no_leftover
}

@test "only bump/propose-pr items are processed (noop/refuse are filtered out)" {
  # 비-Lane 항목(noop/refuse)은 적법한 plan이지만 러너의 일이 아니다. 미지 action(구 'skip' 같은)은
  # 필터가 아니라 decodePlan의 red다 — 아래 별도 증인이 그 계약을 고정한다.
  seed_repo
  cat > "$REPO/plan.json" <<EOF
[ {"target":{"kind":"app","name":"page"},"action":"noop","reason":"배포 SHA == main tip","current":{"tag":"sha-0000000"},"candidate":null},
  {"target":{"kind":"app","name":"trip-mate"},"action":"bump","reason":"","src":"ukyi-app/trip-mate","candidate":{"gitsha":"feedbee","tag":"sha-feedbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/trip-mate/deploy/prod/values.yaml"} ]
EOF
  run_runner 0
  [ "$status" -eq 0 ]
  run grep -c "argv: --kind app --name page" "$LEDGER"     # noop은 처리 안 함
  [ "$output" = "0" ]
  run grep -c "argv: --kind app --name trip-mate" "$LEDGER"
  [ "$output" = "1" ]
}

@test "a target name failing APP_NAME_RE is aggregated fail-closed (red), never a silent skip" {
  # decodePlan은 이름을 '빈 문자열 아님'까지만 잰다 — 러너의 APP_NAME_RE가 유일한 이름 정책 게이트다.
  # 불합격이 조용한 skip이면 그 항목은 아무도 처리하지 않는데 run은 초록이다(vacuous green).
  seed_repo
  cat > "$REPO/plan.json" <<EOF
[ {"target":{"kind":"app","name":"Bad_Name"},"action":"bump","reason":"","src":"ukyi-app/bad","candidate":{"gitsha":"deadbee","tag":"sha-deadbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/bad/deploy/prod/values.yaml"},
  {"target":{"kind":"app","name":"trip-mate"},"action":"bump","reason":"","src":"ukyi-app/trip-mate","candidate":{"gitsha":"feedbee","tag":"sha-feedbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/trip-mate/deploy/prod/values.yaml"} ]
EOF
  run_runner 0
  [ "$status" -ne 0 ]                                       # run은 빨갛다(fail-closed 집계)
  run grep -c "argv: --kind app --name Bad_Name" "$LEDGER"  # 불합격 항목은 처리되지 않는다
  [ "$output" = "0" ]
  run grep -c "argv: --kind app --name trip-mate" "$LEDGER" # 나머지 항목은 굶지 않는다
  [ "$output" = "1" ]
  no_leftover
}

@test "a malformed plan (unknown action or missing target) dies at decode before any worktree is made (fail-closed)" {
  # 러너의 입구가 decodePlan이다 — 미지 action·신원 부재가 조용한 skip이 되면 그 항목은 아무도 처리하지
  # 않는데 run은 초록이다(회수·배포 모두 굶는 vacuous green). exit 2 + worktree 0이어야 한다.
  seed_repo
  cat > "$REPO/plan.json" <<EOF
[ {"target":{"kind":"app","name":"page"},"action":"yolo","reason":"","current":null,"candidate":null} ]
EOF
  run_runner 0
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "yolo"
  cat > "$REPO/plan.json" <<EOF
[ {"app":"page","action":"bump","reason":"","candidate":{"gitsha":"deadbee","tag":"sha-deadbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/page/deploy/prod/values.yaml"} ]
EOF
  run_runner 0
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "target"
  run grep -c "=== call ===" "$LEDGER"   # ensure 미도달(디코드가 입구다)
  [ "$output" = "0" ]
  no_leftover
}

@test "the seam exec ledger records the runner's per-item call sequence in-process (d6 observation adapter)" {
  # AC(14): 한 경로의 호출 시퀀스가 인-프로세스 원장으로 검증된다 — PATH stub 없이, seam의
  # HOMELAB_EXEC_LEDGER(JSONL)만으로 러너가 무엇을 어떤 argv로 실행했는지 본다.
  seed_repo; plan_json bump propose-pr
  L="$BATS_TEST_TMPDIR/exec-ledger.jsonl"
  export HOMELAB_EXEC_LEDGER="$L"   # run_runner의 env가 상속한다(호출 형태 복제 금지)
  run_runner 0
  unset HOMELAB_EXEC_LEDGER
  [ "$status" -eq 0 ]
  [ -f "$L" ]
  # ① 조각의 실재 — 격리 worktree 생성 → bump-tag(bun, argv로 결속) → 스테이징 → ensure(bash) → 정리.
  grep -qF '"cmd":"git","args":["worktree","add"' "$L"
  run grep -cE '"cmd":"bun","args":\["[^"]*bump-tag\.ts"' "$L"   # bun 호출이 곧 bump-tag임을 argv로 못박는다
  [ "$output" = "2" ]
  grep -qF '"cmd":"git","args":["add"' "$L"
  grep -qF '"cmd":"bash"' "$L"
  grep -qF '"cmd":"git","args":["worktree","remove"' "$L"
  grep -qF '"cmd":"git","args":["branch","-D"' "$L"
  # ② 순서 — 첫 worktree add가 어떤 정리(branch -D)보다도 앞이고, 마지막 정리가 마지막 add 뒤다.
  first_add="$(grep -nF '"cmd":"git","args":["worktree","add"' "$L" | head -1 | cut -d: -f1)"
  first_del="$(grep -nF '"cmd":"git","args":["branch","-D"' "$L" | head -1 | cut -d: -f1)"
  last_add="$(grep -nF '"cmd":"git","args":["worktree","add"' "$L" | tail -1 | cut -d: -f1)"
  last_del="$(grep -nF '"cmd":"git","args":["branch","-D"' "$L" | tail -1 | cut -d: -f1)"
  [ -n "$first_add" ]; [ -n "$first_del" ]
  [ "$first_add" -lt "$first_del" ]
  [ "$last_add" -lt "$last_del" ]
  # ③ 개수 — 항목당 git 5회(worktree add·add·commit·worktree remove·branch -D) × 2항목 = 정확히 10.
  n="$(grep -cF '"cmd":"git"' "$L")"
  [ "$n" -eq 10 ]
}
