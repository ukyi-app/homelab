#!/usr/bin/env bats
# homelab status — 앱 목록/단일 앱/핸들 조회의 프로세스 경계 계약.
# 계층 계약(스펙): 레포(핀·바인딩) + GitHub(최근 run·열린 PR)가 기본, KUBECONFIG가 있으면
# ArgoCD sync/health를 덧붙이고 없으면 그 구간을 "생략"(envelope.omitted=["live"])으로 명시한다 —
# 생략은 성공(exit 0)이지 skip(4)이 아니다(부분 정보 제공이 계약). 하네스: helpers/cli_stub.bash
# (gh·kubectl PATH stub + NUL argv 원장 + --root 주입 앱 픽스처) — 라이브 무의존.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
#
# ── 알려진 무증인 축(예약 — homelab-cli-r2 티켓 35 (e)) ─────────────────────────────────────────
# `status.ts`의 **프로덕션 기본 루트**(`defaultRoot()` = `new URL("../..", import.meta.url)`)는 이
# 파일의 어떤 @test도 밟지 않는다: 목록·앱 모드 호출이 전부 `--root "$APPS_ROOT"` 심을 통과하고
# `??`라 기본값 표현식이 **호출조차 되지 않기** 때문이다. 그래서 그 앵커를 `"../../.."`로 바꿔도
# 전건 초록이다 — 하필 그 경로가 MCP status tool이 항상 타는 유일한 경로다(root 미노출).
# 지금 이 자리에 "루트에서 count 0" 같은 단언을 세우면 apps/에 앱이 0개라 **공허하다**(그린필드).
# ⇒ **첫 실전 앱이 `apps/`에 착지하는 커밋**에서 `--root` 없는 @test를 추가한다: 그 앱 이름이
#    목록에 실재함을 재면 앵커 파손이 red가 된다(그 전에는 어떤 형태로도 비-vacuous하지 않다).
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_gh_stub
  make_kubectl_stub
  KC="$BATS_TEST_TMPDIR/kubeconfig"
  echo "apiVersion: v1" > "$KC"
}

# 방출된 envelope을 결과 계약으로 대조한다(티켓 25 (a) — variant별 **실산출물**을 검증기에 태운다).
# 형상 결합이 없던 동안 status failure 4곳은 스키마 대조 없이 variant만 봤다.
assert_envelope_valid() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/assert-env.json"
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = JSON.parse(readFileSync(process.argv[1], "utf8"));
    const errs = schemaErrors(env, sch, sch);
    console.log(errs.length ? "INVALID: " + errs.join(" | ") : "valid");
  ' "$BATS_TEST_TMPDIR/assert-env.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^valid$"
}

@test "status --json on a greenfield root reports an empty list with exit 0" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.verb')" = "status" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "list" ]
  [ "$(echo "$output" | jq -r '.result.count')" = "0" ]
  [ "$(echo "$output" | jq -r '.result.apps | length')" = "0" ]
}

@test "status list enumerates apps with pin, autoDeploy, and source repo" {
  make_app_fixture blog true
  make_app_fixture page false
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.count')" = "2" ]
  [ "$(echo "$output" | jq -r '[.result.apps[].name] | sort | join(",")')" = "blog,page" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="blog") | .autoDeploy')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="page") | .autoDeploy')" = "false" ]
  echo "$output" | jq -r '.result.apps[] | select(.name=="blog") | .tag' | grep -q "^sha-1111111"
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="page") | .sourceRepo')" = "ukyi-app/page" ]
}

@test "status folds a non-boolean autoDeploy to false and reports a missing bindings file as key absence" {
  # 해석 SSOT는 descriptorAutoDeploy(app-surface 경유 — d4) 하나다: bindings가 실재하면 정확히
  # boolean true만 true고, non-boolean("yes")은 인가 의미론과 같은 false로 **표시**된다.
  # "미기록"(키 부재)은 bindings 파일 자체의 부재/파손뿐이다.
  make_app_fixture blog true
  make_app_fixture page '"yes"'
  make_app_fixture bare true
  rm "$APPS_ROOT/apps/bare/deploy/prod/.bindings.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="page") | .autoDeploy')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="bare") | has("autoDeploy")')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="blog") | .autoDeploy')" = "true" ]
}

@test "status app mode reports pin, runs, lane-filtered open PRs, and live ArgoCD state" {
  make_app_fixture page true
  printf '[{"name":"release","status":"completed","conclusion":"success","head_sha":"c0ffee1","html_url":"https://github.com/ukyi-app/page/actions/runs/9"}]\n' > "$FIX/runs.json"
  # 레인 픽스처(브랜치 명명 SSOT 형식): 매치 4(bump 레거시 tag형·bump kind 인코딩 신형·secrets run_id형·
  # teardown/teardown-app-) + 배제 3(비접두 형제 'pages', 하이픈 형제 'page-extra' — 접두는 같아도 잔여가
  # tag형이 아님, 동명 bespoke target — kind가 다르면 이 앱의 브랜치가 아니다)
  printf '[{"number":7,"title":"bump page","head":"bump-poll/page-sha-abcdef1","html_url":"u1","auto_merge":true},{"number":8,"title":"secrets","head":"update-secrets/page-123","html_url":"u2","auto_merge":true},{"number":9,"title":"other app","head":"bump-poll/pages-sha-abcdef1","html_url":"u3","auto_merge":false},{"number":10,"title":"teardown","head":"teardown/teardown-app-page-456","html_url":"u4","auto_merge":false},{"number":11,"title":"sibling","head":"bump-poll/page-extra-sha-abcdef1","html_url":"u5","auto_merge":true},{"number":12,"title":"bump page new","head":"bump-poll/app/page-sha-abcdef1","html_url":"u6","auto_merge":true},{"number":13,"title":"bespoke twin","head":"bump-poll/bespoke/page-sha-abcdef1","html_url":"u7","auto_merge":false}]\n' > "$FIX/homelab-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "app" ]
  [ "$(echo "$output" | jq -r '.result.app.name')" = "page" ]
  echo "$output" | jq -r '.result.app.tag' | grep -q "^sha-1111111"
  [ "$(echo "$output" | jq -r '.result.app.autoDeploy')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.runs | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.result.runs[0].conclusion')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.openPrs | length')" = "4" ]
  [ "$(echo "$output" | jq -r '[.result.openPrs[].number] | sort | join(",")')" = "7,8,10,12" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.sync')" = "Synced" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.health')" = "Healthy" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revision')" = "abc1234" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd | has("revisions")')" = "false" ]
  [ "$(echo "$output" | jq -r '.omitted | length')" = "0" ]
}

