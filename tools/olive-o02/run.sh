#!/usr/bin/env bash
# 올리브 계획 O02 시험을 밖에서 돌리는 창구. 관리자의 kubeconfig로 돈다. 순서는 시험 절차 문서(PR 본문이 가리킨다)를 따른다.
#
#   run.sh status                  읽기(kubectl get): 시험 파드의 상태, UID, 재시작 횟수
#   run.sh logs                    읽기(kubectl logs): 컨테이너 로그에 가짜 표식이 남았는지
#   run.sh step <단계> [기다릴 초]   쓰기(kubectl exec): 세션 컨테이너의 실행기에 단계 이름 하나를 넘긴다
#   run.sh probe <역할>             쓰기(kubectl exec): 대조 컨테이너에서 탐침을 돈다(sibling-nomount, sibling-ro, peer)
#
# kubectl exec는 클러스터 쓰기다. 관리자 승인 범위 안에서만 돌린다. 한 번에 하나만 돌린다.
# 파드에 넘기는 것은 단계 이름·역할 이름뿐이다. 명령이나 경로를 넘기지 않는다.
# 파드에서 온 출력은 제어 문자를 지운 뒤에 찍고, 같은 내용을 O02_LOG_DIR에 남긴다.
set -euo pipefail

NS=olive-o02-test
LOG_DIR=${O02_LOG_DIR:-$HOME/olive-verify/O02/run}

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# 파드 출력을 믿지 않는다. 탭·줄바꿈을 뺀 제어 문자를 지운다(파드 안 정제와 따로 한 번 더).
strip_ctrl() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

keep() { # <이름>: 표준 입력을 정제해 화면과 기록 파일에 쓴다
  mkdir -p "$LOG_DIR"
  strip_ctrl | tee "$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$1.txt"
}

cmd=${1:-}
case "$cmd" in
  status)
    {
      kubectl -n "$NS" get pods -o wide
      kubectl -n "$NS" get pod -l app=o02-session -o jsonpath='{range .items[*]}{.metadata.name}{" uid="}{.metadata.uid}{" node="}{.spec.nodeName}{" qos="}{.status.qosClass}{"\n"}{range .status.initContainerStatuses[*]}{"  init "}{.name}{" exit="}{.state.terminated.exitCode}{"\n"}{end}{range .status.containerStatuses[*]}{"  "}{.name}{" restarts="}{.restartCount}{" last="}{.lastState.terminated.reason}{"\n"}{end}{end}'
    } 2>&1 | keep status
    ;;
  logs)
    {
      for c in fetch-hc session sibling-nomount sibling-ro; do
        echo "== $c: 줄 수와 가짜 표식(o02fake-)이 든 줄 수"
        kubectl -n "$NS" logs deploy/o02-session -c "$c" --tail=-1 2>&1 | awk '{ n++ } /o02fake-/ { m++ } END { printf "줄 %d, 표식 든 줄 %d\n", n, m }'
      done
      echo "== fetch-hc 로그"
      kubectl -n "$NS" logs deploy/o02-session -c fetch-hc --tail=20 2>&1
    } | keep logs
    ;;
  step)
    step=${2:-}
    limit=${3:-240}
    [[ $step =~ ^[a-z0-9-]+$ && $limit =~ ^[0-9]+$ ]] || usage
    kubectl -n "$NS" exec deploy/o02-session -c session -- bash /opt/o02/ctl.sh "$step" "$limit" 2>&1 | keep "step-$step"
    ;;
  probe)
    role=${2:-}
    case "$role" in
      sibling-nomount | sibling-ro)
        kubectl -n "$NS" exec deploy/o02-session -c "$role" -- bash /opt/o02/probe.sh "$role" 2>&1 | keep "probe-$role"
        ;;
      peer)
        kubectl -n "$NS" exec deploy/o02-peer -c peer -- bash /opt/o02/probe.sh peer 2>&1 | keep probe-peer
        ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac
