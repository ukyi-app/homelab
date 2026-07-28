#!/usr/bin/env bats
# 워크플로 준비상태 회계(G-09)의 gate 테스트 — tools/check-workflow-readiness.ts + policy/workflow-readiness.json.
#
# 병: 자격/설정 부재로 job이 통째로 skip됐는데 GHA run은 **초록**이다. 그 job 안의 알림 스텝은
# `if: always()`여도 함께 skip되므로(skip된 job은 스텝을 0개 실행한다) owner 신호가 정확히 0이다.
# 라이브 실측(2026-07-27): tf-reconcile의 drift-github·drift-tailscale은 시크릿 미등록으로 한 번도
# 실행된 적이 없는데 매 30분 run이 success였다.
#
# ⚠️ **픽스처 트리로 검증한다.** 실 레포로 단언하면 원장이 바뀔 때마다 테스트가 깨지고(=원장이
# 테스트를 결정한다), 더 나쁘게는 "지금 상태가 곧 계약"이 되어 mutation이 아무것도 증명하지 못한다.
# 실 레포 단언은 두 개뿐이다: 가드가 통과한다(+ 스캔 건수) · 탐지기가 알려진 사이트를 실제로 잡는다.
# ⚠️ @test 이름은 영어만(한글이면 bats dir-run 인코딩 깨짐 — AGENTS.md).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 실패는 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

GUARD() { bun "$ROOT/tools/check-workflow-readiness.ts" "$@"; }

# 준비상태 게이트 3종(job-level·step-level·비-게이트)과 회계 job을 한 워크플로에 담은 픽스처 레포.
# tracked 열거를 쓰므로 git init + add가 필요하다(안 하면 열거가 0건이 되어 바닥값이 먼저 잡는다).
_fixture() {
  local t="$BATS_TEST_TMPDIR/${1:-fx}"
  mkdir -p "$t/.github/workflows" "$t/policy"
  cat > "$t/.github/workflows/demo.yaml" <<'YAML'
name: demo
on:
  schedule:
    - cron: "0 0 * * *"
jobs:
  preflight:
    runs-on: ubuntu-latest
    outputs:
      configured: ${{ steps.check.outputs.configured }}
    steps:
      - id: check
        env:
          TOK: ${{ secrets.DEMO_TOKEN }}
        run: |
          if [ -n "$TOK" ]; then
            echo "configured=true" >> "$GITHUB_OUTPUT"
          else
            echo "configured=false" >> "$GITHUB_OUTPUT"
            echo "::notice::DEMO_TOKEN 미설정 — demo skip"
          fi
  worker:
    needs: preflight
    if: needs.preflight.outputs.configured == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo work
  probe:
    runs-on: ubuntu-latest
    outputs:
      executed: ${{ steps.go.outputs.executed }}
    steps:
      - id: pf
        env:
          TOK: ${{ secrets.DEMO_TOKEN }}
        run: |
          if [ -n "$TOK" ]; then
            echo "ready=true" >> "$GITHUB_OUTPUT"
          else
            echo "ready=false" >> "$GITHUB_OUTPUT"
          fi
      - id: go
        if: steps.pf.outputs.ready == 'true'
        run: echo "executed=true" >> "$GITHUB_OUTPUT"
  # 결과 플래그 대조군 ①: 자격 env가 **아예 없다**(github 컨텍스트에서 파생).
  outcome:
    runs-on: ubuntu-latest
    steps:
      - id: diff
        env:
          BEFORE: ${{ github.event.before }}
        run: |
          if [ -z "$BEFORE" ]; then
            echo "changed=true" >> "$GITHUB_OUTPUT"
          else
            echo "changed=false" >> "$GITHUB_OUTPUT"
          fi
      - if: steps.diff.outputs.changed == 'true'
        run: echo build
  # 결과 플래그 대조군 ②: **자격 env를 쓰면서** <key>=false를 쓴다. 오직 "자격 변수의 공백 검사"
  # 유무만이 이 job을 준비상태 게이트에서 갈라낸다 — tf-reconcile의 terraform drift 스텝과 같은 모양이다.
  # ⚠️ 이 대조군이 없으면 탐지기의 구분선을 통째로 지워도 전 테스트가 green이다(mutation으로 실측).
  plan:
    runs-on: ubuntu-latest
    steps:
      - id: drift
        env:
          TF_VAR_token: ${{ secrets.DEMO_TOKEN }}
        run: |
          set +e
          terraform plan -detailed-exitcode
          rc=$?
          set -e
          case "$rc" in
            0) echo "drift=false" >> "$GITHUB_OUTPUT" ;;
            2) echo "drift=true" >> "$GITHUB_OUTPUT" ;;
            *) exit "$rc" ;;
          esac
      - if: steps.drift.outputs.drift == 'true'
        run: echo apply
  # 이중 게이트: 바깥은 job-level(자격 A), 안쪽은 step-level(자격 B). 바깥이 통과해도 B가 없으면
  # job은 success인 채 아무것도 안 한다 — 예전 탐지기는 바깥만 보고 kind='job'으로 확정해 이걸 놓쳤다.
  dual:
    needs: preflight
    if: needs.preflight.outputs.configured == 'true'
    runs-on: ubuntu-latest
    outputs:
      executed: ${{ steps.dgo.outputs.executed }}
    steps:
      - id: dpf
        env:
          TOK2: ${{ secrets.DEMO_TOKEN_2 }}
        run: |
          if [ -n "$TOK2" ]; then
            echo "ready=true" >> "$GITHUB_OUTPUT"
          else
            echo "ready=false" >> "$GITHUB_OUTPUT"
          fi
      - id: dgo
        if: steps.dpf.outputs.ready == 'true'
        run: echo "executed=true" >> "$GITHUB_OUTPUT"
  accounting:
    needs: [preflight, worker, probe, dual]
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    steps:
      - run: bun tools/check-workflow-readiness.ts --workflow demo.yaml
