#!/usr/bin/env bats
# 베어메탈 파괴 프리미티브(D-j)의 안전 불변식을 오프라인에서 강제한다 — 라이브 파괴 없이.
#
# ⚠️⚠️ **이 파일은 스크립트를 실제로 실행한다.** 안전은 세 겹이 함께 보장한다. 여기에 @test를
#    더할 때 셋을 모두 유지할 것 — 하나라도 빠지면 이 파일이 NUC에서 라이브 노드를 파괴한다.
#      (a) 픽스처 REPO_ROOT 위의 **복사본**을 돌린다(국면 A 게이트가 픽스처 versions.env를 읽는다).
#      (b) 모든 권한 명령이 K3S_RUN 시임을 지나므로, 시임에 argv 기록기를 꽂으면 아무것도 실행되지 않는다.
#      (c) 그래도 K3S_RUN이 새어 기본값 `sudo`가 될 경우에 대비해, PATH 앞에 **가짜 sudo**(같은 기록기)를 둔다.
#    2026-08-16에 에이전트 3개가 파괴 명령을 '실증하려고' 실제로 실행해 라이브 클러스터를 날렸다.
#    이 파일이 그 실증의 **유일하게 안전한 형태**다.
#
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    되돌리면 위 (a)~(c) 안전망을 지키는 @test들이 destroy-node.sh 부재에도 초록이 된다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
sh=scripts/destroy-node.sh
reader=infra/k3s-bootstrap/versions-read.sh

_fixture() {                 # $1 = BULK_MIGRATION_WINDOW_UNTIL 값 · $2 = findmnt이 답할 bulk SOURCE(선택)
  FX="$BATS_TEST_TMPDIR/fx$RANDOM"
  mkdir -p "$FX/scripts" "$FX/infra/k3s-bootstrap" "$FX/bin"
  cp "$sh" "$FX/scripts/destroy-node.sh"
  VENV="$FX/infra/k3s-bootstrap/versions.env"
  { printf 'export BULK_MIGRATION_WINDOW_UNTIL="%s"\n' "$1"
    printf 'export BULK_STORAGE_PATH="/mnt/bulk"\n'; } > "$VENV"
  # ⚠️ 픽스처는 versions.env **와 리더**를 함께 재합성한다. 리더는 자기 옆의 versions.env를
  #    기본 피연산자로 삼으므로(SCRIPT_DIR 관용구), 이 한 줄이 없으면 destroy-node.sh가 (2)에서
  #    '리더 비실행'으로 죽고 아래 국면 A 단언들이 조용히 vacuous해진다.
  cp "$reader" "$FX/infra/k3s-bootstrap/versions-read.sh"
  [ -x "$FX/infra/k3s-bootstrap/versions-read.sh" ]
  # 기본 SOURCE = 국면 B(별도 디바이스). 국면 A를 흉내 내려면 $2로 bind 소스를 준다.
  FM_SRC="${2:-/dev/nvme1n1p1}"
  # argv 기록기 — 권한 명령을 **기록만** 한다. 두 가지만 실물처럼 답한다:
  #   · `test -e`  파괴 후 확인 경로(남아 있지 않다)
  #   · `findmnt`  (2b) bind 소스 게이트가 판정에 쓰는 값
  #   · `command -v findmnt` 존재 확인
  cat > "$FX/bin/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC_LOG"
case "$*" in
  "test -e "*)            exit 1 ;;   # 파괴 후: 남아 있지 않다
  "command -v findmnt")   exit 0 ;;
  "findmnt "*)            printf '%s\n' "$FM_SRC"; exit 0 ;;
