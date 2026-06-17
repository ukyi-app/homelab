#!/usr/bin/env sh
# tf plan의 delete/replace(=delete+create) 액션 수를 세어 무인 apply를 가드한다(SSOT).
# ⚠️ codex pass5 F1: 결과를 **typed output**(result, destroy_count)으로 낸다 — 호출 측이 "의도된 delete 차단"과
# "내부 오류(plan 읽기 실패·jq 부재·파싱 실패)"를 구분해, 후자는 잡을 **loud 실패**시키게 한다(가드가 깨졌는데
# green으로 위장하는 것 방지).
#   result=ok             : delete 0 (또는 mode=warn)  → exit 0
#   result=blocked-delete : delete>0 && mode=block      → exit 1 (호출 측이 alert-and-skip로 강등)
#   result=error          : 내부/도구 오류              → exit 2 (호출 측이 잡 실패)
# 단위 테스트용: PLAN_JSON이 있으면 그 파일을, 없으면 `terraform -chdir=$ROOT show -json $PLAN`.
set -u
out="${GITHUB_OUTPUT:-/dev/null}"
emit() { echo "result=$1" >> "$out"; }

MODE="${MODE:-block}"
case "$MODE" in
  warn|block) : ;;
  *) emit error; echo "::error::tf-destroy-guard: mode는 warn|block만 — '$MODE' 거부"; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { emit error; echo "::error::tf-destroy-guard: jq 부재 — 내부 오류(잡 실패)"; exit 2; }

if [ -n "${PLAN_JSON:-}" ]; then
  plan_json=$(cat "$PLAN_JSON" 2>/dev/null) || { emit error; echo "::error::PLAN_JSON 읽기 실패: ${PLAN_JSON}"; exit 2; }
else
  ROOT="${ROOT:?ROOT(=-chdir 루트) 필요}"
  PLAN="${PLAN:-tf.plan}"
  plan_json=$(terraform -chdir="$ROOT" show -json "$PLAN" 2>/tmp/tdg.err) || { emit error; echo "::error::terraform show 실패(plan 산출 누락/손상): $(cat /tmp/tdg.err 2>/dev/null)"; exit 2; }
fi

# 기존 인라인 가드와 동일 셀렉터 — replace(delete+create)의 delete도 잡는다.
destroys=$(printf '%s' "$plan_json" | jq '[.resource_changes[].change.actions[] | select(. == "delete")] | length' 2>/dev/null)
case "$destroys" in
  ''|*[!0-9]*) emit error; echo "::error::destroy_count 파싱 실패(plan JSON 손상)"; exit 2 ;;
esac
echo "destroy_count=$destroys" >> "$out"

if [ "$destroys" -gt 0 ]; then
  if [ "$MODE" = "block" ]; then
    emit blocked-delete
    echo "::error::tf plan에 delete/replace ${destroys}건 — 무인 apply 차단(수동 검토 후 적용)"
    exit 1
  fi
  emit ok
  echo "::warning::tf plan에 delete/replace ${destroys}건 — 머지 시 무인 apply가 차단(수동 검토 필요)"
  exit 0
fi
emit ok
exit 0