YAML
  # 보안 핀(SECURITY_CRITICAL)은 대상 워크플로 부재를 **드리프트로** 낸다 — 픽스처도 최소 형태를 갖춘다.
  cat > "$t/.github/workflows/bump-poll.yaml" <<'YAML'
name: bump-poll
on:
  schedule:
    - cron: "*/10 * * * *"
jobs:
  preflight:
    runs-on: ubuntu-latest
    outputs:
      writer: ${{ steps.check.outputs.writer }}
    steps:
      - id: check
        env:
          WRITER: ${{ secrets.HOMELAB_WRITER_APP_ID }}
        run: |
          if [ -n "$WRITER" ]; then
            echo "writer=true" >> "$GITHUB_OUTPUT"
          else
            echo "writer=false" >> "$GITHUB_OUTPUT"
          fi
  reconcile:
    needs: preflight
    if: needs.preflight.outputs.writer == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo revoke
  accounting:
    needs: [preflight, reconcile]
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    steps:
      - run: bun tools/check-workflow-readiness.ts --workflow bump-poll.yaml
YAML
  # 두 번째 워크플로: 자격 env를 **job 레벨**에 두고 빈-문자열 비교로 게이트한다.
  # 스텝 env만 보거나 `-n`/`-z`만 보는 탐지기는 이 사이트를 통째로 놓친다(구조적 false negative).
  # 원장에 선언하지 않았으므로, 탐지되면 역방향 대조가 red를 내야 한다 — 즉 이 파일이 곧 mutation 실증이다.
  cat > "$t/.github/workflows/altgate.yaml" <<'YAML'
name: altgate
on:
  schedule:
    - cron: "0 1 * * *"
# 워크플로-level 자격 env — 세 계층 중 가장 바깥. 이걸 병합하지 않으면 아래 gpre가 탐지에서 빠진다.
env:
  GLOBAL_TOK: ${{ secrets.ALT_GLOBAL }}
jobs:
  pre:
    runs-on: ubuntu-latest
    # job-level 자격 env — 스텝 env만 보는 탐지기는 여기를 놓친다.
    env:
      TOK: ${{ secrets.ALT_TOKEN }}
    outputs:
      ready: ${{ steps.c.outputs.ready }}
    steps:
      - id: c
        run: |
          if [ "$TOK" = "" ]; then
            echo "ready=false" >> "$GITHUB_OUTPUT"
          else
            echo "ready=true" >> "$GITHUB_OUTPUT"
          fi
  work:
    needs: pre
    if: needs.pre.outputs.ready == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo alt
  gpre:
    runs-on: ubuntu-latest
    outputs:
      ok: ${{ steps.g.outputs.ok }}
    steps:
      - id: g
        run: |
          if [ -z "$GLOBAL_TOK" ]; then
            echo "ok=false" >> "$GITHUB_OUTPUT"
          else
            echo "ok=true" >> "$GITHUB_OUTPUT"
          fi
  gwork:
    needs: gpre
    if: needs.gpre.outputs.ok == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo global
