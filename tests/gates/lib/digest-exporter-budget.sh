#!/usr/bin/env bash
# digest-exporter **지연 예산 SSOT** — 부트스트랩 안전성 계약(DigestExporterStale의 `for:`가 그 위에 선다)을
# 이루는 상수·파생·부등식을 **한 곳에서만** 정의한다.
#
# 왜 lib인가: 이 예산은 서로 다른 3개 게이트가 **같은 부등식**을 독립 판정한다 —
#   tests/gates/test_digest-exporter.bats            (정적 카디널리티 게이트)
#   tests/gates/vmalert-digest-stale-firing-e2e.sh   (발화 e2e preflight ①④)
#   tests/gates/skopeo-timeout-smoke.sh              (실물 타임아웃 스모크)
# 상수(POD_START·EXEC_SLACK)와 파생 sed를 각자 리터럴로 복제하면 한쪽만 바뀌었을 때 두 게이트의 판정이
# **조용히 갈린다**(주석으로 "같은 값이어야 한다"고 적는 것은 강제가 아니다). 여기서 파생하고 여기서만 센다.
#
# 사용: `. tests/gates/lib/digest-exporter-budget.sh` 후 `deb_load <digest-exporter.yaml>`.
#       lib은 셸 옵션을 건드리지 않는다(caller가 `set -e` 등을 소유한다). bats에서도 그대로 source 가능.
#
# ⚠️ fail-closed: 매니페스트 파생이 실패하면(경로 변경·형식 변경 → 빈 값·비수치) `deb_load`가 **1을 반환**하고
#    이유를 stderr에 쓴다. 소비자는 반드시 `|| <fail>`로 받아 RED를 만든다 — 빈 값을 그대로 산술에 넣으면
#    부등식이 참으로 평가돼(0 < ADS) 상한을 하나도 강제하지 못한 채 게이트가 green이 된다(= fail-open).

# ── 명시 상수(매니페스트에서 파생 불가 — 계약의 일부라 코드에 못박는다. 여기가 유일한 정의처다) ─────────
# activeDeadlineSeconds는 **파드 생성부터** 재므로 스케줄+이미지 pull이 데드라인 **안에** 들어간다.
#
# ⚠️ DEB_POD_START_BUDGET_S는 **가정이지 강제된 값이 아니다** — k8s에는 이 잡의 startup에 상한을 거는
#    수단이 없고(activeDeadlineSeconds는 startup을 **포함한** 총량 상한일 뿐), 매니페스트 어디에서도 파생되지
#    않는다. 즉 N_MAX와 첫-하트비트 상한 계산은 "스케줄+이미지 pull ≤ 60s"라는 **관측 기반 가정** 위에 선다.
#    ㆍ현재 여유: N=2에서 60 + 2×10 + 30 + 10 = 120 < 180(ADS) → startup이 실제로 120s까지 늘어져도 push가 산다.
#    ㆍ가정이 깨져도 **fail-open이 아니다**: startup이 예산을 초과하면 Job이 ADS에 걸려 죽고 → 하트비트가
#      미발행되고 → DigestExporterStale이 운다(fail-closed). 즉 최악은 "거짓 페이지"이지 "무성 실패"가 아니다.
#    ㆍ강제 가능한 제약에서 파생하는 것(startup SLA 도입 또는 ADS/N_MAX 재산정)은 PRD Follow-up **F-7**.
DEB_POD_START_BUDGET_S=60   # 파드 스케줄 + 이미지 pull 예산(관측 기반 **가정** — 위 ⚠️ 참조)
DEB_EXEC_SLACK_S=10         # sed/head/셸 오버헤드

# ── 파생값(deb_load가 채운다) ───────────────────────────────────────────────────────────────────────
DEB_SKOPEO_TIMEOUT_S=""     # run.sh SKOPEO_TIMEOUT 기본값(초)
DEB_CURL_MAX_TIME_S=""      # run.sh CURL_MAX_TIME 기본값(초)
DEB_ACTIVE_DEADLINE_S=""    # CronJob jobTemplate.spec.activeDeadlineSeconds
DEB_APPS_N=""               # APPS env의 "name=ref" 항목 수
DEB_CRON_PERIOD_S=""        # CronJob schedule "*/N * * * *" → N×60(= push 주기)
DEB_CONCURRENCY_POLICY=""   # CronJob concurrencyPolicy(상한이 레거시 Job을 빠져나가지 않는가)

deb_err() { echo "digest-exporter-budget: $*" >&2; }

deb_is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

