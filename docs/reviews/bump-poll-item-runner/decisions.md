# Triage 결정 — bump-poll-item-runner (F-1)

### design r1

DG-1 accept (high) — 설계가 enforced call-site 게이트 `tests/gates/test_bump-poll-callsite.bats`(22 witness·84KB) migration을 누락. 워크플로 한 줄 호출은 그 게이트를 필연 실패시킴. → design change surface에 이 게이트 이관 추가: 22 witness(순서·레인 verbatim/승인게이트·원격 변이 소유·real-git 격리·staged-잔여·effective-ownership)를 (a) thin 워크플로→러너 경계와 (b) 러너 실행 테스트로 분할, 계약·변이 witness 무약화·무삭제.
DG-2-note — 아래 "T2 이관 회계"가 DG-1의 이행 증거다(witness별 행선지 + 이빨 실측).

DG-2 accept (medium) — 러너 테스트 매트릭스가 H-2의 실제 상태(git add 후 staged 잔여)를 안 만듦(bump-tag 실패는 add 전, ensure-bump-pr stub 실패는 commit 후 clean index). → post-stage/post-write 실패 시나리오 추가(staging 후 commit 실패·write 후 bump-tag 실패): 다음 항목 commit이 자기 경로만·전 worktree remove·run 계속·끝 비-0 + cleanup/격리 teeth witness. (기존 게이트 @test 16 witness를 러너 레벨로 이관+강화와 동일.)

## T2 이관 회계 (DG-1 이행 — 무약화 증거)

rewrite 직후 실측: callsite 22 witness 중 **PASS 12 / FAIL 10**. 각 witness의 행선지는 아래와 같다.
원칙: 계약이 사라지는 witness는 없다 — **호출부가 이사했으면 계약도 같이 이사한다**.

| # | witness | 결과 |
|---|---|---|
| 1·2 | gh pr create 0 / git push 0 (워크플로) | **유지** + 러너에도 같은 금지 추가(신규 witness — 금지를 워크플로에만 두면 러너가 우회로) |
| 3 | 실행기 배선 | **강화**: 두 홉(bump 스텝→러너, 러너 기본 ensure 경로=실행기). 옛 형태는 reconcile job 호출만으로도 통과하는 죽은 텍스트가 됐다 |
| 4 | 브랜치명 RUN_ID 0 | 유지 |
| 5 | 순서(브랜치→갱신→commit→ensure) | 러너 스위트로 이관(ensure 시점 HEAD=bump 커밋·`main..HEAD==1`·갱신 실패 시 ensure 미도달) + 워크플로엔 경계 witness 2종 신설 |
| 6 | auto-merge 스크립트 직접 호출 0 | 유지 |
| 7 | 레인 verbatim(정적) | 러너 소스로 겨냥 이동(대입 1회·출처 item.action·`--action` 전수 verbatim) + 무장 플래그 금지는 **두 파일**로 확대 |
| 8 | 두 레인 hermetic 실행 | 러너 스위트로 이관(같은 혼합 plan을 **진짜 git worktree**에서 실행) |
| 9 | action 재대입 0 | 7과 통합(러너 소스) |
| 10·11 | pr-sweeper 비선택 / update-branch 0 | 유지 |
| 12·13 | reconcile 독립(플래너·reader 무관) | 유지 |
| 14 | real-git 항목 격리 | 러너 스위트로 이관(H-2 staged 잔여 + 쓰기 전 실패 두 시나리오) |
| 15 | 격리 이빨(`-f` 제거 재현) | **구조적으로 소멸**: 격리가 플래그(`checkout -f`)가 아니라 **항목별 worktree**라 제거할 대상이 없다(주석으로 기록) |
| 16 | job 독립 + 양방향 비-기아 | 유지, ③만 adapt(앱별 도달은 러너 스위트 몫 → 여기선 "회수 실패 주기에도 러너가 1회 호출된다") |
| 17·18 | 자격 조합별 job 게이트 평가 + 이빨 | 유지 |
| 19 | poll-ghcr + `--expect-current` | **분할**: poll-ghcr는 워크플로, expect-current는 러너(정적) + 러너 스위트(실행) |
| 20 | auto-merge 금지의 파일 스코프 | 유지 |
| 21 | 실효 소유권(정체성·메시지) | 러너 스위트로 이관 — 기대값 파생(실행기 소스, 못 찾으면 exit 2)을 **그대로** 옮기고 대조 대상만 stub 모형 → **진짜 커밋 오브젝트**로 바뀜. `main..HEAD==1`(항목당 1커밋)이 옛 "후보당 1커밋"을 대체 |
| 22 | 소유권 이빨(config 덮어쓰기·--amend) | **구조적으로 소멸**: 모형 git이 last-write-wins/--amend를 흉내내는지 증명하던 하네스 자기증명이었다. 실물 관측엔 흉내가 없다(대신 러너 쪽 3변이 RED 실측으로 대체) |

**신규 경계 witness(러너 이관이 만든 새 표면)**
- `the bump step's only command is the runner invocation with the planner's plan` (정적) — 러너 앞뒤의
  추가 명령은 **plan 변조(레인 위조)·직접 원격 변이**의 자리다. 명령 목록이 곧 계약: 정확히 한 줄.