YAML
  cat > "$t/policy/workflow-readiness.json" <<'JSON'
{
  "workflows": {
    "demo.yaml": {
      "accounting_job": "accounting",
      "expect_executed": 3,
      "jobs": {
        "worker": { "state": "required", "severity": "error", "why": "픽스처: job-level 게이트" },
        "probe": { "state": "required", "severity": "warning", "why": "픽스처: step-level 게이트" },
        "dual": { "state": "required", "severity": "error", "why": "픽스처: job-level + step-level 이중 게이트(바깥이 통과해도 안쪽 자격이 없으면 무작동)" }
      }
    },
    "bump-poll.yaml": {
      "accounting_job": "accounting",
      "expect_executed": 1,
      "jobs": {
        "reconcile": { "state": "required", "severity": "error", "why": "픽스처: 면제 불가 보안 항목" }
      }
    },
    "altgate.yaml": {
      "jobs": {
        "work": { "state": "optional", "why": "픽스처: job-level env + 빈문자열 비교 게이트(탐지 커버리지 증인)" },
        "gwork": { "state": "optional", "why": "픽스처: 워크플로-level env 게이트(탐지 커버리지 증인)" }
      }
    }
  }
}
JSON
  git -C "$t" init -q
  git -C "$t" add -A
  echo "$t"
}

# 픽스처 원장을 python으로 변형한다(jq는 순서를 보존하지 않아 diff가 커진다).
_mutate() { python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
exec(sys.argv[2])
json.dump(d,open(p,'w',encoding='utf-8'),ensure_ascii=False,indent=2)
" "$1/policy/workflow-readiness.json" "$2"; }

FIXTURE_ARGS="--min-workflows 1 --min-declarations 1"

# ── 실 레포 (딱 두 가지만) ────────────────────────────────────────────────────

@test "the guard passes on the real tree and reaches its domain" {
  run GUARD --repo-root "$ROOT"
  [ "$status" -eq 0 ]
  # 스캔 건수를 함께 단언한다 — 열거가 무너져 0건을 봐도 '위반 0'과 똑같이 초록이기 때문.
  echo "$output" | grep -qE '^SCAN: check-workflow-readiness:workflows: [0-9]{2,}$'
  echo "$output" | grep -qE '^SCAN: check-workflow-readiness:declarations: [0-9]+$'
}

@test "the detector still sees the known real gates (positive control against narrowing)" {
  # 정방향 "미선언 0건"만 두면 탐지기가 좁아져도 계속 참이라 통과한다(실측된 회귀 방향).
  # 두 종류(job-level·step-level)를 각각 못박아 어느 한쪽이 죽으면 red가 되게 한다.
  run bun -e '
    import { readinessGates } from "'"$ROOT"'/tools/check-workflow-readiness.ts";
    import { parse } from "yaml"; import { readFileSync } from "node:fs";
    const g = readinessGates(parse(readFileSync("'"$ROOT"'/.github/workflows/tf-reconcile.yaml","utf8")));
    console.log([...g].map(([j,k])=>j+":"+k).sort().join(","));
  '
  [ "$status" -eq 0 ]
  [ "$output" == "drift-github:step,drift-tailscale:step,reconcile:job" ]
}

# ── 정적: 양방향 대조 ─────────────────────────────────────────────────────────

@test "a clean fixture passes both directions" {
  t="$(_fixture clean)"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 0 ]
}

@test "an undeclared readiness gate is rejected (reverse direction)" {
  t="$(_fixture undecl)"
  _mutate "$t" "del d['workflows']['demo.yaml']['jobs']['worker']; d['workflows']['demo.yaml']['expect_executed']=2"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "미선언"
}

