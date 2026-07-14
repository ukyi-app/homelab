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
# 보존(태그 없음 — baseline에서 GREEN): 하네스 자체의 증명(인자 경계·계약 밖 argv 거부)·신뢰 경계
# (포크·타인 불신)·fail-closed·조회-우선 순서·**레인 격리**(propose-pr은 무장 0 / `--auto-merge` 플래그 부재).
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
  export STUB_HEADS="$BATS_TEST_TMPDIR/ls-remote.out" # git ls-remote --heads 가 뱉을 바이트
  : > "$CALLS"
  printf '[]' > "$STUB_PRS"    # 기본: 열린 PR 0건
  : > "$STUB_HEADS"            # 기본: 원격 브랜치 없음

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
elif mode == "dump":
    for i, r in enumerate(records, 1):
        print("%2d) argc=%d  %s" % (i, len(r), " ".join(repr(a) for a in r)))
else:
    sys.exit(2)
PY

  # ── gh stub: pr list는 픽스처를 그대로 내보내고, 변이 서브커맨드는 성공만 흉내낸다.
  #    알 수 없는 서브커맨드는 exit 3 — 도구의 gh 표면이 조용히 넓어지는 걸 막는다.
  cat > "$STUB/gh" <<'GH'
#!/bin/sh
# NUL 구분 원장(R-9): 인자 개수·경계 보존. 레코드는 RS(0x1e)로 종단한다.
{ printf '%s\0' gh "$@"; printf '\036'; } >> "$CALLS"
case "$1:$2" in
  pr:list)
    if [ -n "${STUB_GH_LIST_FAIL:-}" ]; then echo "stub: gh pr list 실패(조회 장애 시뮬)" >&2; exit 1; fi
    cat "$STUB_PRS"
    ;;
  pr:create) echo "https://github.com/ukyi/homelab/pull/999" ;;
  pr:merge)  : ;;
  pr:view)   echo CLEAN ;;
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
    if [ -n "${STUB_GIT_LSREMOTE_FAIL:-}" ]; then echo "stub: git ls-remote 실패(원격 장애 시뮬)" >&2; exit 1; fi
    if [ -f "$STUB_HEADS" ]; then cat "$STUB_HEADS"; fi
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
}

# writer App 작성자의 라이브 표기 — `gh pr list --json author`는 App을 `app/<slug>`로 준다
# (`<slug>[bot]`이 아니다. 실측: {"is_bot":true,"login":"app/ukyi-homelab-writer"}).
writer_author() { printf '{"is_bot":true,"login":"app/ukyi-homelab-writer"}'; }

# `gh pr list --json autoMergeRequest`의 **라이브 실측 스키마**(이 레포에서 확인):
#   무장 안 됨 → null
#   무장 됨   → {"authorEmail":null,"commitBody":null,"commitHeadline":null,"mergeMethod":"SQUASH",
#                "enabledAt":"…","enabledBy":{"is_bot":true,"login":"app/ukyi-homelab-writer"}}
# 무장 여부의 유일한 신호는 **null 여부**다(내부 필드는 판정에 쓰지 않는다 — 무장은 있거나 없거나).
amr_armed()  { printf '{"authorEmail":null,"commitBody":null,"commitHeadline":null,"mergeMethod":"SQUASH","enabledAt":"2026-07-13T06:35:24Z","enabledBy":{"is_bot":true,"login":"app/ukyi-homelab-writer"}}'; }
amr_absent() { printf 'null'; }

# gh pr list --head <branch> --state open
#   --json number,isCrossRepository,mergeStateStatus,author,headRefOid,autoMergeRequest 의 **원시 스키마** 그대로.
write_prs()   { printf '%s' "$1" > "$STUB_PRS"; }
# git ls-remote --heads origin <branch> 의 원시 출력("<oid>\trefs/heads/<branch>").
write_heads() { printf '%s\t%s\n' "$1" "refs/heads/$BRANCH" > "$STUB_HEADS"; }

