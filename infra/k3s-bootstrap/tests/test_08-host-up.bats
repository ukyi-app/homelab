#!/usr/bin/env bats
load test_helper

setup() {
  WORK="$(mktemp -d)"; ORDER="$WORK/order.log"; export WORK ORDER
  # HOSTUP_BINDIR로 실제 하위 스크립트를 순서 기록 stub으로 가린다.
  # ⚠️ 이 시임이 host-up.sh의 **유일한** 테스트 가능성 원천이다 — 없으면 순서 계약을 라이브
  #    노드 없이는 증명할 수 없고, 그 순간 이 파일은 "실행해 본 적 없는 오케스트레이터"가 된다.
  mkdir -p "$WORK/bin"
  for s in host-preflight.sh k3s-install.sh apply-storage.sh verify-cluster.sh; do
    cat >"$WORK/bin/$s" <<EOF
#!/usr/bin/env bash
echo "$s" >> "$ORDER"; exit 0
EOF
    chmod +x "$WORK/bin/$s"
  done
  export HOSTUP_BINDIR="$WORK/bin"
}
teardown() { rm -rf "$WORK"; }

@test "runs sub-steps in order: preflight, install, storage, verify" {
  run "$BOOTSTRAP_DIR/host-up.sh"
  [ "$status" -eq 0 ]
  run cat "$ORDER"
  [ "${lines[0]}" = "host-preflight.sh" ]
  [ "${lines[1]}" = "k3s-install.sh" ]
  [ "${lines[2]}" = "apply-storage.sh" ]
  [ "${lines[3]}" = "verify-cluster.sh" ]
}

@test "preflight runs BEFORE the installer — a failing precondition must not install k3s" {
  # ⚠️ 이 순서가 이 파일에서 가장 비싼 계약이다. 타임존·resolved 스텁은 k3s가 뜬 **뒤에는**
  #    고치기 어렵다(고치러 들어가려면 이름해석이 필요한데 그게 바로 깨진 것이다 — §2.4 교착).
  #    그래서 "preflight가 목록에 있다"가 아니라 "**실패하면 설치가 안 일어난다**"를 단언한다.
  cat >"$HOSTUP_BINDIR/host-preflight.sh" <<'EOF'
#!/usr/bin/env bash
echo "host-preflight.sh" >> "$ORDER"; echo "FAIL: host-preflight: 타임존" >&2; exit 1
EOF
  chmod +x "$HOSTUP_BINDIR/host-preflight.sh"
  run "$BOOTSTRAP_DIR/host-up.sh"
  [ "$status" -ne 0 ]
  run cat "$ORDER"
  [ "${lines[0]}" = "host-preflight.sh" ]
  # 설치가 시작되지 않았어야 한다.
  run bash -c "grep -c 'k3s-install.sh' '$ORDER' || true"
  printf '%s' "$output" | grep -qx '0'
}

@test "no OrbStack step survives in the pipeline (bare metal has no VM layer)" {
  # orb-create/orb-guard 삭제의 회귀 가드. 문자열이 남아 있으면 없는 파일을 부르게 된다.
  # ⚠️ 이 @test에는 형제 단언이 없다 — `-ne 0`이던 동안에는 host-up.sh를 리네임해도(rc 2) 혼자
  #    초록으로 남아, 파이프라인 자체가 사라진 상태를 "OrbStack 잔재 없음"으로 읽었다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
  run grep -cE 'orb-(create|guard)' "$BOOTSTRAP_DIR/host-up.sh"
  [ "$status" -eq 1 ]
}