@test "a declaration with no matching gate is rejected (forward direction, dead claim)" {
  t="$(_fixture dead)"
  _mutate "$t" "d['workflows']['demo.yaml']['jobs']['ghost']={'state':'optional','why':'존재하지 않는 job'}"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "실제 준비상태 게이트가 아니다"
}

@test "a result flag is not mistaken for a readiness gate (the credential emptiness test is the line)" {
  # 대조군 둘이 서로 다른 것을 증명한다:
  #   outcome — 자격 env가 아예 없다(`if (!cred.length) continue`가 거른다).
  #   plan    — **자격 env를 쓰면서** drift=false를 쓴다. 오직 공백 검사 유무가 이걸 갈라낸다.
  # plan이 없으면 구분선을 통째로 지워도 전 테스트가 green이다(mutation 실측 — 그래서 추가했다).
  t="$(_fixture outcome)"
  run bun -e '
    import { readinessGates } from "'"$ROOT"'/tools/check-workflow-readiness.ts";
    import { parse } from "yaml"; import { readFileSync } from "node:fs";
    const g = readinessGates(parse(readFileSync(process.argv[1]+"/.github/workflows/demo.yaml","utf8")));
    console.log(["outcome","plan"].filter((j)=>g.has(j)).join(",") || "ok");
  ' "$t"
  [ "$status" -eq 0 ]
  [ "$output" == "ok" ]
}

# ── 정적: 회계 job 계약 ───────────────────────────────────────────────────────

@test "a step-level gate without outputs.executed is rejected (unobservable by construction)" {
  t="$(_fixture noexec)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("    outputs:\n      executed: ${{ steps.go.outputs.executed }}\n", "")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "outputs.executed 승격 없이는"
}

@test "an accounting job without !cancelled() is rejected (watchdog shares the gate's fate)" {
  t="$(_fixture nocancel)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("    if: ${{ !cancelled() }}\n", "    if: ${{ success() }}\n")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "cancelled"
}

# ⚠️ 삭제된 워크플로에는 핀이 걸리지 않는다(지킬 표면이 없다). 그 갈래는 다른 픽스처들이
# bump-poll.yaml 없이 통과하는 것으로 이미 실증된다 — 여기선 **존재하는데 강등**만 본다.
@test "an accounting job that does not need a declared job is rejected" {
  t="$(_fixture noneeds)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("    needs: [preflight, worker, probe, dual]\n", "    needs: [preflight, worker, dual]\n")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "needs에서 'probe' 누락"
}

@test "a missing accounting job is rejected when required entries exist" {
  t="$(_fixture noacct)"
  _mutate "$t" "d['workflows']['demo.yaml']['accounting_job']='absent-job'"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "job이 워크플로에 없다"
}

@test "expect_executed must equal the number of required entries (enumeration floor)" {
  t="$(_fixture floor)"
  _mutate "$t" "d['workflows']['demo.yaml']['expect_executed']=1"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "바닥값 드리프트"
}

# ── 정적: 원장 스키마 ─────────────────────────────────────────────────────────

@test "an unconfigured entry without since and owner_action is rejected" {
  t="$(_fixture unconf)"
  _mutate "$t" "d['workflows']['demo.yaml']['jobs']['probe']={'state':'unconfigured','why':'근거'}; d['workflows']['demo.yaml']['expect_executed']=2"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "since=YYYY-MM-DD"
  echo "$output" | grep -q "owner_action"
}

@test "a required entry without severity is rejected" {
  t="$(_fixture nosev)"
  _mutate "$t" "del d['workflows']['demo.yaml']['jobs']['probe']['severity']"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "severity가 필요하다"
}

@test "a declaration without a why is rejected (an unexplained ledger row is not a ledger)" {
  t="$(_fixture nowhy)"
  _mutate "$t" "d['workflows']['demo.yaml']['jobs']['probe']['why']=''"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "why가 비었다"
}

@test "a missing policy file is a loud failure, not an empty ledger (fail-open direction)" {
  t="$(_fixture nopolicy)"
  rm "$t/policy/workflow-readiness.json"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
}

# ── 정적: 면제 불가 보안 항목 ─────────────────────────────────────────────────