@test "status live revision resolves multi-source revisions[] to one value, keeps the single-source form (control), and reports skew raw" {
  make_app_fixture page true
  # 기본 픽스처 = 멀티소스(revisions 3개·revision 키 부재) — 앱 Application의 실제 형상(티켓 01).
  [ "$(jq -r '.status.sync | has("revisions") and (has("revision") | not)' "$FIX/argocd-app.json")" = "true" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revision')" = "abc1234" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd | has("revisions")')" = "false" ]
  # 단일소스 대조군(db/cache 레인 형상) — 같은 리더가 단수 필드를 그대로 낸다.
  printf '{"status":{"sync":{"status":"Synced","revision":"abc1234"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revision')" = "abc1234" ]
  # skew(소스 간 불일치)는 확정 revision 없이 관측 원본 revisions를 낸다(사람 렌더도 미확정 표기).
  printf '{"status":{"sync":{"status":"OutOfSync","revisions":["abc1234","def5678","abc1234"]},"health":{"status":"Progressing"}}}\n' > "$FIX/argocd-app.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd | has("revision")')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revisions | join(",")')" = "abc1234,def5678,abc1234" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "미확정"
}

@test "mutation and status engines share one ArgoCD revision reader (no literal sync.revision reads remain)" {
  # 티켓 01 수용 기준 — 두 엔진이 lib/argocd.ts 리더를 호출하고 단수 필드 직접 참조는 0건. 부정 카운트라
  # 같은 패턴이 리더 자신에서는 매치함을 양성 대조로 단언한다(검출기 생존).
  n=0
  for f in tools/lib/mutation.ts tools/lib/status.ts; do
    [ "$(grep -cF 'syncRevisionOf(' "$f")" -ge 1 ]
    [ "$(grep -cF 'sync?.revision' "$f")" = "0" ]
    n=$((n+1))
  done
  [ "$n" -eq 2 ]
  [ "$(grep -cF 'sync.revision' tools/lib/argocd.ts)" -ge 1 ]
}

@test "status app mode reports the memory-ledger limit when the app has a ledger row" {
  make_app_fixture page true
  make_ledger_row page 64 128
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app.ledgerMi')" = "128" ]
}

@test "status app mode omits ledgerMi when the app has no ledger row (absence is key absence)" {
  make_app_fixture page true
  make_ledger_row other-app 64 128
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app | has("ledgerMi")')" = "false" ]
}

@test "status app mode fails loud when the homelab PR listing errors" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_PRS_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  assert_envelope_valid "$output"
}

@test "an in-repo app (no source-repo) skips the runs fetch and reports an empty runs list" {
  make_app_fixture local-app true -
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status local-app --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.runs | length')" = "0" ]
  [ "$(echo "$output" | jq -r '.result.app | has("sourceRepo")')" = "false" ]
  # 원장 증인: gh 호출은 열린 PR 목록 1회뿐(run 조회 없음)
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "1" ]
}

@test "status app mode without KUBECONFIG omits the live section explicitly and exits 0 (not skip)" {
  make_app_fixture page true
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.omitted | join(",")')" = "live" ]
  [ "$(echo "$output" | jq -r '.result | has("live")')" = "false" ]
  echo "$stderr" | grep -q "생략"
  # 생략이면 kubectl을 아예 부르지 않는다
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl)" = "0" ]
}

@test "status app mode with a broken cluster reports a live error but still succeeds" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_KUBECTL_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live | has("error")')" = "true" ]
  [ "$(echo "$output" | jq -r '.omitted | length')" = "0" ]
}

