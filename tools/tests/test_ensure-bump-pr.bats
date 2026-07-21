#!/usr/bin/env bats
# ensure-bump-pr — bump PR 멱등 **실행기**(조회 → 결정 → 변이). 같은 bump = 같은 브랜치 = 열린 PR 1개.
#
# 왜 실행 seam인가(plan r2 R-4): 결정만 하는 도구는 GREEN이 돼도 프로덕션은 그대로일 수 있다.
# 이 스위트는 도구가 **실제로 낸 명령**(argv)을 PATH stub으로 가로채 기록하고, 그 기록으로
# ① 순서(조회 → 변이) ② 부작용 유무(skip이면 push·create 0회) ③ 정확한 argv 배열을 단언한다.
# 하네스 관용구는 이 레포의 선례를 따른다 — tests/test_sealed-secrets-restore.bats(kubectl stub),
# tests/gates/test_digest-exporter-producer.bats(skopeo/curl stub).
#
# ── 원장은 **NUL 구분**이다(plan r4 R-9) ────────────────────────────────────────────────────
# 이전 하네스는 argv를 `"$*"`로 **한 줄로 평탄화**해 기록했다. 그래서
#     git push origin HEAD:refs/heads/<b>      (2인자 — 계약)
#     git push "origin HEAD:refs/heads/<b>"    (1인자 — 라이브 git은 'origin HEAD:…' 전체를 remote 이름으로
#                                               읽고 실패한다)
# 이 둘이 **같은 원장 줄**("git push origin HEAD:refs/heads/<b>")이 되어 `grep -Fx` 증인을 나란히 통과했다
# → 인자를 붙여 쓴 구현이 GREEN인데 프로덕션은 아무것도 밀지 못하는 **거짓 GREEN**. lease/remote/refspec을
# 합쳐 쓴 형태도 같은 구멍을 지난다.
# 인자 경계를 보존할 수 있는 유일한 구분자는 NUL(인자에 들어갈 수 없는 유일한 바이트)이다:
#   레코드 = <arg>\0<arg>\0…\0  +  RS(0x1e) 종단   → argc와 각 인자의 경계가 그대로 남는다(빈 인자 포함).
# 계약 매칭·테스트 단언은 전부 **인자 배열 단위**다(문자열 접두/부분 일치 금지).
#   · stub 쪽: argv를 NUL로 이어붙인 바이트열의 hex를 키로 써서 계약 3종과 **정확히 일치**할 때만 통과,
#     그 외 push는 exit 3(붙여 쓴 인자는 0x20 vs 0x00로 키가 갈린다 → 절대 통과 못 한다).
#   · 증인 쪽: python3 원장 파서가 레코드를 배열로 복원해 argc + 각 위치 문자열을 비교한다.
#
# push argv 계약(완전 형태 — plan r3). git stub은 이 셋 말고는 전부 exit 3으로 죽인다:
#   create : git push origin HEAD:refs/heads/<b>
#   rebuild: git push --force-with-lease=refs/heads/<b>:<PR headRefOid> origin HEAD:refs/heads/<b>
#   adopt  : git push --force-with-lease=refs/heads/<b>:<고아 원격 OID> origin HEAD:refs/heads/<b>
# 근거(git-push(1) + bare 원격 실측): `<refname>:<expect>` 명시 형태만이 **원격 추적 참조 없이**(워크플로
# checkout은 main만 가져온다) 동작한다 — "…or we do not even have to have such a remote-tracking branch
# when this form is used". bare lease는 stale 거부, lease 없는 push는 고아와 non-fast-forward 충돌.
#
# ── 레인(--action)과 판정(action)은 **다른 축**이다(plan r5 R-11) ─────────────────────────────
# 레인 = 플래너(poll-ghcr)가 `.bindings.json`의 autoDeploy로 정한 배포 승인 모델이고, 호출부는 그
# `.action`을 **그대로** `--action`으로 넘긴다:
#     bump       (autoDeploy:true)  → auto-merge 무장
#     propose-pr (autoDeploy:false) → **절대 무장하지 않는다**(사람 머지 = 배포 승인)
# 무장을 켜는 **별도 플래그는 없다**(`--auto-merge` 제거) — 있으면 호출부가 두 레인 모두에 무조건
# 넘기는 것만으로 승인 앱이 자동 배포된다. 승인 레인을 무장시키려면 플래너를 속여야 한다(= autoDeploy SSOT).
#
# ── 무장은 "PR 생성 직후 1회"가 아니라 **desired state**다(plan r5 R-10) ──────────────────────
# push+create는 성공했는데 무장이 실패하면(또는 그 사이 프로세스가 죽으면) 원격엔 **무장 안 된 신뢰 PR**이
# 남는다. 다음 폴링은 그걸 신뢰하고 skip → 영원히 무장 없음 → autoDeploy 배포가 **조용히 정지**한다
# (pr-sweeper는 `autoMergeRequest`가 **이미 있는** PR만 다룬다). 그래서 무장 여부를 사실로 관측한다
# (`gh pr list --json autoMergeRequest`).
#
# ★ 무장 계약(정확히) — 무장 축은 **판정 축과 직교**한다:
#     lane=bump      + 신뢰 PR 있음 + 무장 없음 → 그 run의 **판정이 무엇이든**(skip이든 rebuild든) 재무장한다
#     lane=bump      + 신뢰 PR 있음 + 무장 있음 → 손대지 않는다(멱등 — force-push는 무장을 지우지 않는다)
#     lane=bump      + create/adopt(PR을 새로 만듦)  → 생성 직후 무장한다
#     lane=propose-pr                              → **어떤 경우에도 무장하지 않는다**(사람 머지 = 배포 승인)
#   ⚠️ "재무장"을 skip 경로에만 구현하면 **DIRTY + 미무장**(라이브에서 실제로 겹친다: run 1이 무장에서 죽고,
#      이후 main 이동이 그 PR을 충돌시킨다)에서 rebuild만 하고 무장 갭은 그대로 남는다 → W6가 그걸 막는다.
#
# 회귀(test_tags=regression) — 지금 RED:
#   W1 중복 금지  : 신뢰 PR(CLEAN)이 열려 있으면 push·create 0회(skip).  현재: 둘 다 실행 → 중복 PR.
#   W2 DIRTY 회복 : 신뢰 PR이 DIRTY면 위 rebuild argv push 1회 + create 0회.
#                  현재: create → 중복 PR(게다가 lease 없음 → R-5 stale 거부).
#   W3 고아 브랜치: 열린 PR 0 + 원격 브랜치 있음 → 위 adopt argv push + create 1회.
#                  현재: lease 없는 plain push → 고아와 non-fast-forward 충돌 → 배포 정지.
#   W4 재무장     : bump 레인 + 신뢰 PR이 **무장 안 됨** → 무장 1회 + push·create 0회(2-run 수렴).
#                  현재: create 경로 → 중복 PR을 새로 열고 그걸 무장한다(옛 PR의 무장 갭은 그대로).
#   W5 무장 멱등  : bump 레인 + 신뢰 PR이 **이미 무장** → 무장 0회(재무장 금지).
#                  현재: create 경로가 새 PR을 열고 무조건 무장 → 1회.
#   W6 rebuild+재무장: bump + DIRTY + **미무장** → rebuild push 1회 + 무장 1회 + create 0회(두 축 동시).
#                  현재: create 경로 → 중복 PR. (W4만 있으면 재무장을 skip 경로에만 구현해도 GREEN이 된다.)
#   W7 rebuild 멱등  : bump + DIRTY + **이미 무장** → rebuild push 1회 + 무장 0회.
#                  현재: create 경로가 무조건 무장 → 1회. (무장을 rebuild의 부작용으로 매달면 여기서 걸린다.)
#
# ── 파티션의 기준: **픽스 이전 프로덕션에도 있었는가** ──────────────────────────────────────────
# RED baseline = 픽스 이전 bump-poll.yaml의 bump 스텝을 이 seam으로 옮긴 것뿐이다:
#     git push -u origin <b>  →  gh pr create(무조건)  →  (bump 레인) auto-merge-or-fail.sh <b>
# **조회가 없다** — 열린 PR도, 원격 브랜치도, 커밋 소유권도 묻지 않는다. 따라서 판정도, lease도,
# 소유권 증명도, 해제도, fail-closed도 없다.
#
# 보존(태그 없음 — **baseline에서도 GREEN**)은 그래서 딱 이만큼이다:
#   · 하네스 자체의 증명(인자 경계 보존 · 계약 밖 push argv 거부)
#   · bare lease 금지(양 끝단 모두 bare lease를 내지 않는다)
#   · create 경로의 레인 격리(propose-pr은 무장 0 / 무장은 PR 생성 **뒤**)
#   · CLI 표면(레인 필수·기본값 없음 · 알 수 없는 옵션 exit 2 · `--auto-merge` 플래그 부재 · --help)
# 그 밖의 **모든 실행기 계약은 회귀다** — 조회(완전 열거·검색 API 금지·ls-remote·조회-우선 순서)·
# 신뢰 경계·판정(create/adopt/skip/rebuild)·완전 push argv·인가 reconcile(재무장·해제)·소유권·
# fail-closed는 **전부 픽스가 만든다**. baseline엔 존재하지 않으므로 여기서 전부 RED다.
#
# ⚠️ 증인 설계 규칙(이 파티션을 정직하게 유지하는 것): **증상은 원장(argv)만으로 단언한다.**
#    `.observed.*`(=픽스의 조회 설계)를 증상 단언의 **전제조건**으로 두면, 아무것도 조회하지 않는
#    실행기(= 픽스 이전 프로덕션)가 그 가드에서 먼저 죽어 **엉뚱한 이유의 RED**가 된다. 관측 단언은
#    증상 단언 **뒤**에 온다(W1·W3 참고).
#
# ⚠️ 중간 복합 단언 금지([[ ]]·중간 `!`는 bats에서 침묵 통과) → 한 줄에 [ ] 하나씩.
# ⚠️ @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
# ⚠️ `run`은 기본이 stdout+stderr 병합이다 — 자식(git/gh) 출력이 섞이면 결과 JSON을 jq로 못 읽는다
#    (실측: `gh pr create`의 URL 줄이 앞에 붙어 파싱 실패). 결과 JSON을 읽는 곳은 --separate-stderr.
bats_require_minimum_version 1.5.0

# argv 배열의 **정체성 키** — NUL로 이어붙인 바이트열의 hex.
# 셸 변수는 NUL을 담을 수 없다 → hex로 인코딩해야 배열 동일성을 문자열 비교로 옮길 수 있다.
# 붙여 쓴 인자와 나뉜 인자는 여기서 갈린다: 'origin HEAD:…'(…6e **20** 48…) vs 'origin','HEAD:…'(…6e **00** 48…).
argv_key()  { printf '%s\0' "$@" | od -An -v -tx1 | tr -d ' \n'; }
# 사람이 읽는 표기(에러 메시지용) — 인자 경계를 따옴표로 드러낸다.
argv_show() { printf "'%s' " "$@"; echo; }

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1

  APP="page"
  # 배포 핀 tag: sha- + 40 hex (라이브에서 중복 PR 3개를 낸 그 커밋 형태)
  TAG="sha-815abb1$(printf '%033d' 0)"
  BRANCH="bump-poll/${APP}-${TAG}"
  # 열린 PR의 head OID(= DIRTY rebuild lease 기대값) vs 고아 원격 브랜치 OID(= adopt lease 기대값)
  PR_OID="1111111111111111111111111111111111111111"
  ORPHAN_OID="2222222222222222222222222222222222222222"

  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  # stub이 기록하는 argv 원장(NUL 구분) — 호출 순서·인자 경계·횟수의 단일 증거.
  export CALLS="$BATS_TEST_TMPDIR/calls.nul"
  export STUB_PRS="$BATS_TEST_TMPDIR/prs.json"        # gh pr list 가 뱉을 바이트
  export STUB_HEADS="$BATS_TEST_TMPDIR/ls-remote.out" # git ls-remote --heads origin <branch> 가 뱉을 바이트
  # ── superseded 형제(같은 앱, 다른 tag) 픽스처 ────────────────────────────────────────────────
  # STUB_SIBLINGS = `git ls-remote --heads origin`(**네임스페이스 열거** — 브랜치 인자 없음)이 뱉을 바이트.
  # SIB_DIR       = 형제 브랜치별 PR 픽스처(`<head>.json`)와 형제 head 커밋 픽스처(`commit-<oid>.json`).
  # 기본은 **형제 0건** — 기존 증인들은 그대로 "형제 없음" 세계에서 돈다(스윕이 그들을 오염시키지 않는다).
  export STUB_SIBLINGS="$BATS_TEST_TMPDIR/ls-remote-all.out"
  export SIB_DIR="$BATS_TEST_TMPDIR/siblings"
  mkdir -p "$SIB_DIR"
  printf '[]' > "$SIB_DIR/.none.json"   # 픽스처 없는 head = 열린 PR 0건(gh_pages가 읽는다)
  : > "$CALLS"
  printf '[]' > "$STUB_PRS"    # 기본: 열린 PR 0건
  : > "$STUB_HEADS"            # 기본: 원격 브랜치 없음
  : > "$STUB_SIBLINGS"         # 기본: 형제 브랜치 0건

  # ── force-push 대상 커밋의 **소유권** 픽스처(structure r5 high-1) ────────────────────────────
  # 기본값 = **우리 bump 커밋**(라이브 실측 형태) → adopt/rebuild 정상 경로가 그대로 동작한다.
  #   author/committer 정체성은 호출부가 심는 그것과 같다(bump-poll.yaml):
  #     git config user.name  "ukyi-homelab-writer[bot]"
  #     git config user.email "293311924+ukyi-homelab-writer[bot]@users.noreply.github.com"
  #   메시지는 이 bump의 결정적 커밋 메시지다(app·tag까지):
  #     git commit -m "chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)"
  # ⚠️ 라이브 확인: 이 커밋들은 **서명이 없다**(`signature: null` — 토큰 push는 GitHub이 서명하지 않는다).
  #    그러니 이 검증은 **인증이 아니라 안전 인터록**이다: 사고성 파괴(남의 커밋·낯선 브랜치)는 확실히 막지만,
  #    contents:write를 가진 악의적 행위자는 정체성·메시지를 위조할 수 있다(진짜 불변식은 ruleset — 도구 밖).
  export STUB_COMMIT_NAME="ukyi-homelab-writer[bot]"
  export STUB_COMMIT_EMAIL="293311924+ukyi-homelab-writer[bot]@users.noreply.github.com"
  export STUB_COMMIT_MSG="chore: ${APP} 이미지를 ${TAG}(digest 핀)로 갱신 (GHCR 폴링)"

  # ── push argv 계약(완전 형태 3종)을 **배열**로 고정한다. 하네스(stub)와 증인(테스트)이 같은 배열을 본다.
  #    왜 완전 형태인가(plan r3): 접두만 보면 `origin HEAD:refs/heads/<b>`를 빠뜨린 구현도 GREEN이 되는데,
  #    라이브에선 아무것도 밀지 못해(또는 엉뚱한 ref를 밀어) DIRTY/고아 회복이 실패하고 배포가 정지한다.
  #    왜 배열인가(plan r4 R-9): 문자열로 두면 `"origin HEAD:…"`처럼 **붙여 쓴 1인자**가 같은 문자열이 되어
  #    증인을 통과한다(라이브 git은 실패) → argc까지 계약이다.
  #    bare 원격 레포 실측(git 2.50): 목적지 refspec 없는 push는 push.default(=simple) 해석에 맡겨져
  #    lease의 <refname>과 같은 ref라는 보장이 사라진다 → 목적지·lease 모두 refs/heads/로 완전 수식한다.
  #    소스는 HEAD(호출부가 최신 main에서 재구축해 체크아웃해 둔 상태) — 로컬 브랜치명 표기에 의존 0.
  PUSH_CREATE=(git push origin "HEAD:refs/heads/${BRANCH}")
  PUSH_REBUILD=(git push "--force-with-lease=refs/heads/${BRANCH}:${PR_OID}" origin "HEAD:refs/heads/${BRANCH}")
  PUSH_ADOPT=(git push "--force-with-lease=refs/heads/${BRANCH}:${ORPHAN_OID}" origin "HEAD:refs/heads/${BRANCH}")
  # stub이 읽는 계약 키(hex) + 거부 메시지용 표기.
  export C_PUSH_CREATE="$(argv_key "${PUSH_CREATE[@]}")"
  export C_PUSH_REBUILD="$(argv_key "${PUSH_REBUILD[@]}")"
  export C_PUSH_ADOPT="$(argv_key "${PUSH_ADOPT[@]}")"
  export H_PUSH_CREATE="$(argv_show "${PUSH_CREATE[@]}")"
  export H_PUSH_REBUILD="$(argv_show "${PUSH_REBUILD[@]}")"
  export H_PUSH_ADOPT="$(argv_show "${PUSH_ADOPT[@]}")"

  # ── 원장 파서 — NUL/RS를 그대로 다룰 수 있는 도구로 레코드를 **배열로 복원**해 질의한다.
  #    모드: count(접두 일치 레코드 수) / exact(배열 완전 일치 존재?) / first(접두 일치 첫 레코드의 1-기반 순번)
  #          / hasarg(어떤 레코드든 그 **정확한 인자 원소**를 포함?) / dump(사람용 — argc + 따옴표 표기)
  LEDGER_PY="$BATS_TEST_TMPDIR/ledger.py"
  cat > "$LEDGER_PY" <<'PY'
import sys

mode, path = sys.argv[1], sys.argv[2]
want = sys.argv[3:]
raw = open(path, "rb").read()

# 레코드 = NUL로 구분된 인자들 + RS(0x1e) 종단. 각 레코드의 마지막 NUL이 남기는 빈 꼬리만 떼어낸다
# (그 외의 빈 문자열은 **진짜 빈 인자**다 — 경계를 보존해야 하므로 지우지 않는다).
records = []
for chunk in raw.split(b"\x1e"):
    if chunk == b"":
        continue
    fields = chunk.split(b"\x00")
    if fields and fields[-1] == b"":
        fields.pop()
    records.append([f.decode("utf-8", "surrogateescape") for f in fields])


def is_prefix(rec, pre):
    return len(rec) >= len(pre) and rec[: len(pre)] == pre


if mode == "count":
    print(sum(1 for r in records if is_prefix(r, want)))
elif mode == "exact":  # argc + 각 위치 문자열이 모두 같은 레코드가 있는가
    sys.exit(0 if any(r == want for r in records) else 1)
elif mode == "first":
    for i, r in enumerate(records, 1):
        if is_prefix(r, want):
            print(i)
            sys.exit(0)
    sys.exit(1)
elif mode == "hasarg":  # 어떤 레코드든 want[0]과 **정확히 같은 인자 원소**를 갖는가(부분 문자열 아님)
    sys.exit(0 if any(want[0] in r for r in records) else 1)
elif mode == "hassub":  # 어떤 레코드의 **어떤 인자 원소 안에** want[0]이 부분 문자열로 들어 있는가
    # (GraphQL 질의문처럼 한 인자에 통째로 실리는 페이로드의 내용을 검사할 때만 쓴다.)
    sys.exit(0 if any(any(want[0] in a for a in r) for r in records) else 1)
elif mode == "argafter":  # want[0] 플래그 **바로 다음** 인자를 출력(첫 매치) — 예: `gh pr close … --comment <본문>`
    for r in records:
        for i, a in enumerate(r):
            if a == want[0] and i + 1 < len(r):
                print(r[i + 1])
                sys.exit(0)
    sys.exit(1)
elif mode == "hassub2":  # want[0]로 **레코드를 고른 뒤**, want[1]이 그 **같은 레코드** 안에 있는가
    # 두 GraphQL 질의(본 질의 / 형제 질의)가 같은 원장에 함께 있을 때, 어느 질의가 그 필드를 갖는지
    # 구분해야 한다 — hassub은 "아무 레코드에나 있으면 통과"라 한쪽에서 필드가 빠져도 다른 쪽이 가려 준다.
    hits = [r for r in records if any(want[0] in a for a in r)]
    ok = bool(hits) and all(any(want[1] in a for a in r) for r in hits)
    sys.exit(0 if ok else 1)
elif mode == "dump":
    for i, r in enumerate(records, 1):
        print("%2d) argc=%d  %s" % (i, len(r), " ".join(repr(a) for a in r)))
else:
    sys.exit(2)
PY

  # ── gh stub: pr list는 픽스처를 내보내되 **라이브 gh처럼 --limit에서 잘라낸다**, 변이 서브커맨드는 성공만 흉내낸다.
  #    알 수 없는 서브커맨드는 exit 3 — 도구의 gh 표면이 조용히 넓어지는 걸 막는다.
  #
  # ★ 왜 stub이 --limit을 **지켜야** 하는가(structure high-2): 라이브 질의는 경계가 있다.
  #   실측(GH_DEBUG=api): repository.pullRequests(states:$state, headRefName:$headBranch, first:$limit,
  #                                               orderBy:{field: CREATED_AT, direction: DESC})
  #   기본 상한은 **30**이고 `--head`는 owner 한정 필터를 지원하지 않는다 → **공개 포크가 같은 브랜치명으로 연
  #   PR도 같은 페이지를 놓고 경쟁**하고, 최신순 정렬이라 나중에 열린 포크 PR들이 **먼저 열린 writer PR을
  #   페이지 밖으로 밀어낸다**. stub이 픽스처를 통째로 뱉으면 이 절단이 하네스에서 사라져, 경계 없는 조회를
  #   가정한 구현이 GREEN이 된다(라이브에선 자기 PR을 못 보고 고아로 오인 → force-push + 중복 create).
  #   → 픽스처는 **최신순 목록**(앞 = 최신)으로 쓰고, stub은 앞에서 limit개만 준다(라이브와 같은 절단).
  #   비-JSON/비-배열 픽스처(fail-closed 증인)는 자를 수 없으므로 원본 바이트를 그대로 흘린다.
  cat > "$STUB/gh" <<'GH'
#!/bin/sh
# NUL 구분 원장(R-9): 인자 개수·경계 보존. 레코드는 RS(0x1e)로 종단한다.
{ printf '%s\0' gh "$@"; printf '\036'; } >> "$CALLS"

# ── 이 stub은 라이브 gh의 **ref-연결 페이지 조회**를 흉내낸다(structure r12 R-40) ─────────────────
# 도구는 `repository.ref(qualifiedName:$ref).associatedPullRequests` connection을 **한 페이지씩** 소비한다
# (`endCursor` 변수가 가리키는 페이지). 커서 규약(라이브 opaque 커서 흉내): 없음 = 0페이지, "cursorN" = N+1페이지.
# ★ 라이브 실측(gh api graphql): associatedPullRequests는 **head-연결**이라(base=main에도 0건 — 라이브 확인)
#   우리 ref가 head인 same-repo PR만 준다 → 포크(isCrossRepository:true)는 이 응답에 **구조적으로** 들어올 수
#   없다(포크 PR의 head는 포크 레포 ref다). gh_pages가 픽스처에서 포크 노드를 걸러 그 사실을 모델한다 —
#   그래서 질의 작업(페이지 수)이 **포크 수와 무관**하다(R-40). 옛 이름-매치 질의(pullRequests(headRefName))로
#   되돌아가면 stub이 exit 3으로 거부한다(그 질의는 포크가 같은 이름으로 오염시킬 수 있는 취약 표면이다).
gh_pages() {
  f="$1"; shift
  cursor=""
  for a in "$@"; do
    case "$a" in endCursor=*) cursor="${a#endCursor=}" ;; esac
  done
  if [ -z "$cursor" ]; then i=0; else i=$(( ${cursor#cursor} + 1 )); fi
  # ★ 포크 배제: isCrossRepository:true 노드는 라이브 ref-조회에 없으므로 픽스처에서 걸러 낸다(R-40).
  # ★ ref.target.oid(R-43): 라이브 ref-조회는 브랜치 tip OID를 함께 준다 → ls-remote OID와 교차 검증한다.
  #   REF_OID(호출부가 STUB_HEADS에서 유도)를 실어, GraphQL과 ls-remote가 **합의**하는 정상 케이스를 모델한다.
  refoid="${REF_OID:-1111111111111111111111111111111111111111}"
  PAGE='
    map(select(.isCrossRepository != true)) as $all
    | ($all | length) as $n
    | (if $n == 0 then 1 else (($n + 99) / 100 | floor) end) as $np
    | { data: { repository: { ref: { target: { oid: $refoid }, associatedPullRequests: {
          pageInfo: {
            hasNextPage: (if $i < $np - 1 then true else $forcelast end),
            endCursor: (if $i < $np - 1 then "cursor\($i)" else null end)
          },
          nodes: $all[($i * 100):(($i + 1) * 100)]
        } } } } }'
  if out="$(jq -c --argjson i "$i" --argjson forcelast "${FORCE_LAST:-false}" --arg refoid "$refoid" "$PAGE" "$f" 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  # 깨진 JSON·비배열 픽스처(fail-closed 증인)는 쪼갤 수 없다 → ref 봉투에 원본을 그대로 실어 흘린다.
  printf '{"data":{"repository":{"ref":{"target":{"oid":"%s"},"associatedPullRequests":{"pageInfo":{"hasNextPage":%s,"endCursor":null},"nodes":%s}}}}}' \
    "$refoid" "${FORCE_LAST:-false}" "$(cat "$f")"
}

case "$1:$2" in
  api:graphql)
    # 이 stub은 **세 GraphQL 질의**를 흉내낸다 — 질의문(한 인자에 통째로 실린다)으로 갈라낸다.
    #   object(oid:      → 커밋 소유권 조회(COMMIT_QUERY)
    #   mergeStateStatus → 본 PR 질의(PR_QUERY) — 판정에 그 필드가 필요한 **유일한** 질의다
    #   isDraft          → 형제 PR 질의(SIBLING_PR_QUERY)
    # ⚠️ 순서가 계약이다: PR_QUERY도 사람의 흔적(H-4)을 조회하면서 `isDraft`를 갖게 됐다 → `isDraft`로
    #    먼저 갈라내면 **본 질의가 형제 stub으로 오라우팅**되어 "열린 PR 0건"이 되고, 도구가 자기 PR을
    #    고아로 오인해 adopt+create를 낸다(하네스가 만든 거짓 버그 — 실제로 밟았다).
    # ⚠️ 알 수 없는 질의는 exit 3 — 조용한 빈 응답이 다시 그런 오라우팅을 숨기지 못하게.
    q=""
    for a in "$@"; do case "$a" in query=*) q="$a" ;; esac; done

    case "$q" in
      *"object(oid:"*)
        # ── 커밋 소유권 조회(force-push 직전 · superseded 형제 검증) ──────────────────────────
        oid=""
        for a in "$@"; do case "$a" in oid=*) oid="${a#oid=}" ;; esac; done
        # 형제 head 커밋은 **OID별 픽스처**가 있으면 그것을 쓴다(형제마다 기대 메시지가 다르다 —
        # 그 PR 자신의 tag로 재계산한 메시지여야 소유권이 증명된다).
        if [ -f "$SIB_DIR/commit-$oid.json" ]; then cat "$SIB_DIR/commit-$oid.json"; exit 0; fi
        if [ -n "${STUB_COMMIT_FAIL:-}" ]; then echo "stub: 커밋 조회 실패" >&2; exit 1; fi
        if [ -n "${STUB_COMMIT_RAW+set}" ]; then printf '%s' "$STUB_COMMIT_RAW"; exit 0; fi
        # 기본값 = **우리 bump 커밋**(라이브 실측 형태) → 정상 경로(adopt/rebuild)가 그대로 동작한다.
        printf '{"data":{"repository":{"object":{"oid":"%s","message":%s,"author":{"name":"%s","email":"%s"},"committer":{"name":"%s","email":"%s"}}}}}' \
          "$oid" \
          "$(printf '%s' "${STUB_COMMIT_MSG}" | jq -Rs .)" \
          "${STUB_COMMIT_NAME}" "${STUB_COMMIT_EMAIL}" \
          "${STUB_COMMIT_CNAME:-$STUB_COMMIT_NAME}" "${STUB_COMMIT_CEMAIL:-$STUB_COMMIT_EMAIL}"
        ;;
      *mergeStateStatus*)
        # ── 본 PR 열거(PR_QUERY) ──────────────────────────────────────────────────────────
        # mergeStateStatus는 **판정(create/adopt/skip/rebuild)에만** 필요하다 → 본 질의의 지문이다.
        # ★ R-40: 반드시 **ref-연결 질의**(associatedPullRequests)여야 한다. 옛 이름-매치(pullRequests(headRefName))로
        #   되돌아가면 포크가 같은 브랜치명으로 이 connection을 오염시킬 수 있다 → 그런 질의는 라이브가 우리 ref로
        #   주는 응답이 아니므로 stub이 거부한다(exit 3 → 도구 fail-closed). "포크 배제는 구조적"의 하네스 절반이다.
        case "$q" in
          *associatedPullRequests*) : ;;
          *) echo "stub gh: 본 질의가 ref-연결(associatedPullRequests)이 아니다 — 이름-매치 질의는 포크가 오염시킨다(R-40): $q" >&2; exit 3 ;;
        esac
        if [ -n "${STUB_GH_LIST_FAIL:-}" ]; then echo "stub: gh api graphql 실패(조회 장애 시뮬)" >&2; exit 1; fi
        # ref === null = 우리 브랜치가 원격에 없다(라이브 응답: {repository:{ref:null}}) → 도구는 "우리 것 PR 0건"으로
        # 접는다. **STUB_REF_NULL은 강제 부재**(R-43 불일치 증인 W75: ls-remote는 브랜치를 보고하는데 GraphQL만
        # ref:null인 stale/저하 뷰를 재현한다 → 도구는 fail-closed여야 한다).
        if [ -n "${STUB_REF_NULL:-}" ]; then printf '{"data":{"repository":{"ref":null}}}'; exit 0; fi
        if [ -n "${STUB_GRAPHQL_RAW+set}" ]; then printf '%s' "$STUB_GRAPHQL_RAW"; exit 0; fi
        # ★ ref 존재는 ls-remote(STUB_HEADS)와 **합의**한다(R-43): 브랜치가 heads에 있으면 그 OID로 ref 존재,
        #   없으면서 STUB_PRS가 **유효하게 비었으면** ref:null(둘 다 부재 → create). same-repo PR이 있으면 브랜치는
        #   반드시 존재하므로(라이브 불변) ref 존재로 친다(그 영역은 cross-check에 닿지 않는다 — trusted≠null).
        #   ⚠️ 깨진 JSON 픽스처(prcount 빈값)는 ref:null로 접지 않는다 — gh_pages 폴백으로 흘려보내 fail-closed시킨다.
        refarg=""; for a in "$@"; do case "$a" in ref=*) refarg="${a#ref=}" ;; esac; done
        refoid="$(awk -v r="$refarg" '$2==r{print $1; exit}' "$STUB_HEADS" 2>/dev/null)"
        prcount="$(jq 'map(select(.isCrossRepository != true)) | length' "$STUB_PRS" 2>/dev/null)"
        if [ -z "$refoid" ] && [ "$prcount" = "0" ]; then printf '{"data":{"repository":{"ref":null}}}'; exit 0; fi
        # ★ 라이브처럼 **first:100 페이지 경계**로 쪼갠다: 첫 페이지만 소비하는 구현이 통과하면 안 된다.
        # STUB_REF_OID: GraphQL ref.target.oid를 ls-remote와 **다르게** 강제하는 훅(R-43 OID-상이 불일치 증인 W77).
        REF_OID="${STUB_REF_OID:-${refoid:-$PR_OID}}" FORCE_LAST="${STUB_HAS_NEXT_PAGE:-false}" gh_pages "$STUB_PRS" "$@"
        ;;
      *isDraft*)
        # ── 형제 PR 조회(SIBLING_PR_QUERY — ref별 exact 질의) ──────────────────────────────
        # 본 질의와 달리 mergeStateStatus가 없다(형제는 판정 대상이 아니라 회수·close 대상이다).
        # ★ 이 질의도 **ref-연결**이라(R-40) 형제 브랜치명이 공개여도 포크가 같은 head로 연 PR은 회수 경로의
        #   열거에 구조적으로 들어오지 못한다 — 그래서 회수의 질의 작업도 포크 수와 무관하다(W71).
        case "$q" in
          *associatedPullRequests*) : ;;
          *) echo "stub gh: 형제 질의가 ref-연결(associatedPullRequests)이 아니다(R-40): $q" >&2; exit 3 ;;
        esac
        if [ -n "${STUB_SIB_FAIL:-}" ]; then echo "stub: 형제 PR 조회 실패(조회 장애 시뮬)" >&2; exit 1; fi
        # ★ R-43 불일치: 형제 ref는 `git ls-remote`가 **존재를 보고했기에** 회수 대상이 됐는데, ref-조회가
        #   ref:null(부재)을 주면 두 읽기가 어긋난 것이다(stale/저하 뷰·재생성) → observeBranchPr가 fail-closed
        #   → revocationBlind(무장 여부를 모르는데 조용히 넘어가지 않는다). STUB_SIB_REF_NULL로 그 상태를 재현한다.
        if [ -n "${STUB_SIB_REF_NULL:-}" ]; then printf '{"data":{"repository":{"ref":null}}}'; exit 0; fi
        ref=""
        for a in "$@"; do case "$a" in ref=*) ref="${a#ref=}" ;; esac; done
        branch="${ref#refs/heads/}"
        f="$SIB_DIR/$(printf '%s' "$branch" | tr '/' '_').json"
        if [ ! -f "$f" ]; then f="$SIB_DIR/.none.json"; fi   # 그 ref에 열린 PR 0건(형제 ref는 ls-remote에 있으므로 존재한다)
        # ★ R-44: 형제 GraphQL ref.target.oid는 그 형제의 **실제 ls-remote OID**(STUB_SIBLINGS)에서 유도한다 —
        #   111 기본값을 쓰면 ls-remote(333…)와 어긋나 정상 케이스가 거짓 불일치가 된다(또는 갭을 가린다).
        #   STUB_SIB_REF_OID로 그 OID를 **일부러 어긋나게** 강제하면 reconcile OID-불일치 증인이 된다.
        sibref="$(awk -v r="$ref" '$2==r{print $1; exit}' "$STUB_SIBLINGS" 2>/dev/null)"
        REF_OID="${STUB_SIB_REF_OID:-${sibref:-$SIB_OID}}" FORCE_LAST=false gh_pages "$f" "$@"
        ;;
      *)
        # 알 수 없는 GraphQL 질의 — **조용한 빈 응답을 주지 않는다**. 질의문이 드리프트해 stub의
        # 라우팅이 어긋나면(실제로 밟았다: PR_QUERY가 isDraft를 갖게 되면서 형제 stub으로 새어 갔다)
        # 도구는 "열린 PR 0건"을 보고 자기 PR을 고아로 오인한다 → 하네스가 **거짓 버그**를 만든다.
        echo "stub gh: 알 수 없는 GraphQL 질의(라우팅 드리프트): $q" >&2
        exit 3
        ;;
    esac
    ;;
  # gh pr create는 만든 PR의 **URL**을 stdout에 낸다 → 도구가 거기서 번호를 파싱해 무장 셀렉터로 쓴다.
  # STUB_GH_CREATE_OUT으로 출력 형식 드리프트(번호 파싱 불가)를 주입할 수 있다(fail-closed 증인).
  pr:create) printf '%s\n' "${STUB_GH_CREATE_OUT-https://github.com/ukyi/homelab/pull/999}" ;;
  # ── 해제(--disable-auto) 실패 주입(R-32) ──────────────────────────────────────────────────────
  # 라이브의 해제 실패(API 5xx·레이스·권한 회수)는 드물지만 일어난다. 그때 **"회수하지 못했다"는 사실이
  # 조용히 묻히는가**(exit 0)를 실측하려면 **특정 PR의 해제만** 죽일 수 있어야 한다 — 전부 죽이면 주 경로의
  # 해제(③-a)까지 같이 죽어 **다른 이유의 RED**가 된다(그건 이 증인이 겨냥하는 결함이 아니다).
  # ⚠️ 무장(--auto)은 건드리지 않는다: 이 주입은 `--disable-auto` + 그 PR 번호가 argv에 **둘 다** 있을 때만 문다.
  pr:merge)
    if [ -n "${STUB_DISARM_FAIL_PR:-}" ]; then
      da=""
      for a in "$@"; do
        case "$a" in --disable-auto) da=1 ;; esac
      done
      if [ -n "$da" ]; then
        for a in "$@"; do
          if [ "$a" = "$STUB_DISARM_FAIL_PR" ]; then
            echo "stub: gh pr merge --disable-auto $a 실패(주입 — API 장애)" >&2
            exit 1
          fi
        done
      fi
    fi
    ;;
  pr:view)   echo CLEAN ;;
  # superseded 형제 close. ⚠️ **브랜치 삭제는 계약 밖이다**(close는 reopen으로 되돌아가지만 ref 삭제는
  # 되돌아가지 않는다) → `--delete-branch`가 붙은 형태는 exit 3으로 죽인다(라이브 성공이 아니라 하네스 거부).
  pr:close)
    if [ -n "${STUB_GH_CLOSE_FAIL:-}" ]; then echo "stub: gh pr close 실패" >&2; exit 1; fi
    for a in "$@"; do
      case "$a" in
        --delete-branch|-d) echo "stub gh: 계약 밖 argv — bump-poll 브랜치는 어떤 경우에도 삭제하지 않는다: $*" >&2; exit 3 ;;
      esac
    done
    ;;
  *) echo "stub gh: 예상치 못한 호출: $*" >&2; exit 3 ;;