@test "bump-poll reconcile cannot be downgraded out of required+error (security pin)" {
  # 인가 회수는 가용성이 아니라 보안 속성이다 — 원장 편집만으로 강등할 수 없어야 한다.
  # 실 레포를 건드리지 않고 같은 이름의 픽스처로 상수 자체를 실증한다.
  t="$BATS_TEST_TMPDIR/secpin"
  mkdir -p "$t/.github/workflows" "$t/policy"
  cat > "$t/.github/workflows/bump-poll.yaml" <<'YAML'
name: bump-poll
on:
  schedule:
    - cron: "*/10 * * * *"
jobs:
  preflight:
    runs-on: ubuntu-latest
    outputs:
      writer: ${{ steps.check.outputs.writer }}
    steps:
      - id: check
        env:
          WRITER: ${{ secrets.HOMELAB_WRITER_APP_ID }}
        run: |
          if [ -n "$WRITER" ]; then
            echo "writer=true" >> "$GITHUB_OUTPUT"
          else
            echo "writer=false" >> "$GITHUB_OUTPUT"
          fi
  reconcile:
    needs: preflight
    if: needs.preflight.outputs.writer == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo reconcile
YAML
  cat > "$t/policy/workflow-readiness.json" <<'JSON'
{
  "workflows": {
    "bump-poll.yaml": {
      "jobs": {
        "reconcile": { "state": "optional", "why": "강등 시도" }
      }
    }
  }
}
JSON
  git -C "$t" init -q; git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "required+error 고정"
}

# ── 정적: 바닥값 자신 ─────────────────────────────────────────────────────────

