#!/usr/bin/env bash
# kubeconfig 정체성 각인 (D-i, 2026-08-12) — k3s가 만드는 기본 이름을 이 클러스터의 고유 이름으로
# 바꾸고, 필요하면 server URL도 재작성한다. 설치 경로와 소급 적용이 **같은 구현**을 쓴다.
#
# 왜 필요한가: k3s의 kubeconfig는 context·cluster·user가 전부 `default`다. 라이브 Mac 클러스터의
# kubeconfig도 같은 상대경로·같은 포트·같은 이름이고, #449 이후 k8s 노드명까지 `k3s`로 같아졌다.
# 그 상태에서 KUBECONFIG를 잘못 export하면 **조용히 반대편 클러스터를 때린다**.
# ⚠️ 이름만으로는 사고를 막지 못한다(레포에 --context 참조가 0건이다). 실제 차단은
#    assert-cluster-identity.sh가 이 이름을 읽어 라이브와 대조할 때 생긴다. 이 스크립트는 그 대조가
#    딛고 설 **텍스트 단서**를 만드는 것이 전부다.
#
# 왜 yq가 아니라 sed인가: 이 스크립트는 G11 콜드스타트(k3s-install.sh)의 경로에 있다. NUC의 yq는
# mise shim이고 mise 설정은 레포 밖 개인 dotfile이라 그 시점에 존재를 보장할 수 없다. sed는
# 프로비저닝 경로에 새 의존을 더하지 않는다.
# ⚠️ sed의 약점은 **0건 치환도 rc=0**이라는 것이다. 아래 사후 대조가 그 구멍을 닫는다.
#
# 사용: kubeconfig-identity.sh --file <path> --name <name> [--server <url>]
# 멱등: 이미 각인된 파일에 다시 돌려도 무변경으로 통과한다.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

FILE=""; NAME=""; SERVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)   FILE="${2:-}"; shift 2 ;;
    --name)   NAME="${2:-}"; shift 2 ;;
    --server) SERVER="${2:-}"; shift 2 ;;
    *) fail "알 수 없는 인자: $1 (허용: --file --name --server)" ;;
  esac
done
[ -n "$FILE" ] || fail "--file 누락"
[ -n "$NAME" ] || fail "--name 누락"
[ -f "$FILE" ] || fail "파일이 없다: $FILE"
[ -s "$FILE" ] || fail "파일이 비어 있다: $FILE"
# 이름은 sed 치환부에 들어간다 — 구분자(#)와 정규식 메타를 원천 배제한다.
case "$NAME" in
  *[!a-zA-Z0-9._-]*) fail "이름에 쓸 수 없는 문자가 있다: $NAME (허용: 영숫자 . _ -)" ;;
esac

# k3s가 만드는 기본 kubeconfig의 `default` 이름 필드는 정확히 6곳이다(라이브 실측):
#   clusters[].name · contexts[].context.cluster · contexts[].context.user · contexts[].name
#   · current-context · users[].name
# ⚠️ 필드를 **앵커로 못박는다** — `namespace: default` 같은 무관한 자리를 건드리지 않기 위해서다
#    (레포의 Mac 사본은 그 자리에 argocd를 갖고 있다. 값만 보고 치환하면 그런 파일에서 오작동한다).
DEFAULT_FIELDS='^(  name|- name|    cluster|    user|current-context): default$'
NAMED_FIELDS="^(  name|- name|    cluster|    user|current-context): ${NAME}\$"

before="$(grep -cE "$DEFAULT_FIELDS" "$FILE" || true)"
already="$(grep -cE "$NAMED_FIELDS" "$FILE" || true)"

case "${before}:${already}" in
  6:0) ;;                                     # 각인 전 — 정상 경로
  0:6) echo "==> kubeconfig 정체성: 이미 ${NAME} — 무변경(멱등)" ;;
  *) fail "kubeconfig 형태가 예상과 다르다 — default 이름 필드 ${before}건 · ${NAME} ${already}건(기대: 6:0 또는 0:6). 부분 각인이거나 clusters/users가 여러 벌인 파일이다. 손으로 확인하라: $FILE" ;;
esac

if [ "$before" = "6" ]; then
  # BSD/GNU 양쪽에서 도는 in-place 관용구(k3s-install.sh와 동형). 백업은 즉시 지운다.
  sed -i.bak -E \
    -e "s/^(  name): default\$/\1: ${NAME}/" \
    -e "s/^(- name): default\$/\1: ${NAME}/" \
    -e "s/^(    cluster): default\$/\1: ${NAME}/" \
    -e "s/^(    user): default\$/\1: ${NAME}/" \
    -e "s/^(current-context): default\$/\1: ${NAME}/" \
    "$FILE"
  rm -f "${FILE}.bak"
fi

# ── 사후 대조 — sed가 조용히 아무것도 안 했을 가능성을 여기서 닫는다 ──────────────────────
left="$(grep -cE "$DEFAULT_FIELDS" "$FILE" || true)"
[ "$left" = "0" ] || fail "이름 필드 ${left}건이 아직 default다 — 치환이 부분적으로만 먹었다: $FILE"
hits="$(grep -cE "$NAMED_FIELDS" "$FILE" || true)"
[ "$hits" = "6" ] || fail "${NAME} 이름 필드가 ${hits}건이다(기대 6) — 6필드가 모두 각인되지 않았다: $FILE"

if [ -n "$SERVER" ]; then
  # 노드 로컬은 127.0.0.1을 그대로 둔다(k3s는 tailscaled와 순서 관계가 없어 부팅 직후 tailscale0이
  # 없는 창이 있다). 원격에서 쓸 사본에만 이 인자를 준다 — 값은 SAN 안에 있어야 한다.
  sed -i.bak "s#server: https://127.0.0.1:6443#server: ${SERVER}#" "$FILE"
  rm -f "${FILE}.bak"
  grep -qF "server: ${SERVER}" "$FILE" || fail "server 재작성 실패 — ${SERVER}: $FILE"
fi

srv="$(sed -n 's/^    server: //p' "$FILE" | head -1)"
echo "==> kubeconfig 정체성 각인 완료: name=${NAME} server=${srv:-<없음>} ($FILE)"