esac
GH

  # ── git stub: ls-remote만 픽스처를 내보내고, **push는 계약된 정확한 argv 배열에만** 성공한다.
  #    계약 밖 push(목적지 refspec 누락·bare lease·엉뚱한 ref/OID·plain force·**인자를 붙여 쓴 형태** 등)는
  #    exit 3 — "하네스가 거부한 호출"이지 프로덕션 성공이 아니다. 이게 없으면 argv를 빼먹거나 붙여 쓴
  #    구현이 GREEN이 된다(R-9의 정확한 실패 모드).
  #    알 수 없는 git 서브커맨드도 exit 3 — 도구의 git 표면(fetch 후 bare lease 같은 우회)이 조용히
  #    넓어지는 걸 막는다(gh stub의 unknown-subcommand 처리와 동형).
  cat > "$STUB/git" <<'GIT'
#!/bin/sh
{ printf '%s\0' git "$@"; printf '\036'; } >> "$CALLS"
# argv 배열의 정체성 키(hex of NUL-join) — 셸 변수는 NUL을 못 담으므로 hex로 옮긴다.
# 'origin HEAD:…'(한 인자)와 'origin','HEAD:…'(두 인자)는 여기서 0x20 vs 0x00으로 갈린다.
argv_key() { printf '%s\0' "$@" | od -An -v -tx1 | tr -d ' \n'; }
# 거부 메시지에서 인자 경계를 따옴표로 드러낸다(붙여 쓴 인자가 눈에 보이게).
argv_show_sh() { printf "'%s' " "$@"; echo; }
case "$1" in
  ls-remote)
    # 두 질의를 구분한다(argc):
    #   git ls-remote --heads <remote> <branch>  (argc 4) → 이 bump의 원격 브랜치 존재/OID
    #   git ls-remote --heads <remote>           (argc 3) → `bump-poll/*` **네임스페이스 열거**(형제 스윕)
    # ⚠️ 실행기는 열거에 **glob 패턴을 넘기지 않는다** — ls-remote의 패턴 매칭 의미에 열거 완전성을 걸면
    #    과소 열거 = 해제 누락(= R-25 재발)이 된다. 그 계약을 여기서 argc로 고정한다.
    if [ "$#" -ge 4 ]; then
      if [ -n "${STUB_GIT_LSREMOTE_FAIL:-}" ]; then echo "stub: git ls-remote 실패(원격 장애 시뮬)" >&2; exit 1; fi
      if [ -f "$STUB_HEADS" ]; then cat "$STUB_HEADS"; fi
    else
      if [ -n "${STUB_GIT_SIBLINGS_FAIL:-}" ]; then echo "stub: git ls-remote(네임스페이스) 실패" >&2; exit 1; fi
      if [ -f "$STUB_SIBLINGS" ]; then cat "$STUB_SIBLINGS"; fi
    fi
    ;;
  push)
    got="$(argv_key git "$@")"
    if [ "$got" = "$C_PUSH_CREATE" ]; then exit 0; fi
    if [ "$got" = "$C_PUSH_REBUILD" ]; then exit 0; fi
    if [ "$got" = "$C_PUSH_ADOPT" ]; then exit 0; fi
    echo "stub git: 계약 밖 push argv(라이브에선 밀리지 않거나 엉뚱한 ref를 민다):" >&2
    echo "  받음(argc=$#): $(argv_show_sh git "$@")" >&2
    echo "  허용: $H_PUSH_CREATE" >&2
    echo "  허용: $H_PUSH_REBUILD" >&2
    echo "  허용: $H_PUSH_ADOPT" >&2
    exit 3
    ;;
  *) echo "stub git: 예상치 못한 호출: $*" >&2; exit 3 ;;
esac
exit 0
GIT

  # ── bash stub: **pass-through**(원장에 기록한 뒤 진짜 bash로 exec) ─────────────────────────
  #    auto-merge 무장의 레포 관용구는 "도구가 `scripts/auto-merge-or-fail.sh`를 부른다"이다
  #    (races-6 폴백 — `gh pr merge --auto`는 이미 CLEAN인 PR에 에러를 낸다 — 을 재구현하지 않는다).
  #    그래서 **그 스크립트 호출 자체**가 원장에 남아야 "무장했는가 / 몇 번 했는가"를 셀 수 있다.
  #    왜 pass-through(죽은 stub이 아니라)인가: 스크립트를 **실제로 실행**해야 그 안의
  #    `gh pr merge --auto --squash <b>`가 gh stub에 걸린다 = 무장이 GitHub 표면까지 닿았다는 증거.
  #    죽은 stub이면 도구가 스크립트를 부르기만 하고 스크립트가 아무것도 안 해도 GREEN이 된다.
  #    또한 bats 내부/보조 도구의 다른 bash 사용도 그대로 통과시킨다(하네스가 자기 발을 쏘지 않는다).
  cat > "$STUB/bash" <<'BASH'
#!/bin/sh
if [ -n "${CALLS:-}" ]; then { printf '%s\0' bash "$@"; printf '\036'; } >> "$CALLS"; fi
exec /bin/bash "$@"
BASH

  chmod +x "$STUB/gh" "$STUB/git" "$STUB/bash"
  export PATH="$STUB:$PATH"

  # 도구가 부르는 공유 무장 스크립트의 절대 경로(도구는 path.join(import.meta.dir,"..","scripts",…)로
  # 정규화한 같은 경로를 만든다) — 원장 질의의 기대 argv다.
  AUTOMERGE_SH="$ROOT/scripts/auto-merge-or-fail.sh"

  # ── autoDeploy SSOT 픽스처 루트(--reconcile-only 전용 — H-1) ──────────────────────────────────
  # reconcile 패스의 레인은 플래너가 아니라 **파일**에서 온다(noop/refuse 주기엔 플래너가 레인을 말해주지
  # 않기 때문이다 — `.action`이 "noop"인 건 "승인 레인"이라는 뜻이 아니라 "후보가 없다"는 뜻이다).
  # 기본값은 **파일 없음** = SSOT를 읽을 수 없는 상태다(fail-closed 증인이 그대로 쓴다).
  SSOT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$SSOT_ROOT"
}

# apps 레인의 SSOT — apps/<app>/deploy/prod/.bindings.json (poll-ghcr.ts가 읽는 바로 그 경로)
write_bindings() {
  mkdir -p "$SSOT_ROOT/apps/$APP/deploy/prod"
  printf '%s' "$1" > "$SSOT_ROOT/apps/$APP/deploy/prod/.bindings.json"
}
# 베스포크 핀 레인의 SSOT — platform/<comp>/prod/.image-pin.json (autoDeploy가 여기 산다)
write_image_pin() {
  mkdir -p "$SSOT_ROOT/platform/$APP/prod"
  printf '%s' "$1" > "$SSOT_ROOT/platform/$APP/prod/.image-pin.json"
}
# 인가 회수 전용 패스 — **후보(tag)도, 레인 인자도, 대상 앱도 넘기지 않는다**(그게 이 모드의 요점이다).
# ★ `--app`이 없다(R-27): 대상은 `bump-poll/*` **네임스페이스**(git ls-remote)가 권위이고 app은
#   브랜치명에서 유도된다. 호출부가 대상 목록을 정하면 그 목록의 출처(플래너)가 죽는 순간 회수가 굶는다.
run_reconcile() {
  run --separate-stderr bun tools/ensure-bump-pr.ts --reconcile-only --root "$SSOT_ROOT"
  # ⚠️ bats의 `run`은 호출할 때마다 $output/$status를 **덮어쓴다** — 원장 질의(`run disarm_calls …`)를
  #    한 번이라도 하면 $status는 그 질의의 것이 된다. 종료 코드도 결과 JSON처럼 **보존**해야 단언이 산다.
  JSON="$output"
  RCODE="$status"
}
# 다른 앱의 SSOT(교차-앱 증인용) — reconcile은 앱마다 레인을 **따로** 푼다.
write_bindings_for() {
  mkdir -p "$SSOT_ROOT/apps/$1/deploy/prod"
  printf '%s' "$2" > "$SSOT_ROOT/apps/$1/deploy/prod/.bindings.json"
}

# writer App 작성자의 **GraphQL 라이브 표기**(실측 — 이 레포의 실제 bump PR #350):
#   {"login":"ukyi-homelab-writer","__typename":"Bot"}
# ★★ 표기는 표면마다 다르다 — 이걸 틀리면 신뢰 판정이 조용히 0이 되어 중복 PR이 되살아난다:
#     gh pr list → "app/ukyi-homelab-writer"(is_bot:true) / REST → "ukyi-homelab-writer[bot]"
#     GraphQL    → "ukyi-homelab-writer"(__typename:"Bot")   ← 도구가 쓰는 표면
# ★★ __typename은 **신뢰 조건**이다: 봇 계정의 실제 login은 `<slug>[bot]`이므로 `<slug>` 그대로의
#    **사람 계정**이 존재할 수 있다 → login만 보면 사칭이 가능하다(아래 사칭 증인이 이걸 고정한다).
writer_author() { printf '{"login":"ukyi-homelab-writer","__typename":"Bot"}'; }
human_author()  { printf '{"login":"%s","__typename":"User"}' "${1:-drive-by}"; }

# GraphQL `autoMergeRequest{ enabledAt }`의 라이브 실측:
#   무장 안 됨 → null            무장 됨 → {"enabledAt":"2026-07-13T06:35:20Z"}
# 무장 여부의 유일한 신호는 **null 여부**다(내부 필드는 판정에 쓰지 않는다 — 무장은 있거나 없거나).
amr_armed()  { printf '{"enabledAt":"2026-07-13T06:35:20Z"}'; }
amr_absent() { printf 'null'; }

# ── 본 PR 질의(PR_QUERY)의 **원시 스키마** 그대로 픽스처를 심는다 ──────────────────────────────
# ★ 라이브 응답은 **질의한 필드를 전부** 담는다. PR_QUERY가 사람의 흔적(H-4: isDraft·reviews·
#   reviewRequests·assignees·comments·labels·timelineItems[REOPENED_EVENT])까지 조회하므로 픽스처도
#   그래야 한다. 기존 픽스처가 뜻하는 바는 "**사람의 흔적 0**"이니, 여기서 그 기본값을 채운다.
#   명시 필드가 이긴다(`$d + .`) → 흔적을 심는 증인은 그 키만 직접 준다.
# ⚠️ jq가 실패하는 픽스처(깨진 JSON·비배열 — fail-closed 증인)는 **원본 바이트 그대로** 흘린다.
#    그래야 "malformed JSON은 fail-closed" 같은 증인이 하네스에 의해 조용히 고쳐지지 않는다.
# ⚠️ `comments`/`labels`는 **경계된 연결**이다(first:100 / first:50) → 라이브 응답은 `totalCount`를 함께
#    준다. 그게 잘림의 유일한 신호다(R-28): totalCount > 받은 nodes 수 = **첫 페이지 밖에 무언가 있다**.
#    기본 픽스처의 뜻은 "사람의 흔적 0 · **잘림 없음**"이므로 totalCount 0을 명시한다.
HUMAN_NONE='{"isDraft":false,"labels":{"totalCount":0,"nodes":[]},"assignees":{"totalCount":0},"reviewRequests":{"totalCount":0},"reviews":{"totalCount":0},"comments":{"totalCount":0,"nodes":[]},"timelineItems":{"totalCount":0}}'
write_prs() {
  local out
  if out="$(printf '%s' "$1" | jq -c --argjson d "$HUMAN_NONE" 'map($d + .)' 2>/dev/null)"; then
    printf '%s' "$out" > "$STUB_PRS"
  else
    printf '%s' "$1" > "$STUB_PRS"
  fi
}
# 사람의 흔적 필드를 **의도적으로 빼는** 드리프트 증인 전용(정규화 없이 바이트 그대로).
write_prs_raw() { printf '%s' "$1" > "$STUB_PRS"; }
# git ls-remote --heads origin <branch> 의 원시 출력("<oid>\trefs/heads/<branch>").
#
# ★ 픽스처 불변식(structure r3): **열린 동일-레포 PR이 있으면 그 브랜치는 이 레포에 존재한다.**
#   `isCrossRepository:false`인 PR의 head는 우리 레포의 ref일 수밖에 없다(포크와 달리 남의 레포에 못 둔다).
#   그러니 동일-레포 PR을 주입하는 픽스처는 **반드시 write_heads도 함께** 준다. 이걸 빠뜨리면
#   "PR은 있는데 브랜치는 없다"는 **프로덕션에 존재할 수 없는 상태**를 테스트하게 되고, 바로 그 틈에
#   adopt(force-push) 경로가 숨는다 — 실제로 그렇게 숨어 있었다(비-writer 증인이 남의 브랜치를 덮어쓰는
#   파괴 경로를 통과시켰다). 반대로 **포크 PR만** 있는 경우엔 우리 레포에 그 브랜치가 없을 수 있다
#   (포크의 head는 자기 레포 ref다) → 그때만 write_heads를 생략한다.
write_heads() { printf '%s\t%s\n' "$1" "refs/heads/$BRANCH" > "$STUB_HEADS"; }

# 신뢰 PR(동일-레포 + writer App Bot + base=main) 한 건의 GraphQL 노드 — number / state / 무장 / base가 갈린다.
# base 기본값은 main(도구의 --base 기본값) — 4번째 인자로 **다른 base**를 주면 "우리 PR이 아닌" 노드가 된다.
# 5번째 인자(jq 필터)로 그 위를 덮어쓴다 — 사람의 흔적(H-4)을 심을 때 쓴다(예: '.reviews.totalCount=1').
# 흔적 필드의 기본값은 write_prs가 채운다(= 흔적 0) → 여기서 명시한 키만 그 기본값을 이긴다.
writer_pr() {
  printf '{"number":%s,"isCrossRepository":false,"mergeStateStatus":"%s","headRefOid":"%s","baseRefName":"%s","author":%s,"autoMergeRequest":%s}' \
    "$1" "$2" "$PR_OID" "${4:-main}" "$(writer_author)" "$3" | jq -c "${5:-.}"
}

# ── 포크 크라우딩 픽스처 — **경계된 조회**를 공격하는 형태(structure high-2) ────────────────────────
# 이 레포는 공개다 → 아무나 포크에서 **같은 결정적 브랜치명**(bump-poll/<app>-<tag>)으로 PR을 열 수 있다.
# 라이브 질의는 최신순(CREATED_AT DESC)으로 `first: $limit`만 가져오므로, **나중에 열린 포크 PR**들이
# 앞을 차지하고 **먼저 열린 writer PR**을 페이지 밖으로 밀어낸다 → 실행기가 자기 PR을 못 보고
# "고아 브랜치"로 오인해 force-push + 중복 create를 낸다(공격자에 의한 멱등성 파괴).
# 픽스처는 그 최신순 목록 그대로다: 포크 n건(앞 = 최신) + writer PR(뒤 = 가장 먼저 열림).
crowded_prs() {
  local n="$1" tail_pr="$2" i=0
  printf '['
  while [ "$i" -lt "$n" ]; do
    [ "$i" -eq 0 ] || printf ','
    printf '{"number":%d,"isCrossRepository":true,"mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"main","author":%s,"autoMergeRequest":null}' \
      "$((9000 + i))" "$ORPHAN_OID" "$(human_author "drive-by$i")"
    i=$((i + 1))
  done
  if [ -n "$tail_pr" ]; then
    [ "$n" -eq 0 ] || printf ','
    printf '%s' "$tail_pr"
  fi
  printf ']'
}

# ── R-40 이후: 포화 바이트 픽스처/캡처-경계 헬퍼는 사라졌다 ─────────────────────────────────────
# 옛 W70/W71은 포크로 **응답 총 바이트**를 부풀려 subprocess 캡처 경계(R-33)를 넘겼다. 이제 조회가
# ref-연결(associatedPullRequests)이라 포크는 응답에 **구조적으로** 없다 → 응답 크기가 포크 수와 무관하고
# 캡처 경계는 공격자가 닿을 수 없다. 그래서 fat_fork_prs·capture_bound·assert_crosses_capture_bound는
# 삭제했다(도구의 MAX_CAPTURE는 심층 방어로 남는다 — 이제 포크는 그 상한을 채울 수 없다).
# 포화는 여전히 crowded_prs(포크 노드 수)로 표현하고, 새 W70/W71은 **질의 작업이 포크 수와 무관**함을 단언한다.

# ── 무장 **해제**(gh pr merge --disable-auto <번호>) 횟수 ──────────────────────────────────────
# 대상은 브랜치명이 아니라 **관측된 신뢰 PR 번호**다 — `gh pr merge <branch>`는 같은 브랜치명의 포크 PR로
# 오조준될 수 있다. 그래서 argv 배열을 **번호까지** 못박는다.
disarm_calls() { count_calls gh pr merge --disable-auto "$1"; }
# 무장·해제를 합친 총 `gh pr merge` 호출 수(어느 쪽도 몰래 새지 않았는지 교차 검증).
merge_calls()  { count_calls gh pr merge; }

# ── superseded 형제 픽스처 ────────────────────────────────────────────────────────────────────
# 형제 브랜치명(같은 앱, **다른** tag) — 이 앱의 옛 후보가 남긴 브랜치다.
SIB_TAG="sha-9999999$(printf '%033d' 0)"
SIB_BRANCH_OF()  { echo "bump-poll/${APP}-${1:-$SIB_TAG}"; }
SIB_OID="3333333333333333333333333333333333333333"

# 형제 PR 노드(GraphQL 원시 스키마) — 기본은 **닫아도 되는 형태**(동일-레포 · writer Bot · base=main ·
# draft 아님 · 리뷰/코멘트/assignee/리뷰어요청/라벨 0 · **reopen 이력 0**). 5번째 인자로 jq 필터를 주면
# 그 위를 덮어쓴다(예: '.isCrossRepository=true' → 포크 / '.reviews.totalCount=1' → 사람 리뷰 /
# '.timelineItems.totalCount=1' → 사람이 reopen한 PR).
# createdAt은 close의 **유일한 순서 근거**다(T_old와 T 사이엔 git 순서가 없다).
# ★ timelineItems = `timelineItems(itemTypes:[REOPENED_EVENT], last:1){ totalCount }`의 응답(H-3).
#   reopen은 author·createdAt·head를 **하나도 바꾸지 않고**, 그 PR의 유일한 코멘트는 우리 봇의 close 코멘트다
#   → 이 필드가 없으면 사람이 되살린 PR을 다음 주기가 **조용히 다시 닫는다**(영원히).
sib_node() {
  local number="$1" oid="$2" created="$3" armed="$4" filter="${5:-.}"
  printf '{"number":%s,"isCrossRepository":false,"isDraft":false,"createdAt":"%s","headRefOid":"%s","baseRefName":"main","author":{"login":"ukyi-homelab-writer","__typename":"Bot"},"autoMergeRequest":%s,"labels":{"totalCount":0,"nodes":[]},"assignees":{"totalCount":0},"reviewRequests":{"totalCount":0},"reviews":{"totalCount":0},"comments":{"totalCount":0,"nodes":[]},"timelineItems":{"totalCount":0}}' \
    "$number" "$created" "$oid" "$armed" | jq -c "$filter"
}

# 형제 브랜치를 **네임스페이스 열거**(git ls-remote --heads origin)에 등록하고 그 head의 열린 PR을 심는다.
add_sibling() {
  local sbranch="$1" oid="$2" node="$3"
  printf '%s\t%s\n' "$oid" "refs/heads/$sbranch" >> "$STUB_SIBLINGS"
  if [ -n "$node" ]; then
    printf '[%s]' "$node" > "$SIB_DIR/$(printf '%s' "$sbranch" | tr '/' '_').json"
  else
    printf '[]' > "$SIB_DIR/$(printf '%s' "$sbranch" | tr '/' '_').json"   # 고아 ref(열린 PR 0건)
  fi
}
# 그 형제 head 커밋의 소유권 픽스처. 기본 = **그 형제 자신의 tag로 계산한 우리 bump 커밋**(닫아도 되는 형태).
sibling_commit() {
  local oid="$1" msg="$2"
  local name="${3:-ukyi-homelab-writer[bot]}"
  local email="${4:-293311924+ukyi-homelab-writer[bot]@users.noreply.github.com}"
  printf '{"data":{"repository":{"object":{"oid":"%s","message":%s,"author":{"name":"%s","email":"%s"},"committer":{"name":"%s","email":"%s"}}}}}' \
    "$oid" "$(printf '%s' "$msg" | jq -Rs .)" "$name" "$email" "$name" "$email" \
    > "$SIB_DIR/commit-$oid.json"
}
# 그 형제의 결정적 bump 커밋 메시지(실행기의 BUMP_COMMIT_MESSAGE와 **글자 그대로** 같은 형태 — 단 tag가 다르다).
sib_commit_msg() { echo "chore: ${APP} 이미지를 ${1}(digest 핀)로 갱신 (GHCR 폴링)"; }

# close 호출 수(대상은 **인증된 PR 번호** — 브랜치 셀렉터 금지).
close_calls()        { count_calls gh pr close "$1"; }
close_calls_total()  { count_calls gh pr close; }
# close 코멘트 본문(원장에서 `--comment` **바로 다음 인자**를 되읽는다) — 탈출구 안내가 진실인지 본다(H-3).
close_comment()      { python3 "$LEDGER_PY" argafter "$CALLS" --comment; }
# 실행기가 `gh pr update-branch`를 **한 번이라도** 냈는가(내면 head가 머지 커밋이 되어 소유권 증명이 영구 파괴된다).
update_branch_calls() { count_calls gh pr update-branch; }

# 레인(--action)은 **필수**다 — 기본값이 없다(승인 게이트 우회 방지, plan r5 R-11).
# 테스트 기본 레인은 bump(autoDeploy) — 라이브에서 중복 PR 3개가 터진 바로 그 레인이다.
run_ensure_lane() {
  run --separate-stderr bun tools/ensure-bump-pr.ts --app "$APP" --tag "$TAG" --action "$1" \
    --title "chore: ${APP} 이미지 갱신 (자동)" --body "GHCR 폴링 bump"
  # ⚠️ bats의 `run`은 **호출할 때마다 $output을 덮어쓴다**. 아래 증인들은 판정 단언 전에
  # `run has_call_exact …`(원장 질의)를 쓰므로, 그 시점엔 $output이 이미 원장 질의의 출력(빈 문자열)이다
  # → `echo "$output" | jq -r .action`이 항상 ''을 읽어 **어떤 구현으로도 통과할 수 없는 단언**이 된다.
  # (red baseline에선 그 앞의 push argv 단언에서 먼저 죽어 이 결함이 가려져 있었다.)
  # 결과 JSON을 별도 변수에 **보존**해 판정 단언이 실제로 평가되게 한다(단언을 푸는 게 아니라 되살린다).
  JSON="$output"
}
run_ensure() { run_ensure_lane bump; }

# ── 원장 질의(전부 **인자 배열 단위** — 문자열 접두/부분 일치 금지) ─────────────────────────────
# 인자로 준 배열을 **접두**로 갖는 레코드 수(매치 0이면 0).
count_calls()    { python3 "$LEDGER_PY" count "$CALLS" "$@"; }
# argc와 각 위치 문자열이 **정확히** 같은 레코드가 있는가(붙여 쓴 인자는 절대 여기 걸리지 않는다).
has_call_exact() { python3 "$LEDGER_PY" exact "$CALLS" "$@"; }
# 어떤 레코드든 그 **정확한 인자 원소**를 갖는가(예: bare `--force-with-lease` 탐지 — `=…` 형태와 구분된다).
has_arg_exact()  { python3 "$LEDGER_PY" hasarg "$CALLS" "$@"; }
# 어떤 인자 **원소 안에** 이 부분 문자열이 있는가 — GraphQL 질의문(한 인자에 통째로 실린다) 검사 전용.
has_substr()     { python3 "$LEDGER_PY" hassub "$CALLS" "$@"; }
# $1로 **질의를 특정**하고, 그 질의문 안에 $2가 있는가. 본 질의와 형제 질의가 같은 원장에 공존할 때
# "어느 질의가 그 필드를 갖는가"를 못박는다(has_substr은 한쪽만 있어도 통과 — 필드 누락을 가려 준다).
query_has()      { python3 "$LEDGER_PY" hassub2 "$CALLS" "$1" "$2"; }
# 접두 일치 첫 레코드의 1-기반 순번(없으면 빈 문자열).
first_call()     { python3 "$LEDGER_PY" first "$CALLS" "$@" || true; }
dump_calls()     { echo "--- 실행된 명령(원장 — argc + 인자 경계 보존) ---"; python3 "$LEDGER_PY" dump "$CALLS"; }

# ── 무장(auto-merge) 횟수 — **두 층위**를 따로 센다 ────────────────────────────────────────────
# ① 도구가 공유 스크립트를 불렀는가(레포 관용구). 도구가 `gh pr merge --auto`를 직접 부르면 races-6
#    폴백(이미 CLEAN인 PR엔 --auto가 에러)이 사라지므로 여기서 0이 되어 잡힌다.
# ② 그 스크립트가 실제로 GitHub에 무장했는가(pass-through stub으로 스크립트가 진짜 실행된다).
# 둘 다 세는 이유: ①만 보면 "부르기만 하고 아무 일도 안 하는" 스크립트가 GREEN이 되고, ②만 보면
# 도구가 관용구를 우회해 raw gh를 불러도 GREEN이 된다.
#
# ★ 셀렉터는 **번호**다(브랜치 금지) — `gh pr merge <branch>`/`gh pr view <branch>`는 **동명 포크 PR**로
#   해석될 수 있다(공개 레포: 아무나 같은 결정적 브랜치명으로 PR을 연다) → 그 경로로 무장하면 **공격자의 PR이
#   auto-merge된다**. 그래서 셀렉터별로 따로 센다: arm_calls_num(정답) / arm_calls_branch(금지된 형태).
arm_calls_script() { count_calls bash "$AUTOMERGE_SH"; }            # 무장 호출 총 횟수(셀렉터 무관)
arm_calls_num()    { count_calls bash "$AUTOMERGE_SH" "$1"; }       # **인증된 PR 번호**로 무장한 횟수
arm_calls_branch() { count_calls bash "$AUTOMERGE_SH" "$BRANCH"; }  # 브랜치 셀렉터 무장(항상 0이어야 한다)
arm_calls_gh()     { count_calls gh pr merge; }
# 공유 스크립트가 실제로 GitHub에 무장할 때 쓴 셀렉터(스크립트는 인자를 그대로 gh에 넘기는 패스스루다).
gh_arm_with()      { count_calls gh pr merge --auto --squash "$1"; }

# ---------------------------------------------------------------------------
# 회귀 — 현재 RED (실행기 seam: 도구가 실제로 낸 명령을 단언한다)
# ---------------------------------------------------------------------------

# bats test_tags=regression
@test "W1: an open same-repo writer PR suppresses every mutation (no push, no create)" {
  # PR은 **이미 무장**돼 있다 → 이 주기의 옳은 행동은 문자 그대로 "아무것도 하지 않음"이다
  # (무장이 빠진 경우의 재무장은 W4가, 재무장의 멱등성은 W5가 따로 고정한다).
  write_prs "[{\"number\":350,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure
  [ "$status" -eq 0 ]

  # ⚠️ 증상은 **원장(argv)만으로** 단언한다 — `.observed.*`에 **어떤 전제도 두지 않는다**.
  #    예전엔 여기 "도구가 그 PR을 관측했는가" 하네스 가드가 **증상 단언보다 먼저** 있었다. 그건
  #    **픽스의 설계(조회)를 버그 관측의 전제조건으로 삼는 것**이다: 아무것도 조회하지 않는 실행기
  #    (= 픽스 이전 프로덕션 그 자체)는 그 가드에서 먼저 죽어 **증상 토큰을 출력하지 못한다**
  #    → RED이긴 하되 **엉뚱한 이유의 RED**다. 증인은 "아무것도 안 보고 그냥 PR을 또 여는 실행기"를
  #    잡을 수 있어야 한다. 배선(관측) 단언은 **증상 단언 뒤로** 옮겼다.
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || {
    echo "duplicate bump PR: ensure-bump-pr executed 'gh pr create' while PR #350 (same-repo, writer) is already open"
    dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "duplicate bump PR: ensure-bump-pr pushed ${BRANCH} while PR #350 (same-repo, writer) is already open"
    dump_calls; false
  }
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ] || {
    echo "duplicate bump PR: ensure-bump-pr decided '$action' while PR #350 (same-repo, writer) is already open (expected skip)"
    echo "$JSON"; false
  }

  # 변이 0을 확인한 **뒤에야** 배선을 본다: skip이 "조회해서 그 PR을 찾았기 때문"임을 못박는다
  # (변이 0이 조회 없이 우연히 나온 것이 아니라는 증명 — 예: 아무것도 안 하는 no-op 실행기 배제).
  echo "$JSON" | jq -e '.observed.trusted.number == 350' > /dev/null \
    || { echo "duplicate bump PR: 변이는 없지만 도구가 열린 PR #350을 **관측하지도 않았다** — skip이 사실에 근거하지 않는다"; echo "$JSON"; dump_calls; false; }
}

# bats test_tags=regression
@test "W2: a DIRTY writer PR is recovered by a leased force-push, never by a second create" {
  # DIRTY 교착: 유일한 PR이 충돌나면 이후 폴링이 전부 skip → 깨끗한 대체 PR이 영영 안 생겨
  # 배포가 조용히 멈춘다(pr-sweeper는 DIRTY를 무시). 최신 main에서 재구축해 force-push해야 풀린다.
  write_prs "[{\"number\":351,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.observed.trusted.mergeStateStatus == "DIRTY"' > /dev/null \
    || { echo "harness: 도구가 DIRTY 상태를 관측하지 못했다"; echo "$output"; dump_calls; false; }
  # R-5: lease 기대값(headRefOid)을 조회 단계에서 **실제로** 받아왔는가.
  echo "$output" | jq -e --arg o "$PR_OID" '.observed.trusted.headRefOid == $o' > /dev/null \
    || { echo "harness: 도구가 PR head OID를 관측하지 못했다(--json headRefOid 배선 확인)"; echo "$output"; false; }

  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || {
    echo "duplicate bump PR: ensure-bump-pr executed 'gh pr create' while PR #351 (same-repo, writer) is already open — a DIRTY PR must be rebuilt, not duplicated"
    dump_calls; false
  }

  # ⚠️ R-5: bare `--force-with-lease`는 그 브랜치의 원격 추적 참조가 없으면(checkout은 main만 가져온다)
  # stale로 거부돼 회복이 영구 실패한다 → 기대 OID를 명시한 `<ref>:<oid>` 형태여야 한다.
  # ⚠️ plan r3/r4: **완전 argv 배열**을 단언한다(접두·평탄화 문자열 금지) — lease만 맞고
  # `origin HEAD:refs/heads/<b>`를 빠뜨리거나 **붙여 쓰면** 라이브에선 아무것도 밀지 못해 DIRTY가 그대로
  # 남는다(테스트만 GREEN).
  run has_call_exact "${PUSH_REBUILD[@]}"
  if [ "$status" -ne 0 ]; then
    echo "stale lease: ensure-bump-pr did not force-push the rebuilt branch with the exact leased argv array"
    echo "  expected(argc=${#PUSH_REBUILD[@]}): ${H_PUSH_REBUILD}"
    dump_calls; false
  fi
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]

  # ⚠️ $output은 위 `run has_call_exact`가 덮어썼다 → 도구의 결과 JSON은 $JSON(run_ensure_lane이 보존)에서 읽는다.
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "rebuild" ] || {
    echo "duplicate bump PR: ensure-bump-pr decided '$action' while PR #351 is DIRTY on ${BRANCH} (expected rebuild)"
    echo "$JSON"; false
  }
}

# bats test_tags=regression
@test "W3: an orphan remote branch (push ok, pr create failed) is adopted with a leased push, not collided with" {
  # R-4 회복 경로: 앞선 run이 브랜치 push엔 성공하고 `gh pr create`에서 죽으면 원격에 고아 브랜치가 남는다.
  # 다음 폴링이 "열린 PR 없음 → create"로 가서 lease 없는 plain push를 하면 non-fast-forward로 충돌 →
  # 매 주기 실패 → 배포 정지. 고아는 **원격 OID를 기대값으로 한 lease push**로 접수(adopt)하고 PR을 연다.
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  run_ensure
  [ "$status" -eq 0 ]

  # ⚠️ W1과 같은 이유로 배선(관측) 단언은 **증상 단언 뒤**다 — 아무것도 조회하지 않는 실행기
  #    (= 픽스 이전 프로덕션)도 반드시 **이 증상 메시지로** 죽어야 한다. 관측 가드를 앞에 두면
  #    "조회를 한다"는 픽스의 설계가 버그 관측의 전제조건이 되어 엉뚱한 이유의 RED가 된다.
  # 완전 argv 배열 단언(plan r3/r4) — 고아 OID를 기대값으로 한 lease + 완전 목적지 refspec.
  # (bare 원격 실측: 이 형태만이 원격 추적 참조 없이도 고아를 덮어쓴다. 접두만 맞거나 붙여 쓰면 라이브는 무동작.)
  run has_call_exact "${PUSH_ADOPT[@]}"
  if [ "$status" -ne 0 ]; then
    echo "orphan bump branch: ensure-bump-pr did not adopt the orphan (${ORPHAN_OID}) with the exact leased argv array"
    echo "  expected(argc=${#PUSH_ADOPT[@]}): ${H_PUSH_ADOPT}"
    dump_calls; false
  fi
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]
  # 고아 접수 시점엔 열린 PR이 없다 → PR은 열어야 한다(1회).
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]

  # ⚠️ $output은 위 `run has_call_exact`가 덮어썼다 → 결과 JSON은 $JSON에서 읽는다.
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "adopt" ] || {
    echo "orphan bump branch: ensure-bump-pr decided '$action' with an orphan remote branch present (expected adopt)"
    echo "$JSON"; false
  }

  # adopt의 lease 기대값이 **관측된 원격 OID**에서 왔음을 못박는다(증상 단언 뒤 — 전제가 아니다).
  echo "$JSON" | jq -e --arg o "$ORPHAN_OID" '.observed.remoteBranch.oid == $o' > /dev/null \
    || { echo "orphan bump branch: adopt는 했지만 고아 원격 브랜치를 **관측하지 않았다**(git ls-remote 배선 확인)"; echo "$JSON"; dump_calls; false; }
}

# bats test_tags=regression
@test "W4: a trusted PR left un-armed is re-armed on the next run (arming is desired state, not a one-shot)" {
  # R-10의 2-run 증인. **run 1**(여기서 재현하지 않는다): push + `gh pr create`는 성공했는데 무장에서
  # 실패했다(또는 그 사이 프로세스가 죽었다) → 원격엔 **무장 안 된 신뢰 PR**이 남는다.
  # **run 2**(= 이 테스트의 상태): 다음 폴링이 그 PR을 본다. "PR이 있으니 skip"으로 끝내면 무장은
  # 영영 안 붙고 autoDeploy 배포가 **조용히 정지**한다(pr-sweeper는 `autoMergeRequest`가 이미 있는
  # PR만 다루므로 아무도 이걸 고쳐주지 않는다). 무장은 desired state여야 한다 → 재무장으로 수렴한다.
  #
  # 기대: 무장 1회(공유 스크립트 경유) + push 0 + create 0(PR은 이미 있다 — 새로 열면 그게 중복 PR이다).
  write_prs "[{\"number\":360,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  # 하네스 확인: 무장 갭을 **사실로** 관측했는가(관측이 죽었으면 버그가 아니라 테스트 결함이다).
  echo "$output" | jq -e '.observed.trusted.number == 360' > /dev/null \
    || { echo "harness: 도구가 열린 PR을 관측하지 못했다"; echo "$output"; dump_calls; false; }
  echo "$output" | jq -e '.observed.trusted.autoMerge == false' > /dev/null \
    || { echo "harness: 도구가 무장 갭을 관측하지 못했다(--json autoMergeRequest 배선 확인)"; echo "$output"; dump_calls; false; }

  # 무장은 레포 관용구(공유 스크립트)로 — raw `gh pr merge --auto`를 직접 부르면 races-6 폴백이 사라진다.
  arms="$(arm_calls_script)"
  [ "$arms" -eq 1 ] || {
    echo "stalled autoDeploy: 무장 안 된 신뢰 PR #360이 재무장되지 않았다(scripts/auto-merge-or-fail.sh 호출 ${arms}회, 기대 1회)"
    echo "  무장이 '생성 직후 1회'뿐이면 무장 실패가 영구화된다 — 다음 run이 반드시 수렴시켜야 한다."
    dump_calls; false
  }
  # 그 스크립트가 실제로 GitHub 표면까지 닿았는가(pass-through stub이 진짜 스크립트를 돌린다).
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 1 ]

  # 재무장은 **PR을 새로 열지 않는다** — 그러면 그게 바로 이 브랜치가 고치려는 중복 PR 버그다.
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || {
    echo "duplicate bump PR: 재무장해야 할 자리에서 'gh pr create'를 실행했다(PR #360이 이미 열려 있다)"
    dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "duplicate bump PR: 재무장해야 할 자리에서 ${BRANCH}를 push했다"
    dump_calls; false
  }

  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "skip" ] || {
    echo "ensure-bump-pr decided '$action' — 무장만 수렴시키면 되는 자리다(expected skip + 재무장)"
    echo "$output"; false
  }
}

# bats test_tags=regression
@test "W5: an already-armed trusted PR is never re-armed (arming converges, it does not churn)" {
  # 멱등의 반대편: 무장이 **이미** 있으면 아무것도 하지 않는다. 매 폴링(10분)마다 무장을 다시 걸면
  # `gh pr merge --auto`가 이미 무장된 PR에 대해 무슨 짓을 하든(성공/에러/재무장 이벤트) 그건
  # desired-state 수렴이 아니라 churn이다 — 무장은 "있거나 없거나"이므로 있으면 손대지 않는다.
  write_prs "[{\"number\":361,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.observed.trusted.autoMerge == true' > /dev/null \
    || { echo "harness: 도구가 기존 무장을 관측하지 못했다(--json autoMergeRequest 배선 확인)"; echo "$output"; dump_calls; false; }

  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "arming churn: 이미 무장된 PR #361을 다시 무장했다(scripts/auto-merge-or-fail.sh ${arms}회, 기대 0회)"
    dump_calls; false
  }
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
}

# bats test_tags=regression
@test "W6: a DIRTY un-armed trusted PR is both rebuilt and re-armed in the same run (the two axes are independent)" {
  # ★ 재무장은 **판정과 직교**한다. W4는 skip 판정에서의 재무장만 고정한다 — 그러면 "PR이 있고 무장이
  # 없으면 재무장"을 **skip 경로에만** 구현한 도구가 GREEN이 된다. 그런데 라이브에서 무장 실패와 DIRTY는
  # 같이 온다: run 1이 push+create는 성공하고 무장에서 죽은 뒤(무장 없는 PR), 다음 main 이동이 그 PR을
  # 충돌시키면 → **DIRTY + 미무장**이다. 그 상태에서 rebuild만 하고 무장을 건너뛰면 PR은 깨끗해지는데
  # auto-merge가 영영 안 붙어 autoDeploy 배포가 조용히 정지한다(pr-sweeper는 무장된 PR만 다룬다).
  # 계약: 신뢰 PR이 있고 lane=bump인데 무장이 없으면, **그 run의 판정이 무엇이든**(skip이든 rebuild든) 재무장한다.
  write_prs "[{\"number\":363,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  # 하네스 확인: 두 사실(DIRTY + 무장 갭)을 **둘 다** 관측했는가.
  echo "$output" | jq -e '.observed.trusted.mergeStateStatus == "DIRTY"' > /dev/null \
    || { echo "harness: 도구가 DIRTY 상태를 관측하지 못했다"; echo "$output"; dump_calls; false; }
  echo "$output" | jq -e '.observed.trusted.autoMerge == false' > /dev/null \
    || { echo "harness: 도구가 무장 갭을 관측하지 못했다(--json autoMergeRequest 배선 확인)"; echo "$output"; dump_calls; false; }

  # ① 판정 축: rebuild(정확한 lease argv 배열) — PR은 재사용하고 create는 하지 않는다.
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || {
    echo "duplicate bump PR: ensure-bump-pr executed 'gh pr create' while PR #363 is DIRTY on ${BRANCH} — a DIRTY PR must be rebuilt, not duplicated"
    dump_calls; false
  }
  run has_call_exact "${PUSH_REBUILD[@]}"
  if [ "$status" -ne 0 ]; then
    echo "stale lease: ensure-bump-pr did not force-push the rebuilt branch with the exact leased argv array"
    echo "  expected(argc=${#PUSH_REBUILD[@]}): ${H_PUSH_REBUILD}"
    dump_calls; false
  fi
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]

  # ② 무장 축: 무장이 없으므로 **같은 run에서** 재무장한다(레포 관용구 = 공유 스크립트).
  arms="$(arm_calls_script)"
  [ "$arms" -eq 1 ] || {
    echo "stalled autoDeploy: DIRTY PR #363을 rebuild하면서 무장 갭을 닫지 않았다(scripts/auto-merge-or-fail.sh ${arms}회, 기대 1회)"
    echo "  재무장은 skip 경로 전용이 아니다 — 신뢰 PR + lane=bump + 무장 없음이면 판정과 무관하게 무장한다."
    dump_calls; false
  }
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 1 ]

  # ⚠️ $output은 위 `run has_call_exact`가 덮어썼다 → 결과 JSON은 $JSON에서 읽는다.
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "rebuild" ] || {
    echo "duplicate bump PR: ensure-bump-pr decided '$action' while PR #363 is DIRTY on ${BRANCH} (expected rebuild + 재무장)"
    echo "$JSON"; false
  }
}

# bats test_tags=regression
@test "W7: a DIRTY already-armed PR is rebuilt without re-arming (rebuild does not churn the arming)" {
  # W6의 멱등 짝. rebuild가 "무조건 무장"으로 구현되면(판정 축에 무장을 매달면) 충돌난 PR을 되살릴 때마다
  # 이미 살아 있는 무장을 다시 건드린다 — 무장은 desired state지 rebuild의 부작용이 아니다.
  # force-push는 무장을 지우지 않는다(autoMergeRequest는 head OID가 아니라 PR에 붙는다) → 재무장할 게 없다.
  write_prs "[{\"number\":364,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.observed.trusted.autoMerge == true' > /dev/null \
    || { echo "harness: 도구가 기존 무장을 관측하지 못했다"; echo "$output"; dump_calls; false; }

  # 판정 축은 W2와 같다(rebuild) — 여기서 고정하는 건 **무장을 건드리지 않는다**는 쪽이다.
  run has_call_exact "${PUSH_REBUILD[@]}"
  if [ "$status" -ne 0 ]; then
    echo "stale lease: ensure-bump-pr did not force-push the rebuilt branch with the exact leased argv array"
    echo "  expected(argc=${#PUSH_REBUILD[@]}): ${H_PUSH_REBUILD}"
    dump_calls; false
  fi
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]

  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "arming churn: 이미 무장된 DIRTY PR #364을 rebuild하면서 다시 무장했다(scripts/auto-merge-or-fail.sh ${arms}회, 기대 0회)"
    echo "  무장은 desired state다 — rebuild의 부작용으로 매번 걸면 안 된다(force-push는 무장을 지우지 않는다)."
    dump_calls; false
  }
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 0 ]
}

# ── W8~W9: 무장 **해제** — 승인 레인의 desired state는 "무장 없음"이다(structure high-1) ──────────
# 실행기가 무장을 **단방향**(arm만, disarm 없음)으로 다루면 **낡은 머지 인가가 살아남는다**:
#   run 1: autoDeploy:true → bump 레인 → PR을 열고 무장한다.
#   그 뒤 owner가 .bindings.json의 autoDeploy를 **false로** 바꾼다(= 이제부터 사람 머지 = 배포 승인).
#          그런데 그 **결정적 PR은 아직 열려 있다**(같은 app+tag = 같은 브랜치 = 같은 PR).
#   run 2: 플래너가 propose-pr을 준다. 단방향 구현은 "승인 레인이니 무장하지 않는다"로 끝내는데,
#          **기존 무장은 그대로 살아 있다** → gate가 green이 되는 순간 GitHub이 **사람 승인 없이 머지**한다.
#          = 승인 게이트 우회. skip이든 rebuild든 똑같이 샌다(무장은 PR에 붙지 head OID에 붙지 않는다).
# 계약: lane=propose-pr + 신뢰 PR + 무장 있음 → **그 run의 판정이 무엇이든** 해제한다(정확히 1회).

# bats test_tags=regression
@test "W8: the propose-pr lane disarms a stale auto-merge on the SKIP path (autoDeploy was turned off under an open armed PR)" {
  # autoDeploy:true 시절에 열려 **무장된** PR이, autoDeploy:false로 바뀐 뒤에도 그대로 열려 있다.
  # 이 주기의 옳은 행동: 판정은 skip(변이 0)이되 **낡은 인가는 회수**한다.
  write_prs "[$(writer_pr 370 CLEAN "$(amr_armed)")]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]

  # 하네스 확인: 무장이 살아 있다는 **사실**을 관측했는가.
  echo "$output" | jq -e '.observed.trusted.autoMerge == true' > /dev/null \
    || { echo "harness: 도구가 기존 무장을 관측하지 못했다(--json autoMergeRequest 배선 확인)"; echo "$output"; dump_calls; false; }

  # ① 해제 1회 — 대상은 **관측된 PR 번호**(브랜치명 아님).
  run disarm_calls 370
  disarms="$output"
  [ "$disarms" -eq 1 ] || {
    echo "approval gate bypass: propose-pr 레인이 무장된 PR #370의 auto-merge를 해제하지 않았다(해제 ${disarms}회, 기대 1회)"
    echo "  autoDeploy:true 시절의 무장이 살아남으면 gate green 순간 GitHub이 **사람 승인 없이** 머지한다."
    echo "  기대 argv: gh pr merge --disable-auto 370"
    dump_calls; false
  }
  # ② 무장은 0회 — 해제해야 할 자리에서 무장하면 정반대다.
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "approval gate bypass: 승인 레인이 auto-merge를 무장했다"
    dump_calls; false
  }
  # ③ `gh pr merge` 총 호출은 해제 1회뿐(무장이 다른 표기로 몰래 새지 않았는가).
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ]

  # ④ 판정 축은 그대로 skip — 해제는 판정과 **직교**한다(PR을 새로 열거나 push하지 않는다).
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ] || {
    echo "ensure-bump-pr decided '$action' — 무장만 회수하면 되는 자리다(expected skip + 해제)"
    echo "$JSON"; false
  }
}

# bats test_tags=regression
@test "W9: the propose-pr lane disarms a stale auto-merge on the REBUILD path too (the two axes are independent)" {
  # ★ W8만 있으면 해제를 **skip 분기 안에** 심은 구현이 GREEN이 된다. 그런데 라이브에서 겹치는 조합이다:
  # 무장된 채 열려 있던 PR이 main 이동으로 DIRTY가 되고, 그 사이 autoDeploy가 false로 바뀐다.
  # rebuild(force-push)만 하고 해제를 건너뛰면, 그 push가 체크를 다시 green으로 만들어 **바로 그 순간**
  # 낡은 무장이 머지를 성사시킨다 — 승인 게이트가 통째로 우회된다.
  write_prs "[$(writer_pr 371 DIRTY "$(amr_armed)")]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.observed.trusted.mergeStateStatus == "DIRTY"' > /dev/null \
    || { echo "harness: DIRTY 상태를 관측하지 못했다"; echo "$output"; dump_calls; false; }
  echo "$output" | jq -e '.observed.trusted.autoMerge == true' > /dev/null \
    || { echo "harness: 기존 무장을 관측하지 못했다"; echo "$output"; dump_calls; false; }

  # ① 해제 축: 판정이 rebuild여도 해제한다.
  run disarm_calls 371
  disarms="$output"
  [ "$disarms" -eq 1 ] || {
    echo "approval gate bypass: propose-pr 레인이 rebuild 경로에서 무장된 PR #371을 해제하지 않았다(해제 ${disarms}회, 기대 1회)"
    echo "  해제는 skip 경로 전용이 아니다 — 무장은 PR에 붙지 head OID에 붙지 않는다(force-push로 지워지지 않는다)."
    dump_calls; false
  }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ]

  # ② 판정 축: rebuild(정확한 lease argv) + create 0 — 승인 PR은 재사용한다.
  run has_call_exact "${PUSH_REBUILD[@]}"
  if [ "$status" -ne 0 ]; then
    echo "stale lease: rebuild가 계약된 leased argv 배열로 force-push하지 않았다"
    echo "  expected(argc=${#PUSH_REBUILD[@]}): ${H_PUSH_REBUILD}"
    dump_calls; false
  fi
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]

  # ③ 해제는 **첫 변이**여야 한다 — force-push가 체크를 green으로 되돌리기 **전에** 인가를 회수한다.
  #    (rebuild를 먼저 하면 그 push가 gate를 통과시키는 순간 낡은 무장이 머지를 성사시킬 수 있다.)
  disarm_at="$(first_call gh pr merge --disable-auto)"
  push_at="$(first_call git push)"
  [ -n "$disarm_at" ]
  [ -n "$push_at" ]
  [ "$disarm_at" -lt "$push_at" ] || {
    echo "stale authorization window: 해제(줄 $disarm_at)가 force-push(줄 $push_at)보다 늦다 —"
    echo "  push가 체크를 green으로 만들면 해제 전에 머지가 성사될 수 있다. 해제가 첫 변이여야 한다."
    dump_calls; false
  }
}

# ── W10~W11: **경계된 조회**가 writer PR을 가린다(structure high-2) ────────────────────────────
# 라이브 질의(GH_DEBUG=api 실측):
#   repository.pullRequests(states:$state, headRefName:$headBranch, first:$limit, after:$endCursor,
#                           orderBy:{field: CREATED_AT, direction: DESC})
# 기본 상한 **30**, `--head`는 owner 한정 필터 **미지원**. 공개 레포라 포크가 같은 브랜치명으로 PR을 열 수 있고,
# 최신순 정렬이라 **나중에 열린 포크 PR이 먼저 열린 writer PR을 페이지 밖으로 밀어낸다**.
# → 실행기가 "열린 신뢰 PR 없음 + 원격 브랜치 있음"으로 읽어 **고아로 오인** → force-push + 중복 create.
# 계약: 부재는 **권위 있어야** 한다 — 완전히 열거했거나(상한 미만), 아니면 **모호하다고 죽거나**(fail-closed).
# 어느 쪽이든 force-push·중복 create는 **0회**다.

# bats test_tags=regression
@test "W10: forks with the same branch name (in the wild) are structurally excluded from the ref query — our writer PR is found regardless" {
  # ★★ R-40: 옛 이름-매치 조회(pullRequests(headRefName))는 포크가 같은 브랜치명으로 결과를 채워
  #   writer PR을 가릴 수 있었다(경계된 조회면 밀려나고, 상한 없으면 포크 수만큼 페이지를 태운다). 이제
  #   조회는 **우리 ref에 연결된 PR**만 본다(associatedPullRequests) → 포크 60건이 세상에 있어도 그 PR의
  #   head는 포크 레포 ref라 이 응답에 **하나도 들어오지 못한다**. 자기 PR은 언제나 그 안에 있다.
  write_prs "$(crowded_prs 60 "$(writer_pr 380 CLEAN "$(amr_armed)")")"
  write_heads "$PR_OID"   # 그 PR의 head — 원격 브랜치는 당연히 있다(고아가 **아니다**)
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  # ① 자기 PR을 찾았는가(포크 유무와 무관).
  echo "$output" | jq -e '.observed.trusted.number == 380' > /dev/null \
    || { echo "hidden writer PR: ref-연결 조회가 자기 PR(#380)을 보지 못했다"; echo "$output"; dump_calls; false; }

  # ② 고아 오인의 결과(force-push + 중복 create)가 **0회**인가 — 이게 공격자가 깨려는 멱등성이다.
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "idempotency broken by a fork: 포크에 속아 ${BRANCH}를 force-push했다(자기 PR을 고아로 오인)"
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || {
    echo "duplicate bump PR: 포크에 속아 PR을 또 만들었다(#380이 이미 열려 있다)"
    dump_calls; false
  }
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ] || {
    echo "ensure-bump-pr decided '$action' — 신뢰 PR #380이 열려 있다(expected skip)"
    echo "$JSON"; false
  }
  # ③ ★ 포크는 **관측조차 되지 않는다**(ref-연결의 구조적 배제 — R-40): crossRepo == 0, 신뢰 정확히 1건.
  echo "$JSON" | jq -e '.observed.summary.crossRepo == 0' > /dev/null \
    || { echo "포크가 ref-연결 조회에서 배제되지 않았다(summary.crossRepo != 0)"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.observed.summary.sameRepoTrusted == 1' > /dev/null \
    || { echo "신뢰 PR이 정확히 1건으로 관측되지 않았다(summary.sameRepoTrusted)"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W11: 200 fork PRs cannot stall the deployment (unbounded enumeration reconciles right through them)" {
  # ★★ 이 브랜치의 **핵심 계약**. 경계된 조회의 fail-closed 버전은 파괴적 오분류는 피했지만 **배포 정지
  # 원시 무기**를 만들었다: 결정적 브랜치명은 공개고, 그 head의 포크 PR은 **공격자가 무한정 열 수 있다** →
  # 페이지를 채우면 모든 폴링이 화해 전에 죽는다. 상한 없는 완전 열거는 그 무기를 무력화한다 —
  # 포크가 200건이든 우리 PR은 열거 안에 있고, 폴링은 **정상적으로 화해한다**.
  write_prs "$(crowded_prs 200 "$(writer_pr 381 BLOCKED "$(amr_absent)")")"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ] || {
    echo "deployment stalled by forks: 포크 200건 앞에서 도구가 죽었다 — 포크는 배포를 막을 수 없어야 한다"
    echo "$output"; dump_calls; false
  }

  # 포크 200건 사이에서 우리 PR을 정확히 찾아 **정상 화해**한다(무장 갭을 닫는다).
  echo "$output" | jq -e '.observed.trusted.number == 381' > /dev/null \
    || { echo "hidden writer PR: 포크 200건에 가려 자기 PR(#381)을 보지 못했다"; echo "$output"; dump_calls; false; }
  run arm_calls_num 381
  [ "$output" -eq 1 ] || {
    echo "deployment stalled by forks: 포크에 가려 재무장(#381)이 일어나지 않았다"
    dump_calls; false
  }
  # 고아 오인은 없다 — push·create 0회(신뢰 PR이 이미 열려 있다).
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ]
}

# bats test_tags=regression
@test "W11b: 200 fork PRs cannot block adopting our own orphan branch either (no trusted PR, forks only)" {
  # 위의 짝 — 신뢰 PR이 **없을** 때도 포크는 우리를 막지 못한다. 포크 PR은 우리 레포의 ref를 소유하지 않으므로
  # 남은 브랜치는 여전히 우리 고아다 → 정상적으로 adopt한다(포크 수와 무관).
  write_prs "$(crowded_prs 200 "")"
  write_heads "$ORPHAN_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ] || {
    echo "deployment stalled by forks: 포크 200건이 우리 고아 브랜치의 adopt를 막았다"
    echo "$output"; dump_calls; false
  }
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "adopt" ] || {
    echo "deployment stalled by forks: 포크 200건 앞에서 '$action'로 갔다(기대 adopt)"
    echo "$JSON"; false
  }
  run has_call_exact "${PUSH_ADOPT[@]}"
  [ "$status" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
}

# bats test_tags=regression
@test "W11c: an incomplete pagination fails closed (a truncated enumeration cannot prove absence)" {
  # 완전 열거의 **증명**은 마지막 페이지의 hasNextPage=false다. true로 끝났다면 gh가 페이지를 다 따라가지
  # 못한 것(--paginate 배선 실수·API 이상) → "열린 PR 없음"을 증명할 수 없다 → 조용히 create/adopt로
  # 흘리면 안 된다(그게 이 브랜치가 고치는 중복 PR·force-push 버그의 입구다).
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  export STUB_HAS_NEXT_PAGE=true
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "unproven absence: 페이지네이션이 끝나지 않았는데(hasNextPage=true) 도구가 성공으로 끝났다"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# bats test_tags=regression
@test "W74: a null ref (our branch does not exist) means 'no PR of ours', not a query failure — plain create" {
  # ★ R-40: ref-연결 조회는 `repository.ref(qualifiedName)`로 시작한다. 우리 브랜치가 원격에 **없으면**
  #   라이브 GitHub은 `{data:{repository:{ref:null}}}`을 준다(라이브 실측). 그건 **조회 실패가 아니라**
  #   "우리 것 PR 0건"이다 — git ls-remote가 그 브랜치를 못 찾는 신호와 정합해야 한다. 여기서 fail-closed하면
  #   정상 create(첫 bump)가 영구히 막힌다. (ref null을 스키마 위반으로 접으면 이 증인이 RED가 된다.)
  export STUB_REF_NULL=1
  : > "$STUB_HEADS"          # 원격 브랜치도 없다 → 정상 create 경로
  run_ensure_lane bump
  [ "$status" -eq 0 ] || {
    echo "null ref mis-read as failure: 브랜치가 없다는 정상 신호(ref:null)에 도구가 fail-closed했다 — 첫 bump가 막힌다"
    echo "$output"; dump_calls; false
  }
  echo "$output" | jq -e '.observed.trusted == null' > /dev/null \
    || { echo "null ref: 신뢰 PR을 null로 접지 않았다"; echo "$output"; false; }
  echo "$output" | jq -e '.observed.summary.totalOpen == 0' > /dev/null \
    || { echo "null ref: 우리 것 PR 0건으로 접지 않았다(totalOpen != 0)"; echo "$output"; false; }
  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "create" ] || { echo "null ref: '$action'로 갔다(기대 create)"; echo "$output"; false; }
  run has_call_exact git push origin "HEAD:refs/heads/${BRANCH}"
  [ "$status" -eq 0 ] || { echo "null ref: 정상 create push가 나가지 않았다"; dump_calls; false; }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
}

# bats test_tags=regression
@test "W75: a GraphQL ref:null contradicting an ls-remote-present branch fails closed (two non-atomic reads must agree — R-43)" {
  # ★ R-43: ref-조회(GraphQL)와 git ls-remote는 **두 번의 비원자적 읽기**다. GraphQL이 ref:null(브랜치 부재)을
  #   주는데 ls-remote는 그 브랜치를 보고하면(존재), 두 읽기가 **어긋난** 것이다 — GraphQL 뷰가 stale/저하됐거나
  #   ref가 그 사이 재생성됐다. 예전엔 ref:null을 "PR 0건"으로 접은 뒤 ls-remote만 보고 **무조건 adopt(force-push)**
  #   했다 → GraphQL이 **실재하는 열린 PR을 숨긴** 경우 남의 커밋을 덮고 중복 PR을 열었다. 이제는 **fail-closed**다:
  #   한쪽만 존재하면 사실을 모르는 것이므로 force-push도 create도 하지 않는다(다음 주기가 다시 읽는다).
  export STUB_REF_NULL=1       # GraphQL: ref:null(부재)
  write_heads "$ORPHAN_OID"    # ls-remote: 브랜치 존재 → **불일치**
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "ref disagreement mis-adopted: GraphQL ref:null인데 ls-remote는 브랜치 존재 → 도구가 fail-closed하지 않았다"
    echo "  (stale/저하된 GraphQL 뷰가 실재하는 PR을 숨겼다면 이건 force-push로 남의 커밋을 덮는 경로다 — R-43)"
    echo "$output"; dump_calls; false
  }
  # ★ 변이 0: force-push(adopt)도, plain push도, create도 하지 않는다.
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || { echo "ref disagreement: push가 나갔다($pushes회) — 사실을 모른 채 밀면 안 된다"; dump_calls; false; }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || { echo "ref disagreement: gh pr create가 나갔다($creates회)"; dump_calls; false; }
}

# bats test_tags=regression
@test "W76: a sibling ls-remote reports but whose ref:null in GraphQL turns the run red (revocation cannot silently miss an armed zombie — R-43)" {
  # ★ R-43(회수 경로): 형제 ref는 `git ls-remote`가 **존재를 보고했기에** 회수 스윕의 대상이 됐다. 그런데
  #   ref-조회가 ref:null(부재)을 주면 어긋난 것이다 — 그 브랜치에 무장된 좀비 PR이 있는지 **알 수 없다**.
  #   예전 관용구("ref:null = PR 0건")를 그대로 쓰면 **무장된 PR을 못 본 채 run이 초록**이 된다. 이제는
  #   관측 실패로 접어(revocationBlind) run을 빨갛게 만든다 — 회수 대상을 가릴 수 있는 관측 실패는 회수 실패다(V-2).
  local sib; sib="$(SIB_BRANCH_OF)"
  write_bindings '{"autoDeploy":false}'   # 승인 레인 — 이 네임스페이스의 무장은 회수 대상이다
  add_sibling "$sib" "$SIB_OID" "$(sib_node 361 "$SIB_OID" "2026-07-13T06:30:00Z" "$(amr_armed)")"
  export STUB_SIB_REF_NULL=1               # 형제 ref-조회가 ref:null(ls-remote는 위 add_sibling로 존재 보고) → 불일치
  run_reconcile
  [ "$RCODE" -ne 0 ] || {
    echo "revocation silently missed: 형제 ref-조회가 ref:null인데(ls-remote는 존재) run이 초록으로 끝났다 — 무장된 좀비를 못 본 것이다(R-43)"
    echo "$JSON"; dump_calls; false
  }
  # 불일치는 revocationFailures에 그 브랜치가 이름으로 남는다(무엇을 보지 못했는지).
  echo "$JSON" | jq -e --arg b "$sib" '[.revocationFailures[] | select(contains($b))] | length >= 1' > /dev/null \
    || { echo "보고 누락: 불일치한 형제($sib)가 revocationFailures에 없다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W78: an EMPTY GraphQL connection at a tip that differs from ls-remote turns the run red (a stale view's 0-PR is not evidence — R-44)" {
  # ★ R-44(finding의 정확한 시나리오): ls-remote는 tip A를 보는데 stale GraphQL 뷰가 tip B에서 **빈 connection**을
  #   준다 → 예전엔 "PR 0건 → 회수할 것 없음"으로 접혔다. 하지만 **A에 무장된 좀비가 있어도** B의 빈 응답은 그걸
  #   증명하지 못한다. 열거한 OID(A)를 씸에 넘겨 GraphQL tip(B)과 대조 → 어긋나면 revocationBlind(run 빨강).
  #   ★ 여기선 **형제에 열린 PR을 심지 않는다**(빈 connection) → 3자 가드(PR headRefOid)는 관여하지 않고
  #     **expectedOid 대조 가드만** 이 케이스를 잡는다(뮤턴트 격리).
  local sib; sib="$(SIB_BRANCH_OF)"
  write_bindings '{"autoDeploy":false}'
  add_sibling "$sib" "$SIB_OID" ""                                    # ls-remote tip = SIB_OID(A), 열린 PR 0건
  export STUB_SIB_REF_OID="5555555555555555555555555555555555555555"  # GraphQL ref tip = B(≠A) + 빈 connection
  run_reconcile
  [ "$RCODE" -ne 0 ] || {
    echo "stale empty view trusted: GraphQL tip(B)이 ls-remote(A)와 다른데 빈 connection을 '회수할 것 없음'으로 접고 run이 초록이 됐다 — A의 무장 좀비를 놓칠 수 있다(R-44)"
    echo "$JSON"; dump_calls; false
  }
  echo "$JSON" | jq -e --arg b "$sib" '[.revocationFailures[] | select(contains($b))] | length >= 1' > /dev/null \
    || { echo "보고 누락: OID 불일치 형제($sib)가 revocationFailures에 없다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W79: a sibling PR whose headRefOid disagrees with the ref tip turns the run red (three-way OID agreement — R-44)" {
  # ★ R-44 3자 합의: GraphQL ref tip과 ls-remote tip이 **일치**해도(expectedOid 가드 통과), 그 응답 안의 신뢰
  #   PR headRefOid가 ref tip과 어긋나면 섞인/부분 뷰다 → 그 PR의 무장을 유지·회수할 근거가 흔들린다. fail-closed.
  local sib; sib="$(SIB_BRANCH_OF)"
  write_bindings '{"autoDeploy":false}'
  # ls-remote tip = SIB_OID, GraphQL ref tip = SIB_OID(기본 유도 — 일치) 이지만 PR headRefOid는 **다른 OID**.
  add_sibling "$sib" "$SIB_OID" "$(sib_node 363 "6666666666666666666666666666666666666666" "2026-07-13T06:30:00Z" "$(amr_armed)")"
  run_reconcile
  [ "$RCODE" -ne 0 ] || {
    echo "mixed view trusted: 신뢰 PR headRefOid(6666)이 ref tip(SIB_OID)과 다른데 run이 초록으로 끝났다 — 인가 근거가 흔들린다(R-44)"
    echo "$JSON"; dump_calls; false
  }
  echo "$JSON" | jq -e --arg b "$sib" '[.revocationFailures[] | select(contains($b))] | length >= 1' > /dev/null \
    || { echo "보고 누락: head 불일치 형제($sib)가 revocationFailures에 없다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W77: a GraphQL ref whose OID differs from ls-remote fails closed (the ref moved between the two reads — R-43)" {
  # ★ R-43: 두 읽기가 **둘 다 브랜치를 보고**해도, tip OID가 어긋나면 ref가 그 사이 이동/재생성된 것이다.
  #   그 상태로 adopt(원격 OID를 lease 기대값으로 force-push)하면 잘못된 baseline 위에서 밀거나, 다른
  #   내용을 덮을 수 있다 → OID가 일치할 때만 adopt하고, 어긋나면 fail-closed(다음 주기가 다시 읽는다).
  write_prs '[]'                                                       # 열린 신뢰 PR 없음
  write_heads "$ORPHAN_OID"                                            # ls-remote tip = ORPHAN_OID
  export STUB_REF_OID="4444444444444444444444444444444444444444"      # GraphQL ref.target.oid = 다른 OID → 불일치
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "ref OID mismatch mis-adopted: GraphQL과 ls-remote의 tip OID가 다른데 도구가 fail-closed하지 않았다(R-43)"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || { echo "ref OID mismatch: push가 나갔다($pushes회)"; dump_calls; false; }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "W80: a trusted PR whose head/ref/ls-remote OIDs disagree is never rebuilt or re-armed (main-path three-way agreement — R-44)" {
  # ★ R-44: 신뢰 PR(무장·DIRTY)이 있어도, GraphQL ref tip이 ls-remote/PR headRefOid와 어긋나면 stale/섞인 뷰다.
  #   그 상태로 rebuild(force-push)하면 잘못된 baseline 위로 밀고, 재무장하면 낡은 head에 auto-merge를 건다.
  #   셋이 합의할 때만 진행 → 어긋나면 fail-closed(변이 0). (예전엔 OID를 create/adopt에서만 비교했다.)
  write_prs "[{\"number\":390,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"                                                 # ls-remote tip = PR_OID = PR headRefOid
  export STUB_REF_OID="7777777777777777777777777777777777777777"      # GraphQL ref tip = 다른 OID → 3자 불일치
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "stale-head mutated: 신뢰 PR의 head/ref/ls-remote OID가 어긋나는데 rebuild·재무장을 진행했다(R-44)"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || { echo "3자 불일치: force-push가 나갔다($pushes회) — 잘못된 baseline"; dump_calls; false; }
  arms="$(count_calls gh pr merge)"
  [ "$arms" -eq 0 ] || { echo "3자 불일치: 낡은 head에 auto-merge를 걸었다($arms회)"; dump_calls; false; }
}

# ── R-40/R-41: 포크 억제가 **질의 작업(API·서브프로세스·벽시계) 예산**으로 이동했다 ────────────────
# 옛 이름-매치 조회(pullRequests(headRefName))는 바이트는 foldConnection이 경계지었지만, **공격자 통제
# 페이지마다 gh api graphql 서브프로세스를 하나씩** hasNextPage=false까지 띄웠다 → 폴링·회수가 **포크 수에
# 비례**해 GraphQL 예산·서브프로세스·벽시계를 태운다(충분한 포크면 writer PR을 찾기 전에 매 주기 실패).
# 종결 픽스: ref-연결 조회(associatedPullRequests)는 포크를 **구조적으로 배제**한다 → 질의 작업이 **우리 ref에
# 연결된 PR 수**에만 비례하고(여기선 1건), 포크가 세상에 몇 건이든 상수다. 아래 두 증인이 그 성질을 못박는다.
# ★ 취약 메커니즘을 고정하지 않는다: 정확한 포크 카운트·페이지 수·커서 대신 **포크-독립 질의-작업 경계**만
#   단언한다 → fork를 열거하지 않는 안전한 구현이 종단 결정을 만족하면 통과한다(R-41).

# bats test_tags=regression
@test "W70: the main query's work is independent of fork count (a ref-connection query cannot be saturated by same-named forks)" {
  # 포크 650건이 세상에 열려 있고(같은 결정적 브랜치명 bump-poll/<app>-<tag>) + 우리 writer PR 1건이 열려 있다.
  # ref-연결 조회는 포크 PR(head가 포크 레포 ref)을 **응답에 담지 않는다** → 포크 650건은 질의에 **아무 비용도
  # 부과하지 못한다**. 옛 이름-매치 조회였다면 650/100 = 7페이지 = 7 서브프로세스를 태웠을 것이다.
  write_prs "$(crowded_prs 650 "$(writer_pr 382 CLEAN "$(amr_absent)")")"
  write_heads "$PR_OID"

  run_ensure_lane bump
  [ "$status" -eq 0 ] || {
    echo "deployment suppressed by fork budget: 포크 650건 앞에서 도구가 죽었다 — ref-연결 조회는 포크에 비용을 주지 않아야 한다"
    echo "$output"; dump_calls; false
  }

  # ① 종단 결정: 자기 PR을 찾아 정상 화해(고아 오인 0 — push·create 0회 + 무장 갭 수렴).
  echo "$output" | jq -e '.observed.trusted.number == 382' > /dev/null \
    || { echo "hidden writer PR: ref-연결 조회가 자기 PR(#382)을 보지 못했다"; echo "$output"; dump_calls; false; }
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ] || { echo "ensure-bump-pr decided '$action' — 신뢰 PR #382이 열려 있다(expected skip)"; echo "$JSON"; false; }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  run arm_calls_num 382
  [ "$output" -eq 1 ]

  # ② ★ 포크는 **관측조차 되지 않는다**(ref-연결의 구조적 배제): crossRepo == 0, 신뢰 정확히 1건.
  echo "$JSON" | jq -e '.observed.summary.crossRepo == 0' > /dev/null \
    || { echo "포크가 ref-연결 조회에서 배제되지 않았다(summary.crossRepo != 0)"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.observed.summary.sameRepoTrusted == 1' > /dev/null \
    || { echo "신뢰 PR이 정확히 1건으로 관측되지 않았다(summary.sameRepoTrusted)"; echo "$JSON"; false; }
  # ★ 전량 노드 배열은 직렬화되지 않는다(R-36 출력 경계 유지) — `.observed.prs`는 없다.
  echo "$JSON" | jq -e '.observed | has("prs") | not' > /dev/null \
    || { echo "unbounded output: 전량 노드 배열(.observed.prs)이 직렬화됐다(R-36 위반)"; echo "$JSON"; false; }

  # ③ ★★ **질의 작업이 포크 수와 무관**하다(R-41의 핵심). 페이지네이션은 경계 있는 카운터(정수 하나)로만
  #    관측하는데, 포크 650건이 세상에 있어도 조회는 **우리 PR 1건 = 1페이지 = 1 서브프로세스**로 끝난다.
  #    (이름-매치 조회였다면 7페이지였고, stub이 그 질의를 exit 3으로 거부해 fail-closed → RED가 된다.)
  echo "$JSON" | jq -e '.graphqlPages == 1' > /dev/null \
    || { echo "query work NOT fork-independent: graphqlPages != 1 — 포크 수에 비례해 페이지를 태웠다(R-40)"; echo "$JSON"; false; }
  # read-only PR 페이지 조회는 감사 원장에 하나도 남지 않는다(포크 수에 무관 — R-36 유지).
  echo "$JSON" | jq -e '[.executed[] | select(contains("associatedPullRequests"))] | length == 0' > /dev/null \
    || { echo "unbounded audit: read-only PR 조회(associatedPullRequests)가 executed에 기록됐다(R-36 위반)"; echo "$JSON"; false; }

  # ④ ★ 조회가 **ref-연결**임을 못박는다(포크가 오염시킬 수 있는 이름-매치 표면이 아니다 — R-40).
  run has_arg_exact "ref=refs/heads/$BRANCH"
  [ "$status" -eq 0 ] || { echo "fork-taintable query: 우리 ref로 질의하지 않았다(ref=refs/heads/$BRANCH 없음)"; dump_calls; false; }
  run has_substr 'headRefName:'
  [ "$status" -ne 0 ] || { echo "fork-taintable query regression: 조회가 headRefName 이름-매치로 되돌아갔다 — 포크가 오염시킬 수 있다"; dump_calls; false; }
}

# bats test_tags=regression
@test "W71: the revocation sweep's query work is fork-independent too (a fork-saturated sibling head cannot hide an armed zombie or burn the budget)" {
  # 같은 성질을 **회수 경로**에 겨눈다: 형제 브랜치명도 공개라 포크가 같은 head로 PR을 연다. ref-연결 조회는
  # 그 포크들을 **응답에 담지 않는다** → 포화된 형제 head라도 (a) 무장된 좀비를 가리지 못하고, (b) 회수의
  # 질의 작업을 포크 수만큼 태우지 못한다. 이름-매치로 되돌아가면 stub이 exit 3 → 관측 실패 → revocationBlind → RED.
  local sib armed_node
  sib="$(SIB_BRANCH_OF)"
  # 그 형제 head에 포크 650건(같은 브랜치명) + **무장된 우리 writer PR**(꼬리). ref-연결 조회가 포크를 배제한다.
  armed_node="$(sib_node 340 "$SIB_OID" "2026-07-13T06:30:00Z" "$(amr_armed)")"
  printf '%s\t%s\n' "$SIB_OID" "refs/heads/$sib" >> "$STUB_SIBLINGS"
  crowded_prs 650 "$armed_node" > "$SIB_DIR/$(printf '%s' "$sib" | tr '/' '_').json"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"

  write_prs '[]'   # 이번 후보는 아직 PR이 없다(정상 create 경로)
  run_ensure_lane bump
  [ "$status" -eq 0 ] || {
    echo "revocation blinded/starved by forks: 형제 head가 포화되자 스윕이 그 브랜치를 관측하지 못했다"
    echo "$output"; dump_calls; false
  }

  # ① 포크 뒤에 숨지 못한 **무장된 형제**를 찾아 회수했다.
  run disarm_calls 340
  [ "$output" -eq 1 ] || {
    echo "armed zombie survived: 포크 650건에 가려 형제 PR #340의 무장을 회수하지 못했다"
    echo "  → 낡은 머지 인가가 살아남는다(누군가 그 브랜치를 전진시키면 무승인 롤백 — R-25)."
    dump_calls; false
  }
  echo "$JSON" | jq -e '[.superseded[] | select(.number == 340 and .disarmed)] | length == 1' > /dev/null \
    || { echo "보고 누락: 회수한 형제가 superseded 보고에 없다"; echo "$JSON"; false; }
  # ② ★ 형제 조회도 **ref-연결**이라(우리 ref로 질의) 질의 작업이 포크 수와 무관하다 — read-only PR 조회는
  #    감사 원장에 하나도 남지 않는다(O(1) — R-36 유지).
  run has_arg_exact "ref=refs/heads/$sib"
  [ "$status" -eq 0 ] || { echo "fork-taintable sibling query: 형제 ref로 질의하지 않았다(ref=refs/heads/$sib 없음)"; dump_calls; false; }
  echo "$JSON" | jq -e '[.executed[] | select(contains("associatedPullRequests"))] | length == 0' > /dev/null \
    || { echo "unbounded audit: 포화 형제의 read-only PR 조회(associatedPullRequests)가 executed에 기록됐다(R-36 위반)"; echo "$JSON"; false; }
  # ③ 메인 판정은 그대로 진행됐다(포화가 배포를 막지 못한다).
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "create" ]
}

# bats test_tags=regression
@test "W11d: a trusted PR is identified by the (head, base) PAIR — another base is not our PR" {
  # 지적 1: `--base`는 PR **생성**을 제어하는데 식별이 head로만 이뤄지면, 같은 결정적 head를 **다른 base**로
  # 향한 writer PR을 "우리 PR"로 착각한다 → 그걸 skip/rebuild/무장/해제하고, 정작 요청된 base의 PR은 영영
  # 안 생긴다. 식별은 (head, base) **쌍**이다.
  # ⚠️ 다만 그 PR도 **동일-레포**라 이 브랜치를 쓰고 있다(소유권은 base와 무관) → 우리 것이 아니면서 우리가
  #    덮어쓸 수도 없다 = fail-closed(r3의 파괴 가드). "건드리지 않는다"가 계약이다.
  write_prs "[$(writer_pr 390 CLEAN "$(amr_armed)" gh-pages)]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "misidentification: base가 다른 PR #390(→gh-pages)을 우리 PR로 취급했다"
    echo "$output"; dump_calls; false
  }
  # 우리 PR이 아니다 — 신뢰하지 않는다.
  echo "$stderr" | grep -q "신뢰할 수 없는 동일-레포 PR" \
    || { echo "다른 base PR을 신뢰하지 않는다는 사실이 드러나지 않는다"; echo "$stderr"; false; }

  # **건드리지 않는다**: 그 PR을 skip/rebuild하지도, 무장/해제하지도, force-push로 덮어쓰지도 않는다.
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ] || {
    echo "misidentification: base가 다른 PR #390의 auto-merge를 건드렸다"
    dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "destructive: base가 다른 PR #390이 쓰는 브랜치를 force-push로 덮어썼다"
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "W11e: two trusted PRs on the same (head, base) fail closed (GitHub cannot produce this — something is broken)" {
  # 모호성 fail-closed는 유지한다. 같은 head→base에 열린 PR은 GitHub이 1건만 허용하므로 2건은 **불가능**하다 →
  # 보였다면 우리의 신뢰 경계나 GitHub 계약 중 하나가 깨진 것이다. 아무거나 고르면 나머지는 방치된다(무장 갭·좀비).
  write_prs "[$(writer_pr 391 CLEAN "$(amr_armed)"),$(writer_pr 392 CLEAN "$(amr_absent)")]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "ambiguous identity: 신뢰 PR 2건(#391,#392)인데 도구가 하나를 골라 진행했다"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# bats test_tags=regression
@test "W11f: a human account whose login equals the writer slug is NOT trusted (__typename gates the impersonation)" {
  # ★ GraphQL 표면의 함정: 봇 계정의 실제 login은 `<slug>[bot]`이므로 **`<slug>` 그대로의 사람 계정**이
  # 존재할 수 있다. login만 정규화해서 비교하면 그 사람이 writer App으로 **사칭**된다 → 그 PR을 신뢰해
  # 무장(=자동 머지)까지 걸어줄 수 있다. GraphQL이 주는 __typename(Bot vs User)이 그 경계다.
  write_prs "[{\"number\":393,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(human_author ukyi-homelab-writer),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  # 사람이 연 동일-레포 PR = 신뢰 불가 + 그 브랜치는 그 사람 것 → 파괴 가드로 fail-closed.
  [ "$status" -ne 0 ] || {
    echo "impersonation: __typename=User인 사람 계정('ukyi-homelab-writer')을 writer App으로 신뢰했다"
    echo "$output"; dump_calls; false
  }
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ] || {
    echo "impersonation: 사칭 PR #393에 auto-merge를 걸었다 — 사람 코드가 자동 머지된다"
    dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# ── W12~W16: 무장 셀렉터는 **인증된 PR 번호**다 — 브랜치 셀렉터는 동명 포크 PR을 머지시킨다 ────────
# 조회 단계에서 신뢰 경계를 지켜도(동일-레포 + writer), **변이 단계에서 브랜치명을 셀렉터로 쓰면** 그 경계가
# 통째로 샌다: `gh pr merge <branch>` / `gh pr view <branch>`는 브랜치명으로 PR을 **다시 찾는데**, 공개 레포라
# 포크가 **같은 결정적 브랜치명**으로 PR을 열 수 있다 → 그 조회가 포크 PR을 지목하면 **공격자의 코드가
# auto-merge된다**. 인증된 셀렉터(번호)를 변이 경로 끝까지 들고 가야 한다:
#   skip/rebuild → trusted.number   |   create/adopt → gh pr create가 낸 URL의 번호   |   해제 → trusted.number
# 공유 스크립트는 인자를 gh에 그대로 넘기는 **패스스루**라(브랜치명 자체를 쓰는 로직 없음) 번호만 넘기면 된다.

# bats test_tags=regression
@test "W12: arming on the CREATE path targets the number gh returned, never the branch selector" {
  write_prs '[]'
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  # 도구는 `gh pr create`가 낸 URL(.../pull/999)에서 번호를 파싱해 그 번호로 무장해야 한다.
  run arm_calls_num 999
  [ "$output" -eq 1 ] || {
    echo "ambiguous arming selector: 새로 만든 PR을 **번호**(999)로 무장하지 않았다"
    echo "  gh pr create가 돌려준 URL의 번호가 인증된 셀렉터다 — 브랜치명으로 되짚으면 동명 포크 PR을 지목할 수 있다."
    dump_calls; false
  }
  run arm_calls_branch
  [ "$output" -eq 0 ] || {
    echo "ambiguous arming selector: 브랜치명('${BRANCH}')으로 무장했다 — 같은 브랜치명의 **포크 PR**이 머지될 수 있다"
    dump_calls; false
  }
  # 공유 스크립트가 GitHub에 실제로 무장할 때 쓴 셀렉터도 번호여야 한다(패스스루라 그대로 흘러간다).
  run gh_arm_with 999
  [ "$output" -eq 1 ]
  run gh_arm_with "$BRANCH"
  [ "$output" -eq 0 ]
}

# bats test_tags=regression
@test "W13: arming on the ADOPT path targets the number gh returned, never the branch selector" {
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "adopt" ]
  run arm_calls_num 999
  [ "$output" -eq 1 ] || {
    echo "ambiguous arming selector: adopt 경로가 새 PR을 번호(999)로 무장하지 않았다"
    dump_calls; false
  }
  run arm_calls_branch
  [ "$output" -eq 0 ]
}

# bats test_tags=regression
@test "W14: re-arming on the SKIP path targets the trusted PR number, never the branch selector" {
  write_prs "[$(writer_pr 360 BLOCKED "$(amr_absent)")]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  run arm_calls_num 360
  [ "$output" -eq 1 ] || {
    echo "ambiguous arming selector: 재무장이 신뢰 PR 번호(360)를 지목하지 않았다"
    dump_calls; false
  }
  run arm_calls_branch
  [ "$output" -eq 0 ] || {
    echo "ambiguous arming selector: 재무장이 브랜치명으로 갔다 — 동명 포크 PR이 무장될 수 있다"
    dump_calls; false
  }
}

# bats test_tags=regression
@test "W15: re-arming on the REBUILD path targets the trusted PR number, never the branch selector" {
  write_prs "[$(writer_pr 363 DIRTY "$(amr_absent)")]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  run arm_calls_num 363
  [ "$output" -eq 1 ] || {
    echo "ambiguous arming selector: rebuild 경로의 재무장이 신뢰 PR 번호(363)를 지목하지 않았다"
    dump_calls; false
  }
  run arm_calls_branch
  [ "$output" -eq 0 ]
}

# bats test_tags=regression
@test "W16: with a same-named fork PR crowding the branch, arming still targets the trusted number" {
  # ★ 이 결함의 **정확한 공격 시나리오**: 포크가 같은 브랜치명으로 PR을 열어 두면, 브랜치 셀렉터로 하는
  # 무장(`gh pr merge <branch>`)이 그 포크 PR을 지목할 수 있다 → 공격자 코드가 auto-merge된다.
  # 조회 단계의 신뢰 경계(동일-레포 + writer)는 이미 포크를 걸러낸다 — 변이 단계도 그 판정을 **그대로** 따라야 한다.
  write_prs "$(crowded_prs 5 "$(writer_pr 380 BLOCKED "$(amr_absent)")")"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  # 하네스 확인: 포크는 ref-연결 조회에서 **구조적으로 배제**되고(관측 0건), 신뢰 PR만 잡혔는가(R-40).
  #   무장 셀렉터가 브랜치가 아니라 번호여야 한다는 계약은 그대로다 — 포크가 없어도 브랜치 셀렉터는 금지다.
  echo "$output" | jq -e '.observed.summary.crossRepo == 0' > /dev/null
  echo "$output" | jq -e '.observed.trusted.number == 380' > /dev/null

  run arm_calls_num 380
  [ "$output" -eq 1 ] || {
    echo "attacker PR could be auto-merged: 동명 포크 PR이 섞인 상태에서 무장이 신뢰 PR 번호(380)를 지목하지 않았다"
    dump_calls; false
  }
  run arm_calls_branch
  [ "$output" -eq 0 ] || {
    echo "attacker PR could be auto-merged: 브랜치명('${BRANCH}')으로 무장했다 — 그 조회는 포크 PR로 해석될 수 있다"
    dump_calls; false
  }
  # 포크 PR 번호(9000~)로는 절대 무장하지 않는다.
  run arm_calls_num 9000
  [ "$output" -eq 0 ]
}

# bats test_tags=regression
@test "W17: an unparseable gh pr create output fails closed (no arming with an unknown selector)" {
  # 번호를 확정할 수 없으면 **브랜치로 폴백하지 않는다** — 폴백이 곧 이 결함이다(동명 포크 PR 오조준).
  # 출력 형식이 드리프트하면(경고 혼입·URL 부재) 무장 대상을 모르는 것이므로 시끄럽게 죽는다.
  write_prs '[]'
  export STUB_GH_CREATE_OUT="Warning: something changed in gh output"
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "unknown arming selector: gh pr create 출력에서 PR 번호를 못 읽었는데 도구가 성공으로 끝났다"
    echo "$output"; dump_calls; false
  }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "unknown arming selector: 번호를 모른 채 무장했다(브랜치 폴백?) — 동명 포크 PR이 머지될 수 있다"
    dump_calls; false
  }
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# ── W20~W24: **ref 소유권** — PR 작성자 인증은 "누가 그 ref를 썼는가"를 증명하지 않는다 ──────────
# isTrusted는 **누가 PR을 열었는지**만 본다. 그런데 force-push는 **ref의 내용**을 지운다:
#   · adopt : PR이 안 보이는 원격 ref를 무조건 덮어썼다 — 그게 우리 잔해라는 근거가 0이었다.
#   · rebuild: writer가 연 PR이라도 **다른 동일-레포 행위자가 그 head에 push**하면 PR 작성자는 그대로
#              writer다 → 신뢰된 채로 남고, 우리는 그 사람의 커밋을 지운다(contents:write 보유자의 작업 파괴).
# → force-push하는 두 경로는 **밀어낼 커밋이 우리 bump 커밋인지** 먼저 증명한다(정체성 + 결정적 메시지).
# ⚠️ 라이브 확인: 이 커밋들엔 **서명이 없다**(signature: null) → 이건 인증이 아니라 **안전 인터록**이다.
#    사고성 파괴는 확실히 막지만, 악의적 contents:write 행위자는 정체성·메시지를 위조할 수 있다.
#    강제 가능한 불변식은 ruleset(`bump-poll/**` writer 전용 예약) — 도구 밖이다.

# bats test_tags=regression
@test "W20: an orphan branch whose head commit is NOT ours is never force-pushed over (adopt fails closed)" {
  # 고아처럼 보이지만 실은 **남의 브랜치**다(같은 이름을 누가 먼저 썼거나, 우리 것이 아닌 잔해).
  # 옛 코드는 "열린 PR 없음 + 원격 ref 있음"만 보고 무조건 force-push했다 → 그 커밋을 지운다.
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  export STUB_COMMIT_NAME="ukkiee"
  export STUB_COMMIT_EMAIL="ukkiee@users.noreply.github.com"
  export STUB_COMMIT_MSG="feat: 내 작업 중인 커밋"
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "destructive force-push: 남의 커밋이 올라간 ref를 adopt로 덮어썼다"
    echo "$output"; dump_calls; false
  }
  echo "$stderr" | grep -q "우리 bump 커밋이 아니다" \
    || { echo "에러가 소유권 실패를 말하지 않는다"; echo "$stderr"; false; }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "destructive force-push: ${BRANCH}(남의 커밋)를 force-push로 덮어썼다 — 작업 파괴"
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# bats test_tags=regression
@test "W21: a DIRTY writer PR whose head was pushed by someone else is never rebuilt over (rebuild fails closed)" {
  # ★ 이게 "PR 작성자 인증 ≠ ref 소유권"의 정확한 형태다. PR은 writer가 열었으니 isTrusted는 통과한다 —
  # 그런데 그 사이 **다른 동일-레포 행위자가 그 브랜치에 자기 커밋을 push**했다(PR head가 갱신됐다).
  # PR 작성자는 여전히 writer라 신뢰는 유지되고, rebuild는 그 사람 커밋을 force-push로 지운다.
  write_prs "[$(writer_pr 395 DIRTY "$(amr_armed)")]"
  write_heads "$PR_OID"
  export STUB_COMMIT_NAME="ukkiee"
  export STUB_COMMIT_EMAIL="ukkiee@users.noreply.github.com"
  export STUB_COMMIT_MSG="fix: 이 브랜치에 내가 올린 수정"
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "destructive force-push: 남이 갱신한 PR head를 rebuild로 덮어썼다"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "destructive force-push: PR #395의 head(남의 커밋)를 force-push로 지웠다"
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "W22: a commit carrying the writer identity but a FOREIGN message is not ours either (message is part of the proof)" {
  # 정체성만 보면, 같은 봇이 만든 **다른 목적의 커밋**(다른 워크플로가 같은 ref를 재사용)도 통과한다.
  # 우리 브랜치는 (app, tag)로 결정적이므로 그 위의 우리 커밋 메시지도 결정적이다 → 메시지도 증명의 일부다.
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  export STUB_COMMIT_MSG="chore: 전혀 다른 자동 커밋"
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "destructive force-push: writer 정체성만 맞으면 남의 목적의 커밋도 덮어썼다"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "W23: a commit whose COMMITTER is not the writer fails closed (author alone is not enough)" {
  # author는 위조하기 쉬운 자유 텍스트이고, 실제로 ref에 커밋을 얹은 주체는 committer다 → 둘 다 본다.
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  export STUB_COMMIT_CNAME="ukkiee"
  export STUB_COMMIT_CEMAIL="ukkiee@users.noreply.github.com"
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "destructive force-push: committer가 writer가 아닌 커밋을 덮어썼다(author만 보고 통과)"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
}

# bats test_tags=regression
@test "W24: a failing or drifted commit lookup fails closed (unknown content is never force-pushed over)" {
  # 무엇을 덮어쓰는지 **모르면** 덮어쓰지 않는다. 조회 실패·스키마 드리프트·OID 미발견 전부 같다.
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  export STUB_COMMIT_FAIL=1
  run_ensure_lane bump
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]

  # 스키마 드리프트(object=null — 그 OID를 못 찾음)도 같은 결론이다.
  : > "$CALLS"
  unset STUB_COMMIT_FAIL
  export STUB_COMMIT_RAW='{"data":{"repository":{"object":null}}}'
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "unknown content: 커밋을 못 찾았는데(object=null) force-push로 진행했다"
    echo "$output"; dump_calls; false
  }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
}

# ── W25~W28: 소유권은 **force-push 허가**가 아니라 **인가(auto-merge) 조정의 입력**이다(structure r6 R-23) ──
# W20~W24는 소유권을 force-push 경로(adopt·rebuild)에만 걸었다. 그래서 두 구멍이 남았다:
#   ① **skip 경로**: writer가 연 PR인데 그 head 커밋을 **다른 행위자가 갈아치웠다**. 상태가 CLEAN/BLOCKED/
#      UNKNOWN이면 판정은 skip이고 소유권은 **아예 검사되지 않는다** → bump 레인은 그 PR을 계속 신뢰해
#      **무장을 유지하거나 새로 건다**. 그건 **남의 커밋에 머지 인가를 부여**한 것이다: auto-merge는 head OID가
#      아니라 **PR에 붙으므로**, gate가 green이 되는 순간 그 낯선 head가 main으로 들어간다. force-push를
#      안 했다고 안전한 게 아니다 — 인가는 push만큼 강력한 변이다.
#   ② **propose-pr 해제 경로**: ARMED + DIRTY + 낯선 head는 소유권 검증에서 **먼저 죽어** `--disable-auto`에
#      닿지 못했다 → **낡은 인가가 가장 회수돼야 할 때 살아남았다**(정확히 뒤집힌 결과다).
# 계약:
#   · 증명되지 않은 head엔 **절대 무장하지 않는다**(레인 무관).
#   · 이미 무장돼 있으면 **해제한다** — 인가 회수는 언제나 안전한 방향이다.
#   · **순서**: 회수(해제)가 **abort할 수 있는 소유권 검사보다 먼저**다. 안전 방향 행동이 앞, 중단 가능한
#     검사가 뒤다(안 그러면 ②가 그대로 재현된다).
#   · 그 뒤 변이 쪽은 fail-closed(force-push 0 · create 0 · 무장 0).

# 낯선 행위자가 이 브랜치 head에 올린 커밋(정체성·메시지 둘 다 우리 것이 아니다).
foreign_head_commit() {
  export STUB_COMMIT_NAME="ukkiee"
  export STUB_COMMIT_EMAIL="ukkiee@users.noreply.github.com"
  export STUB_COMMIT_MSG="fix: 내가 이 브랜치 head에 올린 커밋"
}

# bats test_tags=regression
@test "W25: an ARMED trusted PR whose head is NOT ours is DISARMED on the bump lane (authorization is revoked, never kept)" {
  # 판정은 skip(CLEAN)이라 force-push는 애초에 없다 — 그런데 **무장은 살아 있다**. 옛 코드는 소유권을
  # skip 경로에서 검사하지 않아 그 무장을 **그대로 뒀다** = 남의 커밋에 머지 인가를 유지한 것이다.
  write_prs "[$(writer_pr 396 CLEAN "$(amr_armed)")]"
  write_heads "$PR_OID"
  foreign_head_commit
  run_ensure_lane bump

  # 변이 쪽은 fail-closed — 하지만 그 전에 인가는 회수돼 있어야 한다.
  [ "$status" -ne 0 ] || {
    echo "unproven head authorized: 낯선 head를 가진 PR #396을 신뢰한 채로 성공했다"
    echo "$output"; dump_calls; false
  }

  # ① 회수(해제) 1회 — 대상은 **인증된 PR 번호**다.
  run disarm_calls 396
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 낯선 head(PR #396)의 auto-merge를 해제하지 않았다(해제 ${output}회, 기대 1회)"
    echo "  auto-merge는 head OID가 아니라 **PR**에 붙는다 — gate가 green이 되는 순간 남의 커밋이 머지된다."
    dump_calls; false
  }
  # 브랜치 셀렉터 금지(동명 포크 PR 오조준).
  run disarm_calls "$BRANCH"
  [ "$output" -eq 0 ]

  # ② 무장은 0회 — 회수해야 할 자리에서 무장하면 정반대다.
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "unproven head authorized: 증명되지 않은 head에 auto-merge를 무장했다"
    dump_calls; false
  }
  # `gh pr merge` 총 호출은 **해제 1회뿐**(무장이 다른 표기로 새지 않았는가).
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ]

  # ③ 변이 0 — 남의 커밋을 밀어내지도, PR을 또 열지도 않는다.
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "W26: an UN-ARMED trusted PR whose head is NOT ours is never armed on the bump lane (no authorization is granted)" {
  # W25의 짝. 무장 갭(R-10)만 보면 "재무장하라"는 신호지만, 그 head는 **우리 것이 아니다** →
  # 재무장은 남의 커밋에 머지 인가를 **새로 부여**하는 짓이다. 갭보다 소유권이 우선한다.
  write_prs "[$(writer_pr 397 CLEAN "$(amr_absent)")]"
  write_heads "$PR_OID"
  foreign_head_commit
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "unproven head authorized: 낯선 head를 가진 PR #397에서 도구가 성공으로 끝났다"
    echo "$output"; dump_calls; false
  }

  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "unproven head authorized: 무장 갭을 이유로 **낯선 head**(PR #397)에 auto-merge를 걸었다(무장 ${arms}회, 기대 0회)"
    echo "  재무장은 desired state지만, 그 전제는 'head가 우리 것'이다 — 갭은 소유권을 대신하지 못한다."
    dump_calls; false
  }
  # 무장된 적이 없으니 회수할 것도 없다 → gh pr merge 총 0회(해제 churn 금지).
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "W27: a DIRTY ARMED PR with a foreign head is disarmed BEFORE the ownership abort (bump lane)" {
  # W21은 "force-push하지 않는다"까지만 고정한다 — 그 PR에 **무장이 살아 있다는 사실**은 건드리지 않는다.
  # 옛 코드는 소유권 검증에서 **먼저 죽어** 무장을 그대로 남겼다: 그 PR은 낯선 head + 머지 인가를 든 채
  # 영원히 열려 있고, main이 움직여 충돌이 풀리는 순간(또는 누가 브랜치를 갱신하는 순간) 머지된다.
  # 계약: 회수(안전 방향)를 먼저 하고, 그 다음에 fail-closed한다.
  write_prs "[$(writer_pr 398 DIRTY "$(amr_armed)")]"
  write_heads "$PR_OID"
  foreign_head_commit
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "destructive force-push: 낯선 head를 가진 DIRTY PR #398에서 도구가 성공으로 끝났다"
    echo "$output"; dump_calls; false
  }

  # ① 인가 회수가 **실제로 실행됐다** — 원장에 남아 있다는 것 자체가 "abort보다 먼저"의 증거다.
  run disarm_calls 398
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives the abort: 낯선 head의 DIRTY PR #398을 해제하지 않고 죽었다(해제 ${output}회, 기대 1회)"
    echo "  소유권 검사가 회수보다 먼저 abort하면, 인가가 **가장 위험한 상태 그대로** 남는다."
    dump_calls; false
  }
  disarm_at="$(first_call gh pr merge --disable-auto)"
  [ -n "$disarm_at" ]

  # ② 파괴는 0 — 남의 커밋을 force-push로 지우지 않는다(W21의 계약을 유지한다).
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "destructive force-push: PR #398의 head(남의 커밋)를 force-push로 지웠다"
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ]
}

# bats test_tags=regression
@test "W28: an ARMED DIRTY PR with a foreign head is disarmed on the propose-pr lane too (revocation precedes the abort)" {
  # ★★ 두 결함이 정확히 겹치는 자리다: **승인 레인**(사람 머지 = 배포 승인)인데 **낡은 무장**이 살아 있고,
  # 게다가 그 head는 **남의 커밋**이다. 옛 코드는 rebuild 판정 → 소유권 검증 → abort 순서라 `--disable-auto`에
  # 닿지 못했다: 인가를 **가장 회수해야 할 상태**에서 정확히 회수하지 못한 것이다.
  # 계약: 회수는 판정·소유권·레인 어느 것에도 가로막히지 않는다(안전 방향 행동이 먼저다).
  write_prs "[$(writer_pr 399 DIRTY "$(amr_armed)")]"
  write_heads "$PR_OID"
  foreign_head_commit
  run_ensure_lane propose-pr
  [ "$status" -ne 0 ] || {
    echo "destructive force-push: 승인 레인이 낯선 head의 DIRTY PR #399을 rebuild했다"
    echo "$output"; dump_calls; false
  }

  # ① 회수 1회 — **인증된 PR 번호**로.
  run disarm_calls 399
  [ "$output" -eq 1 ] || {
    echo "approval gate bypass: 승인 레인이 낯선 head의 무장된 PR #399을 해제하지 못한 채 죽었다(해제 ${output}회, 기대 1회)"
    echo "  소유권 fail-closed가 회수보다 먼저 실행되면, 낡은 인가가 살아남아 사람 승인 없이 머지된다."
    dump_calls; false
  }
  # 브랜치 셀렉터는 금지다(동명 포크 PR이 해제/머지 대상으로 오조준될 수 있다).
  run disarm_calls "$BRANCH"
  [ "$output" -eq 0 ]

  # ② 무장 0 · 변이 0 — 회수만 하고 조용히 죽는다.
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# ── W29~W33: **BEHIND 수렴은 실행기 몫**이다(structure r7 R-25) ────────────────────────────────
# 예전엔 `pr-sweeper.yaml`이 "무장 + BEHIND"인 봇 PR을 `gh pr update-branch`로 전진시켰고, 그 선택 접두에
# `bump-poll/`이 있었다. 두 가지가 동시에 깨진다:
#   ① **승인 게이트 우회**: 스위퍼는 레인을 보지 않는다 → autoDeploy가 true→false로 바뀌어도 이미 무장된
#      PR은 무장된 채 남고, 스위퍼가 브랜치를 갱신해 체크를 재시작시키면 green 시점에 GitHub이 **사람 승인
#      없이 머지**한다. 무장/해제 reconcile은 레인을 아는 실행기만 할 수 있다 → 전진도 같은 소유자여야 한다.
#   ② **소유권 인터록 파괴**: `gh pr update-branch`는 head를 **머지 커밋**으로 만든다 → proveOurCommit이
#      영구 실패 → 무장 회수 + fail-closed → 그 앱의 bump가 **영원히 멈춘다**.
# 계약: BEHIND는 **DIRTY와 같은 변이**(최신 main에서 재구축한 커밋의 leased force-push)로 푼다.
#   head는 언제나 우리의 결정적 bump 커밋 1개로 유지되고, `gh pr update-branch`는 **한 번도 실행되지 않는다**.
#   rebuild는 **레인-무관**(무장만 레인-의존) — 단 해제(③-a)가 **모든 push보다 먼저**여야 안전하다.

# bats test_tags=regression
@test "W29: a BEHIND writer PR is converged by the executor's leased force-push (never by gh pr update-branch)" {
  # bump 레인 + BEHIND + 소유권 증명됨 + 무장 갭 → rebuild(정확한 lease argv) + 재무장. create는 0이다.
  write_prs "[$(writer_pr 410 BEHIND "$(amr_absent)")]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.observed.trusted.mergeStateStatus == "BEHIND"' > /dev/null \
    || { echo "harness: 도구가 BEHIND 상태를 관측하지 못했다"; echo "$output"; dump_calls; false; }

  # ① `gh pr update-branch`는 **절대** 실행되지 않는다 — 머지 커밋 head는 소유권 증명을 영구 파괴한다.
  ub="$(update_branch_calls)"
  [ "$ub" -eq 0 ] || {
    echo "ownership interlock destroyed: 실행기가 'gh pr update-branch'를 실행했다(${ub}회) —"
    echo "  그건 head에 **머지 커밋**을 얹는다 → 다음 주기 proveOurCommit이 실패 → 무장 회수 + fail-closed →"
    echo "  그 앱의 bump가 **영구 정지**한다. BEHIND는 leased force-push로 수렴시킨다."
    dump_calls; false
  }

  # ② BEHIND는 DIRTY와 같은 변이로 풀린다 — 정확한 leased argv 배열 1회.
  run has_call_exact "${PUSH_REBUILD[@]}"
  if [ "$status" -ne 0 ]; then
    echo "stalled deployment: BEHIND한 PR #410을 수렴시키지 않았다 — pr-sweeper가 사라졌으니 아무도 안 고쳐준다"
    echo "  expected(argc=${#PUSH_REBUILD[@]}): ${H_PUSH_REBUILD}"
    dump_calls; false
  fi
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]

  # ③ 무장 축은 그대로 desired state로 수렴한다(무장 갭 → 재무장).
  run arm_calls_num 410
  [ "$output" -eq 1 ] || {
    echo "stalled autoDeploy: BEHIND 수렴을 하면서 무장 갭을 닫지 않았다"
    dump_calls; false
  }

  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "rebuild" ] || {
    echo "ensure-bump-pr decided '$action' while PR #410 is BEHIND (expected rebuild — leased force-push)"
    echo "$JSON"; false
  }
}

# bats test_tags=regression
@test "W30: an ARMED BEHIND PR on the propose-pr lane is DISARMED before any advance (autoDeploy was turned off)" {
  # ★★ R-25의 정확한 형태. autoDeploy:true 시절에 열려 **무장된** PR이 BEHIND로 멈춰 있고, 그 사이
  # autoDeploy가 false로 뒤집혔다. 스위퍼는 레인을 모르니 그냥 전진시켰고 → green 순간 **승인 없이 머지**.
  # 계약: 실행기는 (1) 먼저 **해제**하고 (2) 그 다음에만 전진시킨다. 원장 **순서**가 이빨이다.
  write_prs "[$(writer_pr 411 BEHIND "$(amr_armed)")]"
  write_heads "$PR_OID"
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]

  # ① 해제 1회 — 대상은 인증된 PR 번호.
  run disarm_calls 411
  [ "$output" -eq 1 ] || {
    echo "approval gate bypass: BEHIND + 무장된 승인 PR #411을 해제하지 않았다(해제 ${output}회, 기대 1회)"
    dump_calls; false
  }
  # ② update-branch는 어느 레인에서도 0회.
  ub="$(update_branch_calls)"
  [ "$ub" -eq 0 ] || {
    echo "approval gate bypass: 승인 레인에서 'gh pr update-branch'를 실행했다 — 전진은 해제 뒤에만, 그리고 force-push로만"
    dump_calls; false
  }
  # ③ 무장은 0회.
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ]

  # ④ ★ **해제가 전진보다 먼저**다 — force-push가 체크를 green으로 되돌리기 전에 인가를 회수한다.
  disarm_at="$(first_call gh pr merge --disable-auto)"
  push_at="$(first_call git push)"
  [ -n "$disarm_at" ]
  [ -n "$push_at" ]
  [ "$disarm_at" -lt "$push_at" ] || {
    echo "stale authorization window: 해제(줄 $disarm_at)가 force-push(줄 $push_at)보다 늦다 —"
    echo "  push가 체크를 green으로 만들면 해제 전에 낡은 무장이 머지를 성사시킬 수 있다."
    dump_calls; false
  }
  # ⑤ 수렴 자체는 한다(레인-무관) — BEHIND인 승인 PR은 사람이 머지 버튼을 누를 수 없다(strict 보호).
  run has_call_exact "${PUSH_REBUILD[@]}"
  [ "$status" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "W31: a BEHIND PR whose head is NOT ours is never advanced (disarm, then fail closed)" {
  # BEHIND라고 남의 head를 밀어도 되는 건 아니다. 증명 실패 → 무장 회수 → 변이 0 → fail-closed.
  write_prs "[$(writer_pr 412 BEHIND "$(amr_armed)")]"
  write_heads "$PR_OID"
  foreign_head_commit
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "unproven head advanced: 낯선 head를 가진 BEHIND PR #412에서 도구가 성공으로 끝났다"
    echo "$output"; dump_calls; false
  }
  run disarm_calls 412
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 낯선 head의 BEHIND PR #412 무장을 회수하지 않았다"
    dump_calls; false
  }
  ub="$(update_branch_calls)"
  [ "$ub" -eq 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "destructive force-push: 증명되지 않은 head(PR #412)를 BEHIND라는 이유로 밀었다"
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
}

# bats test_tags=regression
@test "W32: only DIRTY and BEHIND trigger a rebuild (every other merge state pushes nothing)" {
  # ★ livelock 가드. rebuild 트리거는 **정확히 두 상태**다. UNKNOWN(GitHub의 지연 계산)이나 CLEAN/BLOCKED/
  # UNSTABLE을 끼워 넣으면 매 폴링 force-push → 게이트가 영구 재시작 → 배포가 영영 안 끝난다.
  for state in UNKNOWN CLEAN BLOCKED UNSTABLE HAS_HOOKS; do
    : > "$CALLS"
    write_prs "[$(writer_pr 413 "$state" "$(amr_armed)")]"
    write_heads "$PR_OID"
    run_ensure_lane bump
    [ "$status" -eq 0 ] || { echo "state=$state 에서 도구가 죽었다"; echo "$output"; dump_calls; false; }
    pushes="$(count_calls git push)"
    [ "$pushes" -eq 0 ] || {
      echo "deployment livelock: mergeStateStatus=$state 인데 force-push했다(rebuild 트리거는 DIRTY·BEHIND뿐)"
      dump_calls; false
    }
    ub="$(update_branch_calls)"
    [ "$ub" -eq 0 ] || { echo "state=$state 에서 gh pr update-branch를 실행했다"; dump_calls; false; }
    action="$(echo "$JSON" | jq -r '.action')"
    [ "$action" = "skip" ] || { echo "state=$state → '$action'(기대 skip)"; echo "$JSON"; false; }
  done
}

# ── W34~W44: superseded 형제 — **해제는 넓게, close는 증거가 완비될 때만** ─────────────────────
# (app, tag) 한 브랜치만 방문하는 실행기는 더 새 태그가 나오는 순간 옛 PR을 **영영 방문하지 않는다**
# (라이브 좀비 #348·#350·#351: DIRTY + 무장 + 영구 잔류). 그 낡은 인가는 살아 있고, 누가 브랜치를
# 전진시키면 **옛 이미지가 승인 없이 배포**된다. → 실행기가 `bump-poll/<app>-*` 네임스페이스 전체를 소유한다.
#   ① 해제 스윕: 넓은 대상(동일-레포 + writer Bot + 같은 base) · 약한 증거 · **레인 무관** · 중단 불가.
#   ② close 스윕: 증거 전부 만족할 때만. **브랜치는 어떤 경우에도 삭제하지 않는다**.

# 닫아도 되는 완전한 형제 하나를 심는다(증거 전부 충족).
setup_closable_sibling() {
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
}

# bats test_tags=regression
@test "W34: a superseded sibling PR with complete evidence is disarmed and then closed (never branch-deleted)" {
  # 우리 PR은 이번 run에 **새로 만든다**(create) → 열려 있던 형제는 정의상 우리보다 오래됐다.
  write_prs '[]'
  setup_closable_sibling
  run_ensure_lane bump
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }

  # ① 낡은 인가 회수 — 이게 R-25 피해를 0으로 만드는 유일한 행동이다.
  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: superseded 형제 PR #348(무장됨)의 auto-merge를 회수하지 않았다"
    echo "  더 새 태그가 나오면 옛 armed PR은 (app,tag) 키로 도는 실행기에 **영영 방문되지 않는다**."
    dump_calls; false
  }
  # ② close 1회 — 대상은 **인증된 PR 번호**(브랜치 셀렉터 금지).
  run close_calls 348
  [ "$output" -eq 1 ] || {
    echo "zombie PR: 증거가 완비된 superseded 형제 PR #348을 닫지 않았다(close ${output}회, 기대 1회)"
    dump_calls; false
  }
  # ③ 브랜치는 지우지 않는다(ref 삭제는 되돌아가지 않는다 — 하네스가 --delete-branch를 exit 3으로 죽인다).
  run has_arg_exact "--delete-branch"
  [ "$status" -ne 0 ] || {
    echo "irreversible destruction: close에 --delete-branch를 붙였다 — ref 삭제는 되돌릴 수 없다"
    dump_calls; false
  }
  # ④ close는 **맨 마지막 변이**다 — 후계자(우리 PR)가 확정된 뒤에만 닫는다.
  create_at="$(first_call gh pr create)"
  close_at="$(first_call gh pr close)"
  [ -n "$create_at" ]
  [ -n "$close_at" ]
  [ "$create_at" -lt "$close_at" ] || {
    echo "no successor: close(줄 $close_at)가 우리 PR 생성(줄 $create_at)보다 먼저다 — 열린 제안이 0이 될 수 있다"
    dump_calls; false
  }
  # ⑤ 해제가 close보다 먼저다(안전 방향 먼저, 파괴는 뒤).
  disarm_at="$(first_call gh pr merge --disable-auto)"
  [ -n "$disarm_at" ]
  [ "$disarm_at" -lt "$close_at" ]
  # ⑥ 우리 PR은 정상적으로 열리고 무장된다(스윕이 주 판정을 오염시키지 않았는가).
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
  run arm_calls_num 999
  [ "$output" -eq 1 ]
  echo "$JSON" | jq -e '[.superseded[] | select(.closed)] | length == 1' > /dev/null
}

@test "W35: a FORK PR on a sibling branch name is never disarmed and never closed" {
  # 공개 레포다 — 포크는 같은 결정적 브랜치명으로 PR을 열 수 있다. 접두 일치는 소유권의 증거가 **아니다**.
  write_prs '[]'
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" '.isCrossRepository=true')"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "destroyed a stranger's PR: 포크(cross-repo) PR #348을 닫았다 — 외부인의 기여를 죽인다"
    dump_calls; false
  }
  run disarm_calls 348
  [ "$output" -eq 0 ] || { echo "포크 PR의 auto-merge를 건드렸다"; dump_calls; false; }
}

@test "W36: a HUMAN-authored PR on a sibling branch name is never disarmed and never closed" {
  # `bump-poll/**` ruleset(F-0)이 없으므로 그 접두는 **예약돼 있지 않다** — 사람이 쓸 수 있다.
  write_prs '[]'
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" '.author={"login":"ukkiee","__typename":"User"}')"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "destroyed a human's PR: 사람(ukkiee)이 연 PR #348을 닫았다"
    dump_calls; false
  }
  run disarm_calls 348
  [ "$output" -eq 0 ]
}

# bats test_tags=regression
@test "W37: a sibling whose head commit is NOT ours is DISARMED but never closed (revoke, do not destroy)" {
  # ★ 두 축의 분리를 못박는 증인. 소유권을 증명하지 못하면 **닫지 않는다**(파괴 금지) — 그런데
  # **해제는 한다**(인가 회수는 안전 방향이고, R-25의 피해는 해제만으로 0이 된다).
  # close의 증거 요건이 해제의 커버리지를 깎아먹으면 낡은 인가가 살아남는다(= R-25 재발).
  write_prs '[]'
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  sibling_commit "$SIB_OID" "fix: 내가 이 브랜치 head에 올린 커밋" "ukkiee" "ukkiee@users.noreply.github.com"
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: head 소유권을 증명하지 못했다는 이유로 **해제까지** 건너뛰었다"
    echo "  해제는 약한 증거로 충분하다(안전 방향) — close만이 강한 증거를 요구한다."
    dump_calls; false
  }
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "destructive close: head가 우리 것임을 증명하지 못한 PR #348을 닫았다 — 남의 커밋을 매장한다"
    dump_calls; false
  }
}

# bats test_tags=regression
@test "W38: any human trace on a sibling blocks the close (review, comment, assignee, review request, draft, hold label)" {
  # ⚠️ 가장 아픈 오작동: 승인 대기(propose-pr) PR이나 사람이 검토 중인 PR을 발밑에서 닫는 것.
  # 여섯 신호 각각이 **독립적으로** close를 막아야 한다(하나만 구현하면 나머지 다섯이 샌다).
  local sb; sb="$(SIB_BRANCH_OF)"
  for f in '.reviews.totalCount=1' '.comments.nodes=[{"author":{"__typename":"User"}}]' \
           '.assignees.totalCount=1' '.reviewRequests.totalCount=1' \
           '.isDraft=true' '.labels.nodes=[{"name":"hold"}]'; do
    : > "$CALLS"
    : > "$STUB_SIBLINGS"
    write_prs '[]'
    add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" "$f")"
    sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
    run_ensure_lane bump
    [ "$status" -eq 0 ] || { echo "필터 '$f' 에서 도구가 죽었다"; echo "$output"; dump_calls; false; }
    total="$(close_calls_total)"
    [ "$total" -eq 0 ] || {
      echo "destroyed human work: 사람의 흔적('$f')이 있는 형제 PR #348을 닫았다"
      dump_calls; false
    }
    # 해제는 그대로 한다(피해 차단은 close가 아니라 해제가 한다).
    run disarm_calls 348
    [ "$output" -eq 1 ] || { echo "필터 '$f': 해제를 건너뛰었다"; dump_calls; false; }
  done
}

# bats test_tags=regression
@test "W39: a sibling NEWER than our PR is disarmed but never closed (createdAt is the only total order)" {
  # T_old와 T 사이엔 git 순서가 없다(빌드 완료 역전·앱 레포 revert) → 순서 근거는 **PR의 나이**뿐이다.
  # "더 나중에 만들어진 PR만 더 오래된 PR을 닫는다"는 단조 규칙이라 두 실행기가 서로를 닫는 flip-flop이
  # 구조적으로 불가능하다. 우리 PR이 더 **오래됐으면** 닫지 않는다.
  write_prs "[{\"number\":420,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"createdAt\":\"2026-07-13T06:00:00Z\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 421 "$SIB_OID" "2026-07-13T09:00:00Z" "$(amr_armed)")"   # 우리보다 **새롭다**
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "flip-flop: 우리 PR(#420, 06:00)보다 **새로운** 형제 PR #421(09:00)을 닫았다 —"
    echo "  두 실행기가 서로를 매 주기 닫는 무한 파괴 루프가 된다(단조 규칙 위반)."
    dump_calls; false
  }
  run disarm_calls 421
  [ "$output" -eq 1 ]
}

@test "W40: other prefixes and other apps are not siblings (the name boundary is a literal prefix + TAG_RE)" {
  # 정규식 한 글자 실수로 열린 봇 PR 전부가 대상이 되는 걸 막는다. 이름 경계는 **리터럴 접두 + 앵커 완전일치**다.
  write_prs '[]'
  # ① 다른 접두(bump/…) ② 다른 앱(bump-poll/other-…) ③ 모호 파싱(tag 자리가 TAG_RE가 아니다)
  add_sibling "bump/pg-tools" "$SIB_OID" "$(sib_node 500 "$SIB_OID" "2026-07-13T06:00:00Z" "$(amr_armed)")"
  add_sibling "bump-poll/other-${SIB_TAG}" "$SIB_OID" "$(sib_node 501 "$SIB_OID" "2026-07-13T06:00:00Z" "$(amr_armed)")"
  add_sibling "bump-poll/${APP}-sha-aaaaaaa-sha-bbbbbbb" "$SIB_OID" "$(sib_node 502 "$SIB_OID" "2026-07-13T06:00:00Z" "$(amr_armed)")"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "blast radius: 우리 네임스페이스 밖(다른 접두·다른 앱·모호 파싱)의 PR을 닫았다"
    dump_calls; false
  }
  disarms="$(count_calls gh pr merge --disable-auto)"
  [ "$disarms" -eq 0 ] || { echo "남의 네임스페이스 PR의 auto-merge를 건드렸다"; dump_calls; false; }
  echo "$JSON" | jq -e '.superseded | length == 0' > /dev/null \
    || { echo "형제로 오인한 브랜치가 있다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W41: more close candidates than the cap closes NOTHING (a parsing bug cannot mass-close)" {
  write_prs '[]'
  local i=0
  while [ "$i" -lt 4 ]; do
    t="sha-$(printf '%d' $((7000000 + i)))aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    o="$(printf '4%039d' "$i")"
    add_sibling "bump-poll/${APP}-${t}" "$o" "$(sib_node "$((600 + i))" "$o" "2026-07-13T06:0${i}:00Z" "$(amr_armed)")"
    sibling_commit "$o" "$(sib_commit_msg "$t")"
    i=$((i + 1))
  done
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "blast radius: close 후보 4건(캡 3 초과)인데 ${total}건을 닫았다 — 캡을 넘으면 **한 건도** 닫지 않는다"
    dump_calls; false
  }
  # 해제는 전부 한다(캡은 파괴에만 걸린다 — 인가 회수까지 막으면 R-25가 살아난다).
  disarms="$(count_calls gh pr merge --disable-auto)"
  [ "$disarms" -eq 4 ] || {
    echo "stale authorization survives: 캡 초과 시 해제까지 건너뛰었다(해제 ${disarms}회, 기대 4회)"
    dump_calls; false
  }
}

# bats test_tags=regression
@test "W42: a blind sibling sweep never blocks the main decision, but it can never be reported as success either (an unobservable subject is a revocation failure)" {
  # ★★ 두 성질을 **함께** 못박는다(V-2). 예전 증인은 앞의 하나만 봤고, 그래서 **결함을 GREEN으로 잠갔다**:
  #   ① **비-기아**(예전에도 있었다): 스윕이 주 판정을 abort시킬 수 있으면 아무나 `bump-poll/<app>-*` 브랜치
  #      하나를 만들어(또는 API를 흔들어) **배포를 영구 정지**시킬 수 있다 → 메인 변이는 끝까지 간다.
  #   ② **비-침묵**(새로 못박는다): 형제를 **관측하지 못한 것**은 "형제가 없다"가 아니다. 그 브랜치에
  #      **무장된 좀비 PR**이 있었을 수 있는데, 예전 코드는 `closeAbandoned`만 세우고 **exit 0**으로 끝냈다
  #      (`closeAbandoned`는 close(위생)만 막고 종료 코드엔 영향이 0이다 — 종료 코드는 revocationFailures가
  #      정한다) → **회수 대상을 보지도 못한 채 run이 초록이고 telegram도 울리지 않는다**.
  #      같은 실패를 `--reconcile-only`는 exit 1로 냈다 → 두 경로의 "같은 실패 계약"이 **거짓**이었다.
  write_prs '[]'
  export STUB_GIT_SIBLINGS_FAIL=1
  run_ensure_lane bump
  unset STUB_GIT_SIBLINGS_FAIL
  RC="$status"   # ⚠️ 아래 원장 질의(`run …`)가 $status를 덮어쓴다 → 지금 보존한다(하네스 함정)

  # ① 메인 변이는 굶지 않았다 — 스윕은 배포를 막을 수 없다.
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ] || {
    echo "deployment suppressed: 형제 열거 실패가 주 판정(create)을 죽였다 — 억제는 공격 표면이다"
    echo "$JSON"; echo "$stderr"; dump_calls; false
  }
  run has_call_exact "${PUSH_CREATE[@]}"
  [ "$status" -eq 0 ] || { echo "deployment suppressed: 계약 push가 나가지 않았다"; dump_calls; false; }
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || { echo "불완전 열거 위에서 close했다"; dump_calls; false; }

  # ② 그런데 run은 **빨갛다** — 회수 대상을 열거조차 못 했다.
  [ "$RC" -ne 0 ] || {
    echo "silent blind sweep: bump-poll/* 네임스페이스 열거가 실패했는데 실행기가 성공(exit 0)으로 끝났다 —"
    echo "  그 네임스페이스에 **무장된 좀비 PR**이 있었는지 우리는 모른다. '보지 못했다'는 '없다'가 아니다."
    echo "$JSON"; echo "$stderr"; dump_calls; false
  }
  # ③ 그리고 **무엇을 보지 못했는지** 보고에 남는다(주 경로와 --reconcile-only가 같은 키를 쓴다).
  echo "$JSON" | jq -e '.revocationFailures | length == 1' > /dev/null || {
    echo "silent target: 관측 실패를 revocationFailures로 보고하지 않았다"; echo "$JSON"; false
  }
  echo "$JSON" | jq -e '.revocationFailures[0] | test("열거")' > /dev/null || { echo "$JSON"; false; }

  # ── 형제 PR **조회**(GraphQL) 실패도 **글자 그대로 같은 계약**이다 ────────────────────────────
  : > "$CALLS"
  export STUB_SIB_FAIL=1
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  run_ensure_lane bump
  unset STUB_SIB_FAIL
  RC="$status"

  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ] || {
    echo "deployment suppressed: 형제 PR 조회 실패가 주 판정을 죽였다"
    echo "$JSON"; echo "$stderr"; dump_calls; false
  }
  total="$(close_calls_total)"
  [ "$total" -eq 0 ]
  [ "$RC" -ne 0 ] || {
    echo "silent blind sweep: 형제 PR 조회가 실패했는데 run이 초록이다 — 그 브랜치(${sb})의 PR #348은"
    echo "  **무장된 채 열려 있는데** 우리는 그것을 보지도 못했다(그리고 이 앱은 bump 레인이라"
    echo "  --reconcile-only도 그 무장을 '인가된 것'으로 남겨 둘 수 있다)."
    echo "$JSON"; echo "$stderr"; dump_calls; false
  }
  # **실패한 주체(브랜치)가 이름으로 남는다** — exit 코드만으론 어느 형제를 못 봤는지 알 수 없다.
  echo "$JSON" | jq -e --arg b "$sb" '[.revocationFailures[] | select(test($b))] | length == 1' > /dev/null || {
    echo "silent target: 관측하지 못한 형제 브랜치(${sb})가 보고에 없다"
    echo "$JSON"; false
  }
}

# bats test_tags=regression
@test "W43: a failed gh pr create closes nothing (close is a replacement, never a removal)" {
  # close는 제거가 아니라 **교체**다. 우리 PR이 열리지 않았는데 옛 PR을 닫으면 **열린 제안이 0**이 된다.
  write_prs '[]'
  export STUB_GH_CREATE_OUT="Warning: something changed in gh output"   # 번호 파싱 실패 → fail-closed
  setup_closable_sibling
  run_ensure_lane bump
  [ "$status" -ne 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "no successor: 우리 PR이 열리지 않았는데 superseded 형제를 닫았다 — 열린 제안이 0이 된다"
    dump_calls; false
  }
  # 인가 회수는 이미 끝나 있다(그건 안전 방향이라 abort보다 앞선다).
  run disarm_calls 348
  [ "$output" -eq 1 ]
}

# bats test_tags=regression
@test "W44: the propose-pr lane disarms superseded siblings but never closes them (the human's judgment is the point)" {
  # 승인 레인의 PR은 **사람의 리뷰를 기다리는 것이 존재 이유**다. R-25의 피해는 해제로 이미 0이 되었으니,
  # 닫는 것은 owner의 명시적 결정으로 남긴다.
  write_prs '[]'
  setup_closable_sibling
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]
  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 승인 레인이 superseded 형제 #348의 무장을 회수하지 않았다"
    dump_calls; false
  }
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "destroyed an approval PR: 승인 레인에서 superseded 형제를 닫았다 — 사람의 판단이 그 PR의 존재 이유다"
    dump_calls; false
  }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
}

@test "W45: an orphan sibling ref (no open PR) is left alone — the branch is never deleted" {
  # 고아 ref는 남겨 둔다: 그 tag가 다시 후보가 되면 adopt가 접수한다. ref 삭제는 되돌아가지 않는다.
  write_prs '[]'
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" ""    # ref만 있고 열린 PR 0건
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ]   # 새로 만든 우리 PR의 무장뿐
  run has_arg_exact "--delete"
  [ "$status" -ne 0 ] || { echo "irreversible destruction: 고아 형제 ref를 지웠다"; dump_calls; false; }
  echo "$JSON" | jq -e '.superseded[0].number == null' > /dev/null
}

# bats test_tags=regression
@test "W46: our own branch is never a sibling of itself (self-close is structurally impossible)" {
  write_prs "[$(writer_pr 430 CLEAN "$(amr_armed)")]"
  write_heads "$PR_OID"
  # 네임스페이스 열거에 **우리 브랜치도** 들어온다(라이브에서 당연히 그렇다) → 자기 자신은 형제가 아니다.
  printf '%s\t%s\n' "$PR_OID" "refs/heads/$BRANCH" > "$STUB_SIBLINGS"
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.superseded | length == 0' > /dev/null \
    || { echo "self-supersede: 자기 브랜치를 형제로 열거했다"; echo "$output"; false; }
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "self-close: 실행기가 **자기 PR**을 superseded로 닫았다"
    dump_calls; false
  }
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]   # 이미 무장돼 있고 우리 PR이다 → 아무것도 하지 않는다
}

# ── W47~W52 · W59~W61: `--reconcile-only` — **회수는 후보에도, 플래너에도 의존하지 않는다**(H-1 · R-27) ──
# 위의 모든 증인은 "플래너가 이번 주기에 후보를 냈다"를 전제로 한다(--tag가 있어야 도구가 돈다).
# 그런데 호출부의 bump 루프는 action이 bump|propose-pr인 앱만 돈다 — `noop`(핀이 이미 최신)이나
# `refuse`(GHCR 일시 장애·앱 레포 이력 재작성)인 주기엔 그 앱의 실행기가 **한 번도 호출되지 않는다**.
# 그 사이 autoDeploy가 true→false로 뒤집히면, 이미 무장된 PR이 **낡은 머지 인가를 무기한** 들고 있는다.
# ★★ 회수는 **가용성이 아니라 보안 속성**이다 — 플래너가 후보를 내주느냐에 의존해선 안 된다.
#
# ★★★ 그리고 **주체 목록도 플래너에서 오면 안 된다**(R-27). 예전엔 호출부가 `/tmp/plan.json`에서 앱을
#      뽑아 `--reconcile-only --app <app>`로 넘겼다 → reader 토큰이 죽거나·플래너가 죽거나·어떤 앱이
#      플래너 출력에서 빠지기만 해도 그 앱은 **방문조차 되지 않았다**(낡은 무장 생존). 의존을 한 칸
#      옮겼을 뿐(`.action` 필터 → plan.json 존재)이지 끊은 게 아니었다.
#      → 대상은 **`bump-poll/*` 원격 ref**가 권위이고(git ls-remote), `<app>`은 **브랜치명에서 유도**한다.
#      이 모드는 `--app`을 **받지 않는다**(호출부가 대상을 좁히면 그게 곧 회수의 기아다).
#
# 계약(좁다 — "이번 후보가 무엇인지" 알 필요조차 없다):
#   lane=propose-pr → 그 브랜치의 열린 신뢰 PR 무장을 회수한다.
#   lane=bump       → 아무것도 하지 않는다(그 무장은 인가된 것이다).
#   SSOT 없음/깨짐  → **그것도 propose-pr이다**(플래너와 같은 결론) → **회수한다**(R-26).
#                     인가 문맥의 fail-closed는 "아무것도 하지 않는다"가 아니라 **"권한을 거둔다"**이다.
#                     둘은 보고에서만 갈린다: absent(정상 상태 — 조용히) / unreadable(결함 — run이 빨개진다).
# 그리고 이 모드의 변이는 **해제 하나뿐**이다: push·create·무장·close는 어떤 경로로도 일어나지 않는다.

# bats test_tags=regression
@test "W47: --reconcile-only disarms every armed PR of an autoDeploy:false app, with no candidate in play" {
  # ★ 이 증인의 핵심은 **--tag가 없다는 것**이다. 플래너가 noop/refuse를 낸 주기(= 실행기가 호출조차
  # 되지 않던 주기)를 그대로 모델링한다. 그런 주기에도 낡은 인가는 회수돼야 한다.
  write_bindings '{"autoDeploy": false}'
  # 이 앱의 열린 bump-poll PR 둘(서로 다른 tag) — 둘 다 무장돼 있다(autoDeploy:true 시절의 잔재).
  local t2="sha-8888888$(printf '%033d' 0)"
  add_sibling "$(SIB_BRANCH_OF)" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  add_sibling "$(SIB_BRANCH_OF "$t2")" "$ORPHAN_OID" "$(sib_node 350 "$ORPHAN_OID" "2026-07-13T06:35:00Z" "$(amr_armed)")"
  run_reconcile
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }

  # ① 두 건 모두 회수 — 대상은 **인증된 PR 번호**다(브랜치 셀렉터 금지).
  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: autoDeploy:false 앱의 무장된 PR #348을 회수하지 않았다"
    echo "  이 주기엔 후보가 없다(noop/refuse) — 그런데도 해제는 **반드시** 돌아야 한다(해제는 보안 속성이다)."
    dump_calls; false
  }
  run disarm_calls 350
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: autoDeploy:false 앱의 무장된 PR #350을 회수하지 않았다(형제 하나만 돌았다?)"
    dump_calls; false
  }

  # ② 이 모드는 **해제 말고 아무것도 하지 않는다** — 인가를 부여할 길이 구조적으로 없다.
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || { echo "reconcile-only가 push했다"; dump_calls; false; }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || { echo "reconcile-only가 PR을 만들었다"; dump_calls; false; }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || { echo "reconcile-only가 auto-merge를 무장했다 — 이 모드는 회수만 한다"; dump_calls; false; }
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || { echo "reconcile-only가 PR을 닫았다 — close는 이 모드에 존재하지 않는다"; dump_calls; false; }
  ub="$(update_branch_calls)"
  [ "$ub" -eq 0 ]

  # ③ 레인은 **파일에서** 왔다(플래너의 .action이 아니라). 그리고 주체는 **네임스페이스**에서 왔다.
  echo "$JSON" | jq -e '.mode == "reconcile-only"' > /dev/null
  echo "$JSON" | jq -e '[.subjects[] | select(.lane == "propose-pr")] | length == 2' > /dev/null \
    || { echo "레인이 autoDeploy SSOT에서 파생되지 않았다"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '[.subjects[] | select(.disarmed)] | length == 2' > /dev/null
  # app은 **브랜치명에서 유도**됐다(호출부가 준 게 아니다 — --app을 넘기지도 않았다).
  echo "$JSON" | jq -e --arg a "$APP" '[.subjects[] | select(.app == $a)] | length == 2' > /dev/null \
    || { echo "브랜치명에서 app을 유도하지 못했다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W48: --reconcile-only leaves ONLY the newest open PR of an autoDeploy:true app armed (the newest is authorized, its older siblings are not)" {
  # ★★ V-1로 **좁혀진** 증인이다. 예전엔 "autoDeploy:true 앱의 무장은 건드리지 않는다"였는데, 그 문장은
  #    **너무 넓었다**: superseded된 옛 형제의 무장까지 인가된 것으로 취급해 버렸고, 그 형제를 회수할
  #    사람은 주 경로의 스윕뿐인데 그 경로는 플래너가 후보를 내는 주기에만 돈다(noop/refuse면 굶는다).
  #    올바른 문장: **그 앱의 가장 새로운 PR 하나만** 인가된 무장이다.
  # ⚠️ 원래의 anti-churn 의도는 그대로 산다 — 최신 PR의 무장은 **손대지 않는다**(매 10분 지웠다 다시 거는
  #    churn 금지 · noop 주기엔 다시 걸어 줄 bump 루프조차 돌지 않는다).
  write_bindings '{"autoDeploy": true}'
  local t2="sha-8888888$(printf '%033d' 0)"
  # 옛 형제(#348 · 06:34)와 최신(#350 · 06:44) — 둘 다 무장돼 있고 둘 다 head가 우리 커밋이다.
  add_sibling "$(SIB_BRANCH_OF)" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  add_sibling "$(SIB_BRANCH_OF "$t2")" "$ORPHAN_OID" "$(sib_node 350 "$ORPHAN_OID" "2026-07-13T06:44:00Z" "$(amr_armed)")"
  sibling_commit "$ORPHAN_OID" "$(sib_commit_msg "$t2")"
  run_reconcile
  [ "$status" -eq 0 ] || { echo "$JSON"; echo "$stderr"; dump_calls; false; }

  # ① **최신**(#350)의 무장은 그대로다 — 인가된 무장이고, churn을 만들지 않는다.
  run disarm_calls 350
  [ "$output" -eq 0 ] || {
    echo "arming churn: autoDeploy:true 앱의 **최신** PR #350의 무장을 회수했다 —"
    echo "  매 10분 무장을 지웠다 다시 거는 churn이 되고, noop 주기엔 다시 걸어 줄 bump 루프조차 돌지 않는다."
    dump_calls; false
  }
  # ② 그런데 **옛 형제**(#348)는 회수된다 — superseded PR은 레인과 무관하게 머지될 자격이 없다.
  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: superseded된 옛 PR #348(06:34 < 06:44)의 무장을 남겼다 —"
    echo "  이 앱은 bump 레인이라 주 경로의 형제 스윕이 유일한 회수자인데, 그 경로는 플래너가 후보를"
    echo "  낸 주기에만 돈다(noop/refuse면 굶는다) → 낡은 인가가 무기한 살아남는다(무승인 롤백)."
    echo "$JSON"; dump_calls; false
  }
  merges="$(merge_calls)"
  [ "$merges" -eq 1 ] || { echo "gh pr merge ${merges}회(기대 1회 — 옛 형제 해제뿐)"; dump_calls; false; }
  # ③ 이 모드의 변이는 여전히 **해제 하나뿐**이다.
  total="$(close_calls_total)"
  [ "$total" -eq 0 ]
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
  echo "$JSON" | jq -e '[.subjects[] | select(.lane == "bump")] | length == 2' > /dev/null
  echo "$JSON" | jq -e '[.subjects[] | select(.disarmed) | .number] == [348]' > /dev/null \
    || { echo "회수된 주체가 #348 하나가 아니다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W67: --reconcile-only revokes a bump-lane app's superseded sibling with NO candidate, NO planner, and NO caller-supplied app (the sole revoker must not starve on a noop cycle)" {
  # ★★★ V-1의 핵심 증인. 회수 트리거는 **셋**인데(레인 뒤집힘 · superseded 형제 · 증명되지 않은 head)
  #      예전 reconcile 패스는 **첫째만** 다루고 `if (lane === "bump") continue`로 나머지를 통째로 버렸다.
  #      나머지 둘의 유일한 회수자는 **주 경로의 형제 스윕**인데, 호출부는 그 경로를 **플래너가 그 앱의
  #      후보를 낸 주기에만** 부른다(`select(.action == "bump" or .action == "propose-pr")`).
  # ⚠️ 그래서 굶는 순간이 정확히 있다 — 그리고 그건 예외 상태가 아니라 **정상 상태**다:
  #      · `noop`   : bump가 머지된 **직후**(배포 핀 = GHCR 최신 태그) → 후보 없음 → 실행기 미호출.
  #      · `refuse` : 앱 레포 이력 재작성 · source-repo 드리프트 · GHCR 일시 장애.
  #    그 주기에 옛 armed PR은 **열린 채 살아남고 run은 초록이다**(telegram 무발화). 나중에 누가 그
  #    브랜치를 전진시키면("Update branch" · 체크 재실행 · main 이동) **옛 이미지가 승인 없이 머지된다**.
  # ★ 이 증인은 **실행기 계약**이다(호출부 계약이 아니다): 실행기는 플래너가 무엇을 냈는지 **알 필요도,
  #   알 방법도 없어야** 한다. 그래서 여기선 --app·--tag·--action을 **하나도 넘기지 않는다**.
  write_bindings '{"autoDeploy": true}'
  local t2="sha-8888888$(printf '%033d' 0)"
  add_sibling "$(SIB_BRANCH_OF)" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  add_sibling "$(SIB_BRANCH_OF "$t2")" "$ORPHAN_OID" "$(sib_node 350 "$ORPHAN_OID" "2026-07-13T06:44:00Z" "$(amr_armed)")"
  sibling_commit "$ORPHAN_OID" "$(sib_commit_msg "$t2")"

  run_reconcile   # ← 후보(tag)도, 레인도, 대상 앱도, plan.json도 없다. 오직 --reconcile-only뿐이다.
  [ "$status" -eq 0 ] || { echo "$JSON"; echo "$stderr"; dump_calls; false; }

  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 후보 없는 주기(noop/refuse)에 superseded 형제 #348의 무장이 살아남았다."
    echo "  reconcile 패스가 bump 레인을 통째로 건너뛰면, 그 앱의 superseded 무장을 회수할 사람은"
    echo "  **플래너가 후보를 낸 주기의 주 경로**뿐이다 — 그리고 그 주기는 오지 않을 수 있다."
    echo "$JSON"; dump_calls; false
  }
  # 회수 사유가 **superseded**로 보고된다(레인 뒤집힘이 아니라) — 어느 트리거가 물었는지 구분된다.
  echo "$JSON" | jq -e '[.subjects[] | select(.number == 348) | .revokeReason] | length == 1' > /dev/null
  echo "$JSON" | jq -e '.subjects[] | select(.number == 348) | .revokeReason | test("superseded")' > /dev/null \
    || { echo "회수 사유가 superseded로 보고되지 않았다"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.subjects[] | select(.number == 348) | .revokeReason | test("#350")' > /dev/null \
    || { echo "무엇에 의해 superseded됐는지(더 새로운 PR 번호)를 보고하지 않았다"; echo "$JSON"; false; }
  # 그리고 **레인은 여전히 bump다** — 회수가 레인 오독으로 일어난 게 아님을 못박는다(다른 이유의 GREEN 금지).
  echo "$JSON" | jq -e '.subjects[] | select(.number == 348) | .lane == "bump"' > /dev/null
  # 이 모드의 변이는 해제 하나뿐이다(push·create·무장·close 0).
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ]
}

# bats test_tags=regression
@test "W68: when the createdAt order cannot be established, EVERY arming of that bump app is revoked (at least one of them is certainly superseded)" {
  # ★ 애매함의 방향을 정한다. 이 앱엔 열린 신뢰 PR이 **2건**인데 그중 하나의 createdAt을 관측할 수 없다
  #   → 누가 최신인지 증명할 수 없다. 그런데 **이번 후보는 하나뿐이므로 최소 하나는 확실히 superseded다**.
  #   "모르니까 놔둔다"는 그 확실한 낡은 인가를 **확실히 살려 두는** 선택이다.
  # ⚠️ close(파괴)의 관용구("관측할 수 없으면 아무것도 하지 않는다")와 **일부러 반대 방향**이다 —
  #   두 연산의 안전 방향이 반대이기 때문이다: close는 되돌릴 수 없고, 회수는 다음 주기가 되돌린다(R-10).
  write_bindings '{"autoDeploy": true}'
  local t2="sha-8888888$(printf '%033d' 0)"
  add_sibling "$(SIB_BRANCH_OF)" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  # 최신이어야 할 PR의 나이를 **관측할 수 없다**(스키마 드리프트·권한) → 전순서가 무너진다.
  add_sibling "$(SIB_BRANCH_OF "$t2")" "$ORPHAN_OID" "$(sib_node 350 "$ORPHAN_OID" "2026-07-13T06:44:00Z" "$(amr_armed)" 'del(.createdAt)')"
  sibling_commit "$ORPHAN_OID" "$(sib_commit_msg "$t2")"
  run_reconcile
  [ "$status" -eq 0 ] || { echo "$JSON"; echo "$stderr"; dump_calls; false; }

  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 전순서를 세울 수 없다는 이유로 옛 PR #348의 무장을 남겼다 —"
    echo "  이 앱에 열린 신뢰 PR이 2건이면 **최소 하나는 확실히 superseded**다. 모른다는 것이 인가의 근거가 될 수 없다."
    echo "$JSON"; dump_calls; false
  }
  run disarm_calls 350
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 나이를 관측할 수 없는 PR #350의 무장을 '최신일 것'이라며 남겼다"
    echo "$JSON"; dump_calls; false
  }
  echo "$JSON" | jq -e '.subjects[] | select(.number == 348) | .revokeReason | test("createdAt")' > /dev/null \
    || { echo "회수 사유(전순서 불능)를 보고하지 않았다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W69: --reconcile-only revokes an armed PR whose head is not provably ours, in the bump lane too (R-23 parity — ownership is the precondition of authorization)" {
  # ★ R-23은 "증명되지 않은 head엔 무장하지 않고, 이미 무장돼 있으면 회수한다"였는데 그 계약이
  #   **주 경로에만** 있었다 → autoDeploy:true 앱에서 누가 그 head를 갈아치우면, 후보가 없는 주기엔
  #   아무도 그 사실을 확인하지 않고 **남의 커밋에 머지 인가가 걸린 채** 남는다.
  #   무장은 push만큼이나 강력한 변이다: gate가 green이 되는 순간 그 head가 main으로 들어간다.
  write_bindings '{"autoDeploy": true}'   # ← bump 레인이다(그런데도 회수한다 — 소유권은 레인과 직교한다)
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  # 이 head는 **우리 bump 커밋이 아니다**(누군가 이 ref에 자기 커밋을 올렸다).
  sibling_commit "$SIB_OID" "fix: 내가 이 브랜치 head에 올린 커밋" "ukkiee" "ukkiee@users.noreply.github.com"
  run_reconcile
  [ "$status" -eq 0 ] || { echo "$JSON"; echo "$stderr"; dump_calls; false; }

  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "merge authorization on a stranger's commit: head가 우리 것임이 증명되지 않은 PR #348의 무장을 남겼다 —"
    echo "  bump 레인이라는 이유로. 소유권은 **인가의 전제조건**이지 레인의 함수가 아니다(R-23)."
    echo "$JSON"; dump_calls; false
  }
  echo "$JSON" | jq -e '.subjects[0].headProven == false' > /dev/null \
    || { echo "head 소유권 판정을 사실로 보고하지 않았다"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.subjects[0].revokeReason | test("R-23")' > /dev/null \
    || { echo "회수 사유가 소유권 미증명으로 보고되지 않았다"; echo "$JSON"; false; }
  # 이 모드는 여전히 **회수만** 한다 — 낯선 head를 만났다고 push하거나 닫지 않는다.
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ]
}

@test "a lone armed PR of a bump app keeps its arming even when its createdAt is unobservable (no sibling, no supersession, no churn)" {
  # ⚠️⚠️ **characterization(태그 없음)** — 이유를 정확히 적어 둔다: 이 증인의 유일한 단언은 "회수하지
  #    **않는다**"이고, baseline은 `--reconcile-only`를 모르는 채 exit 2로 죽어 **아무것도 하지 않는다** →
  #    **공짜로 통과**한다. 공짜 통과는 회귀 증인이 아니다(실측으로 확인했다).
  #    (baseline이 exit 2라는 사실에 기대는 `status`/JSON 단언을 붙이면 **엉뚱한 이유의 RED**가 되므로
  #     붙이지 않는다 — 그런 단언은 픽스가 아니라 CLI 표면을 시험한다. 이 모드의 성공·보고는
  #     W48/W67이 같은 픽스처 모양으로 이미 고정한다.)
  # 이 증인이 지키는 것: V-1의 회수 규칙이 **과잉 회수 쪽으로 새지 않는가**(뮤턴트 증명 전용 앵커).
  #   형제가 **없으면** superseded될 수 없다 → 나이를 몰라도 그 무장은 인가된 것이다. `group.length > 1`
  #   가드를 지우면 uniqueNewest(단일 그룹)가 createdAt 부재로 null을 내고 → 이 PR이 회수돼 RED가 된다
  #   (매 10분 무장을 지웠다 다시 거는 churn · noop 주기엔 다시 걸어 줄 bump 루프조차 돌지 않는다).
  write_bindings '{"autoDeploy": true}'
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" 'del(.createdAt)')"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  run_reconcile
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ] || {
    echo "arming churn: 형제가 없는(= superseded될 수 없는) PR #348의 무장을 나이를 모른다는 이유로 회수했다"
    echo "$JSON"; dump_calls; false
  }
}

# bats test_tags=regression
@test "W49: --reconcile-only DISARMS an armed PR whose app has NO .bindings.json (a missing SSOT is the propose-pr lane, not 'do nothing')" {
  # ★★ R-26. 플래너의 계약은 하나다(tools/poll-ghcr.ts planApp — 읽기 전용):
  #       let autoDeploy = false;
  #       if (existsSync(bindingsPath)) { try { … } catch { autoDeploy = false; } }
  #       … action: s.autoDeploy ? "bump" : "propose-pr"
  #    즉 **파일 없음 = autoDeploy:false = propose-pr**(fail-closed). 그런데 옛 probeLane은 같은 상태를
  #    "레인을 알 수 없다"로 읽고 **아무것도 회수하지 않았다** → 바인딩이 사라진 앱(철거·오삭제)에 이미
  #    무장된 PR이 있으면 그 **낡은 머지 인가가 그대로 살아남는다**. 한 SSOT, 두 해석 — 그것도 인가 경계에서.
  # ⚠️ 인가 문맥의 fail-closed는 "아무것도 하지 않는다"가 아니라 **"권한을 거둔다"**이다.
  setup_closable_sibling   # 무장된 열린 writer PR이 있다 — 그런데 이 앱엔 .bindings.json이 **없다**
  run_reconcile
  [ "$status" -eq 0 ] || {
    echo "SSOT 부재는 **정상 상태**다(플래너가 그렇게 규정한다 — 바인딩 없는 앱 = 승인 레인) — run을 죽이지 않는다"
    echo "$JSON"; echo "$stderr"; dump_calls; false
  }

  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: .bindings.json이 **없는** 앱의 무장된 PR #348을 회수하지 않았다 —"
    echo "  플래너는 같은 상태를 propose-pr(승인 레인)로 확정한다. 회수만 '모른다'며 손을 떼면"
    echo "  그 PR은 gate가 green이 되는 순간 **사람 승인 없이 머지**된다(낡은 인가)."
    echo "$JSON"; dump_calls; false
  }
  # 레인은 propose-pr로 **확정**됐다(null이 아니다) — 다만 어떻게 확정됐는지는 구분해 보고한다.
  echo "$JSON" | jq -e '.subjects[0].lane == "propose-pr"' > /dev/null \
    || { echo "SSOT 부재를 propose-pr로 접지 않았다(플래너와 갈라진 두 번째 진실)"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.subjects[0].laneResolution == "absent"' > /dev/null \
    || { echo "absent와 unreadable을 구분해 보고하지 않는다"; echo "$JSON"; false; }
  # 이 모드의 변이는 여전히 **해제 하나뿐**이다.
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ]
}

# bats test_tags=regression
@test "W59: an UNREADABLE autoDeploy SSOT also revokes, and says so loudly (absent and corrupt differ in the report, never in the authorization)" {
  # 같은 R-26의 다른 절반: 깨진 SSOT도 플래너는 `catch { autoDeploy = false; }`로 **propose-pr**에 접는다.
  # → 회수는 **한다**. 다만 이건 사람이 고쳐야 하는 **결함**이므로 run을 빨갛게 만든다(absent와 갈리는 축은
  #   "인가"가 아니라 "보고"다).
  write_bindings 'not json at all'
  setup_closable_sibling
  run_reconcile

  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: **깨진** autoDeploy SSOT 아래에서 무장된 PR #348을 회수하지 않았다 —"
    echo "  '읽을 수 없다'는 'autoDeploy:true'가 아니다. 증명할 수 없는 인가는 거둬야 한다."
    echo "$JSON"; dump_calls; false
  }
  echo "$JSON" | jq -e '.subjects[0].lane == "propose-pr"' > /dev/null
  echo "$JSON" | jq -e '.subjects[0].laneResolution == "unreadable"' > /dev/null \
    || { echo "깨진 SSOT를 absent와 구분해 보고하지 않는다"; echo "$JSON"; false; }
  # 그리고 **시끄럽다** — 깨진 SSOT는 조용히 지나가면 안 된다(사람이 고쳐야 한다).
  echo "$JSON" | jq -e '.failures | length > 0' > /dev/null \
    || { echo "깨진 SSOT를 failures로 보고하지 않았다"; echo "$JSON"; false; }
  # ⚠️ $status가 아니라 $RCODE다 — 위의 `run disarm_calls`가 $status를 이미 덮어썼다(하네스 함정).
  [ "$RCODE" -ne 0 ] || {
    echo "silent corruption: 깨진 autoDeploy SSOT인데 run이 초록이다(telegram 무발화)"
    echo "$JSON"; false
  }
}

# bats test_tags=regression
@test "W60: --reconcile-only takes its subjects from the bump-poll namespace and resolves each app's lane on its own (no caller-supplied app list)" {
  # ★★ R-27. 대상 목록의 출처가 **플래너**면(호출부가 plan.json에서 앱을 뽑아 --app으로 넘기면),
  #    플래너가 죽거나 어떤 앱이 그 출력에서 빠지는 순간 그 앱은 **방문조차 되지 않는다** → 낡은 무장 생존.
  #    그래서 대상은 `bump-poll/*` **원격 ref**가 권위이고, app은 **브랜치명에서 유도**한다.
  # 두 앱이 네임스페이스에 있고 **레인이 서로 다르다** — 한 번의 호출로 각각 옳게 처리돼야 한다.
  write_bindings '{"autoDeploy": false}'                 # page       → 승인 레인 → 회수
  write_bindings_for other '{"autoDeploy": true}'        # other      → 자동 레인 → 그대로 둔다
  add_sibling "$(SIB_BRANCH_OF)" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  add_sibling "bump-poll/other-${SIB_TAG}" "$ORPHAN_OID" "$(sib_node 501 "$ORPHAN_OID" "2026-07-13T06:00:00Z" "$(amr_armed)")"
  # ⚠️ **자동 레인 앱의 head 커밋 픽스처가 필요하다**(V-1의 R-23 패리티): 무장을 **남겨 두려면** 그 head가
  #    우리 bump 커밋임이 증명돼야 한다. 증명하지 못하면 이 패스는 레인과 무관하게 회수한다(W69) —
  #    즉 이 픽스처가 없으면 이 증인은 **엉뚱한 이유로** GREEN/RED가 된다(레인이 아니라 소유권 때문에).
  #    메시지는 **그 브랜치 자신의 (app, tag)** 로 재계산한다(app=other).
  sibling_commit "$ORPHAN_OID" "chore: other 이미지를 ${SIB_TAG}(digest 핀)로 갱신 (GHCR 폴링)"
  run_reconcile
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }

  # ① 승인 레인 앱의 무장은 회수됐다 — 호출부는 이 앱의 이름을 **한 번도 말한 적이 없다**.
  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 네임스페이스에서 유도한 앱(page)의 무장을 회수하지 않았다"
    dump_calls; false
  }
  # ② 자동 레인 앱의 무장은 그대로다(레인은 **앱마다** SSOT에서 따로 풀린다 — 하나로 뭉뚱그리지 않는다).
  run disarm_calls 501
  [ "$output" -eq 0 ] || {
    echo "arming churn: autoDeploy:true 앱(other)의 무장까지 회수했다 — 레인을 앱별로 풀지 않았다"
    dump_calls; false
  }
  echo "$JSON" | jq -e '[.subjects[] | select(.app == "page")   | .lane] == ["propose-pr"]' > /dev/null
  echo "$JSON" | jq -e '[.subjects[] | select(.app == "other")  | .lane] == ["bump"]' > /dev/null
}

@test "W61: --reconcile-only refuses an injected lane OR an injected subject list (--action and --app cannot reach this mode)" {
  # ★ 승인 게이트 우회 봉인(R-11)의 연장 + 회수 기아 봉인(R-27).
  #   · 레인을 인자로 받으면 호출부가 레인을 지어낼 수 있다(autoDeploy:false인데 bump로 넘겨 회수를 끈다).
  #   · **대상(--app)을 인자로 받으면 호출부가 목록을 좁힐 수 있다** — 그 목록의 출처가 플래너면,
  #     플래너가 죽는 순간 회수도 죽는다. 대상은 네임스페이스가 정한다.
  write_bindings '{"autoDeploy": false}'
  setup_closable_sibling
  run --separate-stderr bun tools/ensure-bump-pr.ts --reconcile-only --root "$SSOT_ROOT" --action bump
  [ "$status" -eq 2 ] || {
    echo "lane injection: --reconcile-only가 --action을 받아들였다(exit $status, 기대 2)"
    echo "$output$stderr"; false
  }
  run --separate-stderr bun tools/ensure-bump-pr.ts --reconcile-only --root "$SSOT_ROOT" --app "$APP"
  [ "$status" -eq 2 ] || {
    echo "subject injection: --reconcile-only가 --app을 받아들였다(exit $status, 기대 2) —"
    echo "  호출부가 대상 목록을 정할 수 있으면 그 목록(= 플래너 출력)이 비는 순간 회수가 굶는다."
    echo "$output$stderr"; false
  }
  # 후보(tag)도 받지 않는다 — 이 모드엔 '이번 후보'라는 개념이 없다.
  run --separate-stderr bun tools/ensure-bump-pr.ts --reconcile-only --root "$SSOT_ROOT" --tag "$TAG"
  [ "$status" -eq 2 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# ── R-34: **관측 실패**를 "우리 것이 아니다"로 접으면 무장된 PR이 회수에서 증발한다 ────────────────
# 파서가 둘이었고(본 질의 / 형제·reconcile), 둘이 `author`를 다르게 읽었다:
#   본 파서 : 키 부재 = 스키마 실패 → fail-closed(옳다)
#   형제 파서: 키 부재 = null(계정 삭제)로 접음 → 신뢰 술어가 false → **그 PR이 대상 목록에서 사라진다**
# 그래서 **무장된 writer PR이 reconcile에서 통째로 증발하고 run은 exit 0**이었다(revocationBlind에 닿지도
# 못한다). 방금 세운 V-2 계약("회수 대상을 가릴 수 있는 관측 실패는 그 자체가 회수 실패다")과 정면 충돌이다.
# 픽스는 파서·신뢰 술어를 **하나로 합치는 것**이다: author 키는 반드시 있어야 하고, **명시적 null만**
# 정당한 상태(계정 삭제)다. 키 부재·형식 위반은 관측 실패 → 집계 → 비-0 종료.

# bats test_tags=regression
@test "W72: --reconcile-only never loses an armed PR whose author is unobservable (a missing author is a revocation observation failure, never a silent 'not ours')" {
  local sib
  sib="$(SIB_BRANCH_OF)"
  write_bindings '{"autoDeploy":false}'   # 승인 레인 — 이 무장은 인가되지 않았다(= 회수 대상이다)
  # 무장된 writer PR인데 응답에 **author 키가 없다**(스키마 드리프트·권한·부분 응답).
  add_sibling "$sib" "$SIB_OID" "$(sib_node 341 "$SIB_OID" "2026-07-13T06:30:00Z" "$(amr_armed)" 'del(.author)')"
  run_reconcile

  # ① **조용히 성공하지 않는다** — 이게 결함의 심장이다(무장된 PR이 증발하고 run은 초록이었다).
  [ "$RCODE" -ne 0 ] || {
    echo "armed PR vanished: author를 관측하지 못한 무장 PR을 '우리 것이 아니다'로 접고 exit 0으로 끝났다"
    echo "  → 낡은 머지 인가가 살아남는데 아무도 모른다(telegram 무발화)."
    echo "$JSON"; dump_calls; false
  }
  # ② **무엇을 보지 못했는지** 보고에 이름으로 남는다(회수 실패는 보안 사실이다).
  echo "$JSON" | jq -e --arg b "$sib" '[.revocationFailures[] | select(contains($b))] | length >= 1' > /dev/null \
    || { echo "보고 누락: 관측하지 못한 브랜치($sib)가 revocationFailures에 없다"; echo "$JSON"; false; }
  echo "$JSON" | jq -e --arg b "$sib" '[.failures[] | select(contains($b))] | length >= 1' > /dev/null \
    || { echo "보고 누락: failures에도 없다"; echo "$JSON"; false; }
  # ③ 변이는 0 — 인증하지 못한 PR을 건드리지 않는다(관측 실패는 회수의 근거가 아니라 회수의 **실패**다).
  disarms="$(disarm_calls 341)"
  [ "$disarms" -eq 0 ]
}

# bats test_tags=regression
@test "W73: a sibling whose author cannot be observed turns the run RED, and the main mutation still goes through (blind is not an abort, and it is not a success either)" {
  local sib
  sib="$(SIB_BRANCH_OF)"
  add_sibling "$sib" "$SIB_OID" "$(sib_node 342 "$SIB_OID" "2026-07-13T06:30:00Z" "$(amr_armed)" 'del(.author)')"
  write_prs '[]'   # 이번 후보는 PR이 없다 → 정상 create 경로
  run_ensure_lane bump

  # ① 조용한 성공은 없다(형제 스윕이 그 무장을 **보지 못했다**).
  [ "$status" -ne 0 ] || {
    echo "armed sibling vanished: author 관측 실패를 '우리 것이 아니다'로 접고 run이 초록으로 끝났다"
    echo "$JSON"; dump_calls; false
  }
  # ② 보고에 이름이 남는다.
  echo "$JSON" | jq -e --arg b "$sib" '[.revocationFailures[] | select(contains($b))] | length >= 1' > /dev/null \
    || { echo "보고 누락: 관측하지 못한 형제($sib)가 revocationFailures에 없다"; echo "$JSON"; false; }
  # ③ 그래도 **메인 변이는 끝까지 간다** — 억제는 공격 표면이다(형제 브랜치 하나로 배포를 세울 수 없다).
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "create" ] || { echo "억제됨: 형제의 관측 실패가 메인 판정을 막았다('$action')"; echo "$JSON"; false; }
  run has_call_exact "${PUSH_CREATE[@]}"
  [ "$status" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
  # ④ close(파괴)는 포기한다 — 불완전한 열거 위에서 아무것도 닫지 않는다.
  closes="$(close_calls_total)"
  [ "$closes" -eq 0 ]
}

# bats test_tags=regression
@test "W51: the bespoke pin lane's autoDeploy lives in .image-pin.json and is honoured too" {
  # 바인딩된 앱은 apps/ 레인만이 아니다 — 베스포크 핀 레인(platform/<comp>/prod/.image-pin.json)도
  # 같은 `bump-poll/<app>-*` 네임스페이스를 쓴다(라이브: files). 여기서 SSOT를 못 찾으면 그 앱의
  # 회수가 통째로 fail-closed로 죽어 낡은 무장이 남는다.
  write_image_pin '{"file":"deployment.yaml","path":["spec"],"autoDeploy": false}'
  setup_closable_sibling
  run_reconcile
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }
  echo "$JSON" | jq -e '.subjects[0].lane == "propose-pr"' > /dev/null
  echo "$JSON" | jq -e '.subjects[0].laneResolution == "present"' > /dev/null
  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "stale authorization survives: 베스포크 핀 레인(.image-pin.json)의 autoDeploy:false를 읽지 못했다"
    dump_calls; false
  }
}

# bats test_tags=regression
@test "W52: --reconcile-only never touches forks, humans, or other namespaces" {
  # 회수도 변이다 — 신뢰 경계는 주 경로와 **같다**(동일-레포 + writer Bot + 같은 base + 리터럴 접두).
  # ⚠️ **다른 앱**의 bump-poll 브랜치는 여기 없다 — 그건 이제 정당한 주체다(W60). 경계는 앱이 아니라
  #    "포크·사람·다른 접두"다.
  write_bindings '{"autoDeploy": false}'
  add_sibling "$(SIB_BRANCH_OF)" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" '.isCrossRepository=true')"
  local t2="sha-8888888$(printf '%033d' 0)"
  add_sibling "$(SIB_BRANCH_OF "$t2")" "$ORPHAN_OID" "$(sib_node 349 "$ORPHAN_OID" "2026-07-13T06:35:00Z" "$(amr_armed)" '.author={"login":"ukkiee","__typename":"User"}')"
  add_sibling "bump/pg-tools" "$SIB_OID" "$(sib_node 500 "$SIB_OID" "2026-07-13T06:00:00Z" "$(amr_armed)")"
  run_reconcile
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ] || {
    echo "blast radius: reconcile 패스가 포크/사람/다른 네임스페이스의 PR 무장을 건드렸다(${merges}회, 기대 0회)"
    dump_calls; false
  }
}

# ── W53~W55: **사람의 reopen을 관측한다**(H-3) ──────────────────────────────────────────────────
# reopen은 author도, createdAt도, head도 바꾸지 않고, 그 PR의 유일한 코멘트는 **우리 봇의 close 코멘트**다
# → humanTouchOf의 어떤 신호에도 걸리지 않는다. 그래서 사람이 일부러 되살린 PR을 다음 폴링(≤10분)이
# **조용히 다시 닫는다 — 영원히**. 게다가 옛 close 코멘트는 바로 그 reopen을 해법으로 안내했다
# (도구가 사람을 함정으로 걸어 들어가게 했다).

# bats test_tags=regression
@test "W53: a sibling a human REOPENED is disarmed but never re-closed (the close loop must not fight a human)" {
  write_prs '[]'
  local sb; sb="$(SIB_BRANCH_OF)"
  # REOPENED_EVENT가 1건 — 나머지 신호(리뷰·코멘트·assignee·라벨·draft)는 전부 0이다(reopen만으론
  # 다른 어떤 흔적도 남지 않는다는 게 이 결함의 핵심이다).
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" '.timelineItems.totalCount=1')"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  run_ensure_lane bump
  [ "$status" -eq 0 ]

  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "close loop fights a human: 사람이 **reopen한** PR #348을 다시 닫았다 —"
    echo "  reopen은 author·createdAt·head를 바꾸지 않고 코멘트도 우리 봇 것뿐이라 다른 신호엔 안 걸린다."
    echo "  그래서 이 PR은 10분마다 영원히 다시 닫힌다(그리고 close 코멘트가 reopen을 안내했다)."
    dump_calls; false
  }
  # 회수는 그대로 한다(피해 차단은 close가 아니라 해제가 한다).
  run disarm_calls 348
  [ "$output" -eq 1 ]
  echo "$JSON" | jq -e '.superseded[0].humanTouch != null' > /dev/null

  # ★ **형제 질의문 자체**가 reopen을 조회하는가. 하네스는 질의문과 무관하게 픽스처를 주므로,
  #   질의를 못박지 않으면 필드를 지워도 아무 증인이 죽지 않는다(거짓 GREEN). 그래서 **그 질의 안**에서 본다
  #   ('isDraft createdAt'는 형제 질의의 노드 줄에만 있는 지문이다 — 본 질의는 '... createdAt isDraft' 순서다).
  run query_has 'isDraft createdAt' 'REOPENED_EVENT'
  [ "$status" -eq 0 ] || {
    echo "필드 계약 위반: 형제 PR 질의문이 timelineItems(itemTypes:[REOPENED_EVENT])를 조회하지 않는다 —"
    echo "  reopen을 관측하지 못하면 사람이 되살린 PR을 10분마다 영원히 다시 닫는다."
    dump_calls; false
  }
}

# bats test_tags=regression
@test "W54: an unobservable reopen history blocks the close too (unknown is never a licence to destroy)" {
  # 필드 드리프트(GitHub 스키마 변경·권한 부족)로 timelineItems를 못 읽으면 **닫지 않는다**.
  # 기존 신호들과 같은 관용구다: 관측할 수 없으면 "흔적 있음"으로 읽는다.
  write_prs '[]'
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" 'del(.timelineItems)')"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || {
    echo "destroyed on an unknown: reopen 이력을 **관측할 수 없는데** PR #348을 닫았다"
    dump_calls; false
  }
  run disarm_calls 348
  [ "$output" -eq 1 ]
}

# bats test_tags=regression
@test "W55: the close comment names the escape hatch that actually works (the hold label, not just reopen)" {
  # ★ 도구가 사람을 함정으로 안내하면 안 된다. 옛 코멘트는 "필요하면 reopen하면 된다"라고만 했는데,
  # 그때는 reopen을 관측하지 않아 **다음 주기가 다시 닫았다**. 코멘트는 **실제로 작동하는** 탈출구를
  # 말해야 한다 — 영속적이고 명시적인 것은 hold 라벨이다(라벨은 브랜치·후보가 바뀌어도 남는다).
  write_prs '[]'
  setup_closable_sibling
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  run close_calls 348
  [ "$output" -eq 1 ] || { echo "harness: 형제가 닫히지 않았다 — 코멘트를 검사할 수 없다"; dump_calls; false; }

  comment="$(close_comment)"
  [ -n "$comment" ] || { echo "harness: close 코멘트를 원장에서 되읽지 못했다"; dump_calls; false; }
  # HOLD_LABELS 두 개가 **둘 다** 안내돼야 한다(도구의 상수와 코멘트가 갈라지면 안내가 거짓이 된다).
  echo "$comment" | grep -q 'hold' || {
    echo "misleading close comment: 코멘트가 'hold' 라벨(실제로 작동하는 탈출구)을 안내하지 않는다"
    echo "  관측: $comment"
    false
  }
  echo "$comment" | grep -q 'do-not-close' || {
    echo "misleading close comment: 코멘트가 'do-not-close' 라벨을 안내하지 않는다(HOLD_LABELS와 갈라졌다)"
    echo "  관측: $comment"
    false
  }
}

# ── W56~W58: **사람이 만진 PR은 force-push하지 않는다**(H-4) ────────────────────────────────────
# BEHIND가 rebuild 트리거가 되면서 새 위험이 생겼다: strict 보호 main에서는 **main에 머지가 일어날 때마다**
# 열린 PR이 전부 BEHIND가 된다 → 승인 레인 PR은 사람이 리뷰하는 내내 ~10분마다 BEHIND이고, 가드가 없으면
# 그때마다 force-push당한다: 승인이 **stale review로 취소되고**, 인라인 리뷰 코멘트가 outdated로 접히고,
# required 체크가 처음부터 다시 돈다. close 스윕엔 humanTouch 가드가 있는데 rebuild엔 없었다.
#
# ⚠️ 가르는 축은 **레인이 아니라 흔적**이다. "승인 레인은 아예 rebuild하지 않는다"는 답은 틀렸다 —
#    strict 보호에서 사람은 **BEHIND한 PR을 머지할 수 없고**(버튼이 잠긴다), pr-sweeper는 이제 이
#    네임스페이스를 건드리지 않으므로(R-25) 그 레인이 **구조적으로 막힌다**.
#    흔적 **없음** → rebuild(두 레인 모두 — 파괴할 리뷰 상태가 애초에 없다; W30이 승인 레인의 이 경우를 고정한다)
#    흔적 **있음** → 밀지 않는다(두 레인 모두 — 전진은 사람의 선택이다)

# bats test_tags=regression
@test "W56: a DIRTY PR a human has touched is never force-pushed (review state is not ours to destroy)" {
  write_prs "[$(writer_pr 440 DIRTY "$(amr_armed)" main '.reviews.totalCount=1')]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }

  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "destroyed review state: 사람이 리뷰한 PR #440을 force-push했다 —"
    echo "  stale review로 승인이 취소되고 인라인 코멘트가 outdated로 접힌다. 전진은 사람의 선택이다."
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ] || { echo "DIRTY + 사람 흔적 → '$action'(기대 skip)"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.observed.trusted.humanTouch != null' > /dev/null \
    || { echo "도구가 사람의 흔적을 **관측하지도** 않았다 — skip이 사실에 근거하지 않는다"; echo "$JSON"; false; }
}

# bats test_tags=regression
@test "W57: every human trace blocks the rebuild of a BEHIND PR (review, comment, assignee, request, draft, hold, reopen, and an unobservable connection)" {
  # ★ strict 보호 main에서는 **머지가 일어날 때마다** 열린 PR이 전부 BEHIND가 된다 → 이 경로가
  # 사람이 리뷰 중인 PR을 10분마다 짓밟는 그 경로다. 신호들이 **각각 독립적으로** 막아야 한다.
  # ★ 마지막 두 필터(R-28): 연결이 `totalCount` **없이** 돌아오면 잘렸는지조차 알 수 없다 = 관측 불가.
  #   같은 관용구로 접는다(관측 불가 ⇒ 흔적 있음 ⇒ 밀지 않는다) — 스키마 드리프트가 force-push를
  #   인가하는 일은 없다. (잘림이 **관측된** 경우는 W62·W63이 따로 못박는다.)
  # ⚠️ 연결 **객체 전체**를 준다(`del(.comments.totalCount)`가 아니라) — write_prs의 기본값 병합(`$d + .`)은
  #    키 단위라, 노드에 그 키가 없으면 기본값(totalCount 0)이 되살아나 필터가 no-op이 된다(실측).
  for f in '.reviews.totalCount=1' '.comments.nodes=[{"author":{"__typename":"User"}}]' \
           '.assignees.totalCount=1' '.reviewRequests.totalCount=1' \
           '.isDraft=true' '.labels.nodes=[{"name":"hold"}]' '.timelineItems.totalCount=1' \
           '.comments={"nodes":[]}' '.labels={"nodes":[]}'; do
    : > "$CALLS"
    write_prs "[$(writer_pr 441 BEHIND "$(amr_armed)" main "$f")]"
    write_heads "$PR_OID"
    run_ensure_lane propose-pr
    [ "$status" -eq 0 ] || { echo "필터 '$f'에서 도구가 죽었다"; echo "$output"; echo "$stderr"; dump_calls; false; }
    pushes="$(count_calls git push)"
    [ "$pushes" -eq 0 ] || {
      echo "destroyed review state: 사람의 흔적('$f')이 있는 BEHIND PR #441을 force-push했다"
      dump_calls; false
    }
    # 해제(승인 레인의 안전 방향)는 그대로 한다 — 흔적 가드는 **파괴만** 막는다.
    run disarm_calls 441
    [ "$output" -eq 1 ] || { echo "필터 '$f': 승인 레인의 낡은 무장을 회수하지 않았다"; dump_calls; false; }
  done
}

# bats test_tags=regression
@test "W58: an unobservable human trace also blocks the rebuild (a drifted schema never licenses a force-push)" {
  # 필드 드리프트(스키마 변경·권한 축소)로 흔적을 못 읽으면 **밀지 않는다**. 안전한 귀결은
  # "force-push하지 않는다"이지 "일단 밀어 본다"가 아니다(모르는 상태에서 남의 리뷰를 파괴하지 않는다).
  # ⚠️ write_prs_raw = 정규화 없이 바이트 그대로(하네스가 흔적 필드를 몰래 채워 넣지 않는다).
  write_prs_raw "[{\"number\":442,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"createdAt\":\"2026-07-13T06:00:00Z\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "force-pushed on an unknown: 사람의 흔적을 **관측할 수 없는데** DIRTY PR #442을 force-push했다"
    dump_calls; false
  }
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ]
}

# ── W62~W64: **경계된 흔적 조회는 부재를 날조한다**(R-28) ────────────────────────────────────────
# humanTouchOf의 입력 중 둘은 **상한 있는 연결**이다: `comments(first:100)` · `labels(first:50)`.
# 그 nodes만 보고 "사람 흔적 0"이라고 결론 내리면, 101번째 코멘트나 51번째 라벨에 있는 흔적은
# **보이지 않는 것이 아니라 없는 것**으로 읽힌다 → 실행기가 **리뷰된 PR을 force-push**하고(승인 stale,
# 인라인 코멘트 outdated) **사람이 hold로 지킨 PR을 닫는다**. 우리는 PR 열거에서 정확히 이 함정을 이미
# 고쳤다(상한 → 완전 페이지네이션) — 흔적 조회는 그때 같이 고쳐지지 않았다.
# 중첩 연결은 `--paginate`로 따라갈 수 없으므로(바깥 연결 하나만 민다) **`totalCount`로 잘림을 관측**한다:
#   totalCount > 받은 nodes 수  ⇒ 잘렸다 ⇒ **관측 불가** ⇒ 모듈의 관용구대로 "흔적 있음" ⇒ 닫지도, 밀지도 않는다.
# ⚠️ 그래서 증인은 **두 가지를 함께** 못박는다: ① 잘린 응답에서 파괴하지 않는다(행동) ② 질의가 실제로
#    `totalCount`를 **요청한다**(계약). ②가 없으면 질의에서 totalCount를 지워도 stub이 픽스처를 그대로
#    주므로 아무 증인도 죽지 않는다(거짓 GREEN) — 라이브에선 **모든 PR이 영원히 "흔적 있음"**이 되어
#    DIRTY/BEHIND 수렴과 close가 통째로 멈춘다.

# bats test_tags=regression
@test "W62: a human comment beyond the first page of comments blocks the rebuild (a bounded read fabricates a false absence)" {
  # 첫 페이지(100건)는 **전부 봇 코멘트**다 — nodes만 훑는 구현은 "흔적 없음"으로 읽는다.
  # 그런데 totalCount=101이다: 사람의 코멘트가 그 너머에 **있다**. 그걸 모른 채 force-push하면
  # 그 사람의 리뷰 코멘트가 outdated로 접히고 승인이 stale로 취소된다.
  write_prs "[$(writer_pr 443 DIRTY "$(amr_armed)" main \
    '.comments.nodes=[range(100)|{author:{__typename:"Bot"}}] | .comments.totalCount=101')]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }

  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "false absence authorized a force-push: 코멘트 연결이 **잘렸는데**(totalCount=101 > nodes=100)"
    echo "  DIRTY PR #443을 force-push했다 — 사람의 코멘트는 첫 페이지 밖에 있었다."
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ] || { echo "잘린 코멘트 연결 → '$action'(기대 skip)"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.observed.trusted.humanTouch != null' > /dev/null \
    || { echo "잘림을 '흔적 있음'으로 접지 않았다 — skip이 사실에 근거하지 않는다"; echo "$JSON"; false; }

  # ★ 질의 계약: **본 질의**가 comments/labels의 totalCount를 요청해야 잘림이 관측된다.
  #   (하네스는 질의문과 무관하게 픽스처를 주므로, 이걸 못박지 않으면 필드를 지워도 아무도 안 죽는다.)
  run query_has 'mergeStateStatus' 'comments(first:100){ totalCount'
  [ "$status" -eq 0 ] || {
    echo "필드 계약 위반: 본 PR 질의가 comments의 totalCount를 조회하지 않는다 — 잘림을 **관측할 수 없다**"
    echo "  (경계된 읽기가 부재를 날조한다: 첫 페이지 밖의 사람 코멘트가 '없음'이 되어 force-push된다)"
    dump_calls; false
  }
  run query_has 'mergeStateStatus' 'labels(first:50){ totalCount'
  [ "$status" -eq 0 ] || {
    echo "필드 계약 위반: 본 PR 질의가 labels의 totalCount를 조회하지 않는다 — hold 라벨의 잘림을 관측할 수 없다"
    dump_calls; false
  }
}

# bats test_tags=regression
@test "W63: a hold label beyond the first page of labels blocks the rebuild too (the escape hatch cannot depend on page size)" {
  # `hold`는 사람이 "건드리지 마라"고 말하는 **명시적 탈출구**다(close 코멘트가 바로 그걸 안내한다).
  # 그 라벨이 51번째라는 이유로 무시되면 그 안내는 거짓말이 된다 — 그리고 BEHIND는 strict 보호 main에서
  # **머지마다** 발생하므로, 그 PR은 10분마다 force-push당한다.
  write_prs "[$(writer_pr 444 BEHIND "$(amr_armed)" main \
    '.labels.nodes=[range(50)|{name:("l"+tostring)}] | .labels.totalCount=51')]"
  write_heads "$PR_OID"
  run_ensure_lane bump
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; dump_calls; false; }

  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "false absence authorized a force-push: 라벨 연결이 **잘렸는데**(totalCount=51 > nodes=50)"
    echo "  BEHIND PR #444를 force-push했다 — hold 라벨은 첫 페이지 밖에 있었다."
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "skip" ] || { echo "잘린 라벨 연결 → '$action'(기대 skip)"; echo "$JSON"; false; }
  echo "$JSON" | jq -e '.observed.trusted.humanTouch != null' > /dev/null
}

# bats test_tags=regression
@test "W64: a truncated trace connection never authorizes a close either (the sibling is disarmed, never destroyed)" {
  # 같은 결함의 파괴 쪽 절반: close는 **되돌릴 수 있지만**(reopen) 사람의 판단을 짓밟는다.
  # 두 연결(코멘트·라벨)이 **각각 독립적으로** close를 막아야 한다.
  for f in '.comments.nodes=[range(100)|{author:{__typename:"Bot"}}] | .comments.totalCount=101' \
           '.labels.nodes=[range(50)|{name:("l"+tostring)}] | .labels.totalCount=51'; do
    : > "$CALLS"
    : > "$STUB_SIBLINGS"
    write_prs '[]'
    local sb; sb="$(SIB_BRANCH_OF)"
    add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" "$f")"
    sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
    run_ensure_lane bump
    [ "$status" -eq 0 ] || { echo "필터=$f"; echo "$output"; echo "$stderr"; dump_calls; false; }

    total="$(close_calls_total)"
    [ "$total" -eq 0 ] || {
      echo "destroyed on a truncated read: 흔적 연결이 **잘렸는데**(필터=$f) 형제 PR #348을 닫았다 —"
      echo "  사람의 코멘트/hold 라벨이 첫 페이지 밖에 있었을 수 있다. 모르는 것을 근거로 파괴하지 않는다."
      dump_calls; false
    }
    # 회수는 그대로 한다(피해 차단은 close가 아니라 해제가 한다 — 안전 방향은 언제나 실행된다).
    run disarm_calls 348
    [ "$output" -eq 1 ] || { echo "필터=$f: 형제의 낡은 무장을 회수하지 않았다"; dump_calls; false; }
  done

  # ★ 질의 계약: **형제 질의**도 totalCount를 요청해야 한다(본 질의와 따로 관리되는 질의문이다).
  run query_has 'isDraft createdAt' 'comments(first:100){ totalCount'
  [ "$status" -eq 0 ] || {
    echo "필드 계약 위반: 형제 PR 질의가 comments의 totalCount를 조회하지 않는다 — close가 잘린 읽기로 인가된다"
    dump_calls; false
  }
  run query_has 'isDraft createdAt' 'labels(first:50){ totalCount'
  [ "$status" -eq 0 ] || {
    echo "필드 계약 위반: 형제 PR 질의가 labels의 totalCount를 조회하지 않는다 — hold 라벨의 잘림을 관측할 수 없다"
    dump_calls; false
  }
}

# ══ 회수 실패의 **계약**(structure r9 R-32) — 두 경로가 같은 계약을 쓴다 ═══════════════════════
# 계속하는 것(비-기아)과 성공으로 끝나는 것(비-보고)은 다른 이야기다. 예전엔 형제 해제 실패가 warn 뒤
# **exit 0**으로 끝났다 — 그런데 `autoDeploy:true` 앱에선 `--reconcile-only`가 무장을 **일부러** 건드리지
# 않으므로(인가된 무장이다 — W48), 그 PR이 superseded되는 순간 **이 스윕이 유일한 회수자**다.
# 해제가 실패하고 close마저 막히면(사람 흔적·불완전 열거·CLOSE_MAX 캡·킬 스위치 — 넷 다 **정상 동작**이다)
# → 무장된 좀비 PR이 남는데 **run은 초록이고 telegram도 울리지 않는다**.
# 계약: ① 모든 대상과 **메인 변이는 계속 처리** ② 실패한 회수를 **집계해 끝에서 비-0 종료** ③ **보고에 남긴다**.

# bats test_tags=regression
@test "W65: a failed sibling disarm lets the main mutation through but still turns the run RED (revocation failure is a security fact)" {
  # 형제는 **사람이 만진** superseded PR이다 → close는 humanTouch로 막힌다(정상 동작) → 이 주기에
  # 그 낡은 인가를 거둘 수단은 **해제 하나뿐**이고, 그 해제가 실패한다. 즉 "무장된 채 남는" 그 상태다.
  write_prs '[]'   # 우리 PR은 없다 → 판정은 create(= 메인 변이가 있어야 "굶기지 않았다"를 볼 수 있다)
  local sb; sb="$(SIB_BRANCH_OF)"
  add_sibling "$sb" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)" '.reviews.totalCount=1')"
  sibling_commit "$SIB_OID" "$(sib_commit_msg "$SIB_TAG")"
  export STUB_DISARM_FAIL_PR=348
  run_ensure_lane bump
  unset STUB_DISARM_FAIL_PR
  RC="$status"   # ⚠️ 아래 원장 질의(`run …`)가 $status를 덮어쓴다 → 지금 보존한다(하네스 함정)

  # ① ★ 증상: **회수를 못 했는데 run이 초록이다.** 이게 R-32가 지적한 바로 그 침묵이다.
  [ "$RC" -ne 0 ] || {
    echo "silent revocation failure: 형제 PR #348의 auto-merge 해제가 실패했는데 실행기가 성공(exit 0)으로 끝났다 —"
    echo "  close는 사람의 흔적으로 막혔다(정상) → 그 PR은 **열린 채 무장된 채** 남는다. 그런데 run은 초록이고"
    echo "  telegram도 울리지 않는다. 회수 실패는 **보안 사실**이다 — 조용히 지나갈 수 없다."
    echo "$JSON"; echo "$stderr"; dump_calls; false
  }

  # ② 그래도 **해제를 시도는 했다**(실패했을 뿐) — 시도조차 안 한 것과 구분한다.
  run disarm_calls 348
  [ "$output" -eq 1 ] || {
    echo "형제 PR #348의 해제를 시도조차 하지 않았다(호출 ${output}회, 기대 1회)"
    dump_calls; false
  }

  # ③ ★ 그리고 **메인 변이는 굶지 않았다** — 한 PR의 회수 실패가 배포를 멈추면 억제가 곧 공격 표면이다.
  run has_call_exact "${PUSH_CREATE[@]}"
  [ "$status" -eq 0 ] || {
    echo "starved deployment: 형제 해제 실패가 이번 주기의 push(create)를 막았다 —"
    echo "  회수 실패는 **보고**되어야지 다른 변이를 **굶겨선** 안 된다(억제 = 공격 표면)."
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ] || {
    echo "starved deployment: 형제 해제 실패가 우리 PR 생성을 막았다(create ${creates}회, 기대 1회)"
    dump_calls; false
  }
  run arm_calls_num 999
  [ "$output" -eq 1 ] || {
    echo "starved deployment: 형제 해제 실패가 우리 PR의 무장까지 막았다(무장 ${output}회, 기대 1회)"
    dump_calls; false
  }

  # ④ close는 **여전히 막혀 있다**(사람 흔적) — 즉 그 형제는 진짜로 무장된 채 남았다.
  total="$(close_calls_total)"
  [ "$total" -eq 0 ] || { echo "사람이 만진 형제를 닫았다"; dump_calls; false; }

  # ⑤ ★ **무엇을 회수하지 못했는지 보고에 남는다**(exit 코드만으론 어느 PR인지 알 수 없다).
  echo "$JSON" | jq -e '.revocationFailures | length == 1' > /dev/null || {
    echo "silent target: 회수 실패를 보고하지 않았다 — 어떤 PR의 무장이 남았는지 알 수 없다"
    echo "$JSON"; false
  }
  echo "$JSON" | jq -e '.revocationFailures[0] | test("#348")' > /dev/null || {
    echo "wrong target: 보고된 회수 실패가 PR #348을 가리키지 않는다"
    echo "$JSON"; false
  }
  echo "$JSON" | jq -e '[.superseded[] | select(.disarmed)] | length == 0' > /dev/null
}

# bats test_tags=regression
@test "W66: --reconcile-only carries the SAME failure contract (one failed disarm never starves the next subject, and the pass still exits non-zero)" {
  # ★ 두 회수 경로의 계약이 **갈라지면** 안 된다(R-32): 한쪽은 모아서 비-0, 다른 쪽은 warn 후 초록 —
  #   그 비대칭이 "어느 경로가 회수자였느냐"에 따라 침묵을 만든다. 같은 공유 연산, 같은 계약이어야 한다.
  write_bindings '{"autoDeploy": false}'   # 승인 레인 → 무장은 인가되지 않았다 → 전부 회수 대상이다
  local t2="sha-8888888$(printf '%033d' 0)"
  add_sibling "$(SIB_BRANCH_OF)" "$SIB_OID" "$(sib_node 348 "$SIB_OID" "2026-07-13T06:34:00Z" "$(amr_armed)")"
  add_sibling "$(SIB_BRANCH_OF "$t2")" "$ORPHAN_OID" "$(sib_node 350 "$ORPHAN_OID" "2026-07-13T06:35:00Z" "$(amr_armed)")"
  export STUB_DISARM_FAIL_PR=348   # **첫** 주체의 해제가 실패한다 → 뒤따르는 주체가 굶는가?
  run_reconcile
  unset STUB_DISARM_FAIL_PR

  # ① 뒤따르는 주체는 **여전히 회수된다** — 한 실패가 나머지를 굶기면 그게 곧 회수의 실패다.
  run disarm_calls 350
  [ "$output" -eq 1 ] || {
    echo "starved revocation: PR #348의 해제 실패가 다음 주체(PR #350)의 회수를 굶겼다(해제 ${output}회, 기대 1회) —"
    echo "  회수는 항목별로 격리돼야 한다(한 PR의 API 장애가 다른 앱의 낡은 인가를 살려 두면 안 된다)."
    echo "$JSON"; dump_calls; false
  }
  # ② 그런데 run은 **빨갛다**(같은 계약의 나머지 절반).
  [ "$RCODE" -ne 0 ] || {
    echo "silent revocation failure: 해제 실패가 있었는데 reconcile 패스가 성공(exit 0)으로 끝났다"
    echo "$JSON"; false
  }
  # ③ 보고: **어떤 대상**을 회수하지 못했는가(주 경로와 **같은 키**로 보고한다).
  echo "$JSON" | jq -e '.revocationFailures | length == 1' > /dev/null || {
    echo "두 회수 경로의 보고 형태가 다르다 — 같은 공유 연산이 아니다"; echo "$JSON"; false
  }
  echo "$JSON" | jq -e '.revocationFailures[0] | test("#348")' > /dev/null || { echo "$JSON"; false; }
  echo "$JSON" | jq -e '.failures | length > 0' > /dev/null
  # ④ 실패한 주체는 disarmed=false, 성공한 주체는 true(보고가 사실과 일치한다).
  echo "$JSON" | jq -e '[.subjects[] | select(.disarmed)] | length == 1' > /dev/null || { echo "$JSON"; false; }
  echo "$JSON" | jq -e '[.subjects[] | select(.number == 350 and .disarmed)] | length == 1' > /dev/null || { echo "$JSON"; false; }
}

# ---------------------------------------------------------------------------
# 하네스 자체의 증명 — 이게 GREEN이 아니면 위 증인들은 아무것도 증명하지 못한다
# ---------------------------------------------------------------------------

@test "the harness kills the disarm of exactly one PR (the injection must not spill into arming or the other subjects)" {
  # W65·W66의 주입점 증명. 이게 없으면 stub이 **모든** merge를 죽이거나(→ 다른 이유의 RED) 아무것도
  # 죽이지 않아도(→ 거짓 GREEN) 위 두 증인이 조용히 무의미해진다.
  STUB_DISARM_FAIL_PR=348 run "$STUB/gh" pr merge --disable-auto 348
  [ "$status" -eq 1 ]
  STUB_DISARM_FAIL_PR=348 run "$STUB/gh" pr merge --disable-auto 350
  [ "$status" -eq 0 ]
  STUB_DISARM_FAIL_PR=348 run "$STUB/gh" pr merge --auto --squash 348
  [ "$status" -eq 0 ]
  run "$STUB/gh" pr merge --disable-auto 348
  [ "$status" -eq 0 ]
}

@test "the harness kills every branch-deleting argv (a close can never take the ref with it)" {
  # ★ close를 계약에 넣는다는 건 **파괴 표면을 새로 여는 일**이다. close는 reopen으로 되돌아가지만
  # **ref 삭제는 되돌아가지 않는다** → 삭제 형태를 stub이 exit 3으로 죽여 계약 밖임을 못박는다.
  run "$STUB/gh" pr close 348 --delete-branch
  [ "$status" -eq 3 ]
  run "$STUB/gh" pr close 348 -d
  [ "$status" -eq 3 ]
  run "$STUB/git" push --delete origin "bump-poll/${APP}-${SIB_TAG}"
  [ "$status" -eq 3 ]
  run "$STUB/git" push origin ":refs/heads/bump-poll/${APP}-${SIB_TAG}"
  [ "$status" -eq 3 ]
  run "$STUB/git" push origin "+refs/heads/x:refs/heads/bump-poll/${APP}-${SIB_TAG}"
  [ "$status" -eq 3 ]
  run "$STUB/gh" api --method DELETE "repos/ukyi/homelab/git/refs/heads/bump-poll/${APP}-${SIB_TAG}"
  [ "$status" -eq 3 ]
  # `gh pr update-branch`도 계약 밖이다 — head를 머지 커밋으로 만들어 소유권 증명을 영구 파괴한다.
  run "$STUB/gh" pr update-branch 410
  [ "$status" -eq 3 ]
  # 반대로 계약된 close 형태는 통과한다(가드가 과하게 조여 정상 구현을 막지 않는가).
  run "$STUB/gh" pr close 348 --comment "superseded by #999"
  [ "$status" -eq 0 ]
}


@test "the ledger preserves argv boundaries (a combined-arg push can never satisfy the contract witness)" {
  # plan r4 R-9의 직접 증명. 예전 `"$*"` 원장에서는 아래 **1인자** 호출이 계약 **2인자** 호출과 같은 줄
  # ("git push origin HEAD:refs/heads/<b>")로 기록돼 `grep -Fx` 증인을 통과했다 — 그런데 라이브 git은
  # 'origin HEAD:refs/heads/<b>' 전체를 remote 이름으로 읽고 죽는다(거짓 GREEN).
  run "$STUB/git" push "origin HEAD:refs/heads/${BRANCH}"
  [ "$status" -eq 3 ]

  # ① 원장은 거부(exit 3)보다 **먼저** 기록한다 → 이 호출은 원장에 남는다(argc=3: git, push, '한 덩어리').
  run has_call_exact git push "origin HEAD:refs/heads/${BRANCH}"
  [ "$status" -eq 0 ]

  # ② 그런데 그 레코드는 계약(argc=4)과 **다른 배열**이다 → 증인이 통과하지 못한다. 이게 R-9의 봉인이다.
  run has_call_exact "${PUSH_CREATE[@]}"
  if [ "$status" -eq 0 ]; then
    echo "false GREEN: 붙여 쓴 1인자 push가 계약(2인자 remote+refspec) 증인을 통과했다 — 원장이 인자 경계를 잃었다"
    dump_calls; false
  fi

  # ③ lease까지 통째로 붙인 형태도 마찬가지다(argc=3 vs 계약 argc=5).
  run "$STUB/git" push "--force-with-lease=refs/heads/${BRANCH}:${PR_OID} origin HEAD:refs/heads/${BRANCH}"
  [ "$status" -eq 3 ]
  run has_call_exact "${PUSH_REBUILD[@]}"
  if [ "$status" -eq 0 ]; then
    echo "false GREEN: lease/remote/refspec을 합쳐 쓴 1인자 push가 rebuild 계약 증인을 통과했다"
    dump_calls; false
  fi
}

@test "the harness kills any push argv outside the contract (a witness cannot pass with an unusable push)" {
  # 하네스 자체의 증명(plan r3/r4): stub이 계약 밖 push를 exit 3으로 죽이지 않으면, `origin HEAD:refs/heads/<b>`를
  # 빠뜨리거나 **붙여 쓴** 구현도 lease 단언을 통과해 GREEN이 되고 **라이브 DIRTY/고아 회복은 실패**한다.
  run "$STUB/git" push --force-with-lease=refs/heads/${BRANCH}:${PR_OID}          # 목적지 refspec 누락
  [ "$status" -eq 3 ]
  run "$STUB/git" push --force-with-lease=refs/heads/${BRANCH}:${PR_OID} origin   # 목적지 refspec 누락(원격만)
  [ "$status" -eq 3 ]
  run "$STUB/git" push --force-with-lease=refs/heads/${BRANCH}:${PR_OID} origin "${BRANCH}"  # 미수식 목적지
  [ "$status" -eq 3 ]
  run "$STUB/git" push --force-with-lease origin HEAD:refs/heads/${BRANCH}        # bare lease
  [ "$status" -eq 3 ]
  run "$STUB/git" push --force origin HEAD:refs/heads/${BRANCH}                   # lease 없는 force
  [ "$status" -eq 3 ]
  run "$STUB/git" push -u origin "${BRANCH}"                                      # 미수식 create(구 형태)
  [ "$status" -eq 3 ]

  # ── R-9 negative 증인: **인자를 붙여 쓴** 형태. 평탄화 원장에선 계약과 같은 줄이 됐지만 라이브 git은 죽는다.
  run "$STUB/git" push "origin HEAD:refs/heads/${BRANCH}"                         # remote+refspec 결합(1인자)
  [ "$status" -eq 3 ]
  run "$STUB/git" push "--force-with-lease=refs/heads/${BRANCH}:${PR_OID} origin HEAD:refs/heads/${BRANCH}"  # lease+remote+refspec 결합(1인자)
  [ "$status" -eq 3 ]
  run "$STUB/git" push "--force-with-lease=refs/heads/${BRANCH}:${PR_OID} origin" "HEAD:refs/heads/${BRANCH}" # lease+remote 결합(2인자)
  [ "$status" -eq 3 ]
  run "$STUB/git" push origin "HEAD:refs/heads/${BRANCH}" ""                       # 잉여 빈 인자(argc 계약 위반)
  [ "$status" -eq 3 ]

  # 반대로 계약된 세 형태는 통과한다(가드가 과하게 조여 정상 구현을 막지 않는가).
  run "$STUB/git" push origin "HEAD:refs/heads/${BRANCH}"
  [ "$status" -eq 0 ]
  run "$STUB/git" push "--force-with-lease=refs/heads/${BRANCH}:${PR_OID}" origin "HEAD:refs/heads/${BRANCH}"
  [ "$status" -eq 0 ]
  run "$STUB/git" push "--force-with-lease=refs/heads/${BRANCH}:${ORPHAN_OID}" origin "HEAD:refs/heads/${BRANCH}"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 아래부터 — 보존(태그 없음: baseline에서도 GREEN)과 회귀가 섞여 있다. 태그가 SSOT다.
# baseline이 **조회를 하지 않으므로**, 사실을 근거로 하는 계약(조회·신뢰·판정·fail-closed)은 전부 회귀다.
# ---------------------------------------------------------------------------

@test "the lease is never bare (a bare --force-with-lease is stale-rejected on a fresh checkout)" {
  # ⚠️ baseline에서도 GREEN이다(지금은 lease 자체가 없다) → regression 태그를 붙이지 않는다.
  #    수정이 lease를 **넣되 기대 OID를 빼먹는** 회귀(R-5의 정확한 실패 모드)를 잡는 게 목적이다:
  #    bare lease는 원격 추적 참조가 없는 새 checkout(main만 fetch)에서 항상 stale로 거부된다
  #    (bare 원격 실측: `! [rejected] … (stale info)`).
  # ⚠️ 배열 원장이라 `--force-with-lease`를 **정확한 인자 원소**로 찾는다 — `--force-with-lease=<ref>:<oid>`는
  #    다른 원소이므로 오탐이 없다(문자열 접두 매칭이었다면 정상 lease도 걸렸다).
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  run_ensure
  tool_status="$status"
  # 원장은 stub의 거부(exit 3)보다 **먼저** argv를 기록한다 → 죽은 push도 여기서 잡힌다.
  run has_arg_exact "--force-with-lease"
  if [ "$status" -eq 0 ]; then
    echo "stale lease: bare --force-with-lease(기대 OID 없음) — 새 checkout엔 원격 추적 참조가 없어 항상 stale 거부된다"
    dump_calls; false
  fi
  [ "$tool_status" -eq 0 ]
}

# bats test_tags=regression
@test "no open PR and no remote branch: pushes the branch (exact argv) and opens exactly one PR" {
  # ⚠️ baseline에서 RED다 — 픽스 이전 프로덕션의 push는 `git push -u origin <branch>`(미수식 목적지)라
  #    계약 argv(`git push origin HEAD:refs/heads/<b>`)와 **다른 배열**이다. 정상 create 경로의 완전 argv는
  #    픽스가 새로 못박는 계약이다(목적지를 refs/heads/로 완전 수식 — lease의 <refname>과 글자 그대로 같은 ref).
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted == null'
  echo "$output" | jq -e '.observed.remoteBranch == null'
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]
  # create 경로의 push argv도 **완전 배열**로 못박는다 — lease만 없을 뿐 목적지 계약은 세 경로가 같다.
  run has_call_exact "${PUSH_CREATE[@]}"
  if [ "$status" -ne 0 ]; then
    echo "create push argv 계약 위반 — expected(argc=${#PUSH_CREATE[@]}): ${H_PUSH_CREATE}"
    dump_calls; false
  fi
  creates="$(count_calls gh pr create --base main --head "$BRANCH")"
  [ "$creates" -eq 1 ]
}