@test "the result states which checkout the repo layer read (root always, head only when it is a repo)" {
  # 병: status의 '레포 계층'은 CLI 자신의 **로컬 체크아웃** 디스크다. bump-poll 자동 머지·--wait 머지
  # 뒤 git pull을 안 한 체크아웃에서 「배포 핀: 옛 tag」+「라이브: 새 rev」가 모순 없이 success로 나온다.
  # MCP status tool은 root를 입력으로 노출하지 않아 **항상** defaultRoot를 타므로, 어느 체크아웃을
  # 읽었는지는 결과가 말해야 한다. origin/main 비교는 넣지 않는다(gh 의존 + 낡은 스냅샷 200 함정).
  make_app_fixture page true
  # ① 비-git 루트 — head는 키 부재이고 그래도 success다(기본 픽스처가 밟는 분기).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.repo.root')" = "$APPS_ROOT" ]
  [ "$(echo "$output" | jq -r '.result.repo | has("head")')" = "false" ]
  assert_envelope_valid "$output"
  # ② git 루트 — head가 실제 short SHA다.
  git -C "$APPS_ROOT" init -q -b main
  printf 'x\n' > "$APPS_ROOT/seed.txt"
  git -C "$APPS_ROOT" add -A
  git -C "$APPS_ROOT" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m seed
  want="$(git -C "$APPS_ROOT" rev-parse --short HEAD)"
  [ -n "$want" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.repo.head')" = "$want" ]
  echo "$stderr" | grep -q "레포 계층"
  # ③ app 모드도 같은 출처를 진술한다(두 SHA 대조는 소비자 몫이라 좌표가 결과에 있어야 한다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.repo.head')" = "$want" ]
}

@test "a broken source-repo never masquerades as an in-repo app, and a real in-repo app says runs are omitted" {
  # 병: app-surface가 부재(정상 인레포)·빈 값(잘린 쓰기)·읽기 불가를 한 null로 접어, 잘린 쓰기 하나가
  # 「이 앱은 인레포 앱이다」라는 **적극적 거짓 주장**이 되고 그 앱의 최근 run이 영원히 '없음'이었다.
  make_app_fixture blank true
  printf '   \n' > "$APPS_ROOT/apps/blank/deploy/prod/source-repo"
  # 목록 모드 — 파손을 '인레포'로 말하지 않는다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="blank") | .sourceRepoState')" = "empty" ]
  echo "$stderr" > "$BATS_TEST_TMPDIR/list-human.txt"
  grep -q "source-repo" "$BATS_TEST_TMPDIR/list-human.txt"
  # app 모드 — GitHub 계층을 못 여는 상태라 fail-loud다(빈 목록 위장 금지, 모듈 헤더의 계약).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status blank --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "source-repo"
  # 파손 분기는 gh를 **한 번도** 부르지 않는다. 총계 1은 바로 위 목록 모드의 머지 대기 레인 1회이고
  # (티켓 40), app 모드가 더한 호출은 0이다 — 두 등식이 함께 서야 이게 정확 상한이다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/blank/actions/runs?per_page=3" --jq)" = "0" ]
  # 읽기 불가(디렉토리 = EISDIR)도 인레포로 위장하지 않는다.
  make_app_fixture unread true
  rm -f "$APPS_ROOT/apps/unread/deploy/prod/source-repo"
  mkdir -p "$APPS_ROOT/apps/unread/deploy/prod/source-repo"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status unread --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "source-repo"
  # 대조군 — 진짜 인레포 앱(파일 부재)은 성공하고, run 계층 생략을 omitted가 명시한다.
  make_app_fixture inrepo true -
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status inrepo --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.omitted | index("runs") != null')" = "true" ]
  assert_envelope_valid "$output"
}

@test "the ledger join is scoped to the prod env so a same-named platform row cannot be misattributed" {
  # 실측: 앱 이름이 platform 컴포넌트와 겹치면(homepage) 그 컴포넌트 행의 limit이 앱 예산으로 보고됐다.
  # platform 행은 손 편집으로 들어와 create-app의 전역 이름 유일성 게이트를 지나지 않고, addRow가
  # 앱 행을 **맨 뒤**에 넣으므로 `rows.find`의 첫 매치는 항상 위쪽 platform 행이다.
  make_app_fixture page true
  make_ledger_row page 32 208 platform
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app | has("ledgerMi")')" = "false" ]
  # 양성 대조 — 같은 이름의 prod 행이 뒤에 오면 그 값을 잡는다(조인이 상수가 아니다).
  make_ledger_row page 64 128
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app.ledgerMi')" = "128" ]
}

@test "the live layer tells absent, unreachable, and present apart (three states, one fixture set)" {
  # 병: `--ignore-not-found` 없이 조회해 NotFound(exit 1)를 조회 실패로 접었다 — 'appset이 아직
  # Application을 안 만들었다/prune이 끝났다'는 **상태**인데 관측 실패로 위장됐다(create·teardown
  # 머지 직후가 정확히 그 창이다). 같은 레포의 teardown 수렴은 이미 부재를 상태로 다룬다.
  make_app_fixture page true
  # ① 부재
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_APP_ABSENT=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.live.absent')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.live | has("error")')" = "false" ]
  # 생략(omitted)과도 다른 축이다 — 부재는 관측했고, 생략은 관측하지 않은 것이다.
  [ "$(echo "$output" | jq -r '.omitted | length')" = "0" ]
  # ⚠️ 사람용 채널 단언은 assert_envelope_valid **앞**이다 — 그 헬퍼가 자기 `run`으로 $stderr를 덮는다.
  echo "$stderr" | grep -q "Application 부재"
  assert_envelope_valid "$output"
  # ② 조회 실패(클러스터 도달 불가)
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_KUBECTL_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live | has("error")')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.live | has("absent")')" = "false" ]
  # ③ 실재 — 기본 픽스처는 그대로 Synced다(부재 케이스가 모든 조회를 삼키지 않았다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.sync')" = "Synced" ]
  [ "$(echo "$output" | jq -r '.result.live | has("absent")')" = "false" ]
}

@test "Degraded conditions ride along as the top three in source order, normalized to one line" {
  # 'Degraded'만 보고하면 다음 행동이 CLI 밖(kubectl·ArgoCD UI)에서 시작된다. 정렬 기준은 **원본
  # 배열 순서**로 고정한다 — 임의 정렬은 골든을 비결정적으로 만든다.
  make_app_fixture page true
  printf '{"status":{"sync":{"status":"OutOfSync","revisions":["abc1234"]},"health":{"status":"Degraded"},"conditions":[{"type":"ComparisonError","message":"첫 줄\\n둘째 줄"},{"type":"SyncError","message":"two"},{"type":"OrphanedResourceWarning","message":"three"},{"type":"Extra","message":"four"}]}}\n' > "$FIX/argocd-app.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.health')" = "Degraded" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.conditions | length')" = "3" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.conditions[0].type')" = "ComparisonError" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.conditions[2].type')" = "OrphanedResourceWarning" ]
  # 단일 줄 정규화 — 여러 줄 메시지가 사람용 렌더의 줄 구조를 깨지 않게 op 계층에서 접는다.
  [ "$(echo "$output" | jq -r '.result.live.argocd.conditions[0].message' | wc -l | tr -d ' ')" = "1" ]
  echo "$output" | jq -r '.result.live.argocd.conditions[0].message' | grep -q "둘째 줄"
  # ⚠️ 사람용 채널 단언은 assert_envelope_valid **앞**이다(그 헬퍼의 `run`이 $stderr를 덮는다).
  echo "$stderr" | grep -q "ComparisonError"
  assert_envelope_valid "$output"
  # 대조군 — conditions가 없는 픽스처는 키 자체가 없다(compact 규약: 값 없음 = 키 부재).
  printf '{"status":{"sync":{"status":"Synced","revisions":["abc1234"]},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd | has("conditions")')" = "false" ]
}

@test "an over-long condition message is capped so the result stays a report, not a log dump" {
  make_app_fixture page true
  long="$(printf 'x%.0s' $(seq 1 900))"
  printf '{"status":{"sync":{"status":"OutOfSync","revisions":["abc1234"]},"health":{"status":"Degraded"},"conditions":[{"type":"ComparisonError","message":"%s"}]}}\n' "$long" > "$FIX/argocd-app.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  n="$(echo "$output" | jq -r '.result.live.argocd.conditions[0].message' | awk '{print length($0)}')"
  [ "$n" -le 200 ]
  # 바닥값 — 상한이 0으로 붕괴하지 않았다(빈 문자열이면 minLength 위반이라 스키마도 잡는다).
  [ "$n" -ge 100 ]
  assert_envelope_valid "$output"
}