deb_load() { # $1 = platform/victoria-stack/prod/digest-exporter.yaml → DEB_* 전역 설정 (실패=1)
  local f="${1:-}" runsh cron cron_min apps_key apps_raw
  [ -n "$f" ] && [ -f "$f" ] || {
    deb_err "매니페스트를 찾을 수 없다: '${1:-<empty>}'"
    return 1
  }

  runsh="$(yq 'select(.kind=="ConfigMap").data["run.sh"]' "$f")"
  [ -n "$runsh" ] || {
    deb_err "ConfigMap에서 run.sh를 추출하지 못했다($f) — 타임아웃 기본값을 파생할 수 없다."
    return 1
  }

  DEB_SKOPEO_TIMEOUT_S="$(printf '%s\n' "$runsh" | sed -n 's/.*SKOPEO_TIMEOUT:-\([0-9]*\)s}.*/\1/p' | head -1)"
  deb_is_uint "$DEB_SKOPEO_TIMEOUT_S" || {
    deb_err "SKOPEO_TIMEOUT 파생 실패(값='$DEB_SKOPEO_TIMEOUT_S') — run.sh의 \${SKOPEO_TIMEOUT:-Ns} 기본값이 사라졌거나 형식이 바뀌었다. 앱당 스크레이프 상한이 무강제가 되면 행(hung) 잡이 activeDeadlineSeconds를 통째로 태우고 push 전에 죽는다."
    return 1
  }

  DEB_CURL_MAX_TIME_S="$(printf '%s\n' "$runsh" | sed -n 's/.*CURL_MAX_TIME:-\([0-9]*\)}.*/\1/p' | head -1)"
  deb_is_uint "$DEB_CURL_MAX_TIME_S" || {
    deb_err "CURL_MAX_TIME 파생 실패(값='$DEB_CURL_MAX_TIME_S') — run.sh의 \${CURL_MAX_TIME:-N} 기본값이 사라졌거나 형식이 바뀌었다. push 상한이 무강제다."
    return 1
  }

  DEB_ACTIVE_DEADLINE_S="$(yq 'select(.kind=="CronJob").spec.jobTemplate.spec.activeDeadlineSeconds' "$f" | head -1)"
  deb_is_uint "$DEB_ACTIVE_DEADLINE_S" || {
    deb_err "activeDeadlineSeconds 파생 실패(값='$DEB_ACTIVE_DEADLINE_S') — 부재/비정수 = 지연 상한 없음. 행 잡이 슬롯을 무한 점유해 첫 하트비트가 임의로 늦어진다(최초 배포 거짓 페이지)."
    return 1
  }
  [ "$DEB_ACTIVE_DEADLINE_S" -gt 0 ] || {
    deb_err "activeDeadlineSeconds=0 — 상한이 아니다."
    return 1
  }

  DEB_CONCURRENCY_POLICY="$(yq 'select(.kind=="CronJob").spec.concurrencyPolicy' "$f" | head -1)"
  [ -n "$DEB_CONCURRENCY_POLICY" ] || {
    deb_err "concurrencyPolicy 파생 실패 — 빈 값."
    return 1
  }

  cron="$(yq 'select(.kind=="CronJob").spec.schedule' "$f" | head -1)"
  case "$cron" in
    '*/'[0-9]*' * * * *')
      cron_min="${cron%% *}"
      DEB_CRON_PERIOD_S=$(( ${cron_min#\*/} * 60 ))
      ;;
    *)
      deb_err "CronJob schedule이 '*/N * * * *' 형식이 아니다(값='$cron') — push 주기를 파생할 수 없다."
      return 1
      ;;
  esac
  deb_is_uint "$DEB_CRON_PERIOD_S" && [ "$DEB_CRON_PERIOD_S" -gt 0 ] || {
    deb_err "push 주기 파생 실패(값='$DEB_CRON_PERIOD_S')."
    return 1
  }

  # APPS env **엔트리 존재**는 fail-closed(yq 경로가 바뀌면 N=0으로 조용히 무너진다), 값이 빈 것은 허용(N=0).
  apps_key="$(yq 'select(.kind=="CronJob").spec.jobTemplate.spec.template.spec.containers[].env[] | select(.name=="APPS").name' "$f" | head -1)"
  [ "$apps_key" = "APPS" ] || {
    deb_err "CronJob에서 APPS env 엔트리를 찾지 못했다(yq 경로 변경?) — 앱 카디널리티를 셀 수 없어 인-데드라인 부등식이 무의미해진다."
    return 1
  }
  apps_raw="$(yq 'select(.kind=="CronJob").spec.jobTemplate.spec.template.spec.containers[].env[] | select(.name=="APPS").value' "$f" | head -1)"
  DEB_APPS_N="$(printf '%s\n' "$apps_raw" | tr ' ' '\n' | grep -c '=' | tr -d '[:space:]')"
  deb_is_uint "$DEB_APPS_N" || {
    deb_err "APPS 카디널리티 파생 실패(값='$DEB_APPS_N')."
    return 1
  }
}

# ── 부등식/파생 산술(소비자 3곳이 공유) ─────────────────────────────────────────────────────────────

# 순차 스크레이프 예산(초). 이 값이 activeDeadlineSeconds보다 **엄격히 작아야** Job이 push 전에 죽지 않는다.
# 등호 금지: 컨트롤러는 duration ≥ ADS에서 만료시키므로, 등호를 허용하면 "push 전에 죽는 Job"을 승인하게 된다
# → GHCR 장애가 아니라 DigestExporterStale/KubeJobFailed로 **오귀속**된다.
deb_in_deadline_budget() {
  printf '%s' "$(( DEB_POD_START_BUDGET_S + DEB_APPS_N * DEB_SKOPEO_TIMEOUT_S + DEB_CURL_MAX_TIME_S + DEB_EXEC_SLACK_S ))"
}

# 현 계약이 허용하는 최대 앱 수(N_MAX). N > N_MAX면 CI red — 8번째 앱이 조용히 상한을 깨지 못하게 한다.
deb_n_max() {
  printf '%s' "$(( (DEB_ACTIVE_DEADLINE_S - 1 - DEB_POD_START_BUDGET_S - DEB_CURL_MAX_TIME_S - DEB_EXEC_SLACK_S) / DEB_SKOPEO_TIMEOUT_S ))"
}

# 강제된 **최악 첫 하트비트 상한**(초) = cron 주기 + 파드 예산 + activeDeadlineSeconds.
# DigestExporterStale의 `for:`가 이 값보다 커야 최초 배포가 거짓 페이지를 내지 않는다(엄격 부등식).
deb_first_heartbeat_bound() {
  printf '%s' "$(( DEB_CRON_PERIOD_S + DEB_POD_START_BUDGET_S + DEB_ACTIVE_DEADLINE_S ))"
}
