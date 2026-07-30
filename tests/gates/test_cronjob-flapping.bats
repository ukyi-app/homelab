#!/usr/bin/env bats
# CronJobFlapping의 **관측 가능성** 게이트 — 룰이 셀 수 있는 것만 세는지 검증한다.
#
# 병: 이 알림은 "최근 창 안에 실패한 실행이 N회 이상"을 센다. 그런데 실패 Job 오브젝트의 수명은
# `failedJobsHistoryLimit`가 지배하므로, 그 값이 N 미만인 CronJob은 **원리적으로 N을 셀 수 없다** —
# 룰은 문법상 멀쩡하고 알림도 조용한데 그 워크로드는 감시에서 통째로 빠진다(무성 무측정).
# 실제로 digest-exporter·gha-liveness-exporter가 기본값 1이었고, 후자는 하트비트 임계가 3주기라
# 교대 실패가 어느 알림에도 안 잡히는 사각지대였다.
#
# ⚠️ 감시 목록을 **하드코딩과 대조하지 않는다**(티켓 07 D-1에서 배운 클래스). 룰의 임계와 각 CronJob의
#    limit을 **레포에서 계산해** 대조하므로, 새 CronJob이 생기거나 임계가 바뀌면 자동으로 red가 된다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  CORE="platform/victoria-stack/prod/rules/core.yaml"
  ALERT=CronJobFlapping
}

# 룰 expr에서 발화 임계(`>= N`)를 뽑는다. 추출 실패는 빈 값(호출부가 fail-closed).
flap_threshold() {
  yq '.data["core.yaml"]' "$CORE" \
    | yq '.groups[].rules[] | select(.alert=="'"$ALERT"'") | .expr' \
    | sed 's/#.*//' | grep -oE '>=[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | tail -1
}

# 룰의 for:(초) — 창 하한 부등식의 항이다.
flap_for() {
  yq '.data["core.yaml"]' "$CORE" \
    | yq '.groups[].rules[] | select(.alert=="'"$ALERT"'") | .for' \
    | sed 's/m$/*60/; s/h$/*3600/; s/s$//' | bc 2>/dev/null
}

# 룰 expr에서 최근성 창(초)을 뽑는다.
flap_window() {
  yq '.data["core.yaml"]' "$CORE" \
    | yq '.groups[].rules[] | select(.alert=="'"$ALERT"'") | .expr' \
    | sed 's/#.*//' | grep -oE '\)[[:space:]]*<[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1
}

