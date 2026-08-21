#!/usr/bin/env bats
# make help 가독성 — 타겟이 정렬돼 나오는지(타겟이 늘면서 파일순 나열은 스캔이 어렵다).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "make help lists targets in sorted order" {
  # ⚠️ `--no-print-directory`가 계약이다. `make ci`가 이 bats를 부르면 MAKEFLAGS에 `w`가 실려
  #    서브-make가 `make: Entering directory '...'`를 **첫 줄로** 찍고, 아래 `awk '{print $1}'`가
  #    그 `make:`를 타깃 이름으로 집어 정렬이 깨진다(`m` > `a`). 단독 실행에서는 안 나오므로
  #    "혼자 돌리면 초록, make ci에서만 빨강"이 된다.
  #    맥(GNU Make 3.81)에서는 안 밟혔고 NUC(4.4.1)에서 발각됐다 — 2026-08-19 이관.
  # ⚠️⚠️ 기대값은 **절대 계약**(`LC_ALL=C sort`)이지 "네 로케일에서 정렬됐는가"가 아니다.
  #    앞선 판 `"$(echo "$names" | sort)"`는 **자기참조**라 호출 로케일이 질문과 답을 함께 바꿨다 —
  #    en_US에서는 recipe 출력도 기대값도 함께 흔들려 무엇이 계약인지 말할 수 없었다.
  #    cf. `docs/traps-detail.md` 「로케일 콜레이션이 게이트를 뒤집는다 …」
  # ⚠️ `grep -E '^[A-Za-z]'`도 `LC_ALL=C`로 감싼다 — 브래킷 범위는 콜레이션 의존이라 en_US에서
  #    악센트 소문자를 추가로 매치한다. **가드 자신이 로케일 의존이면 안 된다.**
  run make --no-print-directory help
  [ "$status" -eq 0 ]
  names="$(printf '%s\n' "$output" | awk '{print $1}' | LC_ALL=C grep -E '^[A-Za-z]')"
  [ -n "$names" ]
  # 열거 붕괴 바닥값 — 파싱이 깨져 1~2줄만 남으면 '정렬됨'은 공짜로 참이 된다(2026-08-20 실측 39개).
  [ "$(printf '%s\n' "$names" | grep -c .)" -ge 25 ]
  [ "$names" = "$(printf '%s\n' "$names" | LC_ALL=C sort)" ]
}

@test "make help lists every documented target — the floor cannot see a single silent omission" {
  # ★ 바닥값(≥25)은 "몇 개 이상인가"만 묻는다. 그래서 선언 40개 중 39개만 나와도 초록이었다 —
  #   빠진 하나가 `m6-tools`였고, 문자 클래스 `[a-zA-Z_-]`에 숫자가 없어 두 번째 문자 `6`에서
  #   앵커드 매치가 실패한 것이었다(실측 2026-08-21). 죽은 타깃도 아니었다: `ci:`의 선행조건이라
  #   실제로 도는데 도움말에만 없었다. **전단사**로 바꿔 그 클래스를 통째로 닫는다.
  # ⚠️ 기대 목록은 Makefile에서 **파생**한다 — 리터럴 로스터를 두면 다음 타깃이 이 레인 밖에서 태어난다.
  declared="$(LC_ALL=C grep -hE '^[a-zA-Z0-9_.-]+:.*## ' $(git ls-files 'Makefile') | cut -d: -f1 | LC_ALL=C sort -u)"
  [ -n "$declared" ]
  [ "$(printf '%s\n' "$declared" | grep -c .)" -ge 25 ]
  run make --no-print-directory help
  [ "$status" -eq 0 ]
  listed="$(printf '%s\n' "$output" | awk '{print $1}' | LC_ALL=C grep -E '^[A-Za-z0-9]' | LC_ALL=C sort -u)"
  [ "$declared" = "$listed" ]
}
