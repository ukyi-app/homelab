#!/usr/bin/env bash
# bats 단언-스타일 가드 — bats 「코드 표면」에서 **조용히 통과하는 단언 형태** 다섯 클래스를 잡는다.
# bats는 negated/[[ 명령의 실패를 errexit/ERR-trap 면제로 침묵 통과시킨다(라이브 확증: bats 1.13에서
# 중간 `! echo x|grep -q x`가 'ok'). 그런 중간 단언은 죽은(false-green) 가드다.
#   NEG(중간 `! `)  = 모든 bash에서 발생(negated pipeline은 set -e 면제) → hard-zero.
#   BB (중간 `[[ `) = bash 3.2 함정 변종 — **0 수렴 완료**, 이제 hard-zero다.
#     실증: bats 1.13에서 `[[ "$x" == *ABSENT* ]]`가 거짓인데 ok. 같은 자리를
#     `printf '%s' "$x" | grep -qF …`로 바꾸면 정확히 red가 난다(변환 전 53건은 전부 죽은 단언이었다).
#   ABS(부재 단언)  = `run grep …` + `[ "$status" … ]` 짝의 **철자와 형태** — 래칫으로 출발해
#     **0 수렴 완료**, 이제 hard-zero다(아래 ABS_BASELINE 줄이 상환 기록을 진다).
#   QV (`grep -qv`) = 줄 단위 반전이 전칭(∀¬)을 존재(∃¬)로 바꾼다 → hard-zero(아래).
#   SETCAP(이름 있는 집합의 상한 부재) = `@test` 이름이 exactly/only/no other/전수/EVERY/정확로
#     원소 전수를 선언하는데 본문에 그 상한을 재는 술어가 없다 — hard-zero 도달 후 술어 자체의
#     결함(traps-ops-2, 2026-09-05)이 드러나 **래칫으로 재개장**했으나, 12라운드 분류(predicate 8·
#     rename 18)가 잔액을 전부 상환해 **다시 hard-zero로 복귀**했다(티켓 78, 아래 SETCAP_BASELINE).
# 휴리스틱: 다줄 @test 규약 가정("@test … {" 한 줄 시작, 0열 "}" 종료). heredoc 본문은 명령으로 안 센다.
# (레포 단일 한줄 @test는 단일 명령이라 무해 — 신규 한줄 본문은 다줄로 작성할 것.)
# 인자로 파일을 주면 그 파일만 스캔하고 다섯 클래스 아무거나 있으면 실패(픽스처/ad-hoc 탐지 모드).
# bash 3.2 호환: mapfile 금지(while read). shellcheck 클린.
#
# ── 코드 표면 = `@test` 본문 **+ 0열 함수 본문**(`setup()`·`teardown()`·헬퍼) ──────────────────
# 착지 전 이 검출기는 `^@test … {`로만 상태에 들어가서, 도메인에 있는 파일이어도 `@test` **밖** 줄은
# 전부 판정 밖이었다(그 갭은 이 헤더가 「부재-단언 클래스를 얹을 때의 몫」으로 계상해 뒀다).
# 이제 0열 `name() {` 본문도 같은 상태 기계에 들어간다. 근거 셋:
#   ① 함정이 같다 — 헬퍼는 @test에서 호출되므로 중간 `!`/`[[ ]]`의 errexit 면제가 그대로 전파된다.
#   ② `[ABS]`의 증인(비공허 바닥값·양성 대조)이 관례적으로 `setup()`과 스텁 팩토리에 산다.
#      본문을 못 보면 그 증인들이 **원리적으로** 안 보여 전건 위반이 된다.
#   ③ 대가가 0이다 — 착지 전 실측: 0열 함수 본문의 NEG·BB 신규 검출 **0건**(추적 288파일).
# ⇒ 그래서 `test_helper.bash`처럼 `@test`가 없는 seam 파일도 이제 실제로 판정된다: 자기 함수 본문이
#    위반 자리이자 같은 파일 `@test`들의 증인 공급처가 된다(04번이 넓힌 열거가 여기서 load-bearing).
#
# ── [ABS] — bats 부재 단언 ────────────────────────────────────────────────────────────────────
# 병: `run grep <경로> ; [ "$status" -ne 0 ]`은 **무매치(rc 1)와 대상 부재(rc 2)를 구별하지 않는다.**
# 피연산자가 리네임/삭제되면 "그 문자열이 없다"가 무증인 초록이 된다(SSOT: docs/traps-detail.md
# 「열거 붕괴 → vacuous green」③ 부정 카운트 · 그 「처방(bats 부재 단언)」).
# 두 레인이다 — **철자만 거부하면 안 된다**(설계 게이트 r1 · F3):
#   [ABS]      철자 — 대상 run의 판정이 `-ne 0`/`-gt 0`. 정확한 무매치는 `-eq 1` 하나다.
#   [ABS-REC]  형태 — 피연산자가 **재귀/디렉토리**인 부재 판정(`grep -r…` · 경로가 `/`로 끝남 ·
#              `git grep`)인데 같은 `@test`(또는 그 파일의 함수 본문)에 **비공허 바닥값과 양성
#              대조가 함께** 있지 않다. `-eq 1`로는 안 닫히는 자리다 — 빈 디렉토리 `grep -r`은
#              rc **1**이라 무매치와 값이 같다(실측).
#   [ABS-LOOP] 형태 — 같은 요구를 **루프 구동** 판정에 건다. 목록이 비면 반복 0회라 어떤 rc로도
#              안 보인다(`for d in $DISPATCHERS`가 실측 사례).
#   (bash -c 언랩) 형태(F3, 감사 63) — `run (bash|sh) -c '<본문>'`(홑따옴표만, `abs_target` 참조)의
#              본문 head가 grep 계열이면 그 안도 분모다. **본문에 파이프가 있으면 REC로 분류**한다 —
#              앞 grep의 rc 2가 파이프에 먹혀 `-eq 1`로도 안 닫히므로(재현: 부재 피연산자에 대해
#              `grep P "$1" | grep Q`는 `-ne 0`·`-eq 1` 양쪽 다 ok, 단일 `grep -qE P "$1"`은 rc 2가
#              살아 있어 `-eq 1`만 닫는다) 철자 판정을 면제하고 REC와 같은 floor∧양성대조 요구만
#              건다. 겹따옴표 래퍼(바깥 셸이 먼저 보간)는 대상 밖 — 실측(레포 전역) 이 형태는 홑따옴표
#              +위치인자(`"$1"`) 4곳뿐이라 분모를 그 리터럴 형태로 좁혀 둔다(과확장은 소유 밖 파일에
#              새 red를 만든다).
# ⚠️ **분모는 grep 계열 + 경로 피연산자뿐이다.** 히어스트링(`<<<`)은 경로가 없어 rc 2 채널 자체가
#    없고(그 자리의 `-ne 0`은 옳다 — 착지 시점 잔여 `-ne 0` 95곳이 **전부** 히어스트링이었다),
#    `run bash|bun|make|conftest`·`yq`·`jq`·`ls`는 (위 bash -c 언랩이 그 안에서 grep을 찾은 경우
#    제외) rc 알파벳이 grep과 달라 하나의 형태 규칙으로 말할 수 없다(실측: `bun <없는 파일>`=1인데
#    그 도구의 **거부**도 1 · `ls`는 무매치와 부재를 둘 다 2로 접는다). 이 구별이 없으면
#    `tests/gates/test_scan-floor.bats`처럼 18곳 전부 정당한 비대상인 파일이 영구 red 또는 영구
#    예외 목록 항목이 된다.
# ⚠️ **증인은 존재만 본다 — 피연산자로 연결하지 않는다.** 셸에서 피연산자 동일성은 정적으로 결정
#    불가능하고(변수·조립 경로·루프 변수), 결정하는 척하면 그 연결이 조용히 어긋나 이 가드 자신이
#    vacuous green이 된다. 형태 규칙은 "증인 두 종류가 스코프 안에 실재하는가"까지만 묻는다.
# ⚠️ ABS_BASELINE은 래칫으로 출발해 **0에 수렴했다**(BB_BASELINE 선례 그대로) — 이제 hard-zero다.
#    래칫 시절 남았던 건수는 "증인이 실재하지 않는다"가 아니라 "증인이 **기계가 읽는 형태로**
#    있지 않다"는 뜻이었고, 상환은 전부 그 형태를 세우는 방향이었다(잔액 줄의 실측 기록 참조).
#    scan-floor.sh:30-31이 금지하는 '손 관리 수치'와 다른 종류였다: 저건 아무도 대조하지 않는
#    도메인 건수고, 이건 **매 실행이 대조하는** 부채 잔액이라 드리프트가 곧 red였다.
#
# ── [QV] — `grep -qv`는 부재를 재지 않는다 ─────────────────────────────────────────────────────
# `-v`는 **줄 단위** 반전이라 `grep -qv TOKEN`은 "TOKEN이 없다"(∀¬)가 아니라 "TOKEN이 없는 줄이
# 하나라도 있다"(∃¬)다 — 피연산자가 두 줄 이상이면 TOKEN이 **있어도** rc 0이고, 반대로 입력이
# 통째로 비면 rc 1이라 진짜 부재에서 red다(SSOT 실측표: docs/traps-detail.md 「`grep -qv`는 부재를
# 재지 않는다」). 라이브 항진이 이 레포에서만 3곳 적발됐다(tailscale scopes · host-ports 6곳 ·
# ops-repin). **[ABS]와 같은 레인에 넣지 않는다**: 저건 run/status 짝의 rc 철자 문제고 이건 술어의
# 양화사가 뒤집히는 문제라 한 숫자로 접으면 그 수가 무엇의 잔액인지 말할 수 없게 된다. 라이브 0건이라
# 래칫할 부채도 없다 → hard-zero. (필터로 쓰는 `| grep -v '^---'` 류는 `-q`가 없어 대상이 아니다 —
# rc를 판정으로 쓰지 않기 때문이다.)
#
# ── [SETCAP] — 이름 있는 집합의 상한 부재 ──────────────────────────────────────────────────────
# 다른 축이다: 위 네 클래스는 "단언이 조용히 통과하는 형태"를 잡고, 이건 "이름이 상한을 선언하는데
# 본문이 그 상한을 재지 않는" **이름-본문 불일치**를 잡는다(SSOT: docs/traps-detail.md 「이름 있는
# 집합의 상한 부재」· CONTRIBUTING.md 「가드 스캔 신호」 형제 절 규칙 ①②. 근거: 5라운드 비평가
# 군집 ①(생존 12건) · 6라운드 재발 판정 ①(9건 — infra-a-1·a-3·b-4·kustomization-2/3/4·
# httproute-1/2·posture-2) · 7라운드 축 N).
# `@test` 이름에 exactly/only/no other/전수/EVERY/정확 중 하나가 있으면(대소문자 구별 그대로 —
# 표기 변형을 넓히면 다른 축이 된다, grep-a-1/grep-a-5의 재발과 같은 함정) 그 본문(다음 `@test`
# 또는 파일 끝까지, 0열 "}"가 경계)에 집합 등식 술어 — bracket-test 문자열 등식(`[ "$a" = "b" ]`) ·
# 수 등식(`-eq [0-9]+`) · jq/yq `contains(` · jq/yq `join(",")` · jq/yq `length ==` · jq/yq
# `== [` 배열 리터럴 등식 · `grep -qxF`/`grep -qx` 구조적 등식(전체 행 일치, traps-ops-2가 추가) —
# 중 하나 이상이 있어야 한다. 일곱 형태는 문안 그대로다(텍스트 매치이지 문장 위치·인용 anchor
# 요구 없음 — ABS/QV처럼 위치를 재는 레인이 아니라 **존재**만 잰다).
# ⚠️ **오탐은 면제 어휘가 아니라 이름 정정으로 닫는다.** 이름의 "only"가 집합이 아니라 단수
#    대상·시간 부사·복합어를 가리키는 자리(`read-only`·`owner-only`·`readonly` 같은 합성어,
#    "only when"류 조건 부사, "only 1"류 서술 수사)는 검출기가 **그대로** 잡는다 — 면제 조건을
#    넣지 않는다(아래 픽스처가 이 결정을 고정한다: 오탐 대조 픽스처가 여전히 red여야 한다).
#    처방은 그 이름에서 상한 어휘를 빼는 것 하나뿐이다(4·5라운드 규약 그대로 — 정직한 이름이 처방).
# ⚠️ **알려진 갭(다음 라운드 입력) — `-eq N`은 `"$status"` rc 검사와 구별하지 않는다.** 이
#    레인은 6라운드 비평가 처방 문안을 그대로 옮긴 것이라(「6라운드 비평가 처방 그대로」— 티켓 59),
#    `[ "$status" -eq 0 ]`처럼 이 레포 거의 모든 @test에 있는 흔한 관용구도 술어로 인정한다.
#    실측(2026-09-05): 이 관용구를 제외하고 재면 착수 시점 위반이 14건이 아니라 **70건**이다
#    (프로토타입 스크래치패드 실측 — 커밋되지 않음). 좁히지 않은 이유는 처방 문안을 벗어난
#    자체 확장이 이 축의 범위를 티켓 하나가 감당 못 할 크기로 불리기 때문이다(round7이 이미
#    "0건 finding + 규칙 문안 2개도 정당한 답"이라고 명시). 다음 라운드가 `-eq` 분모에서
#    `"\$status"` 좌변을 제외하는 방향으로 좁힐 후보다.
#    ⚠️ **순서 조건(7라운드 setcap-denominator-2 실측)** — 6번째 형태(jq/yq `== [` 배열 리터럴
#    등식)를 먼저 얹은 뒤에만 좌변 제외를 진행해야 한다. 그 형태 없이 좌변만 제외하면 이미
#    `jq -e '...enum == [...]'`로 완전히 상한이 잠긴 자리(test_schema_fail_closed.bats:53,62)가
#    새 위반으로 뒤집힌다 — 그 잠금이 뒤따르는 `[ "$status" -eq 0 ]`(jq 성공 rc)에 우연히
#    걸려 있었을 뿐이기 때문이다.
# SETCAP_BASELINE은 BB/ABS가 밟은 것과 같은 경로다 — 래칫으로 출발해(티켓 59, 착수 시점
# 위반 14건 중 11건은 단수/조건/합성어 오탐이라 이름 정정으로 닫았다) **0에 수렴**했다
# (티켓 64 c64-7, 2026-09-05). 남았던 3건(포트·볼륨·디스패처 입력 집합)은 각각 집합 등식
# 술어를 얻었다.
# ⚠️ **hard-zero에서 다시 래칫으로(traps-ops-2, 2026-09-05)** — setcap_hit의 문자열 등식
#    술어(`=[ \t]*"[^"]+"`)가 bracket-test 좌변(`[ "$a" = "b" ]`)이나 `$` 참조를 요구하지
#    않아, 스코프 안 아무 문자열 대입(`VAR="x"`) 하나로 무력화됐다(BB/ABS/QV가 밟은
#    가드-자신-무증인 클래스 재발). 처방: (1) 그 술어에 `=` 앞 공백 요구를 더해 대입과
#    bracket-test를 문법으로 구별하고(대입은 `=` 앞에 공백이 없다), (2) 이 레포가 실제로
#    선호하는 구조적 등식 관용구 `grep -qxF`/`grep -qx`(전체 행 일치 — platform/victoria-stack/
#    prod/test_pvc_du_exporter.bats:31-33)를 여섯째 술어로 추가했다. 두 교정을 함께 적용해
#    실 트리를 재측정(2026-09-05)하니 26건 — bracket-test 요구 전면화(34건)보다 8건 적은데,
#    그 8건이 정확히 새 grep-qx 술어가 새로 인정한 자리다. BB/ABS가 밟은 순서 그대로 **래칫
#    으로 재출발**한다(hard-zero 강행은 26곳 동시 재작업을 부른다 — 107-110행의 관례 위반).
#    남은 26건은 이름 어휘가 실제로 합성어/단수/조건부사인 오탐(read-only·name-only류, 이
#    검출기의 설계상 의도된 잔여 — 위 ⚠️ 오탐 규약)과 진짜 미상환 부채가 섞여 있었다.
# ⚠️ **다시 0으로(티켓 78, 2026-09-05)** — 12라운드 분류자+검토자 합의(predicate 8 · rename 18 ·
#    detector 0)가 26건 전건을 실측 검증해 착지했다. predicate 8건은 진짜 집합 상한 주장이라
#    술어를 얻었다(`[ -z "$bad" ]`류 부재 단언 → `bad_n=$(printf '%s' "$bad" | wc -w); [ "$bad_n"
#    -eq 0 ]` 건수 등식, 또는 `grep -c . || true` — `|| true` 누락은 위반 0건(정상 상태)에서
#    grep -c의 rc=1이 대입 자체를 set -e로 죽이는 별도 결함이라 처방에 반드시 포함). 그중 하나
#    (setcap-17, tests/gates/test_telegram-callsites.bats:51)는 이름 정정이 아니라 setcap_hit
#    자체에 여덟 번째 술어(자기유도 변수 등식, `-eq[ \t]+"?\$…[ \t]*\]` — bracket-test 종료
#    앵커 필수: 앵커 없이 제안된 원안 그대로 넣으면 reg-c-ledger-rows-1과 같은 급의 run-인자
#    오탐이 재발한다)를 추가했다. rename 18건은 실제로 단일 시나리오/조건 부사/합성어였다 —
#    뜻 보존한 채 상한 어휘만 뺐다(옛 이름 인용처 0건 확인). detector(이름-어휘 정규식 면제)는
#    0건 유지 — 하이픈 복합어 면제를 넣으면 진짜 ∀ 폐쇄 주장 2건(setcap-4/5)이 영구 무증인이
#    된다는 12라운드 재검증이 tests/gates/test_bats-style.bats:601의 오탐 대조 결정을 재확인했다.
#    전체 스캔 SETCAP 26/0 실측(2026-09-05) — hard-zero 복귀, 신규 위반은 즉시 red다.
#
# ── [ABS-EXEC] — 레포 소유 실행물 호출의 부재 단언(F4, 감사 63 · 설계 노트
#    `.scratch/audit-2026-09/design-abs-denominator.md` §6-C) ──────────────────────────────────
# 다른 분모다: [ABS]는 grep 계열 head만 본다(rc 알파벳이 grep 자신의 것이라 프로그램 rc 부재
# 단언과 다르다는 게 헤더 :42-47의 근거). 이 레인은 **레포가 소유한 실행물**(scripts/*.sh ·
# tools/*.ts · infra/**/*.sh · tests/gates/*.sh) 호출이 `-ne 0`/`-eq N`(N≠0) 등 비-0으로 판정되는
# 자리를 잰다 — 그 프로그램이 **거부했다**를 주장하는데, 부재/리네임/기동 실패로 죽어도 같은
# 판정이 나올 수 있기 때문이다(R1·R2가 이 티켓에서 실증). grep 계열은 [ABS] 분모에서 이미 빠지므로
# 이중 계상하지 않는다(`exec_target`이 `abs_target`을 먼저 물어 배제한다).
# ⚠️ **전면 문구 증인(echo/printf|grep 강제)이 아니다.** `docs/adr/0007`이 이미 기각한 자리다 —
#    S(스텁 계약 rc)·H(`helm template --set` 스키마 거부, rc가 계약)·Y(`yq -e`/`jq -e` 술어, rc가
#    술어값)처럼 **문구가 원리적으로 없는** 42레인이 반례이고, 예외 목록을 만들면 그 목록이 곧
#    ADR-0007이 기각한 "처방의 목록"이 된다. 그래서 증인은 **W1 ∨ W2** 접속이 아니라 선택(OR)이고,
#    분모도 grep이 아니라 "레포가 소유해 출력 계약을 우리가 정하는 실행물"로 좁혀 둔다(레포 밖
#    도구·helm/yq/jq 술어는 이 분모 밖).
#   W1(출력 문구 증인) = 같은 `@test`(또는 파일 스코프 함수)에 `echo "$output"`/`printf … "$output"`을
#      `grep -q`로 넘기는 지배 관용구(§5 실측 994+346건), **또는** `run bash -c '… "$1" …' _ "$out"`
#      위치-인자 형태(`docs/traps-detail.md` 「정적 증인의 두 함정」— bats 지역 변수가 `bash -c`
#      안에서 빈 문자열로 보이는 함정을 피하는 안전 관용구다. 이 갈래를 검출기가 안 읽으면 규약을
#      **지킨** 자리가 red가 된다 — `tests/test_dr-drill.bats`가 이 위험을 실증했다).
#   W2(양성 대조) = **같은 파일**에 **같은 도구 신원**(추출한 경로 리터럴)의 `[ "$status" -eq 0 ]`
#      레인 — `[ABS-REC]`가 이미 쓰는 존재-기반 판정과 같은 축이다(피연산자로 연결하지 않는다,
#      `:48` 규약 그대로).
# ABSEXEC_BASELINE은 hard-zero다 — **래칫 신설 금지**(설계 노트 §9). F1(adguard 2곳)·F2(나머지
# 10곳)가 먼저 잔액을 0으로 갚은 뒤에만 이 클래스를 켠다(BB·[ABS]가 밟은 순서 그대로).
#
# ⚠️ 이 가드는 ci.yaml·Makefile(`verify`·`ci`)의 **명시 스텝**이다 — 자기 bats에만 의존하면
#    `tests/.ci-exclude` 한 줄로 자기가 꺼진다(형제 check-bats-accounting.sh가 같은 근거로 거부한
#    자리). NEG·QV 두 hard-zero 클래스의 유일한 집행자가 한 줄로 꺼지면 안 되므로, 그 배선은
#    이 클래스의 별건 확대가 아니라 **전제**다. 패리티는 policy/ci-parity.json이 대조한다.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-bats-style
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "check-bats-style" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
cd "$ROOT"
# ⚠️ 래칫 수치에 env 오버라이드를 두지 않는다 — `BB_BASELINE_OVERRIDE`는 소비자 0인 채로 남아 있던
#    off-switch였다(env는 호출부에 보이지 않는 채로 판정을 끈다 — scan-floor.sh의 어휘 통일 근거 그대로).
BB_BASELINE=0    # **0 수렴 완료** — 이제 hard-zero다(NEG와 같은 규율). 신규 중간 [[ ]]는 즉시 red.
# 부재-단언 부채 잔액 — **0 수렴 완료**. 신규 [ABS]/[ABS-REC]/[ABS-LOOP]/[ABS-GIT]는 즉시 red다.
# 5→0으로 내린 세 자리와 실제 원인(2026-08-31 실측 — 자리마다 없던 절반이 달랐다):
#   test_app-token-sha-ssot 2 — 양성 대조가 없었다. setup의 `[ -d .github ]`에 비공허
#     (`[ -n "$(find .github -name '*.yaml' -print -quit)" ]`)를 더하고, 두 @test에 **같은
#     피연산자**(.github/)를 쓰는 `run grep -rlE '^on:' … ; [ "$status" -eq 0 ]`을 세웠다.
#   test_sealed-secrets-restore 2 — 없던 절반은 **바닥값**이다. 이 줄이 착지 전 적었던 "양성 대조는
#     스텁 팩토리 heredoc 안이라 형태 밖"은 오독이었다(실측 정정): 그 `grep -q … "$TMP/plaintext-probe"`
#     는 heredoc **밖**의 0열 함수 본문이라 이 검출기가 파일 스코프 양성 대조로 이미 읽고 있었다 —
#     그 한 줄만 지우면 두 자리가 그대로 재검출된다(격리 복사본에서 확인). 형태 밖이었던 건 바닥값
#     `[ "$(cat …)" = OLD-BACKUP ]`(커맨드 치환)뿐이고, 같은 사실을 `[ -s … ]`로 낸 것이 처방이다.
#   test_seal-secret 1 — `grep -rq`의 `-r`이 원인이다. 피연산자가 단일 파일이라 재귀는 무의미한데
#     그 플래그 하나가 자리를 REC로 읽히게 했다. `-r`을 떼면 FILE 형태라 `-eq 1`만으로 닫힌다.
# 올리는 방향은 부채 재유입이다 — 그래도 필요하면 같은 diff에서 이 줄을 고쳐야 하고, 그건 리뷰에
# 보인다(check-bats-accounting의 EXCL_MAX와 같은 성격).
ABS_BASELINE=0
# 이름 있는 집합의 상한 부재 부채 잔액 — 티켓 59가 래칫으로 착지(2026-09-05, baseline 3)했고
# **0 수렴 완료**(티켓 64 c64-7, 2026-09-05) — 이제 hard-zero다. 남았던 3건과 상환 형태:
#   test_worker_ports.bats:21 "web defaults to http only and no metrics scrape annotation" —
#     포트 집합에 `[.spec.template.spec.containers[].ports[]?.name] | sort | join(",")` = "http" 등식 추가.
#   test_basebackup.bats:12 "cronjob runs non-root 26 and mounts only bulk-ssd PVC" —
#     `[.spec.jobTemplate.spec.template.spec.volumes[].name] | sort | join(",")` = "backup" 등식 추가.
#   test_mutation-dispatch.bats:204 "each dispatcher references inputs only via env or with: …" —
#     `[ -z "$bad" ]`(다섯 술어 목록 밖 표기 변형)를 위반 카운트 `-eq 0`으로 재작성(동작 불변).
# traps-ops-2(2026-09-05)가 술어 결함을 고쳐 hard-zero에서 래칫으로 재개장했었다 — 그 26건을
# 티켓 78(2026-09-05)이 12라운드 분류(predicate 8·rename 18·detector 0)대로 전부 착지해
# **다시 0으로 수렴**했다(위 ⚠️ 「다시 0으로」 절 참조). 올리는 방향은 부채 재유입이다.
SETCAP_BASELINE=0
# 레포 소유 실행물 호출의 부재 단언 부채 잔액 — **hard-zero**(F4, 감사 63 착지, 2026-09-05).
# F1(adguard 리컨실러 2곳)·F2(나머지 10곳 — tools/tests/test_cli-flag-guard.bats 5 ·
# tests/gates/test_scan-floor.bats 3 · tests/gates/test_secret-cert-check.bats 1 ·
# tests/test_dr-drill.bats 1은 처방 불요, W1 위치-인자 갈래로 이미 닫힘)가 착수 시점 잔액을 0으로
# 갚은 뒤에 켠다 — [ABS]/[BB]와 같은 순서(래칫으로 출발하지 않는다, 설계 노트 §9).
ABSEXEC_BASELINE=0
# ── 기본 모드의 도메인 = **추적 `*.bats` + bats가 `load`하는 `*.bash` seam** ─────────────
# `.bash` seam을 빼면 그 파일은 이 가드에게 **영원히 안 보인다** — bats 본문과 같은 문법을
# 쓰는 코드인데 확장자 하나로 판정 밖이 된다(「처방 도달」 축의 도달 실패).
# 확장자가 도메인을 정확히 가른다: 추적 `*.bash`는 전부 `load` 대상이고(파생:
# `git ls-files '*.bats' | xargs grep -h '^\s*load '` ↔ `git ls-files '*.bash'`), 반대로
# `tests/gates/lib/*.sh`는 @test 표면이 아니라 가드 본체가 source하는 라이브러리라
# `.bash`가 아니고, 그래서 이 합집합에 안 들어온다(들어오면 bats 표면 판정이 셸 표면으로 번진다).
# 증인: tests/gates/test_bats-style.bats의 픽스처 테스트가 합집합 열거를 고정한다(글롭을 좁히면 red).
FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.bats' '*.bash')
fi
# ⚠️ 기본 모드의 도메인은 **정당하게 0이 될 수 없다**: 0건은 열거 붕괴다.
# (건수는 여기 적지 않는다 — 손 관리 수치는 반드시 드리프트한다, scan-floor.sh 규약.)
# 바닥값은 라벨 하나 = 도메인 하나 규약대로 합집합 전체에 한 번 건다(접미사 분할 없음).
# 여기에 skip 규약(exit 4 + `SKIP:`)을 쓰면 거의 같은 도메인(추적 `*.bats`)을 쓰는
# check-skeleton·check-bats-accounting(둘 다 바닥값 + exit 1)과 **정반대 신호**가 된다 —
# 커널 주석(lib/scan-floor.sh)이 "마커를 내면 사람이 정반대 뜻으로 읽는다"고 금지한 채널 혼동이다.
# 명시-파일 모드($# > 0)는 원소가 항상 ≥1이라 이 분기에 도달하지 않지만, 픽스처가 1건짜리로
# 부를 수 있으므로 바닥값은 기본 모드에만 건다(선례: check-app-netpol의 --root 면제). 래칫 아님.
if [ "$#" -eq 0 ] || floor_set check-bats-style; then
  scan_floor check-bats-style "${#FILES[@]}" "$(floor_of check-bats-style 150)" quiet || exit 1
