#!/usr/bin/env bats
# DR 자산 신선도 posture — 라이브 전용 검증 3종을 한 자리에서 판정한다(owner-local `make verify-posture`).
# 2026-09-03 감사 2라운드 실측: 세 검증이 전부 owner 수동 호출뿐이라 21일간 (1) committed cert가 라이브
# active cert와 불일치(secret-cert-check STALE → seal-batch가 `make seal-*` 전부 차단) (2) sealing key 백업이
# 라이브 키 셋보다 오래됨(dr-drill [0.6] abort · 재구축 직후 컨트롤러가 만든 active 키는 무백업) (3) 런북
# tarball 백업이 편집보다 오래됨 — 아무 신호도 없었다. 판정처가 하나도 없어 "돌린 적 없는 검증"이 됐던 자리다.
# ⚠️ 백업 경로는 git 밖(owner 매체)이라 env로 받는다. 미설정은 skip이 아니라 **red**다 — dr-drill.sh가
#    SEALED_KEY_BACKUP_DIR을 같은 규약으로 요구한다(값 부재 = 검증 불가 = 실패, 조용한 통과 금지).
#    예: SEALED_KEY_BACKUP_DIR=<git 밖>/sealed-secrets LOCAL_ASSET_BACKUP_DIR=<git 밖>/local-asset make verify-posture
# LIVE: KUBECONFIG + kubeseal(--fetch-cert) + sops/age 키. @test 이름은 영어.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "the committed sealing cert matches the live controller cert (seal path is not silently blocked)" {
  run bash scripts/secret-cert-check.sh
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'secret-cert-check OK'
}

@test "the latest sealing key backup contains the live key set (dr-drill [0.6] precondition)" {
  [ -n "${SEALED_KEY_BACKUP_DIR:-}" ]   # 미설정 = red (dr-drill.sh와 같은 규약)
  run bash scripts/backup-sealed-secrets-key.sh --verify "$SEALED_KEY_BACKUP_DIR"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '라이브 sealing key 셋과 일치'
}

@test "the latest runbook backup matches the current runbook set (local asset backup chain)" {
  [ -n "${LOCAL_ASSET_BACKUP_DIR:-}" ]
  run bash scripts/backup-local-asset.sh --verify "$LOCAL_ASSET_BACKUP_DIR"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '현재 런북과 일치'
}
