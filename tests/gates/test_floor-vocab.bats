#!/usr/bin/env bats
# 바닥값 어휘 거부 가드(scripts/check-floor-vocab.sh, kernel-followups 04)의 gate 테스트.
#
# 병: 01~03·05가 구 어휘(--min-* 플래그·*_MIN_* env 폴백 읽기)를 --floor 하나로 접었지만,
# 재유입을 막는 것은 관례뿐이었다 — env 바닥값이 되살아나도 라벨 집합은 불변이라 로스터 등식·
# 선언⊆방출 대조 모두 침묵한다(03 리뷰 실측: "04가 유일한 문"). 인식이 아니라 거부가 문을 닫는다
# (check-scan-producers 선례).
# ⚠️ @test 이름은 영어 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/check-floor-vocab.sh"
  FX="$BATS_TEST_TMPDIR"
}

@test "check-floor-vocab passes on the current tree and reaches its domain" {
  run bash "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-floor-vocab: [0-9]{2,}$'
}

@test "a shell --min flag parser is rejected (retired vocabulary resurrection)" {
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in --min-scan) MIN=$2 ;; esac' > "$FX/old-flag.sh"
  run bash "$S" "$FX/old-flag.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "[F]"
}

@test "a shell env-fallback floor read is rejected (invisible knob resurrection)" {
  printf '%s\n' '#!/usr/bin/env bash' 'MIN="${FOO_MIN_SCAN:-10}"' > "$FX/old-env.sh"
  run bash "$S" "$FX/old-env.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "[E]"
}

@test "a TS --min flag registration is rejected" {
  printf '%s\n' 'const flags = typedFlags(argv, { value: ["--min-refs"], bool: [] });' > "$FX/old-flag.ts"
  run bash "$S" "$FX/old-flag.ts"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "[F]"
}

@test "a TS process.env floor read is rejected" {
  printf '%s\n' 'const n = Number(process.env.DISK_CAP_MIN_FLAGS ?? "2");' > "$FX/old-env.ts"
  run bash "$S" "$FX/old-env.ts"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "[E]"
}

@test "constants, local reads, --floor and comments are not violations (the legitimate line)" {
  # 정당 보유처 — 상수 정의·지역 변수 읽기(폴백 없음)·--floor 어휘·주석 산문(05 인계의 선).
  printf '%s\n' '#!/usr/bin/env bash' 'MIN_SCAN=20' 'n="$MIN_SCAN"' \
    'take_floors "demo" "$@" || exit $?' 'm="$(floor_of demo 3)"' \
    '# 옛 어휘 --min-scan 은 폐지됐다(산문 언급일 뿐)' > "$FX/ok.sh"
  run bash "$S" "$FX/ok.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' 'const MIN_STEPS = 19;' '// 구 --min-scan 폐지 경위 산문' 'const m = MIN_STEPS;' > "$FX/ok.ts"
  run bash "$S" "$FX/ok.ts"
  [ "$status" -eq 0 ]
}

@test "the enumeration floor fires when the scan domain collapses" {
  run bash "$S" --floor check-floor-vocab=99999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "the guard scans itself clean (assembled patterns need no self-exclusion)" {
  run bash "$S" "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^SCAN: check-floor-vocab: 1$"
}

@test "MIN embedded in another word is not a floor knob (ADMIN, MINIO stay green)" {
  # 리뷰 실측(H1) — 부분문자열 매치였다면 자격증명 시딩류가 엉뚱한 진단으로 red가 났다.
  printf '%s\n' '#!/usr/bin/env bash' 'p="${GRAFANA_ADMIN_PASSWORD:-x}"' 'u="${MINIO_ROOT_USER:-m}"' 't="${SLEEP_MINUTES:-5}"' > "$FX/edge-ok.sh"
  run bash "$S" "$FX/edge-ok.sh"
  [ "$status" -eq 0 ]
}

@test "all three fallback spellings of an env floor read are rejected (:-, -, :=)" {
  # 리뷰 실측(H2) — 병의 근거는 폴백 표기가 아니라 "환경에서 온다"다. 한 표기만 보면 같은 뜻의
  # 재작성이 통과한다.
  printf '%s\n' '#!/usr/bin/env bash' 'a="${FOO_MIN_SCAN-10}"' > "$FX/fb1.sh"
  run bash "$S" "$FX/fb1.sh"; [ "$status" -eq 1 ]
  printf '%s\n' '#!/usr/bin/env bash' ': "${FOO_MIN_SCAN:=10}"' > "$FX/fb2.sh"
  run bash "$S" "$FX/fb2.sh"; [ "$status" -eq 1 ]
}

@test "tail comments and TS block comments are prose, not violations" {
  # 03 인계의 선("산문·주석 잔존은 04의 주석-제외 규율상 영구 밖") — 형제 check-scan-producers의
  # 주석 표면(행두·블록·꼬리)을 승계했다.
  printf '%s\n' '#!/usr/bin/env bash' 'n=1   # 구 --min-scan 폐지 산문' > "$FX/tail.sh"
  run bash "$S" "$FX/tail.sh"; [ "$status" -eq 0 ]
  printf '%s\n' '/**' ' * 구 --min-registry 폐지 경위와 ${FOO_MIN_SCAN:-10} 인용.' ' */' 'const x = 1;' > "$FX/block.ts"
  run bash "$S" "$FX/block.ts"; [ "$status" -eq 0 ]
}
