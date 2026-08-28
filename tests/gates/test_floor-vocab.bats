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

@test "an emission call before the last detect_run is rejected (precedence lane)" {
  # 마커는 "열거·바닥값을 통과했다"는 뜻인데, 검출기가 죽은 실행은 **아무것도 검사하지 못했다**.
  # 그런 실행이 마커를 내면 소비자가 정반대로 읽는다 — 착지 전 3가드가 정확히 그 형태였다(실측).
  # ⚠️ 원안은 `마지막 마커 줄 > 마지막 detect_run 줄`이었는데, 그 비교는 **이른 방출 하나 뒤에
  #    늦은 신호 하나**가 있기만 하면 만족한다. 그래서 **모든** 방출 콜사이트를 본다.
  printf '%s\n' '#!/usr/bin/env bash' \
    'scan_signal check-fake 3' \
    'findings="$(detect_run check-fake "$DETECT" "$@")"' \
    'scan_signal check-fake 3' > "$FX/early.sh"
  run bash "$S" "$FX/early.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "[P]"
}

@test "emission after the last detect_run is not a violation, and quiet judgment before it is fine" {
  # 음성 대조 — 판정(quiet)은 검출 **앞**에 있어도 된다. 억제는 출력 채널의 성질이지 판정의 성질이
  # 아니기 때문이다(scan-floor 커널 규약). 이 구별이 없으면 규칙이 정당한 형태를 위반으로 잡는다.
  printf '%s\n' '#!/usr/bin/env bash' \
    'scan_floor check-fake 3 1 quiet || exit 1' \
    'findings="$(detect_run check-fake "$DETECT" "$@")"' \
    'scan_signal check-fake 3' > "$FX/late.sh"
  run bash "$S" "$FX/late.sh"
  [ "$status" -eq 0 ]
}

@test "a quiet floor judgment without its later signal is rejected (pairing lane)" {
  # `scan_floor … quiet`는 **판정만** 한다 — 그 도메인의 마커는 뒤에서 반드시 나가야 한다.
  # 짝이 없으면 그 가드는 "검사했다고 주장하지 않는" 상태가 되고, 로스터 등식은 라벨이 준 것을
  # 붕괴로도 미실행으로도 읽지 못한다. 결합되지 않은 2단계 프로토콜의 fail-open이다.
  printf '%s\n' '#!/usr/bin/env bash' \
    'scan_floor check-fake:alpha 3 1 quiet || exit 1' \
    'findings="$(detect_run check-fake "$DETECT" "$@")"' \
    'scan_signal check-fake:beta 3' > "$FX/unpaired.sh"
  run bash "$S" "$FX/unpaired.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "[Q]"
}

@test "a quiet floor judgment with its matching signal is not a violation" {
  printf '%s\n' '#!/usr/bin/env bash' \
    'scan_floor check-fake:alpha 3 1 quiet || exit 1' \
    'findings="$(detect_run check-fake "$DETECT" "$@")"' \
    'scan_signal check-fake:alpha 3' > "$FX/paired.sh"
  run bash "$S" "$FX/paired.sh"
  [ "$status" -eq 0 ]
}