# 레인(--action)은 **필수**다 — 기본값이 없다(승인 게이트 우회 방지, plan r5 R-11).
# 테스트 기본 레인은 bump(autoDeploy) — 라이브에서 중복 PR 3개가 터진 바로 그 레인이다.
run_ensure_lane() {
  run --separate-stderr bun tools/ensure-bump-pr.ts --app "$APP" --tag "$TAG" --action "$1" \
    --title "chore: ${APP} 이미지 갱신 (자동)" --body "GHCR 폴링 bump"
}
run_ensure() { run_ensure_lane bump; }

# ── 원장 질의(전부 **인자 배열 단위** — 문자열 접두/부분 일치 금지) ─────────────────────────────
# 인자로 준 배열을 **접두**로 갖는 레코드 수(매치 0이면 0).
count_calls()    { python3 "$LEDGER_PY" count "$CALLS" "$@"; }
# argc와 각 위치 문자열이 **정확히** 같은 레코드가 있는가(붙여 쓴 인자는 절대 여기 걸리지 않는다).
has_call_exact() { python3 "$LEDGER_PY" exact "$CALLS" "$@"; }
# 어떤 레코드든 그 **정확한 인자 원소**를 갖는가(예: bare `--force-with-lease` 탐지 — `=…` 형태와 구분된다).
has_arg_exact()  { python3 "$LEDGER_PY" hasarg "$CALLS" "$@"; }
# 접두 일치 첫 레코드의 1-기반 순번(없으면 빈 문자열).
first_call()     { python3 "$LEDGER_PY" first "$CALLS" "$@" || true; }
dump_calls()     { echo "--- 실행된 명령(원장 — argc + 인자 경계 보존) ---"; python3 "$LEDGER_PY" dump "$CALLS"; }

# ── 무장(auto-merge) 횟수 — **두 층위**를 따로 센다 ────────────────────────────────────────────
# ① 도구가 공유 스크립트를 불렀는가(레포 관용구). 도구가 `gh pr merge --auto`를 직접 부르면 races-6
#    폴백(이미 CLEAN인 PR엔 --auto가 에러)이 사라지므로 여기서 0이 되어 잡힌다.
# ② 그 스크립트가 실제로 GitHub에 무장했는가(pass-through stub으로 스크립트가 진짜 실행된다).
# 둘 다 세는 이유: ①만 보면 "부르기만 하고 아무 일도 안 하는" 스크립트가 GREEN이 되고, ②만 보면
# 도구가 관용구를 우회해 raw gh를 불러도 GREEN이 된다.
arm_calls_script() { count_calls bash "$AUTOMERGE_SH" "$BRANCH"; }
arm_calls_gh()     { count_calls gh pr merge; }

# ---------------------------------------------------------------------------
# 회귀 — 현재 RED (실행기 seam: 도구가 실제로 낸 명령을 단언한다)
# ---------------------------------------------------------------------------

# bats test_tags=regression
@test "W1: an open same-repo writer PR suppresses every mutation (no push, no create)" {
  # PR은 **이미 무장**돼 있다 → 이 주기의 옳은 행동은 문자 그대로 "아무것도 하지 않음"이다
  # (무장이 빠진 경우의 재무장은 W4가, 재무장의 멱등성은 W5가 따로 고정한다).
  write_prs "[{\"number\":350,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
  run_ensure
  [ "$status" -eq 0 ]

  # 하네스 확인: 도구가 그 사실을 관측은 했는가(배선이 죽었다면 버그가 아니라 테스트 결함이다).
  echo "$output" | jq -e '.observed.trusted.number == 350' > /dev/null \
    || { echo "harness: 도구가 열린 PR 사실을 관측하지 못했다(gh pr list 배선 확인)"; echo "$output"; dump_calls; false; }

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
  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "skip" ] || {
    echo "duplicate bump PR: ensure-bump-pr decided '$action' while PR #350 (same-repo, writer) is already open (expected skip)"
    echo "$output"; false
  }
}