@test "the workflow enumeration floor fires when the domain collapses" {
  run GUARD --repo-root "$ROOT" --min-workflows 99999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "the floor values must be non-negative integers (never a silently disabled floor)" {
  run GUARD --repo-root "$ROOT" --min-workflows ""
  [ "$status" -eq 2 ]
  run GUARD --repo-root "$ROOT" --min-declarations abc
  [ "$status" -eq 2 ]
}

@test "an unknown flag is rejected with the usage exit code" {
  run GUARD --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

# ── 런타임 회계 ───────────────────────────────────────────────────────────────

_needs() { WORKFLOW_NEEDS="$1" GUARD --repo-root "$2" --workflow demo.yaml; }

@test "runtime: every declared job executed is a clean pass" {
  t="$(_fixture rt-ok)"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"success","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "required 3/3 실행"
}

@test "runtime: a skipped error-severity job fails the accounting job" {
  t="$(_fixture rt-err)"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"skipped","outputs":{}},"probe":{"result":"success","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "::error::.*'worker' 미실행"
}

@test "runtime: a step-level job that reports success without executing is caught" {
  # 이 갈래가 09의 핵심이다 — job은 success인데 스텝을 하나도 안 돌린 상태.
  t="$(_fixture rt-step)"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"success","outputs":{}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "::warning::.*'probe' 미실행"
  echo "$output" | grep -q "경고 1건"
}

@test "runtime: a failed job counts as executed (failure is already loud)" {
  # 실패를 미실행로 또 세면 원인이 두 번 오귀속된다 — run은 이미 red이고 그 job이 스스로 알린다.
  t="$(_fixture rt-fail)"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"failure","outputs":{}},"probe":{"result":"failure","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "required 3/3 실행"
}

@test "runtime: a declared job absent from the needs payload is a failure" {
  t="$(_fixture rt-absent)"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "needs 페이로드에서 누락"
}

@test "runtime: a declared gap warns but keeps the run green (declared is accounted, not exempt)" {
  t="$(_fixture rt-gap)"
  _mutate "$t" "d['workflows']['demo.yaml']['jobs']['probe']={'state':'unconfigured','since':'2026-07-27','owner_action':'시크릿 등록','why':'알려진 갭'}; d['workflows']['demo.yaml']['expect_executed']=2"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"success","outputs":{}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "준비상태 갭"
  out="$output"
  # 갭은 telegram 조건(warnings)에 들어가면 안 된다 — 매 run 재발해 진짜 신호를 덮는다.
  run grep -q "경고 0건" <<<"$out"
  [ "$status" -eq 0 ]
}

@test "runtime: a gap that has closed fails until the ledger follows (stale declaration)" {
  t="$(_fixture rt-stale)"
  _mutate "$t" "d['workflows']['demo.yaml']['jobs']['probe']={'state':'unconfigured','since':'2026-07-27','owner_action':'시크릿 등록','why':'알려진 갭'}; d['workflows']['demo.yaml']['expect_executed']=2"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"success","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "원장은 unconfigured다"
}

@test "runtime: a missing needs payload is a failure, not a silent pass" {
  t="$(_fixture rt-nopayload)"
  run env -u WORKFLOW_NEEDS bun "$ROOT/tools/check-workflow-readiness.ts" --repo-root "$t" --workflow demo.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "WORKFLOW_NEEDS"
}

@test "runtime: a workflow with no ledger entry cannot silently account itself" {
  t="$(_fixture rt-undeclared)"
  run env WORKFLOW_NEEDS='{}' bun "$ROOT/tools/check-workflow-readiness.ts" --repo-root "$t" --workflow ghost.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "선언이 없다"
}

@test "runtime: GITHUB_OUTPUT carries the counts the notify step gates on" {
  t="$(_fixture rt-out)"
  out="$BATS_TEST_TMPDIR/gh-output"
  : > "$out"
  run env GITHUB_OUTPUT="$out" WORKFLOW_NEEDS='{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"success","outputs":{}},"dual":{"result":"success","outputs":{"executed":"true"}}}' \
    bun "$ROOT/tools/check-workflow-readiness.ts" --repo-root "$t" --workflow demo.yaml
  [ "$status" -eq 0 ]
  grep -q '^failures=0$' "$out"
  grep -q '^warnings=1$' "$out"
  grep -q '^gaps=0$' "$out"
  grep -q '^body<<READINESS_EOF$' "$out"
}

@test "runtime: a skip caused by an upstream failure is attributed to that failure, not to credentials" {
  # `result=skipped`는 자격 부재와 상류 크래시를 구별하지 못한다 — 원인이 정반대인데 같은 값이다.
  # 판정은 그대로(미실행은 미실행) 두되 메시지가 진짜 원인을 지목해야 오귀속이 안 생긴다.
  t="$(_fixture rt-upstream)"
  run _needs '{"preflight":{"result":"failure","outputs":{}},"worker":{"result":"skipped","outputs":{}},"probe":{"result":"success","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "상류 job(preflight) 실패"
}

@test "runtime: a credential-absence skip is NOT attributed to an upstream failure (no false cause)" {
  t="$(_fixture rt-nocause)"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"skipped","outputs":{}},"probe":{"result":"success","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "상류 job" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "the detector sees gates declared with job-level and workflow-level env (all three env layers)" {
  # 두 변형이 동시에 걸린 사이트다: 자격 env가 **job 레벨**이고, 공백 검사가 `-n`이 아니라 `= ""`다.
  # 어느 한쪽이라도 탐지기가 못 보면 이 job은 준비상태 게이트로 잡히지 않고, 그러면 원장의 선언이
  # "죽은 선언"으로 red가 된다 — 즉 이 단언은 탐지 폭이 좁아지는 방향을 정확히 막는다.
  t="$(_fixture altgate)"
  run bun -e '
    import { readinessGates } from "'"$ROOT"'/tools/check-workflow-readiness.ts";
    import { parse } from "yaml"; import { readFileSync } from "node:fs";
    const g = readinessGates(parse(readFileSync(process.argv[1]+"/.github/workflows/altgate.yaml","utf8")));
    console.log([...g].map(([j,k])=>j+":"+k).sort().join(","));
  ' "$t"
  [ "$status" -eq 0 ]
  [ "$output" == "gwork:job,work:job" ]
}

# ── 적대 재검토가 지목한 결함들의 증인 (전부 mutation으로 load-bearing 확인) ──────────────

@test "a job gated at BOTH levels is classified as step, not job (the outer gate must not swallow the inner)" {
  # 바깥 게이트가 통과해도 안쪽 자격이 없으면 job은 success인 채 아무것도 안 한다.
  # 예전 탐지기는 job-level을 만나면 스텝 스캔을 멈춰 kind='job'으로 확정했고, 그러면 정적은
  # outputs.executed 승격을 면제하고 런타임은 success만 보고 '실행됨'으로 셌다 — G-09의 병 그 자체다.
  t="$(_fixture dualdet)"
  run bun -e '
    import { readinessGates } from "'"$ROOT"'/tools/check-workflow-readiness.ts";
    import { parse } from "yaml"; import { readFileSync } from "node:fs";
    const g = readinessGates(parse(readFileSync(process.argv[1]+"/.github/workflows/demo.yaml","utf8")));
    console.log(g.get("dual") ?? "none");
  ' "$t"
  [ "$status" -eq 0 ]
  [ "$output" == "step" ]
}

@test "runtime: a dual-gated job that reports success without the inner gate is caught" {
  t="$(_fixture dualrt)"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"success","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{}}}' "$t"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "'dual' 미실행"
}

@test "renaming a job output escapes nothing — the outputs mapping is resolved, not assumed" {
  # `outputs: { ready: ${{ steps.check.outputs.configured }} }`처럼 이름만 바꾸면 예전 축약 매칭이
  # 게이트를 못 봤고, 미선언 job이 원장 강제를 통째로 우회했다.
  t="$(_fixture alias)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("      configured: ${{ steps.check.outputs.configured }}", "      ready: ${{ steps.check.outputs.configured }}")
s = s.replace("    if: needs.preflight.outputs.configured == 'true'", "    if: needs.preflight.outputs.ready == 'true'")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run bun -e '
    import { readinessGates } from "'"$ROOT"'/tools/check-workflow-readiness.ts";
    import { parse } from "yaml"; import { readFileSync } from "node:fs";
    const g = readinessGates(parse(readFileSync(process.argv[1]+"/.github/workflows/demo.yaml","utf8")));
    console.log([...g].map(([j,k])=>j+":"+k).sort().join(","));
  ' "$t"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "worker:job"
}

@test "a gate output whose source cannot be read statically is rejected (no silent escape hatch)" {
  t="$(_fixture unresolved)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("      configured: ${{ steps.check.outputs.configured }}", "      configured: ${{ steps.check.outputs.configured || 'true' }}")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "출처를 정적으로 해석할 수 없다"
}

@test "an outputs.executed promoted from outside the gate is rejected (presence is not observation)" {
  # 상수나 게이트 밖 스텝으로 승격하면 정적·런타임이 전부 초록인 채 회계가 아무것도 관측하지 못한다.
  t="$(_fixture fakeexec)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("      executed: ${{ steps.go.outputs.executed }}\n    steps:\n      - id: pf",
              "      executed: 'true'\n    steps:\n      - id: pf")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "outputs.executed 승격 없이는"
}

@test "the security pin fires when its target workflow disappears (rename is not a silent exemption)" {
  # 리네임 + 새 이름으로 optional 선언 = 두 편집으로 면제 불가 통제가 사라지던 경로.
  t="$(_fixture pinmissing)"
  rm "$t/.github/workflows/bump-poll.yaml"
  python3 - "$t/policy/workflow-readiness.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
del d["workflows"]["bump-poll.yaml"]
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "보안 핀 대상"
}

@test "the security pin fires when its declaration is deleted while the workflow remains" {
  t="$(_fixture pingone)"
  _mutate "$t" "del d['workflows']['bump-poll.yaml']['jobs']['reconcile']; d['workflows']['bump-poll.yaml']['expect_executed']=0"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "보안 항목"
}

@test "an accounting job that sits inside a readiness gate is rejected (the watchdog would skip too)" {
  t="$(_fixture acctgated)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("    needs: [preflight, worker, probe, dual]\n    if: ${{ !cancelled() }}",
              "    needs: [preflight, worker, probe, dual]\n    if: ${{ !cancelled() && needs.preflight.outputs.configured == 'true' }}")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "자기도 준비상태 게이트 안에 있다"
}

