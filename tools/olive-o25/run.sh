#!/usr/bin/env bash
# 올리브 계획 O25 시험을 밖에서 돌리는 창구. 관리자의 kubeconfig로 돈다. 순서는 시험 절차 문서(PR 본문이 가리킨다)를 따른다.
#
#   run.sh status                  읽기(kubectl get): 파드 UID, 조건, 컨테이너별(init 포함) ID·재시작 횟수·시작 시각·마지막 종료, 이벤트
#   run.sh logs                    읽기(kubectl logs): 컨테이너 로그 줄 수와 표식(o25fake-) 든 줄 수, fetch-hc 재사용 줄, 문지기 줄
#   run.sh step <단계> [기다릴 초]   쓰기(kubectl exec -c control): 실행기에 단계 이름 하나를 넘긴다(body-term은 전에 API 상태를 남긴다)
#   run.sh show <단계>              쓰기(kubectl exec -c control): 끝난 단계의 결과를 다시 본다
#   run.sh gate                    쓰기(kubectl exec -c control): 세대 기록과 장부 끝(제어 컨테이너가 떠 있을 때만. 멈춰 있으면 logs)
#   run.sh body <단계>              쓰기(kubectl exec -c body): status, hide, after-restart, after-body-term, shm
#   run.sh submit <작업>            쓰기(kubectl exec): 검사 요청 하나를 낸다. cred(제어), body-cred·body-hide(본체). 요청 ID를 찍는다
#   run.sh result <요청 ID> [초]    읽기(kubectl logs): 그 파드·컨테이너 로그에서 요청 결과 묶음을 회수한다(exec 없음)
#   run.sh show-req <요청 ID>       쓰기(kubectl exec -c control): 제어 쪽 요청의 근거 글 전체(검사가 끝난 뒤에만)
#   run.sh body-only-check         읽기(kubectl get): step body-term 전에 남긴 상태와 지금을 견줘 본체만 다시 떴는지 본다
#   run.sh claude-judge            쓰기(kubectl exec -c control ctl.sh show claude-ui)+읽기(logs -c body): claude 변형 (4) 판정
#   (step은 배포된 본체 변형을 먼저 읽는다. claude 변형에 셸 단계(relay·false-exit·plant·body-term)를, 셸 변형에 claude-ui를 넘기지 않는다)
#
# kubectl exec는 클러스터 쓰기다. 관리자 승인 범위 안에서만 돌린다. 한 번에 하나만 돌린다. 검사 요청을 낸 뒤 결과를 회수할 때까지
# 그 컨테이너에 다른 exec를 넣지 않는다(검사 순간 살아 있는 exec 프로세스는 읽지 못한 대상이 되어 판단 필요가 된다).
# 파드에 넘기는 것은 단계·작업 이름뿐이다. 명령이나 경로를 넘기지 않는다.
# 파드에서 온 출력은 sanitize.py를 지난 뒤에만 찍고, 같은 내용을 O25_LOG_DIR에 남긴다. 본체 컨테이너의 출력은 특히 믿지 않는다.
set -euo pipefail

NS=olive-o25-test
LOG_DIR=${O25_LOG_DIR:-$HOME/olive-verify/O25/run}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# 이 함수를 거치지 않고 파드 출력을 찍지 않는다. -I: 현재 폴더와 환경의 파이썬 경로를 읽지 않는다.
strip_ctrl() { python3 -I "$HERE/sanitize.py"; }
keep() { # <이름>
  mkdir -p "$LOG_DIR"
  strip_ctrl | tee "$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$1.txt"
}

