#!/usr/bin/env bats
# 호스트 systemd 유닛 실패의 **즉시 채널** 회귀 가드 — `OnFailure=` → textfile collector → r4 알림.
#
# 병: oneshot이 실패해도 울 채널이 0개였다(`OnFailure=` 레포 유닛 0건 + node-exporter에 systemd
# 콜렉터 없음). 유일한 신호는 신선도 알림인데 **신선도는 원리적으로 주기보다 빨리 울 수 없다** —
# 배수를 조여도 하한이 1주기라 "1회 실패"의 즉시 관측이 구조적으로 불가능했다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  TREE="$ROOT/infra/k3s-bootstrap/host-config/etc/systemd/system"
  R4="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  NE="$ROOT/platform/victoria-stack/prod/node-exporter.yaml"
  N="$ROOT/scripts/notify-unit-failure.sh"
  TMPFILES="$ROOT/infra/k3s-bootstrap/host-config/etc/tmpfiles.d/10-k3s-node.conf"
}

_expr() { # $1=alert 이름 → r4 ConfigMap 안의 expr(주석 제거)
  yq '.data["r4.yaml"]' "$R4" | yq ".groups[].rules[] | select(.alert==\"$1\") | .expr" - | sed 's/#.*//'
}

@test "every timer-driven oneshot unit routes its failure to the notifier" {
  # 열거 바닥값 먼저 — 대상 0건을 '위반 0건'으로 읽지 않는다(글롭이 깨지면 이 루프는 공짜로 참이 된다).
  n=0
  for u in "$TREE"/*.timer; do
    [ -f "$u" ] || continue
    svc="${u%.timer}.service"
    [ -f "$svc" ] || { echo "짝 service 부재: $svc"; false; }
    n=$(( n + 1 ))
    grep -qE '^OnFailure=unit-failure-notify@%n\.service$' "$svc" \
      || { echo "OnFailure 미배선: $svc — 이 유닛의 실패는 신선도 알림이 1주기 뒤에 알릴 때까지 무성이다"; false; }
  done
  [ "$n" -ge 1 ] || { echo "timer 유닛을 하나도 못 찾았다 — 열거 붕괴"; false; }
}

@test "the notifier template exists and never chains OnFailure onto itself" {
  T="$TREE/unit-failure-notify@.service"
  [ -f "$T" ]
  grep -qF 'ExecStart=/home/ukyi/workspace/homelab/scripts/notify-unit-failure.sh %i' "$T"
  # 자기 자신에 달면 실패 루프가 된다.
  run grep -qE '^OnFailure=' "$T"
  [ "$status" -ne 0 ]
}

@test "no non-producer file writes metrics (the completeness guard cannot see outside its extensions)" {
  # 🔴 **실측된 구멍**(2026-08-20): `tools/lib/repo-walk.ts`의 producers 스코프 include는
  #    `\.(ya?ml|sh|m?[jt]s|py)$`라 `.service`·`.timer`·`Makefile`·`.conf`가 **확장자에서 탈락**한다.
  #    격리 사본에서 `files-data-backup.service`에 `ExecStopPost=… curl …/api/v1/import/prometheus`로
  #    **레지스트리에 없는 메트릭**을 push하게 하고 린터를 돌렸더니 "모드 A/B/C 위반 0"으로 통과했다.
  #    같은 push를 `scripts/*.sh`에 두면 즉시 FAIL이다. 즉 그 메트릭은 모드 C 검사를 원리적으로
  #    빠져나가고, rollup 없이 참조하는 룰이 배포돼도 아무도 막지 않는다 — **죽은 알림이 초록으로 태어난다.**
  # ⇒ 처방은 스코프 include를 넓히는 것이 **아니다**(그러면 다음 확장자가 똑같이 조용히 빠진다).
  #    **보형(complement)** 을 열거해 "생산자 확장자 밖 파일에는 쓰기 동사가 없다"를 단언한다.
  # ⚠️ 문서(prose)와 테스트 하네스는 정당하게 그 문자열을 담는다 — `repo-walk`의 TEST_HARNESS와
  #    같은 어휘로 뺀다. 그 둘을 빼고 남는 집합이 곧 "실행되는데 회계 밖인" 파일들이다.
  comp="$(git ls-files \
    | grep -vE '\.(ya?ml|sh|m?[jt]s|py)$' \
    | grep -vE '\.(md|txt)$|^docs/' \
    | grep -vE '\.bats$|(^|/)tests?/|(^|/)fixtures[^/]*/|(^|/)test_[^/]*$')"
  # 열거 붕괴 바닥값 — 0건이면 '위반 없음'이 아니라 글롭이 깨진 것이다(2026-08-20 실측 76건).
  n="$(printf '%s\n' "$comp" | grep -c . || true)"
  [ "$n" -ge 40 ] || { echo "보형 집합이 ${n}건으로 붕괴했다(기대 >=40) — 이 단언이 공허해진다"; false; }
  # 양성 대조 — 생산자 확장자 파일에는 실제로 그 문자열이 있다(패턴이 죽어 0건인 것을 초록으로 읽지 않는다).
  run bash -c "git ls-files '*.sh' '*.yaml' | tr '\n' '\0' | xargs -0 grep -lE 'api/v1/(import|write)' | grep -q ."
  [ "$status" -eq 0 ]
  bad="$(printf '%s\n' "$comp" | tr '\n' '\0' | xargs -0 grep -lE 'api/v1/(import|write)|--data-binary' 2>/dev/null || true)"
  [ -z "$bad" ] || { echo "생산자 확장자 밖에서 메트릭을 쓴다 — 완전성 가드가 이 메트릭을 영영 못 본다:"; echo "$bad"; false; }
}

