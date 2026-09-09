#!/usr/bin/env bats
# gh 스텁의 jq 필터 의미론 계약 — 이 레포의 CLI 테스트는 전부 하나의 gh 스텁 위에 서는데, 그 스텁은
# jq를 **적용한 뒤의** 형상을 되돌려준다(픽스처는 손으로 접어 적은 결과다). 그래서 필터가 실제
# GitHub 페이로드에 대해 무엇을 하는지는 어떤 테스트도 밟지 않았다. 두 축으로 그 공백을 메운다:
#   (a) 텍스트 등식 — lib 소스의 필터 리터럴 == 스텁 case 패턴(정확 일치). 어느 쪽이 드리프트하면
#       계약 밖 호출이 되어 스텁이 exit 3으로 죽는다. 표기를 재는 축이지 의미론을 재는 축이 아니다.
#   (b) raw 형상 — 접힘이 있는 네 필터(`.workflow_runs[]` 언랩 · `head: .head.ref` 중첩 ·
#       `auto_merge != null` · 레인 PR의 `head_sha: .head.sha` 중첩)에 대해 **손으로 적은 원시
#       페이로드**(fixtures/homelab/gh-raw/)에 스텁이 실제 jq를 돌린다. GitHub 필드 리네임이 여기서
#       red가 된다. 레인 PR 레그는 그 접힘이 **다음 질의의 좌표**라 특히 조용했다 — 접힌
#       픽스처에서는 필드가 사라져도 아무 단언이 밟지 않는다.
# 라이브 녹화 + 신선도 게이트는 채택하지 않았다 — 인증 부재 venue에서 시한폭탄 red가 되고 해제
# 수단이 owner-local gh뿐이다. 라이브 의존은 이 파일에 0건이다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_gh_stub
}

@test "the nine composite jq filters are shared verbatim by the lib sources and the gh stub (floor 9)" {
  # 구분자는 '%' — 필터 본문에 '|'가 들어 있어 파이프를 구분자로 쓸 수 없다.
  # 4번째 칸(lit)은 **소스에 실린 리터럴**이다: 목록형 레인 필터는 lane-pr.ts가
  # `[.[] | ${LANE_PR_FIELDS}]` 템플릿으로 **합성**해서 전문이 소스에 없다(투영 SSOT는 필드 집합
  # 쪽이다). 비면 filter를 그대로 쓴다 — 합성이 아닌 다섯 행은 종전과 같은 등식이다.
  n=0
  while IFS='%' read -r src path filter lit; do
    [ -n "$src" ] || continue
    n=$((n+1))
    # ① lib 소스가 그 필터 리터럴을 실제로 담는다(엔진이 필터를 바꾸면 이 줄이 먼저 red).
    grep -qF -- "${lit:-$filter}" "$src"
    # ② 스텁 case가 그 필터를 계약 안으로 받는다.
    run "$STUB/gh" api "$path" --jq "$filter"
    [ "$status" -eq 0 ]
    # ③ 한 글자 드리프트는 계약 밖 호출이다 — 종전 `--jq "*` 글롭이면 조용히 통과했다.
    run "$STUB/gh" api "$path" --jq "${filter}x"
    [ "$status" -eq 3 ]
  done <<'EOF'
tools/lib/mutation.ts%repos/ukyi-app/homelab/actions/workflows/create-database.yaml/runs?per_page=20%[.workflow_runs[] | {id, name, status, conclusion, html_url}]
tools/lib/mutation.ts%repos/ukyi-app/homelab/actions/workflows/create-database.yaml/runs?per_page=20%[.workflow_runs[] | {id, name}]
tools/lib/mutation.ts%repos/ukyi-app/homelab/actions/runs/501/jobs%[.jobs[] | select(.conclusion == "failure") | .name]
tools/lib/mutation.ts%repos/ukyi-app/homelab/commits/c0ffee1/check-runs?check_name=gate&filter=all&per_page=100%[.check_runs[] | {id, name, status, conclusion, html_url, started_at}]
tools/lib/lane-pr.ts%repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501%[.[] | {number, html_url, merged_at, merge_commit_sha, state, head_sha: .head.sha}]%{number, html_url, merged_at, merge_commit_sha, state, head_sha: .head.sha}
tools/lib/lane-pr.ts%repos/ukyi-app/homelab/pulls/21%{number, html_url, merged_at, merge_commit_sha, state, head_sha: .head.sha}
tools/lib/status.ts%repos/ukyi-app/page/actions/runs?per_page=3%[.workflow_runs[] | {name, status, conclusion, head_sha, head_branch, event, html_url}]
tools/lib/status.ts%repos/ukyi-app/homelab/pulls?state=open&per_page=100%[.[] | {number, title, head: .head.ref, html_url, auto_merge: (.auto_merge != null)}]
tools/lib/status.ts%repos/ukyi-app/homelab/pulls/7%{number, state, merged, merge_commit_sha, title, head_ref: .head.ref, head_sha: .head.sha, auto_merge: (.auto_merge != null), html_url}
EOF
  # 비공허 바닥값 — 아홉 줄이 실제로 돌았다(heredoc이 비면 위 전칭이 항진이다).
  [ "$n" -eq 9 ]
  # 변이 엔진의 run 목록 필터는 다섯 레인(create-app·teardown-app·update-secrets·create-cache·
  # create-database)이 **한 텍스트를 공유**한다. 위 루프는 대표 하나만 밟으므로, 나머지 넷이 함께
  # 좁혀졌는지는 이 등식이 잰다(부분 narrowing = 남은 글롭이 드리프트를 삼킨다).
  [ "$(grep -cF '[.workflow_runs[] | {id, name, status, conclusion, html_url}]' tools/tests/helpers/cli_stub.bash)" = "5" ]
  # 신선도 스냅샷의 투영은 **경로만 글롭인 한 케이스**가 5레인을 다 받는다 — 응답이 레인
  # 무관(기본 공집합)이라 사본을 다섯 벌 두면 드리프트 표면만 늘어난다. 그래서 여기는 1건이다.
  [ "$(grep -cF '[.workflow_runs[] | {id, name}]' tools/tests/helpers/cli_stub.bash)" = "1" ]
}