esac
REC
  chmod +x "$FX/bin/rec"
  cp "$FX/bin/rec" "$FX/bin/sudo"          # (c) 2중 방어 — 시임이 새도 여기서 잡힌다
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/bin/k3s-uninstall.sh"
  chmod +x "$FX/bin/k3s-uninstall.sh"
  REC_LOG="$FX/argv.log"; : > "$REC_LOG"
  PATH="$FX/bin:$PATH"
  export FX VENV REC_LOG PATH FM_SRC
}
# 창 값을 **판정 불가**로 만드는 뮤테이션. 옛 sed 파생(`… 2>/dev/null || true`)에서는 넷 다
# 빈 문자열로 접혀 "국면 B — 파괴해도 좋다"로 읽혔다. 이 4종이 그 fail-open의 직접 증인이다.
_break_window() {            # $1 = 뮤테이션 이름 (_fixture 뒤에 부른다)
  case "$1" in
    file-missing) rm -f "$VENV" ;;
    key-missing)  printf 'export BULK_STORAGE_PATH="/mnt/bulk"\n' > "$VENV" ;;
    unquoted)     { printf 'export BULK_MIGRATION_WINDOW_UNTIL=\n'
                    printf 'export BULK_STORAGE_PATH="/mnt/bulk"\n'; } > "$VENV" ;;
    duplicate)    printf 'export BULK_MIGRATION_WINDOW_UNTIL=""\n' >> "$VENV" ;;
    *)            return 1 ;;
  esac
}
_run_destroy() {             # 나머지 인자는 env 오버라이드
  run env "$@" FM_SRC="$FM_SRC" K3S_RUN="$FX/bin/rec" bash "$FX/scripts/destroy-node.sh"
}

@test "destroy-node exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

@test "destroy-node REFUSES without the explicit confirmation env (and touches nothing)" {
  _fixture ''
  _run_destroy K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'DR_DRILL_DESTROY_CONFIRM=1'
  run bash -c "grep -c . '$REC_LOG' || true"
  printf '%s' "$output" | grep -qx '0'          # 권한 명령이 하나도 나가지 않았다
}

@test "destroy-node REFUSES while the phase-A bulk window is open, even WITH the confirmation" {
  _fixture 2026-12-31
  _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'DESTROY ABORT: 국면 A'
  printf '%s' "$output" | grep -qF -- '2026-12-31'
  run bash -c "grep -c . '$REC_LOG' || true"
  printf '%s' "$output" | grep -qx '0'
}

@test "destroy-node REFUSES when the window value is UNDECIDABLE (the old sed folded all of these to empty)" {
  # ⚠️ 이 @test가 티켓 07의 본안이다. 옛 파생은 파일 부재 · 키 부재 · 줄 포맷 변경 · 중복을 **전부**
  #    빈 문자열로 접었고, 바로 아래 `[ -n ]`이 그 넷을 모두 "국면 B, 파괴 허용"으로 읽었다.
  #    같은 파일의 BULK_STORAGE_PATH는 반대로 fail-closed였다 — 한 파일 안의 그 비대칭이 병소였다.
  # ⚠️ 완화 사실(무효화되는 것이 무엇인지 정확히 적는다): (2b)의 findmnt 정체성 게이트가 뒤에 있으므로
  #    옛 형태에서도 **데이터 유실까지 가지는 않았다.** 깨지는 것은 dr-drill.sh 헤더가 명시한
  #    "거부가 부작용 0으로 끝난다"는 성질이다 — 거부가 권한 상승 조회 뒤로 밀린다.
  for m in file-missing key-missing unquoted duplicate; do
    _fixture ''
    _break_window "$m"
    _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
    [ "$status" -ne 0 ]
    # 진단은 **판정 불가**를 말해야 한다 — "창이 비었다"가 아니다.
    printf '%s' "$output" | grep -qF -- 'BULK_MIGRATION_WINDOW_UNTIL을 판정하지 못했다'
    # 리더가 낸 사유 토큰이 실제로 흘러나온다(리더가 조용히 죽으면 이 줄이 red다).
    printf '%s' "$output" | grep -qE 'versions-read: (FILE_MISSING|KEY_MISSING|MALFORMED|DUPLICATE):'
    # 권한 명령이 하나도 나가지 않았다 — 거부가 부작용 0으로 끝난다.
    run bash -c "grep -c . '$REC_LOG' || true"
    printf '%s' "$output" | grep -qx '0'
  done
}

