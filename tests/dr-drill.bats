#!/usr/bin/env bats
# DR drill 스크립트(R5)의 안전 불변식을 오프라인에서 강제한다 — 라이브 파괴 없이.
sh=scripts/dr-drill.sh

@test "dr-drill exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

@test "dr-drill requires the out-of-band age key (R5 input that survives node loss)" {
  grep -q 'SOPS_AGE_KEY_FILE' "$sh"
  grep -q 'age key missing' "$sh"
}

@test "dr-drill PROVES recoverability BEFORE any destruction (refuses to destroy otherwise)" {
  # 파괴 전 복구 증명이 'orb delete'보다 먼저 와야 한다 — 핵심 안전 불변식.
  proof_line=$(grep -n 'DR ABORT: 파괴 전 복구 실패' "$sh" | head -1 | cut -d: -f1)
  destroy_line=$(grep -n 'orb delete -f k3s' "$sh" | head -1 | cut -d: -f1)
  [ -n "$proof_line" ] && [ -n "$destroy_line" ]
  [ "$proof_line" -lt "$destroy_line" ]
}

@test "dr-drill takes a VERIFIED backup (waits for completed, not a fixed sleep)" {
  grep -q 'kind: Backup' "$sh"
  grep -q 'completed' "$sh"
  grep -q 'COMPLETE되지 않음' "$sh"
}

@test "dr-drill destroys the VM (cattle) and rebuilds from committed cloud-init" {
  grep -q 'orb delete -f k3s' "$sh"
  grep -q 'infra/k3s-bootstrap/host-up.sh' "$sh"
  grep -q 'make bootstrap' "$sh"
}

@test "dr-drill recovers the DB from R2 on the rebuilt node and checks the canary" {
  grep -q 'recovery:' "$sh"
  grep -q 'barmanObjectName: pg-r2' "$sh"
  grep -q 'restore_canary' "$sh"
  grep -q 'DR DRILL FAIL: recovered canary' "$sh"
}

@test "dr-drill uses drill-ssd (Delete reclaim) so verify clusters never leak storage" {
  grep -q 'storageClass: drill-ssd' "$sh"
  grep -q 'delete pvc' "$sh"
}

@test "dr-drill re-exports KUBECONFIG after the VM is rebuilt" {
  # host-up.sh가 kubeconfig를 재생성하므로 재구축 후 재export가 없으면 stale 컨텍스트로 죽는다.
  grep -q 'use_live_kubeconfig # host-up.sh가 kubeconfig를 재생성한다' "$sh"
}

@test "dr-drill prints the canonical PASS marker only at the very end" {
  grep -q 'DR DRILL PASS' "$sh"
  [ "$(grep -c 'DR DRILL PASS' "$sh")" -eq 1 ]
  [ "$(tail -1 "$sh" | grep -c 'DR DRILL PASS')" -eq 1 ]
}