@test "the workflow_runs unwrap and the head.ref nesting are witnessed against raw payloads (real jq)" {
  make_app_fixture page true
  # 라이브 계층은 이 축과 무관하다 — KUBECONFIG 없이 돌려 GitHub 계층만 남긴다(omitted:["live"]).
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" STUB_GH_RAW=1 \
    "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.runs | length')" = "2" ]
  [ "$(echo "$output" | jq -r '.result.runs[0].headSha')" = "c0ffee1c0ffee1c0ffee1c0ffee1c0ffee1c0ffe" ]
  # headBranch·event 두 필드도 원시 페이로드에서 접힌다 — '핀이 최신 main 빌드인가'의 원료다.
  [ "$(echo "$output" | jq -r '.result.runs[0].headBranch')" = "main" ]
  [ "$(echo "$output" | jq -r '.result.runs[0].event')" = "push" ]
  # raw의 `"conclusion": null`이 키 부재로 접힌다(계약 "값 없음 = 키 부재").
  [ "$(echo "$output" | jq -r '.result.runs[1] | has("conclusion")')" = "false" ]
  # head.ref 중첩이 실제로 접혀야 레인 필터가 값을 읽는다 — 형제 앱 'pages'(#9)만 배제된다.
  [ "$(echo "$output" | jq -r '[.result.openPrs[].number] | sort | join(",")')" = "7,8" ]

  MUT="$BATS_TEST_TMPDIR/gh-raw-mut"; mkdir -p "$MUT"
  cp "$GH_RAW_DIR/pulls-open.json" "$GH_RAW_DIR/pull.json" "$MUT/"
  # ① 래퍼 리네임 — `.workflow_runs[]`가 null을 훑어 jq가 죽고 GitHub 계층이 fail-loud가 된다.
  sed 's/"workflow_runs"/"workflow_run"/' "$GH_RAW_DIR/workflow-runs.json" > "$MUT/workflow-runs.json"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" STUB_GH_RAW=1 GH_RAW_DIR="$MUT" \
    "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  # ② head.ref 리네임 — 접힌 head가 null이 되어 레인 필터가 아무것도 고르지 못한다.
  cp "$GH_RAW_DIR/workflow-runs.json" "$MUT/workflow-runs.json"
  sed 's/"ref":/"branch_name":/' "$GH_RAW_DIR/pulls-open.json" > "$MUT/pulls-open.json"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" STUB_GH_RAW=1 GH_RAW_DIR="$MUT" \
    "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.openPrs | length')" = "0" ]
}

