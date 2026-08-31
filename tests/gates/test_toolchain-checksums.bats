#!/usr/bin/env bats
# setup-toolchain 다운로드 공급망 위생 — 모든 바이너리가 SHA256 검증을 거치고 age가 핀됐는가.
# TLS만 믿으면 미러/계정 침해 시 변조 바이너리가 gate 러너에서 실행된다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

# ⚠️ 검사 도메인(action.yml)이 실재하는지 setup에서 닫는다 — 아래 부재 단언은 전부 이 한 파일을 읽는다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-toolchain/action.yml"; [ -f "$A" ]; }

@test "age is pinned to a fixed version (not latest)" {
  # dl.filippo.io/age/latest 무핀 경로가 사라졌는가
  run grep -E 'dl\.filippo\.io/age/latest' "$A"
  # ⚠️ `-ne 0`은 grep rc 2(대상 파일 부재/읽기불가)도 통과로 읽는다 — 무매치는 정확히 rc 1이다.
  [ "$status" -eq 1 ]
  # 고정 버전 자산(age-v...-linux-arm64.tar.gz)으로 받는가
  run grep -E 'age/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/age-v[0-9]' "$A"
  [ "$status" -eq 0 ]
}

@test "bats is pinned to an immutable commit SHA (not apt, not an unstable auto-generated archive)" {
  # bats만 apt(ports.ubuntu.com SPOF)였다. bats-core는 업로드 릴리스 에셋이 없고, GitHub 자동생성
  # 아카이브(/archive/refs/tags/)는 압축 재생성으로 체크섬이 변할 수 있어(R-1, 문서화된 불안정) required
  # gate를 깰 위험이 있다 → 불변 커밋 SHA로 clone+검증한다(git 객체 content-addressed, fetch 시 git이 SHA 검증).
  # apt 설치 경로 부재(원 SPOF 재발 차단)
  run grep -E 'apt-get (update|install).*bats|install.*-y bats' "$A"
  [ "$status" -eq 1 ]   # rc 2(대상 부재)를 통과로 읽지 않는다
  # 불안정 자동생성 아카이브 경로 부재(R-1 재발 차단)
  run grep -E 'bats-core/bats-core/archive/' "$A"
  [ "$status" -eq 1 ]   # rc 2(대상 부재)를 통과로 읽지 않는다
  # bats-core를 clone하고 HEAD를 고정 40-hex 커밋 SHA와 대조 검증하는가(content-addressed 불변 핀)
  run grep -E 'git clone .*github\.com/bats-core/bats-core' "$A"
  [ "$status" -eq 0 ]
  run grep -E 'rev-parse HEAD' "$A"
  [ "$status" -eq 0 ]
  # 커밋 SHA 대조 — `= "<40hex>"` 앵커로 sha256(64-hex echo)와 구분. 40 정확(태그 이동 시 fail-closed 근거)
  run grep -E '= "[0-9a-f]{40}"' "$A"
  [ "$status" -eq 0 ]
}

@test "no workflow installs a toolchain binary via apt (the composite pin is the only path)" {
  # composite만 검사하면 **워크플로가 자기 손으로 apt를 부르는 경로**가 열린 채 남는다 — 실측:
  # #372가 setup-toolchain의 apt bats를 커밋 SHA 핀으로 바꿨는데 iac.yaml만 마이그레이션에서 빠져
  # `sudo apt-get install -y bats`가 그대로 있었고, 위 @test는 composite만 보므로 초록이었다.
  # arm64 러너의 ports.ubuntu.com은 미러 SPOF다(2026-07-16 실장애 — 그 워크플로 실패 2건의 유일 원인).
  # 도구는 setup-toolchain 한 곳에서만 온다: 그래야 핀·체크섬 규율이 실제로 전 경로를 덮는다.
  run bash -c "git ls-files '.github/workflows/*.yaml' '.github/actions/**' | xargs grep -nE 'apt-get +(install|update)' || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "워크플로/액션이 apt로 도구를 깐다 — setup-toolchain(핀+체크섬)을 쓸 것:"
    printf '%s\n' "$output"
    false
  }
}

@test "every download step verifies a sha256 checksum" {
  # sha256 핀 도구 10종(yq/kubeconform/helm/kustomize/conftest/shellcheck/sops/age/kubeseal/actionlint) 전부
  # sha256sum -c를 호출하는지 — 한 번이라도 누락이면 fail. **실제 호출**(`| sha256sum -c -`)만 센다 —
  # 설명 주석의 'sha256sum -c' 산문이 카운트를 부풀려 임계를 느슨하게 만들던 것(off-by-one)을 배제.
  # (bats는 업로드 에셋이 없어 sha256이 아니라 위의 커밋-SHA 핀으로 검증 — 이 10종에 포함되지 않는다.)
  n=$(grep -c '| sha256sum -c -' "$A")
  [ "$n" -ge 10 ]
}

@test "no checksum line is an obvious placeholder" {
  # 0000.../deadbeef/TODO/REPLACE 류 더미가 커밋되지 않았는지
  run grep -Ei 'REPLACE|TODO|deadbeef|^0{16}|[[:space:]]0{64}[[:space:]]' "$A"
  # 이 @test는 부정 단언 하나뿐이다 — rc 2(대상 부재)가 통과가 되면 검사가 통째로 vacuous해진다.
  [ "$status" -eq 1 ]
}