# bats test_tags=regression
@test "W2: a DIRTY writer PR is recovered by a leased force-push, never by a second create" {
  # DIRTY 교착: 유일한 PR이 충돌나면 이후 폴링이 전부 skip → 깨끗한 대체 PR이 영영 안 생겨
  # 배포가 조용히 멈춘다(pr-sweeper는 DIRTY를 무시). 최신 main에서 재구축해 force-push해야 풀린다.
  write_prs "[{\"number\":351,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
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

  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "rebuild" ] || {
    echo "duplicate bump PR: ensure-bump-pr decided '$action' while PR #351 is DIRTY on ${BRANCH} (expected rebuild)"
    echo "$output"; false
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

  echo "$output" | jq -e --arg o "$ORPHAN_OID" '.observed.remoteBranch.oid == $o' > /dev/null \
    || { echo "harness: 도구가 고아 원격 브랜치를 관측하지 못했다(git ls-remote 배선 확인)"; echo "$output"; dump_calls; false; }

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

  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "adopt" ] || {
    echo "orphan bump branch: ensure-bump-pr decided '$action' with an orphan remote branch present (expected adopt)"
    echo "$output"; false
  }
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
  write_prs "[{\"number\":360,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
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
  write_prs "[{\"number\":361,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
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
  write_prs "[{\"number\":363,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
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

  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "rebuild" ] || {
    echo "duplicate bump PR: ensure-bump-pr decided '$action' while PR #363 is DIRTY on ${BRANCH} (expected rebuild + 재무장)"
    echo "$output"; false
  }
}