- `running the extracted bump step executes the runner and NOTHING else` (실행) — 그 한 줄이 파이프·서브셸로
  다른 명령을 품는 경우까지 원장으로 잡는다. ⚠️ **stub 범위가 이빨이다**: 최초 구현은 jq를 stub하지 않아
  `jq 'map(.action="bump")'` 변이를 조용히 통과시켰다(정적 증인만 RED) → jq/sed/awk/python3/curl stub 추가 후 재측정 RED.

**이빨 실측(변이 → RED 확인)**
- 러너 `--pin` 전달 제거 → 베스포크 핀 witness RED.
- 러너 `WRITER_NAME` 변조 / 커밋 메시지 템플릿 변조 / 항목당 커밋 2건(동일 신원·메시지) → 소유권 witness가 각각 RED
  (세 번째는 `ahead` 단언이 잡는다 — 신원·메시지만으로는 통과한다).
- 워크플로: 러너 앞 jq plan 변조 → 정적+실행 witness RED · plan 경로 바꿔치기 → 정적 RED · 러너 호출 제거 → 4 witness RED.

**최종**: callsite 22→19 · toctou 5→5(러너로 겨냥 이동) · 러너 스위트 6→8. `make ci` green(bats 1373).

### T2 스펙 편차(선언)

티켓 02 L13은 "git config(writer identity)·GH_TOKEN env·poll-ghcr→plan.json 준비는 **유지**(env 셋업)"라고
적었다. 구현은 **`git config` 두 줄을 제거**했다 — 러너가 커밋마다 `git -c user.name/user.email`로 신원을
명시하기 때문이다(`tools/run-bump-plan.ts`). 이건 완화가 아니라 **강화**다: 워크플로 레벨 config는
last-write-wins라 뒤따르는 한 줄이 실효 정체성을 바꿀 수 있었고(옛 게이트가 그 사각지대를 잡으려고
stub git 시뮬레이터까지 두었다), 커밋별 `-c`는 그 표면 자체를 없앤다. GH_TOKEN·plan 스텝은 티켓대로 유지.

### T2 code-review(2축) 반영

- **git stub 부재(HIGH·둘 다 지적)** — 실행 경계 증인의 stub 집합에 `git`이 빠져 있었다. 두 겹으로 나쁘다:
  ① 직접 git 호출이 원장에 안 남아 증인이 침묵하고, ② 하네스가 cd하지 않으므로 **진짜 git이 이 레포
  작업트리에서 실행**된다(회귀가 RED 대신 개발자 트리 변이). → stub 목록에 `git` 추가 + 이유를 주석에 명시.
- **공허한 단언(HIGH)** — `grep -qE 'BUMP_TAG,.*|--expect-current'`는 ERE alternation이라 `--expect-current`
  하나로 통과하고, 바로 다음 줄이 같은 걸 다시 봤다. → callsite에서 **중복 사본 제거**(expect-current의
  소유자는 races-4 파일인 `tools/tests/test_bump-poll-toctou.bats`, callsite는 그 존재만 확인).
- **이관 잔재 죽은 코드(MEDIUM)** — `PAGE_TAG`/`TRIP_TAG`(+거짓이 된 주석)·`STUB_FAIL_APP` 주입 arm과
  `run_step_rc` 전달·원장 파서의 `opt()`가 소비자 없이 남았다. → 전부 제거.
- **없는 증인 인용(MEDIUM)** — 주석이 "main is left untouched" 증인을 인용했는데 그런 테스트가 없었다.
  → 인용을 지우는 대신 **실제로 만들었다**: `the base main worktree is left untouched…`(main tip 불변 ·
  tracked 변경 0 · 값 불변). 옛 순서 계약의 첫 절(브랜치 생성 → 태그 갱신)의 실행판이다.
- **정규식 취약(LOW)** — toctou의 `[^\n]`은 ERE에서 개행이 아니라 리터럴 `n` 제외다(grep은 행 단위) → `.*`.
  토큰 사이 공백 고정도 `[[:space:]]*`로 완화(포맷 변경이 거짓 RED를 내지 않도록).
- **격리 이빨 미측정(MEDIUM)** — 지적대로 회계표에 격리 변이 실측이 없었다. → 러너를 **공유 worktree**
  (옛 셸 루프 구조: `checkout -B`를 repoRoot에서, worktree/정리 없음)로 되돌리는 변이를 실행:
  러너 스위트 9 witness 중 **7이 RED**(#1 자기 경로만 커밋 · #3 main 불변 · #4 H-2 staged 잔여 ·
  #5 fail-closed 순서 · #6 집계 · #7 원격 무변이 · #8 베스포크 핀). 공간 격리가 실제로 그 계약들을 지탱한다.
- **수용하지 않음** — toctou 파일명(`test_bump-poll-toctou.bats`)이 이제 러너를 겨냥하니 개명/병합하자는
  판단 건: 티켓 02 L17이 "이 파일을 러너 검증으로 **이관**"하라고 명시했고, 이름의 주어는 여전히
  **bump-poll 파이프라인의 races-4 가드**다(구현 계층이 아니라 계약의 소유자를 가리킨다). 헤더에 명시.
