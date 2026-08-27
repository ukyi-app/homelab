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
# 왜 정적 하한 가드인가: 페이로드를 줄이는 길이 막혀 있다(13.1.0 프로브 기준 — 13.1.3에서 재확인
# 안 함: 13.1.x 사이에 preinstall 세트 자체가 바뀐다는 게 이번 실측이라, 킬스위치 동작도 태그 종속
# 주장이다). 기본 preinstall 목록은 바이너리에 컴파일돼 `GF_PLUGINS_PREINSTALL=""`로도 안 사라지고,
# 유일한 킬스위치 `GF_PLUGINS_PREINSTALL_DISABLED=true`는 요구한 VL 데이터소스까지 함께 제거한다
# (3종 프로브 실측).
# ⚠️ 한계: 정적 가드라 미래 업스트림 증가 자체는 못 잡는다 — 그건 emptyDir 사용률 관측이 담당해야 한다.
#
# 측정 앵커(followup-sweep 02): MEASURED_PAYLOAD_KIB는 **잰 시점의 이미지 태그**(MEASURED_AT_TAG)와
# 짝이다 — 태그만 올라가고 상수가 낡으면 가드가 옛 페이로드로 마진을 재는 죽은 가드가 된다
# (실측: 13.1.0→13.1.3 사이 재측정 없이 페이로드 +10.5%·preinstall에 zipkin 신규 — 커밋 0건 성장).
# 아래 @test가 grafana.yaml의 이미지 태그와 앵커 태그를 대조해 불일치를 red로 만든다.
# ⚠️ 이 대조는 **재측정을 강제하지 않는다** — 태그 한 줄만 고쳐도 초록이다. 강제하는 것은 bump가
# 이 파일을 반드시 지나가게 만드는 것까지고, du를 실제로 도는 것은 리뷰어의 규율이다(아래 절차).
#
# 재측정 절차(grafana bump PR마다 — 앵커 대조 red의 해소 경로):
#   1) 새 태그가 아직 배포 전이면 1Gi 프로브로 임시 실측. ⚠️ command/args를 덮지 않는다 —
#      grafana entrypoint가 돌아야 플러그인 다운로드가 일어나고, readinessProbe(/api/health)가
#      다운로드 완료의 프록시다(둘 중 하나라도 빠지면 "그럴듯하게 낮은" 앵커가 나온다 — 06 리뷰):
#      kubectl -n observability run grafana-probe --restart=Never --image=grafana/grafana:<newtag> \
#        --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"grafana-probe",
#        "image":"grafana/grafana:<newtag>","env":[{"name":"GF_INSTALL_PLUGINS","value":"victoriametrics-logs-datasource"}],
#        "readinessProbe":{"httpGet":{"path":"/api/health","port":3000}},
#        "volumeMounts":[{"name":"data","mountPath":"/var/lib/grafana"}]}],
#        "volumes":[{"name":"data","emptyDir":{"sizeLimit":"1Gi"}}]}}'
#      kubectl -n observability wait --for=condition=Ready pod/grafana-probe --timeout=600s
#      kubectl -n observability exec grafana-probe -- du -sk /var/lib/grafana
#      kubectl -n observability delete pod grafana-probe   # --rm이 아니므로 수동 정리(1Gi 파드 잔류 금지)
#      (--image와 override의 image가 같은 값을 두 번 말한다 — override가 이기지만 둘 다 새 태그로.)
#   2) 이미 라이브가 새 태그로 돌고 있으면 러닝 파드로 재도 된다 — 단 **러닝 이미지를 눈으로 확증**
#      한다(매니페스트 태그가 아니라 그 순간 돌고 있는 것을 재는 것이므로, 롤아웃 중이면 낡은 태그):
#      kubectl -n observability get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'
#      kubectl -n observability exec deploy/grafana -- du -sk /var/lib/grafana
#   3) MEASURED_PAYLOAD_KIB·MEASURED_AT_TAG·내역 주석을 같은 PR에서 갱신한다(상수만 올리고 실측을
#      건너뛰면 앵커가 거짓말이 된다 — 값의 출처는 언제나 du다).
#
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩), 중간 단언은 [ ]/run만(bash 3.2 [[ ]]·중간 `!` 침묵통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  D="$ROOT/platform/victoria-stack/prod"

  # 독립 실측치 — 2026-08-27, 라이브 grafana 13.1.3 러닝 파드에서 `du -sk /var/lib/grafana`
  # (512Mi 안에서 안정 가동 중이라 evict 없는 관측. ⚠️ 프로브와 완전 등가는 아니다 — 러닝 파드는
  #  dashboards configMap이 /var/lib/grafana/dashboards로 겹쳐 마운트돼 du가 그 tmpfs까지 세고
  #  grafana.db가 가동 중 자란다. 둘 다 **과대**계상 방향이고 합쳐 수 MiB 미만이라 마진 판정에는
  #  무영향 — 정밀 재측정이 필요하면 헤더의 프로브 경로를 쓴다). 내역:
  # victoriametrics-logs-datasource 213,648(단일 zip에 8개 플랫폼 백엔드 바이너리 동봉) +
  # preinstall 앱 5종 75,128(lokiexplore 18,136·pyroscope 11,900·exploretraces 9,888·
  # metricsdrilldown 9,224 + **zipkin 25,980 — 13.1.0→13.1.3 사이 신규**, 전부 미사용) +
  # grafana.db 등 1,604. 코드에서 재계산한 값이 아니라 라이브에서 잰 값이다.
  # (직전 앵커: 13.1.0 = 262,844 KiB — 세 패치 사이 +10.5%, 재측정 없이는 아무도 몰랐다.)
  MEASURED_PAYLOAD_KIB=290380
  MEASURED_AT_TAG=13.1.3

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

# grafana 매니페스트에서 이미지 태그(digest 앞 semver)를 뽑는다 — 부재·형식 밖은 fail-loud.
_grafana_image_tag() {
  local raw
  # 행두 앵커 — 주석에 직전 태그를 병기하는 이 레포의 습관("직전 앵커: 13.1.0" 류)이 이미지 줄
  # 위에 오면 head -1이 주석을 읽는다(06 리뷰 실측 클래스). 스트립은 ##(최장 매치)와 세트다.
  raw="$(grep -oE '^[[:space:]]*image: grafana/grafana:[0-9]+\.[0-9]+\.[0-9]+@' "$1" | head -1)"
  [ -n "$raw" ] || return 1
  raw="${raw##*grafana/grafana:}"
  printf '%s' "${raw%@}"
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

@test "the measurement anchor pins the image tag it was probed on (stale constant = red)" {
  # 앵커 태그 ≠ 배포 태그면 상수가 옛 이미지의 페이로드다 — 재측정(헤더 절차) 전에는 마진 판정이
  # 무의미하므로 red다. 13.1.0→13.1.3 drift가 이 대조 없이 조용히 지나갔던 것이 이 증인의 출생.
  run _grafana_image_tag "$D/grafana.yaml"
  [ "$status" -eq 0 ]
  echo "anchor=${MEASURED_AT_TAG} deployed=${output}"
  [ "$output" = "$MEASURED_AT_TAG" ]
}

@test "the anchor comparison rejects a bumped image against a stale anchor (red-green)" {
  tmp="$(mktemp -d)"
  printf '%s\n' '          image: grafana/grafana:99.0.0@sha256:feedbeef' > "$tmp/grafana.yaml"
  run _grafana_image_tag "$tmp/grafana.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "99.0.0" ]
  run test "$output" = "$MEASURED_AT_TAG"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "the extractor rejects any image line the anchor cannot compare (no pin, registry prefix, pre-release)" {
  # 앵커의 신뢰는 태그 문자열의 정확한 대조에 걸려 있다 — 모호하면 red가 정답이다(digest 없는 핀은
  # check-image-pins 레인1이 독립으로 막고 있어 여기서는 심층방어).
  tmp="$(mktemp -d)"
  for bad in 'image: grafana/grafana:latest' 'image: docker.io/grafana/grafana:13.1.3@sha256:x' 'image: grafana/grafana:13.2.0-rc1@sha256:x'; do
    printf '          %s\n' "$bad" > "$tmp/grafana.yaml"
    run _grafana_image_tag "$tmp/grafana.yaml"
    [ "$status" -ne 0 ]
  done
  rm -rf "$tmp"
}

@test "the extractor ignores a commented-out image line above the real one" {
  # 직전 값을 주석에 병기하는 습관과의 충돌 방어 — 행두 앵커가 없으면 head -1이 주석을 읽는다.
  tmp="$(mktemp -d)"
  printf '%s\n' '          # 직전: image: grafana/grafana:13.1.0@sha256:old' \
    '          image: grafana/grafana:13.1.3@sha256:new' > "$tmp/grafana.yaml"
  run _grafana_image_tag "$tmp/grafana.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "13.1.3" ]
  rm -rf "$tmp"
}