# pod_snap [파드 이름]: "이름 UID 컨테이너=ID:재시작 …" 한 줄. 이름이 없으면 세션 파드가 정확히 하나일 때만.
pod_snap() {
  local name=${1:-} n
  if [ -z "$name" ]; then
    n=$(kubectl -n "$NS" get pod -l app=o25-session -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] || return 1
    name=$n
  fi
  kubectl -n "$NS" get pod "$name" -o jsonpath='{.metadata.name}{" "}{.metadata.uid}{range .status.initContainerStatuses[*]}{" init-"}{.name}{"="}{.containerID}{":"}{.restartCount}{end}{range .status.containerStatuses[*]}{" "}{.name}{"="}{.containerID}{":"}{.restartCount}{end}'
}
# body_variant: 배포된 Deployment의 제어 컨테이너 환경 O25_BODY_VARIANT(shell|claude). 못 읽거나 모르는 값이면 실패한다.
body_variant() {
  local v
  v=$(kubectl -n "$NS" get deploy o25-session -o jsonpath='{.spec.template.spec.containers[?(@.name=="control")].env[?(@.name=="O25_BODY_VARIANT")].value}') || return 1
  case "$v" in shell | claude) printf '%s' "$v" ;; *) return 1 ;; esac
}
# body_env <이름>: 배포된 본체 컨테이너 환경값(핀 대조용).
body_env() {
  kubectl -n "$NS" get deploy o25-session -o jsonpath="{.spec.template.spec.containers[?(@.name==\"body\")].env[?(@.name==\"$1\")].value}"
}
# snap_get <스냅샷 줄> <키>: "키=ID:횟수"의 값.
snap_get() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1; }

cmd=${1:-}
case "$cmd" in
  status)
    {
      kubectl -n "$NS" get pods -o wide
      # 전체 재시작의 증거: 같은 파드 UID에서 init의 재시작 횟수가 오르고, control·body의 startedAt이 모두 바뀌며,
      # body의 lastState.finishedAt이 새 init의 시작보다 앞이어야 한다. 1차 실측의 조건 이름은 AllContainersRestarting이다.
      kubectl -n "$NS" get pod -l app=o25-session -o jsonpath='{range .items[*]}{.metadata.name}{" uid="}{.metadata.uid}{" node="}{.spec.nodeName}{"\n"}{range .status.conditions[*]}{"  cond "}{.type}{"="}{.status}{" "}{.lastTransitionTime}{"\n"}{end}{range .status.initContainerStatuses[*]}{"  init "}{.name}{" restarts="}{.restartCount}{" exit="}{.state.terminated.exitCode}{" started="}{.state.terminated.startedAt}{" finished="}{.state.terminated.finishedAt}{" id="}{.containerID}{"\n"}{end}{range .status.containerStatuses[*]}{"  "}{.name}{" restarts="}{.restartCount}{" started="}{.state.running.startedAt}{" waiting="}{.state.waiting.reason}{" last.exit="}{.lastState.terminated.exitCode}{" last.reason="}{.lastState.terminated.reason}{" last.finished="}{.lastState.terminated.finishedAt}{" id="}{.containerID}{"\n"}{end}{end}'
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
          printf '%s\n' "$lines" | awk 'NF { n++ } /o25fake-/ { m++ } / reject code=/ { r++ } END { printf "줄 %d, 표식 든 줄 %d, 요청 거절 줄 %d\n", n, m, r }'
          if [ "$c" = fetch-hc ]; then
            # 전체 재시작 뒤에는 "reuse verified archive"(받아 둔 묶음을 다시 대조만 함)가 예상이다. 첫 기동은 내려받기 뒤 fetched 줄뿐이다.
            printf '%s\n' "$lines" | awk '/^reuse verified archive$/ { r++ } /^fetched: / { f++ } END { printf "검증한 파일 재사용 줄 %d, fetched 줄 %d\n", r, f }'
            # claude 변형: 같은 init의 Claude 줄. 실패 줄(크기·sha)이 1 이상이면 init이 멈춘 이유다.
            printf '%s\n' "$lines" | awk '/^claude: reuse verified file$/ { r++ } /^claude: fetched / { f++ } /^claude: size mismatch$|FAILED/ { b++ } END { printf "claude 재사용 줄 %d, claude fetched 줄 %d, 크기·sha 실패 줄 %d\n", r, f, b }'
          fi
          if [ "$c" = body ]; then
            # claude 변형: 본체 PID 1의 실행 증거 줄(o25c). 판정은 run.sh claude-judge.
            printf '%s\n' "$lines" | awk '/^o25c / { print "  " $4, $5 }' | strip_ctrl
          fi
        else
          echo "로그를 읽지 못했다(kubectl logs 실패). 표식이 없다는 증거가 아니다"
        fi
      done
      echo "== gen·control 로그 끝(세대와 문지기 줄)"
      kubectl -n "$NS" logs deploy/o25-session -c gen --tail=5 2>&1
      kubectl -n "$NS" logs deploy/o25-session -c control --tail=10 2>&1
      echo "== control 직전 실행(--previous. 전체 재시작 뒤에는 못 읽는 것이 1차 실측이다)"
      kubectl -n "$NS" logs deploy/o25-session -c control --previous --tail=10 2>&1 || true
    } | keep logs
    ;;
  step)
    step=${2:-}
    limit=${3:-240}
    [[ $step =~ ^[a-z0-9-]+$ && $limit =~ ^[0-9]+$ ]] || usage
    # 실행기도 같은 거절을 하지만(files/lib.sh step_fn), 여기서 먼저 막아 exec 자체를 하지 않는다.
    v=$(body_variant) || {
      echo "배포된 본체 변형(O25_BODY_VARIANT)을 읽지 못했다. 단계를 넘기지 않는다" >&2
      exit 5
    }
    case "$v $step" in
      "claude relay" | "claude false-exit" | "claude plant" | "claude body-term" | "shell claude-ui")
        echo "거절: '$step'은 본체 변형 '$v'에서 돌리지 않는다(시험 절차서 Claude 변형 절)" >&2
        exit 5
        ;;
    esac
    if [ "$step" = body-term ]; then
      # body-only-check가 견줄 "전" 상태. 이것을 못 남기면 단계를 넘기지 않는다.
      mkdir -p "$LOG_DIR"
      pod_snap >"$LOG_DIR/snap-body-term.txt" || {
        echo "세션 파드 상태를 남기지 못했다(파드가 하나가 아님). body-term을 넘기지 않는다" >&2
        exit 3
      }
      echo "전 상태: $(strip_ctrl <"$LOG_DIR/snap-body-term.txt")"
    fi
    # restart·ctl-crash는 실행기가 끝나 exec가 끊긴다(0이 아닌 종료). 그 뒤 status와 after-restart로 본다.
    kubectl -n "$NS" exec deploy/o25-session -c control -- bash /opt/o25/ctl.sh "$step" "$limit" 2>&1 | keep "step-$step" || true
    ;;
  show)
    step=${2:-}
    [[ $step =~ ^[a-z0-9-]+$ ]] || usage
    kubectl -n "$NS" exec deploy/o25-session -c control -- bash /opt/o25/ctl.sh show "$step" 2>&1 | keep "show-$step"
    ;;
  show-req)
    req=${2:-}
    [[ $req =~ ^[0-9a-f]{12}$ ]] || usage
    kubectl -n "$NS" exec deploy/o25-session -c control -- bash /opt/o25/ctl.sh show-req "$req" 2>&1 | keep "show-req-$req"
    ;;
  gate)
    kubectl -n "$NS" exec deploy/o25-session -c control -- bash /opt/o25/ctl.sh gate 2>&1 | keep gate
    ;;
  body)
    step=${2:-}
    case "$step" in
      status | hide | after-restart | after-body-term | shm)
        kubectl -n "$NS" exec deploy/o25-session -c body -- bash /opt/o25/bctl.sh "$step" 2>&1 | keep "body-$step"
        ;;
      *) usage ;;
    esac
    ;;
  submit)
    job=${2:-}
    case "$job" in
      cred) c=control ;;
      body-cred | body-hide) c=body ;;
      *) usage ;;
    esac
    # 파드 이름·UID·컨테이너 ID를 먼저 고정하고 그 파드에만 낸다. 회수도 같은 파드·컨테이너에서만 한다.
    snap=$(pod_snap) || {
      echo "세션 파드가 정확히 하나가 아니다" >&2
      exit 3
    }
    name=${snap%% *}
    out=$(kubectl -n "$NS" exec "$name" -c "$c" -- python3 /opt/o25/o25.py submit "$job" 2>&1 | keep "submit-$job") || true
    printf '%s\n' "$out"
    sub=$(printf '%s\n' "$out" | sed -n 's/^제출 req=\([0-9a-f]\{12\}\) gen=\([0-9a-f]\{12\}\) .*/\1 \2/p' | head -n 1)
    if [ -z "$sub" ]; then
      echo "제출 줄이 없다. 요청이 나가지 않았다" >&2
      exit 4
    fi
    req=${sub% *}
    printf 'name=%s\nuid=%s\ncontainer=%s\ncid=%s\ngen=%s\njob=%s\n' "$name" "$(printf '%s' "$snap" | cut -d' ' -f2)" "$c" \
      "$(snap_get "$snap" "$c")" "${sub#* }" "$job" >"$LOG_DIR/req-$req.env"
    echo "요청 $req 기록: $LOG_DIR/req-$req.env. 회수: run.sh result $req"
    ;;
  result)
    req=${2:-}
    limit=${3:-120}
    [[ $req =~ ^[0-9a-f]{12}$ && $limit =~ ^[0-9]+$ && -r "$LOG_DIR/req-$req.env" ]] || usage
    get() { sed -n "s/^$1=\([0-9a-zA-Z:/._-]*\)$/\1/p" "$LOG_DIR/req-$req.env" | head -n 1; }
    name=$(get name) uid=$(get uid) c=$(get container) cid=$(get cid) gen=$(get gen) job=$(get job)
    end=$((SECONDS + limit))
    while :; do
      why=""
      now=$(pod_snap "$name" 2>/dev/null) || why="pod-read-failed"
      if [ -z "$why" ] && { [ "$(printf '%s' "$now" | cut -d' ' -f2)" != "$uid" ] || [ "$(snap_get "$now" "$c")" != "$cid" ]; }; then
        # 파드가 바뀌었거나 그 컨테이너가 다시 떴다. 결과가 있었더라도 다른 실행의 로그이므로 미완료로 닫는다.
        why="container-changed"
      fi
      if [ -z "$why" ]; then
        if logs=$(kubectl -n "$NS" logs "$name" -c "$c" --tail=-1 2>/dev/null); then
          if res=$(printf '%s\n' "$logs" | python3 -I "$HERE/result.py" "$uid" "$gen" "$req" "$job"); then
            printf '%s\n' "$res" | keep "result-$req"
            exit 0
          fi
        else
          res=""
          why="logs-failed"
        fi
      fi
      if [ -n "$why" ] || [ "$SECONDS" -ge "$end" ]; then
        if [ -n "$why" ]; then
          python3 -I "$HERE/result.py" "$uid" "$gen" "$req" "$job" </dev/null | sed "s/이유=not-found/이유=$why/; s/회수 미완료(not-found)/회수 미완료($why)/" | keep "result-$req"
        else
          printf '%s\n' "$res" | keep "result-$req"
        fi
        exit 1
      fi
      sleep 3
    done
    ;;
  body-only-check)
    # 본체만 다시 떴는가: 같은 파드 UID, control·init의 ID와 재시작 횟수 그대로, body는 ID가 바뀌고 재시작 1회 늘어남.
    k=4.body-only.재시작-분리
    before=$(cat "$LOG_DIR/snap-body-term.txt" 2>/dev/null || true)
    now=$(pod_snap 2>/dev/null || true)
    {
      echo "전: $before"
      echo "지금: $now"
      # 네 컨테이너의 "ID:횟수"가 전후 모두 정확히 한 번, 비어 있지 않은 ID로 있어야 견준다. 재기동 중인 API는 ID를 비워 둘 수 있고,
      # 빈 값끼리는 같아 보인다.
      bad=""
      for snap in "$before" "$now"; do
        [[ $(printf '%s' "$snap" | cut -d' ' -f2) =~ ^[0-9a-f-]{36}$ ]] || bad="$bad pod-uid"
        for key in control body init-fetch-hc init-gen; do
          [ "$(printf '%s\n' "$snap" | tr ' ' '\n' | grep -c "^$key=")" = 1 ] &&
            [[ $(snap_get "$snap" "$key") =~ ^[a-z0-9]+://[0-9A-Za-z]{1,128}:[0-9]{1,6}$ ]] || bad="$bad $key"
        done
      done
      b0=$(snap_get "$before" body) b1=$(snap_get "$now" body)
      if [ -z "$before" ] || [ -z "$now" ]; then
        echo "결과 $k 판단 필요 — 전 상태나 지금 상태를 읽지 못했다"
      elif [ -n "$bad" ]; then
        echo "결과 $k 판단 필요 — 컨테이너 ID·재시작 횟수가 없거나 모양이 다르다:$bad"
      elif [ "${b0%:*}" = "${b1%:*}" ] && [ "$b0" != "$b1" ]; then
        echo "결과 $k 판단 필요 — 본체 재시작 횟수는 바뀌었는데 컨테이너 ID가 그대로다"
      elif [ "$(printf '%s' "$before" | cut -d' ' -f2)" != "$(printf '%s' "$now" | cut -d' ' -f2)" ]; then
        echo "결과 $k 안 됨 — 파드 UID가 바뀌었다(파드가 새로 떴다)"
      else
        changed=""
        for key in control init-fetch-hc init-gen; do
          [ "$(snap_get "$before" "$key")" = "$(snap_get "$now" "$key")" ] || changed="$changed $key"
        done
        if [ -n "$changed" ]; then
          echo "결과 $k 안 됨 — 본체 밖에서도 바뀐 컨테이너:$changed"
        elif [ "$b0" = "$b1" ]; then
          echo "결과 $k 판단 필요 — 본체 컨테이너가 아직 다시 뜨지 않았다(ID·재시작 횟수 그대로)"
        elif [ "${b1##*:}" = "$((${b0##*:} + 1))" ]; then
          echo "결과 $k 됨 — 본체만 ID가 바뀌고 재시작 ${b0##*:}→${b1##*:}회. control·init의 ID와 재시작 횟수, 파드 UID 그대로"
        else
          echo "결과 $k 판단 필요 — 본체 재시작 ${b0##*:}→${b1##*:}회(한 번이 아니다)"
        fi
      fi
    } 2>&1 | keep body-only-check
    ;;
  claude-judge)
    [ "$(body_variant || true)" = claude ] || {
      echo "claude 변형이 아니다(또는 변형을 읽지 못했다)" >&2
      exit 5
    }
    snap=$(pod_snap) || {
      echo "세션 파드가 정확히 하나가 아니다" >&2
      exit 3
    }
    name=${snap%% *} uid=$(printf '%s' "$snap" | cut -d' ' -f2)
    sha=$(body_env O25_PROG_SHA256) ver=$(body_env O25_PROG_VERSION)
    mkdir -p "$LOG_DIR"
    t=$(date -u +%Y%m%dT%H%M%SZ)
    kubectl -n "$NS" exec "$name" -c control -- bash /opt/o25/ctl.sh show claude-ui 2>&1 | strip_ctrl >"$LOG_DIR/$t-claude-ui.txt" || true
    kubectl -n "$NS" logs "$name" -c body --tail=-1 2>&1 | strip_ctrl >"$LOG_DIR/$t-body-log.txt" || true
    gen=$(sed -n 's/^시작 [^ ]* 세대 \([0-9a-f]\{12\}\) .*/\1/p' "$LOG_DIR/$t-claude-ui.txt" | head -n 1)
    echo "파드 $name uid $uid 세대 ${gen:-?} 핀 $ver ${sha:0:16}"
    python3 -I "$HERE/claude-judge.py" "$uid" "${gen:-unknown}" "$sha" "$ver" "$LOG_DIR/$t-claude-ui.txt" "$LOG_DIR/$t-body-log.txt" 2>&1 |
      keep claude-judge
    ;;
  *) usage ;;
esac
