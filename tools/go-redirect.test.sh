#!/usr/bin/env bash
# platform/go 리다이렉트 규칙 시험(T08c, 설계 C.3.5 "짧은 주소"). 차트를 운영·VM 값으로 렌더해 그 ConfigMap·init 스크립트·
# 이미지·명령을 그대로 컨테이너로 띄우고 curl로 본다. 규칙을 따로 흉내 내지 않으므로 렌더한 설정 자체를 시험한다.
#
# bun run ci에 넣지 않는다. 이미지를 Docker Hub에서 받아야 하는데 외부 레지스트리 조회는 필수 검사 밖이다(설계 C.4.6, P27).
# platform/go의 규칙(configmap.yaml), init 검사·명령(deployment.yaml), 이미지를 바꾸면 로컬에서 돌리고 결과를 PR에 적는다.
# 쓰는 도구: helm, yq(.tool-versions), curl, podman 또는 docker(환경변수 CONTAINER로 고른다).
set -euo pipefail
export LC_ALL=C

cd "$(dirname "$0")/.."
engine=${CONTAINER:-$(command -v podman || command -v docker || true)}
[[ -n $engine ]] || { echo "go-redirect.test.sh: podman이나 docker가 필요하다" >&2; exit 1; }

# 가짜 tailnet 도메인. 실제 tailnet 이름은 저장소에 두지 않는다(D-23).
domain=example-tailnet.ts.net
# 로그에 남으면 안 되는 표시(경로·쿼리).
marker=tok-0b7e5c-marker

t=$(mktemp -d)
names=()
cleanup() {
  for n in "${names[@]}"; do "$engine" rm -f "$n" >/dev/null 2>&1 || true; done
  rm -rf "$t"
}
trap cleanup EXIT

fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# 렌더 결과에서 컨테이너 실행 재료를 꺼낸다. $1: 접두, $2: 이름.
render() {
  local dir="$t/$2"
  mkdir -p "$dir/tmpl"
  helm template go platform/go --namespace go --set-string "tailscale.prefix=$1" >"$dir/render.yaml"
  yq 'select(.kind == "ConfigMap") | .data["nginx.conf.tmpl"]' "$dir/render.yaml" >"$dir/tmpl/nginx.conf.tmpl"
  yq 'select(.kind == "Deployment") | .spec.template.spec.initContainers[0].args[0]' "$dir/render.yaml" >"$dir/init.sh"
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$dir/render.yaml" >"$dir/image"
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].command[]' "$dir/render.yaml" >"$dir/command"
  chmod -R a+rX "$dir"
}

