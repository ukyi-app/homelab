#!/usr/bin/env bats
# 자격 인벤토리 정합 가드(scripts/verify-credential-inventory.sh)의 **변별력** 테스트.
#
# 왜 필요한가: 이 가드의 도메인(런북)은 gitignored라 **CI에서는 영원히 SKIP**이다. 즉 검출기가
# 망가져도 러너는 그 사실을 모른다 — 픽스처로 양성·음성 대조를 거는 이 파일만이 검출기가 살아
# 있음을 증명한다. 픽스처는 전부 hermetic(인자로 파일을 주므로 실 런북이 없어도 돈다).
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/verify-credential-inventory.sh"
  FX="$BATS_TEST_TMPDIR"
  # 원장 4건 — 바닥값(3)이 방향 단언을 **가리지 않도록** 한 건을 빼도 3이 남게 잡는다.
  cat > "$FX/led.json" <<'EOF'
[{"name":"aaa (x)","expires":"2099-12-31","note":"n"},
 {"name":"bbb (y)","expires":"2099-12-31","note":"n"},
 {"name":"ccc (z)","expires":"2099-12-31","note":"n"},
 {"name":"ddd (w)","expires":"2099-12-31","note":"n"}]
EOF
}

# $1 = 표 본문(행들) · $2 = "N건 등재" 줄 내용
mk_rb() {
  printf '## A. 표\n\n| # | 원장 name | 발급처 |\n|---|---|---|\n%s\n\n### 현재 원장 상태\n- %s\n' "$1" "$2" > "$FX/rb.md"
}
ALL4='| ① | `aaa` | x |
| ② | `bbb` | y |
| ③ | `ccc` | z |
| ④ | `ddd` | w |'

@test "a matching runbook table and ledger pass, and the scan signals name both domains" {
  mk_rb "$ALL4" '**4건** 등재'
  run bash "$S" "$FX/rb.md" "$FX/led.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: verify-credential-inventory:ledger: 4$'
  echo "$output" | grep -qE '^SCAN: verify-credential-inventory:runbook: 4$'
}

@test "direction ledger-to-table fires — this is the shape of the incident that motivated the gate" {
  # ★ 2026-08-21 실측: 원장에는 PR #511/#517로 두 행이 들어갔는데 런북 §A 표는 3건인 채였다.
  #   `check-credential-expiry.sh`는 원장 **안**만 보므로 이 방향에 대해 원리적으로 침묵한다.
  mk_rb '| ① | `aaa` | x |
| ② | `bbb` | y |
| ③ | `ccc` | z |' '**4건** 등재'
  run bash "$S" "$FX/rb.md" "$FX/led.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '원장에 있으나 런북 §A 표에 없다: ddd'
  # 바닥값이 이 방향을 **가리지 않았는지** 확인한다(스캔 3 ≥ 3이라 붕괴 판정이 아니다).
  run bash -c "bash '$S' '$FX/rb.md' '$FX/led.json' 2>&1 | grep -c '열거 붕괴' || true"
  [ "$output" -eq 0 ]
}

@test "direction table-to-ledger fires when the runbook names a credential the ledger lost" {
  mk_rb "$ALL4"'
| ⑤ | `eee` | v |' '**4건** 등재'
  run bash "$S" "$FX/rb.md" "$FX/led.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '런북 §A 표에 있으나 원장에 없다: eee'
}

@test "the hand-managed count is machine-compared instead of being deleted" {
  # 런북은 사람이 읽는 문서라 수치가 있는 편이 낫다 — 그러면 기계가 대조하게 만드는 것이 답이다.
  mk_rb "$ALL4" '**7건** 등재'
  run bash "$S" "$FX/rb.md" "$FX/led.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "런북이 '7건 등재'라 적었는데 원장은 4건이다"
}

@test "a missing count is a failure, not a pass — not finding it is not agreement" {
  mk_rb "$ALL4" '등재 상태는 아래 표 참조'
  run bash "$S" "$FX/rb.md" "$FX/led.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '수치를 찾지 못했다'
}

@test "an absent runbook signals SKIP with exit 4, never a silent success" {
  # ★ exit 0과 exit 4를 **절대 같게 쓰지 않는다.** CI에서는 항상 이 경로를 탄다.
  run bash "$S" "$FX/nonexistent.md" "$FX/led.json"
  [ "$status" -eq 4 ]
  echo "$output" | grep -qE '^SKIP: verify-credential-inventory: '
  # 마커를 냈으면 성공 메시지를 함께 내면 안 된다(사람이 정반대로 읽는다).
  # ⚠️ 성공 문장 전체로 대조한다 — `정합` 한 낱말만 세면 SKIP 메시지 자신이 걸려 이 단언이
  #    **다른 이유로** 판정된다(첫 판이 그랬다).
  run bash -c "bash '$S' '$FX/nonexistent.md' '$FX/led.json' 2>&1 | grep -c '양방향 정합 + 수치 일치 OK' || true"
  [ "$output" -eq 0 ]
}

@test "an unparseable ledger fails closed instead of comparing against nothing" {
  printf 'not json\n' > "$FX/bad.json"
  mk_rb "$ALL4" '**4건** 등재'
  run bash "$S" "$FX/rb.md" "$FX/bad.json"
  [ "$status" -ne 0 ]
  run bash -c "bash '$S' '$FX/rb.md' '$FX/bad.json' 2>&1 | grep -c '양방향 정합 + 수치 일치 OK' || true"
  [ "$output" -eq 0 ]
}

@test "an empty table collapses the enumeration instead of passing vacuously" {
  mk_rb '' '**4건** 등재'
  run bash "$S" "$FX/rb.md" "$FX/led.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '열거 붕괴'
}

@test "the gate is wired to a make target so it has an authority path on the owner machine" {
  # 이 가드는 CI에서 영원히 SKIP이므로, 권위는 owner-local make 진입점뿐이다. 그 배선을 문다.
  run bash -c "grep -c 'scripts/verify-credential-inventory.sh' '$ROOT/Makefile'"
  [ "$output" -ge 1 ]
}

@test "the live runbook and ledger actually agree (or the runbook is absent on this machine)" {
  # owner 머신에서만 실제 대조가 일어난다. CI/fresh checkout에서는 SKIP(4)이 정상이다.
  run bash "$S"
  [ "$status" -eq 0 ] || [ "$status" -eq 4 ]
}
