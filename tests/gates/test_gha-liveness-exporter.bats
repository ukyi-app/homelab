#!/usr/bin/env bats
# GHA liveness 하트비트(티켓 10)의 gate 테스트 — gha-liveness-exporter + r6 룰 3종.
#
# 병: 09(준비상태 회계)는 *run 안에서* job이 조용히 skip되는 것을 닫았다. 남은 표면은 **run이 아예
# 발생하지 않는 것**이다(GitHub의 60일 스케줄 자동 비활성화·Actions 비활성화·스케줄러 유실).
# run conclusion으로는 원리적으로 볼 수 없다 — 없는 run은 색이 없다. 관측자는 run **밖**에 있어야 하고,
# GitHub-hosted 러너는 internal-by-default 때문에 vmsingle에 못 닿으므로 방향은 클러스터 폴링뿐이다.
#
# ⚠️ 이 스위트의 핵심은 **감시 목록을 하드코딩과 대조하지 않는 것**이다. 티켓 07 D-1에서 배운 대로,
#    하드코딩 목록은 자기 자신에 대해서만 정확하다. 그래서 감시 집합과 나이 예산을 **워크플로 파일의
#    cron에서 계산해** 강제한다 — 새 스케줄 워크플로가 생기면 자동으로 red가 된다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  MF="platform/victoria-stack/prod/gha-liveness-exporter.yaml"
  R6="platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
}

# WORKFLOWS env를 "파일=예산" 줄로 뽑는다.
watched() {
  bun -e '
    const { readFileSync } = require("node:fs");
    const t = readFileSync(process.argv[1], "utf8");
    const m = /- name: WORKFLOWS\n\s+value: >-\n((?:[ \t]+\S+\.ya?ml=\d+[ \t]*\n)+)/.exec(t);
    if (!m) { console.error("WORKFLOWS 블록을 못 찾았다"); process.exit(2); }
    // ⚠️ `\S+`로만 이어 받으면 폴드 블록을 넘어 뒤따르는 `resources:` 같은 키까지 삼킨다(실측).
    //    항목 모양(`<파일>.yaml=<숫자>`)으로 종료 조건을 준다 — 모양이 깨지면 그 항목은 빠지고,
    //    그러면 아래 집합 대조가 red가 된다(fail-closed).
    console.log(m[1].trim().split(/\s+/).filter((x) => /\.ya?ml=\d+$/.test(x)).join("\n"));
  ' "$MF"
}

# 레포의 스케줄 워크플로와 그 주기(초)를 계산한다. **알 수 없는 cron 형태는 fail-closed**로 죽는다 —
# 조용히 0을 돌려주면 아래 부등식이 무조건 참이 되어 예산 검사가 통째로 무력해진다.
scheduled() {
  bun -e '
    const { readdirSync, readFileSync } = require("node:fs");
    const dir = ".github/workflows";
    const out = [];
    for (const f of readdirSync(dir).sort()) {
      if (!/\.ya?ml$/.test(f)) continue;
      const t = readFileSync(dir + "/" + f, "utf8");
      const c = /^\s*-\s*cron:\s*"([^"]+)"/m.exec(t);
      if (!c) continue;
      const [min, hour, dom, , dow] = c[1].trim().split(/\s+/);
      let period;
      let mm, hh;
      if ((mm = /^\*\/(\d+)$/.exec(min))) period = Number(mm[1]) * 60;
      else if ((hh = /^\*\/(\d+)$/.exec(hour))) period = Number(hh[1]) * 3600;
      else if (/^[0-6]$/.test(dow)) period = 604800;
      else if (dom === "*" && /^\d+$/.test(hour)) period = 86400;
      else { console.error("알 수 없는 cron 형태(fail-closed): " + f + " = " + c[1]); process.exit(2); }
      out.push(f + " " + period);
    }
    console.log(out.join("\n"));
  '
}

@test "the watched set equals the repo scheduled workflow set (both directions, derived not hardcoded)" {
  w="$(watched | sed 's/=.*//' | sort)"
  s="$(scheduled | awk '{print $1}' | sort)"
  [ -n "$w" ]
  [ -n "$s" ]
  # 열거 붕괴 바닥값 — 0건이면 '차이 없음'이 아니라 파싱이 깨진 것이다.
  n="$(printf '%s\n' "$s" | grep -c . || true)"
  [ "$n" -ge 5 ]
  [ "$w" == "$s" ] || { echo "감시 집합 != 스케줄 워크플로 집합"; echo "watched:"; echo "$w"; echo "scheduled:"; echo "$s"; false; }
}

