#!/usr/bin/env bash
# 올리브 계획 O25 시험을 밖에서 돌리는 창구. 관리자의 kubeconfig로 돈다. 순서는 시험 절차 문서(PR 본문이 가리킨다)를 따른다.
#
#   run.sh status                  읽기(kubectl get): 파드 UID, 조건, 컨테이너별 재시작 횟수·시작 시각·마지막 종료 코드, 이벤트
#   run.sh logs                    읽기(kubectl logs): 컨테이너 로그 줄 수와 가짜 표식(o25fake-)이 든 줄 수, 실행기 문지기 줄
#   run.sh step <단계> [기다릴 초]   쓰기(kubectl exec -c control): 실행기에 단계 이름 하나를 넘긴다
#   run.sh show <단계>              쓰기(kubectl exec -c control): 끝난 단계의 결과를 다시 본다
#   run.sh gate                    쓰기(kubectl exec -c control): 세대 기록과 장부 끝(제어 컨테이너가 떠 있을 때만. 멈춰 있으면 logs)
#   run.sh body <단계>              쓰기(kubectl exec -c body): 본체 컨테이너에서 본다(status, hide, after-restart, cred)
#
# kubectl exec는 클러스터 쓰기다. 관리자 승인 범위 안에서만 돌린다. 한 번에 하나만 돌린다.
# 파드에 넘기는 것은 단계 이름뿐이다. 명령이나 경로를 넘기지 않는다.
# 파드에서 온 출력은 sanitize.py를 지난 뒤에만 찍고, 같은 내용을 O25_LOG_DIR에 남긴다. 본체 컨테이너의 출력은 특히 믿지 않는다.
set -euo pipefail

NS=olive-o25-test
LOG_DIR=${O25_LOG_DIR:-$HOME/olive-verify/O25/run}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# 이 함수를 거치지 않고 파드 출력을 찍지 않는다. -I: 현재 폴더와 환경의 파이썬 경로를 읽지 않는다.
strip_ctrl() { python3 -I "$HERE/sanitize.py"; }
keep() { # <이름>
  mkdir -p "$LOG_DIR"
  strip_ctrl | tee "$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$1.txt"
}

cmd=${1:-}
case "$cmd" in
  status)
    {
      kubectl -n "$NS" get pods -o wide
      # 전체 재시작의 증거: 같은 파드 UID에서 init의 재시작 횟수가 오르고, control·body의 startedAt이 모두 바뀌며,
      # body의 lastState.finishedAt이 새 init의 시작보다 앞이어야 한다. PodRestartInPlace 조건도 함께 본다.
      kubectl -n "$NS" get pod -l app=o25-session -o jsonpath='{range .items[*]}{.metadata.name}{" uid="}{.metadata.uid}{" node="}{.spec.nodeName}{"\n"}{range .status.conditions[*]}{"  cond "}{.type}{"="}{.status}{" "}{.lastTransitionTime}{"\n"}{end}{range .status.initContainerStatuses[*]}{"  init "}{.name}{" restarts="}{.restartCount}{" exit="}{.state.terminated.exitCode}{" started="}{.state.terminated.startedAt}{" finished="}{.state.terminated.finishedAt}{"\n"}{end}{range .status.containerStatuses[*]}{"  "}{.name}{" restarts="}{.restartCount}{" started="}{.state.running.startedAt}{" waiting="}{.state.waiting.reason}{" last.exit="}{.lastState.terminated.exitCode}{" last.reason="}{.lastState.terminated.reason}{" last.finished="}{.lastState.terminated.finishedAt}{" id="}{.containerID}{"\n"}{end}{end}'
      echo "== 파드 스펙에 실린 재시작 규칙(기능 게이트가 꺼지면 API 서버가 떨어뜨린다)"
      kubectl -n "$NS" get pod -l app=o25-session -o jsonpath='{range .items[*].spec.containers[*]}{"  "}{.name}{" restartPolicy="}{.restartPolicy}{" rules="}{.restartPolicyRules}{"\n"}{end}'
      echo "== 이벤트(시각순 끝 30줄)"
      kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 30
    } 2>&1 | keep status
    ;;
  logs)
    {
      for c in fetch-hc gen control body; do
        echo "== $c: 줄 수와 가짜 표식(o25fake-)이 든 줄 수"
        # 로그를 읽지 못하면 실패로 적는다. 0은 로그를 실제로 읽었을 때만 증거다.
        if lines=$(kubectl -n "$NS" logs deploy/o25-session -c "$c" --tail=-1 2>/dev/null); then
          printf '%s\n' "$lines" | awk 'NF { n++ } /o25fake-/ { m++ } END { printf "줄 %d, 표식 든 줄 %d\n", n, m }'
        else
          echo "로그를 읽지 못했다(kubectl logs 실패). 표식이 없다는 증거가 아니다"
        fi
      done
      echo "== gen·control 로그 끝(세대와 문지기 줄)"
      kubectl -n "$NS" logs deploy/o25-session -c gen --tail=5 2>&1
      kubectl -n "$NS" logs deploy/o25-session -c control --tail=10 2>&1
      echo "== control 직전 실행(--previous)"
      kubectl -n "$NS" logs deploy/o25-session -c control --previous --tail=10 2>&1 || true
    } | keep logs
    ;;
  step)
    step=${2:-}
    limit=${3:-240}
    [[ $step =~ ^[a-z0-9-]+$ && $limit =~ ^[0-9]+$ ]] || usage
    # restart·ctl-crash는 실행기가 끝나 exec가 끊긴다(0이 아닌 종료). 그 뒤 status와 after-restart로 본다.
    kubectl -n "$NS" exec deploy/o25-session -c control -- bash /opt/o25/ctl.sh "$step" "$limit" 2>&1 | keep "step-$step" || true
    ;;
  show)
    step=${2:-}
    [[ $step =~ ^[a-z0-9-]+$ ]] || usage
    kubectl -n "$NS" exec deploy/o25-session -c control -- bash /opt/o25/ctl.sh show "$step" 2>&1 | keep "show-$step"
    ;;
  gate)
    kubectl -n "$NS" exec deploy/o25-session -c control -- bash /opt/o25/ctl.sh gate 2>&1 | keep gate
    ;;
  body)
    step=${2:-}
    case "$step" in
      status | hide | after-restart | cred)
        kubectl -n "$NS" exec deploy/o25-session -c body -- bash /opt/o25/bctl.sh "$step" 2>&1 | keep "body-$step"
        ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac
