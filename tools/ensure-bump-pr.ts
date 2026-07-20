// bump PR 멱등 **실행기** — 조회 → 결정 → 변이(push/PR)를 한 seam에 모은다(중복 PR 버그의 수정 seam).
//
// 배경(라이브 버그): bump-poll.yaml은 run마다 새 브랜치 `bump-poll/<app>-<RUN_ID>`로 PR을 연다.
// 플래너(poll-ghcr)는 "GHCR 최신 vs main의 배포 핀"만 보는데 PR이 머지되기 전엔 main이 여전히
// 옛 digest다 → 매 10분 주기가 같은 후보로 새 PR을 낸다(page sha-815abb…: 11분에 PR 3개,
// 1개만 머지되고 나머지는 충돌 잔류).
//
// 왜 도구가 **실행**까지 하는가(plan r2 R-4): 결정만 하는 도구는 GREEN이 돼도 프로덕션은 그대로일 수
// 있다 — 워크플로가 도구를 부르기 **전에** 이미 push/create를 해버리면 그만이다. 또한 "브랜치 push는
// 성공했는데 `gh pr create`가 실패"한 run이 남기는 **고아 원격 브랜치**는, 다음 폴링이 "열린 PR 없음"으로
// 보고 create를 택하는 순간 non-fast-forward로 충돌해 배포를 정지시킨다. 조회·결정·변이가 한 프로세스
// 안에 있어야 그 순서와 부작용(skip이면 push도 create도 없음)을 테스트로 증명할 수 있다.
//
// 관측 사실(변이 이전에 반드시 수집):
//   gh api graphql … repository.ref(qualifiedName:refs/heads/<branch>).associatedPullRequests(states:OPEN)
//     — **ref-연결**이라 포크를 구조적으로 배제한다(아래 ★★★★). 상한 없이 한 페이지씩 완전 열거.
//   git ls-remote --heads origin <branch>                                  ← 원격 브랜치 존재/OID
//
// ★ 조회는 **상한이 없어야** 한다 — 경계된 조회는 배포 정지 무기가 된다(structure 게이트 r2/r4) ────
// 처음엔 `gh pr list --head <b>`를 썼다. 그건 **경계된** 질의다(기본 30건, `--limit`으로만 늘어난다):
//   repository.pullRequests(headRefName:$h, first:$limit, orderBy:{CREATED_AT, DESC})   ← GH_DEBUG=api 실측
// 결정적 브랜치명은 **공개**고 `--head`는 owner 한정 필터를 지원하지 않는다 → **포크가 같은 브랜치명으로 연
// PR이 같은 페이지를 놓고 경쟁**하고, 최신순이라 나중에 열린 포크 PR들이 **먼저 열린 writer PR을 페이지 밖으로
// 밀어낸다**. 두 가지 실패가 여기서 갈라진다:
//   ① 상한을 믿고 진행 → 자기 PR을 "고아"로 오인 → force-push + 중복 create (멱등성 파괴)
//   ② 상한에 닿으면 fail-closed → **포크로 페이지를 채우는 것만으로 모든 폴링이 죽는다**(배포 정지 무기).
// 둘 다 공격자 통제다. 유일한 출구는 **상한을 없애는 것**이다: 끝까지 페이지네이션해 전부 열거하면,
// 포크가 몇 건이든 우리 PR은 반드시 그 안에 있다 → 포크는 아무것도 막지 못한다.
//   완전 열거의 증명 = **마지막 페이지의 hasNextPage === false**(아니면 fail-closed).
//
// ★★ 그런데 상한은 **한 층 아래에서 되살아난다**(structure r10 R-33) — 그래서 페이지를 우리가 따라간다 ──
// 예전엔 `gh api graphql --paginate --slurp`로 **전 페이지를 한 subprocess 캡처에** 받았다. spawnSync의
// 출력 버퍼는 유한하다(bun 1.3.14 실측: 기본 **1 MiB** → 넘으면 자식이 SIGTERM으로 **살해**되고 ENOBUFS).
// PR 한 건이 comments(first:100)·labels(first:50)까지 싣고 오므로 수 KB다 → **같은 head의 포크 PR을 수백 건
// 열면 응답 총량이 그 버퍼를 넘고 gh가 죽는다** → 그 앱의 폴링이 매 주기 fail-closed한다.
// **GraphQL 계층에서 없앤 포크 포화 무기가 프로세스 계층에 그대로 재현된 것이다.**
// → 이제 `--paginate --slurp`을 쓰지 않는다: 한 페이지 받고 → 줄이고 → `endCursor`로 다음 페이지
//   (foldConnection). **캡처 하나 = 한 페이지(first:100)** 라 공격자가 키울 수 없고, 열거의 완전성·강한
//   일관성·검색 API 금지는 하나도 바뀌지 않는다. 버퍼를 키우는 건 답이 아니다(더 큰 포화로 다시 넘긴다).
//
// ★★★ 그런데 그 상한은 **또 한 층 위에서 되살아난다**(structure r11 R-36) — 그래서 페이지를 **접는다** ──
// 캡처를 페이지로 경계지어도, 예전 구현은 **모든 페이지를 pages[]에** 모으고 열거가 끝난 **뒤에야**
// **모든 노드를 out[]에** 쌓은 다음 그 전량을 파싱·직렬화했다. 그러면 같은 head의 포크 PR이 **부모
// 프로세스의 Bun 힙과 워크플로 로그를 노드 수에 선형으로** 키운다 → executor가 죽거나 로그가 고갈될 때까지
// 간다. **억제 무기가 이번엔 부모 프로세스로 올라간 것이다.** → 이제 페이지를 받는 **즉시** 파싱·검증·접어
//   결정에 필요한 사실만 남기고(신뢰 PR + 경계 카운터) **원본 페이지·미신뢰 포크 노드는 버린다**
//   (foldConnection/scanReducer). → **직렬화되는 출력**(`observed`와 `executed` 원장 **둘 다**)에는 결정에
//   필요한 경계 있는 사실만 남는다: 포크는 요약 카운터로, 페이지네이션은 `graphqlPages`(정수 하나)로만 관측하고,
//   read-only 페이지 조회는 원장에 **남기지 않는다**(남기면 executed가 페이지 수에 비례해 로그·힙을 다시 키운다).
//   힙에 남는 건 사이클 검출용 커서 집합(seenCursors)뿐이고 그건 **페이지 수** 경계다 — "상주 메모리가 포크
//   수와 무관"이라고 넘겨짚지 않는다(정직한 진술 = 직렬화되는 상태만 경계 있는 결정 사실이다).
//
// ★★★★ 그런데 상한은 **또 되살아난다**(structure r12 R-40) — 바이트가 아니라 **질의 작업(API 호출·벽시계)** 으로.
// 위까지는 전부 `pullRequests(headRefName:<branch>)` 이름-매치 connection을 **완전 열거**하는 전제였다. 그런데
// 결정적 브랜치명은 공개고, 포크 PR(head가 포크 레포의 ref)도 headRefName이 일치하면 **이 connection에 담긴다**.
// 그래서 fold로 바이트를 경계지어도, **포크 페이지마다 `gh api graphql` 서브프로세스를 하나씩** hasNextPage=false
// 까지 태운다 → 폴링·회수가 포크 수에 비례해 GraphQL 예산·서브프로세스·벽시계를 태우고, 충분한 포크면
// writer PR을 찾기 전에 매 주기 죽는다. **완전 열거 자체가 공격 표면이었다.** → 종결: 이름-매치를 버리고
//   **우리 ref에 연결된 PR**만 조회한다(`repository.ref(refs/heads/<branch>).associatedPullRequests`). 포크 PR의
//   head는 우리 `refs/heads/*`가 **아니므로** 이 connection에 **구조적으로 담기지 않는다**(라이브 실측: base=main
//   에도 0건 = head-연결). 형제 스윕도 `git ls-remote --heads origin 'bump-poll/*'`(권위 있는 same-repo ref, 포크
//   불변)로 **우리 ref만** 열거해 각각 ref-조회한다 → **질의 작업이 포크 수와 무관**하다(우리 ref 수에만 비례,
//   그건 우리가 통제한다). 사람-흔적(comments/labels) 상세는 신뢰 후보를 고른 **뒤에만** 가져와 페이지를 가볍게.
//   (완전 열거·hasNextPage 완전성·강한 일관성·검색 금지는 그대로 — ref-연결에도 페이지네이션이 있으면 동일 적용.)
// ⚠️ 검색 API는 금지다: `gh pr list --author`는 내부적으로 `search(...)`로 갈아탄다(GH_DEBUG=api 실측).
//    검색 인덱스는 **결과적 일관성**이라 직전 주기가 만든 PR이 안 잡히면 **공격자 없이도** 거짓 부재가 난다.
//    connection 질의는 primary datastore = **강한 일관성**이다.
// ⚠️ 모호성 fail-closed는 유지한다: **신뢰 PR이 2건 이상**이면 에러(GitHub 계약상 불가능 — 무언가 깨진 것이다).
// 신뢰 판정은 **서버 필터에 맡기지 않는다**(심층 방어) — isTrusted가 동일-레포 + writer Bot + base를 재검증한다.
//
// ── 레인(--action)과 판정(action)은 **다른 축**이다 ────────────────────────────────────────────
// · 레인 = 플래너(poll-ghcr)가 .bindings.json의 autoDeploy로 정한 배포 승인 모델:
//     autoDeploy:true  → "bump"       (자동 배포 — auto-merge 무장)
//     autoDeploy:false → "propose-pr" (승인 레인 — **사람 머지 = 배포 승인**)
//   호출부는 플래너의 `.action`을 **그대로** `--action`으로 넘긴다(재해석 금지).
// · 판정 = 이 도구가 관측 사실로 정하는 변이 경로(create/adopt/skip/rebuild).
// ⚠️ auto-merge 무장 여부는 **오직 레인**이 정한다(`--action bump`일 때만). 승인 레인을 무장시킬 수 있는
//    별도 플래그는 **존재하지 않는다** — `--auto-merge` 같은 우회 스위치를 두면 호출부가 두 레인 모두에
//    무조건 넘기는 것만으로 `autoDeploy:false` 앱이 자동 배포된다(승인 게이트 우회, plan r5 R-11).
//    승인 레인을 무장시키려면 **플래너를 속여야** 한다 = .bindings.json(autoDeploy SSOT)을 고쳐야 한다.
//
// 신뢰 경계: 이 레포는 **공개**다. 포크(cross-repo) PR은 같은 브랜치명을 쓸 수 있고 아무나 연다 →
// 절대 신뢰하지 않는다. 신뢰하면 포크 PR 하나로 배포를 무기한 억제할 수 있다(억제 = 공격 표면).
// 신뢰하는 제안은 **동일-레포(isCrossRepository=false) + writer App 작성자**뿐이다.
//
// 판정표. push는 **정확히 이 세 argv뿐**:
//   신뢰 PR 없음 + 원격 브랜치 없음            → create   git push origin HEAD:refs/heads/<b>                                → gh pr create
//   신뢰 PR 없음 + 원격 브랜치 **있음**(고아)   → adopt    git push --force-with-lease=refs/heads/<b>:<원격 OID> origin HEAD:refs/heads/<b> → gh pr create
//   신뢰 PR + CLEAN/BLOCKED/UNKNOWN/그 외      → skip     push·create 둘 다 하지 않는다
//   신뢰 PR + **DIRTY 또는 BEHIND** + 사람 흔적 0 → rebuild git push --force-with-lease=refs/heads/<b>:<headRefOid> origin HEAD:refs/heads/<b> (PR 재사용 — create 금지)
//   신뢰 PR + DIRTY/BEHIND + **사람의 흔적**    → skip     force-push하지 않는다(리뷰·승인 상태 파괴 금지 — H-4)
//   조회 실패·깨진 JSON                        → fail-closed(비-0 종료 — 조용한 create 금지)
// ⚠️ UNKNOWN은 DIRTY도 BEHIND도 아니다(GitHub 지연 계산 — 라이브에서 흔하다). rebuild로 오분류하면 매 폴링 force-push.
//
// ★ 모드가 하나 더 있다: `--reconcile-only`(H-1 · R-27) — **해제 스윕만** 한다(push·create·무장·close 전부 0).
//   요약하면 "해제는 보안 속성이라 **후보 계획(planning)의 가용성·완전성에 의존해선 안 된다**":
//     · 후보(tag)가 없어도 돈다(noop/refuse 주기).
//     · **대상 목록을 인자로 받지 않는다** — `bump-poll/*` 원격 ref를 직접 열거하고 app을 브랜치명에서
//       유도한다. 플래너가 죽든, reader 토큰이 죽든, 어떤 앱이 plan.json에서 빠지든 그 앱은 방문된다.
//     · 레인은 autoDeploy SSOT에서 직접 읽고, **부재·파손도 레인이다**(플래너와 같은 결론 = propose-pr →
//       무장 회수). 인가 문맥의 fail-closed는 "아무것도 하지 않는다"가 아니라 "권한을 거둔다"이다(R-26).
//   자세한 근거는 아래 그 블록의 주석 참고.
//
// ★★ BEHIND 수렴은 **이 실행기 몫**이다(structure r7 R-25) — `gh pr update-branch`는 쓰지 않는다 ────
// 예전엔 `pr-sweeper.yaml`이 30분 크론으로 "무장 + BEHIND"인 봇 PR을 `gh pr update-branch`로 전진시켰고,
// 그 선택 접두에 `bump-poll/`이 들어 있었다. 두 가지가 동시에 깨진다:
//   ① **승인 게이트 우회**: 스위퍼는 **레인을 보지 않는다**. autoDeploy가 true→false로 바뀌어도 이미
//      무장된 PR은 무장된 채 남는데, 스위퍼가 브랜치를 갱신해 체크를 재시작시키면 green 시점에 GitHub이
//      **사람 승인 없이 머지**한다. 무장/해제 reconcile은 레인을 아는 이 실행기만 할 수 있다 →
//      **전진(advance)도 같은 소유자여야 한다**. 그래서 스위퍼에서 `bump-poll/` 접두를 뺐다.
//   ② **소유권 인터록 파괴**: `gh pr update-branch`는 base를 head에 머지해 head를 **머지 커밋**으로 만든다.
//      그러면 아래 proveOurCommit(결정적 bump 커밋 메시지 + writer ident)이 **영구 실패**한다 →
//      그 앱의 bump는 무장 회수 + fail-closed로 **영구 정지**한다(라이브에서 이미 충돌하는 조합이었다).
// → 그래서 BEHIND는 **DIRTY와 같은 변이**로 푼다: 호출부가 최신 main에서 재구축해 둔 로컬 커밋을
//   leased force-push한다. 결과적으로 head는 **언제나 우리의 결정적 bump 커밋 1개**이고(소유권 증명 가능),
//   새 gh 동사도 새 권한도 새 argv 계약도 필요 없다. 이 도구는 `gh pr update-branch`를 **절대 실행하지 않는다**.
// ⚠️ rebuild는 **레인-무관**이다(무장만 레인-의존): propose-pr PR도 BEHIND면 사람이 머지 버튼을 누를 수
//    없다(strict 보호). 승인 레인의 수렴은 머지가 아니다 — 그리고 해제(③-a)가 **모든 push보다 먼저**라
//    force-push가 체크를 green으로 되돌리는 순간에도 그 PR엔 이미 무장이 없다.
// ⚠️⚠️ 다만 rebuild는 **사람의 흔적에는 의존한다**(H-4): 리뷰·리뷰어 요청·assignee·사람 코멘트·hold 라벨·
//    draft·reopen 중 하나라도 있으면 **밀지 않는다**(그 force-push가 승인을 stale로 날리고 리뷰 코멘트를
//    outdated로 접는다). 가르는 축은 레인이 아니라 흔적이다 — 자세한 근거는 아래 판정(②) 블록의 주석 참고.
// ⚠️ push argv는 **완전 형태**가 계약이다(plan r3): lease 플래그만 맞고 `origin HEAD:refs/heads/<b>`를
//    빠뜨리면 라이브에선 아무것도 밀지 못한다 → 테스트 stub이 계약 밖 push argv를 exit 3으로 죽인다.
//    · 목적지를 `refs/heads/<b>`로 완전 수식 → lease의 <refname>과 **글자 그대로 같은 ref**(refname_match 모호성 0).
//    · 소스는 `HEAD`(호출부가 재구축해 체크아웃해 둔 상태) → 로컬 브랜치명 표기에 의존하지 않는다.
//    · `-u`(upstream)는 소비자가 없다 — PR 생성은 `gh pr create --head <b>`가, auto-merge는 브랜치명이 몫.
// ⚠️ `--force-with-lease`는 반드시 `<ref>:<expected-oid>` 형태다(plan r2 R-5). bare lease는 그 브랜치의
//    원격 추적 참조가 없으면(워크플로 checkout은 main만 가져온다) stale로 거부돼 회복이 영구 실패한다.
//    반대로 명시 형태는 원격 추적 참조도, 그 OID의 로컬 오브젝트도 필요 없다 — git-push(1):
//    "…or we do not even have to have such a remote-tracking branch when this form is used"
//    (bare 원격 레포로 실측: bare lease=stale 거부 / 명시 lease=forced update 성공).
// DIRTY를 rebuild로 되살리지 않으면 유일한 PR이 충돌난 순간 이후 폴링이 영원히 skip →
// 깨끗한 대체 PR이 영영 안 생겨 배포가 조용히 멈춘다(pr-sweeper는 DIRTY를 안 건드린다).
//
// auto-merge 무장도 **desired state**다(plan r5 R-10). "PR 생성 직후 1회 무장"은 무장이 실패하거나
// (또는 그 사이 프로세스가 죽으면) 영영 복구되지 않는다: 다음 폴링은 그 **무장 안 된 PR**을 신뢰하고
// skip해버리고, pr-sweeper는 `autoMergeRequest`가 **이미 있는** PR만 다룬다 → autoDeploy 배포가 조용히
// 정지한다. 그래서 무장 여부(`autoMergeRequest`)를 사실로 관측한다.
//
// ★ 무장 계약(정확히) — 무장 축은 위 판정표와 **직교**하고, **양방향**이다. 판정은 브랜치/PR의 존재로,
//   무장은 레인 · `autoMergeRequest` · **head 소유권**으로 각각 독립적으로 정해진다:
//     lane=bump      + 신뢰 PR + 무장 없음 + head **우리 것** → 그 run의 **판정이 무엇이든** 재무장한다
//     lane=bump      + 신뢰 PR + 무장 있음 + head **우리 것** → 손대지 않는다(멱등 — force-push는 무장을 지우지
//                                            않는다: autoMergeRequest는 head OID가 아니라 PR에 붙는다)
//     lane=bump      + create/adopt(PR 신규) → 생성 직후 무장한다
//     lane=propose-pr + 신뢰 PR + 무장 **있음** → **해제한다**(gh pr merge --disable-auto <번호>)
//     lane=propose-pr + 그 외                   → 무장하지 않는다(멱등 — 해제할 것도 없다)
//     **head가 우리 것임이 증명되지 않음**(레인 무관) → 무장하지 않는다. 무장돼 있으면 **해제한다**(R-23).
//                                            그 뒤 변이 쪽은 fail-closed(push·create 0).
// ⚠️ 재무장을 skip 경로에만 매달면 **DIRTY + 미무장**에서 새 나간다(라이브에서 실제로 겹치는 조합이다:
//    run 1이 무장에서 죽어 무장 없는 PR이 남고, 이후 main 이동이 그 PR을 충돌시킨다). rebuild만 하고
//    무장 갭을 남기면 PR은 깨끗해지는데 auto-merge가 영영 안 붙어 배포가 정지한다.
// ⚠️⚠️ 소유권은 **force-push 허가**가 아니라 **인가(auto-merge)의 전제조건**이다(R-23). 소유권 검증을
//    force-push 경로에만 걸면, writer가 연 PR의 head를 **다른 행위자가 갈아치운** 경우 상태가 CLEAN이면
//    판정이 skip이라 검증이 아예 돌지 않고 → 그 **남의 커밋에 auto-merge가 무장된 채 유지된다**(= 머지 인가
//    부여). 그래서 소유권은 판정과 무관하게 확인하고, 증명 실패 시 **무장을 거둔다**(회수가 안전 방향).
//
// ★★ 무장이 desired state라면 **해제도 desired state여야 한다**(structure 게이트 high-1) ────────────
// 무장을 "arm만 있고 disarm은 없는" 단방향으로 다루면 **낡은 머지 인가가 살아남는다**:
//   run 1: .bindings.json에 autoDeploy:true → 플래너가 bump 레인 → PR을 열고 **무장**한다.
//   그 사이 owner가 autoDeploy를 **false로 바꾼다**(= 이제부터 사람 머지 = 배포 승인). 그런데 그 결정적
//   PR은 **아직 열려 있다**(같은 app+tag = 같은 브랜치 = 같은 PR).
//   run 2: 플래너가 이제 propose-pr 레인을 준다. 단방향 구현은 "propose-pr이니 무장하지 않는다"로 끝낸다 —
//          그런데 **기존 무장은 그대로 살아 있다** → gate가 green이 되는 순간 GitHub이 **사람 승인 없이 머지**한다.
//          skip(CLEAN/BLOCKED)이든 rebuild(DIRTY)든 똑같이 샌다: 무장은 PR에 붙지 head OID에 붙지 않는다.
// → 승인 레인의 desired state는 "무장 없음"이다. 관측된 무장이 있으면 **그 run에서 즉시 해제**한다.
// ⚠️ 해제는 **첫 변이**다(push/create보다 먼저). 무장된 PR은 gate가 green이 되는 어느 순간에도 머지될 수
//    있으므로, 낡은 인가를 들고 있는 시간을 최소화한다. 특히 rebuild(force-push)를 먼저 하면 그 push가
//    체크를 green으로 만들어 **해제하기 전에** 머지가 성사될 수 있다.
//
// ★★★ 무장·해제의 대상은 **언제나 인증된 PR 번호**다(브랜치명 금지) ────────────────────────────
// `gh pr merge <branch>` / `gh pr view <branch>`는 브랜치명을 **셀렉터**로 해석한다 — 그런데 이 레포는
// 공개고, 포크는 **같은 결정적 브랜치명**으로 PR을 열 수 있다. 브랜치 셀렉터로 무장하면 그 조회가
// **동명 포크 PR을 지목**할 수 있고, 그러면 **공격자의 코드가 auto-merge된다**(신뢰 경계를 조회 단계에서만
// 지키고 변이 단계에서 흘린 셈이다). 그래서 인증된 셀렉터를 변이 경로 **끝까지** 들고 간다:
//     skip/rebuild(기존 PR) → trusted.number          (조회에서 신뢰 판정을 통과한 그 PR)
//     create/adopt(새 PR)   → gh pr create가 낸 URL의 번호 (gh가 "방금 내가 만든 PR"이라고 알려준 값)
//     해제(propose-pr)      → trusted.number
// 번호를 확정할 수 없으면 **fail-closed** — 브랜치명으로 폴백하지 않는다(폴백이 곧 이 결함이다).
// 공유 스크립트 `auto-merge-or-fail.sh`는 인자를 `gh pr merge`/`gh pr view`에 그대로 넘기는 **패스스루**라
// (브랜치명 자체를 쓰는 로직이 없다) 번호를 넘기는 것만으로 모호성이 사라진다 — 스크립트는 손대지 않는다.
// (다른 호출자 bump.yaml·pr-first-commit은 계속 브랜치를 넘긴다 — 그 경로엔 포크 PR이 끼어들 수 없다.)
//
// ★★★★ superseded 형제 PR — 소유 범위의 키는 (app, tag)가 아니라 **네임스페이스**다(R-25) ──────────
// (app, tag) 한 브랜치만 방문하는 실행기는 **더 새 태그가 나오는 순간 옛 PR을 영영 보지 못한다**:
//   run N   : tag T1 → bump-poll/<app>-T1 PR을 열고 무장한다.
//   run N+1 : 앱이 T2를 빌드했다 → 플래너의 후보가 T2로 갈아탄다 → 브랜치가 bump-poll/<app>-T2다.
//             T1 PR은 **열린 채, 무장된 채** 남고 아무도 방문하지 않는다(라이브 좀비 #348·#350·#351).
// 그 낡은 인가는 살아 있다: 누가(사람의 "Update branch" 버튼, 다른 워크플로) 그 브랜치를 전진시키면
// **옛 이미지가 승인 없이 배포**된다(= 무승인 롤백). 그래서 실행기는 `bump-poll/<app>-*` **전체**를 소유한다.
//
// 두 행동을 **분리**한다(파괴는 언제나 뒤, 증거는 언제나 앞):
//   ① **해제 스윕(넓게·약한 증거·중단 불가)** — 이번 후보가 아닌 모든 형제 writer PR의 무장을 회수한다.
//      **레인을 읽지 않는다**: superseded PR은 레인과 무관하게 머지될 자격이 없다. 회수는 안전 방향이라
//      소유권 증명도 필요 없다. R-25의 피해는 **이 스윕 하나로 100% 사라진다**.
//   ② **close 스윕(좁게·강한 증거·언제든 포기)** — 순수 위생이다(좀비 누적 방지). 파괴 방향이므로
//      증거가 하나라도 모자라면 **아무것도 닫지 않는다**. 브랜치는 **어떤 경우에도 삭제하지 않는다**
//      (close는 reopen으로 되돌아가지만 ref 삭제는 되돌아가지 않는다).
// ⚠️ **"더 새로운 태그"는 증명할 수 없다**: 실행기의 GH_TOKEN은 writer(homelab 전용)라 앱 레포 compare를
//    호출할 수 없고, 애초에 T1과 T2 사이엔 git 순서가 없다(GHCR 빌드 완료 역전·앱 레포 revert). 유일하게
//    건전한 명제는 "플래너가 **이번 run에** 승인한 후보는 T 하나이며 이 PR은 T가 아니다"뿐이다.
//    close의 순서 근거는 그래서 **PR의 createdAt**이다(전순서를 갖는 유일한 관측 사실): **우리 PR보다
//    엄격히 오래된** 형제만 닫는다 → 두 실행기가 동시에 돌아도 서로를 닫는 flip-flop이 구조적으로 불가능하다.
// close의 증거(**전부** 만족해야 한다 — 하나라도 아니면 close 0):
//   포크 아님 · writer **Bot** 작성 · 같은 base · 리터럴 접두 `bump-poll/<app>-` + TAG_RE 완전일치 ·
//   tag ≠ 우리 tag · **그 PR 자신의 tag로 재계산한 커밋 메시지·ident로 head 소유권 증명** ·
//   createdAt < 우리 PR · **사람의 흔적 0**(리뷰·사람 코멘트·리뷰어 요청·assignee·draft·hold 라벨) ·
//   **우리 PR이 이미 열려 있음**(후계자 없는 제거 금지) · 후보 수 ≤ CLOSE_MAX · 레인 = bump.
// ⚠️ 승인 레인(propose-pr)의 형제는 **해제만 하고 닫지 않는다** — 그 레인의 존재 이유가 사람의 판단이다.
// ⚠️ 스윕의 조회·close 실패는 **abort시키지 않는다**(주 판정은 끝까지 간다). 안 그러면 아무나
//    `bump-poll/<app>-*` 브랜치 하나를 만들어 **배포를 영구 정지**시킬 수 있다(억제 = 공격 표면).
//    다만 **조용하지도 않다** — 아래 두 별표 블록(R-32 · V-2)이 그 결과 계약을 정한다.
//
// ★★★★★ 그런데 **회수 실패는 조용히 지나갈 수 없다**(structure r9 R-32) ─────────────────────────
// 계속하는 것(비-기아)과 성공으로 끝나는 것(비-보고)은 **다른 이야기**인데 예전 코드는 그 둘을 한 덩어리로
// 묶었다: 형제 해제가 실패하면 warn만 하고 exit 0으로 끝났다 → 옛 PR이 **열린 채 무장된 채** 남는데
// (close는 사람 흔적·불완전 열거·CLOSE_MAX 캡·킬 스위치로 **정상적으로** 막힐 수 있다) 프로세스는 **성공**으로
// 끝나고 telegram도 울리지 않는다. "회수 실패는 보안 사실이다"라는 불변식과 정면으로 모순된다.
// → 회수는 **결과를 나르는 하나의 공유 연산**이다(revokeArming): 두 경로(--reconcile-only · 형제 스윕)가
//   같은 실패 계약을 쓴다 —
//     ① **모든 대상과 메인 변이는 끝까지 처리한다**(억제 = 공격 표면 — 한 실패가 다른 앱·다른 변이를 굶기면 안 된다),
//     ② 실패한 회수를 **전부 집계**해 처리가 끝난 뒤 **비-0으로 종료**한다(run이 빨개지고 telegram이 발화한다),
//     ③ **무엇을 회수하지 못했는지 보고에 남긴다**(stdout JSON의 `revocationFailures`).
// ⚠️ 이 계약은 close의 성공 여부에 **의존하지 않는다** — 위생(close)의 성공에 보안 사실(회수)의 보고를
//    매다는 것이 바로 이 결함이었다.
//
// ★★★★★★ 그리고 **회수 대상을 보는 일(관측)에도 같은 계약이 걸린다**(V-2) ────────────────────────
// R-32는 회수 **호출**에만 실패 계약을 줬다. 그 바로 앞 단계 — 형제 ref 열거 · 형제 PR 조회 · 파싱 ·
// 신뢰 PR 모호성 — 은 여전히 warn + `closeAbandoned`로 끝났는데, `closeAbandoned`는 **close만** 막고
// 종료 코드엔 아무 영향이 없다(종료 코드는 오직 revocationFailures가 정한다). 즉 형제 하나의 조회가 깨지면
// **그 브랜치의 무장된 좀비를 보지도 못한 채 run이 초록**이었다. 반대편(`--reconcile-only`)은 같은 넷을
// 실패로 집계해 exit 1이었다 → "두 경로가 같은 실패 계약을 쓴다"는 이 헤더의 주장이 **거짓**이었다.
// → **회수 대상을 가릴 수 있는 관측 실패는 그 자체로 회수 실패다**(revocationBlind). 모르는 것을 근거로
//   "회수할 게 없었다"고 말할 수 없다. 이제 두 경로가 정말로 하나의 결과 계약을 공유한다.
//
// ★★★★★★★ 회수의 **완전성**도 마찬가지다 — `--reconcile-only`는 네임스페이스 전체를 판정한다(V-1) ──
// 회수 트리거는 셋(레인 뒤집힘 · superseded 형제 · 증명되지 않은 head)인데, 예전엔 `--reconcile-only`가
// **첫째만** 다루고(`if (lane === "bump") continue`) 나머지 둘을 주 경로에만 뒀다. 그런데 주 경로는
// **플래너가 그 앱의 후보를 낸 주기에만** 돈다 → `autoDeploy:true` 앱의 superseded 무장은 `noop`
// (bump 머지 직후의 **정상 상태**)나 `refuse` 주기에 **아무도 회수하지 않는다**. 자세한 근거와 그 패스의
// 새 규칙은 아래 `--reconcile-only` 블록의 주석 참고.
//
// 사실은 파싱·검증해 stdout의 `observed`에(무장 여부 포함), 실제 실행한 명령은 `executed`에 실어
// 호출부/테스트가 "무엇을 관측하고 무엇을 변이했는가"를 검증할 수 있게 한다
// (tools/tests/test_ensure-bump-pr.bats가 argv 원장으로 이 계약을 고정한다).
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { TAG_RE, descriptorAutoDeploy } from "./lib/image-pin.ts";