@test "the notifier writes atomically and world-readable (the collector runs as nobody)" {
  # 부분 기록 파일을 읽으면 node_textfile_scrape_error 1이 되고, 0600이면 uid 65534가 못 읽는다.
  grep -qF 'mktemp' "$N"
  grep -qE '^mv -f "\$TMP" "\$OUT"$' "$N"
  grep -qE '^chmod 0644 "\$TMP"$' "$N"
}

@test "the notifier rejects unit names that could break the exposition format" {
  run bash "$N" 'evil"}injected{x="'
  [ "$status" -eq 2 ]
  run bash "$N"
  [ "$status" -eq 2 ]
}

@test "the notifier produces a parseable exposition line for a real unit name" {
  d="$BATS_TEST_TMPDIR/tf"
  run env NODE_EXPORTER_TEXTFILE_DIR="$d" bash "$N" files-data-backup.service
  [ "$status" -eq 0 ]
  f="$d/unit-failure-files-data-backup.service.prom"
  [ -f "$f" ]
  grep -qE '^systemd_unit_last_failure_timestamp\{unit="files-data-backup\.service"\} [0-9]+$' "$f"
  grep -qE '^# TYPE systemd_unit_last_failure_timestamp gauge$' "$f"
  # 0644 — 콜렉터가 읽을 수 있어야 한다(플랫폼 무관하게 마지막 3자리만 본다).
  [ "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")" = "644" ]
}

@test "node-exporter reads the textfile directory and the host declares it" {
  grep -qF -- '--collector.textfile.directory=/host/root/var/lib/node_exporter/textfile' "$NE"
  # `/`가 이미 /host/root에 마운트돼 있어야 그 경로가 성립한다 — 새 마운트를 늘리지 않는 것이 이 설계의 근거다.
  grep -qF 'mountPath: /host/root' "$NE"
  # 디렉토리는 부팅마다 보장돼야 한다 — 유닛의 mkdir은 '첫 실패 때'뿐이라 부재와 무실패가 구별되지 않는다.
  grep -qE '^d /var/lib/node_exporter/textfile 0755 root root -$' "$TMPFILES"
}

@test "the failure alert carries no absent guard (absence IS the healthy state)" {
  e="$(_expr SystemdUnitFailed)"
  [ -n "$e" ]
  run bash -c "printf '%s' \"\$1\" | grep -qF 'absent('" _ "$e"
  [ "$status" -ne 0 ]
  # 양성 대조 — 같은 파일의 다른 룰은 absent를 실제로 쓴다(패턴이 깨져 0건인 것을 초록으로 읽지 않는다).
  run bash -c "printf '%s' \"\$1\" | grep -qF 'absent('" _ "$(_expr FilesBackupStale)"
  [ "$status" -eq 0 ]
}

@test "the failure alert self-resolves through a bounded recency window and uses no rollup" {
  e="$(_expr SystemdUnitFailed)"
  printf '%s' "$e" | grep -qE '\(time\(\) - systemd_unit_last_failure_timestamp\) < [0-9]+'
  # ⚠️ rollup 금지 — 이 메트릭은 push가 아니라 스크레이프라 구멍이 없다. 씌우면 해소만 늦어진다.
  run bash -c "printf '%s' \"\$1\" | grep -qE '[a-z_]+_over_time'" _ "$e"
  [ "$status" -ne 0 ]
}

@test "the staleness threshold matches the sibling daily-backup family (1.16x of the timer period)" {
  # 형제(LocalBasebackup·R2Backup·PgDumpHedge·CacheBackup)는 전부 100000s = 86400s의 1.157배다.
  # FilesBackupStale만 180000s(2.083배)였고 그래서 1회 실패가 T+50.5h까지 무성이었다.
  printf '%s' "$(_expr FilesBackupStale)" | grep -qF -- '> 100000'
  [ "$(grep -c -- '> 100000' "$R4")" -ge 5 ]
  # 여유 산술: OnCalendar(86400) + RandomizedDelaySec(1800) + TimeoutStartSec(1800) = 90000 < 100000.
  T="$ROOT/infra/k3s-bootstrap/host-config/etc/systemd/system/files-data-backup.timer"
  S="$ROOT/infra/k3s-bootstrap/host-config/etc/systemd/system/files-data-backup.service"
  grep -qE '^OnCalendar=daily$' "$T"
  rnd="$(grep -oE '^RandomizedDelaySec=[0-9]+min' "$T" | grep -oE '[0-9]+')"
  tmo="$(grep -oE '^TimeoutStartSec=[0-9]+min' "$S" | grep -oE '[0-9]+')"
  [ -n "$rnd" ]; [ -n "$tmo" ]
  worst=$(( 86400 + rnd * 60 + tmo * 60 ))
  [ "$worst" -lt 100000 ] || { echo "최악 간격 ${worst}s >= 임계 100000s — 정상 동작이 오발화한다"; false; }
}
