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

_fixture() {                 # $1 = BULK_MIGRATION_WINDOW_UNTIL 값 · $2 = findmnt이 답할 bulk SOURCE(선택)
  FX="$BATS_TEST_TMPDIR/fx$RANDOM"
  mkdir -p "$FX/scripts" "$FX/infra/k3s-bootstrap" "$FX/bin"
  cp "$sh" "$FX/scripts/destroy-node.sh"
  { printf 'export BULK_MIGRATION_WINDOW_UNTIL="%s"\n' "$1"
    printf 'export BULK_STORAGE_PATH="/mnt/bulk"\n'; } > "$FX/infra/k3s-bootstrap/versions.env"
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
  export FX REC_LOG PATH FM_SRC
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