@test "every age budget is at least three cron periods (single miss must not page)" {
  bad=""
  while read -r wf period; do
    [ -n "$wf" ] || continue
    budget="$(watched | grep "^${wf}=" | sed 's/.*=//')"
    [ -n "$budget" ] || { echo "예산 없음: $wf"; false; }
    min=$(( period * 3 ))
    if [ "$budget" -lt "$min" ]; then bad="$bad $wf(budget=$budget < 3x${period}=$min)"; fi
  done <<EOF
$(scheduled)
EOF
  [ -z "$bad" ] || { echo "예산이 3주기 미만:$bad"; false; }
}

@test "the unauthenticated GitHub rate limit budget holds (watched x polls-per-hour <= 60)" {
  # 레포가 public이라 토큰이 없다 — 대가는 IP당 60 req/hr다. 크론을 올리거나 워크플로를 늘리면
  # 이 부등식이 먼저 깨져야 한다(안 그러면 라이브에서 403 → ScrapeIncomplete 소음으로 발견하게 된다).
  n="$(watched | grep -c . || true)"
  cron="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$MF" | grep -oE '[0-9]+')"
  [ -n "$cron" ]
  per_hour=$(( 60 / cron ))
  total=$(( n * per_hour ))
  [ "$total" -le 60 ] || { echo "rate limit 초과: ${n} 워크플로 x ${per_hour}회/시 = ${total} > 60"; false; }
}

@test "the bootstrap inequality holds (first heartbeat lands before the stale threshold)" {
  # 첫 하트비트 ≤ cron + activeDeadlineSeconds + 파드 예산 < GHALivenessExporterStale 임계.
  # 이게 깨지면 **최초 배포에 거짓 페이지**가 난다(digest-exporter가 같은 자리에서 배운 계약).
  cron_min="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$MF" | grep -oE '[0-9]+')"
  ads="$(grep -oE 'activeDeadlineSeconds: [0-9]+' "$MF" | grep -oE '[0-9]+')"
  thr="$(grep -oE 'gha_liveness_last_success_timestamp\[6h\]\)\) > [0-9]+' "$R6" | grep -oE '[0-9]+$')"
  [ -n "$cron_min" ]; [ -n "$ads" ]; [ -n "$thr" ]
  first=$(( cron_min * 60 + ads + 60 ))
  [ "$first" -lt "$thr" ] || { echo "부트스트랩 부등식 위반: 첫 하트비트 ${first}s >= 임계 ${thr}s"; false; }
}

@test "the rollup window is at least the push period (no series hole under the instant lookback)" {
  # push 주기 > vmalert instant 룩백이면 시리즈에 구멍이 생겨 for: pending이 매 주기 리셋된다
  # = 영구 무발화(ImageDigestDrift의 원래 버그). 윈도가 주기보다 커야 그 구멍을 덮는다.
  cron_min="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$MF" | grep -oE '[0-9]+')"
  # 룰이 쓰는 윈도는 [3h] — 초로 환산해 비교한다.
  run grep -q 'gha_workflow_last_success_timestamp\[3h\]' "$R6"
  [ "$status" -eq 0 ]
  [ $(( cron_min * 60 )) -le 10800 ]
}

@test "the heartbeat is the LAST line of the payload (streaming truncation is fail-closed)" {
  # /api/v1/import/prometheus는 스트리밍 인입이라 중도 절단 시 **읽은 접두부만** 적재된다.
  # 하트비트가 앞에 있으면 '하트비트는 적재 / 나머지는 유실'이 가능해져 두 알림이 모두 무성해진다.
  last="$(grep -n 'OUT="\${OUT}' "$MF" | tail -1)"
  echo "$last" | grep -q 'gha_liveness_last_success_timestamp' \
    || { echo "마지막 exposition 줄이 하트비트가 아니다: $last"; false; }
}