@test "an accounting call step neutered by continue-on-error or if or || true is rejected" {
  for kind in coe cond ortrue; do
    t="$(_fixture "neuter-$kind")"
    python3 - "$t/.github/workflows/demo.yaml" "$kind" <<'PY'
import sys
p, kind = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
call = "      - run: bun tools/check-workflow-readiness.ts --workflow demo.yaml"
repl = {
    "coe": "      - continue-on-error: true\n        run: bun tools/check-workflow-readiness.ts --workflow demo.yaml",
    "cond": "      - if: github.event_name == 'schedule'\n        run: bun tools/check-workflow-readiness.ts --workflow demo.yaml",
    "ortrue": "      - run: bun tools/check-workflow-readiness.ts --workflow demo.yaml || true",
}[kind]
open(p, "w", encoding="utf-8").write(s.replace(call, repl))
PY
    git -C "$t" add -A
    run GUARD --repo-root "$t" $FIXTURE_ARGS
    [ "$status" -eq 1 ] || { echo "neuter=$kind 가 통과했다"; false; }
  done
}

@test "a workflow with required entries but no accounting_job is rejected" {
  t="$(_fixture noacctdecl)"
  _mutate "$t" "del d['workflows']['demo.yaml']['accounting_job']"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "accounting_job 미선언"
}

