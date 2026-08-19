#!/usr/bin/env bash
# 레포가 핀한 **모든** 이미지 digest가 레지스트리에 아직 실재하는지 확인한다.
#
# 병(2026-08-18 라이브): `quay.io/skopeo/stable:v1.22.2@sha256:c7d3c512…`의 매니페스트가 quay.io에서
# **사라졌다**(태그는 200, 핀한 digest는 404). 업스트림이 릴리스된 태그를 재푸시하면서 옛 매니페스트가
# GC된 것이다. 결과:
#   · CI  — 모든 PR의 gate가 red. 그런데 신호가 skopeo **타임아웃 스모크**의 `HARNESS FAULT`라
#           "왜 red인지"를 사람이 역추적해야 했다(실제로 두 번 재실행하고 나서야 원인에 닿았다).
#   · 라이브 — CronJob 2개(digest-exporter · gha-liveness-exporter)가 **노드 이미지 캐시 덕에** 계속
#           돌고 있었다. 캐시가 정리되거나 DR로 재구축하면 그때 영구히 못 뜬다(가장 늦게 아는 경로).
#
# ⚠️ **기존 감시는 이 축을 원리적으로 못 본다.** `digest-exporter`/`ImageDigestDrift`가 묻는 것은
#    "우리 빌드가 실행 중 파드에 반영됐나"(R6 write-back staleness)이고, 대상도 `ghcr.io/ukyi-app/*`
#    자체 빌드 앱뿐이다. 서드파티 핀(skopeo·grafana·victoria-*·pause…)은 아예 범위 밖이다.
#    그래서 여기서 **존재 여부**를 전 핀에 대해 직접 묻는다.
#
# fail / fault 구분(레포 규약):
#   · 404          → fail. 확정적이다. 핀이 죽었고 재핀 외에 방법이 없다.
#   · 그 밖의 실패 → fault(exit 2). 레지스트리 장애·토큰 실패를 "핀이 죽었다"로 오귀속하지 않는다.
#                    ⚠️ 다만 조용히 넘기지도 않는다 — 결론을 못 낸 것도 red다(fail-open 금지).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

fault() { echo "HARNESS FAULT: $*" >&2; exit 2; }
FAILED=0
fail() { echo "FAIL $*" >&2; FAILED=$(( FAILED + 1 )); }

command -v curl >/dev/null || fault "curl 부재"
command -v python3 >/dev/null || fault "python3 부재"

ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# 열거: 추적 파일의 `<name>:<tag>@sha256:<64hex>`. 테스트 픽스처는 제외한다 —
# 그쪽 digest는 `1111…`처럼 의도적으로 가짜라 실재하지 않는 것이 정상이다.
# ⚠️ 제외를 경로로만 하지 말 것: `tools/tests/`처럼 tests가 중간에 오는 경우가 있다.
PINS="$(git grep -noE '[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9._-]+@sha256:[a-f0-9]{64}' -- . \
        | grep -vE '(^|/)tests?/|test_[^/]*\.bats|\.example' \
        | sed 's/^\([^:]*\):[0-9]*:/\1\t/' | sort -u -k2)"

# ⚠️ 열거 0건은 통과가 아니다 — 정규식이 안 물었다는 뜻이다(핀이 사라졌을 리 없다).
[ -n "$PINS" ] || fault "digest 핀을 하나도 못 찾았다 — 열거가 붕괴했다(가드가 무측정이 된다)"
N="$(printf '%s\n' "$PINS" | grep -c .)"
[ "$N" -ge 10 ] || fault "digest 핀이 ${N}건뿐이다 — 바닥값(10) 미만이라 열거를 믿을 수 없다"

CHECKED=0
while IFS=$'\t' read -r file ref; do
  [ -n "$ref" ] || continue
  digest="${ref##*@}"; np="${ref%@*}"; name="${np%:*}"

  case "$name" in
    *.*/*) reg="${name%%/*}"; repo="${name#*/}" ;;   # 레지스트리 호스트가 명시된 형태
    */*)   reg="docker.io";   repo="$name" ;;
    *)     reg="docker.io";   repo="library/$name" ;;
  esac
  case "$reg" in
    docker.io)       auth="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull"; host="registry-1.docker.io" ;;
    ghcr.io)         auth="https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull";                   host="ghcr.io" ;;
    quay.io)         auth="https://quay.io/v2/auth?service=quay.io&scope=repository:${repo}:pull";                 host="quay.io" ;;
    registry.k8s.io) auth=""; host="registry.k8s.io" ;;                                                            # 익명 pull
    *)               fault "미지원 레지스트리 ${reg} (${name}) — 검사 도메인 밖이면 가드가 조용히 좁아진다. 이 스크립트에 인증 흐름을 추가할 것" ;;
  esac

  # 일시 오류(토큰 실패·5xx·타임아웃)는 재시도로 걸러 낸다 — 26건짜리 검사에서 한 번의 딸꾹질이
  # PR을 막으면 이 가드가 곧 무시된다.
  code=""
  for attempt in 1 2 3; do
    tok=""
    if [ -n "$auth" ]; then
      tok="$(curl -s --max-time 20 "$auth" | python3 -c "import json,sys
try:
  d = json.load(sys.stdin); print(d.get('token') or d.get('access_token') or '')
except Exception:
  print('')" 2>/dev/null)"
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 25 \
              ${tok:+-H "Authorization: Bearer $tok"} -H "Accept: ${ACCEPT}" \
              "https://${host}/v2/${repo}/manifests/${digest}")"
    case "$code" in 200|404) break ;; esac
    sleep $(( attempt * 2 ))
  done

  CHECKED=$(( CHECKED + 1 ))
  case "$code" in
    200) ;;
    404)
      # 재핀 후보를 같이 알려 준다 — 태그가 살아 있으면 그 digest가 답이다.
      now="$(curl -sI -L --max-time 25 ${tok:+-H "Authorization: Bearer $tok"} -H "Accept: ${ACCEPT}" \
               "https://${host}/v2/${repo}/manifests/${np##*:}" \
               | grep -i '^docker-content-digest' | tr -d '\r' | awk '{print $2}')"
      fail "핀한 digest가 레지스트리에 없다: ${ref}
      파일: ${file}
      → 태그 ${np##*:}의 현재 digest: ${now:-(태그도 없음 — 업스트림이 릴리스를 내렸다)}
      상류가 릴리스된 태그를 재푸시해 옛 매니페스트가 GC된 것이다. 재핀하면 된다." ;;
    *)
      fault "${name} 검사 결론 실패(HTTP ${code:-없음}, 3회 시도) — 레지스트리 장애/네트워크일 수 있다.
      이것을 '핀이 죽었다'로 읽지 말 것. 다만 결론을 못 낸 것도 통과가 아니다." ;;
  esac
done <<EOF
$PINS
EOF

[ "$CHECKED" -eq "$N" ] || fault "열거 ${N}건 중 ${CHECKED}건만 검사됐다 — 루프가 조용히 건너뛰었다"
[ "$FAILED" -eq 0 ] || { echo "image-pin-liveness: ${FAILED}건 실패 / ${CHECKED}건 검사" >&2; exit 1; }
echo "image-pin-liveness OK (핀 ${CHECKED}건 전부 레지스트리에 실재한다)"