@test "a DECLARED empty window still destroys — undecidable and legitimately-empty are different things" {
  # ⚠️ 위 @test의 짝이다. 리더가 '전부 거부'로 퇴화하면 이 자리가 red다 — 그것이 곧
  #    "빈 값도 못 읽는다"는 회귀이고, 국면 B에서 드릴이 영영 못 도는 상태다.
  _fixture ''
  grep -qxF 'export BULK_MIGRATION_WINDOW_UNTIL=""' "$VENV"   # 양성 대조: 창이 **선언된** 빈 값이다
  _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
  [ "$status" -eq 0 ]
  grep -qF -- 'rm -rf /var/lib/rancher' "$REC_LOG"
}

@test "destroy-node REFUSES when the versions.env reader is absent or not executable" {
  # ⚠️ 리더가 실행 비트를 잃으면(형제 bulk-gate-probe.sh가 644다) 판정 경로가 통째로 사라진다.
  #    그 상태는 '국면 B'가 아니라 판정 불가다.
  _fixture ''
  chmod -x "$FX/infra/k3s-bootstrap/versions-read.sh"
  _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '리더가 실행 가능하지 않다'
  run bash -c "grep -c . '$REC_LOG' || true"
  printf '%s' "$output" | grep -qx '0'
}

@test "both versions.env derivations go through the reader (no sed one-liner survives)" {
  # 소비자 2곳이 **각각** 리더를 지난다 — 개수가 아니라 키 이름으로 잠근다(손 관리 수치 금지).
  grep -qE '^[^#]*"\$VERSIONS_READ" BULK_MIGRATION_WINDOW_UNTIL' "$sh"
  grep -qE '^[^#]*"\$VERSIONS_READ" BULK_STORAGE_PATH' "$sh"
  # 옛 관용구가 되살아나면 red. `^[^#]*` — 이 파일과 destroy-node.sh 양쪽 **주석이 같은 리터럴을
  # 담고 있어서**(fail-open의 근거를 적은 자리) 전체 줄 grep은 주석에 걸려 거짓 red를 낸다.
  run grep -nE "^[^#]*sed -n 's/\^export " "$sh"
  [ "$status" -eq 1 ]
}

@test "destroy-node fails loudly when the k3s uninstaller is absent (absence is not 'nothing to do')" {
  _fixture ''
  _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/nope.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'k3s 언인스톨러가 없다'
  # ⚠️ 여기서는 로그가 **비어 있지 않다** — (2b) bind 소스 게이트가 그 앞에서 읽기 전용 조회
  #    (`command -v findmnt` · `findmnt <bulk>`)를 하기 때문이다. 그러니 '0줄'이 아니라
  #    **파괴 명령이 없음**을 단언한다. (앞의 두 @test는 (2b)에 닿기 전에 거부하므로 0줄이 맞다.)
  run grep -cE 'rm -rf|k3s-uninstall' "$REC_LOG"
  printf '%s' "$output" | grep -qx '0'
}

@test "with the window cleared it DOES destroy: uninstaller plus the rancher tree (positive control)" {
  # 이게 없으면 '항상 거부하는' 죽은 스크립트도 위 세 @test를 전부 통과한다.
  _fixture ''
  _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "$FX/bin/k3s-uninstall.sh" "$REC_LOG"
  # ⚠️ k3s-uninstall.sh는 /var/lib/rancher/k3s만 지운다 — k3s-storage/internal(standard 클래스 PV)이
  #    남으면 '노드 유실'이 거짓이 되고 재구축이 옛 로컬 데이터 위의 부활을 위장한다.
  grep -qF -- 'rm -rf /var/lib/rancher' "$REC_LOG"
}

