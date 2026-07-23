#!/usr/bin/env bats
# setup-toolchain 다운로드 공급망 위생 — 모든 바이너리가 SHA256 검증을 거치고 age가 핀됐는가.
# TLS만 믿으면 미러/계정 침해 시 변조 바이너리가 gate 러너에서 실행된다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-toolchain/action.yml"; }

@test "age is pinned to a fixed version (not latest)" {
  # dl.filippo.io/age/latest 무핀 경로가 사라졌는가
  run grep -E 'dl\.filippo\.io/age/latest' "$A"
  [ "$status" -ne 0 ]
  # 고정 버전 자산(age-v...-linux-arm64.tar.gz)으로 받는가
  run grep -E 'age/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/age-v[0-9]' "$A"
  [ "$status" -eq 0 ]
}

@test "bats is pinned to a fixed version with a checksum (not apt)" {
  # bats만 apt(ports.ubuntu.com SPOF·무핀)였다 — required gate 경로라 다른 툴과 동일한 핀+체크섬으로 전환.
  # apt 설치 경로가 사라졌는가(재발 방지)
  run grep -E 'apt-get (update|install).*bats|install.*-y bats' "$A"
  [ "$status" -ne 0 ]
  # 고정 버전 소스 tarball(bats-core/archive/refs/tags/vX.Y.Z)로 받는가
  run grep -E 'bats-core/bats-core/archive/refs/tags/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$A"
  [ "$status" -eq 0 ]
}

@test "every download step verifies a sha256 checksum" {
  # 핀 도구 11종(yq/kubeconform/helm/kustomize/conftest/shellcheck/sops/age/kubeseal/actionlint/**bats**) 전부
  # sha256sum -c를 호출하는지 — 한 번이라도 누락이면 fail. **실제 호출**(`| sha256sum -c -`)만 센다 —
  # 설명 주석의 'sha256sum -c' 산문이 카운트를 부풀려 임계를 느슨하게 만들던 것(off-by-one)을 배제.
  n=$(grep -c '| sha256sum -c -' "$A")
  [ "$n" -ge 11 ]
}

@test "no checksum line is an obvious placeholder" {
  # 0000.../deadbeef/TODO/REPLACE 류 더미가 커밋되지 않았는지
  run grep -Ei 'REPLACE|TODO|deadbeef|^0{16}|[[:space:]]0{64}[[:space:]]' "$A"
  [ "$status" -ne 0 ]
}
