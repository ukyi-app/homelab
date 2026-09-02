#!/usr/bin/env bats
# secret-cert-check.sh — 봉인 전 preflight. 커밋된 sealed-secrets cert가 라이브 컨트롤러 cert와
# fingerprint로 일치하는지. 불일치(stale)면 새 봉인본을 컨트롤러가 복호 못 한다 → 봉인 전 차단.
# kubeseal을 스텁해 fingerprint 비교 로직을 오프라인 검증(seal-secret.bats 선례).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  # 대상 실재를 setup에서 닫는다 — 선택 실행(`bats -f`)에서도 부재가 초록으로 읽히지 않게(operand-witness 05 (b)).
  [ -f "$ROOT/scripts/secret-cert-check.sh" ]
  TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"
  # 두 개의 자체서명 cert(A=committed 픽스처, B=다른 라이브)
  openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out "$TMP/certA.pem" -days 1 -nodes -subj "/CN=a" 2>/dev/null
  openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out "$TMP/certB.pem" -days 1 -nodes -subj "/CN=b" 2>/dev/null
}
teardown() { rm -rf "$TMP"; }

stub_kubeseal() { # $1: cat할 cert 파일(없으면 exit 1로 fetch 실패 모사)
  if [ -n "${1:-}" ]; then printf '#!/bin/sh\ncat %q\n' "$1" > "$TMP/bin/kubeseal"
  else printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/kubeseal"; fi
  chmod +x "$TMP/bin/kubeseal"
}

@test "passes when committed cert matches the live controller cert" {
  stub_kubeseal "$TMP/certA.pem"
  PATH="$TMP/bin:$PATH" run bash scripts/secret-cert-check.sh --cert "$TMP/certA.pem"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "OK"
}

@test "fails (stale) when committed cert differs from live controller cert" {
  stub_kubeseal "$TMP/certB.pem"
  PATH="$TMP/bin:$PATH" run bash scripts/secret-cert-check.sh --cert "$TMP/certA.pem"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE "STALE|불일치"
}

@test "skips with a distinct exit 4 when the live cert cannot be fetched (offline)" {
  # exit 0(검증됨)·1(stale)과 구분되는 SKIP 신호 → 자동화가 fail-open을 '검증됨'으로 오인하지 않음.
  # 4는 규약(CONTRIBUTING '가드 skip 신호') — 예전 2는 아래 unknown-option과 같은 코드였다.
  stub_kubeseal ""
  PATH="$TMP/bin:$PATH" run bash scripts/secret-cert-check.sh --cert "$TMP/certA.pem"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "^SKIP: secret-cert-check:"
}

@test "an unknown option still exits 2 (usage), distinct from the skip code" {
  run bash scripts/secret-cert-check.sh --bogus
  [ "$status" -eq 2 ]
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "never prints private key material" {
  stub_kubeseal "$TMP/certA.pem"
  PATH="$TMP/bin:$PATH" run bash scripts/secret-cert-check.sh --cert "$TMP/certA.pem"
  # ⚠️ rc 단언이 없으면 스크립트가 **누출 경로에 닿기 전에** 죽어도(대상 부재 rc 127 등) 부재 판정이 참이 된다.
  # 정상 경로의 계약은 성공이다(:22 레인이 같은 인자로 0을 단언한다).
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "PRIVATE KEY"
}