@test "runtime: expect_executed drifting from the ledger is caught at run time too" {
  t="$(_fixture rt-floor)"
  _mutate "$t" "d['workflows']['demo.yaml']['expect_executed']=9"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"success","outputs":{"executed":"true"}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "바닥값 드리프트"
}

@test "runtime: a step-level job that failed before reaching its gate is NOT counted as executed" {
  # `failure`를 무조건 실행으로 세면, 게이트 스텝에 도달도 못 하고 죽은 job이 '실행됨'이 되고
  # unconfigured 항목에서는 '갭이 닫혔다'는 **정반대 처방**이 나간다.
  t="$(_fixture rt-earlyfail)"
  _mutate "$t" "d['workflows']['demo.yaml']['jobs']['probe']={'state':'unconfigured','since':'2026-07-27','owner_action':'시크릿 등록','why':'알려진 갭'}; d['workflows']['demo.yaml']['expect_executed']=2"
  run _needs '{"preflight":{"result":"success","outputs":{}},"worker":{"result":"success","outputs":{}},"probe":{"result":"failure","outputs":{}},"dual":{"result":"success","outputs":{"executed":"true"}}}' "$t"
  out="$output"
  run grep -q "원장은 unconfigured다" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "a prefix-colliding variable does not fake a credential emptiness test (word boundary)" {
  # 자격 env `CF`가 있는 스텝에서 **다른** 변수 `$CFG`를 `= \"\"`로 비교하면, 경계가 없던 정규식이
  # 그걸 자격 공백 검사로 오인해 같은 스텝의 결과 플래그를 준비상태로 승격시켰다.
  t="$(_fixture prefix)"
  python3 - "$t/.github/workflows/demo.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("""      - id: drift
        env:
          TF_VAR_token: ${{ secrets.DEMO_TOKEN }}
        run: |
          set +e""",
"""      - id: drift
        env:
          TF_VAR_token: ${{ secrets.DEMO_TOKEN }}
        run: |
          if [ "$TF_VAR_token_extra" = "" ]; then echo noop; fi
          set +e""")
open(p, "w", encoding="utf-8").write(s)
PY
  git -C "$t" add -A
  run bun -e '
    import { readinessGates } from "'"$ROOT"'/tools/check-workflow-readiness.ts";
    import { parse } from "yaml"; import { readFileSync } from "node:fs";
    const g = readinessGates(parse(readFileSync(process.argv[1]+"/.github/workflows/demo.yaml","utf8")));
    console.log(g.has("plan") ? "MISDETECTED" : "ok");
  ' "$t"
  [ "$status" -eq 0 ]
  [ "$output" == "ok" ]
}

@test "the required gate invokes the static mode (its only protected venue)" {
  # check-guard-authority는 **가드 파일 단위**로 venue를 세므로, 스케줄 워크플로의 런타임 호출
  # (`--workflow <f>`)만으로 이 도구의 권위가 충족된다 — 정적 모드(원장↔워크플로 양방향)는 그 회계에
  # 보이지 않는다. 즉 ci.yaml에서 이 스텝을 지워도 다른 게이트가 아무 말을 하지 않는다.
  run grep -qE '^ +run: bun tools/check-workflow-readiness\.ts *$' "$ROOT/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
  # make verify 미러도 함께(로컬 진입점에서 같은 검사가 돈다)
  run grep -q 'bun tools/check-workflow-readiness.ts' "$ROOT/Makefile"
  [ "$status" -eq 0 ]
}