const USAGE = `ensure-bump-pr — bump PR 멱등 실행기(조회 → 결정 → 변이; 같은 bump = 같은 브랜치 = 열린 PR 1개)
사용법: bun tools/ensure-bump-pr.ts --app <app> --tag <sha-tag> --action <lane> --title <t> --body <b> [옵션]
       bun tools/ensure-bump-pr.ts --reconcile-only                      (인가 회수 전용 패스 — 대상은 네임스페이스)
  --app <app>       앱 이름(소문자/숫자/하이픈)
  --tag <tag>       후보 배포 핀 tag(sha-<7..40 hex>) — 브랜치는 bump-poll/<app>-<tag>(RUN_ID 없음)
  --action <lane>   플래너(poll-ghcr)의 .action을 **그대로** — bump | propose-pr (필수, 기본값 없음)
                      bump       = autoDeploy:true  → auto-merge 무장(desired state — 없으면 재무장)
                      propose-pr = autoDeploy:false → **절대 무장하지 않는다**(사람 머지 = 배포 승인)
  --title <t>       gh pr create --title
  --body <b>        gh pr create --body
  --base <branch>   PR base (기본 main)
  --remote <name>   git 원격 (기본 origin)
  --writer <slug>   신뢰하는 writer App slug(기본 ukyi-homelab-writer)
  --reconcile-only  **해제 스윕만** 수행한다(push·PR 생성·무장·close 전부 0). 후보(tag)가 없어도,
                    플래너가 죽어도 돈다 — **대상은 \`bump-poll/*\` 원격 ref 전체**(app은 브랜치명에서 유도)이고,
                    레인은 autoDeploy SSOT(.bindings.json / .image-pin.json)에서 **직접** 읽는다.
                    SSOT 부재·파손 = 플래너와 같은 결론(autoDeploy:false) → **무장을 회수한다**.
                    이 모드에선 --app/--tag/--title/--body/--action을 받지 않는다(대상·레인 주입 금지).
  --root <dir>      autoDeploy SSOT 탐색 루트(기본 = 레포 루트) — --reconcile-only 전용
  --help, -h        이 도움말
⚠️ auto-merge를 켜는 **별도 플래그는 없다** — 레인이 유일한 입력이다(승인 게이트 우회 방지, plan r5 R-11).
전제: 호출부가 <branch>를 **최신 main에서 재구축**해 로컬 커밋을 얹어 둔 상태(원격 변이만 이 도구 몫).
출력(stdout): {"action":"create"|"adopt"|"skip"|"rebuild","lane":"bump"|"propose-pr","reason":"…","branch":"…","observed":{…},"superseded":[…],"revocationFailures":[…],"executed":[…]}
종료코드: 0=정상 / 1=fail-closed 또는 **회수 실패**(무장을 거두지 못했다 — 변이는 다 했다) / 2=사용법`;

// 기본 writer App slug. gh는 App 작성자를 `app/<slug>`로, REST/GraphQL은 `<slug>[bot]`로 준다 →
// 아래 normalizeLogin이 두 표기를 모두 같은 slug로 정규화한다.
const DEFAULT_WRITER = "ukyi-homelab-writer";
const APP_RE = /^[a-z0-9-]+$/;
const OID_RE = /^[0-9a-f]{40}$/;

// ── superseded 스윕의 블라스트 반경 상수 ───────────────────────────────────────────────────────
// close 후보가 이보다 많으면 **한 건도 닫지 않는다**. 접두 파싱 버그 한 글자가 열린 봇 PR을 무더기로
// 닫는 사고를 상수로 묶는다(선례: teardown DNS 가드의 allow_max 대량삭제 캡).
const CLOSE_MAX = 3;
// 사람이 "이건 닫지 마라"고 말할 수 있는 명시적 탈출구(문서화된 라벨).
const HOLD_LABELS = ["hold", "do-not-close"];
// 킬 스위치 — **close만** 끈다(해제 스윕은 계속 돈다). 인가(무장/레인)엔 어떤 영향도 주지 않는다:
// 인가를 바꾸는 플래그를 또 만들면 승인 게이트 우회가 재발한다(R-11의 교훈).
const CLOSE_ENABLED = (process.env.BUMP_PR_CLOSE ?? "on") !== "off";


// 배포 승인 레인 — poll-ghcr.ts가 내는 값과 **글자 그대로** 같다(`s.autoDeploy ? "bump" : "propose-pr"`).
// 호출부가 이 값을 재해석하지 않고 그대로 넘기므로, 승인 레인(propose-pr)을 자동 배포로 바꾸려면
// .bindings.json의 autoDeploy(SSOT)를 고치는 수밖에 없다 — 워크플로 편집만으론 불가능하다.
const LANES = ["bump", "propose-pr"] as const;
type Lane = (typeof LANES)[number];
function isLane(v: string): v is Lane {
  return (LANES as readonly string[]).includes(v);
}

// 레포 루트 — autoDeploy SSOT(.bindings.json / .image-pin.json) 탐색의 기본 기준점.
// 이 파일은 언제나 <root>/tools/ 아래에 있다(scripts/auto-merge-or-fail.sh 경로 해석과 같은 관용구).
const REPO_ROOT = path.join(import.meta.dir, "..");

const args: {
  app?: string; tag?: string; title?: string; body?: string; lane?: Lane;
  writer: string; base: string; remote: string; reconcileOnly: boolean; root: string;
} = { writer: DEFAULT_WRITER, base: "main", remote: "origin", reconcileOnly: false, root: REPO_ROOT };
const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) { console.log(USAGE); process.exit(0); }
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--app") args.app = argv[++i];
  else if (a === "--tag") args.tag = argv[++i];
  else if (a === "--title") args.title = argv[++i];
  else if (a === "--body") args.body = argv[++i];
  else if (a === "--action") {
    const v = argv[++i] ?? "";
    if (!isLane(v)) usageError(`--action 형식 위반: '${v}' (${LANES.join(" | ")})`);
    args.lane = v;
  }
  else if (a === "--base") args.base = argv[++i] ?? "";
  else if (a === "--remote") args.remote = argv[++i] ?? "";
  else if (a === "--writer") args.writer = argv[++i] ?? "";
  else if (a === "--reconcile-only") args.reconcileOnly = true;
  else if (a === "--root") args.root = argv[++i] ?? "";
  else {
    console.error(`알 수 없는 옵션: ${a}`);
    process.exit(2);
  }
}

// 사용법 위반(인자)은 exit 2. 비신뢰 입력(gh/git 출력)·조회 실패는 exit 1 — 셋 다 fail-closed
// (조용한 create 금지: "조회 실패 = 중복 PR"이 되면 버그가 그대로 재현된다).
function usageError(msg: string): never {
  console.error(`ensure-bump-pr: ${msg}`);
  process.exit(2);
}
function inputError(msg: string): never {
  console.error(`ensure-bump-pr: 신뢰할 수 없는 조회 출력 — ${msg} (fail-closed: 판정도 변이도 하지 않는다)`);
  process.exit(1);
}
function execError(msg: string): never {
  console.error(`ensure-bump-pr: ${msg} (fail-closed: 변이하지 않는다)`);
  process.exit(1);
}

// ── --reconcile-only의 인자 표면은 **의도적으로 다르다**(H-1 · R-27) ────────────────────────────
// 이 모드엔 후보(tag)가 없다 — 애초에 "플래너가 후보를 내지 못한 주기에도 인가를 회수한다"가 존재 이유다.
// 그리고 **레인도, 앱도 인자로 받지 않는다**:
//   · 레인을 받으면 호출부가 레인을 지어낼 수 있다(승인 게이트 우회, R-11). 레인은 probeLane()이
//     autoDeploy SSOT에서 **직접** 읽는다.
//   · **앱을 받으면 호출부가 대상 목록을 정한다**(R-27). 그러면 회수의 완전성이 **호출부의 목록**에
//     의존한다 — 플래너가 죽거나 어떤 앱이 그 출력에서 빠지면 그 앱은 **방문되지 않고**, 낡은 무장이
//     그대로 산다. 회수는 보안 속성이라 **가용성에도, 다른 스텝의 성공에도 의존해선 안 된다**.
//     → 대상은 **네임스페이스가 권위**다: `bump-poll/*` 원격 ref를 열거하고 `<app>`을 브랜치명에서 유도한다.
// 계약 위반(레인·후보·대상 주입 시도)은 exit 2로 시끄럽게 죽인다.
if (args.reconcileOnly) {
  for (const forbidden of ["--app", "--tag", "--title", "--body", "--action"]) {
    if (argv.includes(forbidden)) {
      usageError(
        `--reconcile-only에는 ${forbidden}을 넘기지 않는다 — 이 모드는 후보(tag)도, 레인 인자도, **대상 앱**도 받지 않는다. `
        + "대상은 `bump-poll/*` 네임스페이스(원격 ref)가 권위이고(호출부가 목록을 좁히면 회수가 굶는다), "
        + "레인은 autoDeploy SSOT(.bindings.json / .image-pin.json)에서만 나온다(호출부의 레인 주입 = 승인 게이트 우회)",
      );
    }
  }
} else {
  if (!args.app) usageError("--app 필수");
  if (!APP_RE.test(args.app)) usageError(`--app 형식 위반: '${args.app}' (소문자/숫자/하이픈만)`);
  if (!args.tag) usageError("--tag 필수");
  if (!args.title) usageError("--title 필수");
  if (!args.body) usageError("--body 필수");
  // 레인은 **기본값 없이 필수**다 — 기본값을 두면(무엇이든) 호출부가 레인을 빼먹었을 때 조용히 한쪽으로
  // 흘러간다. bump로 기본하면 승인 앱이 자동 배포되고, propose-pr로 기본하면 autoDeploy 배포가 멈춘다.
  if (!args.lane) usageError(`--action 필수 (${LANES.join(" | ")}) — 플래너의 .action을 그대로 넘긴다`);
  if (!TAG_RE.test(args.tag)) usageError(`--tag 형식 위반: '${args.tag}' (sha-<7..40 hex>)`);
}

// 검증을 통과한 필수 인자 — 함수 안에서도 좁혀진 타입으로 쓰기 위해 상수로 고정한다.
// ⚠️ reconcile 모드엔 **앱도 후보도 없다**(둘 다 빈 문자열) — 그 모드의 주체는 네임스페이스가 정한다.
const APP: string = args.app ?? "";
const TAG: string = args.tag ?? "";
const lane: Lane = args.lane ?? "propose-pr"; // reconcile 모드에선 쓰이지 않는다(probeLane이 레인을 정한다)

// 결정적 브랜치명 — 같은 bump는 항상 같은 브랜치로 수렴한다(RUN_ID 제거가 중복 PR 픽스의 토대다:
// run마다 브랜치가 달라지면 "이 bump의 열린 PR"을 조회할 대상 자체가 없다).
// ⚠️ reconcile 모드엔 후보가 없으므로 **자기 브랜치가 없다**(빈 문자열) — 그 모드는 아래 주 경로를 타지 않는다.
const branch = args.reconcileOnly ? "" : `bump-poll/${APP}-${TAG}`;
const ref = `refs/heads/${branch}`;

// 실행한 명령 원장 — stdout JSON에 실어 호출부/테스트가 "무엇을 변이했는가"를 검증한다.
// ⚠️ 여기 담는 건 **변이**(create/push/arm/disarm/close·ls-remote)뿐이다 — 그 수는 경계 있다.
//    read-only GraphQL 페이지 조회(foldConnection)는 **여기 남기지 않는다**(runSoft audit=false): 남기면
//    원장이 포크 수(=페이지 수)에 비례해 커져 **부모 힙과 워크플로 로그를 다시** 키운다(R-36이 없앤 억제
//    표면의 한 칸 아래 재현). 페이지네이션은 아래 graphqlPages 카운터 하나로만 관측한다.
const executed: string[] = [];

// GraphQL 페이지네이션의 **경계 있는 관측**(R-36): 이번 run에서 몇 페이지를 접었는가 — **정수 하나**다
// (질의 문자열의 배열이 아니다). 값은 페이지 수(≈ 열린 PR 총수/100)라 포크가 많으면 커지지만, 직렬화·힙
// 비용은 언제나 O(1)이다(한 정수). read-only 조회를 executed에서 뺀 자리를 이 카운터가 대신 관측한다.
let graphqlPages = 0;

function run(cmd: string, a: string[], what: string): string {
  const r = runSoft(cmd, a);
  if (r.failure !== null) execError(`${what} ${r.failure}`);
  return r.stdout;
}
// superseded 스윕 전용 경고 — **주 판정을 abort시키지 않는다**(I-5). 스윕이 죽을 수 있으면 아무나
// `bump-poll/<app>-*` 브랜치 하나를 만들어 배포를 영구 정지시킬 수 있다(억제 = 공격 표면).
function warn(msg: string): void {
  process.stderr.write(`::warning::ensure-bump-pr: ${msg}\n`);
}
// ══ subprocess 캡처의 **버퍼 경계**는 조회의 상한이다(structure r10 R-33) ══════════════════════
// spawnSync는 자식의 stdout을 **한 덩어리로 버퍼링**한다. 그 버퍼엔 유한한 상한이 있고, 넘으면 자식이
// **죽는다**. 실측(bun 1.3.14 / node:child_process — 이 도구가 도는 바로 그 런타임):
//     기본 maxBuffer = **1 MiB**. 정확히 1 MiB → 정상(status 0). 1 MiB + 1바이트 →
//     `error.code = "ENOBUFS"` · `status = null` · `signal = "SIGTERM"` (자식이 SIGTERM으로 살해된다).
//     `stdout`엔 **잘린 앞부분**이 남는다(4/16/64 MiB 입력 모두 1.5 MiB에서 잘렸다) — 조용한 절단은
//     아니지만(error가 반드시 선다), 그 사실을 안 보면 잘린 바이트를 파싱하게 된다.
//     maxBuffer:Infinity → 16 MiB도 온전히(status 0) 받는다.
// → 즉 **위에서 상한을 없앤 조회가 여기서 다시 상한에 묶인다**: 같은 head의 포크 PR을 충분히 열면
//   (각 PR이 comments(first:100)·labels(first:50)까지 실어 오므로 PR 한 건이 수 KB다) 응답 총량이
//   1 MiB를 넘고 → gh가 살해되고 → 그 앱의 폴링이 **매 주기 fail-closed**한다. R-13/R-17에서 GraphQL
//   계층에서 없앤 **포크 포화 = 배포 정지 무기**가 한 층 아래에서 그대로 재현된다.
// ★ 그래서 진짜 픽스는 버퍼를 키우는 게 아니라 **한 번의 캡처를 한 페이지로 경계짓는 것**이다
//   (아래 fetchConnection — `--paginate --slurp`를 버리고 페이지를 우리가 직접 따라간다).
//   버퍼를 키우는 건 벽을 **옮길** 뿐이다: 포크를 10배 더 열면 다시 넘는다. 페이지 소비는 벽을 **없앤다**
//   — 캡처 크기가 포크 수와 **무관해지기** 때문이다(캡처 = 언제나 한 페이지 = 질의가 정한 상한).
//
// ⚠️ 그렇다고 기본 1 MiB로 둘 수는 없다 — **정상적인 한 페이지도 거기 닿을 수 있다**(실측):
//      한 페이지(PR 100건)가 질의의 상한을 다 채우면 = 각 PR이 comments 100건 + labels 50건(50자) →
//      **약 690 KB**. 기본 1 MiB와의 여유는 겨우 1.5배다. 그 페이지가 상한을 넘기면 gh가 살해되고
//      그 앱의 폴링은 **매 주기 fail-closed**한다 — 우리가 없애려는 그 억제가 다시 생긴다.
//   → **명시 상한을 둔다: 4 MiB**(정상 최악 페이지의 약 6배). 도달 불가능하지만 **존재하는** 상한이다:
//     · 공격자는 이 값을 넘길 수 없다 — 페이지 크기는 **우리 질의**가 정하지 포크 수가 정하지 않는다.
//     · 그래도 넘는다면 그건 공격이 아니라 **우리가 모르는 스키마 변화**다 → error가 서고, 우리는 그
//       실패를 **시끄럽게** 다룬다(fail-closed / revocationBlind). 조용한 절단은 어느 경로에도 없다.
//   ⚠️ Infinity(무한 버퍼)는 응답 하나로 메모리를 태울 수 있어 쓰지 않는다.
//   ⚠️ 이 상한을 **키우면 회귀 증인이 RED가 된다**(하네스가 이 상수를 소스에서 읽어 픽스처가 그 경계를
//      정말로 넘는지 확인한다) — 상한을 키우려면 그 경계를 넘는 증인을 함께 키워야 한다.
const MAX_CAPTURE = 4 * 1024 * 1024;

// 실패를 **값으로** 돌려주는 실행기 — 소유권 조회 전용이다. 왜 `run`(즉시 abort)이 아닌가:
// 소유권 판정은 이제 **인가 조정(auto-merge 무장/해제)의 입력**이라, 그 실패조차 "해제(안전 방향)"보다
// 먼저 프로세스를 죽이면 안 된다(★★ 아래 순서 규칙 참고). 여기선 실패를 값으로 받아 두고,
// 해제를 먼저 낸 다음에 fail-closed한다.
// ⚠️ 캡처 실패(ENOBUFS)는 `r.error`로 선다 → 아래 첫 가드가 잡는다. 살해된 자식은 status=null이라
//    둘째 가드(`status !== 0`)에도 걸린다. **잘린 stdout을 성공으로 읽는 경로는 없다.**
// audit=false는 **read-only 페이지 조회 전용**(foldConnection) — 그 조회만 원장에서 뺀다. 변이 경로는
// 전부 기본값(audit=true)으로 예전 그대로 원장에 남는다(create/push/arm/disarm/close·ls-remote 무변경).
function runSoft(cmd: string, a: string[], audit = true): { failure: string | null; stdout: string } {
  if (audit) executed.push([cmd, ...a].join(" "));
  const r = spawnSync(cmd, a, { encoding: "utf8", maxBuffer: MAX_CAPTURE });
  if (r.error) return { failure: `실행 실패: ${r.error.message}`, stdout: "" };
  if (r.stderr) process.stderr.write(r.stderr);
  if (r.status !== 0) return { failure: `실패(exit ${r.status})`, stdout: r.stdout ?? "" };
  return { failure: null, stdout: r.stdout ?? "" };
}
// 변이 명령의 stdout은 stderr로 흘린다 — 이 도구의 stdout은 결과 JSON 전용(호출부가 jq로 읽는다).
function mutate(cmd: string, a: string[], what: string): void {
  const out = run(cmd, a, what);
  if (out) process.stderr.write(out);
}

// ══ 회수(auto-merge 무장 해제) = **결과를 나르는 하나의 공유 연산**(R-32) ═══════════════════════
// 두 스윕(`--reconcile-only` · 주 경로의 superseded 형제)이 **같은 함수, 같은 실패 계약**을 쓴다:
//   · 실패해도 **던지지 않는다** → 호출부는 나머지 대상과 **메인 변이를 계속 처리**한다(억제 = 공격 표면:
//     한 PR의 회수 실패가 다른 앱의 배포나 다른 회수를 굶기면 안 된다).
//   · 실패는 **여기 한 곳에** 모인다 → 처리가 끝난 뒤 호출부가 이 배열로 **비-0 종료**를 결정하고,
//     **무엇을 회수하지 못했는지**를 stdout JSON(`revocationFailures`)에 남긴다.
// ⚠️ 이 배열이 비지 않았는데 exit 0으로 끝나는 경로는 **하나도 없어야 한다** — 그게 R-32의 결함이었다
//    (해제 실패 + close 차단 = 무장된 좀비 PR이 남는데 run은 초록, telegram 무발화).
// ⚠️ 대상은 언제나 **인증된 PR 번호**다(브랜치 셀렉터는 동명 포크 PR로 오조준될 수 있다).
const revocationFailures: string[] = [];
function revokeArming(number: number, where: string): boolean {
  const r = runSoft("gh", ["pr", "merge", "--disable-auto", String(number)]);
  if (r.failure === null) return true;
  const why = `PR #${number}(${where}) auto-merge 해제 실패 ${r.failure}`;
  revocationFailures.push(why);
  warn(
    `${why} — **다음 주기가 재시도한다**(그 재시도는 이제 후보 유무와 무관하다: `
    + "`--reconcile-only`가 네임스페이스 전체를 방문해 superseded 무장을 레인과 무관하게 회수한다 — V-1). "
    + "처리는 계속하지만(다른 대상·다른 변이를 굶기지 않는다) "
    + "이 run은 **비-0으로 끝난다**: 회수하지 못한 무장은 보안 사실이다(낡은 인가가 살아 있다)",
  );
  return false;
}

// ══ 회수 대상을 **가릴 수 있는 관측 실패**는 그 자체로 회수 실패다(V-2) ═══════════════════════════
// R-32는 회수 **호출**(gh pr merge --disable-auto)에 실패 계약을 줬지만, **무엇을 회수해야 하는지 보는 일**
// (형제 ref 열거 · 형제 PR 조회 · 파싱 · 신뢰 PR 모호성)엔 주지 않았다. 그 넷은 warn + `closeAbandoned`만
// 세우고 **exit 0으로 끝났다** — 그런데 `closeAbandoned`는 **close(위생)만** 막고 종료 코드엔 아무 영향이 없다.
// 결과: 형제 하나의 PR 조회가 깨지면 **그 브랜치의 무장된 좀비 PR을 보지도 못한 채** run이 초록으로 끝난다.
// 반대편(`--reconcile-only`)은 같은 넷을 실패로 집계해 exit 1이었다 → **두 경로의 계약이 갈라져 있었다**.
// → 관측 실패도 `revocationFailures`에 모은다. 두 경로가 이제 **하나의 결과 계약**을 공유한다:
//   ① 나머지 대상과 **메인 변이는 끝까지** 처리한다(억제 = 공격 표면 — 아무나 형제 브랜치 하나로 배포를
//      정지시킬 수 있으면 안 된다), ② 끝나고 **비-0 종료**, ③ **무엇을 보지 못했는지 보고에 남긴다**.
// ⚠️ "가려졌을 수 있다"와 "가려졌다"를 구분하지 않는다 — 회수는 보안 속성이라 **모른다 = 실패**다.
function revocationBlind(why: string): void {
  revocationFailures.push(why);
  warn(
    `${why} — 회수 **대상을 관측하지 못했다**(가려진 무장이 있을 수 있다). 처리는 계속하지만 `
    + "이 run은 **비-0으로 끝난다**: 보지 못한 것을 근거로 '회수할 게 없었다'고 말할 수 없다",
  );
}

// ══ ref 소유권 검증 — **두 모드가 공유한다**(주 경로 ③-b · `--reconcile-only`의 R-23 패리티) ═══════
// ★ PR 작성자 인증(isTrusted)은 **누가 PR을 열었는지**만 증명한다 — **그 ref를 누가 마지막으로 썼는지**는
//   증명하지 않는다. 두 구멍이 남아 있었다:
//     · adopt : PR이 안 보이는 원격 ref를 **무조건** force-push로 덮어썼다(그 브랜치가 우리 잔해라는 근거 0).
//     · rebuild: writer가 연 PR이라도, **다른 동일-레포 행위자가 그 head에 push**하면 PR 작성자는 그대로
//                writer다 → 신뢰된 채로 남고, 우리는 그 사람의 커밋을 force-push로 지운다.
//
// ★★ 소유권은 **force-push 허가**만이 아니라 **인가 조정(auto-merge)의 입력**이다(structure r6 R-23) ──
// 예전엔 이 검증을 force-push 경로(adopt/rebuild)에만 걸었다. 그래서 두 구멍이 남았다:
//   ① skip 경로: writer가 연 PR인데 **head 커밋이 다른 행위자로 교체**됐다. 상태가 CLEAN/BLOCKED/UNKNOWN이면
//      판정은 skip이고, 소유권은 아예 검사되지 않는다 → bump 레인이 그 **증명되지 않은 head에 auto-merge를
//      무장**하거나(무장 갭이면) **이미 걸린 무장을 그대로 둔다**. 그건 남의 커밋에 **머지 인가를 부여**한
//      것이다(auto-merge는 PR에 붙고, gate가 green이 되는 순간 그 head가 main으로 들어간다).
//   ② propose-pr 해제 경로: ARMED + DIRTY + 낯선 head인 PR은 소유권 검증에서 **먼저 죽어** `--disable-auto`에
//      닿지 못했다 → **낡은 인가가 가장 필요할 때 살아남았다**.
// → 계약: **증명되지 않은 head는 무장하지 않고, 이미 무장돼 있으면 해제한다**(인가 회수 = 안전 방향).
//   그 뒤에 변이 쪽을 fail-closed한다(force-push 0 · create 0).
// ⚠️ **순서 규칙**: 회수(해제)는 **abort할 수 있는 소유권 검사보다 먼저** 실행한다. 안전 방향 행동이 앞,
//   중단 가능한 검사가 뒤다. 그래서 조회(probe)는 값을 돌려줄 뿐 **죽지 않고**(runSoft), 죽는 건 ③-b다.
// ⚠️⚠️ 같은 계약이 `--reconcile-only`에도 걸린다(V-1의 4번): 그 패스가 **무장을 남겨 두기로 한** PR
//    (= bump 레인의 최신 PR)은 **head가 우리 것임이 증명된 경우에만** 그 인가를 유지한다. 증명하지
//    못하면 회수한다 — 레인과 무관하게. 안 그러면 R-23의 구멍이 후보 없는 주기에 그대로 열려 있다.
//
// 우리 커밋의 조건(전부 만족해야 한다 — 하나라도 아니면 "증명되지 않음"):
//   · author·committer의 name = `<writer>[bot]`, email = `<id>+<writer>[bot]@users.noreply.github.com`
//     (호출부가 `git config user.name/user.email`로 심는 바로 그 정체성 — bump-poll.yaml과 계약이 묶여 있고,
//      그 드리프트는 tests/gates/test_bump-poll-callsite.bats가 잡는다)
//   · 메시지 = 그 bump의 커밋 메시지와 **정확히** 일치(app·tag까지) — 브랜치가 (app, tag)로 결정적이므로
//     그 브랜치의 우리 커밋 메시지도 결정적이다.
// ⚠️ **이건 인증이 아니라 안전 인터록이다**(라이브 확인: 이 커밋들은 `signature: null` — 워크플로의
//    `git commit` + 토큰 push는 서명되지 않는다). git의 author/committer는 자유 텍스트라 contents:write를
//    가진 **악의적** 행위자는 이 정체성과 메시지를 위조할 수 있다. 즉 이 가드가 확실히 막는 것은
//    **사고성 파괴**(다른 봇/사람이 같은 ref를 쓰는 경우, 남은 남의 브랜치, 낯선 커밋)이고,
//    악의적 행위자에 대해서는 심층 방어일 뿐이다. **강제 가능한 불변식은 ruleset**(`bump-poll/**`를 writer App
//    전용으로 예약)이며 그건 이 도구 밖(레포 설정/IaC)이다 — 그 전까지 이 인터록이 최선의 방어다.
function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
// GraphQL 커밋 조회 — 라이브 실측 스키마(이 레포의 실제 bump 커밋):
//   {"oid":"5bb77fc…","message":"chore: page 이미지를 sha-815abb1…(digest 핀)로 갱신 (GHCR 폴링)",
//    "author":{"name":"ukyi-homelab-writer[bot]",
//              "email":"293311924+ukyi-homelab-writer[bot]@users.noreply.github.com"},
//    "committer":{…같음…}}
const COMMIT_QUERY = `query($owner:String!,$repo:String!,$oid:GitObjectID!){
  repository(owner:$owner,name:$repo){
    object(oid:$oid){
      ... on Commit { oid message author{ name email } committer{ name email } }
    }
  }
}`;
// 호출부(bump-poll.yaml)가 만드는 커밋 메시지 — **(app, tag)로 결정적**이다.
// ★ reconcile 패스는 자기 app/tag가 없다(주체는 네임스페이스가 준다) → **브랜치에서 유도한 (app, tag)**로
//   기대 메시지를 재계산한다. 그래서 이 함수는 app까지 인자로 받는다(전역 APP에 매달지 않는다).
function bumpCommitMessageOf(app: string, tag: string): string {
  return `chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)`;
}
const BUMP_COMMIT_MESSAGE = bumpCommitMessageOf(APP, TAG);
// 형제 브랜치의 기대 메시지는 **그 PR 자신의 tag**로 재계산한다(우리 tag가 아니다) — 그래야 그 head가
// "그 bump의 우리 커밋"임을 증명할 수 있다. 브랜치명 파싱만으로는 소유권의 증거가 되지 못한다.
function bumpCommitMessageFor(tag: string): string {
  return bumpCommitMessageOf(APP, tag);
}
const WRITER_BOT_NAME = `${normalizeLogin(args.writer)}[bot]`;
const WRITER_BOT_EMAIL_RE = new RegExp(`^\\d+\\+${escapeRe(WRITER_BOT_NAME)}@users\\.noreply\\.github\\.com$`);

function isWriterIdent(id: { name: string; email: string }): boolean {
  return id.name === WRITER_BOT_NAME && WRITER_BOT_EMAIL_RE.test(id.email);
}

// 이 OID의 커밋이 **우리가 만든 bump 커밋**인지 조회한다. **죽지 않는다** — 판정을 값으로 돌려준다
// (순서 규칙: 회수(해제)가 abort보다 먼저다. 여기서 죽으면 낡은 인가를 회수할 기회가 사라진다).
// 증명 실패의 종류(조회 장애·스키마 드리프트·OID 미발견·낯선 커밋)를 구분하지 않는다:
// **"우리 것임을 증명하지 못했다"는 하나의 사실**이고, 그 사실의 안전한 귀결은 언제나 같다
// (무장하지 않는다 / 무장돼 있으면 회수한다 / 변이하지 않는다).
// `expectMessage`는 기본이 이번 bump의 메시지지만, superseded 형제나 reconcile 주체를 검증할 땐
// **그 브랜치 자신의 (app, tag)로 재계산한 메시지**를 넘긴다(같은 함수, 다른 기대값).
type Proof = { ok: true } | { ok: false; why: string };
function proveOurCommit(oid: string, what: string, expectMessage: string = BUMP_COMMIT_MESSAGE): Proof {
  const no = (why: string): Proof => ({ ok: false, why: `${what}(${oid}) — ${why}` });

  const r = runSoft("gh", [
    "api", "graphql",
    "-f", `query=${COMMIT_QUERY}`,
    "-F", "owner={owner}", "-F", "repo={repo}", "-F", `oid=${oid}`,
  ]);
  if (r.failure !== null) return no(`gh api graphql (commit) ${r.failure} — 무엇인지 모르는 커밋은 우리 것이 아니다`);

  let parsed: any;
  try {
    parsed = JSON.parse(r.stdout);
  } catch (e) {
    return no(`커밋 조회 JSON 파싱 실패: ${(e as Error).message}`);
  }
  if (parsed?.errors !== undefined) return no(`커밋 조회 GraphQL 오류: ${JSON.stringify(parsed.errors)}`);
  const c = parsed?.data?.repository?.object;
  // object가 null이면 그 OID를 못 찾은 것이다(다른 레포의 커밋·GC됨·오타) → 우리 것이라는 증명이 없다.
  if (c === null || typeof c !== "object") return no("커밋을 찾을 수 없다(GC됨·다른 레포·스키마 드리프트)");
  // 스키마 드리프트(필드 누락·Commit이 아님)도 "우리 것"의 증명이 아니다.
  if (typeof c.oid !== "string" || c.oid !== oid) return no(`커밋 조회 결과의 oid 불일치(받음 ${String(c.oid)})`);
  if (typeof c.message !== "string") return no("커밋 message 문자열 아님(Commit이 아니거나 스키마 드리프트)");
  for (const k of ["author", "committer"] as const) {
    const v = c[k];
    if (v === null || typeof v !== "object" || typeof v.name !== "string" || typeof v.email !== "string") {
      return no(`커밋 ${k}.name/email 문자열 아님 — 소유권을 증명할 수 없다`);
    }
  }

  const ident = isWriterIdent(c.author) && isWriterIdent(c.committer);
  const msg = c.message.trim() === expectMessage;
  if (ident && msg) return { ok: true };
  return no(
    "**우리 bump 커밋이 아니다**.\n"
    + `  관측: author=${c.author.name} <${c.author.email}> / committer=${c.committer.name} <${c.committer.email}>\n`
    + `        message=${JSON.stringify(c.message.trim())}\n`
    + `  기대: author·committer=${WRITER_BOT_NAME} <<id>+${WRITER_BOT_NAME}@users.noreply.github.com>\n`
    + `        message=${JSON.stringify(expectMessage)}\n`
    + "  누군가 이 ref에 자기 커밋을 올렸다(또는 우리 것이 아닌 브랜치다).",
  );
}

// ── 조회 = **상한 없는 완전 열거**(GraphQL connection, 끝까지 페이지네이션) ──────────────────────
// `gh pr list`는 쓰지 않는다. 그건 `--limit`으로 **경계된** 질의라, 부재를 증명하려면 "상한에 닿으면
// fail-closed"밖에 방법이 없는데 — 결정적 브랜치명은 **공개**고 같은 head의 **포크 PR은 공격자가 무한정
// 열 수 있다** → 페이지를 채우는 것만으로 **모든 폴링이 화해 전에 죽는다**(배포 정지 원시 무기).
// 상한을 없애면 그 무기가 사라진다: 포크가 몇 건이든 전부 열거하고, 그 사이에서 우리 PR을 정확히 찾는다.
//
// 질의는 `pageInfo{hasNextPage,endCursor}` + `$endCursor: String` 변수를 갖는 **connection**이고,
// **페이지는 우리가 따라간다**(fetchConnection — R-33: `--paginate --slurp`는 전 페이지를 한 subprocess
// 캡처에 담아 spawnSync의 1 MiB 버퍼에서 죽는다 = 포크 포화가 다시 배포 정지 무기가 된다).
// hasNextPage가 false가 될 때까지 `endCursor`를 이어 간다 — 상한은 **어디에도 없다**.
// ⚠️ 검색 API는 금지다 — `gh pr list --author`는 내부적으로 search(...)로 갈아타는데(GH_DEBUG=api 실측),
//    검색 인덱스는 **결과적 일관성**이라 직전 주기가 만든 PR이 안 잡히면 **거짓 부재**가 난다(고아 오인 →
//    force-push). connection 질의는 primary datastore = **강한 일관성**이다.
//
// ★ base를 **서버 필터로 걸지 않는다**(중요) — head로만 열거하고 base는 **클라이언트에서** 본다.
//   식별(우리 PR인가?)은 (head, base) 쌍이지만, **소유권**(이 브랜치를 force-push해도 되는가?)은 base와
//   무관하게 "이 head에 열린 동일-레포 PR이 하나라도 있는가"로 정해진다. base로 서버 필터를 걸면 다른 base를
//   향한 동일-레포 PR이 **보이지 않게 되고**, 그러면 파괴 가드(r3)가 눈이 멀어 그 PR의 브랜치를 force-push로
//   덮어쓴다. 그래서 열거는 head 전체, 판정은 base까지 본다.
//
// ★★ 사람의 흔적(human trace)도 **본 질의의 사실**이다(H-4) ────────────────────────────────────
// rebuild는 force-push다. 그런데 strict 보호 main에서는 **main에 머지가 일어날 때마다** 열린 PR이 전부
// BEHIND가 된다 → 승인 레인(propose-pr)의 PR은 사람이 리뷰하는 동안 **10분마다** BEHIND가 되고, 가드가
// 없으면 그때마다 force-push당한다: **stale review로 승인이 취소되고**, 인라인 리뷰 코멘트가 outdated로
// 접히고, required 체크가 처음부터 다시 돈다. 그건 리뷰를 사실상 불가능하게 만든다.
// → 그래서 close 스윕이 쓰던 것과 **같은 흔적 신호**를 rebuild 경로에도 건다(아래 humanTouchOf).
// ⚠️ 이 필드들은 판정의 **완화** 방향으로만 쓰인다(있으면 force-push를 **하지 않는다**) → 파싱은
//    fail-closed가 아니라 humanTouchOf의 관용구를 따른다: **관측할 수 없으면 "흔적 있음"으로 읽는다**.
//    필드 드리프트의 안전한 귀결은 "force-push하지 않는다"이지 "배포 파이프라인이 죽는다"가 아니다.
// ⚠️⚠️ 흔적 조회는 **잘려선 안 된다**(R-28) — `comments`/`labels`는 nodes를 `first:N`으로만 가져오는
//    **경계된 읽기**다. nodes만 보고 "사람 흔적 없음"이라고 결론 내리면, N+1번째에 있는 사람의 코멘트나
//    `hold` 라벨이 **거짓 부재**가 되고 → 실행기가 **리뷰된 PR을 force-push**하거나 **사람이 지킨 PR을 닫는다**.
//    이건 PR 열거에서 이미 고친 그 함정이다(경계된 읽기는 부재를 날조한다 — R-13/R-17). 그래서 두 연결에
//    **`totalCount`를 함께 조회**해 잘림을 **사실로 관측**하고, 잘렸거나 관측할 수 없으면 "흔적 있음"으로 읽는다
//    (⇒ 절대 닫지 않고, 절대 force-push하지 않는다 — 모듈의 기존 관용구와 같은 방향).
const PR_QUERY = `query($owner:String!,$repo:String!,$ref:String!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    ref(qualifiedName:$ref){
      target{ oid }
      associatedPullRequests(states:OPEN, first:100, after:$endCursor){
        pageInfo{ hasNextPage endCursor }
        nodes{
          number isCrossRepository mergeStateStatus headRefOid baseRefName createdAt isDraft
          author{ login __typename }
          autoMergeRequest{ enabledAt }
          labels(first:50){ totalCount nodes{ name } }
          assignees{ totalCount }
          reviewRequests{ totalCount }
          reviews{ totalCount }
          comments(first:100){ totalCount nodes{ author{ __typename } } }
          timelineItems(itemTypes:[REOPENED_EVENT], last:1){ totalCount }
        }
      }
    }
  }
}`;

// GraphQL 노드의 원시 스키마(라이브 실측 — 이 레포의 실제 bump PR):
//   {"number":350,"isCrossRepository":false,"mergeStateStatus":"DIRTY","headRefOid":"5bb77fc…",
//    "baseRefName":"main","author":{"login":"ukyi-homelab-writer","__typename":"Bot"},
//    "autoMergeRequest":{"enabledAt":"2026-07-13T06:35:20Z"}}
// ★★ author 표기는 **표면마다 다르다**(라이브 확인) — 여기서 틀리면 신뢰 판정이 조용히 죽는다:
//     gh pr list  → "app/ukyi-homelab-writer"     (is_bot: true)
//     REST        → "ukyi-homelab-writer[bot]"
//     GraphQL     → "ukyi-homelab-writer"          (__typename: "Bot")   ← 지금 쓰는 표면
//   normalizeLogin이 셋을 모두 같은 slug로 접는다.
// ★★ __typename도 **신뢰 조건**이다: GraphQL은 App 봇을 `Bot`으로, 사람을 `User`로 준다. login만 보면
//   `ukyi-homelab-writer`라는 **사람 계정**(봇 계정은 `<slug>[bot]`이므로 이 이름은 사람이 가질 수 있다)이
//   writer로 오인될 수 있다 → 타입까지 봐야 신뢰 경계가 닫힌다.
// autoMergeRequest: 무장=객체({enabledAt}) / 미무장=null — 유일한 신호는 **null 여부**다.
// createdAt은 **superseded 판정(close·회수)의 순서 근거**로만 쓴다(T1 vs T2 사이엔 git 순서가 없다 →
// PR 나이가 전순서를 갖는 유일한 관측 사실이다). 그래서 여기선 **선택 필드**다: 없거나 형식이 깨지면
// null로 두고 그 run은 아무것도 닫지 않는다(파괴는 증거가 완전할 때만).
// 판정·무장·해제는 이 값을 전혀 보지 않으므로 여기서 fail-closed로 죽이면 배포만 멈춘다.
// humanTouch: 사람이 이 PR을 만졌는가(있으면 사유 문자열). **관측 불가 = 흔적 있음**(H-4) —
// rebuild(force-push)를 막는 방향으로만 쓰이므로 fail-closed의 안전 방향이 여기선 "밀지 않는다"다.
// mergeStateStatus: **본 질의에만** 있다(판정 전용) — 형제/reconcile 질의는 판정 대상이 아니라 회수·close
// 대상이라 이 필드를 묻지 않는다. 그래서 타입은 nullable이고, **요구 여부는 파서의 인자**다(아래).
type ObservedPr = {
  number: number; isCrossRepository: boolean; mergeStateStatus: string | null;
  headRefOid: string; baseRefName: string; createdAt: string | null;
  author: { login: string; type: string } | null;
  autoMerge: boolean;
  humanTouch: string | null;
};

// ══ PR 관측은 **하나의 파서, 하나의 신뢰 술어**다(structure r10 R-34) ═══════════════════════════
// 예전엔 **두 개**였다 — 본 질의용(parsePrs)과 형제/reconcile용(parseSiblingPrs) — 그리고 둘이 `author`를
// **다르게** 읽었다:
//     본 파서 : `author` 키 누락 = 스키마 실패 → fail-closed (옳다)
//     형제 파서: `author` 키 누락 = `null`(계정 삭제)로 접음 → isTrustedSibling이 false → **그 PR이
//                회수 대상 목록에서 조용히 사라진다** → 무장된 writer PR이 reconcile에서 **증발**하고
//                run은 exit 0. `revocationBlind`엔 닿지도 않는다.
// 그건 방금 세운 V-2 계약("회수 대상을 가릴 수 있는 관측 실패는 그 자체가 회수 실패다")과 **정면 충돌**이다.
// 파서가 둘이면 신뢰 경계도 둘이 되고, 둘 중 **느슨한 쪽**이 보안 속성을 정한다.
// → 그래서 관측은 **하나의 계약**이다:
//   · `author` **키는 반드시 있어야 한다**. 명시적 `null`만이 정당한 상태다(계정 삭제 — 신뢰하지 않을 뿐
//     fail-closed는 아니다: 삭제된 계정 하나로 배포가 영구 억제되면 안 된다).
//   · **키 부재·형식 위반은 관측 실패다** — "신뢰하지 않는다"로 조용히 접지 않는다. 실패의 처리는
//     경로가 정한다: 본 질의 = fail-closed(exit 1) / 형제·reconcile = revocationBlind(집계 → 비-0 종료).
//     **두 경로 다 시끄럽다.** 갈리는 건 "즉시 죽는가 / 나머지를 다 처리하고 죽는가"뿐이다.
type ParseResult<T> = { ok: true; value: T } | { ok: false; why: string };
const parseFail = (why: string): { ok: false; why: string } => ({ ok: false, why });

// 노드 하나 → 관측 사실. `requireMergeState`는 **본 질의 전용**(그 질의만 mergeStateStatus를 묻는다).
function parsePrNode(pr: any, at: string, requireMergeState: boolean): ParseResult<ObservedPr> {
  if (pr === null || typeof pr !== "object") return parseFail(`${at} 객체가 아님`);
  if (!Number.isInteger(pr.number)) return parseFail(`${at}.number 정수 아님`);
  if (typeof pr.isCrossRepository !== "boolean") return parseFail(`${at}.isCrossRepository 불리언 아님`);
  if (requireMergeState && (typeof pr.mergeStateStatus !== "string" || pr.mergeStateStatus === "")) {
    return parseFail(`${at}.mergeStateStatus 문자열 아님`);
  }
  if (typeof pr.headRefOid !== "string" || !OID_RE.test(pr.headRefOid)) {
    return parseFail(`${at}.headRefOid가 40-hex OID 아님(lease 기대값 필수)`);
  }
  // base는 **식별**의 절반이다(head, base) — 없으면 우리 PR인지 판정할 수 없다.
  if (typeof pr.baseRefName !== "string" || pr.baseRefName === "") {
    return parseFail(`${at}.baseRefName 문자열 아님(식별은 (head, base) 쌍이다)`);
  }
  // ★ author는 **키가 있어야 한다**(R-34). 없으면 "이 PR이 우리 것인지"를 **관측하지 못한 것**이고,
  //   그건 "우리 것이 아니다"와 다르다 — 후자로 접으면 무장된 writer PR이 회수 목록에서 증발한다.
  if (!("author" in pr)) {
    return parseFail(
      `${at}.author 필드 없음 — 작성자를 관측할 수 없다(스키마 드리프트·권한). `
      + "**'우리 것이 아니다'로 접지 않는다**: 그러면 무장된 writer PR이 회수 대상에서 조용히 사라진다(R-34)",
    );
  }
  // 명시적 null만이 정당한 "관측했으나 작성자가 없다" = 계정 삭제다 → 신뢰하지 않을 뿐 실패는 아니다.
  let author: { login: string; type: string } | null = null;
  if (pr.author !== null) {
    if (typeof pr.author !== "object") return parseFail(`${at}.author가 객체도 null도 아님`);
    if (typeof pr.author.login !== "string" || pr.author.login === "") return parseFail(`${at}.author.login 문자열 아님`);
    // __typename은 신뢰 조건이다(Bot vs User) — 없으면 사람이 writer slug를 사칭할 수 있다.
    if (typeof pr.author.__typename !== "string" || pr.author.__typename === "") {
      return parseFail(`${at}.author.__typename 없음 — App 봇(Bot)과 사람(User)을 구분할 수 없다(사칭 가드)`);
    }
    author = { login: pr.author.login, type: pr.author.__typename };
  }
  if (!("autoMergeRequest" in pr)) {
    return parseFail(`${at}.autoMergeRequest 필드 없음 — 무장 여부를 모르면 재무장/해제를 판정할 수 없다(필드명 드리프트)`);
  }
  const amr = pr.autoMergeRequest;
  if (amr !== null && (typeof amr !== "object" || Array.isArray(amr))) {
    return parseFail(`${at}.autoMergeRequest가 null도 객체도 아님(무장=객체 / 미무장=null)`);
  }
  return {
    ok: true,
    value: {
      number: pr.number,
      isCrossRepository: pr.isCrossRepository,
      mergeStateStatus: typeof pr.mergeStateStatus === "string" && pr.mergeStateStatus !== "" ? pr.mergeStateStatus : null,
      headRefOid: pr.headRefOid,
      baseRefName: pr.baseRefName,
      // 선택 필드(위 타입 주석 참고) — 없으면 null → 그 run은 아무것도 닫지 않는다.
      createdAt: typeof pr.createdAt === "string" && pr.createdAt !== "" ? pr.createdAt : null,
      author,
      autoMerge: amr !== null,
      // H-4: 사람의 흔적. **여기서 fail-closed하지 않는다** — 관측 실패는 humanTouchOf가 "흔적 있음"으로
      // 접어 주고(= force-push 금지), 그게 이 신호의 안전한 귀결이다(배포 파이프라인을 죽이지 않는다).
      humanTouch: humanTouchOf(pr),
    },
  };
}

// ══ PR 관측은 **스트리밍 fold**다 — 페이지를 받는 즉시 접고, 원본을 버린다(structure r11 R-36) ═══════
// R-33에서 subprocess **캡처**는 페이지로 경계지었지만, 조회는 여전히 **모든 페이지를 pages[]에** 모아
// 두고 열거가 끝난 **뒤에야** 그것을 훑어 **모든 노드를 out[]에** 쌓았다(옛 parsePrPages). 그러면 같은
// head의 포크 PR이 **부모 프로세스의 Bun 힙과 stdout(로그)을 노드 수에 선형으로** 키운다 → executor가
// 죽거나 워크플로 로그가 고갈될 때까지 간다. **억제 무기가 한 계층 위(부모 프로세스)로 올라갔을 뿐이다.**
// 승인된 설계는 "page → reduce → cursor"인데 구현은 "page → 전량 보관 → 전량 파싱·출력"이었다.
// → 이제 각 페이지를 받는 **즉시** 파싱·검증·접어서 **결정에 필요한 사실만** 남긴다(신뢰 PR 후보 +
//   **경계 있는 카운터**). **원본 페이지와 미신뢰 포크 노드는 버린다**(누적 보관 금지) → **직렬화되는 출력**
//   (`observed`와 `executed` 원장 둘 다)은 포크 수와 **무관**하다(포크는 요약 카운터로, 페이지네이션은
//   graphqlPages 정수 하나로만 관측). 힙에 남는 건 사이클 검출용 커서 집합뿐 — 그건 **페이지 수** 경계라
//   포크 수 자체와 무관하다고 넘겨짚지 않는다.
// ⚠️ 완전 열거의 증명은 여전히 **마지막 페이지의 hasNextPage === false**다(아래 foldConnection이 그 판정을
//    한 곳에 둔다). true로 끝났다면 커서를 더 못 따라간 것 → "열린 PR 없음"을 증명할 수 없다(조용한 create/adopt 금지).
// ⚠️ 관측 실패(파싱·스키마 드리프트·author 부재)는 fold 안에서도 지금 계약 그대로 전파한다:
//    본 질의 = fail-closed / 형제·reconcile = revocationBlind. 어느 페이지에서 나든 즉시 값으로 돌려세운다.

// 한 페이지의 노드 배열을 누적기 A에 접는다. 실패는 그대로 전파한다(호출부가 경로별로 처리한다).
type PageReducer<A> = (acc: A, nodes: any[], at: string) => ParseResult<A>;

// ══ 조회는 **한 페이지씩** 소비한다 — 캡처의 경계가 곧 조회의 상한이다(R-33) ═══════════════════
// 예전엔 `gh api graphql --paginate --slurp`로 **전 페이지를 한 subprocess 캡처에** 받았다. 그건 위 상한
// 없는 열거를 **spawnSync의 유한 버퍼**(실측: 기본 1 MiB)로 되묶는 것이다 — 같은 head의 포크 PR을 충분히
// 열면 응답 총량이 그 버퍼를 넘고, gh는 ENOBUFS로 **살해되고**, 그 앱의 폴링은 매 주기 죽는다.
// **GraphQL 계층에서 없앤 포크 포화 무기를 프로세스 계층에서 되살린 셈이다.**
// → 이제 페이지를 **우리가 따라간다**: 한 페이지 받고 → 줄이고 → `endCursor`로 다음 페이지. 캡처 하나는
//   언제나 **한 페이지**(first:100)라 공격자가 키울 수 없다. 열거의 완전성은 그대로다(hasNextPage=false까지).
// ⚠️ 상한(페이지 수 캡)은 **두지 않는다** — 그게 곧 되살아난 배포 정지 무기다(포크 N건이면 죽는 지점).
//    루프의 종료는 오직 `hasNextPage === false`다.
// ⚠️ 커서를 이어받지 못하는 경우(누락·빈 문자열·**전진하지 않는 커서**)엔 **루프를 멈추기만 한다** —
//    그러면 마지막 페이지가 hasNextPage=true인 채 남고, 파서의 완전성 검사가 그것을 실패로 만든다
//    (= "열거가 불완전하다"는 판정이 **한 곳에만** 산다). 무한 루프는 여기서 구조적으로 불가능하다.
// ⚠️ 커서는 `-f`(raw-field)로 넘긴다 — `-F`는 값이 숫자꼴이면 **정수로 타입 추론**해 `$endCursor:String`과
//    타입이 어긋난다(그러면 gh가 죽고, 그 실패는 곧 배포 정지다).
// ⚠️ 검색 API 금지·강한 일관성은 그대로다: 질의는 여전히 repository.pullRequests connection 하나뿐이다.
// ⚠️ 페이지를 받는 즉시 **접는다**(R-36): 원본 page·포크 노드는 이 반복이 끝나며 GC된다(pages[]·out[]
//    누적 제거) → 부모 프로세스가 **포크 노드를 노드 수만큼 쌓아두지 않는다**. 힙에 남는 상태는 사이클
//    검출용 커서 집합(seenCursors)과 카운터뿐이고 그건 페이지 수 경계다 — read-only 조회는 원장(executed)에
//    남기지 않고 graphqlPages 카운터로만 관측한다(그래서 직렬화되는 audit 출력도 포크 수에 비례하지 않는다).
// GraphQL ref 관측 — **부재/존재+OID**를 구분해 나른다(R-43). `git ls-remote`(비원자적 두 번째 읽기)와
// 교차 검증하기 위해서다: `ref === null`(부재)과 `ref 존재 + 빈 connection`이 이전엔 둘 다 "우리 것 PR 0건"으로
// 뭉개졌고, 그 위에서 ls-remote가 브랜치를 보고하면 무조건 adopt(force-push)로 갔다 — GraphQL의 stale/저하된
// 뷰가 실재하는 PR을 숨기면 그게 곧 남의 커밋 파괴·중복 create였다.
// **진짜 discriminated union**(R-44): 부재면 oid 자체가 없다(존재할 때만 oid가 의미 있다).
type RefObs = { present: false } | { present: true; oid: string };
type FoldResult<A> = { value: A; ref: RefObs };
function foldConnection<A>(
  query: string, ref: string, what: string,
  init: () => A, reduce: PageReducer<A>,
): ParseResult<FoldResult<A>> {
  let acc = init();
  const seenCursors = new Set<string>();
  let cursor: string | null = null;
  let pageIndex = 0;
  let refObs: RefObs = { present: false };
  for (;;) {
    const a = [
      "api", "graphql",
      "-f", `query=${query}`,
      "-F", "owner={owner}", "-F", "repo={repo}", "-f", `ref=${ref}`,
    ];
    // 첫 페이지는 커서를 넘기지 않는다($endCursor는 nullable → after:null = 처음부터).
    if (cursor !== null) a.push("-f", `endCursor=${cursor}`);
    // read-only 페이지 조회 — **원장에 남기지 않는다**(audit=false, R-36): 이 조회를 executed에 담으면
    // 페이지(=포크) 수에 비례해 로그·힙이 커진다. 관측은 graphqlPages(정수 하나)로만 한다.
    const r = runSoft("gh", a, false);
    graphqlPages++; // 이번 run이 접은 페이지 수(경계 있는 카운터 — 질의 문자열은 버린다).
    if (r.failure !== null) return parseFail(`${what} ${r.failure}`);
    if (r.stdout.trim() === "") return parseFail(`${what} 빈 출력(조회 실패로 본다)`);
    let page: any;
    try {
      page = JSON.parse(r.stdout);
    } catch (e) {
      return parseFail(`${what} JSON 파싱 실패: ${(e as Error).message}`);
    }
    // ── 페이지 구조 검증 → **즉시 접기**. 이 반복이 끝나면 page(포크 노드 포함)는 참조가 끊겨 버려진다.
    const at = `page[${pageIndex}]`;
    if (page === null || typeof page !== "object" || Array.isArray(page)) return parseFail(`${at} 객체가 아님`);
    if (page.errors !== undefined) return parseFail(`${at}.errors — GraphQL 오류 응답: ${JSON.stringify(page.errors)}`);
    const data = page.data;
    if (data === null || typeof data !== "object") return parseFail(`${at}.data 없음(스키마 드리프트)`);
    const repo = data.repository;
    if (repo === null || typeof repo !== "object") return parseFail(`${at}.data.repository 없음(레포 해석 실패 또는 스키마 드리프트)`);
    // ★ ref === null = **우리 브랜치가 원격에 없다** = 우리 것 PR 0건(고아/create 경로) — 조회 실패가 아니다.
    //   git ls-remote가 그 브랜치를 못 찾는 것과 정합한다: 여기서 fail-closed하면 정상 create가 막힌다.
    //   ★★ 이 null-분기가 곧 **포크 배제의 구조적 근거**다: 이 connection은 `repository(우리)`의 **우리 ref**에
    //      연결된 PR만 준다. 포크 PR의 head는 포크 레포의 ref라(우리 refs/heads/…가 아니다) 이 노드에 절대
    //      들어오지 못한다(라이브 실측: associatedPullRequests는 **head-연결**이라 base=main에도 0건). 그래서
    //      질의 작업(서브프로세스·페이지 수)이 **포크 수와 무관**하다 — 예전 pullRequests(headRefName) 이름-매치는
    //      포크가 같은 이름으로 오염시킬 수 있었다(structure r12 R-40).
    if (repo.ref === null) {
      // ⚠️ 페이지 간 일관성(R-44): 앞 페이지가 ref 존재를 봤는데 뒤 페이지가 ref:null이면 뷰가 흔들린 것이다.
      //    (정상적으로 null ref는 페이지네이션 자체가 없다 → 이건 stale/저하 신호다) → fail-closed.
      if (refObs.present) return parseFail(`${at} ref가 페이지 사이에 사라졌다(앞: 존재 ${refObs.oid} → 지금: null) — 뷰 불안정, 교차 검증 불가`);
      return { ok: true, value: { value: acc, ref: { present: false } } };
    }
    if (typeof repo.ref !== "object" || Array.isArray(repo.ref)) return parseFail(`${at}.data.repository.ref가 객체도 null도 아님`);
    // ref 존재 → target.oid를 관측한다(R-43). 브랜치의 tip OID다 — ls-remote OID와 교차 검증한다.
    // 부재(ref:null)와 "존재 + 빈 connection"을 여기서 갈라 낸다: 전자는 present:false, 후자는 present:true.
    const tgt = repo.ref.target;
    if (tgt === null || typeof tgt !== "object" || typeof tgt.oid !== "string" || !OID_RE.test(tgt.oid)) {
      return parseFail(`${at}.data.repository.ref.target.oid 형식 위반 — 브랜치 tip을 관측할 수 없다(교차 검증 불가)`);
    }
    // ⚠️ 페이지 간 OID 변화 거부(R-44): 열거 도중 브랜치 tip이 바뀌면 여러 tip에 걸친 뷰를 섞어 읽는 것이다.
    if (refObs.present && refObs.oid !== tgt.oid) {
      return parseFail(`${at} ref tip이 페이지 사이에 바뀌었다(${refObs.oid} → ${tgt.oid}) — 열거가 원자적이지 않다, fail-closed`);
    }
    refObs = { present: true, oid: tgt.oid };
    const conn = repo.ref.associatedPullRequests;
    if (conn === null || typeof conn !== "object") {
      return parseFail(`${at}.data.repository.ref.associatedPullRequests 없음(스키마 드리프트)`);
    }
    const info = conn.pageInfo;
    if (info === null || typeof info !== "object" || typeof info.hasNextPage !== "boolean") {
      return parseFail(`${at}.pageInfo.hasNextPage 불리언 아님 — 완전 열거를 증명할 수 없다`);
    }
    if (!Array.isArray(conn.nodes)) return parseFail(`${at}.nodes가 배열이 아님`);
    const stepped = reduce(acc, conn.nodes, at);
    if (!stepped.ok) return stepped;
    acc = stepped.value;

    // ── 완전성 판정은 **한 곳에만** 산다: 더 못 가면 마지막 페이지의 hasNextPage로 결정한다.
    // 상한(페이지 캡)은 **두지 않는다** — 그게 곧 되살아난 배포 정지 무기다. 종료는 오직 hasNextPage === false다.
    if (info.hasNextPage !== true) return { ok: true, value: { value: acc, ref: refObs } }; // 완전 열거 증명(hasNextPage=false)
    const next = info.endCursor;
    // 커서를 이어받지 못하면(누락·빈 문자열·**전진하지 않는 커서**) 마지막 페이지가 hasNextPage=true인 채
    // 끝난 것이다 = 열거 불완전 → fail-closed. 무한 루프는 여기서 구조적으로 불가능하다.
    if (typeof next !== "string" || next === "" || seenCursors.has(next)) {
      return parseFail(
        "마지막 페이지가 hasNextPage=true다 — 페이지네이션이 끝까지 가지 못했다"
        + `(endCursor를 이어받지 못했다: ${JSON.stringify(next ?? null)}). `
        + "열거가 불완전하면 '열린 PR 없음'을 증명할 수 없다",
      );
    }
    seenCursors.add(next);
    cursor = next;
    pageIndex++;
  }
}

// ── 관측 사실의 접이식 누적기 — **포크 노드는 카운터로만**(R-36) ──────────────────────────────────
// 동일-레포 PR(신뢰·비신뢰)은 **쓰기 권한이 필요**해 포화될 수 없다 → 배열로 남겨도 경계 있다.
// 포크(cross-repo)는 공격자가 무한정 열 수 있다 → **노드는 버리고 수만 센다**(포화 벡터를 힙·로그에서 없앤다).
type PrScan = {
  trusted: ObservedPr[];            // 동일-레포 + writer Bot + 같은 base(식별·판정·무장 대상 — 정상 ≤ 1)
  untrustedSameRepo: ObservedPr[];  // 동일-레포 비신뢰(사람·다른 봇·다른 base) — 파괴 가드의 입력
  totalOpen: number;                // 열린 PR 총수(포크 포함) — 카운터
  crossRepo: number;                // 포크(cross-repo) 수 — 노드는 버렸다
};
const newScan = (): PrScan => ({ trusted: [], untrustedSameRepo: [], totalOpen: 0, crossRepo: 0 });
// requireMergeState는 **본 질의 전용**(그 질의만 mergeStateStatus를 묻는다) → 파서 인자로 넘긴다.
function scanReducer(requireMergeState: boolean): PageReducer<PrScan> {
  return (acc, nodes, at) => {
    for (let i = 0; i < nodes.length; i++) {
      const parsed = parsePrNode(nodes[i], `${at}.nodes[${i}]`, requireMergeState);
      if (!parsed.ok) return parsed; // 스키마 드리프트·author 부재 = 관측 실패(호출부가 fail-closed / revocationBlind)
      const pr = parsed.value;
      acc.totalOpen++;
      // ★ 포크 노드는 접는 즉시 **버린다** — 포화 벡터가 힙·로그를 노드 수에 비례해 키우지 못하게(R-36).
      if (pr.isCrossRepository) { acc.crossRepo++; continue; }
      if (isTrustedPr(pr, args.writer, args.base)) acc.trusted.push(pr);
      else acc.untrustedSameRepo.push(pr);
    }
    return { ok: true, value: acc };
  };
}

// `git ls-remote --heads origin <branch>` → "<40-hex>\trefs/heads/<branch>"(없으면 빈 출력).
// 고아 브랜치(= 열린 PR 없이 남은 원격 브랜치)의 OID가 adopt 경로의 lease 기대값이다(R-4).
function parseLsRemote(raw: string): { oid: string } | null {
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (t === "") continue;
    const parts = t.split(/\s+/);
    if (parts.length < 2) inputError(`git ls-remote 출력 파싱 실패: '${t}'`);
    const oid = parts[0]!;
    const refName = parts[1]!;
    if (!OID_RE.test(oid)) inputError(`git ls-remote OID 형식 위반: '${oid}'`);
    if (refName === ref) return { oid };
  }
  return null;
}

// `gh pr create`는 성공 시 **만든 PR의 URL**을 stdout에 낸다(라이브: "https://github.com/<o>/<r>/pull/<n>").
// 그 번호가 create/adopt 경로의 **인증된 셀렉터**다 — 우리가 방금 만든 PR이라는 사실을 gh가 직접 알려준 값이다.
// 브랜치명으로 되짚는 재조회는 하지 않는다: 동명 포크 PR로 해석될 수 있는 바로 그 모호성으로 되돌아간다.
const PR_URL_RE = /^https?:\/\/\S+\/pull\/(\d+)$/;
function createPr(): number {
  const out = run("gh", [
    "pr", "create", "--base", args.base, "--head", branch,
    "--title", args.title!, "--body", args.body!,
  ], "gh pr create");
  process.stderr.write(out); // 이 도구의 stdout은 결과 JSON 전용
  const nums = new Set(
    out.split("\n")
      .map((l) => PR_URL_RE.exec(l.trim()))
      .filter((m): m is RegExpExecArray => m !== null)
      .map((m) => Number(m[1])),
  );
  // 파싱 실패(출력 형식 드리프트·경고 혼입·URL 여러 개)는 **fail-closed**다 — 브랜치명 폴백 금지.
  // 여기서 브랜치로 폴백하면 무장이 동명 포크 PR을 지목할 수 있다(= 이 가드가 막으려는 결함 그 자체).
  if (nums.size !== 1) {
    execError(
      `gh pr create 출력에서 PR 번호를 확정할 수 없다(URL ${nums.size}개) — 무장 대상을 모른 채 `
      + `브랜치명으로 폴백하지 않는다(동명 포크 PR 오조준). 출력: ${JSON.stringify(out)}`,
    );
  }
  return [...nums][0]!;
}

// writer App의 login 표기는 **표면마다 다르다**(전부 라이브 확인) → 셋을 같은 slug로 접는다:
//   gh pr list → "app/ukyi-homelab-writer"  /  REST → "ukyi-homelab-writer[bot]"
//   GraphQL    → "ukyi-homelab-writer"      (__typename:"Bot" — 지금 쓰는 표면)
// 한 표기만 인식하면 신뢰 판정이 조용히 0이 되어 중복 PR이 되살아난다(과거에 실제로 밟은 함정).
function normalizeLogin(login: string): string {
  return login.replace(/^app\//, "").replace(/\[bot\]$/, "").toLowerCase();
}

// 신뢰하는 제안 = **(head, base) 쌍이 우리 것** + 동일-레포(포크 아님) + writer **App 봇** 작성자.
// 그 외(포크·타인·다른 base)는 사실로만 관측하고 판정 근거로 쓰지 않는다.
//   · base: 식별은 head만으로 부족하다 — 같은 head가 **다른 base**를 향한 PR은 **우리 PR이 아니다**.
//           그걸 우리 것으로 착각하면 skip/rebuild/무장/해제를 엉뚱한 PR에 하고, 정작 요청된 base의
//           PR은 영영 안 생긴다.
//   · type: GraphQL은 App 봇을 `Bot`, 사람을 `User`로 준다. 봇 계정의 실제 login은 `<slug>[bot]`이므로
//           **`<slug>` 그대로의 사람 계정이 존재할 수 있다** → login만 보면 사칭이 가능하다. 타입까지 본다.
//
// ★ 신뢰 술어는 **하나뿐이다**(R-34). 예전엔 본 경로와 형제/reconcile 경로가 **각자의 술어**를 들고 있었고
//   (isTrusted / isTrustedSibling), 그 둘이 같은 조건을 두 번 적어 두는 한 언젠가 갈라진다 — 실제로
//   갈라진 건 그 **입력**(파서)이었다: 한쪽은 author 부재를 실패로, 다른 쪽은 `null`로 읽었다 → 같은
//   술어 조건(`author === null → false`)이 한쪽에선 **회수 대상을 지우는** 필터가 됐다.
//   조건은 그대로 두고(동일-레포 · Bot · 정규화된 writer login · 같은 base) **하나로 합친다**.
// ⚠️ 이 술어는 `author === null`(계정 삭제)을 "신뢰하지 않음"으로 접는다 — 그건 **관측된 사실**이라
//    정당하다. 관측 **실패**(author 키 부재)는 여기 오지 못한다: 파서가 먼저 실패로 돌려세운다.
function isTrustedPr(pr: ObservedPr, writer: string, base: string): boolean {
  if (pr.isCrossRepository) return false;
  if (pr.baseRefName !== base) return false;
  if (pr.author === null) return false;
  if (pr.author.type !== "Bot") return false;
  return normalizeLogin(pr.author.login) === normalizeLogin(writer);
}

// ══ superseded 형제(같은 앱, **다른 tag**) — 실행기는 `bump-poll/<app>-*` **네임스페이스 전체**를 소유한다 ══
//
// ── 열거: **우리 레포의 ref만** 본다(git ls-remote) ─────────────────────────────────────────────
// 이 네임스페이스는 `contents:write` 없이는 부풀릴 수 없다 → **포크 포화가 이 경로를 공격할 수 없다**
// (R-13/R-17의 반복 방지). 그리고 GitHub은 head 브랜치가 지워지면 그 PR을 닫으므로,
// "열린 **동일-레포** PR이 있다" ⟹ "그 ref가 우리 레포에 있다" — 이 열거는 **우리가 만질 수 있는 집합에
// 대해 완전**하다. 포크 PR의 head는 포크 레포에 있어 안 잡힌다 — 정확히 원하는 바다(포크는 건드리지 않는다).
// ⚠️ ls-remote에 **패턴을 넘기지 않는다**: 패턴 매칭 의미(fnmatch/tail-match)에 열거 완전성을 걸면
//    **과소 열거 = 해제 누락**이 되고, 그건 곧 R-25(낡은 인가 생존)의 재발이다. 전부 받아 클라이언트에서 자른다.
type SiblingRef = { branch: string; tag: string; oid: string };

// ── 네임스페이스 이름 파서 — `bump-poll/<app>-<tag>` ⇄ (app, tag) ───────────────────────────────
// ★ 이 파서가 **reconcile 패스의 주체 목록**을 만든다(R-27): 대상은 플래너의 plan.json이 아니라
//   **원격 ref 자체**이고, `<app>`은 브랜치명에서 유도한다. 그래서 플래너가 죽어도, reader 토큰이 죽어도,
//   어떤 앱이 플래너 출력에서 빠져도 그 앱의 낡은 무장은 **반드시 방문된다**.
// ⚠️ 분해는 **모호하지 않다**: TAG_RE는 `sha-` 뒤에 **순수 hex**만 허용하므로, `-sha-`가 여러 번 나와도
//    꼬리가 TAG_RE에 걸리는 분기점은 **마지막 것 하나뿐**이다(앞에서 자르면 꼬리에 `-`가 섞여 반드시 실패).
//    그래서 `x-sha-abc1234`처럼 앱 이름이 tag 모양을 품어도 정확히 갈린다(APP_RE가 그런 이름을 허용한다).
const NS_PREFIX = "bump-poll/";
function parseNsBranch(b: string): { app: string; tag: string } | null {
  if (!b.startsWith(NS_PREFIX)) return null;
  const rest = b.slice(NS_PREFIX.length);
  const cut = rest.lastIndexOf("-sha-");
  if (cut <= 0) return null;                 // 접두 뒤에 앱 이름이 없다(또는 `-sha-`가 없다)
  const app = rest.slice(0, cut);
  const tag = rest.slice(cut + 1);
  if (!APP_RE.test(app)) return null;
  if (!TAG_RE.test(tag)) return null;        // 앵커 완전일치 — 아니면 이 브랜치는 우리 형식이 아니다
  return { app, tag };
}

// `bump-poll/*` 네임스페이스의 **전체** 열거. app/tag는 파싱 실패 시 null이다(그 사실도 대상이다 —
// reconcile은 "앱을 모르는 브랜치"에서도 인가를 회수한다: 인가를 **증명할 수 없으면** 거둔다).
type NsRef = { branch: string; app: string | null; tag: string | null; oid: string };
function enumerateNsRefs(): { ok: true; refs: NsRef[] } | { ok: false; why: string } {
  const r = runSoft("git", ["ls-remote", "--heads", args.remote]);
  if (r.failure !== null) return { ok: false, why: `git ls-remote(네임스페이스 열거) ${r.failure}` };
  const refs: NsRef[] = [];
  for (const line of r.stdout.split("\n")) {
    const t = line.trim();
    if (t === "") continue;
    const parts = t.split(/\s+/);
    if (parts.length < 2) return { ok: false, why: `git ls-remote 출력 파싱 실패: '${t}'` };
    const oid = parts[0]!;
    const refName = parts[1]!;
    if (!OID_RE.test(oid)) return { ok: false, why: `git ls-remote OID 형식 위반: '${oid}'` };
    if (!refName.startsWith("refs/heads/")) continue;
    const b = refName.slice("refs/heads/".length);
    if (!b.startsWith(NS_PREFIX)) continue;   // 다른 접두(bump/…·create-app/…)는 이 실행기의 것이 아니다
    const parsed = parseNsBranch(b);
    refs.push({ branch: b, app: parsed?.app ?? null, tag: parsed?.tag ?? null, oid });
  }
  return { ok: true, refs };
}

// 형제(같은 앱, **다른 tag**) — 주 경로 전용. 이름 경계는 위 파서가 강제한다(접두 + APP_RE + TAG_RE 완전일치).
function enumerateSiblingRefs(): { ok: true; refs: SiblingRef[] } | { ok: false; why: string } {
  const all = enumerateNsRefs();
  if (!all.ok) return all;
  const refs: SiblingRef[] = [];
  for (const r of all.refs) {
    if (r.app === null || r.tag === null) continue; // 파싱 불가 = 이 앱의 형제라고 말할 수 없다
    if (r.branch === branch) continue;              // 자기 자신은 형제가 아니다
    if (r.app !== APP) continue;                    // 다른 앱은 대상 밖(주 경로는 app-스코프다)
    if (r.tag === TAG) continue;                    // (방어) 이번 후보는 형제가 아니다
    refs.push({ branch: r.branch, tag: r.tag, oid: r.oid });
  }
  return { ok: true, refs };
}

// ── 형제 ref → 그 head의 열린 PR. 조회는 본 질의와 같은 **강한 일관성 + 상한 없는 완전 열거**다.
// close 증거에 필요한 사실이 더 붙는다: createdAt(순서) · isDraft/reviews/comments/reviewRequests/
// assignees/labels(**사람의 흔적**). 본 질의(PR_QUERY)를 넓히지 않고 **따로** 둔다 — 본 판정 경로의
// fail-closed 계약(필드 드리프트 = 죽는다)에 파괴 전용 필드를 끌어들이면, 그 필드 하나가 사라질 때
// **배포가 멈춘다**(파괴를 못 하는 게 아니라). 스윕의 드리프트는 "닫지 않는다"로 끝나야 한다.
const SIBLING_PR_QUERY = `query($owner:String!,$repo:String!,$ref:String!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    ref(qualifiedName:$ref){
      target{ oid }
      associatedPullRequests(states:OPEN, first:100, after:$endCursor){
        pageInfo{ hasNextPage endCursor }
        nodes{
          number isCrossRepository isDraft createdAt headRefOid baseRefName
          author{ login __typename }
          autoMergeRequest{ enabledAt }
          labels(first:50){ totalCount nodes{ name } }
          assignees{ totalCount }
          reviewRequests{ totalCount }
          reviews{ totalCount }
          comments(first:100){ totalCount nodes{ author{ __typename } } }
          timelineItems(itemTypes:[REOPENED_EVENT], last:1){ totalCount }
        }
      }
    }
  }
}`;

function totalCountOf(v: any): number | null {
  if (v === null || typeof v !== "object" || !Number.isInteger(v.totalCount)) return null;
  return v.totalCount as number;
}

// ── **경계된 읽기는 부재를 날조한다**(R-28) — 연결은 잘림까지 함께 읽는다 ────────────────────────
// `comments(first:100)` / `labels(first:50)`은 **상한 있는** 조회다. nodes만 세고 "사람 흔적 0"이라고
// 결론 내리면, 101번째 코멘트나 51번째 라벨에 있는 사람의 흔적(`hold` 라벨·리뷰 코멘트)이 **보이지 않는
// 것이 아니라 없는 것**으로 읽힌다 → 실행기가 그 PR을 **force-push**하거나 **닫는다**. 우리는 PR 열거에서
// 정확히 이 함정을 이미 고쳤다(상한 → 완전 페이지네이션). 흔적 조회는 그때 같이 고쳐지지 않았다.
// 다만 **중첩 연결은 따라가지 않는다**(fetchConnection이 미는 커서는 **바깥** pullRequests 하나뿐이다 —
// 안쪽까지 따라가면 PR 한 건이 요청 수십 개로 부풀어 폴링이 rate limit에 갇힌다) → 대신
// **`totalCount`로 잘림을 관측**한다: totalCount > 받은 nodes 수면 **잘린 것**이고, 잘린 연결은 곧
// **관측 불가**다 → 모듈의 관용구대로 "흔적 있음"으로 접는다(⇒ 닫지 않는다 · force-push하지 않는다).
// totalCount 자체가 없으면(스키마 드리프트·권한) 그것도 관측 불가 → 같은 귀결(null 반환).
function connectionOf(v: any): { nodes: any[]; truncated: boolean } | null {
  if (v === null || typeof v !== "object") return null;
  if (!Array.isArray(v.nodes)) return null;
  const total = totalCountOf(v);
  if (total === null) return null;             // 잘렸는지조차 알 수 없다 = 관측 불가
  return { nodes: v.nodes, truncated: total > v.nodes.length };
}
// 사람이 이 PR을 만졌는가. **하나라도 있으면 닫지 않는다**(그리고 H-4 이후로는 **force-push도 하지 않는다**) —
// 승인 대기 PR을 사람 발밑에서 닫는 것, 그리고 리뷰 중인 PR의 head를 갈아치우는 것이 이 스윕의 가장 아픈
// 오작동이다(리뷰 중인 PR·머지 버튼을 누르려던 순간과의 레이스 / stale review dismissal).
// 관용구: **관측할 수 없으면 "흔적 있음"으로 읽는다** — 모르는 것을 근거로 파괴하지 않는다.
//
// ★ REOPENED_EVENT(H-3) — 이게 없으면 close 스윕은 **사람의 reopen을 무한히 되닫는다**.
//   reopen은 author도, createdAt도, head도 바꾸지 않고, 그 PR의 유일한 코멘트는 **우리 봇이 남긴 close 코멘트**다
//   → 위의 어떤 신호에도 걸리지 않는다. 그래서 사람이 일부러 되살린 PR이 다음 폴링(≤10분)에 조용히 다시 닫힌다.
//   더 나쁜 건 close 코멘트가 **바로 그 reopen을 해법으로 안내**했다는 점이다(사람을 함정으로 걸어 들어가게 했다).
//   → reopen 이력을 **사실로 관측**하고, 관측되면 그 PR은 사람의 것이다(두 번 다시 닫지 않는다).
function humanTouchOf(pr: any): string | null {
  if (pr.isDraft !== false) return "draft이거나 isDraft를 관측할 수 없다"; // 우리는 draft를 만들지 않는다
  const reviews = totalCountOf(pr.reviews);
  if (reviews === null) return "reviews를 관측할 수 없다";
  if (reviews > 0) return `리뷰 ${reviews}건`;
  const rr = totalCountOf(pr.reviewRequests);
  if (rr === null) return "reviewRequests를 관측할 수 없다";
  if (rr > 0) return `리뷰어 요청 ${rr}건`;
  const asg = totalCountOf(pr.assignees);
  if (asg === null) return "assignees를 관측할 수 없다";
  if (asg > 0) return `assignee ${asg}명`;
  // ★ 코멘트는 **잘림을 먼저 본다**(R-28): 첫 페이지에 봇 코멘트만 있어도, 그 뒤에 사람의 코멘트가
  //   있으면 "흔적 없음"은 거짓이다. 잘린 연결로 파괴(close)나 force-push를 인가하지 않는다.
  const c = connectionOf(pr.comments);
  if (c === null) return "comments를 관측할 수 없다";
  if (c.truncated) return "코멘트 연결이 잘렸다(첫 페이지 밖은 관측할 수 없다 — 사람 코멘트가 그 너머에 있을 수 있다)";
  for (const n of c.nodes) {
    const t = n?.author?.__typename;
    if (typeof t !== "string") return "코멘트 작성자 타입을 관측할 수 없다";
    if (t === "User") return "사람 코멘트";
  }
  // ★ 라벨도 같다 — `hold`는 사람이 "이건 건드리지 마라"고 말하는 **명시적 탈출구**다(close 코멘트가
  //   안내하는 바로 그것). 그 라벨이 첫 페이지 밖에 있다는 이유로 무시되면 탈출구가 거짓말이 된다.
  const labels = connectionOf(pr.labels);
  if (labels === null) return "labels를 관측할 수 없다";
  if (labels.truncated) return "라벨 연결이 잘렸다(첫 페이지 밖은 관측할 수 없다 — hold 라벨이 그 너머에 있을 수 있다)";
  for (const n of labels.nodes) {
    if (n === null || typeof n !== "object" || typeof n.name !== "string") return "라벨 이름을 관측할 수 없다";
    if (HOLD_LABELS.includes(n.name.toLowerCase())) return `hold 라벨(${n.name})`;
  }
  // reopen — 마지막에 본다(가장 새로 붙은 신호). 같은 관용구: 관측 불가 ⇒ 흔적 있음.
  const reopened = totalCountOf(pr.timelineItems);
  if (reopened === null) return "reopen 이력을 관측할 수 없다";
  if (reopened > 0) return "사람이 reopen한 PR";
  return null;
}

// ── 형제/reconcile 브랜치의 열린 신뢰 PR 하나를 관측한다 — **본 경로와 같은 파서, 같은 술어**(R-34) ──
// 이 함수가 두 회수 경로(주 경로의 형제 스윕 · `--reconcile-only`)의 **유일한 관측 seam**이다.
// 실패는 **값으로** 돌려준다(죽지 않는다 — 스윕은 주 판정을 막을 수 없다). 호출부는 그 실패를
// `revocationBlind`로 접는다: **회수 대상을 가릴 수 있는 관측 실패는 그 자체가 회수 실패다**(V-2).
// ⚠️ 신뢰 PR이 2건 이상 = GitHub 계약상 불가능 → 그것도 관측 실패다(어느 것도 건드리지 않는다).
//    같은 head→base에 열린 PR은 1건뿐이므로, 2건이 보인다는 건 사실을 잘못 읽었다는 뜻이다.
// openCount = 그 head에 열린 PR 총수(신뢰 여부 무관) — "고아 ref(열린 PR 0)"와 "열린 PR은 있는데 우리
// 것이 아니다(포크·사람·다른 base)"를 보고에서 가른다. 둘 다 변이는 0이다.
type BranchObservation = { pr: ObservedPr | null; openCount: number };
// ★ expectedOid(R-44): 이 head는 `git ls-remote`(네임스페이스 열거)가 **그 OID로 존재를 보고했기에** 왔다.
//   그 OID를 씸에 넘겨, GraphQL ref의 tip과 **합의**하는지 확인한다. 예전엔 head 이름만 받아 **존재 여부만**
//   봤다 — ls-remote가 OID A를 보는데 stale GraphQL 뷰가 OID B(빈 connection)를 주면 "PR 0건"으로 접혀,
//   A에 무장된 좀비가 있어도 조용히 넘어갔다(R-43의 ref:null 케이스를 넘는 OID 불일치 케이스).
function observeBranchPr(head: string, expectedOid: string): ParseResult<BranchObservation> {
  // 스트리밍 fold(R-36): mergeStateStatus는 이 질의에 없다(회수·close엔 필요 없다) → requireMergeState=false.
  // ★ 조회는 **우리 ref에 연결된 PR**만 본다(R-40): `refs/heads/<head>`를 associatedPullRequests에 넘긴다 →
  //   포크가 같은 브랜치명으로 열어도 그 PR의 head는 포크 레포 ref라 이 connection에 **구조적으로** 없다.
  //   그래서 포화된 형제 head라도 질의 작업(페이지 수)이 포크 수와 무관하다(W71).
  const scanned = foldConnection<PrScan>(SIBLING_PR_QUERY, `refs/heads/${head}`, `PR 조회(${head})`, newScan, scanReducer(false));
  // 조회·파싱 실패 모두 head 문맥을 실어 돌려준다(호출부가 revocationBlind로 접을 때 어느 브랜치인지 남긴다).
  if (!scanned.ok) return parseFail(`PR 조회 파싱 실패(${head}): ${scanned.why}`);
  // ⚠️ **불일치 = 관측 실패**(R-43·R-44): 형제 ref는 `git ls-remote`가 OID `expectedOid`로 **존재를 보고했다**.
  //    ref-조회가 어긋나면(ref:null이거나 tip OID가 다르면) 두 비원자적 읽기가 갈린 것이다 — stale/저하 뷰·
  //    재생성. "PR 0건 → 회수할 것 없음"으로 접으면 **무장된 좀비를 못 본 채 exit 0**이 된다. → fail-closed로
  //    돌려 호출부가 revocationBlind로 접게 한다(회수 대상을 가릴 수 있는 관측 실패 = V-2).
  const refObs = scanned.value.ref;
  if (!refObs.present) {
    return parseFail(`PR 조회 불일치(${head}): ls-remote는 ref(${expectedOid})를 보고했는데 GraphQL은 ref:null이다 — 무장 여부를 알 수 없다(stale 뷰·재생성)`);
  }
  if (refObs.oid !== expectedOid) {
    return parseFail(`PR 조회 OID 불일치(${head}): ls-remote tip=${expectedOid} vs GraphQL tip=${refObs.oid} — ref가 두 읽기 사이 이동했다, 무장 여부를 알 수 없다(R-44)`);
  }
  const mine = scanned.value.value.trusted;
  if (mine.length > 1) {
    return parseFail(`${head}에 신뢰 PR이 ${mine.length}건이다(GitHub 계약상 불가능) — 모호해서 건드리지 않는다`);
  }
  // ★ 3자 합의(R-44): 신뢰 PR이 있으면 그 head도 관측된 ref tip과 같아야 한다(GraphQL 응답 내부 정합성).
  //   섞인 뷰가 tip=A인데 headRefOid=B인 PR을 주면, 그 PR의 무장을 유지·회수할 근거가 흔들린다.
  const pr = mine[0] ?? null;
  if (pr !== null && pr.headRefOid !== refObs.oid) {
    return parseFail(`신뢰 PR head 불일치(${head}): PR #${pr.number} headRefOid=${pr.headRefOid} vs ref tip=${refObs.oid} — 인가 근거가 흔들린다(R-44)`);
  }
  return { ok: true, value: { pr, openCount: scanned.value.value.totalOpen } };
}

// 스윕이 관측·변이한 형제의 상태(테스트/운영이 stdout으로 검증한다).
type SiblingState = {
  branch: string; tag: string; number: number | null;
  trusted: boolean; armed: boolean; createdAt: string | null; headRefOid: string | null;
  humanTouch: string | null;
  disarmed: boolean; closed: boolean; closeBlocked: string | null;
};

// ══ --reconcile-only — **인가 회수 전용 패스**(H-1) ══════════════════════════════════════════════
//
// 왜 별도 모드인가: 아래 주 경로는 **후보(tag)가 있어야** 돈다. 그런데 호출부(bump-poll.yaml)의 bump 루프는
// 플래너가 `bump`/`propose-pr`을 낸 앱만 순회한다 — `noop`(배포 핀이 이미 최신·동일 digest)이나
// `refuse`(GHCR 일시 장애·compare 실패·앱 레포 이력 재작성)인 주기엔 그 앱의 실행기가 **아예 호출되지 않는다**.
// 그 사이 `.bindings.json`의 autoDeploy가 true→false로 뒤집히면, 이미 열려 **무장된** PR이 낡은 머지 인가를
// **무기한** 들고 있는다(gate가 green이 되는 순간 사람 승인 없이 머지된다).
// ★★ **해제는 가용성이 아니라 보안 속성이다** — 플래너가 후보를 내주느냐에 의존해선 안 된다.
//    그래서 호출부는 **바인딩된 전 앱**에 대해 **매 주기** 이 모드를 돌린다(후보 유무·plan action 무관).
//
// ★★★ 이 패스는 **네임스페이스에 대해 완전해야 한다**(V-1) — "레인이 뒤집혔나"만 보면 안 된다 ─────
// 회수의 트리거는 **셋**인데 예전 이 패스는 그중 **하나**(레인이 propose-pr로 뒤집힘)만 다루고
// `if (lane === "bump") continue;`로 나머지를 통째로 건너뛰었다:
//     ① 레인 뒤집힘(autoDeploy true→false)        ← 이 패스가 다뤘다
//     ② **superseded 형제**(더 새 후보가 나왔다)   ← 주 경로의 형제 스윕에만 있었다
//     ③ **증명되지 않은 head**(R-23)               ← 주 경로에만 있었다
// 그런데 주 경로는 **플래너가 그 앱의 후보를 낸 주기에만** 호출된다(`select(.action == "bump" or …)`).
// 즉 `autoDeploy:true` 앱에서 ②·③의 **유일한 회수자가 주 경로**인데, 그 경로는 정확히 다음 순간에 굶는다:
//   · `noop` — bump가 머지된 **직후의 정상 상태**다(배포 핀 = GHCR 최신 태그) → 후보 없음 → 실행기 미호출.
//   · `refuse` — 앱 레포 이력 재작성·source-repo 드리프트·GHCR 일시 장애.
// 그 사이 무장된 옛 PR은 **열린 채 살아남고 run은 매번 초록이다**(telegram 무발화). 누군가(사람의
// "Update branch", 체크 재실행, main 이동에 따른 체크 재평가) 그 브랜치를 전진시키는 순간 **옛 이미지가
// 승인 없이 머지된다** = 무승인 롤백(R-25가 막으려던 바로 그 피해).
// → 그래서 이 패스는 **레인과 무관하게** 네임스페이스 전체를 판정한다. 쓰는 사실은 이 패스가 **이미
//   관측하는 것뿐**이다(네임스페이스 열거 + PR 조회 + 커밋 조회 — 플래너도, reader 토큰도 필요 없다):
//   · lane=propose-pr / SSOT 부재·파손 / 앱을 유도할 수 없는 브랜치 → 신뢰 PR의 무장을 **전부** 회수한다.
//   · lane=bump → 그 앱의 **가장 새로운**(createdAt) 열린 신뢰 PR **하나만** 무장을 유지하고,
//                 **더 오래된 형제는 전부 회수한다**(superseded PR은 레인과 무관하게 머지될 자격이 없다).
//   · 레인 무관 — 무장된 PR의 head가 **우리 bump 커밋임이 증명되지 않으면** 회수한다(R-23 패리티).
// ⚠️ 비대칭이 이 설계를 정당화한다: **과잉 회수는 안전하다**(다음 bump 주기가 정당한 최신 PR을 desired
//    state로 **재무장**한다 — R-10). **과소 회수는 무승인 머지다**. 애매하면 회수한다.
// ⚠️ 남는 한계(정직하게): 그 앱의 열린 신뢰 PR이 **하나뿐**이면 이 패스는 그것을 최신으로 보고 무장을
//    유지한다 — 그게 이미 superseded된 좀비여도(그 사실은 GHCR 최신 태그를 아는 **플래너만** 알 수 있고,
//    이 패스는 의도적으로 플래너에 의존하지 않는다). 그 경우는 후보가 다시 생기는 주기에 주 경로가 잡는다.
//    이 패스가 좁히는 것은 "형제가 둘 이상인데 아무도 방문하지 않는" 구간이다(라이브 좀비 #348·#350·#351).
//
// 변이는 여전히 **해제 하나뿐**이다: push·PR 생성·무장·close는 이 모드에서 **어떤 경로로도** 일어나지 않는다
// (그래서 레인을 잘못 읽어도 인가를 **부여**할 길이 없다 — 최악이 "회수 누락"이거나 "과잉 회수"다).
//
// 레인의 출처는 플래너가 아니라 **autoDeploy SSOT 파일 그 자체**다(poll-ghcr.ts와 **같은 파일, 같은 헬퍼**):
//   apps 레인      : apps/<app>/deploy/prod/.bindings.json
//   베스포크 핀 레인: platform/<app>/prod/.image-pin.json
// plan의 `.action`을 쓰지 않는 이유: noop/refuse 항목엔 레인이 담기지 않는다(그 값은 "후보가 없다"는 뜻이지
// "승인 레인"이라는 뜻이 아니다). 그리고 호출부가 레인을 지어내면 그게 곧 승인 게이트 우회다(R-11).
//
// ★★ **SSOT 부재·파손도 레인이다 — `propose-pr`이다**(R-26) ─────────────────────────────────────
// 예전엔 "SSOT를 못 읽으면 레인을 모른다 → **아무것도 하지 않는다**"였다. 그건 인가 경계에서 **두 개의
// 진실**을 만든 것이다: 플래너(SSOT)는 같은 상태를 **`propose-pr`로 확정**하는데(아래 인용), 회수만
// "모른다"며 손을 뗐다 → `.bindings.json`이 사라진 앱에 **이미 무장된 PR이 있으면 그 낡은 인가가 그대로
// 살아남는다**. 인가 문맥에서 fail-closed는 "아무것도 하지 않는다"가 아니라 **"권한을 거둔다"**이다.
//
// 플래너의 실제 코드(tools/poll-ghcr.ts planApp — 이 도구가 **맞춰야 할** 계약, 읽기 전용):
//     // 승인 정책: autoDeploy === true만 자동, 그 외(false/누락/파싱 불가)는 전부 fail-closed
//     let autoDeploy = false;
//     const bindingsPath = path.join(dir, ".bindings.json");
//     if (existsSync(bindingsPath)) {
//       try { autoDeploy = descriptorAutoDeploy(JSON.parse(readFileSync(bindingsPath, "utf8"))); }
//       catch { autoDeploy = false; }
//     }
//     …  action: s.autoDeploy ? "bump" : "propose-pr"
// 즉 **파일 없음 = 파싱 불가 = autoDeploy:false = propose-pr**. 세 상태가 하나의 레인으로 접힌다.
// → probeLane도 **언제나 레인을 준다**. 다만 어떻게 정해졌는지는 구분해 보고한다(resolution):
//     present    : SSOT를 읽었다(autoDeploy 값 그대로)
//     absent     : SSOT가 없다 → propose-pr. 플래너 계약상 **정상 상태**다(앱이 철거됐거나 바인딩이 없다) → 조용히 회수만.
//     unreadable : SSOT가 깨졌다 → propose-pr. 회수는 **하고**, 그 사실은 실패로 **시끄럽게** 보고한다(사람이 고쳐야 한다).
type LaneResolution = "present" | "absent" | "unreadable";
type LaneProbe = { lane: Lane; resolution: LaneResolution; source: string | null; why: string | null };
function probeLane(app: string): LaneProbe {
  const candidates = [
    path.join(args.root, "apps", app, "deploy", "prod", ".bindings.json"),
    path.join(args.root, "platform", app, "prod", ".image-pin.json"),
  ];
  for (const file of candidates) {
    if (!existsSync(file)) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(file, "utf8"));
    } catch (e) {
      // 깨진 SSOT는 "autoDeploy:true"가 **아니다**. 플래너도 여기서 false로 접는다(위 인용의 catch) →
      // 레인은 propose-pr이고, 그러므로 **무장은 회수한다**. 파손 사실은 failures로 올려 run을 빨갛게 만든다.
      return {
        lane: "propose-pr",
        resolution: "unreadable",
        source: file,
        why: `autoDeploy SSOT 파싱 실패(${file}): ${(e as Error).message} — 플래너와 같은 결론(autoDeploy:false)으로 접고 **인가를 회수한다**`,
      };
    }
    // descriptorAutoDeploy = poll-ghcr.ts가 쓰는 그 함수다(`d?.autoDeploy === true`) — 두 번째 진실을 만들지 않는다.
    return {
      lane: descriptorAutoDeploy(parsed as any) ? "bump" : "propose-pr",
      resolution: "present",
      source: file,
      why: null,
    };
  }
  return {
    lane: "propose-pr",
    resolution: "absent",
    source: null,
    why: `autoDeploy SSOT 없음(${candidates.join(" | ")}) — 플래너 계약상 autoDeploy:false(= propose-pr) → 무장은 인가되지 않았다`,
  };
}

