#!/usr/bin/env bats
# 회귀 가드 — grafana의 `data` emptyDir sizeLimit은 부팅 시 런타임 다운로드되는 플러그인 페이로드보다
# 충분히 커야 한다.
#
# 2026-07-25 라이브 사고: 선언 256Mi(262,144 KiB) vs 실측 페이로드 262,844 KiB로 0.27%(700 KiB) 초과 →
# kubelet이 emptyDir 초과 파드를 evict → grafana가 60초 주기로 부팅↔evict 무한 반복(파드 오브젝트 375개
# 누적), 파생 로그 스트림 폭증으로 victorialogs가 OOMKilled 연쇄. 노드 압박은 무관(DiskPressure=False).
# 도화선은 VM 재부팅(emptyDir 소멸 → 커진 플러그인 세트 재다운로드)이었고, 설정은 그 전부터 한계치의
# 99.7%에 붙어 있었다.
#
# 왜 정적 하한 가드인가: grafana 13.1.0에서 페이로드를 줄이는 길이 막혀 있다. 기본 preinstall 목록은
# 바이너리에 컴파일돼 `GF_PLUGINS_PREINSTALL=""`로도 안 사라지고, 유일한 킬스위치
# `GF_PLUGINS_PREINSTALL_DISABLED=true`는 우리가 요구한 VL 데이터소스까지 함께 제거한다(3종 프로브 실측).
# ⚠️ 한계: 정적 가드라 미래 업스트림 증가 자체는 못 잡는다 — 그건 emptyDir 사용률 관측이 담당해야 한다.
#
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩), 중간 단언은 [ ]/run만(bash 3.2 [[ ]]·중간 `!` 침묵통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  D="$ROOT/platform/victoria-stack/prod"

  # 독립 실측치 — 2026-07-25, grafana 13.1.0 프로브(emptyDir 1Gi로 띄워 evict 없이 관측)에서
  # `du -sk /var/lib/grafana`. 내역: victoriametrics-logs-datasource 0.30.1 = 213,400(단일 zip에 8개
  # 플랫폼 백엔드 바이너리 동봉 — arm64 1개만 사용) + grafana 내장 preinstall 앱 4종 47,872
  # (lokiexplore·pyroscope·exploretraces·metricsdrilldown, 전부 미사용) + grafana.db 등 1,572.
  # 코드에서 재계산한 값이 아니라 라이브에서 잰 값이다.
  MEASURED_PAYLOAD_KIB=262844

  # 요구 마진 1.5배. 업스트림 플러그인은 버전 핀이 불가하고 preinstall 앱은 매 부팅 최신으로 자동
  # 갱신(defaults.ini preinstall_auto_update=true)되므로 여유 없이는 같은 사고가 재발한다.
  MARGIN_NUM=3
  MARGIN_DEN=2
}

# grafana 매니페스트에서 `data` emptyDir의 sizeLimit을 KiB 정수로 뽑는다.
_grafana_data_sizelimit_kib() {
  local raw
  raw="$(grep -oE 'name: data, emptyDir: \{ sizeLimit: [0-9]+(Mi|Gi)' "$1" | grep -oE '[0-9]+(Mi|Gi)$')"
  [ -n "$raw" ] || return 1
  case "$raw" in
    *Mi) echo $(( ${raw%Mi} * 1024 ));;
    *Gi) echo $(( ${raw%Gi} * 1024 * 1024 ));;
    *) return 1;;
  esac
}

@test "grafana data emptyDir sizeLimit keeps margin over the measured plugin payload" {
  run _grafana_data_sizelimit_kib "$D/grafana.yaml"
  [ "$status" -eq 0 ]
  limit="$output"
  required=$(( MEASURED_PAYLOAD_KIB * MARGIN_NUM / MARGIN_DEN ))
  echo "declared=${limit} KiB / measured payload=${MEASURED_PAYLOAD_KIB} KiB / required>=${required} KiB"
  [ "$limit" -ge "$required" ]
}

@test "guard rejects the pre-incident 256Mi declaration (red-green)" {
  tmp="$(mktemp -d)"
  printf '        - { name: data, emptyDir: { sizeLimit: 256Mi } }\n' > "$tmp/grafana.yaml"
  run _grafana_data_sizelimit_kib "$tmp/grafana.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -eq 262144 ]
  required=$(( MEASURED_PAYLOAD_KIB * MARGIN_NUM / MARGIN_DEN ))
  # 사고 당시 값은 요구 마진에 미달해야 한다 — 미달이 아니면 이 가드는 죽은 가드다.
  run test "$output" -ge "$required"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "guard fails loudly when the data emptyDir declaration cannot be parsed" {
  tmp="$(mktemp -d)"
  printf '        - { name: data, emptyDir: {} }\n' > "$tmp/grafana.yaml"
  run _grafana_data_sizelimit_kib "$tmp/grafana.yaml"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}