@test "status for an unknown app fails with exit 1 and an error result" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status ghost --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "app" ]
  echo "$output" | jq -r '.result.error' | grep -q "ghost"
  assert_envelope_valid "$output"
}

@test "status app mode fails loud when the GitHub layer errors (no silent empty lists)" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_RUNS_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  assert_envelope_valid "$output"
}

@test "a GitHub layer failure names its cause, and the four lanes are told apart by it" {
  # 병: ghJson의 null 접힘이 gh 미설치·미인증·404·망 단절·파싱 깨짐을 한 문장으로 만들었다.
  # 같은 statusApp 안에서 kubectl 실패는 이미 사유를 싣는데 GitHub 레그만 지워지는 비대칭이었다.
  make_app_fixture page true
  # ① run 목록 전송 오류 — stub stderr 문구가 result.error에 실린다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_RUNS_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' > "$BATS_TEST_TMPDIR/e-runs.txt"
  grep -q "API 오류" "$BATS_TEST_TMPDIR/e-runs.txt"
  # 레인 구별의 증인 — 전송 오류 문구에 404가 섞이지 않는다(양성 대조는 바로 위 매치).
  run grep -qF "HTTP 404" "$BATS_TEST_TMPDIR/e-runs.txt"
  [ "$status" -eq 1 ]
  # ② 열린 PR 목록 전송 오류 — 같은 계약.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_PRS_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "API 오류"
  # ③ 핸들 404 — 재인증·망 단절과 처방이 다르다(레포 개명·접근권 부재).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_HANDLE_404=1 "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/999" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "HTTP 404"
  # ④ gh 미설치 — 사유가 `spawnSync gh ENOENT`로 새면 운영자에게 무의미하다. 처방으로 번역한다.
  rm -f "$STUB/gh"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/pull/7" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "PATH에 없다"
}

@test "a non-JSON gh response is reported as a parse failure, not as a lookup failure" {
  # 스칼라 jq 오용(오브젝트 아닌 투영)은 rc 0인데 JSON이 아니다 — '조회 실패'로 위장하면
  # 네트워크·권한 처방으로 잘못 분기한다. 3상 리더의 'parse'가 그 층을 지킨다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_NONJSON=1 "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/1" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' > "$BATS_TEST_TMPDIR/e-parse.txt"
  grep -q "파싱 실패" "$BATS_TEST_TMPDIR/e-parse.txt"
  assert_envelope_valid "$output"
  # 양성 대조 — 같은 핸들 경로의 전송 오류 레인은 '파싱'이라 말하지 않는다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_HANDLE_404=1 "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/999" --json
  echo "$output" | jq -r '.result.error' > "$BATS_TEST_TMPDIR/e-404.txt"
  run grep -qF "파싱 실패" "$BATS_TEST_TMPDIR/e-404.txt"
  [ "$status" -eq 1 ]
}

@test "run handle lookup reports status and conclusion from the run URL" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/1" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  [ "$(echo "$output" | jq -r '.result.run.status')" = "completed" ]
  [ "$(echo "$output" | jq -r '.result.run.conclusion')" = "success" ]
}

@test "run handle lookup normalizes a null conclusion by omitting the key (in-progress run)" {
  printf '{"name":"release","status":"in_progress","conclusion":null,"head_sha":"c0ffee1","html_url":"u"}\n' > "$FIX/run-handle.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/2" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run.status')" = "in_progress" ]
  [ "$(echo "$output" | jq -r '.result.run | has("conclusion")')" = "false" ]
}

@test "pr handle lookup reports state, merged, and auto-merge from the PR URL" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/pull/7" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "pr" ]
  [ "$(echo "$output" | jq -r '.result.pr.state')" = "open" ]
  [ "$(echo "$output" | jq -r '.result.pr.merged')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.pr.autoMerge')" = "true" ]
}

@test "handle lookup on a missing operation fails with exit 1" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_HANDLE_404=1 "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/999" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  assert_envelope_valid "$output"
}

@test "a malformed handle URL is a usage error: exit 2, no envelope" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://gitlab.com/x/y/runs/1" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
}

@test "a malformed PR handle URL is a usage error: exit 2, no envelope" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/issues/7" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
}

@test "dot segments in a handle URL are refused before any gh call (traversal closed at the format gate)" {
  # 티켓 27 — owner/repo 캡처가 `[\w.-]+`라 `.`·`..`가 통과했고 그 캡처가 `repos/<o>/<r>/…`로 gh api
  # 경로에 조립됐다(`https://github.com/../../pull/1` → `repos/../../pulls/1`). identity.ts가
  # 'traversal 1차 게이트에 분기를 두지 않는다'를 원칙으로 두는데 핸들 축만 그 밖이었다.
  # 각 케이스마다 **원장 0건**을 함께 잰다 — exit 2만 보면 '거부는 했는데 그 전에 한 번 쏘았다'가 안 보인다.
  n=0
  for u in \
    "https://github.com/../x/actions/runs/1" \
    "https://github.com/x/../actions/runs/1" \
    "https://github.com/x/./actions/runs/1" \
    "https://github.com/-lead/x/actions/runs/1"; do
    : > "$CALLS"
    run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "$u" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]   # 열거 바닥값 — 루프가 짧아지면 vacuous green이다
  # PR 축도 같은 술어를 쓴다(두 정규식이 함께 좁혀졌는지 — 한쪽만 고치면 다른 축이 열린 채 남는다).
  : > "$CALLS"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/../../pull/1" --json
  [ "$status" -eq 2 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
  # 대조군 — 좁히기가 정당한 이름을 함께 막지 않았다. 점-접두 레포(`.github`)는 GitHub의 실재 이름이고
  # 임의 owner/repo 핸들을 받는 것이 이 모드의 계약이다(하네스 case가 레포를 글롭으로 두는 이유).
  : > "$CALLS"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/.github/actions/runs/1" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/.github/actions/runs/1" --jq "{name, status, conclusion, head_sha, html_url}")" = "1" ]
}