# bats test_tags=regression
@test "facts are queried before any mutation (query then decide then mutate)" {
  # R-4의 핵심 순서 계약: 조회가 push/create보다 **먼저** 일어나야 판정이 의미를 갖는다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  list_at="$(first_call gh api graphql)"
  heads_at="$(first_call git ls-remote)"
  push_at="$(first_call git push)"
  create_at="$(first_call gh pr create)"
  [ -n "$list_at" ]
  [ -n "$heads_at" ]
  [ -n "$push_at" ]
  [ -n "$create_at" ]
  [ "$list_at" -lt "$push_at" ]
  [ "$heads_at" -lt "$push_at" ]
  [ "$list_at" -lt "$create_at" ]
  [ "$heads_at" -lt "$create_at" ]
  [ "$push_at" -lt "$create_at" ]
}

# bats test_tags=regression
@test "the PR query is an UNBOUNDED paginated connection query (no --limit can be saturated by forks)" {
  # ★★ 이 증인이 "포크로 배포를 정지시킬 수 없다"는 계약의 **구조적** 절반이다.
  # 경계된 조회(`gh pr list --limit N`)는 두 갈래로 다 진다: 상한을 믿으면 자기 PR을 고아로 오인하고,
  # 상한에서 fail-closed하면 **포크로 페이지를 채우는 것만으로 모든 폴링이 죽는다**(배포 정지 무기).
  # 유일한 출구는 상한을 없애는 것 — `--paginate`가 hasNextPage=false까지 따라간다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]

  # ① connection 질의를 gh api graphql로 낸다(argv 접두 배열이 계약).
  run count_calls gh api graphql
  [ "$output" -ge 1 ] || {
    echo "조회 argv 계약 위반 — gh api graphql … 이 한 번도 불리지 않았다"
    dump_calls; false
  }
  # 변수는 **정확한 인자 원소**로 넘어간다(붙여 쓰면 gh가 못 읽는다). owner/repo는 gh 플레이스홀더가 채운다.
  # ★ R-40: 조회 대상은 브랜치명(head)이 아니라 **우리 ref의 qualifiedName**(refs/heads/<b>)이다 — 포크가
  #   같은 이름으로 오염시킬 수 없는 권위 있는 same-repo ref. `-f ref=`(raw-field)로 넘긴다.
  for want in "owner={owner}" "repo={repo}" "ref=refs/heads/$BRANCH"; do
    run has_arg_exact "$want"
    [ "$status" -eq 0 ] || { echo "조회 변수 계약 위반: '$want' 인자가 없다"; dump_calls; false; }
  done

  # ①-b ★★ **전 페이지를 한 subprocess 캡처에 담지 않는다**(structure r10 R-33) ────────────────
  # `--paginate --slurp`은 열거를 끝까지 따라가지만 그 **전부를 한 응답**으로 받는다. spawnSync의 출력
  # 버퍼는 유한하고(bun 1.3.14 실측: 기본 **1 MiB**, 초과 시 자식이 SIGTERM으로 살해되고 ENOBUFS),
  # PR 하나가 comments(first:100)·labels(first:50)까지 실어 오므로 수 KB다 → **같은 head의 포크 PR을
  # 수백 건 여는 것만으로 응답 총량이 그 버퍼를 넘겨** gh를 죽일 수 있다 = 그 앱의 폴링이 매 주기 죽는다.
  # GraphQL 계층에서 없앤 **포크 포화 = 배포 정지 무기**가 프로세스 계층에서 그대로 되살아난다.
  # → 캡처 하나는 **한 페이지**여야 한다(도구가 endCursor를 직접 따라간다). 실제 다중 페이지 완주는
  #   아래 포화 증인(W70)이 **1 MiB를 실제로 넘겨서** 증명한다 — 여기선 argv 계약만 못박는다.
  run has_arg_exact "--slurp"
  [ "$status" -ne 0 ] || {
    echo "capture-bound regression: 조회가 --slurp으로 **전 페이지를 한 캡처**에 받는다"
    echo "  → spawnSync 버퍼(1 MiB) 초과 = gh 살해 = 포크 포화로 배포를 정지시킬 수 있다(R-33)."
    dump_calls; false
  }
  run has_arg_exact "--paginate"
  [ "$status" -ne 0 ] || {
    echo "capture-bound regression: 조회가 --paginate로 **전 페이지를 한 프로세스**에서 받는다"
    echo "  → 응답 총량이 캡처 버퍼를 넘기면 gh가 죽는다. 페이지는 도구가 endCursor로 따라가야 한다(R-33)."
    dump_calls; false
  }

  # ② 경계된 조회로 되돌아가지 않았는가(gh pr list·--limit은 존재해선 안 된다).
  run count_calls gh pr list
  [ "$output" -eq 0 ] || {
    echo "bounded query regression: gh pr list(경계된 조회)로 되돌아갔다 — 포크가 페이지를 채우면 배포가 정지한다"
    dump_calls; false
  }
  run has_arg_exact "--limit"
  [ "$status" -ne 0 ] || {
    echo "bounded query regression: 조회에 --limit이 붙었다 — 상한은 곧 포크가 채울 수 있는 정지 지점이다"
    dump_calls; false
  }

  # ③ 페이지네이션 계약: 도구가 endCursor를 직접 따라가려면 $endCursor 변수 + pageInfo{hasNextPage,endCursor}가
  #    질의에 있어야 한다. 그리고 조회는 **ref-연결**이어야 한다(R-40): ref(qualifiedName:$ref) +
  #    associatedPullRequests. `headRefName`(이름-매치)은 없어야 한다 — 그게 포크 오염 표면이었다.
  for needle in 'pageInfo' 'hasNextPage' 'endCursor' '$endCursor' 'ref(qualifiedName' 'associatedPullRequests' 'states:OPEN'; do
    run has_substr "$needle"
    [ "$status" -eq 0 ] || {
      echo "페이지네이션/필터 계약 위반: GraphQL 질의문에 '$needle'이 없다"
      dump_calls; false
    }
  done
  # ③-b ★ 이름-매치 조회(pullRequests(headRefName))로 되돌아가지 않았는가 — 그건 포크가 같은 이름으로
  #     오염시킬 수 있는 취약 표면이다(R-40의 결함 그 자체).
  run has_substr 'headRefName:'
  [ "$status" -ne 0 ] || {
    echo "fork-taintable query regression: 조회가 headRefName 이름-매치로 되돌아갔다 — 포크가 같은 브랜치명으로 오염시킬 수 있다(R-40)"
    dump_calls; false
  }

  # ④ 판정에 필요한 필드가 전부 있는가(빠지면 판정이 조용히 무너진다):
  #    headRefOid=lease 기대값 / autoMergeRequest=무장 관측 / isCrossRepository·__typename=신뢰 경계
  #    / baseRefName=(head, base) 식별
  for needle in 'headRefOid' 'autoMergeRequest' 'isCrossRepository' 'baseRefName' '__typename' 'mergeStateStatus'; do
    run has_substr "$needle"
    [ "$status" -eq 0 ] || {
      echo "필드 계약 위반: GraphQL 질의문에 '$needle'이 없다"
      dump_calls; false
    }
  done

  # ⑤ ★ **사람의 흔적**도 본 질의의 사실이다(H-4) — 이걸 조회하지 않으면 rebuild 가드가 관측할 게 없다.
  #    (하네스의 픽스처는 질의문과 무관하게 응답을 주므로, 질의문 자체를 못박지 않으면 필드를 지워도
  #     아무 증인이 죽지 않는다 — 그 사각지대를 여기서 닫는다.)
  for needle in 'isDraft' 'reviews' 'reviewRequests' 'assignees' 'comments' 'labels' 'REOPENED_EVENT'; do
    run has_substr "$needle"
    [ "$status" -eq 0 ] || {
      echo "필드 계약 위반: 본 PR 질의문에 '$needle'이 없다 — 사람의 흔적을 관측하지 못하면"
      echo "  리뷰 중인 PR을 BEHIND라는 이유로 10분마다 force-push한다(승인이 stale로 취소된다)."
      dump_calls; false
    }
  done
}

# bats test_tags=regression
@test "the query never touches the SEARCH api (eventual consistency would fabricate a false absence)" {
  # 심층 방어 + 강한 일관성:
  #   ① `gh pr list --author/--app`는 내부적으로 **검색 API**로 갈아탄다(실측 GH_DEBUG=api: SearchType 프로브
  #      + search(...)). 검색 인덱스는 **결과적 일관성**이라 직전 주기(10분 전)가 만든 PR이 아직 안 잡히면
  #      **공격자 없이도** 거짓 부재가 난다 → 자기 PR을 고아로 오인해 force-push + 중복 create.
  #   ② GraphQL로 옮긴 뒤에도 같은 함정이 있다: `search(...)` 커넥션을 쓰면 똑같이 인덱스에 의존한다.
  # 판정은 primary datastore(=repository.pullRequests connection)만 본다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  run has_arg_exact "--author"
  [ "$status" -ne 0 ] || { echo "search-index dependency: --author(검색 API 경로)"; dump_calls; false; }
  run has_arg_exact "--app"
  [ "$status" -ne 0 ] || { echo "search-index dependency: --app(검색 API 경로)"; dump_calls; false; }
  run has_substr 'search('
  [ "$status" -ne 0 ] || {
    echo "search-index dependency: GraphQL 질의가 search(...) 커넥션을 쓴다 — 결과적 일관성이라 거짓 부재가 난다"
    dump_calls; false
  }
  # 강한 일관성 표면을 쓰는가(repository.ref(...).associatedPullRequests — primary datastore, R-40).
  run has_substr 'associatedPullRequests('
  [ "$status" -eq 0 ]
}

# bats test_tags=regression
@test "the remote branch is probed with git ls-remote on the deterministic branch" {
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  run has_call_exact git ls-remote --heads origin "$BRANCH"
  if [ "$status" -ne 0 ]; then
    echo "조회 argv 계약 위반 — git ls-remote --heads origin <b>"
    dump_calls; false
  fi
}

# bats test_tags=regression
@test "a fork (cross-repo) PR on the same branch name is never trusted (and does not own our branch)" {
  # 공개 레포 — 포크 PR은 같은 브랜치명 + 그럴듯한 본문을 아무나 올릴 수 있다. 이걸 신뢰하면
  # 포크 PR 하나로 배포를 무기한 억제할 수 있다(억제 = 공격 표면) → 신뢰 0.
  # ★★ R-40: 이제 포크는 **관측조차 되지 않는다**. 조회는 `repository.ref(우리 ref).associatedPullRequests`라
  #    포크 PR의 head(포크 레포 ref)는 이 connection에 **구조적으로** 들어오지 못한다(라이브 실측: head-연결).
  #    그래서 포크 노드는 응답에 없다(crossRepo == 0) — "관측했으나 신뢰 안 함"보다 강한 보장이다.
  # ⚠️ 포크의 head는 **자기 레포의 ref**다 — 우리 레포엔 그 브랜치가 없다(그래서 write_heads 없음).
  #    포크 PR은 우리 브랜치를 침해하지 않으므로, 브랜치가 없으면 그대로 create 경로다.
  write_prs "[{\"number\":400,\"isCrossRepository\":true,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(human_author drive-by),\"autoMergeRequest\":$(amr_absent)}]"
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted == null'
  # 포크는 ref-연결 조회에 **애초에 없다**(R-40) → 관측된 포크 0건 · 동일-레포 신뢰 0건.
  echo "$output" | jq -e '.observed.summary.crossRepo == 0'
  echo "$output" | jq -e '.observed.summary.sameRepoTrusted == 0'
  echo "$output" | jq -e '.observed.remoteBranch == null'
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "create" ]
}

# bats test_tags=regression
@test "W18: an untrusted SAME-REPO PR owns the branch — the executor fails closed instead of force-pushing over it" {
  # ★★ 파괴적 경로. 동일-레포(isCrossRepository:false) PR의 head는 **반드시 이 레포의 ref**다 →
  # "사람(ukkiee)이 이 브랜치로 PR을 열어 뒀다" = **그 브랜치는 그 사람 것이다**.
  # 옛 판정은 여기서 trusted=null + remoteBranch!=null을 보고 **adopt**(leased force-push)를 골랐다 →
  # 남의 브랜치를 통째로 덮어쓰고 PR까지 또 연다(작업 파괴). 옛 픽스처는 원격 브랜치를 비워 둬서
  # 그 경로를 숨겼다 — 프로덕션에선 **불가능한 상태**였다.
  # 계약: 신뢰할 수 없는 동일-레포 PR이 이 브랜치에 열려 있으면 **아무것도 변이하지 않는다**(fail-closed).
  write_prs "[{\"number\":401,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(human_author ukkiee),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**(프로덕션 불변식)
  run_ensure
  [ "$status" -ne 0 ] || {
    echo "destructive adopt: 신뢰할 수 없는 동일-레포 PR #401(ukkiee)이 이 브랜치를 소유하는데 도구가 성공으로 끝났다"
    echo "$output"; dump_calls; false
  }
  echo "$output$stderr" | grep -q "신뢰할 수 없는 동일-레포 PR" \
    || { echo "에러 메시지가 원인(신뢰할 수 없는 동일-레포 PR)을 말하지 않는다"; echo "$output$stderr"; false; }

  # 파괴 0 — force-push도, 중복 PR도 없다.
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || {
    echo "destructive adopt: 사람이 연 브랜치 '${BRANCH}'를 force-push로 덮어썼다 — 작업 파괴"
    dump_calls; false
  }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || {
    echo "duplicate PR: 이미 사람의 PR #401이 열린 head에 PR을 또 만들었다"
    dump_calls; false
  }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# bats test_tags=regression
@test "W81: a trusted main PR coexisting with an untrusted different-base PR on the same head is never force-pushed (base-independent ownership — R-45)" {
  # ★ R-45: 파괴 가드가 trusted===null일 때만 발동하면, **신뢰 main PR + 비신뢰 다른-base PR**이 같은 head를
  #   공유할 때 신뢰 PR이 선택돼 DIRTY/BEHIND rebuild가 그 **공유 ref를 force-push** → 비신뢰 PR의 head(리뷰·
  #   사람 상태)를 파괴한다. 소유권은 base-무관 — 비신뢰 PR이 head를 점유하면 신뢰 PR 공존 여부와 무관하게
  #   force-push·create·arm 금지(안전한 회수만 하고 fail-closed).
  write_prs "[$(writer_pr 500 DIRTY "$(amr_armed)"), {\"number\":501,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"gh-pages\",\"author\":$(human_author reviewer),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"   # 공유 head 브랜치는 이 레포에 존재한다
  run_ensure_lane bump
  [ "$status" -ne 0 ] || {
    echo "destructive rebuild over contested head: 신뢰 PR #500이 DIRTY라 rebuild했는데, 같은 head를 점유한 비신뢰 PR #501(→gh-pages)의 head를 재작성했다(R-45)"
    echo "$output"; dump_calls; false
  }
  echo "$output$stderr" | grep -q "배타적으로 우리 것이 아니다" \
    || { echo "에러 메시지가 배타적 head 소유권 위반을 말하지 않는다"; echo "$output$stderr"; false; }
  # ★ 파괴 0: force-push도, 중복 create도, 무장도 없다(안전한 회수만 허용).
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ] || { echo "contested head force-push: 공유 ref를 밀어 #501의 head를 파괴했다($pushes회)"; dump_calls; false; }
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ] || { echo "contested head: 중복 PR을 만들었다($creates회)"; dump_calls; false; }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || { echo "contested head: 애매한 상태에서 무장했다($arms회)"; dump_calls; false; }
}

# ⚠️ baseline에서 RED다(adopt 판정 자체가 없다 — 언제나 create). W18의 파괴 가드가 **포크까지 삼켜**
#    배포를 억제하는 과잉 반응(포크 PR 하나로 영구 정지)을 막는 게 목적이다.
# bats test_tags=regression
@test "a fork-only PR does NOT block adopting our own orphan branch (the fork does not own our ref)" {
  # 위 W18의 정확한 반대편 — **과잉 반응 금지**. 포크 PR은 우리 레포의 ref를 소유할 수 없다(head가 자기 레포에
  # 있다). 그러니 포크 PR이 열려 있어도 우리 레포에 남은 그 브랜치는 **여전히 우리 고아**다(앞선 run이 push엔
  # 성공하고 create에서 죽은 잔해). 여기서 fail-closed로 굳으면 포크 PR 하나로 배포를 영구 억제할 수 있다
  # (억제 = 공격 표면) → 포크는 무시하고 정상적으로 adopt한다.
  write_prs "[{\"number\":400,\"isCrossRepository\":true,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(human_author drive-by),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$ORPHAN_OID"   # 우리 레포에 남은 고아 브랜치(포크는 이걸 만들 수 없다)
  run_ensure
  [ "$status" -eq 0 ] || {
    echo "suppression by fork: 포크 PR 하나가 우리 고아 브랜치의 adopt를 막았다 — 배포가 영구 정지한다"
    echo "$output"; dump_calls; false
  }
  action="$(echo "$JSON" | jq -r '.action')"
  [ "$action" = "adopt" ] || {
    echo "suppression by fork: 포크 PR 때문에 '$action'로 갔다(기대 adopt)"
    echo "$JSON"; false
  }
  run has_call_exact "${PUSH_ADOPT[@]}"
  [ "$status" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
}

# bats test_tags=regression
@test "the writer App is recognized in both gh (app/<slug>) and REST (<slug>[bot]) login forms" {
  # 표기 계약 고정: gh CLI는 `app/ukyi-homelab-writer`, REST/GraphQL은 `ukyi-homelab-writer[bot]`.
  # 한쪽만 인식하면 신뢰 판정이 조용히 무너져(=trusted 0) 중복 PR이 그대로 남는다.
  write_prs "[{\"number\":352,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":{\"login\":\"ukyi-homelab-writer[bot]\",\"__typename\":\"Bot\"},\"autoMergeRequest\":$(amr_armed)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted.number == 352'
}

# ── fail-closed 6종 — **전부 baseline에서 RED**(회귀) ──────────────────────────────────────────
# 픽스 이전 프로덕션은 사실을 **읽지 않았다** → 읽은 사실이 깨졌을 때 어떻게 할지도 없었다. 조회 실패·
# 깨진 JSON·스키마 드리프트에 **조용히 create로 흘러가는 것**이 바로 이 버그의 재발 경로다(중복 PR).
# fail-closed는 픽스가 **새로 만드는** 계약이다 → 회귀 파티션.
# bats test_tags=regression
@test "malformed PR JSON fails closed and mutates nothing" {
  write_prs 'not json at all'
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "empty gh output fails closed (an empty read is not 'no open PRs')" {
  # `gh pr list --json`은 PR이 없어도 '[]'를 준다 → 빈 출력은 조회 실패다. 조용히 create로 흘리면 버그 재현.
  write_prs ''
  run_ensure
  [ "$status" -ne 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "a non-array top level fails closed (gh pr list --json returns an array)" {
  write_prs '{"number":350}'
  run_ensure
  [ "$status" -ne 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "a PR object missing the schema fields fails closed (field-name drift guard)" {
  # gh --json 필드명이 바뀌거나 오타가 나면(예: crossRepository) 조용히 trusted 0이 되어
  # 중복 PR이 되살아난다 → 스키마 위반은 판정하지도, 변이하지도 않는다.
  write_prs "[{\"number\":350,\"crossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":{\"login\":\"app/ukyi-homelab-writer\",\"__typename\":\"Bot\"},\"autoMergeRequest\":$(amr_absent)}]"
  run_ensure
  [ "$status" -ne 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "a PR without headRefOid fails closed (no lease expectation means no safe recovery)" {
  write_prs "[{\"number\":350,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
}

# bats test_tags=regression
@test "a PR without autoMergeRequest fails closed (arming state unknown means re-arm cannot be decided)" {
  # R-10 필드 드리프트 가드. 이 필드가 조용히 사라지면(필드명 변경·오타) 두 갈래로 다 나쁘다:
  #   undefined를 "미무장"으로 읽으면 → 매 폴링 재무장(소음, 남의 PR까지 건드릴 수 있음)
  #   undefined를 "무장됨"으로 읽으면 → 무장 갭이 영영 안 닫혀 autoDeploy 배포가 조용히 정지
  # 둘 다 조용한 오동작이라 판정도 변이도 하지 않는다(headRefOid·isCrossRepository 가드와 동형).
  write_prs "[{\"number\":350,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
}

# bats test_tags=regression
@test "a failing PR query fails closed and mutates nothing" {
  export STUB_GH_LIST_FAIL=1
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "a failing remote-branch probe fails closed and mutates nothing" {
  export STUB_GIT_LSREMOTE_FAIL=1
  write_prs '[]'
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

# bats test_tags=regression
@test "the branch name is deterministic per bump (no RUN_ID — same bump converges to one branch)" {
  # 결정적 브랜치가 중복 PR 픽스의 토대다: run마다 브랜치가 달라지면 조회할 대상 자체가 없다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg b "$BRANCH" '.branch == $b'
  # 결정적 브랜치가 조회의 **대상**이다 — 그 브랜치의 **ref**로 정확히 한 번 질의한다(R-40: ref-연결).
  lists="$(count_calls gh api graphql)"
  run has_arg_exact "ref=refs/heads/$BRANCH"
  [ "$status" -eq 0 ]
  [ "$lists" -eq 1 ]
}

@test "the bump lane arms auto-merge only after the PR is created (never before it exists)" {
  write_prs '[]'
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  create_at="$(first_call gh pr create)"
  merge_at="$(first_call gh pr merge)"
  [ -n "$create_at" ]
  [ -n "$merge_at" ]
  [ "$create_at" -lt "$merge_at" ]
  # 무장은 공유 스크립트 경유가 계약이다(races-6 폴백 재구현 금지).
  arms="$(arm_calls_script)"
  [ "$arms" -eq 1 ]
}

@test "the propose-pr lane NEVER arms auto-merge (approval lane: merge = deployment approval)" {
  # ★ R-11의 핵심 보존 증인. autoDeploy:false 앱의 PR은 **사람이 머지하는 것이 곧 배포 승인**이다.
  # 이 레인에서 무장이 한 번이라도 일어나면 승인 게이트가 통째로 우회된다.
  # 판정(create/adopt/skip/rebuild)이 무엇이든, 사실이 무엇이든, 이 레인은 무장하지 않는다.
  write_prs '[]'
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.lane == "propose-pr"' > /dev/null \
    || { echo "harness: 레인이 출력에 실리지 않았다"; echo "$output"; false; }
  # PR은 열린다(승인 대기) — 하지만 무장은 어느 층위에서도 0이어야 한다.
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "approval gate bypass: propose-pr(autoDeploy:false) 레인이 auto-merge를 무장했다 — 사람 머지 = 배포 승인이 우회된다"
    dump_calls; false
  }
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 0 ] || {
    echo "approval gate bypass: propose-pr 레인이 'gh pr merge'를 실행했다"
    dump_calls; false
  }
}

# bats test_tags=regression
@test "the propose-pr lane does not arm on the SKIP path (a trusted un-armed PR is left alone)" {
  # W4(재무장)가 레인을 넘어 새지 않는가 — 승인 PR에 무장이 없는 건 **정상**이다(그게 승인 레인이다).
  # 재무장은 bump 레인의 desired state일 뿐, "무장 없음"을 보편적 결함으로 취급하면 승인 게이트가 무너진다.
  write_prs "[{\"number\":362,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted.autoMerge == false' > /dev/null
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "approval gate bypass: 승인 레인의 무장 안 된 PR #362을 '재무장'했다 — 승인 PR은 무장이 없는 게 정상이다"
    dump_calls; false
  }
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 0 ]
}

# ── propose-pr × **네 결정 경로 전부** 무장 0(plan r6) ───────────────────────────────────────
# 위 "NEVER arms" 증인은 create 경로만 덮는다 → 무장을 **skip/adopt/rebuild 분기 안에** 심은 구현이
# GREEN이 된다(그 세 경로는 라이브에서 실제로 밟힌다: 이미 열린 PR·고아 브랜치 접수·DIRTY 회복).
# 레인 격리는 **경로별**로 증명한다.
# ⚠️ 아래 세 증인(skip/adopt/rebuild)은 **회귀**다 — baseline엔 그 경로 자체가 없다(언제나 create).
#    create 경로의 레인 격리("NEVER arms")만이 양 끝단에서 GREEN이다(픽스 이전에도 propose-pr은 무장 0).

# bats test_tags=regression
@test "the propose-pr lane does not arm on the ADOPT path (orphan branch is adopted, never armed)" {
  # 고아 원격 브랜치 접수 → PR을 새로 연다. bump 레인이면 생성 직후 무장하지만, 승인 레인은 열기만 한다.
  write_prs '[]'
  write_heads "$ORPHAN_OID"
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg o "$ORPHAN_OID" '.observed.remoteBranch.oid == $o' > /dev/null \
    || { echo "harness: 고아 브랜치 사실을 관측하지 못했다"; echo "$output"; dump_calls; false; }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "approval gate bypass: 승인 레인이 adopt 경로에서 auto-merge를 무장했다 — 사람 머지 = 배포 승인이 우회된다"
    dump_calls; false
  }
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 0 ]
}

# bats test_tags=regression
@test "the propose-pr lane does not arm on the REBUILD path (a DIRTY PR is rebuilt, never armed)" {
  # DIRTY 회복 → PR을 재사용하며 force-push. 무장 갭이 있어도(승인 레인에선 정상) 재무장하지 않는다.
  write_prs "[{\"number\":365,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"baseRefName\":\"main\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted.mergeStateStatus == "DIRTY"' > /dev/null \
    || { echo "harness: DIRTY 상태를 관측하지 못했다"; echo "$output"; dump_calls; false; }
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ] || {
    echo "approval gate bypass: 승인 레인이 rebuild 경로에서 auto-merge를 무장했다 — DIRTY 회복이 배포 승인을 삼켰다"
    dump_calls; false
  }
  gh_arms="$(arm_calls_gh)"
  [ "$gh_arms" -eq 0 ]
}

# ── 해제(disarm)의 반대편 — **과잉 반응 금지**(W8/W9가 새 방향으로 새지 않는가) ────────────────────
# 해제는 "승인 레인 + 무장이 **실제로 남아 있을 때**"만이다. 이 두 증인이 없으면 fix가 해제를 무차별로
# 걸어(매 폴링 churn) 또는 bump 레인의 정상 무장까지 회수해(autoDeploy 배포 정지) 반대 방향으로 깨진다.
# ⚠️ 아래 네 증인은 **전부 baseline에서 RED**다(회귀). 해제(disarm)도, 무장 멱등도 baseline엔 없다:
#    동결된 실행기는 열린 신뢰 PR을 **보지도 않고** 중복 PR을 새로 열어 **무조건 무장**하므로
#    `gh pr merge` 총 호출이 0이 아니다. "무장·해제는 desired state"(양방향 수렴)는 픽스가 만드는 계약이다.
# ⚠️ create/adopt 경로엔 **해제할 대상이 자체가 없다**(신뢰 PR이 없으니 무장도 없다) — 위 두 증인
#    ("NEVER arms" / "does not arm on the ADOPT path")이 `gh pr merge` 총 0회로 이미 그걸 못박는다.

# bats test_tags=regression
@test "the propose-pr lane does not disarm a PR that was never armed (disarming is idempotent)" {
  # 승인 PR에 무장이 없는 건 **정상 상태**다 → 회수할 인가가 없다. 매 폴링 --disable-auto를 때리면
  # 무의미한 API 호출(그리고 gh 에러)로 run이 시끄러워지거나 죽는다.
  write_prs "[$(writer_pr 372 BLOCKED "$(amr_absent)")]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane propose-pr
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted.autoMerge == false' > /dev/null
  run disarm_calls 372
  [ "$output" -eq 0 ] || {
    echo "disarm churn: 무장된 적 없는 승인 PR #372에 --disable-auto를 걸었다(해제는 무장이 있을 때만)"
    dump_calls; false
  }
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# bats test_tags=regression
@test "the bump lane NEVER disarms (the reverse direction must not misfire on autoDeploy apps)" {
  # ★ bump 레인의 desired state는 무장 **있음**이다. 해제 로직이 레인을 넘어 새면 autoDeploy 앱의 무장을
  # 매 폴링 회수해 배포가 조용히 정지한다 — W5(무장 멱등)의 정확한 거울상 결함이다.
  write_prs "[$(writer_pr 373 CLEAN "$(amr_armed)")]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted.autoMerge == true' > /dev/null
  run disarm_calls 373
  [ "$output" -eq 0 ] || {
    echo "stalled autoDeploy: bump 레인이 무장된 PR #373의 auto-merge를 **해제**했다 — 자동 배포가 멈춘다"
    dump_calls; false
  }
  # 이미 무장돼 있으니 재무장도 없다(W5) → gh pr merge 총 0회.
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
}

# bats test_tags=regression
@test "the bump lane does not disarm on the REBUILD path either (a DIRTY armed autoDeploy PR keeps its arming)" {
  # W7(rebuild + 이미 무장 → 재무장 0)의 해제 짝. rebuild 경로에 해제가 새면 DIRTY 회복이 자동 배포를 죽인다.
  write_prs "[$(writer_pr 374 DIRTY "$(amr_armed)")]"
  write_heads "$PR_OID"   # 동일-레포 PR ⇒ 그 head 브랜치는 **이 레포에 존재한다**
  run_ensure_lane bump
  [ "$status" -eq 0 ]
  run disarm_calls 374
  [ "$output" -eq 0 ] || {
    echo "stalled autoDeploy: bump 레인이 rebuild 경로에서 무장된 PR #374을 해제했다"
    dump_calls; false
  }
  merges="$(merge_calls)"
  [ "$merges" -eq 0 ]
  # 판정 축은 그대로 rebuild(해제 로직이 판정을 오염시키지 않았는가).
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 1 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

@test "there is no flag that can arm auto-merge outside the bump lane (--auto-merge does not exist)" {
  # ★ R-11의 **구조적** 봉인. auto-merge를 켜는 입력이 레인 말고 또 있으면, 호출부가 두 레인 모두에
  # 무조건 그 플래그를 넘기는 것만으로 승인 앱이 자동 배포된다(그러면서 모든 증인은 GREEN이다).
  # 그래서 그런 플래그는 **존재하지 않는다** — 알 수 없는 옵션으로 exit 2.
  write_prs '[]'
  run bun tools/ensure-bump-pr.ts --app "$APP" --tag "$TAG" --action propose-pr \
    --title t --body b --auto-merge
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
}

@test "the lane is mandatory with no default (a missing --action can never silently pick a lane)" {
  # 기본값을 두면 호출부가 레인을 빠뜨렸을 때 조용히 한쪽으로 흘러간다:
  #   bump로 기본 → 승인 앱이 자동 배포(승인 게이트 우회)
  #   propose-pr로 기본 → autoDeploy 배포가 조용히 정지
  # 둘 다 조용한 오동작이라 fail-closed(exit 2)로 막는다.
  write_prs '[]'
  run bun tools/ensure-bump-pr.ts --app "$APP" --tag "$TAG" --title t --body b
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- "--action"
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

@test "an unknown lane value exits 2 (only the planner's two actions are lanes)" {
  # 플래너의 다른 action들(noop/refuse)이나 오타가 레인으로 흘러들면 안 된다 — 호출부는 bump/propose-pr만 넘긴다.
  write_prs '[]'
  run bun tools/ensure-bump-pr.ts --app "$APP" --tag "$TAG" --action refuse --title t --body b
  [ "$status" -eq 2 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

@test "an unknown flag exits 2 (no silent default)" {
  run bun tools/ensure-bump-pr.ts --app "$APP" --tag "$TAG" --action bump --title t --body b --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "ensure-bump-pr --help prints usage and exits 0" {
  run bun tools/ensure-bump-pr.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "ensure-bump-pr"
  echo "$output" | grep -q -- "--action"
  echo "$output" | grep -q "propose-pr"
}