@test "destroy-node never swallows a failed destruction (no '|| true' on privileged calls)" {
  grep -qE '^[^#]*\$K3S_RUN' "$sh"                 # 양성 대조: 권한 호출이 실재한다
  run grep -nE '^[^#]*\$K3S_RUN.*\|\|[[:space:]]*true' "$sh"
  [ "$status" -eq 1 ]
  # ⚠️ 한 줄 안에서만 보면 **줄바꿈 연결로 우회된다**(`$K3S_RUN rm -rf … \` + 다음 줄 `|| true`).
  #    **파괴** 명령 줄이 백슬래시로 이어지지 않는다는 것까지 잠근다.
  # ⚠️ 검사 범위를 파괴 호출로 좁힌다 — 게이트의 읽기 전용 조회(`$K3S_RUN command -v findmnt \`)는
  #    정당하게 이어진다. 넓게 잡으면 그 줄에 걸려 이 @test가 거짓 red를 낸다(실측: 그렇게 됐다).
  grep -qE '^[^#]*\$K3S_RUN[^#]*(rm -rf|K3S_UNINSTALL)' "$sh"   # 양성 대조: 파괴 호출이 실재한다
  run grep -nE '^[^#]*\$K3S_RUN[^#]*(rm -rf|K3S_UNINSTALL)[^#]*\\$' "$sh"
  [ "$status" -eq 1 ]
}

@test "every privileged command goes through the K3S_RUN seam (a leak would destroy for real in tests)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — 예전 `-ne 0` 형태에서는 destroy-node.sh를 리네임하면
  #    grep이 rc 2로 죽고도 통과해, 이 파일에서 **혼자 초록으로 남았다**(2026-08-29 격리 트리 실측).
  run grep -nE '^[[:space:]]*sudo ' "$sh"
  [ "$status" -eq 1 ]
}

@test "destroy-node REFUSES when bulk's bind source lives inside the tree it deletes" {
  # ⚠️ 이 @test가 이 파일에서 가장 중요하다. `/mnt/bulk`라는 **경로**만 보면 파괴 대상과 겹치지
  #    않아 보이지만, 국면 A에서 그 bind **소스**는 /var/lib/rancher/k3s-storage/bulk다
  #    (versions.env 실측 SOURCE: /dev/mapper/ubuntu--vg-ubuntu--lv[/var/lib/rancher/k3s-storage/bulk]).
  #    즉 `rm -rf /var/lib/rancher`가 files-data(git+R2+age로 재구축 불가)를 **실제로 지운다.**
  # ⚠️ 창이 비어 있어도(=국면 B 선언) 거부해야 한다 — 선언과 사실이 갈리는 그 상태가 정확히
  #    이 게이트의 존재 이유다("창만 비우고 M.2는 안 꽂았다"). 레포 SSOT: "두 국면의 구별은
  #    경로가 아니라 디바이스 정체성으로 한다"(versions.env).
  _fixture '' '/dev/mapper/ubuntu--vg-ubuntu--lv[/var/lib/rancher/k3s-storage/bulk]'
  _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'bind 소스가 파괴 대상 안에 있다'
  # 파괴 명령이 하나도 나가지 않았다 — findmnt/command -v 조회만 기록돼 있어야 한다.
  run grep -cF -- 'rm -rf' "$REC_LOG"
  printf '%s' "$output" | grep -qx '0'
}

@test "the bind-source gate refuses when findmnt is missing (absence is not proof of safety)" {
  _fixture ''
  # 기록기에서 `command -v findmnt`만 실패시킨다 — 나머지는 그대로.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$REC_LOG"\ncase "$*" in "command -v findmnt") exit 1 ;; "test -e "*) exit 1 ;; esac\n' > "$FX/bin/rec"
  chmod +x "$FX/bin/rec"
  _run_destroy DR_DRILL_DESTROY_CONFIRM=1 K3S_UNINSTALL="$FX/bin/k3s-uninstall.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'findmnt가 없다'
  run grep -cF -- 'rm -rf' "$REC_LOG"
  printf '%s' "$output" | grep -qx '0'
}