// 이 모드가 관측·회수한 주체(브랜치) 하나의 상태 — 테스트/운영이 stdout으로 검증한다.
// createdAt: superseded 판정의 **유일한 순서 근거**(주 경로의 close 스윕과 같은 사실을 쓴다).
// headProven: R-23 패리티의 결과(null = 검사하지 않았다 — 어차피 회수할 대상이었다).
// revokeReason: 왜 회수했는가(null이면 "인가된 무장이라 손대지 않았다").
type SubjectState = {
  branch: string; app: string | null; tag: string | null;
  lane: Lane; laneResolution: LaneResolution | "unparsed-branch"; laneSource: string | null;
  number: number | null; trusted: boolean; armed: boolean; headRefOid: string | null;
  createdAt: string | null;
  humanTouch: string | null;
  headProven: boolean | null;
  revokeReason: string | null;
  disarmed: boolean;
};

// 한 앱의 열린 신뢰 PR들 중 **유일한 최신**(createdAt 전순서)을 고른다. 증명할 수 없으면 null이다.
// ⚠️ **애매하면 회수한다** — 여기서 null을 돌려준다는 건 "이 앱의 어떤 무장도 인가됐다고 말할 수 없다"는
//    뜻이고, 호출부는 그 앱의 무장을 **전부 회수한다**. 이 판단은 close 스윕의 관용구("관측할 수 없으면
//    아무것도 하지 않는다")와 **일부러 반대 방향**이다. 두 연산의 안전 방향이 반대이기 때문이다:
//      · close = **파괴** → 모르면 하지 않는다(되돌릴 수 없는 것을 추측으로 하지 않는다).
//      · 회수 = **인가 박탈** → 모르면 **한다**(모듈 전체가 반복해 말한다: 회수는 언제나 안전 방향이다).
//    결정적 근거: 한 앱에 열린 신뢰 PR이 **2건 이상**이면 그중 **최소 하나는 확실히 superseded**다
//    (이번 후보는 하나뿐이다). 순서를 모른다고 손을 떼면 **낡은 인가가 확실히 하나 살아남는다**.
//    반대로 전부 회수하면 최악이 "정당한 최신 PR의 무장이 한 주기 늦게 복구된다"이고, 그건 R-10의
//    desired-state 재무장이 다음 bump 주기에 자동으로 고쳐 준다. (열린 PR이 하나뿐이면 superseded될
//    형제 자체가 없으므로 호출부가 이 함수를 부르지도 않는다 — 무의미한 churn 0.)
function uniqueNewest(group: SubjectState[]): SubjectState | null {
  let best: SubjectState | null = null;
  let bestAt = -Infinity;
  let tied = false;
  for (const s of group) {
    if (s.createdAt === null) return null;            // 나이를 모르는 PR이 하나라도 있으면 전순서가 없다
    const at = Date.parse(s.createdAt);
    if (Number.isNaN(at)) return null;                // 형식 드리프트도 같다
    if (at > bestAt) {
      bestAt = at;
      best = s;
      tied = false;
    } else if (at === bestAt) {
      tied = true;                                    // 동률 = "그 최신"이 유일하지 않다
    }
  }
  return tied ? null : best;
}

if (args.reconcileOnly) {
  const subjects: SubjectState[] = [];
  // 실패는 **모아서** 끝에서 비-0으로 낸다(회수는 보안 속성이다 — 못 했으면 run이 빨개야 한다).
  // ⚠️ 단, 이 패스의 실패가 bump 루프를 굶겨선 안 된다(억제 = 공격 표면) → 호출부에서 **별도 job**이다.
  const failures: string[] = [];
  // 앱마다 SSOT를 한 번만 읽는다(한 앱에 형제 브랜치가 여러 개 있을 수 있다).
  const laneCache = new Map<string, LaneProbe>();
  const corruptReported = new Set<string>();
  const laneOf = (app: string): LaneProbe => {
    let p = laneCache.get(app);
    if (p === undefined) {
      p = probeLane(app);
      laneCache.set(app, p);
    }
    return p;
  };

  // ══ 패스 A — 관측(변이 0). 네임스페이스 전체를 먼저 **다 본다** ═══════════════════════════════
  // 왜 두 패스인가: superseded 판정은 **한 앱의 형제들을 서로 비교**해야 나온다(누가 가장 새로운가).
  // 주체를 보면서 그 자리에서 회수하면 그 비교를 할 수 없다 — 아직 못 본 형제가 더 새로울 수 있다.
  //
  // ★ 주체는 **네임스페이스가 준다**(R-27) — 플래너의 plan.json도, 호출부의 앱 목록도 입력이 아니다.
  //   그래서 플래너 스텝이 죽든, reader 토큰이 죽든, 어떤 앱이 플래너 출력에서 빠지든 이 스윕은 그대로 돈다.
  const refsResult = enumerateNsRefs();
  if (!refsResult.ok) {
    // 열거가 깨지면 **주체를 하나도 보지 못한 것**이다 → 회수 대상을 가릴 수 있는 관측 실패(V-2).
    revocationBlind(`bump-poll/* 네임스페이스 열거 실패: ${refsResult.why}`);
  } else {
    for (const nref of refsResult.refs) {
      // ── 레인 결정 ────────────────────────────────────────────────────────────────────────
      // 앱을 유도할 수 없는 브랜치(`bump-poll/` 아래인데 `<app>-<tag>` 형식이 아니다)는 **인가를 증명할 수
      // 없는 브랜치**다 → 같은 관용구로 접는다: 증명할 수 없으면 **거둔다**(propose-pr 쪽). 과잉 회수는
      // 안전하다(autoDeploy 앱이면 다음 주기의 bump 경로가 desired state로 **재무장**한다 — R-10).
      const probe = nref.app !== null ? laneOf(nref.app) : null;
      const laneHere: Lane = probe?.lane ?? "propose-pr";
      const resolution: LaneResolution | "unparsed-branch" = probe?.resolution ?? "unparsed-branch";
      if (probe !== null && probe.resolution === "unreadable" && !corruptReported.has(nref.app!)) {
        // 깨진 SSOT는 **회수는 하되**(위 probeLane 참고) 사람이 고쳐야 하는 결함이다 → run을 빨갛게 만든다.
        corruptReported.add(nref.app!);
        failures.push(probe.why!);
        warn(`${nref.app}: ${probe.why}`);
      }
      if (probe === null) {
        warn(`${nref.branch}: 브랜치명에서 앱을 유도할 수 없다 — 인가를 증명할 수 없는 브랜치이므로 **무장이 있으면 회수한다**`);
      }

      // 관측 실패는 **전부** 같은 결론이다(V-2 · R-34): 조회 장애 · 파싱/스키마 드리프트(**author 부재
      // 포함**) · 신뢰 PR 모호성 — 셋 다 "이 브랜치에 무장된 PR이 있는지 **알 수 없다**"이지 "없다"가 아니다.
      // ⚠️ 특히 author 부재를 "우리 것이 아니다"로 접으면 **무장된 writer PR이 여기서 증발한다**(R-34).
      const observed = observeBranchPr(nref.branch, nref.oid);
      if (!observed.ok) {
        revocationBlind(observed.why);
        continue;
      }
      const pr = observed.value.pr;
      subjects.push({
        branch: nref.branch, app: nref.app, tag: nref.tag,
        lane: laneHere, laneResolution: resolution, laneSource: probe?.source ?? null,
        number: pr?.number ?? null, trusted: pr !== null, armed: pr?.autoMerge ?? false,
        headRefOid: pr?.headRefOid ?? null, createdAt: pr?.createdAt ?? null,
        humanTouch: pr?.humanTouch ?? null,
        headProven: null, revokeReason: null, disarmed: false,
      });
    }
  }

  // ══ 패스 B — 판정 + 회수(유일한 변이) ═══════════════════════════════════════════════════════
  // 앱별로 열린 신뢰 PR을 모은다. **이 그룹이 superseded 판정의 전부다** — 그 앱의 후보가 무엇인지
  // 알 필요가 없고(플래너 없음), 알 수도 없다(writer 토큰뿐).
  const byApp = new Map<string, SubjectState[]>();
  for (const st of subjects) {
    if (st.app === null) continue;   // 앱을 모르는 브랜치는 그룹이 없다(어차피 propose-pr → 전부 회수)
    if (!st.trusted) continue;       // 고아 ref · 포크 · 사람 · 다른 base는 우리 PR이 아니다
    const g = byApp.get(st.app) ?? [];
    g.push(st);
    byApp.set(st.app, g);
  }

  for (const st of subjects) {
    if (!st.trusted) continue;       // 우리가 만질 수 있는 PR이 없다 → 아무것도 하지 않는다
    if (!st.armed) continue;         // 이미 무장 없음 → 회수할 것도 없다(멱등)

    // ── 회수 트리거 ① 레인 — 승인 레인·SSOT 부재/파손·앱 미상은 전부 "인가되지 않은 무장"이다(R-26).
    if (st.lane !== "bump") {
      st.revokeReason = `무장이 인가되지 않았다(레인=${st.lane} · ${st.laneResolution})`;
    } else {
      // ── 회수 트리거 ② superseded — 그 앱의 **가장 새로운** PR 하나만 무장을 유지한다(V-1).
      //    형제가 없으면(그 앱의 열린 신뢰 PR이 이 하나뿐) superseded될 수 없다 → 건드리지 않는다
      //    (W48의 anti-churn: 매 10분 무장을 지웠다 다시 거는 짓을 하지 않는다).
      const group = byApp.get(st.app!) ?? [st];
      if (group.length > 1) {
        const newest = uniqueNewest(group);
        if (newest === null) {
          // 전순서를 세울 수 없다(createdAt 부재·형식 드리프트·동률). 그런데 **둘 이상이 열려 있으므로
          // 최소 하나는 확실히 superseded다** → 어느 것도 "인가된 무장"이라고 말할 수 없다 → 전부 회수.
          // (과잉 회수는 R-10의 재무장이 다음 주기에 되돌린다. 과소 회수는 무승인 머지다.)
          st.revokeReason = "이 앱의 열린 신뢰 PR이 2건 이상인데 createdAt으로 최신을 특정할 수 없다"
            + "(부재·형식 드리프트·동률) — 최소 하나는 확실히 superseded이므로 어느 무장도 인가로 볼 수 없다";
        } else if (newest !== st) {
          st.revokeReason = `superseded — 같은 앱의 더 새로운 PR #${newest.number}(${newest.branch})이 열려 있다`;
        }
      }
    }

    // ── 회수 트리거 ③ **증명되지 않은 head**(R-23 패리티 — 레인 무관) ──────────────────────────
    // 무장을 **남겨 두기로 한** PR에만 건다: 그 인가를 유지하려면 head가 우리 bump 커밋이어야 한다.
    // (이미 회수하기로 한 PR엔 묻지 않는다 — 결론이 같은데 커밋 조회를 한 번 더 때릴 이유가 없다.)
    if (st.revokeReason === null) {
      const proof = proveOurCommit(
        st.headRefOid!,
        `PR #${st.number}(${st.branch})의 head`,
        bumpCommitMessageOf(st.app!, st.tag!),
      );
      st.headProven = proof.ok;
      if (!proof.ok) {
        st.revokeReason = `head 소유권 미증명(R-23) — ${proof.why}`;
        warn(`${st.branch}: ${st.revokeReason}`);
      }
    }

    if (st.revokeReason === null) continue;   // **인가된 무장**이다 — 손대지 않는다(멱등)
    // 회수는 **공유 연산**이다(R-32) — 주 경로의 형제 스윕과 **같은 함수, 같은 실패 계약**을 쓴다:
    // 실패해도 **다음 주체로 계속 간다**(한 PR의 실패가 나머지를 굶기면 그게 곧 회수의 실패다).
    // 실패 사실은 revocationFailures에 모여 아래에서 종료 코드와 보고를 함께 결정한다.
    if (!revokeArming(st.number!, st.branch)) continue;
    st.disarmed = true;
  }

  // 이 패스의 실패 = 회수 실패 + 관측 실패(둘 다 revocationFailures — V-2) + 깨진 SSOT(failures).
  // 전부 "회수를 증명하지 못했다"는 같은 결론이라 한 목록으로 보고하고, 한 종료 코드로 낸다.
  const allFailures = [...failures, ...revocationFailures];
  console.log(JSON.stringify({
    mode: "reconcile-only",
    // 주체는 **관측된 네임스페이스**다(입력이 아니다) — 레인은 주체마다 SSOT에서 따로 정해진다.
    subjects,
    failures: allFailures,
    // R-32: **회수만** 따로 뽑은 목록(두 모드가 같은 키로 보고한다) — 무엇을 회수하지 못했는가.
    revocationFailures,
    executed,
    // R-36: 페이지네이션의 **경계 있는 관측**(정수 하나) — read-only 조회는 executed에 담지 않는다.
    graphqlPages,
  }, null, 2));
  // 회수는 보안 속성이다 → 한 건이라도 못 했으면 run은 **빨개야** 한다(telegram 알림이 발화한다).
  process.exit(allFailures.length > 0 ? 1 : 0);
}