@test "app argument and handle flags are mutually exclusive: exit 2" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --run "https://github.com/ukyi-app/page/actions/runs/1" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the two handle flags are mutually exclusive with each other: exit 2" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/1" --pr "https://github.com/ukyi-app/homelab/pull/7" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "status --help prints the verb usage and exits 0" {
  run bun tools/homelab.ts status --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "status"
  echo "$output" | grep -q -- "--run"
  echo "$output" | grep -q -- "--pr"
}

@test "status rejects an unknown option and a single-dash token with the verb usage on stderr (exit 2)" {
  # 티켓 12 — statusCli만 positionalThenFlags 골격을 손으로 다시 쓰고 있었고, 그 인라인 분기를 밟는
  # 테스트가 0건이었다(치환의 등가성 증인). `-h`는 이전엔 '앱 이름 형식 불량: -h'였다(shell-9).
  run --separate-stderr bun tools/homelab.ts status --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- "--bogus"
  echo "$stderr" | grep -q "사용법: homelab status"
  run --separate-stderr bun tools/homelab.ts status -h
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "알 수 없는 옵션"
}

@test "all four status modes emit schema-valid envelopes (floor 4)" {
  make_app_fixture page true
  export OUTDIR="$BATS_TEST_TMPDIR"
  for mode_args in "list:--root $APPS_ROOT" "app:page --root $APPS_ROOT" "run:--run https://github.com/ukyi-app/page/actions/runs/1" "pr:--pr https://github.com/ukyi-app/homelab/pull/7"; do
    args="${mode_args#*:}"
    env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status $args --json 2>/dev/null > "$BATS_TEST_TMPDIR/env-${mode_args%%:*}.json"
  done
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const dir = process.env.OUTDIR;
    let n = 0;
    for (const m of ["list", "app", "run", "pr"]) {
      const env = JSON.parse(readFileSync(dir + "/env-" + m + ".json", "utf8"));
      const errs = [
        ...schemaErrors(env, sch, sch),
        ...schemaErrors(env.result, sch.definitions.statusOk, sch),
      ];
      if (errs.length) { console.error(m + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:4$"
}

@test "status app mode gh calls are read-only (ledger-verified)" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" observation-only "$CALLS"
  [ "$status" -eq 0 ]
}

@test "status human mode renders the app report in Korean on stdout" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "page"
  echo "$output" | grep -q "배포 핀"
  echo "$output" | grep -q "라이브"
}

# ── 티켓 09: run 모드의 브랜치 좌표(--branch) 정확 조회 ────────────────────────────────────
# pending 봉투는 run 핸들과 함께 **레인 브랜치**를 싣는다(추가 API 호출 0). 그 좌표를 받는 조회가
# 여기다 — 와일드카드 스캔이 아니라 `head=<owner>:<branch>` 정확 일치라서 형제 브랜치를 못 집는다.

@test "run mode with --branch reports the lane PR from an exact head query and never a sibling branch's PR" {
  # 대상(…mydb-501)과 형제(…mydb-5011)를 둘 다 픽스처로 둔다 — 형제가 실재해도 조회에 안 나온다.
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee","state":"closed"}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  printf '[{"number":99,"html_url":"https://github.com/ukyi-app/homelab/pull/99","merged_at":null,"merge_commit_sha":null,"state":"open"}]\n' > "$FIX/prs-head-create-database_mydb-5011.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.url')" = "https://github.com/ukyi-app/homelab/pull/21" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.number')" = "21" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.merged')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.mergeSha')" = "feedbee" ]
  # 질의의 정확성을 원장이 고정한다 — 이 문자열이 접두 스캔으로 바뀌면 형제 오귀속이 되살아난다.
  run python3 "$LEDGER_PY" exact "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq "[.[] | {number, html_url, merged_at, merge_commit_sha, state}]"
  [ "$status" -eq 0 ]
  # 형제 브랜치는 조회 자체가 없었다(부재 단언) + 같은 원장 질의의 양성 대조는 위 exact가 소유한다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-5011" --jq)" = "0" ]
}

@test "two PRs on the same lane branch is a race (exit 3), never a pick" {
  printf '[{"number":21,"html_url":"u21","merged_at":null,"merge_commit_sha":null},{"number":22,"html_url":"u22","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r '.variant')" = "race" ]
  [ "$(echo "$output" | jq -r '.result.observedPrs')" = "2" ]
  echo "$output" | jq -r '.result.error' | grep -q "create-database/mydb-501"
}

@test "run mode without --branch carries no pr key (the coordinate is what opens the lookup)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run | has("pr")')" = "false" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "0" ]
  # 같은 @test 안 양성 대조 — 좌표를 주면 같은 경로가 실제로 조회하고 키가 생긴다.
  : > "$CALLS"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run | has("pr")')" = "true" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "1" ]
}

@test "--branch is refused standalone, on a foreign ref, and when its run id contradicts the run URL (no gh query leaks)" {
  # 임의 ref가 질의 문자열로 새면 안 된다 — 세 거부 레인 모두 gh 호출 0건이어야 한다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --branch "create-database/mydb-501" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- "--run"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "refs/heads/../evil" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "브랜치 형식"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-5011" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "5011"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api)" = "0" ]
  # 같은 @test 안 양성 대조 — 유효한 쌍은 같은 경로에서 gh 조회로 나아간다(부재 단언이 공허하지 않다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api)" -ge 1 ]
}