@test "auto_merge folds an object to true and null to false in the same raw response" {
  make_app_fixture page true
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" STUB_GH_RAW=1 \
    "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  # 실제 API는 object|null인데 접힌 픽스처는 그 접힘의 **결과**(불리언)를 손으로 적은 것이다.
  # raw에는 양쪽 형상이 한 응답 안에 있다: #7 = 오브젝트(활성), #8 = null.
  [ "$(echo "$output" | jq -r '.result.openPrs[] | select(.number==7) | .autoMerge')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.openPrs[] | select(.number==8) | .autoMerge')" = "false" ]
  # 핸들 모드는 같은 접힘을 **다른 필터 텍스트**로 한다(중첩 head.ref·head.sha도 함께).
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" STUB_GH_RAW=1 \
    "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/pull/7" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.pr.autoMerge')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.pr.headRef')" = "bump-poll/page-sha-abcdef1" ]
  [ "$(echo "$output" | jq -r '.result.pr.headSha')" = "beef123beef123beef123beef123beef123beef1" ]
  [ "$(echo "$output" | jq -r '.result.pr | has("mergeCommitSha")')" = "false" ]
  # 필드 리네임 뮤테이션 — auto_merge가 사라지면 활성 PR도 false로 접힌다(픽스처가 실제로 실린다).
  MUT="$BATS_TEST_TMPDIR/gh-raw-mut"; mkdir -p "$MUT"
  cp "$GH_RAW_DIR"/*.json "$MUT/"
  sed 's/"auto_merge":/"automerge":/' "$GH_RAW_DIR/pull.json" > "$MUT/pull.json"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" STUB_GH_RAW=1 GH_RAW_DIR="$MUT" \
    "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/pull/7" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.pr.autoMerge')" = "false" ]
}

@test "the raw lane dies loudly (exit 127) when jq is missing from the stub PATH" {
  # 스텁 PATH는 **대체**라 jq도 심링크로 들여온 것이다. 그 심링크가 없으면 raw 레인은 조용히
  # 접힌 픽스처로 폴백하는 게 아니라 exec 실패(127)로 죽어야 한다 — 폴백은 이 파일 전체를
  # vacuous green으로 만든다(픽스처가 이미 접혀 있으니 모든 단언이 그대로 통과한다).
  F='[.workflow_runs[] | {name, status, conclusion, head_sha, head_branch, event, html_url}]'
  run env PATH="$STUB" STUB_GH_RAW=1 "$STUB/gh" api "repos/ukyi-app/page/actions/runs?per_page=3" --jq "$F"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r 'length')" = "2" ]
  rm "$STUB/jq"
  # `run -127`은 종료코드를 단언하면서 bats의 BW01 경고(127 = command not found)를 잠재운다 —
  # 여기서는 127이 결함이 아니라 **계약**이다.
  run -127 env PATH="$STUB" STUB_GH_RAW=1 "$STUB/gh" api "repos/ukyi-app/page/actions/runs?per_page=3" --jq "$F"
  [ "$status" -eq 127 ]
}

@test "the lane PR head.sha nesting is witnessed against a raw payload and steers the required-check query" {
  # `head_sha: .head.sha`는 조기 종결의 **좌표**인데, 접힌 픽스처만으로는
  # 원시 페이로드 증인이 0이었다(스텁이 jq를 적용하지 않으므로 GitHub이 `head`를 리네임해도 초록).
  # 이 레인은 목록형·단건형 둘 다 실제 jq를 돌린다(같은 투영 SSOT = LANE_PR_FIELDS).
  KC="$BATS_TEST_TMPDIR/kubeconfig"; echo "apiVersion: v1" > "$KC"
  printf '[{"id":9500,"name":"gate","status":"completed","conclusion":"failure","html_url":"https://github.com/ukyi-app/homelab/runs/9500","started_at":"2026-09-08T01:00:00Z"}]\n' > "$FIX/gate-checks.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_RAW=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 200 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "21" ]
  # (a) 원시 페이로드에서 접힌 sha가 **다음 질의의 경로**로 그대로 실린다(exact 핀).
  run python3 "$LEDGER_PY" exact "$CALLS" gh api \
    "repos/ukyi-app/homelab/commits/d0d0caca7777d0d0caca7777d0d0caca77770001/check-runs?check_name=gate&filter=all&per_page=100" \
    --jq "[.check_runs[] | {id, name, status, conclusion, html_url, started_at}]"
  [ "$status" -eq 0 ]

  # (b) 필드 리네임 뮤테이션 — `head`가 사라지면 좌표가 없어지고 조기 종결은 fail-open(pending)이다.
  #     ⚠️ 여기서 red가 나야 한다: 종전 판은 null 좌표를 그대로 URL에 실어 `commits/null/…`을 쐈다.
  MUT="$BATS_TEST_TMPDIR/gh-raw-mut"; mkdir -p "$MUT"
  cp "$GH_RAW_DIR"/*.json "$MUT/"
  sed 's/"head":/"head_obj":/' "$GH_RAW_DIR/lane-pulls.json" > "$MUT/lane-pulls.json"
  sed 's/"head":/"head_obj":/' "$GH_RAW_DIR/lane-pull.json" > "$MUT/lane-pull.json"
  : > "$CALLS"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_RAW=1 GH_RAW_DIR="$MUT" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 200 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  # 좌표가 없으면 질의 자체가 나가지 않는다 — `commits/null/…`이 원장에 0건이어야 한다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/commits/null/check-runs?check_name=gate&filter=all&per_page=100" --jq)" = "0" ]
}