@test "SCRAPED increments only after both failure checks (partial failure must not read as success)" {
  # 앞에 두면 전건 실패에도 scraped == configured로 오보고되어 부분 고장이 영영 무성해진다.
  lookup="$(grep -n 'gha run lookup failed' "$MF" | cut -d: -f1)"
  parse="$(grep -n 'gha timestamp parse failed' "$MF" | cut -d: -f1)"
  inc="$(grep -n 'SCRAPED=\$((SCRAPED+1))' "$MF" | cut -d: -f1)"
  [ -n "$lookup" ]; [ -n "$parse" ]; [ -n "$inc" ]
  [ "$inc" -gt "$lookup" ]
  [ "$inc" -gt "$parse" ]
}

@test "the scrape counters are bare series (a label on one side would empty the comparison)" {
  # 룰이 on()/ignoring() 없이 1:1 스칼라 비교를 하므로 한쪽에만 라벨이 붙으면 매치가 사라져 알림이 죽는다.
  run grep -qE 'OUT="\$\{OUT\}gha_liveness_configured \$\{CONFIGURED\}' "$MF"
  [ "$status" -eq 0 ]
  run grep -qE 'OUT="\$\{OUT\}gha_liveness_scraped \$\{SCRAPED\}' "$MF"
  [ "$status" -eq 0 ]
  # 라벨이 붙으면 red — `{`가 메트릭 이름 뒤에 오면 안 된다.
  run grep -qE 'gha_liveness_(configured|scraped)\{' "$MF"
  [ "$status" -ne 0 ]
}

@test "the CronJob bounds itself (Replace + activeDeadlineSeconds + no service account token)" {
  run grep -q 'concurrencyPolicy: Replace' "$MF"; [ "$status" -eq 0 ]
  run grep -qE 'activeDeadlineSeconds: [0-9]+' "$MF"; [ "$status" -eq 0 ]
  run grep -q 'automountServiceAccountToken: false' "$MF"; [ "$status" -eq 0 ]
  run grep -q 'readOnlyRootFilesystem: true' "$MF"; [ "$status" -eq 0 ]
}

@test "the exporter image is byte-identical to the digest-exporter reference (intentional reuse)" {
  # 같은 repo:tag@digest를 쓰면 G2 소유권 회계의 '같은 태그는 같은 digest' 불변식이 두 파일을 함께
  # 묶어 준다 — 한쪽만 bump하면 그 가드가 red를 낸다. 새 이미지를 들이면 소유권 항목·핀 갱신 대상이 는다.
  a="$(grep -oE 'quay\.io/skopeo/stable:[^ ]+' "$MF" | head -1)"
  b="$(grep -oE 'quay\.io/skopeo/stable:[^ ]+' platform/victoria-stack/prod/digest-exporter.yaml | head -1)"
  [ -n "$a" ]
  [ "$a" == "$b" ]
}

@test "egress is locked to DNS, vmsingle and external 443 with no pod-CIDR ipBlock" {
  NP="platform/victoria-stack/prod/networkpolicy.yaml"
  run grep -q 'gha-liveness-exporter-default-deny-egress' "$NP"; [ "$status" -eq 0 ]
  run grep -q 'gha-liveness-exporter-allow-egress' "$NP"; [ "$status" -eq 0 ]
  # pod CIDR ipBlock은 default-deny를 무력화하는 검증된 함정이다.
  # ⚠️ 주석을 세면 안 된다 — 이 파일은 그 함정을 **경고하는 주석**에 같은 문자열을 담고 있다(실측:
  #    단순 grep이 그걸 매치해 거짓 red를 냈다). 실제 `cidr:` 값만 본다.
  run grep -E '^[^#]*cidr:' "$NP"
  [ "$status" -eq 0 ]
  out="$output"
  run grep -q '10\.42\.' <<<"$out"
  [ "$status" -ne 0 ]
}

@test "all three liveness alerts exist and the per-workflow one compares against the pushed budget" {
  for a in GHAWorkflowStale GHALivenessExporterStale GHALivenessScrapeIncomplete; do
    run grep -q "alert: $a" "$R6"; [ "$status" -eq 0 ] || { echo "룰 없음: $a"; false; }
  done
  # 임계값을 룰에 하드코딩하지 않았는지 — 예산 메트릭과 비교해야 한다(주기가 10분~1주로 갈린다).
  run grep -q 'gha_workflow_max_age_seconds' "$R6"
  [ "$status" -eq 0 ]
}