@test "the run+branch and race envelopes validate against the schema (floor 2)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json 2>/dev/null > "$OUTDIR/env-branch.json"
  printf '[{"number":21,"html_url":"u21","merged_at":null,"merge_commit_sha":null},{"number":22,"html_url":"u22","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json 2>/dev/null > "$OUTDIR/env-race.json" || true
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const dir = process.env.OUTDIR;
    let n = 0;
    for (const m of ["branch", "race"]) {
      const env = JSON.parse(readFileSync(dir + "/env-" + m + ".json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(m + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:2$"
}

@test "an app with no deploy artifacts still surfaces the in-flight create-app PR from one open-PR listing" {
  # 그린필드의 정상 상태: create-app PR이 열려 있고(수동 머지 대기) 산출물은 아직 없다. 종전에는
  # 그 상태가 '앱 없음' failure 한 줄이라 MCP 에이전트가 이어갈 좌표가 0이었다(mcp-4).
  printf '[{"number":51,"title":"create-app myapp","head":"create-app/myapp-801","html_url":"https://github.com/ukyi-app/homelab/pull/51","auto_merge":false},{"number":52,"title":"other","head":"create-app/other-802","html_url":"u52","auto_merge":false}]\n' > "$FIX/homelab-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status myapp --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.createPrs | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.result.createPrs[0].number')" = "51" ]
  # 형제 앱(other)의 PR은 집지 않는다(레인 판정은 tail 형식까지) + 조회는 한 번뿐.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=open&per_page=100" --jq)" = "1" ]
}

@test "list mode spends exactly one gh call, and losing gh degrades only the in-flight lane" {
  # 티켓 33이 세운 전제('목록 모드 gh 0회')는 티켓 40의 inFlight로 깨진다 — 부재 단언을 **정확
  # 상한**으로 다시 못박는다: 목록 모드의 GitHub 접촉은 열린 PR 목록 **1회뿐**이고, 그 1회가
  # 실패해도 로컬 인벤토리(count·앱 행)는 그대로이며 exit 0이다.
  make_app_fixture blog true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.count')" = "1" ]
  # 정확 상한 — 전체 gh 호출 1회이고 그 1회가 열린 PR 목록이다(두 등식이 함께 서야 상한이다).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=open&per_page=100" --jq)" = "1" ]
  # 목록 모드는 앱 레포 run을 부르지 않는다(앱 수만큼 늘어나는 호출이 없다는 부정 단언).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/blog/actions/runs?per_page=3" --jq)" = "0" ]
  # gh를 지운 PATH — 로컬 레포 계층은 그대로 서고 GitHub 레그만 사유와 함께 접힌다.
  NOGH="$BATS_TEST_TMPDIR/stub-nogh"; mkdir -p "$NOGH"
  for t in bun bash base64 cat git sleep kubectl; do ln -s "$STUB/$t" "$NOGH/$t"; done
  run --separate-stderr env PATH="$NOGH" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.count')" = "1" ]
  [ "$(echo "$output" | jq -r '.result.apps[0].name')" = "blog" ]
  echo "$output" | jq -r '.result.inFlight.error' | grep -q "PATH"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "1" ]
  # 같은 PATH에서 GitHub 계층이 fail-loud인 경로는 실패한다(부재 단언의 양성 짝 — PATH 조작이 먹혔다).
  run --separate-stderr env PATH="$NOGH" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status blog --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
}

@test "a malformed app name is a usage error: exit 2, no envelope (traversal gate, shared predicate)" {
  # status는 리더지만 app을 그대로 apps/<app>/deploy/prod 경로·kubectl 리소스명에 조립한다 —
  # identity.ts의 traversal 1차 게이트를 형제 술어(verbs/secrets/init)와 같은 문구로 공유한다.
  # `Bad_Name` 오타도 '앱 산출물이 없다' failure(1)가 아니라 usage(2)여야 원인 계층이 안 뭉개진다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status ../x --root "$APPS_ROOT" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status Bad_Name --root "$APPS_ROOT" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
}

@test "status app mode reports the wired data-conn handles and omits the key when nothing is wired (floor 2)" {
  # product-1: conn이 봉인·커밋돼도 앱이 envFrom을 배선 안 하면 어떤 게이트도 안 잡았다(#211 실재발).
  # 배선 **자동화**는 하지 않는다(이름≠앱 케이스) — status가 배선 사실을 보고하는 것이 이 티켓의 범위다.
  make_app_fixture wired true
  printf 'envFrom:\n  - secretRef: { name: db-wired-conn }\n  - secretRef: { name: cache-sessions-ro-conn }\n  - secretRef: { name: wired-secrets }\n' \
    >> "$APPS_ROOT/apps/wired/deploy/prod/values.yaml"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status wired --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  # data-conn 컴포넌트가 내는 핸들만 추린다 — 앱 자기 봉인본(wired-secrets)은 배선이 아니다.
  [ "$(echo "$output" | jq -rc '.result.app.conns')" = '["db-wired-conn","cache-sessions-ro-conn"]' ]
  # 부정 단언의 양성 대조 — 배선이 없는 앱은 키 자체가 부재다(빈 배열이 아니라).
  make_app_fixture bare true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status bare --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app | has("conns")')" = "false" ]
  # 사람용 렌더도 같은 사실을 말한다(기계 채널만 알고 사람은 모르는 상태 금지).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status wired --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-wired-conn"
}

# ── 티켓 40: in-flight 가시성 · 핸들 URL 관용 · 빌드 대조 · 리소스 인벤토리 ─────────────────