# 추적된 매니페스트의 모든 CronJob을 "파일<TAB>이름<TAB>주기(초)<TAB>failedJobsHistoryLimit"로 낸다.
# ⚠️ 미지정 limit은 k8s 기본값 **1**이다 — 빈 값으로 두면 아래 부등식이 조용히 통과한다(fail-open).
cronjobs() {
  # ⚠️ **텍스트가 아니라 YAML로 판다.** 초판은 정규식으로 `kind: CronJob` 줄을 찾았는데, 그 가정이 두 번
  #    깨졌다: ① 인라인 `metadata: { name: x }`를 못 읽어 digest-exporter·gha-liveness-exporter를 조용히
  #    건너뛰었고(뮤테이션 M3), ② 같은 텍스트 가정을 바닥값 쪽에도 써서 `kind: "CronJob"`이나 주석 달린
  #    kind가 **양쪽에서 동시에** 사라지면 교차 대조가 무력해졌다(적대적 리뷰 R-4). yq는 문서를 파싱하므로
  #    인용·주석·플로우 스타일이 판정에 영향을 주지 않는다.
  local files
  files="$(cronjob_candidate_files)"
  [ -n "$files" ] || { echo "CronJob 후보 파일 0건 — 붕괴" >&2; return 2; }
  # 문서마다 kind/name/schedule/limit을 뽑는다. 미지정 limit은 k8s 기본값 **1**이다(빈 값이면 아래
  # 부등식이 조용히 통과한다 — fail-open). null 병합은 yq가 한다.
  # shellcheck disable=SC2086
  yq -N -o=tsv '[select(.kind == "CronJob")
                 | [.metadata.name, .spec.schedule, (.spec.failedJobsHistoryLimit // 1)]]
                | .[]' $files 2>/dev/null \
    | grep -v '^\s*$' \
    | bun -e '
        const rows = require("node:fs").readFileSync(0, "utf8").split("\n").filter((l) => l.trim());
        const out = [];
        for (const line of rows) {
          const [name, sched, lim] = line.split("\t");
          // ★ 조용한 스킵 금지 — CronJob 문서인데 필드를 못 뽑으면 "대상 아님"이 아니라 파서가 깨진 것이다.
          if (!name || !sched || name === "null" || sched === "null") {
            console.error("CronJob 문서에서 name/schedule 추출 실패(fail-closed): " + line);
            process.exit(2);
          }
          const [min, hour, dom, , dow] = sched.trim().split(/\s+/);
          let period, mm, hh;
          if ((mm = /^\*\/(\d+)$/.exec(min))) period = Number(mm[1]) * 60;
          else if ((hh = /^\*\/(\d+)$/.exec(hour))) period = Number(hh[1]) * 3600;
          else if (/^[0-6]$/.test(dow)) period = 604800;
          else if (dom === "*" && /^\d+$/.test(hour)) period = 86400;
          else { console.error("알 수 없는 cron 형태(fail-closed): " + name + " = " + sched); process.exit(2); }
          out.push([name, period, Number(lim)].join("\t"));
        }
        if (!out.length) { console.error("CronJob을 하나도 못 찾았다 — 열거 붕괴"); process.exit(2); }
        console.log(out.join("\n"));
      '
}

# CronJob을 담을 **수 있는** 파일만 좁힌다. yq에 추적 yaml 175개를 한꺼번에 넘기면 파일 열기에서
# 죽는다(실측 — fd 한도로 보인다). 좁히기는 `CronJob` **문자열 포함**이라는 최소 가정만 쓴다:
# `kind: "CronJob"`·`kind: CronJob # 주석`·플로우 스타일 모두 이 그물에 걸리고, kind 값이 CronJob인
# 문서가 그 문자열 없이 존재할 수는 없다. 정확한 판정은 전적으로 yq(YAML 파싱)가 한다.
cronjob_candidate_files() {
  git grep -l -F 'CronJob' -- 'platform/**/*.yaml' 2>/dev/null || true
}

# 레포의 CronJob 문서 수 — 열거 바닥값의 **독립 소스**다(열거는 필드 추출까지 성공한 것만 센다).
cronjob_doc_count() {
  local files
  files="$(cronjob_candidate_files)"
  [ -n "$files" ] || { echo 0; return; }
  # shellcheck disable=SC2086
  yq -N '[select(.kind == "CronJob")] | length' $files 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

@test "the rule exposes a threshold and a recency window this gate can read" {
  t="$(flap_threshold)"; w="$(flap_window)"
  [ -n "$t" ] || { echo "임계 추출 실패 — expr 형태가 바뀌었다면 이 게이트도 함께 고쳐라"; false; }
  [ -n "$w" ] || { echo "최근성 창 추출 실패 — expr 형태가 바뀌었다면 이 게이트도 함께 고쳐라"; false; }
  [ "$t" -ge 2 ] || { echo "임계 ${t} — 1 이하면 단발 실패가 발화해 KubeJobFailed와 역할이 겹친다"; false; }
  [ "$w" -gt 0 ]
}

@test "every in-scope CronJob can actually reach the rule threshold (history limit is the observation window)" {
  # 대상: **주기 < 최근성 창**인 CronJob만. 주기가 창보다 길면 창 안에 2회가 물리적으로 불가능하므로
  # 이 알림의 대상이 아니고(전용 staleness가 지킨다), limit을 올릴 이유도 없다.
  t="$(flap_threshold)"; w="$(flap_window)"
  [ -n "$t" ]; [ -n "$w" ]
  f="$(flap_for)"
  [ -n "$f" ] || { echo "for: 추출 실패"; false; }
  bad=""
  narrow=""
  n=0
  inscope=0
  while IFS=$'\t' read -r name period lim; do
    [ -n "$name" ] || continue
    n=$(( n + 1 ))
    [ "$period" -lt "$w" ] || continue     # 저빈도 — 대상 밖
    inscope=$(( inscope + 1 ))
    # ★★ 하한은 **임계 + 1**이다(임계와 같으면 안 된다). 룰이 "복구된" 실패만 세므로, 새 실패가 도착하는
    #   순간 CronJob 컨트롤러가 가장 오래된 것을 회수하는데 그 새 실패는 아직 **미해소라 세어지지 않는다** →
    #   유효 count가 임계 아래로 떨어진다. 그 리셋이 매 주기 반복되면 `for:`를 영영 못 채운다.
    #   실측 시나리오(adguard, 주기 600s, for 900s, limit 2): F1/S1/F2/S2로 count=2 → pending 시작,
    #   600s 뒤 F3 도착 → F1 회수 → count=1 → pending 리셋 → **영구 무발화**(적대적 리뷰 r2).
    need_lim=$(( t + 1 ))
    if [ "$lim" -lt "$need_lim" ]; then
      bad="$bad ${name}(limit=${lim} < 임계+1=${need_lim})"
    fi
    # ★ 창 하한 — 교대 실패는 실패 간격이 **2주기**다. 창이 `2×주기 + for`보다 좁으면 두 번째 실패가
    #   나타나는 순간 첫 번째가 밀려나 count가 임계에 **영원히 도달하지 못한다**(적대적 리뷰 R-1:
    #   창 3600s + gha-liveness 주기 1800s에서 실제로 그랬다). 이 부등식이 그 상태를 red로 만든다.
    need=$(( 2 * period + f ))
    if [ "$w" -le "$need" ]; then
      narrow="$narrow ${name}(창=${w}s <= 2×${period}+${f}=${need}s)"
    fi
  done <<EOF
$(cronjobs)
EOF
  # 열거 붕괴 바닥값 — **독립 소스**(yq 문서 카운트)와 대조한다. 고정 상수는 조용한 스킵을 못 잡고
  # (초판 `-ge 5`가 2건 스킵을 통과시켰다 — 뮤테이션 M3), 같은 파서로 세면 양쪽이 함께 깨진다(R-4).
  want_n="$(cronjob_doc_count)"
  [ "$want_n" -ge 5 ] || { echo "레포에서 CronJob 문서를 ${want_n}건밖에 못 찾았다 — 열거 붕괴"; false; }
  [ "$n" -eq "$want_n" ] \
    || { echo "열거 ${n}건 != 레포의 CronJob 문서 ${want_n}건 — 파서가 일부를 조용히 건너뛰었다"; false; }
  # 대상이 0이면 이 게이트는 아무것도 검사하지 않은 것이다(창이나 주기 파싱이 깨졌을 때의 모습).
  [ "$inscope" -ge 1 ] || { echo "주기 < 창(${w}s)인 CronJob이 0건 — 이 알림이 감시하는 대상이 없다"; false; }
  [ -z "$narrow" ] || { echo "창이 교대 실패를 담지 못한다(2×주기+for 이하):$narrow"; false; }
  [ -z "$bad" ] || { echo "이 CronJob들은 임계를 원리적으로 셀 수 없다(무성 무측정):$bad"; false; }
}

@test "the flapping rule and KubeJobFailed read the same failure metric (they are two questions on one signal)" {
  # 둘이 다른 메트릭을 읽기 시작하면 "억제가 삼키는 영역을 짝 알림이 잡는다"는 계약이 조용히 깨진다.
  core="$(yq '.data["core.yaml"]' "$CORE")"
  for a in KubeJobFailed "$ALERT"; do
    e="$(printf '%s' "$core" | yq '.groups[].rules[] | select(.alert=="'"$a"'") | .expr' | sed 's/#.*//')"
    [ -n "$e" ] || { echo "expr 추출 실패: $a"; false; }
    printf '%s' "$e" | grep -q 'kube_job_failed' || { echo "$a 가 kube_job_failed를 읽지 않는다"; false; }
  done
}

@test "the firing e2e harness covers this alert (a rule with no firing leg is unmeasured)" {
  H="tests/gates/vmalert-jobfailed-firing-e2e.sh"
  [ -f "$H" ]
  run grep -q "FLAP_ALERT=$ALERT" "$H"
  [ "$status" -eq 0 ]
  # 발화·침묵 양방향 레그가 모두 있어야 한다 — 한쪽만이면 vacuity를 못 가른다.
  run grep -q 'run_scenario flapping' "$H"; [ "$status" -eq 0 ]
  run grep -q 'run_scenario single_failure' "$H"; [ "$status" -eq 0 ]
}