# 파드와 같은 제약(uid 101, 읽기 전용 루트, 권한 없음, /tmp·/run/go만 쓰기)으로 init 스크립트를 돌린다.
# $1: TAILNET_DOMAIN 값("<unset>"이면 env를 넘기지 않는다). 나머지 인자는 init 뒤 exec할 명령(없으면 init만).
# DETACH=1이면 백그라운드로 띄운다.
pod() {
  local dom=$1
  shift
  local opts=(--user 101:101 --read-only --cap-drop ALL --security-opt no-new-privileges
    --tmpfs "/tmp:rw,mode=1777" --tmpfs "/run/go:rw,mode=1777" -v "$t/$cluster/tmpl:/etc/go:ro")
  [[ $dom == "<unset>" ]] || opts+=(-e "TAILNET_DOMAIN=$dom")
  if [[ ${DETACH:-} == 1 ]]; then
    opts+=(-d --name "go-test-$cluster-$$" -p 127.0.0.1::8080)
  else
    opts+=(--rm)
  fi
  local script
  script=$(cat "$t/$cluster/init.sh")
  [[ $# -eq 0 ]] || script+=$'\nexec "$@"'
  "$engine" run "${opts[@]}" --entrypoint /bin/sh "$(cat "$t/$cluster/image")" -ec "$script" go-init "$@"
}

# 렌더한 Deployment의 명령 그대로 nginx를 띄운다.
start() {
  local cmd
  mapfile -t cmd <"$t/$cluster/command"
  names+=("go-test-$cluster-$$")
  DETACH=1 pod "$domain" "${cmd[@]}" >/dev/null
}

# 시작 검사: 실패해야 하는 값. 값 자체가 출력에 나오지 않아야 한다.
startup_rejects() {
  local label=$1 dom=$2 out code=0
  out=$(pod "$dom" 2>&1) || code=$?
  if [[ $code -eq 0 ]]; then
    bad "[$cluster] 시작 검사가 $label 값을 받았다"
  # ".ts.net"은 오류 문구에 그대로 들어 있어 값 노출 검사에서 뺀다.
  elif [[ $dom != "<unset>" && $dom != ".ts.net" && -n $dom && $out == *"$dom"* ]]; then
    bad "[$cluster] 시작 검사가 값($label)을 출력했다"
  else
    ok "[$cluster] 시작 검사 거부: $label"
  fi
}

port_of() { "$engine" port "go-test-$1-$$" 8080 | head -1 | sed 's/.*://'; }

wait_ready() {
  local p=$1
  for _ in $(seq 1 50); do
    curl -fsS -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# $1: 경로(원문 그대로 보낸다), $2: 기대 상태, $3: 기대 Location(없으면 "-").
expect() {
  local path=$1 want_code=$2 want_loc=$3 got code loc
  # 구분자는 탭이 아니라 |다. 탭은 IFS 공백이라 빈 Location 칸이 합쳐진다.
  got=$(curl -s -o /dev/null --path-as-is -w '%{http_code}|%header{location}|%header{cache-control}' "http://127.0.0.1:$port$path")
  IFS='|' read -r code loc cc <<<"$got"
  loc=${loc:--}
  if [[ $code == "$want_code" && $loc == "$want_loc" ]]; then
    ok "[$cluster] $path → $code $loc"
  else
    bad "[$cluster] $path → $code $loc (기대 $want_code $want_loc)"
  fi
  if [[ $code == 302 && $cc != "no-store" ]]; then bad "[$cluster] $path 302에 Cache-Control: no-store가 없다($cc)"; fi
}

label() { printf 'a%.0s' $(seq 1 "$1"); }
url() { printf 'https://%s%s.%s' "$prefix" "$1" "$domain"; }

for cluster in prod vm; do
  case $cluster in
    prod) prefix="" ;;
    vm) prefix="vm-" ;;
  esac
  render "$prefix" "$cluster"
  max=$((63 - ${#prefix}))

  startup_rejects "빈 값" ""
  startup_rejects "키 없음" "<unset>"
  startup_rejects "ts.net 아님" "example.com"
  startup_rejects "ts.net 뒤에 더 붙음" "example.ts.net.evil.com"
  startup_rejects "ts.net만" ".ts.net"
  startup_rejects "대문자" "Example.ts.net"
  startup_rejects "줄바꿈" $'evil.com\nexample.ts.net'
  startup_rejects "두 단계" "a.example.ts.net"

  if out=$(pod "$domain" 2>&1); then ok "[$cluster] 시작 검사 통과: 정상 값"; else bad "[$cluster] 시작 검사가 정상 값을 거부했다: $out"; fi

  start
  port=$(port_of "$cluster" || true)
  if [[ -z $port ]] || ! wait_ready "$port"; then
    bad "[$cluster] nginx가 뜨지 않았다"
    "$engine" logs "go-test-$cluster-$$" 2>&1 | tail -20 || true
    continue
  fi

  # 정상과 경로·쿼리 유지
  expect "/argocd" 302 "$(url argocd)"
  expect "/argocd/" 302 "$(url argocd)/"
  expect "/argocd/applications?x=1" 302 "$(url argocd)/applications?x=1"
  expect "/argocd?x=1&y=%2F" 302 "$(url argocd)?x=1&y=%2F"
  expect "/grafana/d/abc%20def?from=now-1h#frag" 302 "$(url grafana)/d/abc%20def?from=now-1h"
  expect "/a" 302 "$(url a)"
  expect "/0-9" 302 "$(url 0-9)"
  expect "/argocd//evil.com" 302 "$(url argocd)//evil.com"
  # 사용법
  expect "/" 200 -
  expect "/?q=1" 200 -
  # 열린 리다이렉트·잘못된 라벨 거부
  expect "/evil.com" 404 -
  expect "/a.b" 404 -
  expect "/argocd.evil.com/x" 404 -
  expect "/argocd@evil.com" 404 -
  expect "/argocd:443" 404 -
  expect '/argocd\@evil.com' 404 -
  # 디코딩한 $uri로는 /로 정규화돼 사용법이 나온다. 리다이렉트만 아니면 된다.
  expect "/argocd%2F..%2F" 200 -
  expect "/%61rgocd" 404 -
  expect "//evil.com" 404 -
  expect "/Argocd" 404 -
  expect "/-argocd" 404 -
  expect "/argocd-" 404 -
  expect "/argo_cd" 404 -
  # 63자 경계(<접두><이름>)
  expect "/$(label "$max")" 302 "$(url "$(label "$max")")"
  expect "/$(label $((max + 1)))" 404 -
  expect "/$(label $((max - 1)))b/x?y" 302 "$(url "$(label $((max - 1)))b")/x?y"

  # 절대 형식 요청 대상(GET http://host/path)도 Host를 따르지 않는다.
  got=$(curl -s -o /dev/null -w '%{http_code}\t%header{location}' --request-target "http://evil.com/argocd" "http://127.0.0.1:$port/")
  if [[ $got == $'302\t'"$(url argocd)" || $got == $'404\t' ]]; then ok "[$cluster] 절대 형식 → ${got//$'\t'/ }"; else bad "[$cluster] 절대 형식 → $got"; fi
  # 301을 쓰지 않는다
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/argocd")
  if [[ $code != 301 ]]; then ok "[$cluster] 301 아님"; else bad "[$cluster] 301을 낸다"; fi

  # 접근·오류 로그에 경로·쿼리가 없다(정상·404·잘못된 요청 모두)
  curl -s -o /dev/null "http://127.0.0.1:$port/argocd/$marker?code=$marker" || true
  curl -s -o /dev/null "http://127.0.0.1:$port/$marker.evil?x=$marker" || true
  curl -s -o /dev/null --path-as-is "http://127.0.0.1:$port/../$marker" || true
  curl -s -o /dev/null -H "X-Long: $(printf 'x%.0s' $(seq 1 9000))" "http://127.0.0.1:$port/argocd?$marker" || true
  logs=$("$engine" logs "go-test-$cluster-$$" 2>&1 || true)
  if [[ $logs == *"$marker"* ]]; then bad "[$cluster] 로그에 경로·쿼리가 남았다"; else ok "[$cluster] 로그에 경로·쿼리 없음($(printf '%s' "$logs" | wc -l)줄)"; fi
  if [[ $logs == *"$domain"* ]]; then bad "[$cluster] 로그에 tailnet 도메인이 남았다"; else ok "[$cluster] 로그에 tailnet 도메인 없음"; fi
done

echo
if [[ $fails -gt 0 ]]; then
  echo "go-redirect.test.sh: 실패 $fails건"
  exit 1
fi
echo "go-redirect.test.sh: 통과"