@test "list mode surfaces in-flight dispatcher PRs from every lane and never renders a failed lookup as none" {
  # observe-3: create-app·teardown은 **수동 머지** 동사라 '머지 대기 PR'이 그린필드의 정상 상태이고
  # 며칠 지속된다. 그 창에서 목록 모드는 「온보딩된 앱이 없다」한 줄이었고 좌표가 0이었다.
  # ⚠️ inFlight는 live와 같은 모양이다({prs}|{error}) — 핵심 페이로드가 로컬 인벤토리인 모드를
  #    GitHub 의존으로 바꾸지 않는다(조회 실패여도 variant는 success).
  make_app_fixture blog true
  printf '[{"number":51,"title":"create-app","head":"create-app/myapp-801","html_url":"u51","auto_merge":false},{"number":52,"title":"secrets","head":"update-secrets/myapp-802","html_url":"u52","auto_merge":true},{"number":53,"title":"teardown","head":"teardown/teardown-app-myapp-803","html_url":"u53","auto_merge":false},{"number":54,"title":"db","head":"create-database/mydb-804","html_url":"u54","auto_merge":false},{"number":55,"title":"cache","head":"create-cache/mycache-805","html_url":"u55","auto_merge":false},{"number":56,"title":"bad key","head":"create-app/Foo-1","html_url":"u56","auto_merge":false},{"number":57,"title":"bump","head":"bump-poll/blog-sha-abcdef1","html_url":"u57","auto_merge":true}]\n' > "$FIX/homelab-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  # 다섯 레인 전부 — keyKind:"resource"(db·cache)도 포함한다(행 데이터가 소유하는 역파싱).
  [ "$(echo "$output" | jq -r '.result.inFlight.prs | length')" = "5" ]
  [ "$(echo "$output" | jq -r '[.result.inFlight.prs[].action] | sort | join(",")')" = "create-app,create-cache,create-database,teardown-app,update-secrets" ]
  [ "$(echo "$output" | jq -r '.result.inFlight.prs[] | select(.action=="create-database") | .key')" = "mydb" ]
  [ "$(echo "$output" | jq -r '.result.inFlight.prs[] | select(.action=="teardown-app") | .key')" = "myapp" ]
  # 불량 key(대문자)와 비-디스패처 브랜치(bump-poll)는 표시되지 않는다 — 위 5건이 양성 대조다.
  [ "$(echo "$output" | jq -r '[.result.inFlight.prs[].number] | index(56) // "none"')" = "none" ]
  [ "$(echo "$output" | jq -r '[.result.inFlight.prs[].number] | index(57) // "none"')" = "none" ]
  # 로컬 인벤토리는 그대로다(GitHub 레그가 앱 행을 대체하지 않는다).
  [ "$(echo "$output" | jq -r '.result.count')" = "1" ]
  assert_envelope_valid "$output"
  # 사람용 렌더가 좌표를 낸다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/inflight-human.txt"
  [ -s "$BATS_TEST_TMPDIR/inflight-human.txt" ]
  grep -q "머지 대기" "$BATS_TEST_TMPDIR/inflight-human.txt"
  grep -q "create-app" "$BATS_TEST_TMPDIR/inflight-human.txt"
  # 조회 실패는 '없음'으로 렌더되지 않는다(vacuous green의 정면) — 그래도 exit 0 + 앱 행 유지.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_PRS_FAIL=1 "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.count')" = "1" ]
  [ "$(echo "$output" | jq -r '.result.inFlight | has("error")')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.inFlight | has("prs")')" = "false" ]
  assert_envelope_valid "$output"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_PRS_FAIL=1 "$BUN" tools/homelab.ts status --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/inflight-fail.txt"
  [ -s "$BATS_TEST_TMPDIR/inflight-fail.txt" ]
  grep -q "조회 실패" "$BATS_TEST_TMPDIR/inflight-fail.txt"
  [ "$(grep -c "머지 대기: 없음" "$BATS_TEST_TMPDIR/inflight-fail.txt")" = "0" ]
  # 부정 단언의 양성 짝 — PR 0건은 실제로 '없음'으로 렌더된다(그 문구가 존재는 한다).
  printf '[]\n' > "$FIX/homelab-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "머지 대기: 없음"
}

@test "a full page of open PRs is reported as truncated so an empty tail is not read as none" {
  # per_page=100은 상한이고, 100건이 왔다는 것은 '더 있을 수 있다'는 뜻이다 — 그 사실을 안 실으면
  # 101번째 머지 대기 PR이 '없음'과 구별되지 않는다.
  python3 - "$FIX/homelab-prs.json" <<'PY'
import json, sys
rows = [{"number": 1000 + i, "title": "t", "head": "create-app/app%d-%d" % (i, 800 + i), "html_url": "u%d" % i, "auto_merge": False} for i in range(100)]
open(sys.argv[1], "w").write(json.dumps(rows) + "\n")
PY
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.inFlight.prs | length')" = "100" ]
  [ "$(echo "$output" | jq -r '.result.inFlight.truncated')" = "true" ]
  assert_envelope_valid "$output"
  # 대조군 — 99건은 truncated가 아니다(상한 도달이 판정 조건이지 '많음'이 아니다).
  python3 - "$FIX/homelab-prs.json" <<'PY'
import json, sys
rows = [{"number": 1000 + i, "title": "t", "head": "create-app/app%d-%d" % (i, 800 + i), "html_url": "u%d" % i, "auto_merge": False} for i in range(99)]
open(sys.argv[1], "w").write(json.dumps(rows) + "\n")
PY
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.inFlight.prs | length')" = "99" ]
  [ "$(echo "$output" | jq -r '.result.inFlight | has("truncated")')" = "false" ]
}