fi
DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
function flush(){ if(pend!=""){ print pend; pend="" } }
# ── [ABS]/[QV] 레인 헬퍼 ──────────────────────────────────────────────────────────────────
# 후행 주석 제거 — **따옴표 균형이 맞는 자리에서만** 뗀다. 균형을 안 보면 `'^[[:space:]]*#.*repoURL:'`
# 같은 패턴 리터럴의 `#`에서 잘려 판정 대상 자체가 사라진다(형제 check-locale-collation이 밟은
# "상태 기계 순서가 곧 판정" 결함과 같은 얼굴). NEG/BB 레인은 이 후행-주석 정제와는 무관하다(주석만
# 있는 줄은 위에서 이미 걸러진다) — 다만 세그먼트 분해(아래 mask_semi)는 NEG/BB도 함께 쓴다.
function abs_strip(s,   i,c,q1,q2){
  q1=0; q2=0
  for(i=1;i<=length(s);i++){
    c=substr(s,i,1)
    if(c=="'" && q2==0) q1=1-q1
    else if(c=="\"" && q1==0) q2=1-q2
    else if(c=="#" && q1==0 && q2==0 && (i==1 || substr(s,i-1,1) ~ /[ \t]/)) return substr(s,1,i-1)
  }
  return s
}
# NEG/BB 세그먼트 분해 전 마스킹 — 홑/겹따옴표 **안**의 `;`를 플레이스홀더(\001)로 바꿔 split이 그
# 자리를 진짜 문장 경계로 오인하지 않게 한다(실측 회귀: `"x &amp; y"` 리터럴의 `;`·sed 스크립트
# 안 `;;` case 터미네이터 리터럴의 `;`가 마스킹 없이는 가짜 세그먼트 경계를 만들어 [NEG]/[BB]
# 오탐을 냈다). abs_strip과 같은 q1/q2 토글 모델 — split 뒤 세그먼트마다 gsub로 되돌린다.
function mask_semi(s,   i,c,q1,q2,out){
  q1=0; q2=0; out=""
  for(i=1;i<=length(s);i++){
    c=substr(s,i,1)
    if(c=="'" && q2==0) q1=1-q1
    else if(c=="\"" && q1==0) q2=1-q2
    else if(c==";" && (q1 || q2)) c="\001"
    out=out c
  }
  return out
}
# [QV] 세그먼트 분해(abs_stmt의 `|`·`||`·`&&` split) 전 마스킹 — 따옴표 **안**의 `|`를 플레이스홀더
# (\002)로 가려 split이 그 자리를 진짜 파이프 경계로 오인하지 않게 한다(mask_semi와 같은 모델,
# 다른 문자). 안 가리면 `grep -Eq 'command -v kubectl|command -v yq' "$S"` 같은 정당한 리터럴이
# 세그먼트 경계에서 갈라진다(round11 bats-style-lanes-2 va.corrected_fix).
function mask_pipe(s,   i,c,q1,q2,out){
  q1=0; q2=0; out=""
  for(i=1;i<=length(s);i++){
    c=substr(s,i,1)
    if(c=="'" && q2==0) q1=1-q1
    else if(c=="\"" && q1==0) q2=1-q2
    else if(c=="|" && (q1 || q2)) c="\002"
    out=out c
  }
  return out
}
# 대상 판정 — grep 계열 + 경로 피연산자. 히어스트링은 경로가 없으므로 대상 밖(헤더의 분모 규약).
# rc 1 = grep 계열(무매치 1 · 부재/읽기불가 2) · rc 2 = git grep(무매치 1 · 치명적 **128**).
# F3(감사 63) — `bashc_pipe`는 부작용 전역이다: `run (bash|sh) -c '<본문>'`(홑따옴표) 언랩이
# grep 계열을 찾으면, 그 본문에 파이프가 있는지를 여기서 함께 기록해 콜사이트(abs_stmt)가
# REC 강제 여부와 철자-면제 여부를 알 수 있게 한다(단일-grep 본문은 0 그대로 — 일반 FILE/REC
# 판정과 동일하게 다룬다).
function abs_target(s,   p,body,end){
  bashc_pipe=0
  if (s ~ /<<</) return 0
  p=s; sub(/^run[ \t]+/,"",p)
  while (p ~ /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/,"",p)
  sub(/^--separate-stderr[ \t]+/,"",p)
  if (p ~ /^(grep|egrep|fgrep)[ \t]/) return 1
  if (p ~ /^git[ \t]+(-C[ \t]+[^ \t]+[ \t]+)?grep[ \t]/) return 2
  if (p ~ /^(bash|sh)[ \t]+-c[ \t]+'/) {
    body = p
    sub(/^(bash|sh)[ \t]+-c[ \t]+'/, "", body)
    end = index(body, "'")   # 홑따옴표는 셸 자체에 이스케이프가 없다 — 첫 등장이 곧 종료(정확).
    if (end > 0) {
      body = substr(body, 1, end - 1)
      if (body !~ /<<</) {
        if (body ~ /\|/) bashc_pipe = 1
        if (body ~ /^(grep|egrep|fgrep)[ \t]/) return 1
        if (body ~ /^git[ \t]+(-C[ \t]+[^ \t]+[ \t]+)?grep[ \t]/) return 2
      }
    }
  }
  return 0
}
# 재귀/디렉토리 형태 — 옵션 클러스터의 r/R · `--recursive` · 패턴 뒤 피연산자가 `/`로 끝남 · git grep.
# (git grep은 pathspec 전체를 훑으므로 언제나 이 형태다. pathspec이 추적 파일과 하나도 안 맞아도
#  128이 아니라 rc 1이라는 것이 이 레인이 필요한 바로 그 이유다 — 실측.)
function abs_rec(s,kind,   q,n,i,a,pat){
  if (kind==2) return 1
  q=s; gsub(/['"]/,"",q); sub(/^run[ \t]+/,"",q)
  n=split(q,a,/[ \t]+/); pat=0
  for(i=1;i<=n;i++){
    if (a[i] ~ /^-[A-Za-z]*[rR][A-Za-z]*$/ || a[i]=="--recursive") return 1
    if (a[i] ~ /^-/) continue
    if (a[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
    if (a[i]=="grep"||a[i]=="egrep"||a[i]=="fgrep"||a[i]=="git") continue
    if (!pat) { pat=1; continue }
    if (a[i] ~ /\/$/) return 1
  }
  return 0
}
# ── [ABS-EXEC] 레인 헬퍼(F4, 감사 63) ─────────────────────────────────────────────────────
# 분모 판정 — 레포 소유 실행물(scripts/*.sh · tools/*.ts · infra/**/*.sh · tests/gates/*.sh) 호출.
# grep 계열은 `abs_target`이 이미 분모라 먼저 물어 배제한다(이중 계상 금지, 헤더 [ABS-EXEC] 절).
# 경계 문자 하나(문자열 시작 또는 비-단어문자)를 요구해 `myscripts/x.sh` 같은 부분열 오탐을 막는다.
# `cd … && bun …`·`bash -c "…"`처럼 감싸도 경로 리터럴이 문장 어딘가에 있으면 잡는다 — 정적
# 판별이라 피연산자 동일성은 안 본다(`:48` 규약과 같다. `$VAR/scripts/x.sh`처럼 변수 접두라도
# 리터럴 부분만 있으면 대상이다).
function exec_target(s){
  if (abs_target(s)) return 0
  # 홑따옴표 bash -c만 [ABS] 대상으로 승격되므로(F3 분모 규약), 겹따옴표로 감싼 grep 파이프는
  # `abs_target`이 못 보고 여기로 샌다 — 경로 리터럴이 grep의 **피연산자**(실행 대상이 아니다)인
  # 자리라 이중 배제한다(실측: test_image-ownership.bats:387 `bash -c "grep … '$ROOT/scripts/…'"`).
  if (s ~ /(^|[^A-Za-z0-9_])(grep|egrep|fgrep)[ \t]/) return 0
  if (s ~ /(^|[^A-Za-z0-9_])scripts\/[A-Za-z0-9_.\/-]+\.sh/) return 1
  if (s ~ /(^|[^A-Za-z0-9_])tools\/[A-Za-z0-9_.\/-]+\.ts/) return 1
  if (s ~ /(^|[^A-Za-z0-9_])infra\/[A-Za-z0-9_.\/-]+\.sh/) return 1
  if (s ~ /(^|[^A-Za-z0-9_])tests\/gates\/[A-Za-z0-9_.\/-]+\.sh/) return 1
  return 0
}
# 도구 신원 — W2(양성 대조) 매칭 키. `exec_target`과 같은 네 패턴이어야 한다(갈리면 대상은
# 잡히는데 키가 안 잡히는 불일치가 생긴다).
# ⚠️ match()는 **leftmost** 매치라, `run env FALLBACK=scripts/good.sh bash scripts/bad.sh --bogus`처럼
# 한 문장에 스크립트 경로가 두 번(디코이 env 값 + 실제 실행 대상) 나오면 실행과 무관한 앞쪽 참조가
# 키를 가로채 엉뚱한 양성 대조를 빌려준다(round11 bats-style-lanes-3). abs_target(F3 분모 판정)이
# 이미 하는 `run `·`env `·`VAR=val` 접두 스트립 관용구를 그대로 재사용해 그 디코이를 먼저 없앤다.
function exec_toolkey(s,   r){
  r=s
  sub(/^run[ \t]+/,"",r)
  sub(/^env[ \t]+/,"",r)
  while (r ~ /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/,"",r)
  if (match(r, /scripts\/[A-Za-z0-9_.\/-]+\.sh/))     return substr(r,RSTART,RLENGTH)
  if (match(r, /tools\/[A-Za-z0-9_.\/-]+\.ts/))        return substr(r,RSTART,RLENGTH)
  if (match(r, /infra\/[A-Za-z0-9_.\/-]+\.sh/))        return substr(r,RSTART,RLENGTH)
  if (match(r, /tests\/gates\/[A-Za-z0-9_.\/-]+\.sh/)) return substr(r,RSTART,RLENGTH)
  return ""
}
# W1 출력 문구 증인 — (a) echo/printf가 캡처 사본("$output"/"$out")을 grep -q로 넘기는 지배
# 관용구(§5 실측 994+346건) · (b) `run bash -c '… "$1" …' _ "$out"` 위치-인자 형태(bats 지역
# 변수가 `bash -c` 안에서 빈 문자열로 보이는 함정을 피하는 안전 관용구 — docs/traps-detail.md
# 「정적 증인의 두 함정」. 이 갈래를 안 읽으면 규약을 지킨 자리가 red다 — §6-C 경고).
function execw1_hit(s){
  if (s ~ /^(echo|printf)[ \t]/ && s ~ /"\$(output|out)"/ && s ~ /\|[ \t]*grep[ \t]+-[A-Za-z]*q/) return 1
  if (s ~ /^run[ \t]+(bash|sh)[ \t]+-c[ \t]+'.*grep[ \t]+-[A-Za-z]*q/ && s ~ /_[ \t]+"\$(output|out)"/) return 1
  return 0
}
# 따옴표-인식 토큰화 — 홑/겹따옴표 **안**의 공백은 토큰 경계가 아니다(bash의 실제 단어분리와 같은
# 규약). qv_seg의 옛 `gsub(quotes)+split(공백)`은 따옴표만 지우고 공백은 무조건 경계로 써서, 따옴표
# 안에 있던 `-v` 같은 부분열이 따옴표가 사라진 뒤 독립 토큰으로 떠올라 진짜 플래그처럼 읽혔다
# (round11 bats-style-lanes-2 va.corrected_fix — 실측 회귀: tests/gates/test_audit-orphan-pv.bats:9
# `grep -Eq 'command -v kubectl|command -v yq' "$S"`의 따옴표 안 `-v`가 이 자리다).
function qv_tokenize(s, tok,   i,c,q1,q2,cur,n){
  q1=0; q2=0; cur=""; n=0
  for(i=1;i<=length(s);i++){
    c=substr(s,i,1)
    if(c=="'" && q2==0){ q1=1-q1; continue }
    if(c=="\"" && q1==0){ q2=1-q2; continue }
    if((c==" " || c=="\t") && q1==0 && q2==0){
      if(cur!=""){ n++; tok[n]=cur; cur="" }
      continue
    }
    cur=cur c
  }
  if(cur!=""){ n++; tok[n]=cur }
  return n
}
# [QV] 세그먼트 판정 — grep-a-5. 예전 판은 q·v가 **한 토큰 안**에 붙어야 매치해 `grep -q -v`
# (분리 플래그)·`if grep -qv …`(문장 선두, 파이프 無)가 무측정이었다. 여기서는 문장을 `|`·`||`·`&&`로
# 쪼갠 뒤 각 세그먼트에서 grep 호출 뒤 **선행 플래그 토큰들**만 훑어 q·v가 (같은 토큰이든 분리
# 토큰이든) 함께 있으면 위반이다. `abs_rec`처럼 문장 **전체** 토큰을 훑으면 안 된다 — 그러면
# `grep -v X | grep -q Y`(정당한 다중-grep 파이프) 같은 자리가 두 세그먼트 각각에서 오탐을 낸다
# (세그먼트 분리 + **positional 2개(패턴·파일)까지만** 플래그 스캔을 허용하는 카운터 두 축이 그
# 오탐을 막는다 — 실측 8곳 무오탐). ⚠️ round11 va.corrected_fix — "첫 비플래그에서 즉시 break"였던
# 예전 판은 `grep -v EXCLUDE -q FILE`(GNU grep이 실제로 순열 처리하는 형태)를 놓쳤다. positional
# 카운터로 넓히되, 따옴표-인식 토큰화(qv_tokenize) 없이 넓히면 위 회귀가 재현된다 — 두 변경은 짝이다.
function qv_seg(t,   n,a,i,seen,q,v,pos){
  n=qv_tokenize(t,a); seen=0; q=0; v=0; pos=0
  for(i=1;i<=n;i++){
    if(!seen){ if(a[i]=="grep"||a[i]=="egrep"||a[i]=="fgrep") seen=1; continue }
    if(a[i]=="--") break
    if(a[i] ~ /^-/){
      if(a[i] ~ /^-[A-Za-z]*q/) q=1
      if(a[i] ~ /^-[A-Za-z]*v/) v=1
      continue
    }
    pos++
    if(pos>=2) break                              # 패턴(1)+파일(2) — 그 뒤는 대상 밖
  }
  return (seen && q && v)
}
# [SETCAP] 술어 판정 — 텍스트 매치(문장 위치 무관, 존재만 잰다 — ABS/QV처럼 앵커·세그먼트를
# 재는 레인이 아니다). 헤더의 분모 규약: 문자열 등식·수 등식·jq/yq contains(/join(","/length ==/
# == [ 배열 리터럴·grep -qx 구조적 등식. 어느 하나라도 맞으면 그 @test 스코프는 상한 술어를 가진
# 것으로 친다.
# ⚠️ 문자열 등식 술어는 **bracket-test 좌변**(`[ "$a" = "b" ]`, `=` 앞에 공백)만 잡는다 — 대입
#    (`VAR="x"`, `=` 앞 공백 없음)은 배제한다(guard-decision(traps-ops-2), 2026-09-05: `=` 앞
#    공백 요구 없이는 스코프 안 아무 문자열 대입 하나로 이 술어가 통째로 무력화됐다).
# ⚠️ 수 등식 술어도 **bracket-test 종료 앵커**(`-eq N[ \t]*]`)만 잡는다 — 앵커 없이는 `run` 문의
#    CLI 인자에 우연히 등장하는 `-eq N` 텍스트(예 `--retry-eq 5`)만으로 이 술어가 무력화됐다
#    (2026-09 정기 회귀 reg-c-ledger-rows-1, 12라운드). 이 파일이 이미 쓰는 형제 앵커(451/452/
#    459/466/467행)를 그대로 복사한 처방 — 신설 로직 없음. 전체 스캔 SETCAP 26/26 회귀 0 실측.
# ⚠️ 자기유도(self-deriving) 등식 — `-eq`의 우변이 리터럴 숫자가 아니라 변수(`[ "$total" -eq
#    "$expected" ]`류)인 자리는 위 리터럴 술어에 안 걸린다(setcap-17/12라운드 실측 —
#    tests/gates/test_telegram-callsites.bats:51,63). 이 형태도 **bracket-test 종료 앵커**를
#    요구한다 — 앵커 없이 `-eq[ \t]+"?\$` 하나만 텍스트 매치하면 reg-c-ledger-rows-1과 같은
#    급의 `run` 인자 오탐(예 `run … --retry-eq "$RETRIES"`)이 이 형태에도 그대로 재발한다(분류
#    합의문 원안은 앵커 없이 제안했으나, 이 파일이 바로 위 줄에서 같은 이유로 이미 좁혀 둔
#    관례를 그대로 따른다 — 신설 취약점을 지금 막는다). 앵커를 더한 뒤 실측: 517행 두 곳(득실
#    없이 그대로 매치) + 대조 픽스처(run 인자 형태)는 여전히 불일치 확인.
function setcap_hit(s){
  if (s ~ /[ \t]=[ \t]*"[^"]+"/) return 1
  if (s ~ /-eq[ \t]+[0-9]+[ \t]*\]/) return 1
  if (s ~ /-eq[ \t]+"?\$[A-Za-z_][A-Za-z0-9_]*"?[ \t]*\]/) return 1  # 자기유도(변수 우변) 등식
  if (s ~ /contains\(/) return 1
  if (s ~ /join\(","\)/) return 1
  if (s ~ /length[ \t]*==/) return 1
  if (s ~ /==[ \t]*\[/) return 1  # jq/yq 배열 리터럴 등식
  if (s ~ /grep[ \t]+-q[A-Za-z]*x/) return 1  # grep -qxF/-qx 구조적 등식(전체 행 일치 — 형제: test_pvc_du_exporter.bats:31-33)
  return 0
}
# 한 문장 처리 — 루프 깊이 · [QV] · [SETCAP] 술어 · run/status 짝(ABS·ABS-EXEC 둘 다) · 증인 수집.
function abs_stmt(s,   rec,qn,qsg,qi){
  # 한 줄 for/if 관용구(`; do run …`/`; then run …`)는 abs_line의 `;` 분해 뒤 세그먼트가
  # "do run …"/"then run …"가 되어 아래 run-인식 앵커(`^run[ \t]/`)에 안 걸린다 — `do`/`then`과
  # `run`은 세미콜론이 아니라 공백으로만 이어지기 때문이다. 앵커 검사 전에 이 두 키워드 접두를
  # 벗겨 run-인식·[ABS-EXEC]·조건 필터가 모두 재사용하는 이 지역변수 s 하나로 전부 해소한다
  # (2026-09 정기 회귀 reg-d-bats-style-last-2, 12라운드 — 신설 함수 없음).
  sub(/^(do|then)[ \t]+/,"",s)
  # [SETCAP]은 위치·세그먼트 무관 — 스코프 안 어디서든 한 번 맞으면 그 스코프는 닫힌다.
  if (setcap_hit(s)) scpred[absscope]=1
  # [ABS-EXEC] W1 — 마찬가지로 위치 무관, 스코프 안 어디서든 한 번 맞으면 그 스코프는 증인을 진다.
  if (execw1_hit(s)) execw1[absscope]=1
  if (s ~ /^(for|while|until)[ \t]/) absloop++
  else if (s ~ /^done([ \t;].*)?$/) { if(absloop>0) absloop-- }
  # [QV] — rc를 판정으로 쓰는 `-q`와 줄 반전 `-v`가 같은 grep 호출의 선행 플래그에 함께 있으면
  # 항진/거짓실패다. 세그먼트 단위라 `if`/`&&` 선행 위치도 잡는다(문장 선두 앵커 불필요).
  # mask_pipe로 따옴표 안 `|`를 가린 뒤 분해 — 안 가리면 그 리터럴이 세그먼트 경계를 만들어
  # split이 정당한 `grep -Eq 'a|b' file`류 패턴을 조각낸다(round11 bats-style-lanes-2).
  qn=split(mask_pipe(s),qsg,/\|\||&&|\|/)
  for(qi=1;qi<=qn;qi++){ gsub(/\002/,"|",qsg[qi]); if(qv_seg(qsg[qi])){ print FILENAME":"FNR": [QV] "s; break } }
  if (s ~ /^run[ \t]/) {
    absk=abs_target(s)
    if (absk) {
      absrun=s; absline=FNR; absrloop=absloop; absrunpipe=bashc_pipe; execrun=""
    } else {
      absrun=""
      # [ABS-EXEC](F4) — grep 계열은 위에서 이미 배제됐다(exec_target이 abs_target을 먼저 묻는다).
      if (exec_target(s)) { execrun=s; execline=FNR; exectool=exec_toolkey(s); execscope=absscope }
      else execrun=""
    }
    return
  }
  if (s ~ /^\[[ \t]+"\$status"[ \t]/) {
    if (absrun!="") {
      # 양성 대조 ①: 대상 run이 `-eq 0`으로 판정됐다 = 같은 술어 가족이 어딘가에서 매치한다.
      if (s ~ /-eq[ \t]+0[ \t]*\]/) abspos[absscope]++
      else if (s ~ /-eq[ \t]+1[ \t]*\]/ || s ~ /-(ne|gt)[ \t]+0[ \t]*\]/) {
        # GIT = git grep(pathspec) · REC = 파일시스템 재귀/디렉토리·`bash -c` 파이프(F3) · LOOP = 루프
        # 구동 · FILE = 단일 파일.
        rec = (absk==2) ? "GIT" : ((absrunpipe || abs_rec(absrun,absk)) ? "REC" : (absrloop>0 ? "LOOP" : "FILE"))
        # `bash -c` 파이프 형태는 `-eq 1`/`-ne 0`가 동치다(앞 grep의 rc 2가 파이프에 먹혀 철자로
        # 못 닫는다, 헤더 재현) — 철자 판정을 면제하고 REC와 같은 floor∧양성대조 요구만 남긴다.
        absc[absn] = FILENAME"\t"FILENAME":"absline"\t"absscope"\t" \
                     (((s ~ /-eq[ \t]+1[ \t]*\]/) || absrunpipe) ? "ok" : "stale")"\t"rec"\t"absrun
        absn++
      }
      absrun=""
      return
    }
    if (execrun!="") {
      if (s ~ /-eq[ \t]+0[ \t]*\]/) execpos[FILENAME SUBSEP exectool]++
      else if (s ~ /-(ne|gt)[ \t]+0[ \t]*\]/ || s ~ /-eq[ \t]+[1-9][0-9]*[ \t]*\]/) {
        execc[execn] = FILENAME"\t"FILENAME":"execline"\t"execscope"\t"exectool"\t"execrun
        execn++
      }
      execrun=""
    }
    return
  }
  # 조건절·`|| …` 보호절·부정은 단언이 아니다 — 증인으로 세면 필터 한 줄이 증인 노릇을 한다.
  if (s ~ /^(if|elif|while|until)[ \t]/ || s ~ /\|\|/ || s ~ /^!/) return
  # 양성 대조 ②: 맨 grep 호출(bats는 @test 본문의 실패 명령에서 죽으므로 그 자체가 단언이다).
  # ⚠️ **경로 도메인을 질의하는 호출만** 센다 — `printf … | grep -q …`처럼 `$output`을 보는 관용구는
  #    술어가 살아 있음을 증언하지만 그 **경로 열거**에 대해서는 아무 말도 하지 않는다. 그걸 세면
  #    거의 모든 @test가 자동으로 증인을 갖게 되어 이 레인이 자기 자신에게 vacuous해진다.
  #    (실측: 그 형태까지 증인으로 세는 규칙을 넣고 빼며 돌려 봤고 레포 전역 검출은 양쪽 다 5곳이었다 —
  #     느슨하게 할 이유가 없었다. 반대로 그 규칙이 있으면 뮤테이션 M4가 red를 못 낸다.)
  if (abs_target(s)) abspos[absscope]++
  # 양성 대조 ③: 루프가 실제로 돌았다는 카운터(`[ "$hits" -ge 1 ]`). `$status`는 rc라 대상 밖.
  if (s ~ /^\[[ \t]+"?\$/ && s ~ /-(ge|gt)[ \t]+[0-9]+[ \t]*\]/ && s !~ /"\$status"/) abspos[absscope]++
  # 비공허 바닥값: 열거 대상이 실재한다(`[ -d "$WF" ]` · `[ -n "$DISPATCHERS" ]`).
  if (s ~ /^\[[ \t]+-[defsr][ \t]/ || s ~ /^\[[ \t]+-n[ \t]/) absfloor[absscope]++
}
# 한 줄 처리 — 후행 주석 제거 → 줄바꿈 연속(`\`) 접합 → `; [ … ]` 관용구 분해.
function abs_line(raw,   t,i,n,parts,s){
  t=abs_strip(raw); sub(/^[ \t]+/,"",t); sub(/[ \t]+$/,"",t)
  if (t=="") return
  if (abscont!=""){ t=abscont" "t; abscont="" }
  if (t ~ /\\$/){ sub(/\\$/,"",t); abscont=t; return }
  # ⚠️ mask_semi(round11 bats-style-lanes-1이 NEG/BB 레인에 넣은 공용 세그먼터)로 따옴표 안 `;`를
  #    가린 뒤 분해한다 — 안 가리면 `run bash -c '…"a;b"…'`처럼 홑따옴표 본문 안 리터럴 `;`가
  #    abs_stmt/abs_target(F3 `bash -c` 언랩)이 공유하는 이 진입점을 두 조각으로 잘라 닫는 홑따옴표를
  #    못 찾게 만들고, ABS/ABS-REC/ABS-GIT/ABS-LOOP/ABS-EXEC/SETCAP 여섯 레인 전부가 그 문장에서
  #    무증인으로 사라진다(2026-09 정기 회귀 reg-d-bats-style-last-1, 12라운드). NEG/BB(554행)가
  #    이미 하는 관용구를 abs_line 자신에도 적용하는 것뿐 — 신설 함수 없음.
  n=split(mask_semi(t), parts, /;[ \t]*/)
  for(i=1;i<=n;i++){ s=parts[i]; sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); gsub(/\001/,";",s); if(s!="") abs_stmt(s) }
}
BEGIN { absn=0; execn=0 }
FNR==1 { intest=0; pend=""; inhere=0; delim=""; nfiles++
         absscope=FILENAME"#file"; absrun=""; execrun=""; abscont=""; absloop=0 }
{
  line=$0
  if (inhere){ if(line ~ ("^[ \t]*"delim"[ \t]*$")) inhere=0; next }
  # ⚠️ **주석 스킵이 heredoc 매치보다 먼저 온다 — 순서가 곧 판정이다.** 뒤집으면 인용된 heredoc
  #    표기 한 줄이 @test의 나머지를 통째로 지우고, 그 침묵은 red가 아니다(형제
  #    check-locale-collation.sh와 같은 결함 — 착지 전 실측 이 도메인 5파일 602줄).
  #    아래 intest 본문의 `t ~ /^#/`는 intest 판정 **뒤**라 heredoc 매치에 원리적으로 닿지 못한다.
  if (line ~ /^[ \t]*#/) next
  hl = line
  # `<<<` herestring은 heredoc 시작이 아니다 — match()가 **2번째** `<`부터 `<< "foo"`로 읽는다.
  # (형제 check-host-ports.sh·check-locale-collation.sh와 같은 관용구 — 오인원 열거 1번.)
  gsub(/<<</, "@HERESTRING@", hl)
  # 산술 좌시프트 `$(( a << b ))`도 heredoc이 아니다(오인원 열거 2번).
  if (hl ~ /\$\(\(/) gsub(/<</, "@SHIFT@", hl)
  if (match(hl, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
    d=substr(hl,RSTART,RLENGTH); gsub(/.*<<-?[ \t]*['"]?/,"",d); delim=d; inhere=1; next
  }
  if (line ~ /^@test .*\{[ \t]*$/){
    intest=1; pend=""; absscope=FILENAME":"FNR; absrun=""; execrun=""; abscont=""; absloop=0
    # [SETCAP] — 이름이 상한 어휘를 선언하는지는 @test 선언 줄 그 자체로만 판정한다(본문 줄은
    # 술어 스캔 전용). 대소문자 구별 그대로 — 넓히면 다른 축(표기 변형)이 된다.
    scname[absscope] = (line ~ /(exactly|only|no other|전수|EVERY|정확)/) ? 1 : 0
    scpred[absscope] = 0
    sctext[absscope] = line
    next
  }
  # 0열 함수 정의 — 본문을 같은 상태 기계에 들인다(헤더 「코드 표면」). 증인 스코프는 **파일 수준**이다:
  # setup()/스텁 팩토리는 그 파일의 모든 @test보다 먼저 도므로 개별 실행(`bats -f`)에서도 증인이 산다.
  if (line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/){
    absscope=FILENAME"#file"; absrun=""; execrun=""; abscont=""; absloop=0
    t=line; sub(/^[^{]*\{/,"",t)
    if (t ~ /\}[ \t]*$/){ sub(/[ \t]*\}[ \t]*$/,"",t); abs_line(t); next }   # 한 줄 정의는 바로 닫힌다
    intest=1; pend=""; abs_line(t); next
  }
  if (!intest) next
  if (line ~ /^\}[ \t]*$/){
    # [SETCAP] — @test 스코프가 지금 닫힌다. 이름이 상한을 선언했는데 본문 어디서도 술어를
    # 못 봤으면 여기서 딱 한 번 낸다(0열 함수 스코프는 scname이 항상 0이라 이 자리를 안 탄다).
    if (scname[absscope] && !scpred[absscope]) print absscope": [SETCAP] "sctext[absscope]
    intest=0; pend=""; absrun=""; execrun=""; abscont=""; absloop=0; next
  }
  t=line; sub(/^[ \t]+/,"",t)
  if (t=="" || t ~ /^#/) next
  flush()
  # NEG/BB — `;`로 이어붙인 한 줄 복합문도 abs_line(408행)과 같은 분해를 거친다(형제 결함:
  # 원문 `t` 전체의 선두 토큰만 보면 `true; [[ … ]]`가 완전히 안 보이고, `[[ … ]]; true`는 실제로는
  # 중간 단언인데 pend가 그 세그먼트에서 설정된 뒤 `}`에서 무출력 리셋돼 마지막-줄 관용구로 오인
  # 면제된다). 세그먼트 단위로 판정하되 **문장 전체의 마지막(비공백) 세그먼트만** 종전 pend(마지막-줄
  # 관용구) 지연 판정을 받는다 — 그 앞 세그먼트는 뒤따르는 세그먼트가 같은 줄에 실재하므로 무조건
  # '중간' 단언이라 즉시 낸다(pend로 미룰 필요가 없다).
  # ⚠️ split 전에 mask_semi로 따옴표 안 `;`를 가린다 — 안 가리면 `"x &amp; y"` 리터럴이나 sed
  # 스크립트의 `;;` case 터미네이터가 가짜 세그먼트 경계가 되어 [NEG]/[BB] 오탐을 낸다(실측 회귀:
  # tests/gates/test_telegram-notify.bats·tools/tests/test_tf-r2-init.bats).
  bbn=split(mask_semi(t), bbparts, /;[ \t]*/); bbcnt=0
  for (bbi=1; bbi<=bbn; bbi++) {
    bbs=bbparts[bbi]; sub(/^[ \t]+/,"",bbs); sub(/[ \t]+$/,"",bbs); gsub(/\001/,";",bbs)
    if (bbs=="") continue
    bbcnt++; bbseg[bbcnt]=bbs
  }
  for (bbi=1; bbi<bbcnt; bbi++) {
    bbs=bbseg[bbi]
    if (bbs ~ /^![ \t]/)    print FILENAME":"FNR": [NEG] "bbs
    else if (bbs ~ /^\[\[/) print FILENAME":"FNR": [BB] "bbs
  }
  if (bbcnt>0) {
    bbs=bbseg[bbcnt]
    if (bbs ~ /^![ \t]/)    pend=FILENAME":"FNR": [NEG] "bbs
    else if (bbs ~ /^\[\[/) pend=FILENAME":"FNR": [BB] "bbs
  }
  # [ABS]/[QV]는 pend(마지막-명령 면제)를 쓰지 않는다 — 부재 판정은 @test의 **마지막 줄**이 정상 자리다.
  abs_line(line)
}
END {
  for(i=0;i<absn;i++){
    split(absc[i], f, "\t")
    if (f[4]=="stale") print f[2]": [ABS] "f[6]
    if (f[5]=="FILE") continue
    fl = (absfloor[f[3]]>0 || absfloor[f[1]"#file"]>0)
    pc = (abspos[f[3]]>0  || abspos[f[1]"#file"]>0)
    # ⚠️ **git grep은 양성 대조만 요구한다.** 피연산자가 파일시스템 경로가 아니라 pathspec이라
    #    `[ -d … ]` 류 바닥값을 걸 대상이 없고, pathspec이 추적 파일과 하나도 안 맞을 때 git grep은
    #    128이 아니라 **rc 1**을 낸다(실측 git 2.53.0) — 즉 그 붕괴는 같은 pathspec의 양성 대조로만
    #    보인다. 여기에 파일시스템 바닥값을 강요하면 실제 구멍을 안 닫는 줄을 세우게 된다.
    if (f[5]=="GIT") { if (!pc) print f[2]": [ABS-GIT] "f[6]; continue }
    if (!(fl && pc)) print f[2]": [ABS-"f[5]"] "f[6]
  }
  # [ABS-EXEC](F4) — 증인은 W1(출력 문구, 같은 @test 또는 파일-스코프 함수) ∨ W2(같은 파일·같은
  # 도구 신원의 rc-eq-0 양성 대조) 중 하나. 어느 쪽도 없으면 red.
  for(i=0;i<execn;i++){
    split(execc[i], f, "\t")
    ew1 = (execw1[f[3]]>0 || execw1[f[1]"#file"]>0)
    ew2 = (execpos[f[1] SUBSEP f[4]] > 0)
    if (!(ew1 || ew2)) print f[2]": [ABS-EXEC] "f[5]
  }
  # 검출기가 **실제로 읽은** 파일 수를 호출자에게 알린다 — 형제 check-host-ports.sh와 같은 계약.
  printf "READFILES=%d\n", nfiles > "/dev/stderr"
}
AWK
# 검출 실행(인자 검증·rc 포착·READFILES 대조)은 detect_run(guard.sh) 소유 — 여긴 awk 본문만.
findings="$(detect_run check-bats-style "$DETECT" "${FILES[@]}")"
# 검출기가 끝까지 돌았다 — 이제 마커를 낸다(검출기가 죽으면 이 줄에 닿지 않는다).
scan_signal check-bats-style "${#FILES[@]}"
# count_class는 확장 정규식(-E)으로 돈다 — [ABS]와 [ABS-EXEC]를 별개 잔액으로 가르려면 알파벳
# 대안이 필요하다(`abs`가 접두 매치 그대로면 "[ABS-EXEC]"도 "[ABS"에 걸려 이중 계상된다).
count_class() { printf '%s\n' "$findings" | grep -cE "$1" || true; }
neg="$(count_class '\[NEG\]')"; neg="${neg//[^0-9]/}"; neg="${neg:-0}"
bb="$(count_class '\[BB\]')";   bb="${bb//[^0-9]/}";   bb="${bb:-0}"
abs="$(count_class '\[ABS(-REC|-LOOP|-GIT)?\]')"; abs="${abs//[^0-9]/}"; abs="${abs:-0}"
absexec="$(count_class '\[ABS-EXEC\]')"; absexec="${absexec//[^0-9]/}"; absexec="${absexec:-0}"
qv="$(count_class '\[QV\]')";   qv="${qv//[^0-9]/}";   qv="${qv:-0}"
setcap="$(count_class '\[SETCAP\]')"; setcap="${setcap//[^0-9]/}"; setcap="${setcap:-0}"
printf '%s\n' "$findings" | grep -E '\[(NEG|BB|ABS(-REC|-LOOP|-GIT|-EXEC)?|QV|SETCAP)\]' || true   # gate bats가 라벨을 검증
rc=0
if [ "$neg" -gt 0 ]; then
  echo "FAIL: 마지막 명령이 아닌 부정 단언 ${neg}곳 — bats가 침묵 통과. 'run …; [ \"\$status\" -ne 0 ]'로 재작성." >&2; rc=1
fi
if [ "$qv" -gt 0 ]; then
  echo "FAIL: 부재를 재지 않는 \`grep -qv\` ${qv}곳 — -v는 줄 단위 반전이라 항진이다. 'run grep -qF -- TOKEN <<<\"\$out\"; [ \"\$status\" -eq 1 ]'로. cf. docs/traps-detail.md" >&2; rc=1
fi
if [ "$#" -gt 0 ]; then
  # 명시-파일(픽스처) 모드 — 래칫은 레포 전역 잔액이라 여기선 뜻이 없다. 여섯 클래스 전부 hard-zero.
  [ "$bb" -eq 0 ] || { echo "FAIL: (명시 파일) 중간 [[ ]] ${bb}곳 탐지." >&2; rc=1; }
  [ "$abs" -eq 0 ] || { echo "FAIL: (명시 파일) 부재 단언 위반 ${abs}곳 탐지." >&2; rc=1; }
  [ "$absexec" -eq 0 ] || { echo "FAIL: (명시 파일) [ABS-EXEC] 위반 ${absexec}곳 탐지." >&2; rc=1; }
  [ "$setcap" -eq 0 ] || { echo "FAIL: (명시 파일) [SETCAP] 위반 ${setcap}곳 탐지." >&2; rc=1; }
else
  echo "check-bats-style: 중간 [[ ]] ${bb} (baseline ${BB_BASELINE}) · 부재 단언 ${abs} (baseline ${ABS_BASELINE}) · 레포 소유 실행물 무증인 ${absexec} (baseline ${ABSEXEC_BASELINE}) · 이름 있는 집합 상한 부재 ${setcap} (baseline ${SETCAP_BASELINE})"
  [ "$bb" -le "$BB_BASELINE" ] || { echo "FAIL: 중간 [[ ]]가 baseline(${BB_BASELINE}) 초과(${bb}) — 신규는 'run …; [ … ]'로." >&2; rc=1; }
  [ "$abs" -le "$ABS_BASELINE" ] || { echo "FAIL: 부재 단언 위반이 baseline(${ABS_BASELINE}) 초과(${abs}) — [ABS]는 '-eq 1'로 고치고, [ABS-REC]/[ABS-LOOP]는 같은 @test나 그 파일 함수 본문에 **비공허 바닥값 + 양성 대조**를 함께 세워라. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」" >&2; rc=1; }
  [ "$absexec" -le "$ABSEXEC_BASELINE" ] || { echo "FAIL: [ABS-EXEC] 위반이 baseline(${ABSEXEC_BASELINE}) 초과(${absexec}) — 레포 소유 실행물(scripts/*.sh·tools/*.ts·infra/**/*.sh·tests/gates/*.sh) 호출의 비-0 판정에 W1(echo/printf \"\$output\"|grep -q … 또는 run bash -c '… \"\$1\" …' _ \"\$out\") 또는 W2(같은 파일·같은 도구의 rc-eq-0 양성 대조) 중 하나를 세워라. cf. docs/adr/0007" >&2; rc=1; }
  [ "$setcap" -le "$SETCAP_BASELINE" ] || { echo "FAIL: [SETCAP] 위반이 baseline(${SETCAP_BASELINE}) 초과(${setcap}) — 이름이 exactly/only/no other/전수/EVERY/정확를 선언하면 본문에 집합 등식 술어(bracket-test 문자열 등식 · -eq N · jq/yq contains(/join(\",\")/length ==/== [ 배열 리터럴 · grep -qxF/-qx 구조적 등식) 중 하나를 걸어라. 집합이 아니라 단수 대상·조건 부사·합성어면 이름에서 그 어휘를 빼라. cf. docs/traps-detail.md 「이름 있는 집합의 상한 부재」" >&2; rc=1; }
fi
[ "$rc" -eq 0 ] && echo "check-bats-style: 중간 부정 0곳 + grep -qv 0곳 + [[ ]]·부재 단언·실행물 무증인·집합 상한 ratchet OK"
exit "$rc"