// ── ① 조회 — 변이보다 **먼저**, 상한 없이 **전부** 접는다(순서도 완전성도 계약이다: R-4) ────────
// foldConnection이 hasNextPage=false까지 **한 페이지씩** 따라가며 페이지를 받는 즉시 접는다(R-33: 캡처
// 하나 = 한 페이지 / R-36: 원본 페이지·포크 노드는 버려 **직렬화되는 출력**(observed·executed 둘 다)이
// 포크 수와 무관하다 — read-only 조회는 원장 대신 graphqlPages 카운터로만 관측한다).
// 상한이 없으므로 포크 PR이 몇 건이든(200건이든 2000건이든, 응답 총량이 몇 MiB든) 우리 PR은 반드시 이
// 열거 안에 있다 → 포크로는 배포를 정지시킬 수 없다.
// owner/repo는 gh의 `{owner}`/`{repo}` 플레이스홀더가 현재 레포에서 채운다(라이브 확인).
// ⚠️ 본 경로의 관측 실패는 **즉시 fail-closed**다(회수 경로와 갈리는 유일한 지점 — 여기서 계속 가면
//    그건 곧 "사실을 모른 채 create/adopt"이고, 그게 이 픽스가 없애는 중복 PR 버그 그 자체다).
const scannedPrs = foldConnection<PrScan>(PR_QUERY, ref, "gh api graphql (associatedPullRequests)", newScan, scanReducer(true));
if (!scannedPrs.ok) inputError(scannedPrs.why);
const mainScan = scannedPrs.value.value;
const refObserved = scannedPrs.value.ref; // GraphQL이 본 ref: 부재/존재+OID (R-43)
const remoteBranch = parseLsRemote(run("git", ["ls-remote", "--heads", args.remote, branch], "git ls-remote"));

// ── ①-b superseded 형제 열거(관측) — 변이 0. 실패는 **계속하되 조용하지 않다** ────────────────
// 두 가지가 여기서 **갈라진다**(예전엔 한 덩어리였고 그게 결함이었다 — V-2):
//   · `closeAbandoned` = **위생(close)의 게이트**. 열거·조회가 한 곳이라도 깨지면 그 run의 close는 전부
//     포기한다(과소 열거로 **일부만** 닫는 것보다 아예 안 닫는 게 안전하다 — 파괴는 완전한 증거 위에서만).
//   · `revocationBlind()` = **결과(종료 코드·보고)**. 같은 실패는 "이 브랜치에 무장된 PR이 있는지 **모른다**"는
//     뜻이기도 하다. 그건 close의 문제가 아니라 **회수의 문제**다.
// 예전 코드는 `closeAbandoned`만 세우고 exit 0으로 끝냈다 — 그런데 종료 코드는 오직 revocationFailures가
// 정한다 → **형제 조회가 깨지면 무장된 좀비를 보지도 못한 채 run이 초록**이었다(그리고 `--reconcile-only`는
// 같은 상황에서 exit 1이었다 → 두 경로의 계약이 갈라져 있었다). 이제 둘 다 같은 결과 계약을 쓴다.
// ⚠️ 그래도 **abort하지 않는다**: 아무나 `bump-poll/<app>-*` ref 하나로 배포를 정지시킬 수 있으면 안 된다
//    (억제 = 공격 표면). 메인 변이는 끝까지 하고, run만 맨 끝에서 빨개진다.
const siblings: SiblingState[] = [];
let closeAbandoned: string | null = null;
const refsResult = enumerateSiblingRefs();
if (!refsResult.ok) {
  closeAbandoned = refsResult.why;
  revocationBlind(`형제 브랜치 열거 실패 — superseded 스윕이 아무도 방문하지 못했다: ${refsResult.why}`);
} else {
  for (const sref of refsResult.refs) {
    // 관측 실패는 **하나의 사실**이다(조회 장애 · 파싱/스키마 드리프트(**author 부재 포함** — R-34) ·
    // 신뢰 PR 모호성): "이 형제에 무장된 PR이 있는지 모른다". 두 결과가 함께 따라온다 —
    //   · closeAbandoned  = 이 run의 close는 전부 포기(과소 열거로 **일부만** 닫는 것보다 안 닫는 게 안전)
    //   · revocationBlind = 종료 코드·보고(회수 대상을 가릴 수 있는 관측 실패 = 회수 실패 — V-2)
    const observed = observeBranchPr(sref.branch, sref.oid);
    if (!observed.ok) {
      closeAbandoned = observed.why;
      revocationBlind(`${observed.why} — 이 형제의 무장 여부를 모른다`);
      continue;
    }
    const pr = observed.value.pr;
    if (pr === null) {
      // 우리가 만질 수 있는 PR이 없다. 두 경우가 있고, **둘 다 아무것도 하지 않는다**:
      //   · 열린 PR이 아예 없다(고아 ref) → 브랜치는 **지우지 않는다**(ref 삭제는 되돌아가지 않는다).
      //     그 tag가 다시 후보가 되면 adopt가 접수한다.
      //   · 열린 PR은 있는데 우리 것이 아니다(포크·사람·다른 봇·다른 base) → 접두 일치는 소유권의 증거가
      //     아니다(`bump-poll/**` ruleset이 없으므로 그 접두는 예약돼 있지 않다).
      const why = observed.value.openCount > 0
        ? "열린 PR이 있으나 우리 것이 아니다(포크·비-writer·다른 base) — 건드리지 않는다"
        : "열린 PR 없음(고아 ref — 브랜치는 지우지 않는다)";
      siblings.push({
        branch: sref.branch, tag: sref.tag, number: null, trusted: false, armed: false,
        createdAt: null, headRefOid: null, humanTouch: null,
        disarmed: false, closed: false, closeBlocked: why,
      });
      continue;
    }
    siblings.push({
      branch: sref.branch, tag: sref.tag, number: pr.number, trusted: true, armed: pr.autoMerge,
      createdAt: pr.createdAt, headRefOid: pr.headRefOid, humanTouch: pr.humanTouch,
      disarmed: false, closed: false, closeBlocked: null,
    });
  }
}

// ── ①-c **형제 해제 스윕** = 첫 변이(안전 방향 · 넓은 대상 · 약한 증거 · 중단 불가) ──────────────
// R-25의 피해(낡은 인가로 승인 없이 머지)는 **이 스윕 하나로 100% 사라진다**. 그래서 close(파괴)의
// 증거 요건이 여기 커버리지를 깎아먹지 않게 **두 축을 분리**한다:
//   · 해제는 **레인을 읽지 않는다** — superseded PR은 레인과 무관하게 머지될 자격이 없다(옛 이미지 배포).
//   · 해제는 **소유권 증명도 요구하지 않는다** — 인가 회수는 언제나 안전한 방향이다.
// 대상은 언제나 **인증된 PR 번호**다(브랜치 셀렉터 금지 — 동명 포크 PR 오조준).
// ⚠️ 이 스윕은 아래 fail-closed 검사들(신뢰 PR 모호성·비신뢰 동일-레포 PR·소유권)보다 **먼저** 실행한다:
//    중단 가능한 검사가 앞서면, 인가를 **가장 회수해야 할 상태**에서 정확히 회수하지 못한다(R-23의 순서 규칙).
//
// ★ 해제 실패의 계약(R-32) — `--reconcile-only`와 **글자 그대로 같다**(revokeArming 하나를 공유한다):
//   · **중단하지 않는다**: 나머지 형제도, **이번 주기의 메인 변이(push/create/skip)도 그대로 진행**한다.
//     한 PR의 해제 실패가 배포를 멈추면 억제가 곧 공격 표면이 되고, 다른 형제의 회수까지 굶긴다.
//   · **그러나 조용하지도 않다**: 실패는 revocationFailures에 모여 이 run을 **비-0으로 끝낸다**(맨 아래).
//     여기서 실패를 삼키면(그리고 close가 사람 흔적·캡·킬 스위치로 막히면) **무장된 좀비 PR이 남는데
//     아무도 모른다** — 그리고 그건 "다음 주기가 고친다"의 전제조건(누군가 그 PR을 **방문한다**)이
//     성립하지 않는 상태다.
// ★ 이 스윕은 이제 **유일한 회수자가 아니다**(V-1): `--reconcile-only`도 bump 레인의 superseded 형제를
//   회수한다(후보가 없는 noop/refuse 주기에도). 그래서 위 revokeArming의 "다음 주기가 재시도한다"는
//   약속이 **비로소 참이 됐다** — 예전엔 그 재시도가 "플래너가 이 앱의 후보를 또 내주면"이라는 조건에
//   묶여 있었고, 그 조건이 깨진 주기가 정확히 이 결함의 서식지였다.
for (const s of siblings) {
  if (!s.trusted) continue;
  if (!s.armed) continue;
  if (!revokeArming(s.number!, s.branch)) continue;
  s.disarmed = true;
}

// 판정 입력은 fold가 이미 접어 둔 사실뿐이다(R-36): 신뢰 PR·동일-레포 비신뢰 PR·경계 카운터.
// 동일-레포 PR에만 진단용 `trusted` 플래그를 붙인다 — 포크 노드는 애초에 버려졌다(요약 카운터로만 관측).
const trustedAll = mainScan.trusted;
const sameRepoPrs = [
  ...mainScan.trusted.map((pr) => ({ ...pr, trusted: true })),
  ...mainScan.untrustedSameRepo.map((pr) => ({ ...pr, trusted: false })),
];
// GitHub은 같은 head→base 쌍에 열린 PR을 1개만 허용한다 → 신뢰 PR이 2개 이상이면 우리의 신뢰 경계나
// GitHub의 계약 중 하나가 깨진 것이다. 아무거나 고르면 나머지 하나는 조용히 방치된다(무장 갭·좀비).
if (trustedAll.length > 1) {
  inputError(
    `신뢰 PR이 ${trustedAll.length}건이다(#${trustedAll.map((p) => p.number).join(", #")}) — `
    + "같은 브랜치의 열린 신뢰 PR은 1건이어야 한다(어느 하나를 고르면 나머지가 방치된다)",
  );
}
const trusted = trustedAll[0] ?? null;

// ★ 3자 OID 합의(R-44) — 신뢰 PR의 무장 유지/재무장·rebuild는 **세 관측이 같은 tip을 가리킬 때만** 한다.
//   신뢰 PR이 있으면 그 head는 이 레포의 ref이므로 GraphQL ref도 ls-remote도 존재해야 하고, 셋(PR headRefOid
//   · GraphQL ref tip · ls-remote tip)이 모두 같아야 한다. stale/섞인 뷰가 tip을 달리 보고하면, 우리는 잘못된
//   baseline 위로 force-push하거나(rebuild) 낡은 head에 auto-merge를 걸 수 있다 → fail-closed(변이 0).
if (trusted !== null) {
  if (!refObserved.present) {
    execError(`신뢰 PR #${trusted.number}이 열려 있는데 GraphQL ref는 null이다 — 뷰 불일치, 인가 근거가 없다(R-44): force-push도 무장도 하지 않는다`);
  } else if (remoteBranch === null) {
    execError(`신뢰 PR #${trusted.number}이 열려 있는데 ls-remote는 브랜치를 못 봤다 — 뷰 불일치(R-44): 변이하지 않는다`);
  } else if (trusted.headRefOid !== refObserved.oid || refObserved.oid !== remoteBranch.oid) {
    execError(
      `신뢰 PR #${trusted.number} 3자 OID 불일치(R-44): PR headRefOid=${trusted.headRefOid} · GraphQL ref=${refObserved.oid} · ls-remote=${remoteBranch.oid}. `
      + "셋이 같은 tip을 가리키지 않으면 stale/섞인 뷰다 → 잘못된 baseline에 force-push하거나 낡은 head에 auto-merge를 걸 수 없다(변이 0, 다음 주기가 다시 읽는다)",
    );
  }
}

// ★★ 파괴 가드 — `adopt`(force-push)는 **우리 자신의 고아 브랜치**일 때만 정당하다 ────────────────
// 동일-레포(isCrossRepository:false) PR의 head는 **반드시 이 레포의 ref**다(포크와 달리 남의 레포에 있을 수
// 없다). 그러니 "열린 동일-레포 PR이 있다" = "그 브랜치는 이 레포에 존재하고, **그 PR의 주인 것**이다".
// 그 PR을 신뢰하지 못하면(= writer App이 아닌 사람/다른 봇이 열었다) 우리는 두 가지를 다 하면 안 된다:
//   · adopt로 그 브랜치를 leased force-push → **남의 브랜치를 덮어써 작업을 파괴한다**
//   · create로 PR을 또 연다 → 같은 head에 중복 제안
// remoteBranch 유무로 갈리지 않는다: 동일-레포 PR이 열려 있는데 브랜치가 없는 상태는 **불가능**하고,
// 만약 그렇게 보인다면 우리가 사실을 잘못 읽은 것이다 → 어느 쪽이든 변이하지 않는 게 정답이다.
// (포크 PR은 여기 걸리지 않는다 — 포크의 head는 우리 레포 ref가 아니라 우리 브랜치를 침해하지 않는다.
//  그래서 포크만 있는 경우는 기존대로 브랜치 유무로 create/adopt를 고른다.)
// ⚠️ 소유권은 **base와 무관**하다: 같은 head를 다른 base로 향한 동일-레포 PR도 **그 브랜치를 쓰고 있다**.
//    그래서 조회를 base로 필터하지 않고(위 PR_QUERY), 여기서 head 전체의 동일-레포 PR을 본다.
//    (다른 base의 writer PR을 "우리 것"으로 오인하지 않는 건 isTrusted의 base 검사가 맡는다 — 식별과
//     소유권은 다른 질문이다: "우리 PR인가?"는 (head, base), "이 브랜치를 밀어도 되나?"는 head다.)
const untrustedSameRepo = mainScan.untrustedSameRepo;
if (trusted === null && untrustedSameRepo.length > 0) {
  const who = untrustedSameRepo
    .map((p) => `#${p.number}(${p.author?.login ?? "삭제된 계정"} → ${p.baseRefName})`)
    .join(", ");
  execError(
    `신뢰할 수 없는 동일-레포 PR이 이 브랜치에 열려 있다: ${who} — 브랜치 '${branch}'는 그 PR의 것이다. `
    + "force-push(adopt)로 덮어쓰면 남의 작업을 파괴하고, PR을 새로 열면 중복 제안이 된다",
  );
}

// ── ② 결정 — 관측 사실만으로 정한다(부작용 0) ──────────────────────────────────────────────
// 축 1(판정): 신뢰 PR의 **존재**가 최우선이다. 신뢰 PR이 있으면 원격 브랜치는 당연히 있으므로
// (그 PR의 head가 그것이다) 고아 판정으로 내려가지 않는다.
//   신뢰 PR + **DIRTY 또는 BEHIND** → rebuild (PR 재사용 — create 금지)
//   신뢰 PR + 그 외                 → skip    (CLEAN/BLOCKED/UNKNOWN … 변이 0)
//   신뢰 PR 없음 + 고아 원격 브랜치  → adopt
//   신뢰 PR 없음 + 원격 브랜치 없음  → create
// ★ rebuild 트리거는 **정확히 이 허용목록**이다(그 외는 전부 skip). 두 상태 모두 "head가 최신 main 위에
//   있지 않다"는 같은 사실이고, 해법도 같다 — 최신 main에서 재구축한 커밋을 leased force-push.
//   · DIRTY : 형제 PR이 먼저 머지돼 충돌났다(pr-sweeper는 DIRTY를 안 건드린다 → 우리가 안 풀면 영구 정지).
//   · BEHIND: strict 보호에서 main이 움직였다. 예전엔 pr-sweeper가 `gh pr update-branch`로 풀었지만,
//             그건 head를 **머지 커밋**으로 만들어 소유권 증명을 영구 파괴하고(→ 무장 회수 + fail-closed),
//             레인을 보지 않아 **승인 없이 머지**시킬 수 있었다(R-25). 이제 실행기가 소유한다.
//   · 그 외(CLEAN/BLOCKED/UNKNOWN/UNSTABLE/…)는 skip — 특히 UNKNOWN은 GitHub의 **지연 계산**이라
//     rebuild로 오분류하면 매 폴링 force-push가 나 게이트가 영구 재시작한다(배포 livelock).
// ⚠️ rebuild는 **레인-무관**이다(무장만 레인-의존). propose-pr PR도 BEHIND면 사람이 머지 버튼을 누를 수
//    없다 — 수렴은 머지가 아니다. 안전은 순서가 보장한다: 해제(③-a)가 **모든 push보다 먼저**다.
//
// ★★ **사람이 만진 PR은 force-push하지 않는다**(H-4) ──────────────────────────────────────────────
// BEHIND가 rebuild 트리거가 되면서 새 위험이 생겼다: strict 보호 main에서는 **main에 머지가 일어날 때마다**
// 열린 PR이 전부 BEHIND가 된다 → 승인 레인(propose-pr)의 PR은 사람이 리뷰하는 내내 ~10분마다 BEHIND고,
// 가드가 없으면 그때마다 force-push당한다. 그 결과: **승인이 stale review로 취소되고**, 인라인 리뷰 코멘트가
// outdated로 접히고, required 체크가 처음부터 다시 돈다 — 리뷰가 사실상 불가능해진다.
// close 스윕엔 humanTouch 가드가 있었는데 rebuild엔 없었다. 같은 가드를 건다.
//
// ⚠️ **승인 레인을 아예 rebuild하지 않으면 되지 않나?** — 안 된다. strict 보호에서는 사람이 **BEHIND한 PR을
//    머지할 수 없다**(머지 버튼이 잠긴다). 승인 레인의 PR을 영영 전진시키지 않으면 그 레인은 **구조적으로 막힌다**
//    (pr-sweeper는 이제 이 네임스페이스를 건드리지 않는다 — R-25). 그러니 "레인으로 가르는" 답은 틀렸다.
// → 가르는 축은 레인이 아니라 **사람의 흔적**이다. 그게 안전한 중간이다:
//      흔적 **없음** → rebuild한다(두 레인 모두). 파괴할 리뷰 상태가 애초에 없다 — 잃는 게 0이고,
//                     승인 레인은 사람이 머지 버튼을 누를 수 있는 상태로 유지된다.
//      흔적 **있음** → **밀지 않는다**(두 레인 모두). 그 PR은 사람이 다루는 중이다 — "Update branch" 버튼도,
//                     새 커밋도, close도 전부 사람의 선택지다. 우리는 보고만 한다(skip + reason).
//    (관측 불가도 "흔적 있음"으로 접힌다 — 모르는 상태에서 남의 리뷰를 파괴하지 않는다.)
const STALE_STATES = new Set(["DIRTY", "BEHIND"]);
// ⚠️ 본 질의는 mergeStateStatus를 **반드시** 담는다(scanReducer(true)의 parsePrNode requireMergeState가
//    없으면 fail-closed) → 여기 도달한 값은 non-null이다. 타입만 nullable인 이유는 파서를 형제 질의와
//    **공유**하기 때문이다(그 질의는 이 필드를 묻지 않는다 — R-34의 통합). 판정에 쓰기 전에 좁힌다.
const staleState = (pr: ObservedPr): boolean => pr.mergeStateStatus !== null && STALE_STATES.has(pr.mergeStateStatus);
type Decision = "create" | "adopt" | "skip" | "rebuild";
let action: Decision;
let reason: string;
if (trusted !== null) {
  if (staleState(trusted) && trusted.humanTouch !== null) {
    action = "skip";
    reason = `열린 신뢰 PR #${trusted.number}이 ${trusted.mergeStateStatus}지만 **사람의 흔적**이 있다(${trusted.humanTouch}) `
      + "— force-push하지 않는다(리뷰·승인 상태를 파괴한다). 전진은 사람의 선택이다";
    warn(
      `PR #${trusted.number}이 ${trusted.mergeStateStatus}지만 사람의 흔적(${trusted.humanTouch})이 있어 rebuild하지 않는다 `
      + "— 사람이 'Update branch'를 누르거나 새 커밋을 올리면 수렴한다",
    );
  } else if (staleState(trusted)) {
    action = "rebuild";
    reason = trusted.mergeStateStatus === "DIRTY"
      ? `열린 신뢰 PR #${trusted.number}이 DIRTY(충돌) — 최신 main에서 재구축해 leased force-push(같은 PR 재사용, create 금지)`
      : `열린 신뢰 PR #${trusted.number}이 BEHIND(base 이동) — pr-sweeper가 아니라 실행기가 수렴시킨다: 최신 main에서 재구축해 leased force-push(머지 커밋 0 — gh pr update-branch 금지)`;
  } else {
    action = "skip";
    reason = `열린 신뢰 PR #${trusted.number}(${trusted.mergeStateStatus}) — 이미 진행 중이므로 변이하지 않는다(중복 PR 금지)`;
  }
} else {
  // ── 신뢰 PR 없음 → create/adopt는 **두 비원자적 읽기**(GraphQL ref-조회 · git ls-remote)가 **합의**할 때만
  //    한다(R-43). 예전엔 `remoteBranch` 유무만 보고 갈랐다: `ref:null`(GraphQL 부재)이 "PR 0건"으로 접힌 뒤
  //    ls-remote가 브랜치를 보고하면 무조건 adopt(force-push)였다 → GraphQL 뷰가 stale/저하돼 **실재하는 PR을
  //    숨기면** 남의 커밋을 덮고 중복 PR을 열었다. 이제 presence + OID를 교차 검증한다:
  //      · 둘 다 부재                                   → create
  //      · 둘 다 존재 + OID 일치(+ 빈 connection)        → adopt (정당한 고아 — push 성공, PR 생성 실패)
  //      · 그 외(한쪽만 존재 / OID 상이)                 → fail-closed (변이 0 — 사실을 모른 채 밀지 않는다)
  const lsPresent = remoteBranch !== null;
  if (!refObserved.present && !lsPresent) {
    action = "create";
    reason = "열린 신뢰 PR도 원격 브랜치도 없다(GraphQL ref:null + ls-remote 부재 합의) — 정상 경로(push → PR 생성)";
  } else if (refObserved.present && lsPresent && refObserved.oid === remoteBranch!.oid) {
    action = "adopt";
    reason = `열린 신뢰 PR은 없고 원격 브랜치가 고아로 남아 있다(GraphQL·ls-remote 합의, OID ${remoteBranch!.oid}) — 원격 OID를 기대값으로 leased force-push 후 PR 생성`;
  } else {
    // 불일치: GraphQL만/ls-remote만 존재, 또는 OID 상이(두 읽기 사이 ref 이동·재생성·stale 뷰).
    execError(
      `ref 관측 불일치 — 밀지 않는다(R-43): GraphQL ref=${refObserved.present ? `존재(${refObserved.oid})` : "null(부재)"}, `
      + `ls-remote=${lsPresent ? `존재(${remoteBranch!.oid})` : "부재"}. `
      + "한쪽만 존재하거나 OID가 어긋나면 실재하는 PR을 숨긴 stale/저하된 뷰일 수 있다 → force-push도 create도 하지 않는다(다음 주기가 다시 읽는다)",
    );
    action = "skip"; // 도달하지 않는다(execError가 프로세스를 끝낸다) — 타입 만족용
    reason = "unreachable";
  }
}