@test "handle URLs are normalized at one point so query, fragment, job, and attempts tails all resolve" {
  # observe-11: GitHub UI가 붙이는 꼬리(?check_suite_focus=true · #issuecomment-…)는 좌표가 아니라
  # 뷰 상태인데 `/`로 시작하지 않아 usage 거부였다. 정규화는 **검증과 조회가 같은 값을 보도록**
  # 한 지점에서 한다 — 두 곳에서 하면 어긋난 순간 형식 오류와 조회가 다른 URL을 본다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/1?check_suite_focus=true" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  [ "$(echo "$output" | jq -r '.result.run | has("scope")')" = "false" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/pull/7#issuecomment-99" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "pr" ]
  # job·attempts는 받되 **승격 사실을 표기**한다 — job 지정이 조용히 무시되면 결과가 거짓말이다.
  for tail in "job/9" "attempts/2"; do
    run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/1/$tail" --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.result.run.scope')" = "run" ]
    assert_envelope_valid "$output"
  done
  # 정규화가 **검증 앞**이라는 증인 — 쿼리가 붙은 run URL에서 --branch 모순이 형식 오류가 아니라
  # run id 불일치로 잡힌다(정규화가 뒤였다면 'URL 형식 불량'이 먼저 나온다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/homelab/actions/runs/501?x=1" --branch create-database/mydb-5011 --json
  [ "$status" -eq 2 ]
  echo "$stderr" | grep -q "run id"
  # 음성 대조 — 타 호스트·issues URL·짧은 번호는 여전히 usage 거부다(관용이 전칭이 아니다).
  for bad in "https://gitlab.com/ukyi-app/page/actions/runs/1" "https://github.com/ukyi-app/page/issues/1" "712"; do
    run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "$bad" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "run rows carry the head branch and event, and the deploy pin is compared to the latest main build in three states" {
  # observe-12: 앱 레포 run 상위 3개에는 PR 빌드·CI가 섞이는데 branch/event가 없어 '핀이 최신 main
  # 빌드인가'를 판정할 수 없었다. ⚠️ 쿼리 필터(branch=main&event=push)는 **쓰지 않는다** — 실패한
  # PR 빌드를 화면에서 지워 3분기 중 하나를 없앤다. 필드로 싣고 판정은 리더가 한다.
  make_app_fixture page true
  tag="$(sed -n 's/^  tag: //p' "$APPS_ROOT/apps/page/deploy/prod/values.yaml")"
  [ -n "$tag" ]
  sha="${tag#sha-}"
  printf '[{"name":"release","status":"completed","conclusion":"success","head_sha":"%s","head_branch":"main","event":"push","html_url":"https://github.com/ukyi-app/page/actions/runs/9"},{"name":"ci","status":"completed","conclusion":"failure","head_sha":"deadbee","head_branch":"feat/x","event":"pull_request","html_url":"https://github.com/ukyi-app/page/actions/runs/8"}]\n' "$sha" > "$FIX/runs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  # PR 빌드도 목록에 남는다(필터를 걸지 않았다는 증인) + 두 필드가 실린다.
  [ "$(echo "$output" | jq -r '.result.runs | length')" = "2" ]
  [ "$(echo "$output" | jq -r '.result.runs[0].headBranch')" = "main" ]
  [ "$(echo "$output" | jq -r '.result.runs[0].event')" = "push" ]
  [ "$(echo "$output" | jq -r '.result.runs[1].event')" = "pull_request" ]
  [ "$(echo "$output" | jq -r '.result.deployedBuild.matchesLatestMain')" = "true" ]
  assert_envelope_valid "$output"
  # ② 불일치 — 최신 main push run의 head_sha가 핀과 다르다.
  printf '[{"name":"release","status":"completed","conclusion":"success","head_sha":"9999999999999999999999999999999999999999","head_branch":"main","event":"push","html_url":"https://github.com/ukyi-app/page/actions/runs/9"}]\n' > "$FIX/runs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.deployedBuild.matchesLatestMain')" = "false" ]
  # ③ `sha-*` 형식 밖 tag — false가 아니라 **키 부재**다(판정 불가를 부정 판정으로 접지 않는다).
  sed -i.bak 's/^  tag: .*/  tag: v1.2.3/' "$APPS_ROOT/apps/page/deploy/prod/values.yaml"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app.tag')" = "v1.2.3" ]
  [ "$(echo "$output" | jq -r '.result | has("deployedBuild")')" = "false" ]
}

@test "status --resources inventories db and cache rows with per-role artifacts, the cache-only ledger row, and tombstones" {
  # product-2: 라이브에 DB 2·캐시 1이 실재하는데 status는 앱만 열거하고 count 0을 냈다 — `db create`로
  # 만든 것을 되읽을 동사가 CLI에 0개였다. 열거는 레이아웃 커널의 역방향(classifyArtifact)에서
  # 파생한다(두 번째 진실 금지). 새 동사가 아니라 status의 5번째 mode다(ADR 0001 재개 조건 미충족).
  make_db_fixture page
  make_db_fixture orders
  make_cache_fixture sessions
  make_ledger_row cache-sessions 64 128 cache
  printf '{"db:page":{"state":"retained"}}\n' > "$APPS_ROOT/platform/data-conn/prod/.tombstones.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --resources --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "resources" ]
  # 열거 붕괴 방어 — 종류별 바닥값(db 2 · cache 1). 총계만 재면 한 종류가 0으로 꺼져도 통과한다.
  [ "$(echo "$output" | jq -r '.result.count')" = "3" ]
  [ "$(echo "$output" | jq -r '[.result.resources[] | select(.kind=="db")] | length')" = "2" ]
  [ "$(echo "$output" | jq -r '[.result.resources[] | select(.kind=="cache")] | length')" = "1" ]
  [ "$(echo "$output" | jq -r '[.result.resources[].name] | sort | join(",")')" = "orders,page,sessions" ]
  # role별 산출물 실존 — db 5역할·cache 3역할이 전부 present다(전건 실존이 기준선).
  [ "$(echo "$output" | jq -r '.result.resources[] | select(.name=="orders") | [.artifacts[] | select(.present)] | length')" = "5" ]
  [ "$(echo "$output" | jq -r '.result.resources[] | select(.name=="sessions") | [.artifacts[] | select(.present)] | length')" = "3" ]
  # 원장 행은 cache에만 — db는 원장 비접촉 불변식이다.
  [ "$(echo "$output" | jq -r '.result.resources[] | select(.name=="sessions") | .ledgerMi')" = "128" ]
  [ "$(echo "$output" | jq -r '.result.resources[] | select(.name=="page") | has("ledgerMi")')" = "false" ]
  # tombstone은 조인된 행에만 실린다(부재는 키 부재).
  [ "$(echo "$output" | jq -r '.result.resources[] | select(.name=="page") | .tombstone')" = "retained" ]
  [ "$(echo "$output" | jq -r '.result.resources[] | select(.name=="orders") | has("tombstone")')" = "false" ]
  # 관측은 로컬 디스크뿐 — gh를 부르지 않는다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
  assert_envelope_valid "$output"
  # 부분 purge 잔재 — conn만 남고 소스(Database CR)가 사라진 상태를 행이 말한다(전건 present의 음성 짝).
  rm "$APPS_ROOT/platform/cnpg/prod/databases/orders.yaml"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --resources --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.count')" = "3" ]
  [ "$(echo "$output" | jq -r '.result.resources[] | select(.name=="orders") | .artifacts[] | select(.role=="cr") | .present')" = "false" ]
  # 사람용 렌더도 같은 사실을 말한다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --resources --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "orders"
}

@test "the --resources mode joins the mutually exclusive set and its usage error names it" {
  make_app_fixture blog true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status blog --resources --root "$APPS_ROOT" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- "--resources"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --resources --run "https://github.com/ukyi-app/page/actions/runs/1" --root "$APPS_ROOT" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  # 양성 대조 — 단독 지정은 통과한다(상호배타가 전칭 거부가 아니다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --resources --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "resources" ]
}
