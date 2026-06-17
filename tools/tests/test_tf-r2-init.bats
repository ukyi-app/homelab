#!/usr/bin/env bats
# tf-r2-init composite — backend.hcl 작성 + init -lockfile=readonly를 SSOT화.
# 5콜사이트(iac×2, tf-reconcile×3) 중복 제거. -lockfile=readonly 불변식이 한 곳에 산다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/tf-r2-init/action.yml"; }

@test "tf-r2-init composite exists with root + state-key inputs" {
  [ -f "$A" ]
  run grep -E '^[[:space:]]*root:' "$A"
  [ "$status" -eq 0 ]
  run grep -E '^[[:space:]]*state-key:' "$A"
  [ "$status" -eq 0 ]
}

@test "tf-r2-init enforces -lockfile=readonly in init" {
  run grep -E 'init .*-lockfile=readonly' "$A"
  [ "$status" -eq 0 ]
}

@test "iac and tf-reconcile adopt the composite (no inline backend.hcl heredoc)" {
  run grep -F 'uses: ./.github/actions/tf-r2-init' "$ROOT/.github/workflows/iac.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'uses: ./.github/actions/tf-r2-init' "$ROOT/.github/workflows/tf-reconcile.yaml"
  [ "$status" -eq 0 ]
  # 인라인 heredoc(cat > infra/.../backend.hcl)이 두 워크플로에서 제거됐는지
  run grep -E 'cat > infra/.*backend\.hcl' "$ROOT/.github/workflows/iac.yaml"
  [ "$status" -ne 0 ]
  run grep -E 'cat > infra/.*backend\.hcl' "$ROOT/.github/workflows/tf-reconcile.yaml"
  [ "$status" -ne 0 ]
}

@test "all five init call-sites use the composite" {
  n=$(grep -c 'uses: ./.github/actions/tf-r2-init' "$ROOT/.github/workflows/iac.yaml" "$ROOT/.github/workflows/tf-reconcile.yaml" | awk -F: '{s+=$2} END {print s}')
  [ "$n" -eq 5 ]
}