// ── ②-b **ref 소유권** 검증 — 정의는 위(proveOurCommit)에 있다 ────────────────────────────────
// 이 검증기는 **두 모드가 함께 쓰므로**(주 경로 · `--reconcile-only`의 R-23 패리티) 파일 앞쪽으로
// 올려 두었다. 설계 근거는 그 정의 위의 주석을 참고.
//
// 신뢰 PR의 head 소유권 — **판정과 무관하게 언제나** 확인한다(R-23). skip이어도 확인하는 이유:
// 그 head는 무장(=머지 인가)의 **대상**이다. force-push를 하지 않는다고 해서 남의 커밋에 auto-merge를
// 걸어도 되는 건 아니다 — 인가는 push만큼이나 강력한 변이다.
const headProof: Proof = trusted === null
  ? { ok: true } // 신뢰 PR이 없으면 무장/해제할 대상 자체가 없다(create/adopt는 아래 고아 증명이 맡는다)
  : proveOurCommit(trusted.headRefOid, `신뢰 PR #${trusted.number}의 head`);

// 축 2(무장) — **판정과 직교**하고 **양방향**이다(R-10/R-11 + structure high-1/R-23). 레인 + **소유권**이
// 원하는 무장 상태를 정하고, 관측된 무장 상태를 그쪽으로 **수렴**시킨다(단방향 arm-only는 낡은 인가를 보존한다).
//   lane=bump       의 desired = 무장 **있음** — 단, **증명된 head에 한해서다**
//     · create/adopt = PR을 새로 만든다 → 생성 직후 무장(그 PR엔 무장이 있을 수 없다)
//     · skip/rebuild = 이미 있는 신뢰 PR → 무장이 **없고 head가 우리 것일 때만** 재무장(있으면 손대지 않음 — 멱등)
//   lane=propose-pr 의 desired = 무장 **없음**(사람 머지 = 배포 승인)
//     · 신뢰 PR에 무장이 **남아 있으면**(autoDeploy:true 시절에 열려 무장된 PR이 그대로 열려 있는 경우)
//       → **해제**한다. 판정이 skip이든 rebuild든 똑같다(무장은 PR에 붙지 head OID에 붙지 않는다).
//     · 무장이 없으면 아무것도 하지 않는다(멱등 — 승인 레인의 정상 상태다).
//   **증명되지 않은 head**의 desired = 무장 **없음**(레인 무관 — R-23)
//     · 무장하지 않는다. 이미 무장돼 있으면 **회수한다**. 인가를 거두는 쪽이 언제나 안전한 방향이다.
const createsPr = action === "create" || action === "adopt";
const armGap = trusted !== null && !trusted.autoMerge;
// 증명되지 않은 head엔 절대 무장하지 않는다 — 남의 커밋에 머지 인가를 주는 것과 같다.
const shouldArm = lane === "bump" && (createsPr || (armGap && headProof.ok));
// 낡은 머지 인가(stale authorization) — 무장이 살아 있다.
const staleArm = trusted !== null && trusted.autoMerge;
// 회수 조건은 둘이다: ① 승인 레인(사람 머지 = 배포 승인) ② **증명되지 않은 head**(레인 무관).
const shouldDisarm = staleArm && (lane === "propose-pr" || !headProof.ok);

// ── ③ 변이(원격) — 판정이 허락한 것만, 계약된 argv 그대로 ───────────────────────────────────
// push는 세 경로의 argv가 **완전 형태**로 못박혀 있다(plan r3): 목적지를 `refs/heads/<b>`로 완전 수식하고
// lease는 항상 `<ref>:<기대 OID>` 명시 형태다(bare lease는 원격 추적 참조 없는 checkout에서 stale 거부).
// skip은 여기서 **아무것도 하지 않는다** — 그게 이 픽스의 flip이다(중복 PR 금지).
//
// ── ③-a 해제(인가 회수) = **첫 변이**이자 **abort보다 먼저**다 ─────────────────────────────────
// 두 가지 이유로 맨 앞이다:
//   · 낡은 인가를 들고 있는 시간을 최소화한다. rebuild(force-push)를 먼저 하면 그 push가 체크를 다시 돌려
//     green으로 만들고, 해제하기 전에 GitHub이 **사람 승인 없이** 머지해버릴 수 있다.
//   · 소유권 fail-closed(③-b)보다 먼저다(R-23). 낯선 head + 무장이라는 **최악의 조합**에서, 검증이 먼저
//     죽어버리면 그 인가가 영영 회수되지 않는다 — 가장 회수해야 할 때 회수하지 못하는 셈이다.
// 대상은 브랜치명이 아니라 **관측된 신뢰 PR 번호**다(같은 브랜치명의 포크 PR 오조준 방지).
// 무장(arm)과 달리 공유 스크립트(auto-merge-or-fail.sh)를 쓰지 않는다 — 그 스크립트는 races-6 폴백
// ("--auto는 이미 CLEAN인 PR에 에러" → 직접 머지)이 본질이고, 그건 **머지를 성사시키는** 경로다.
// 해제는 정반대(인가 회수)라 폴백이 있어선 안 된다: 실패하면 fail-closed로 시끄럽게 죽는 게 맞다.
//
// ⚠️ 여기만 **형제 스윕(①-c)의 "계속하되 나중에 빨갛게"와 다르다** — 더 **엄격하다**(R-32의 예외가 아니라 강화다).
//    이 PR의 해제가 실패했는데 그대로 진행하면 바로 다음 줄들이 **그 PR을 force-push**한다 → 그 push가
//    required 체크를 다시 돌려 green으로 만들고, **아직 살아 있는 무장**이 사람 승인 없이 머지를 성사시킨다.
//    형제는 그렇지 않다(우리 브랜치를 밀어도 형제의 체크는 green이 되지 않는다) → 형제만 "계속"이 안전하다.
//    두 경로 모두 **run은 비-0으로 끝난다**(회수 실패 = 보안 사실). 여기선 그 위에 "밀지 않는다"가 더 붙는다.
if (shouldDisarm) {
  mutate("gh", ["pr", "merge", "--disable-auto", String(trusted!.number)], "gh pr merge --disable-auto");
}

// ── ③-c superseded **close 자격**(파괴 — 증거는 전부, 하나라도 모자라면 닫지 않는다) ────────────
// 여기서 **판정만** 한다(close 호출 자체는 맨 마지막 ③-e). 위치가 여기인 이유: 이 판정은 형제마다
// GraphQL 커밋 조회를 한 번씩 때리는 **비싼** 단계다 — 인가 회수(①-c 형제 해제 · ③-a 현 PR 해제)를
// 그 뒤로 미루면 낡은 인가를 들고 있는 시간이 그만큼 늘어난다. **안전 방향 변이가 먼저, 파괴 준비는 뒤.**
// run 전체를 막는 사유가 있으면 형제별 증거 조회조차 하지 않는다(닫지 않을 것을 확인하려고 API를 두드릴 이유가 없다).
//
// ⚠️ 순서 근거는 **PR의 나이**다: T_old와 T 사이엔 git 순서가 없고(빌드 완료 역전·앱 레포 revert),
//    실행기의 writer 토큰으론 앱 레포 compare도 못 한다. `createdAt`은 전순서를 갖는 유일한 관측 사실이고,
//    "**더 나중에 만들어진 PR만 더 오래된 PR을 닫는다**"는 단조 규칙이라 두 실행기가 동시에 돌아도
//    서로를 닫는 flip-flop이 **구조적으로 불가능**하다.
const ourCreatedAt = trusted?.createdAt ?? null;
function siblingIsOlder(s: SiblingState): boolean {
  // create/adopt = 우리 PR을 **지금** 만든다 → 이미 열려 있던 형제는 전부 우리보다 오래됐다.
  if (createsPr) return true;
  if (ourCreatedAt === null || s.createdAt === null) return false; // 나이를 모르면 닫지 않는다
  const ours = Date.parse(ourCreatedAt);
  const theirs = Date.parse(s.createdAt);
  if (Number.isNaN(ours) || Number.isNaN(theirs)) return false;
  return theirs < ours; // **엄격** 부등호 — 동률이면 닫지 않는다(flip-flop 방지)
}
// run 전체를 막는 사유(형제별 증거보다 앞선다).
const closeGate: string | null = !CLOSE_ENABLED
  ? "killswitch(BUMP_PR_CLOSE=off) — 해제만 수행한다"
  : lane !== "bump"
    ? "승인 레인(propose-pr) — 사람의 판단이 그 PR의 존재 이유다(해제까지만, close는 owner 몫)"
    : closeAbandoned !== null
      ? `형제 열거/조회가 불완전하다(${closeAbandoned}) — 이 run의 close는 전부 포기한다`
      : null;
for (const s of siblings) {
  if (s.closeBlocked !== null) continue;            // 이미 사유가 있다(고아 ref·우리 것이 아닌 PR 등)
  if (closeGate !== null) { s.closeBlocked = closeGate; continue; }
  if (!s.trusted) { s.closeBlocked = "신뢰 대상 아님(포크·비-writer·다른 base)"; continue; }
  if (s.humanTouch !== null) { s.closeBlocked = `사람의 흔적: ${s.humanTouch}`; continue; }
  if (!siblingIsOlder(s)) { s.closeBlocked = "우리 PR보다 오래됐음을 증명할 수 없다(createdAt)"; continue; }
  // 마지막이자 가장 비싼 증거: **그 PR 자신의 tag로 재계산한** 커밋 메시지 + writer ident로 head 소유권 증명.
  // 이게 "head가 갈아치워진 우리 PR"과 "접두를 도용한 남의 브랜치"를 동시에 막는 유일한 실질 증거다.
  const proof = proveOurCommit(s.headRefOid!, `형제 PR #${s.number}의 head`, bumpCommitMessageFor(s.tag));
  if (!proof.ok) { s.closeBlocked = `head 소유권 미증명 — ${proof.why}`; continue; }
}

// ── ③-b 소유권 fail-closed — 증명되지 않은 head는 **어떤 변이도** 하지 않는다 ─────────────────
// 여기부터가 "중단 가능한 검사"다. 인가 회수(③-a)는 이미 끝났으므로 안전하게 죽을 수 있다.
if (!headProof.ok) {
  execError(
    `${headProof.why}\n`
    + "  이 head는 우리 것임이 증명되지 않았다 — 무장(머지 인가)도, force-push도, PR 생성도 하지 않는다"
    + (staleArm ? " (기존 무장은 위에서 회수했다)." : "."),
  );
}
// 고아 원격 브랜치(adopt)는 **PR이 없다** → 회수할 인가도 없다. 여기서 바로 fail-closed해도 잃는 게 없다.
// create는 **없는 브랜치**를 만드는 plain push라 덮어쓸 커밋 자체가 없다(검증 대상 없음).
if (action === "adopt") {
  const orphanProof = proveOurCommit(remoteBranch!.oid, "고아 원격 브랜치의 head");
  if (!orphanProof.ok) {
    execError(`${orphanProof.why}\n  그 작업을 force-push로 지우지 않는다.`);
  }
}

if (action === "create") {
  mutate("git", ["push", args.remote, `HEAD:${ref}`], "git push");
} else if (action === "adopt") {
  // 고아 브랜치 접수: 기대값은 **원격에 실제로 있는 OID**(ls-remote 관측값)다.
  mutate("git", ["push", `--force-with-lease=${ref}:${remoteBranch!.oid}`, args.remote, `HEAD:${ref}`], "git push");
} else if (action === "rebuild") {
  // DIRTY 회복: 기대값은 **그 PR의 head OID**(gh pr list 관측값)다 — PR은 재사용하므로 create는 없다.
  mutate("git", ["push", `--force-with-lease=${ref}:${trusted!.headRefOid}`, args.remote, `HEAD:${ref}`], "git push");
}
// ── 변이 대상 PR의 **인증된 셀렉터** = 번호 ────────────────────────────────────────────────────
// 브랜치명은 셀렉터로 쓰면 안 된다: `gh pr merge <branch>`/`gh pr view <branch>`는 **같은 브랜치명의
// 포크 PR**로도 해석될 수 있다(공개 레포 — 아무나 같은 결정적 브랜치명으로 PR을 연다). 그 경로로 무장하면
// **공격자의 PR이 auto-merge된다**. 그래서 무장/해제는 전부 "우리가 인증한 번호"만 지목한다:
//   · skip/rebuild = 조회로 신뢰 판정을 통과한 PR      → trusted.number
//   · create/adopt = 방금 우리가 만든 PR              → gh pr create가 돌려준 URL에서 파싱한 번호
// 공유 스크립트(auto-merge-or-fail.sh)는 인자를 `gh pr merge`/`gh pr view`에 **그대로 넘기는 패스스루**라
// (브랜치명 자체를 쓰는 로직이 없다) 번호를 넘기는 것만으로 모호성이 사라진다 — 스크립트 변경 불필요.
let prNumber: number | null = trusted?.number ?? null;
if (createsPr) {
  prNumber = createPr();
}
// 무장의 입력은 **레인 + 소유권** 둘뿐이다 — propose-pr(승인 레인)은 어떤 경로로도 여기 들어오지 못하고(R-11),
// **증명되지 않은 head**도 여기 오지 못한다(R-23 — 애초에 ③-b에서 죽는다).
// 새 PR이면 생성 직후, 기존 PR이면 무장 갭이 있을 때만(판정이 skip이든 rebuild든) 수렴시킨다(R-10).
if (shouldArm) {
  // 번호를 모르면 **무장하지 않는다**. 브랜치로 폴백하는 순간 위의 모호성이 되살아난다(폴백 금지).
  if (prNumber === null) {
    execError("무장 대상 PR 번호를 모른다 — 브랜치명으로는 무장하지 않는다(동명 포크 PR 오조준)");
  }
  // races-6 폴백(gh pr merge --auto는 이미 CLEAN인 PR에 에러) — 검증된 공유 스크립트를 재사용한다.
  const script = path.join(import.meta.dir, "..", "scripts", "auto-merge-or-fail.sh");
  mutate("bash", [script, String(prNumber)], "auto-merge-or-fail");
}

// ── ③-e superseded **close 스윕** = **맨 마지막 변이**(파괴는 언제나 뒤) ──────────────────────
// close는 제거가 아니라 **교체**다 — **후계자가 확정된 뒤에만** 닫는다(prNumber !== null). 우리 판정이
// fail-closed로 죽었거나 `gh pr create`가 실패했다면 여기 도달하지 못한다 → close 0(열린 제안이 0이 되는
// 상태를 만들지 않는다).
// ⚠️ **브랜치는 지우지 않는다**: `--delete-branch`도, `git push --delete`도 없다. close는 reopen으로
//    되돌아가지만 ref 삭제는 되돌아가지 않는다. 고아 ref는 남겨 둔다(그 tag가 다시 후보가 되면 adopt가 접수).
// ⚠️ **캡**: 후보가 CLOSE_MAX를 넘으면 **한 건도 닫지 않는다** — 접두 파싱 버그 한 글자의 반경을 상수로 묶는다.
const closable = siblings.filter((s) => s.closeBlocked === null && s.number !== null);
if (closable.length > 0 && prNumber === null) {
  warn(`superseded 형제 ${closable.length}건을 닫지 않는다 — 우리 PR이 열려 있지 않다(후계자 없는 제거 금지)`);
  for (const s of closable) s.closeBlocked = "후계자 없음(우리 PR 번호를 확정하지 못했다)";
} else if (closable.length > CLOSE_MAX) {
  warn(
    `superseded close 후보가 ${closable.length}건으로 캡(${CLOSE_MAX})을 넘었다 — **한 건도 닫지 않는다**. `
    + `대상: ${closable.map((s) => `#${s.number}(${s.branch})`).join(", ")}. 파싱 버그를 의심하고 수동 확인할 것`,
  );
  for (const s of closable) s.closeBlocked = `cap 초과(${closable.length} > ${CLOSE_MAX}) — 수동 확인 필요`;
} else {
  for (const s of closable) {
    // ⚠️ 코멘트는 **실제로 작동하는 탈출구**를 말해야 한다(H-3). 예전 문구는 reopen만 안내했는데, 그때는
    //    reopen 이력을 관측하지 않아 **다음 주기(≤10분)가 그 PR을 다시 닫았다** — 사람을 함정으로 안내한 셈이다.
    //    지금은 reopen도 관측하지만(humanTouchOf), **영속적이고 명시적인** 탈출구는 hold 라벨이다:
    //    라벨은 브랜치가 다시 후보가 되든 실행기가 바뀌든 그대로 남는다. 그래서 라벨을 **먼저** 안내한다.
    const holdHint = HOLD_LABELS.map((l) => `\`${l}\``).join(" 또는 ");
    const r = runSoft("gh", [
      "pr", "close", String(s.number),
      "--comment",
      `superseded by #${prNumber} — bump-poll이 이 앱의 후보를 \`${TAG}\`로 갱신했다. `
      + "브랜치는 지우지 않았다.\n\n"
      + `이 PR을 살려 두려면 ${holdHint} 라벨을 붙여라 — 그러면 다음 주기부터 이 스윕이 건드리지 않는다. `
      + "(reopen만 해도 다음 주기는 그 이력을 보고 다시 닫지 않지만, 라벨이 더 명시적이고 오래 간다.)",
    ]);
    if (r.failure !== null) {
      warn(`superseded 형제 PR #${s.number} close 실패 ${r.failure} — 다음 주기가 재시도한다`);
      s.closeBlocked = `close 실패: ${r.failure}`;
      continue;
    }
    s.closed = true;
  }
}

console.log(JSON.stringify({
  action,
  lane, // 배포 승인 레인(입력) — 판정(action)과 다른 축이다
  reason,
  branch,
  observed: {
    // R-36: 출력은 **경계 있게** — 미신뢰 포크 노드 배열은 직렬화하지 않는다(포화 응답이 로그를 노드 수에
    // 비례해 키우지 못하게). 대신 **총계 요약** + **결정에 쓰인 동일-레포 PR**(쓰기 권한 필요 → 경계)만 싣는다.
    summary: {
      totalOpen: mainScan.totalOpen,      // 열린 PR 총수(포크 포함)
      crossRepo: mainScan.crossRepo,      // 포크(cross-repo) 수 — 노드는 접는 즉시 버렸다
      sameRepoTrusted: mainScan.trusted.length,
      sameRepoUntrusted: mainScan.untrustedSameRepo.length,
    },
    // 동일-레포 PR만(진단용 trusted 플래그 포함). 포크는 위 summary.crossRepo로만 관측한다.
    sameRepoPrs,
    trusted: trusted
      ? {
        number: trusted.number,
        mergeStateStatus: trusted.mergeStateStatus,
        headRefOid: trusted.headRefOid,
        // R-10: 무장은 **양방향** desired state다 — bump는 없으면 무장(armGap), propose-pr은 있으면 해제(staleArm).
        autoMerge: trusted.autoMerge,
        // R-23: 그 head가 **우리 bump 커밋임이 증명됐는가**. 무장(머지 인가)의 전제조건이다
        // (증명 실패면 여기까지 오지 못하고 ③-b에서 죽는다 → 이 값은 성공 출력에선 항상 true다).
        headProven: headProof.ok,
        // H-4: 사람의 흔적(있으면 사유). null이 아니면 DIRTY/BEHIND여도 **force-push하지 않는다**.
        humanTouch: trusted.humanTouch,
      }
      : null,
    remoteBranch,
  },
  // R-25: `bump-poll/<app>-*` 네임스페이스의 형제들 — 해제(무조건·안전 방향)와 close(증거 완비 시에만).
  superseded: siblings,
  // R-32: **회수하지 못한 무장**(두 모드가 같은 키로 보고한다). 비어 있지 않으면 아래에서 비-0 종료다.
  revocationFailures,
  executed,
  // R-36: 페이지네이션의 **경계 있는 관측**(정수 하나 — 질의 문자열 배열이 아니다). read-only 페이지
  // 조회는 executed(원장)에 남기지 않으므로, 몇 페이지를 접었는지는 이 카운터로만 관측한다. 포화 응답에서도
  // 직렬화 비용은 O(1)이다 → audit 출력(executed·graphqlPages)은 포크 수에 비례해 커지지 않는다(W70).
  graphqlPages,
}, null, 2));

// ── ③-f 회수 실패 = **보안 사실** → 처리는 다 끝내고, run은 빨갛게 끝낸다(R-32) ──────────────────
// 여기까지 왔다는 건 이번 주기의 메인 변이(push/create/skip + 무장/해제 + close)가 **전부 제 일을 했다**는
// 뜻이다 — 회수 실패가 그것들을 굶기지 않았다(억제 = 공격 표면). 그러나 낡은 머지 인가를 **거두지 못한 채**
// 성공으로 끝나면, 무장된 좀비 PR이 남았는데 아무도 모르는 상태가 된다(telegram 무발화).
// ⚠️ 이 판정은 close의 성공 여부를 **보지 않는다**: 위생(close)의 성공에 보안 사실(회수)의 보고를 매다는 것이
//    바로 R-32의 결함이었다. 회수를 못 했으면 close가 어떻게 됐든 이 run은 실패다.
if (revocationFailures.length > 0) {
  console.error(
    `ensure-bump-pr: auto-merge 회수 ${revocationFailures.length}건 실패 — 낡은 머지 인가가 살아 있다:\n`
    + revocationFailures.map((f) => `  · ${f}`).join("\n")
    + "\n  (이번 주기의 다른 변이는 정상 수행했다. 다음 주기가 회수를 재시도한다.)",
  );
  process.exit(1);
}
