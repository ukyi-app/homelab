#!/usr/bin/env bats
# 전 워크플로 YAML 파싱 게이트 — colon-in-unquoted-name 류 문법 오류 회귀 방지.
# (bump-poll.yaml의 step name "신뢰 경계: ..."가 중첩 매핑으로 깨져 update-image 권위 경로
#  전체가 불능이 됐던 버그 — CI 게이트가 못 잡았다.)
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "every workflow file is valid YAML (node yaml parser)" {
  run node -e '
    const y = require("yaml"), fs = require("fs");
    const dir = process.argv[1] + "/.github/workflows";
    const bad = [];
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ya?ml$/.test(f)) continue;
      try { y.parse(fs.readFileSync(dir + "/" + f, "utf8")); }
      catch (e) { bad.push(f + ": " + String(e.message).split("\n")[0]); }
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}

@test "no .yml workflow files remain (all unified to .yaml; reusable-app-build already .yaml)" {
  # git ls-files는 매치 0에도 exit 0 → `!` 부정 아닌 출력-비어있음으로 검사(검증된 함정).
  run bash -c "git -C '$ROOT' ls-files '.github/workflows/*.yml'"
  [ -z "$output" ]
}

@test "no stale .yml references to renamed workflows (code·docs·tests·manifests)" {
  # 구 .yml 참조(워크플로 basename)가 어디에도 잔존하면 안 된다. git grep은 매치0에 exit1 → || true로 흡수.
  run bash -c "git -C '$ROOT' grep -lE '(_create-app|_create-cache|_create-database|_update-secrets|bump-poll|renovate|tf-reconcile|verify)\.yml' -- ':!docs/plans/*' || true"
  [ -z "$output" ]
}

@test "deleted dispatch workflows have no tracked references" {
  # dispatch-mutation 멀티플렉서 + _audit/_teardown reusable 삭제 후 잔존 참조 0.
  # 제외: docs/plans(역사)·외부계약 reusable-app-build·이 가드 파일 자신(패턴 정의가 자기매치).
  run bash -c "git -C \"$ROOT\" grep -lE 'dispatch-mutation|_audit\.yaml|_teardown\.yaml' -- ':!docs/plans/*' ':!.github/workflows/reusable-app-build.yaml' ':!tests/gates/test_workflow-yaml.bats' || true"
  [ -z "$output" ]
}

@test "deleted v1 onboarding identifiers have no tracked references" {
  # v1 onboarding 경로(onboard.yaml·onboard-app·homelab-app-schema·.homelab.yaml) 전면 폐기 후 잔존 0.
  # 제외: docs/plans(역사)·docs/runbooks(로컬 런북, 별도 수동)·자기 가드 파일.
  run bash -c "git -C \"$ROOT\" grep -lE 'onboard\.yaml|onboard-app|homelab-app-schema|\.homelab\.yaml' -- ':!docs/plans/*' ':!docs/runbooks/*' ':!tests/gates/test_workflow-yaml.bats' || true"
  [ -z "$output" ]
}