# bats test_tags=regression
@test "W7: a DIRTY already-armed PR is rebuilt without re-arming (rebuild does not churn the arming)" {
  # W6의 멱등 짝. rebuild가 "무조건 무장"으로 구현되면(판정 축에 무장을 매달면) 충돌난 PR을 되살릴 때마다
  # 이미 살아 있는 무장을 다시 건드린다 — 무장은 desired state지 rebuild의 부작용이 아니다.
  # force-push는 무장을 지우지 않는다(autoMergeRequest는 head OID가 아니라 PR에 붙는다) → 재무장할 게 없다.
  write_prs "[{\"number\":364,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_armed)}]"
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

# ---------------------------------------------------------------------------
# 하네스 자체의 증명 — 이게 GREEN이 아니면 위 증인들은 아무것도 증명하지 못한다
# ---------------------------------------------------------------------------

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
# 보존 — red baseline에서 이미 GREEN(수정 후에도 GREEN이어야 한다)
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

@test "no open PR and no remote branch: pushes the branch (exact argv) and opens exactly one PR" {
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

@test "facts are queried before any mutation (query then decide then mutate)" {
  # R-4의 핵심 순서 계약: 조회가 push/create보다 **먼저** 일어나야 판정이 의미를 갖는다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  list_at="$(first_call gh pr list)"
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

@test "the PR query asks for the exact fields the decision needs (headRefOid for the lease, autoMergeRequest for re-arming)" {
  # 필드가 빠지면 판정이 조용히 무너진다:
  #   headRefOid 누락       → lease 기대값이 사라져 회복이 stale 거부로 돌아간다(R-5)
  #   autoMergeRequest 누락 → 무장 갭을 관측할 수 없어 재무장 수렴이 불가능하다(R-10)
  # 조회 argv도 **배열 계약**이다 — 필드 목록은 한 인자(쉼표 구분)여야 gh가 올바로 읽는다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  run has_call_exact gh pr list --head "$BRANCH" --state open \
    --json "number,isCrossRepository,mergeStateStatus,author,headRefOid,autoMergeRequest"
  if [ "$status" -ne 0 ]; then
    echo "조회 argv 계약 위반 — gh pr list --head <b> --state open --json <6필드 한 인자>"
    dump_calls; false
  fi
}

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

@test "a fork (cross-repo) PR on the same branch name is never trusted" {
  # 공개 레포 — 포크 PR은 같은 브랜치명 + 그럴듯한 본문을 아무나 올릴 수 있다. 이걸 신뢰하면
  # 포크 PR 하나로 배포를 무기한 억제할 수 있다(억제 = 공격 표면) → 신뢰 0.
  write_prs "[{\"number\":400,\"isCrossRepository\":true,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"author\":{\"is_bot\":false,\"login\":\"drive-by\"},\"autoMergeRequest\":$(amr_absent)}]"
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted == null'
  echo "$output" | jq -e '.observed.prs[0].trusted == false'
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
}

@test "a same-repo PR authored by someone other than the writer App is not trusted" {
  write_prs "[{\"number\":401,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"author\":{\"is_bot\":false,\"login\":\"ukkiee\"},\"autoMergeRequest\":$(amr_absent)}]"
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted == null'
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 1 ]
}

@test "the writer App is recognized in both gh (app/<slug>) and REST (<slug>[bot]) login forms" {
  # 표기 계약 고정: gh CLI는 `app/ukyi-homelab-writer`, REST/GraphQL은 `ukyi-homelab-writer[bot]`.
  # 한쪽만 인식하면 신뢰 판정이 조용히 무너져(=trusted 0) 중복 PR이 그대로 남는다.
  write_prs "[{\"number\":352,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"author\":{\"is_bot\":true,\"login\":\"ukyi-homelab-writer[bot]\"},\"autoMergeRequest\":$(amr_armed)}]"
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted.number == 352'
}

@test "malformed PR JSON fails closed and mutates nothing" {
  write_prs 'not json at all'
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

@test "empty gh output fails closed (an empty read is not 'no open PRs')" {
  # `gh pr list --json`은 PR이 없어도 '[]'를 준다 → 빈 출력은 조회 실패다. 조용히 create로 흘리면 버그 재현.
  write_prs ''
  run_ensure
  [ "$status" -ne 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

@test "a non-array top level fails closed (gh pr list --json returns an array)" {
  write_prs '{"number":350}'
  run_ensure
  [ "$status" -ne 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

@test "a PR object missing the schema fields fails closed (field-name drift guard)" {
  # gh --json 필드명이 바뀌거나 오타가 나면(예: crossRepository) 조용히 trusted 0이 되어
  # 중복 PR이 되살아난다 → 스키마 위반은 판정하지도, 변이하지도 않는다.
  write_prs "[{\"number\":350,\"crossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"author\":{\"login\":\"app/ukyi-homelab-writer\"},\"autoMergeRequest\":$(amr_absent)}]"
  run_ensure
  [ "$status" -ne 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

@test "a PR without headRefOid fails closed (no lease expectation means no safe recovery)" {
  write_prs "[{\"number\":350,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
}

@test "a PR without autoMergeRequest fails closed (arming state unknown means re-arm cannot be decided)" {
  # R-10 필드 드리프트 가드. 이 필드가 조용히 사라지면(필드명 변경·오타) 두 갈래로 다 나쁘다:
  #   undefined를 "미무장"으로 읽으면 → 매 폴링 재무장(소음, 남의 PR까지 건드릴 수 있음)
  #   undefined를 "무장됨"으로 읽으면 → 무장 갭이 영영 안 닫혀 autoDeploy 배포가 조용히 정지
  # 둘 다 조용한 오동작이라 판정도 변이도 하지 않는다(headRefOid·isCrossRepository 가드와 동형).
  write_prs "[{\"number\":350,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author)}]"
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
  arms="$(arm_calls_script)"
  [ "$arms" -eq 0 ]
}

@test "a failing PR query fails closed and mutates nothing" {
  export STUB_GH_LIST_FAIL=1
  run_ensure
  [ "$status" -ne 0 ]
  pushes="$(count_calls git push)"
  [ "$pushes" -eq 0 ]
  creates="$(count_calls gh pr create)"
  [ "$creates" -eq 0 ]
}

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

@test "the branch name is deterministic per bump (no RUN_ID — same bump converges to one branch)" {
  # 결정적 브랜치가 중복 PR 픽스의 토대다: run마다 브랜치가 달라지면 조회할 대상 자체가 없다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg b "$BRANCH" '.branch == $b'
  lists="$(count_calls gh pr list --head "$BRANCH")"
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

@test "the propose-pr lane does not arm even when a trusted un-armed PR is open (no re-arm outside autoDeploy)" {
  # W4(재무장)가 레인을 넘어 새지 않는가 — 승인 PR에 무장이 없는 건 **정상**이다(그게 승인 레인이다).
  # 재무장은 bump 레인의 desired state일 뿐, "무장 없음"을 보편적 결함으로 취급하면 승인 게이트가 무너진다.
  write_prs "[{\"number\":362,\"isCrossRepository\":false,\"mergeStateStatus\":\"BLOCKED\",\"headRefOid\":\"$PR_OID\",\"author\":$(writer_author),\"autoMergeRequest\":$(amr_absent)}]"
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
