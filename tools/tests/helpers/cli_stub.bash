# homelab CLI bats 공용 하네스 — PATH stub + argv 원장(NUL 구분 + RS(0x1e) 종단).
# 관용구 출처: tools/tests/test_ensure-bump-pr.bats (인자 경계 보존 원장 · 계약 밖 호출 fail-closed).
# 사용: 테스트 파일에서 `load "helpers/cli_stub"` 후 setup에서 cli_stub_init → make_gh_stub →
#       (kubeseal 존재 시나리오면) make_kubeseal_stub.
#
# PATH는 **전치가 아니라 대체**다: STUB만 PATH로 쓴다. 전치(PATH="$STUB:$PATH")로 두면 호스트에
# 설치된 kubeseal이 "부재" 시나리오로 새어들어 테스트가 호스트 상태에 종속된다. 대신 런타임이
# 실제로 필요로 하는 시스템 도구(bun·bash·base64·cat)를 심링크로 STUB에 들여온다(gh stub의
# `#!/usr/bin/env bash`가 새 PATH에서 bash를 찾는다).
#
# stub의 case 디스패치는 "$*" 평탄화지만, **단언은 원장(NUL 구분)으로만** 한다 — 디스패치는
# 계약 밖 호출을 exit 3으로 죽이는 fail-closed 게이트이고, 인자 경계 증명은 ledger.py 몫이다.

cli_stub_init() {
  STUB="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB"
  export CALLS="$BATS_TEST_TMPDIR/calls.nul"
  : > "$CALLS"
  # git 전역/시스템 설정 격리 — 이 하네스의 픽스처(신원·insteadOf)는 전부 **로컬** config로 심는데,
  # 엔진의 git 호출(commit·push·ls-remote·remote get-url)은 호스트 전역 설정도 함께 읽는다. 호스트에
  # commit.gpgsign=true(키 없음)면 커밋 경로가, 전역 url.*.insteadOf가 있으면 push 라우팅 판정이
  # 하네스 재배선이 아니라 **호스트 설정** 때문에 뒤집힌다(테스트가 자기 전제를 잘못 읽는다).
  # 형제 appinit 하네스는 자기 GIT_CONFIG_GLOBAL(INIT_GCFG)을 run env로 명시해 넘기므로 그쪽이 이긴다.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  # 전역 설치 축 격리 — doctor의 install 항목은 `$BUN_INSTALL/bin`(미설정이면 `~/.bun/bin`)에서
  # `homelab` 엔트리를 찾는다. 격리하지 않으면 판정이 **개발자 머신 상태**에 종속된다: 이 호스트의
  # `~/.bun/bin/homelab`은 삭제된 worktree를 가리키는 dangling 심링크라(2026-09-07 실측) doctor가
  # fail을 내고, CI에서는 부재라 warn이 난다 — 같은 커밋이 venue마다 다른 색이 되는 자리다.
  # 빈 디렉토리를 기본값으로 주고, 설치 상태를 재는 테스트만 여기에 엔트리를 심는다.
  export BUN_INSTALL="$BATS_TEST_TMPDIR/bun-install"
  mkdir -p "$BUN_INSTALL/bin"
  BUN="$(command -v bun)"
  # sleep — 디스패치 타임아웃 주입(STUB_GH_DISPATCH_HANG)이 자식을 살아 있게 두는 유일한 수단이다
  # (PATH는 대체라 시스템 도구가 자동으로 들어오지 않는다).
  # jq는 raw 형상 레인(STUB_GH_RAW=1) 전용이다 — 그 레인에서만 gh stub이 **실제 jq**를 돌린다.
  # 부재 시 조용한 통과가 아니라 exit 127로 죽어야 해서(test_homelab-gh-jq-contract.bats가 단언),
  # 스텁 본체는 폴백을 두지 않는다.
  for t in bun bash base64 cat git sleep jq; do
    ln -s "$(command -v "$t")" "$STUB/$t"
  done

  # 원시 GitHub 페이로드 픽스처 — 접힘이 있는 필터(workflow_runs 언랩 · head.ref 중첩 ·
  # auto_merge != null)의 의미론 증인. 손으로 적은 형상이 SSOT이고, 테스트는 사본을 뮤테이션해
  # 필드 리네임이 red가 되는지 잰다(GH_RAW_DIR를 그 사본으로 가리켜서).
  GH_RAW_DIR="$BATS_TEST_DIRNAME/fixtures/homelab/gh-raw"
  export GH_RAW_DIR

  # 템플릿 컨텐츠 픽스처 — 기본값은 "호환 템플릿"(비대화형 마커 + 컴파일 3종 TARGETARCH).
  # 비호환 시나리오는 각 테스트가 파일을 덮어써서 만든다.
  FIX="$BATS_TEST_TMPDIR/template-fix"
  export FIX
  mkdir -p "$FIX"
  printf 'const flags = ["--archetype", "--name", "--yes"]; // scaffold 비대화형 계약 마커\n' > "$FIX/scaffold.ts"
  for a in api fullstack worker; do
    printf 'FROM oven/bun:1 AS build\nARG TARGETARCH\nRUN bun build --compile --target=bun-linux-${TARGETARCH}\n' > "$FIX/Dockerfile.$a"
  done

  # 변이 엔진 테스트의 고정 nonce — HOMELAB_CORRELATION 주입 심(엔진이 CORRELATION_RE로 검증).
  NONCE="corr-fixed-nonce-01"
  export NONCE

  # db create 픽스처 기본값(행복 경로): 디스패치 접수 → nonce 에코 run 1개(성공) → PR 1개(미머지).
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  printf '{"status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}\n' > "$FIX/db-run.json"
  # 전이 전 관측(티켓 19) — STUB_RUN_COMPLETE_AFTER_FIRST일 때 **첫** 단건 run 조회의 응답.
  # 라이브의 기본 경로(queued/in_progress → completed)를 재현하는 자리로, 둘째 조회부터는 db-run.json.
  printf '{"status":"in_progress","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}\n' > "$FIX/db-run-first.json"
  printf '[]\n' > "$FIX/db-run-jobs.json"
  # 신선도 스냅샷 픽스처(티켓 27) — STUB_GH_STALE_RUN=1 전용. **디스패치 전에 이미** 같은 nonce를
  # 에코하던 옛 완료 run이다(고정 nonce가 프로덕션에서 켜졌을 때의 형상). 투영이 스냅샷 질의와
  # 같아야 한다: 신원(id·name)만 — 상태·URL은 채택하지 않을 run에 대해 의미가 없다.
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]"}]\n' "$NONCE" > "$FIX/stale-runs.json"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
  # PR 단건 권위 조회(티켓 05) — 목록이 state:closed·미머지일 때만 읽힌다(확증 단계). 기본은 목록과
  # 같은 결론(closed·미머지)이고, stale 레인은 테스트가 merged_at을 채운 사본으로 덮어쓴다.
  printf '{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"closed"}\n' > "$FIX/pr-confirm.json"
  printf 'identical\n' > "$FIX/db-compare.txt"
  printf '{"status":{"sync":{"status":"Synced","revision":"feedbee"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"feedbee"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"

  # app create 픽스처 기본값 — create-app run 1개(성공).
  printf '[{"id":801,"name":"✨ create-app — myapp [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/801"}]\n' "$NONCE" > "$FIX/appcreate-runs.json"

  # app teardown 픽스처 기본값 — teardown-app run 1개(성공). 이 동사의 종결은 Application "부재"라
  # kubectl 쪽 기본값도 부재다(STUB_APP_STILL_PRESENT=1로 prune 미완을 만든다).
  printf '[{"id":901,"name":"🗑️ teardown-app — myapp [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/901"}]\n' "$NONCE" > "$FIX/teardown-runs.json"

  # app secrets 픽스처 기본값 — update-secrets run 1개(성공). PR은 테스트가 db-prs.json으로 배치.
  printf '[{"id":701,"name":"✨ update-secrets — myapp [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/701"}]\n' "$NONCE" > "$FIX/secrets-runs.json"

  # cache create 픽스처 기본값(행복 경로) — 변이 엔진 공유, 디스패처·run만 cache 것.
  printf '[{"id":601,"name":"✨ create-cache — mycache [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/601"}]\n' "$NONCE" > "$FIX/cache-runs.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"feedbee"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cache.json"

  # status 픽스처 기본값 — GitHub 응답(빈 목록)·ArgoCD Application. 각 테스트가 덮어써서 조정한다.
  printf '[]\n' > "$FIX/homelab-prs.json"
  printf '[]\n' > "$FIX/runs.json"
  printf '{"name":"release","status":"completed","conclusion":"success","head_sha":"a1b2c3d","html_url":"https://github.com/ukyi-app/page/actions/runs/1"}\n' > "$FIX/run-handle.json"
  printf '{"number":7,"state":"open","merged":false,"merge_commit_sha":null,"title":"bump","head_ref":"bump-poll/page-sha-1","head_sha":"beef123","auto_merge":true,"html_url":"https://github.com/ukyi-app/homelab/pull/7"}\n' > "$FIX/pr-handle.json"
  # ⚠️ 앱 Application(<app>-prod)은 appset(platform/argocd/root/appset.yaml `sources:` 3개)이 만드는
  # **멀티소스**다 — ArgoCD는 멀티소스에서 `status.sync.revision`을 비우고 `revisions[]`만 채운다
  # (라이브 실측: argocd·cnpg-operator `revision=None`, `revisions=[…]`). 그래서 app 레인 기본 픽스처는
  # 복수형이고 `revision` 키가 **없다**. 원소 3개는 appset sources 수에서 외삽한 값이다(라이브 앱 0건).
  # 단일소스 형상(argocd-cnpg-data·data-conn·cache)은 db/cache 레인 대조군으로 그대로 둔다 — 둘 중 하나로
  # 통일하면 다른 쪽 판정이 무증인이 된다.
  # 리비전 자리표시자는 어디서든 **git SHA 형상(hex 7..40)**이어야 한다 — 공유 리더(lib/argocd.ts)가 비-SHA를
  # 미확정으로 접어 gh compare를 부르지 않으므로, 비-hex 자리표시자(옛 afterme·0ldrev1)는 compare 경로 증인을
  # 조용히 우회시킨다(티켓 01 착지 중 실측).
  printf '{"status":{"sync":{"status":"Synced","revisions":["abc1234","abc1234","abc1234"]},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"

  # 앱 배포 산출물 픽스처 루트 — status의 --root 주입 대상(레포 밖 hermetic 검증).
  APPS_ROOT="$BATS_TEST_TMPDIR/repo-root"
  export APPS_ROOT
  mkdir -p "$APPS_ROOT/apps"

  # 원장 파서 — NUL/RS 레코드를 배열로 복원해 질의한다. 모드:
  #   count <argv...>  : 접두 일치 레코드 수
  #   observation-only : 모든 gh 레코드가 읽기(`gh api`/`gh --version`)이고 변이 수단이 없으며,
  #                      모든 git 레코드가 읽기 동사(`var`·`rev-parse`·`config --get*`)인지 (위반 시 비-0)
  #   dump             : 사람용 — argc + 따옴표 표기
  LEDGER_PY="$BATS_TEST_TMPDIR/ledger.py"
  cat > "$LEDGER_PY" <<'PY'
import sys

mode, path = sys.argv[1], sys.argv[2]
want = sys.argv[3:]
records = []
raw = open(path, "rb").read()
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
elif mode == "exact":  # argc + 각 위치 문자열이 모두 같은 레코드가 있는가(인자 경계 보존 단언)
    sys.exit(0 if any(r == want for r in records) else 1)
elif mode == "observation-only":
    # doctor·status는 관측 전용 — gh 레코드는 읽기(`gh api` 또는 `gh --version`)이고 변이 수단이 없어야
    # 하며, git 레코드는 읽기 동사(`var` · `rev-parse` · `config --get*`)뿐이어야 한다. git 계열도
    # exec seam을 지나므로 gh만 보면 "관측 전용"이 gh 축에서만 참인 반쪽 단언이 된다(티켓 14·17).
    MUTATION = {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input"}
    GH_READ_HEADS = (["api"], ["--version"])

    def git_read(rec):
        # `git -C <dir> …`(exec seam의 named adapter 형태)는 동사 앞의 위치 지정일 뿐이라 벗겨 낸다.
        args = rec[1:]
        if args[:1] == ["-C"]:
            args = args[2:]
        head = args[:1]
        if head in (["var"], ["rev-parse"]):
            return True
        return head == ["config"] and len(args) > 1 and args[1].startswith("--get")

    bad = []
    for r in records:
        if r[:1] == ["gh"] and (r[1:2] not in GH_READ_HEADS or set(r) & MUTATION):
            bad.append(r)
        elif r[:1] == ["git"] and not git_read(r):
            bad.append(r)
    for r in bad:
        print("MUTATION-SHAPED: " + " ".join(r))
    sys.exit(1 if bad else 0)
elif mode == "dump":
    for r in records:
        print(str(len(r)) + ": " + " ".join("'" + a + "'" for a in r))
else:
    sys.exit(2)
PY
}

# gh stub — doctor·status가 낼 수 있는 읽기 호출의 완전 목록(계약 밖 호출은 exit 3).
# doctor 케이스는 정확 argv 고정, status의 run/PR 케이스는 레포 부분만 글롭이다 — 핸들 모드가
# 임의 owner/repo URL을 정당한 입력으로 받는 계약이라(좁히면 계약을 거짓으로 검증) 의도적 비대칭.
# 응답은 STUB_* env로 제어: STUB_GH_UNAUTH / STUB_LOGIN / STUB_SCOPES / STUB_NO_SCOPES_HEADER /
# STUB_OWNER / STUB_OWNER_404 / STUB_IS_TEMPLATE / STUB_GH_PRS_FAIL / STUB_GH_RUNS_FAIL /
# STUB_GH_HANDLE_404 / STUB_GH_NONJSON / STUB_GH_RAW / STUB_GH_HTTP_ERR / STUB_GH_VERSION / STUB_PR_CONFIRM_FAIL / STUB_GH_DISPATCH_HANG / 변이 폴링 실패
# 3종(STUB_GH_RUNS_LIST_FAIL · STUB_GH_RUN_READ_FAIL · STUB_GH_PR_LIST_FAIL_AFTER_FIRST) / 변이 분기
# 픽스처 2종(STUB_RUN_COMPLETE_AFTER_FIRST · STUB_GH_PR_LOOKUP_FAIL) / 신선도 스냅샷
# (STUB_GH_STALE_RUN — 디스패치 전에 이미 같은 nonce를 에코하던 옛 run). 템플릿 파일·status 응답
# 내용은 $FIX 픽스처가 SSOT.
#
# ⚠️ 기본 픽스처는 jq를 **적용한 뒤의** 형상이다 — 손으로 접어 적은 결과라 필터의 의미론
#    (`.workflow_runs[]` 언랩 · `head: .head.ref` 중첩 · `auto_merge != null` 접힘)은 증언하지 못한다.
#    case 패턴은 필터 **텍스트**까지 정확 일치라 드리프트를 exit 3으로 잡지만, GitHub 필드 리네임은
#    접힌 픽스처 아래에서 여전히 초록이다. 그 축은 STUB_GH_RAW=1 레인이 진다: 원시 페이로드
#    ($GH_RAW_DIR/*.json)에 **실제 jq**를 돌린다(tools/tests/test_homelab-gh-jq-contract.bats).
make_gh_stub() {
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
{ printf '%s\0' gh "$@"; printf '\x1e'; } >> "$CALLS"
b64() { base64 < "$1"; }
# 변이 레인 폴링 실패 주입(티켓 06) — `workflow run`은 exit 0인데 이후 **관측** 조회만 비-0이 된다.
# status 경로 전용인 STUB_GH_RUNS_FAIL을 재사용하면 이 레인이 vacuous라서 전용 노브를 둔다.
# 본 case보다 **앞**에 있는 별도 case다: 본 case 안에 글롭을 끼우면 첫 매치가 이겨 디스패처별
# 픽스처 케이스가 사문이 된다(bash case는 fallthrough가 없다 — `;;&`는 bash 4+).
case "$*" in
  "api repos/ukyi-app/homelab/actions/workflows/"*"/runs?per_page=20 --jq "*)
    if [ -n "${STUB_GH_RUNS_LIST_FAIL:-}" ]; then echo "gh: HTTP 401: Bad credentials" >&2; exit 1; fi
    ;;
esac
# 디스패치 지연 주입(티켓 08) — 자식이 살아 있는 동안 호출자의 timeoutMs가 만료돼 SIGTERM으로
# 죽는 상황을 만든다(POST 도달 여부는 미상). 부분 stderr를 먼저 흘려 seam의 보존도 함께 관측된다.
# 본 case **앞**의 별도 case다(bash case는 fallthrough가 없다 — 본 case에 끼우면 디스패처별
# 픽스처 케이스가 사문이 된다). 원장 기록은 이 지연보다 앞이라 '정확히 1건'이 그대로 관측된다.
case "$*" in
  "workflow run "*)
    if [ -n "${STUB_GH_DISPATCH_HANG:-}" ]; then echo "gh: 요청 전송 중" >&2; sleep 5; fi
    ;;
esac
case "$*" in
  # gh 버전 — 코드에 박힌 gh 문구 계약(`(HTTP 404)` stderr · `workflow run -f` · `api --jq`)의 전제.
  # STUB_GH_VERSION으로 구버전 레인을 만든다(기본은 계약 최소 버전 이상).
  "--version")
    printf 'gh version %s (2026-08-01)\n' "${STUB_GH_VERSION:-2.97.0}"
    printf 'https://github.com/cli/cli/releases/latest\n'
    ;;
  "api -i user")
    if [ -n "${STUB_GH_UNAUTH:-}" ]; then
      echo "gh: To get started with GitHub CLI, please run:  gh auth login" >&2
      exit 4
    fi
    # STUB_GH_HTTP_ERR — **서버가 응답한** 실패(401·403 rate limit 소진·권한). `gh api -i`는 비-2xx에서도
    # 상태줄+헤더를 stdout에 그대로 낸다(라이브 실측: 404 조회 → stdout 첫 줄 `HTTP/2.0 404 Not Found`).
    # 그 형상이 '자격 부재(rc 4·stdout 공백)'와 이 레인을 가르는 유일한 원료다.
    if [ -n "${STUB_GH_HTTP_ERR:-}" ]; then
      printf 'HTTP/2.0 401 Unauthorized\r\n'
      printf 'X-Ratelimit-Limit: 5000\r\n'
      printf 'X-Ratelimit-Remaining: 0\r\n'
      printf '\r\n'
      echo "gh: Bad credentials (HTTP 401)" >&2
      exit 1
    fi
    printf 'HTTP/2.0 200 OK\r\n'
    if [ -z "${STUB_NO_SCOPES_HEADER:-}" ]; then
      printf 'X-Oauth-Scopes: %s\r\n' "${STUB_SCOPES:-gist, read:org, repo, workflow}"
    fi
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf '\r\n'
    printf '{"login":"%s"}\n' "${STUB_LOGIN:-ukyi}"
    ;;
  "api repos/ukyi-app/homelab/actions/variables/HOMELAB_OWNER --jq .value")
    if [ -n "${STUB_OWNER_404:-}" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    # ⚠️ `:-`가 아니라 `-` — 빈 문자열은 "변수 미설정"이 아니라 "빈 값 fail-closed" 시나리오다.
    printf '%s\n' "${STUB_OWNER-ukyi}"
    ;;
  "api repos/ukyi-app/homelab-app-template --jq .is_template")
    printf '%s\n' "${STUB_IS_TEMPLATE:-true}"
    ;;
  "api repos/ukyi-app/homelab-app-template/contents/scaffold/scaffold.ts --jq .content")
    b64 "$FIX/scaffold.ts"
    ;;
  "api repos/ukyi-app/homelab-app-template/contents/scaffold/archetypes/api/Dockerfile --jq .content")
    b64 "$FIX/Dockerfile.api"
    ;;
  "api repos/ukyi-app/homelab-app-template/contents/scaffold/archetypes/fullstack/Dockerfile --jq .content")
    b64 "$FIX/Dockerfile.fullstack"
    ;;
  "api repos/ukyi-app/homelab-app-template/contents/scaffold/archetypes/worker/Dockerfile --jq .content")
    b64 "$FIX/Dockerfile.worker"
    ;;
  # ── app create 사전 판정(티켓 30) — 앱 레포 main의 .app-config.yml 실존. 기본은 200이고
  # STUB_APP_CONFIG_404(사전 거부 대상)·STUB_APP_CONFIG_ERR(판정 불가 → 통과 후 디스패처 위임)로 가른다.
  "api repos/ukyi-app/"*"/contents/.app-config.yml?ref=main --jq .name")
    if [ -n "${STUB_APP_CONFIG_404:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -n "${STUB_APP_CONFIG_ERR:-}" ]; then echo "gh: HTTP 502: Bad gateway" >&2; exit 1; fi
    printf '.app-config.yml\n'
    ;;
  # ── 신선도 스냅샷(티켓 27) — 변이 엔진이 **디스패치 전에** 내는 질의. 5레인 공통이라 경로만
  #    글롭이다(응답이 레인 무관하다 — 형제 케이스들과 달리 픽스처가 하나뿐인 이유).
  #    기본은 공집합: 프로덕션의 랜덤 nonce 경로가 그렇고, 이 하네스의 고정 nonce 픽스처(run이
  #    처음부터 있다)를 '디스패치 전에도 있었다'로 읽으면 모든 레인이 채택 불가가 된다.
  #    STUB_GH_STALE_RUN=1이면 같은 nonce를 에코하는 **옛** run을 돌려준다(채택 금지 증인).
  "api repos/ukyi-app/homelab/actions/workflows/"*"/runs?per_page=20 --jq "'[.workflow_runs[] | {id, name}]')
    if [ -n "${STUB_GH_STALE_RUN:-}" ]; then cat "$FIX/stale-runs.json"; else echo '[]'; fi
    ;;
  # ── app create 케이스 — create-app 디스패처·runs 목록(수동 머지 동사) ──
  "workflow run create-app.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/create-app.yaml/runs?per_page=20 --jq "'[.workflow_runs[] | {id, name, status, conclusion, html_url}]')
    cat "$FIX/appcreate-runs.json"
    ;;
  # ── app teardown 케이스 — teardown-app 디스패처·runs 목록(수동 머지 = 파괴 승인) ──
  "workflow run teardown-app.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/teardown-app.yaml/runs?per_page=20 --jq "'[.workflow_runs[] | {id, name, status, conclusion, html_url}]')
    cat "$FIX/teardown-runs.json"
    ;;
  # ── app secrets 케이스 — update-secrets 디스패처·runs 목록 ──
  "workflow run update-secrets.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/update-secrets.yaml/runs?per_page=20 --jq "'[.workflow_runs[] | {id, name, status, conclusion, html_url}]')
    cat "$FIX/secrets-runs.json"
    ;;
  # ── cache create 케이스 — db와 같은 엔진, 디스패처·runs 목록만 cache 것 ──
  "workflow run create-cache.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/create-cache.yaml/runs?per_page=20 --jq "'[.workflow_runs[] | {id, name, status, conclusion, html_url}]')
    cat "$FIX/cache-runs.json"
    ;;
  # ── db create 변이 엔진 케이스 — 유일하게 허용되는 변이 argv는 workflow run 하나뿐 ──
  "workflow run create-database.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/create-database.yaml/runs?per_page=20 --jq "'[.workflow_runs[] | {id, name, status, conclusion, html_url}]')
    cat "$FIX/db-runs.json"
    ;;
  "api repos/ukyi-app/homelab/actions/runs/"*"/jobs --jq "'[.jobs[] | select(.conclusion == "failure") | .name]')
    cat "$FIX/db-run-jobs.json"
    ;;
  "api repos/ukyi-app/homelab/actions/runs/"*" --jq {status, conclusion, html_url}")
    # STUB_GH_RUN_READ_FAIL(티켓 06): conclusion 폴링 루프의 관측만 전부 전송 오류.
    if [ -n "${STUB_GH_RUN_READ_FAIL:-}" ]; then echo "gh: connect: connection reset" >&2; exit 1; fi
    # STUB_RUN_COMPLETE_AFTER_FIRST(티켓 19): 첫 조회는 db-run-first.json(전이 전), 이후 db-run.json.
    # 라이브의 **기본 경로**(queued→in_progress→completed)를 밟는 유일한 자리 — 마커는 셸 내장
    # 리다이렉션이다(PATH=$STUB에 touch가 없다, STUB_PR_MERGE_AFTER_FIRST와 같은 관용구).
    if [ -n "${STUB_RUN_COMPLETE_AFTER_FIRST:-}" ] && [ ! -f "$FIX/.run-read-once" ]; then
      : > "$FIX/.run-read-once"; cat "$FIX/db-run-first.json"; exit 0
    fi
    cat "$FIX/db-run.json"
    ;;
  # 필터 텍스트 SSOT는 lib/lane-pr.ts의 LANE_PR_JQ(= `[.[] | ${LANE_PR_FIELDS}]`)다 — 티켓 05가
  # 종결 축으로 `state`를 더하면서 목록형·단건형이 같은 투영을 공유하게 됐다.
  "api repos/ukyi-app/homelab/pulls?state=all&head="*" --jq "'[.[] | {number, html_url, merged_at, merge_commit_sha, state}]')
    # STUB_PR_MERGE_AFTER_FIRST: 첫 조회는 미머지, 이후 머지 — "--wait 중 사람이 머지" 전환 재현
    # (마커는 셸 내장 리다이렉션 — PATH=$STUB에 touch 없음, STUB_COMPARE_FLAKY와 같은 관용구).
    # STUB_GH_PR_LOOKUP_FAIL(티켓 19): PR 특정 조회가 **전부** 전송 오류 — grace 재시도를 다 쓰고도
    # 미확정이면 '명명 드리프트'가 아니라 GitHub 계층 실패다. status의 열린 PR 목록 전용인
    # STUB_GH_PRS_FAIL과 이름을 의도적으로 분리한다(재사용하면 어느 레인이 죽었는지 못 가른다).
    if [ -n "${STUB_GH_PR_LOOKUP_FAIL:-}" ]; then echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; fi
    if [ -n "${STUB_PR_MERGE_AFTER_FIRST:-}" ]; then
      if [ ! -f "$FIX/.pr-read-once" ]; then
        : > "$FIX/.pr-read-once"
        cat "$FIX/db-prs-unmerged.json"
        exit 0
      fi
    fi
    # STUB_PR_EMPTY_FIRST: 첫 조회는 [](낡은/빈 스냅샷 — 함정 「GitHub API는 낡은 스냅샷을 200으로 돌려준다」),
    # 이후 db-prs.json. STUB_PR_FAIL_FIRST: 첫 조회는 전송 오류(exit 1), 이후 정상. 둘 다 PR 특정의 3상
    # 재조회(티켓 04) 증인 — 단발 즉결이면 각각 거짓 failure/no-op·거짓 failure가 된다.
    if [ -n "${STUB_PR_EMPTY_FIRST:-}" ] && [ ! -f "$FIX/.pr-empty-once" ]; then
      : > "$FIX/.pr-empty-once"; printf '[]\n'; exit 0
    fi
    if [ -n "${STUB_PR_FAIL_FIRST:-}" ] && [ ! -f "$FIX/.pr-fail-once" ]; then
      : > "$FIX/.pr-fail-once"; echo "gh: connect: connection reset" >&2; exit 1
    fi
    # STUB_GH_PR_LIST_FAIL_AFTER_FIRST(티켓 06): 첫 조회(step 4 PR 특정)만 정상, 이후 머지 폴링은
    # 전부 전송 오류 — 지속 실패가 '머지 미관측'으로 위장되는 자리를 만든다.
    if [ -n "${STUB_GH_PR_LIST_FAIL_AFTER_FIRST:-}" ]; then
      if [ -f "$FIX/.pr-list-once" ]; then echo "gh: HTTP 403: rate limit exceeded" >&2; exit 1; fi
      : > "$FIX/.pr-list-once"
    fi
    # 브랜치별 응답(티켓 09) — 실물 API의 `head=<owner>:<branch>` **정확 일치**를 스텁도 흉내낸다.
    # 파일명은 브랜치의 '/'를 '_'로 바꾼 `$FIX/prs-head-<branch>.json`이고, 없으면 기존 db-prs.json이
    # 그대로 쓰인다(기존 레인 무영향). ⚠️ 치환은 셸 파라미터 확장으로만 — PATH=$STUB에 tr/sed가 없다.
    hr="${2#*head=ukyi-app:}"
    alt="$FIX/prs-head-${hr//\//_}.json"
    if [ -f "$alt" ]; then cat "$alt"; exit 0; fi
    cat "$FIX/db-prs.json"
    ;;
  # PR 단건 권위 조회(티켓 05) — 머지 없이 닫힌 목록 행의 확증 단계. status의 핸들 조회와 같은
  # 경로 형상이라 **jq 투영으로 구별**한다(status는 {number, state, merged, …}). STUB_PR_CONFIRM_FAIL이면
  # 전송 오류 — 확증이 미확정이면 엔진은 종결하지 않고 폴링을 계속한다.
  "api repos/ukyi-app/homelab/pulls/"*" --jq {number, html_url, merged_at, merge_commit_sha, state}")
    if [ -n "${STUB_PR_CONFIRM_FAIL:-}" ]; then echo "gh: connect: connection reset" >&2; exit 1; fi
    cat "$FIX/pr-confirm.json"
    ;;
  "api repos/ukyi-app/homelab/compare/"*" --jq .status")
    # STUB_COMPARE_FLAKY: 첫 호출만 전송 오류 — 미확정 관측을 캐시하지 않음(재평가 수렴)을 증명.
    # ⚠️ 마커는 셸 내장 리다이렉션으로 만든다 — PATH=$STUB에는 touch가 없다(대체 PATH 하네스).
    if [ -n "${STUB_COMPARE_FLAKY:-}" ] && [ ! -f "$FIX/.compare-called" ]; then
      : > "$FIX/.compare-called"
      echo "gh: connect: connection reset" >&2
      exit 1
    fi
    cat "$FIX/db-compare.txt"
    ;;
  # 머지 커밋의 first parent(= 철거 전 ref) — absence 수렴이 "부재가 철거의 관측인가"를 재는 축.
  # 기본은 dadfeed(확정). STUB_PARENT_FAIL이면 전송 오류(미확정), STUB_PARENT_ROOT면 parents 비어
  # 있음(jq가 "null") — 둘 다 미확정 경로다.
  "api repos/ukyi-app/homelab/commits/"*" --jq .parents[0].sha")
    if [ -n "${STUB_PARENT_FAIL:-}" ]; then echo "gh: connect: connection reset" >&2; exit 1; fi
    if [ -n "${STUB_PARENT_ROOT:-}" ]; then printf 'null\n'; exit 0; fi
    printf 'dadfeed\n'
    ;;
  # 표면 blob sha(3상) — ref=feedbee(머지 SHA)는 요청값, ref=dadfeed는 철거 전, 그 외는 관측 리비전.
  "api repos/ukyi-app/homelab/contents/"*" --jq .sha")
    case "$*" in
      *"?ref=feedbee --jq .sha"|*"?ref=main --jq .sha")
        # feedbee=머지 SHA(변이 요청값) · main=no-op 기준(디스패처가 비교한 HEAD)
        if [ -n "${STUB_SURFACE_MERGE_ABSENT:-}" ] || [ -n "${STUB_SURFACE_NEVER:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
        printf 'blobsha-request\n'
        ;;
      *"?ref=dadfeed --jq .sha")
        # dadfeed=철거 전 ref(머지 커밋의 first parent). 기본은 **실재** — 그래야 머지 SHA의 부재가
        # 철거의 관측이 된다. STUB_SURFACE_NEVER=1이면 어느 ref에서도 404(경로 오타·표면 드리프트
        # 형태 — 부재가 아무것도 증언하지 못하는 상태), STUB_SURFACE_BEFORE_ERROR=1이면 미확정.
        if [ -n "${STUB_SURFACE_NEVER:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
        if [ -n "${STUB_SURFACE_BEFORE_ERROR:-}" ]; then echo "gh: connect: connection reset" >&2; exit 1; fi
        printf 'blobsha-before\n'
        ;;
      *)
        if [ -n "${STUB_SURFACE_ABSENT:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
        if [ -n "${STUB_SURFACE_ERROR:-}" ]; then echo "gh: connect: connection reset" >&2; exit 1; fi
        if [ -n "${STUB_SURFACE_CHANGED:-}" ]; then printf 'blobsha-other\n'; else printf 'blobsha-request\n'; fi
        ;;
    esac
    ;;
  # ── status 동사 케이스 — 응답 픽스처는 $FIX/*.json이 SSOT, 오류 시나리오는 STUB_* env ──
  "api repos/ukyi-app/homelab/pulls?state=open&per_page=100 --jq "'[.[] | {number, title, head: .head.ref, html_url, auto_merge: (.auto_merge != null)}]')
    if [ -n "${STUB_GH_PRS_FAIL:-}" ]; then echo "gh: API 오류" >&2; exit 1; fi
    if [ -n "${STUB_GH_RAW:-}" ]; then exec jq -c "${!#}" "$GH_RAW_DIR/pulls-open.json"; fi
    cat "$FIX/homelab-prs.json"
    ;;
  "api repos/"*"/actions/runs?per_page=3 --jq "'[.workflow_runs[] | {name, status, conclusion, head_sha, html_url}]')
    if [ -n "${STUB_GH_RUNS_FAIL:-}" ]; then echo "gh: API 오류" >&2; exit 1; fi
    if [ -n "${STUB_GH_RAW:-}" ]; then exec jq -c "${!#}" "$GH_RAW_DIR/workflow-runs.json"; fi
    cat "$FIX/runs.json"
    ;;
  "api repos/"*"/actions/runs/"*" --jq "'{name, status, conclusion, head_sha, html_url}')
    if [ -n "${STUB_GH_HANDLE_404:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    # STUB_GH_NONJSON(티켓 15): rc 0인데 본문이 JSON이 아니다 — 스칼라 jq 오용·응답 형상 변경의
    # 재현. 3상 리더의 'parse'가 이 레인을 '조회 실패'(전송 오류)와 갈라야 처방이 갈린다.
    if [ -n "${STUB_GH_NONJSON:-}" ]; then printf 'not-json\n'; exit 0; fi
    cat "$FIX/run-handle.json"
    ;;
  "api repos/"*"/pulls/"*" --jq "'{number, state, merged, merge_commit_sha, title, head_ref: .head.ref, head_sha: .head.sha, auto_merge: (.auto_merge != null), html_url}')
    if [ -n "${STUB_GH_HANDLE_404:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -n "${STUB_GH_RAW:-}" ]; then exec jq -c "${!#}" "$GH_RAW_DIR/pull.json"; fi
    cat "$FIX/pr-handle.json"
    ;;
  *)
    echo "stub gh: 계약 밖 호출: $*" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$STUB/gh"
}

# kubectl stub — status의 ArgoCD Application 조회 전용(그 외 호출은 exit 3 fail-closed).
# STUB_KUBECTL_FAIL 설정 시 클러스터 접근 실패를 재현한다. STUB_APP_STILL_PRESENT(teardown 레인) ·
# STUB_APP_ABSENT(status 레인)가 `--ignore-not-found` 조회의 기본값을 뒤집는다(아래 두 케이스 주석).
make_kubectl_stub() {
  cat > "$STUB/kubectl" <<'SH'
#!/usr/bin/env bash
{ printf '%s\0' kubectl "$@"; printf '\x1e'; } >> "$CALLS"
case "$*" in
  # 부재 조회(--ignore-not-found = 부재를 exit 0 + 빈 stdout으로) — 소비자가 **둘**이다:
  # teardown의 absence 수렴(mutation)과 status의 라이브 계층(티켓 16). 기본값을 한쪽으로 통일하면
  # 다른 쪽 판정이 무증인이 된다 — 전부 부재로 두면 status의 live 테스트가 전건 red이고, 전부
  # 존재로 두면 teardown의 '기본 = prune 완료' 종결 조건이 vacuous해진다. 그래서 **앱 이름으로 분기**한다.
  #   teardown 대상(myapp-prod): 기본 부재. STUB_APP_STILL_PRESENT=1이면 존재(prune 미완).
  #   그 외(status 레인의 앱):   기본 존재. STUB_APP_ABSENT=1이면 부재(생성 전/prune 완료 창).
  # 두 케이스 모두 존재 조회 패턴보다 **앞**에 있어야 한다(뒤에 두면 `-o json`으로 끝나는 패턴이 선점).
  "-n argocd get applications.argoproj.io myapp-prod -o json --ignore-not-found")
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    if [ -n "${STUB_APP_STILL_PRESENT:-}" ]; then cat "$FIX/argocd-app.json"; fi
    ;;
  "-n argocd get applications.argoproj.io "*" -o json --ignore-not-found")
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    if [ -n "${STUB_APP_ABSENT:-}" ]; then exit 0; fi
    cat "$FIX/argocd-app.json"
    ;;
  "-n argocd get applications.argoproj.io cnpg-data -o json")
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    cat "$FIX/argocd-cnpg-data.json"
    ;;
  "-n argocd get applications.argoproj.io cache-prod -o json")
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    cat "$FIX/argocd-cache.json"
    ;;
  "-n argocd get applications.argoproj.io data-conn-prod -o json")
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    cat "$FIX/argocd-data-conn.json"
    ;;
  "-n argocd get applications.argoproj.io "*" -o json")
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    cat "$FIX/argocd-app.json"
    ;;
  # conn-url 엔진의 자격 secret 조회(jsonpath) — cache 핸들은 redis URL, 나머지는 postgres URL.
  "-n prod get secret cache-"*)
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    printf '%s' "cmVkaXM6Ly91OnBAaG9zdDo2Mzc5"
    ;;
  "-n prod get secret "*|"-n database get secret "*)
    if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
    printf '%s' "cG9zdGdyZXM6Ly91OnBAaG9zdC9kYg=="
    ;;
  *)
    echo "stub kubectl: 계약 밖 호출: $*" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$STUB/kubectl"
}

# 앱 배포 산출물 픽스처 — create-app.ts 산출 형상(values.yaml image.{repo,tag,digest} ·
# .bindings.json autoDeploy · source-repo 한 줄)을 $APPS_ROOT 아래에 재현한다.
# 사용: make_app_fixture <name> [autoDeploy(true|false)] [sourceRepo|-]
make_app_fixture() {
  name="$1"; auto="${2:-true}"; src="${3:-ukyi-app/$1}"
  d="$APPS_ROOT/apps/$name/deploy/prod"
  mkdir -p "$d"
  printf 'image:\n  repo: ghcr.io/ukyi-app/%s\n  tag: sha-1111111%s\n  digest: sha256:%s\n' \
    "$name" "$(printf '%033d' 0)" "$(printf 'ab%062d' 0)" > "$d/values.yaml"
  printf '{ "autoDeploy": %s }\n' "$auto" > "$d/.bindings.json"
  if [ "$src" != "-" ]; then printf '%s\n' "$src" > "$d/source-repo"; fi
}

# 메모리 원장 픽스처 행 — 형식 SSOT는 tools/lib/ledger-totals.ts LEDGER_ROW_RE.
# 사용: make_ledger_row <name> <reqMi> <limitMi> [env]
# ⚠️ env를 인자로 연 이유: 2열을 `prod`로 하드코딩하면 「조인이 env를 본다」는 판정이 **구조적으로**
#    무증인이 된다(모든 픽스처 행이 prod라 조건이 항상 참). 실 원장의 platform 행은 손 편집으로
#    들어와 namespace가 prod가 아닐 수 있고, 그 행이 파일 순서상 앱 행보다 앞선다.
make_ledger_row() {
  mkdir -p "$APPS_ROOT/docs"
  printf '| <!-- ledger:row --> %s | %s | %s | %s |\n' "$1" "${4:-prod}" "$2" "$3" >> "$APPS_ROOT/docs/memory-ledger.md"
}

# git 기록 래퍼 — doctor의 git 계열 관측(`var GIT_COMMITTER_IDENT` · `config --get-urlmatch …`)을
# 공용 원장에 남긴다(cli_stub_init의 심링크를 덮어쓴다). 실물 git으로 exec 위임하는 이유는 판정이
# **실제 git 의미론**이어야 하기 때문이다 — `git var`의 IDENT_STRICT(신원 미설정 = 비-0)를 흉내내면
# 그 흉내가 계약이 되고 라이브에서 어긋난다. 관측 전용 원장 판정(observation-only)의 원료이기도 하다.
# ⚠️ cli_stub_init 뒤에 부른다(심링크가 먼저 생겨야 덮어쓸 자리가 있다).
make_git_stub() {
  git_real="$(command -v git)"
  rm -f "$STUB/git"
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf "%%s\\0" git "$@"; printf "\\x1e"; } >> "$CALLS"\n'
    printf 'exec "%s" "$@"\n' "$git_real"
  } > "$STUB/git"
  chmod +x "$STUB/git"
}

# kubeseal 존재 시나리오 — doctor는 PATH 존재만 보므로(Bun.which) 실행되지 않지만,
# 실행돼도 원장에 남도록 기록 프리앰블을 갖춘다.
make_kubeseal_stub() {
  cat > "$STUB/kubeseal" <<'SH'
#!/usr/bin/env bash
{ printf '%s\0' kubeseal "$@"; printf '\x1e'; } >> "$CALLS"
exit 0
SH
  chmod +x "$STUB/kubeseal"
}

# 앱 레포 픽스처(보조 심 2: 임시 **실물** git 레포) — bare 원격 + 클론. remote URL은 canonical
# 텍스트(https://github.com/ukyi-app/<app>.git)로 두고 url.<bare>.insteadOf로 bare 경로에 매핑한다:
# 엔진은 원본 설정값(`git config --get remote.origin.url`)으로 canonical을 판정하고, push·ls-remote는
# insteadOf를 따라 실제 bare로 간다(네트워크 0). 초기 커밋에 봉인본 v1이 있다 — SEAL_VERSION=1이면
# 동일 봉인본(no-op 경로), 2면 갱신 경로. 평문 .env는 gitignored이고 CANARY 값을 담는다(출력 금지 단언용).
# 사용: make_app_repo_fixture <app> → APP_WORK(클론)·APP_REMOTE(bare) 설정.
CANARY="CANARY-s3cr3t-value-9f8e7d"
export CANARY
make_app_repo_fixture() {
  app="$1"
  APP_REMOTE="$BATS_TEST_TMPDIR/remote-$app.git"
  APP_WORK="$BATS_TEST_TMPDIR/work-$app"
  export APP_REMOTE APP_WORK
  # ⚠️ bare에도 `-b main`을 명시한다 — 전역 config 격리(GIT_CONFIG_GLOBAL=/dev/null) 아래에서는
  # 호스트의 init.defaultBranch가 사라져 HEAD가 master로 잡힌다. 브랜치 main은 push로 생기므로
  # 원격 조작(push·fetch)은 그대로 돌지만, 이 bare를 **클론**하는 레인만 조용히 죽는다
  # (`remote HEAD refers to nonexistent ref` → 체크아웃 없음 → `src refspec main does not match any`).
  git init -q -b main --bare "$APP_REMOTE"
  git init -q -b main "$APP_WORK"
  git -C "$APP_WORK" config user.name "fixture"
  git -C "$APP_WORK" config user.email "fixture@example.com"
  mkdir -p "$APP_WORK/tools" "$APP_WORK/deploy"
  printf 'kind: web\n' > "$APP_WORK/.app-config.yml"
  printf '.env\n' > "$APP_WORK/.gitignore"
  printf 'SECRET_KEY=%s\n' "$CANARY" > "$APP_WORK/.env"
  printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nspec:\n  encryptedData:\n    SECRET_KEY: sealed-v1\n' > "$APP_WORK/deploy/$app-secrets.sealed.yaml"
  # 벤더 봉인 도구 stub — 실물 계약(tools/seal-secret.mts: --config --env 필수, --app으로 산출 경로,
  # .env→deploy/<app>-secrets.sealed.yaml, 값 비출력)을 재현한다. 실물처럼 **비결정 암호문**을 낸다
  # (kubeseal은 같은 평문도 매번 다른 ciphertext) — "재봉인 후 동일성"에 기대는 경로는 여기서 죽는다.
  # 원장에는 도구명과 argv만 기록한다(값 없음).
  # 실패 주입 env(티켓 20 — 연쇄 거부 분기의 증인): STUB_SEAL_FAIL=1(exit 1) ·
  # STUB_SEAL_NO_OUTPUT=1(봉인본 미기록) · STUB_SEAL_FOREIGN=1(봉인본 **외** 파일도 기록).
  cat > "$APP_WORK/tools/seal-secret.mts" <<'TS'
import { appendFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
const argv = process.argv.slice(2);
appendFileSync(process.env.CALLS!, ["seal-secret", ...argv].join("\0") + "\0\x1e");
const get = (k: string) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
if (!get("--config") || !get("--env")) { console.error("seal-secret: --config <.app-config.yml> --env <.env> 필수"); process.exit(1); }
if (process.env.STUB_SEAL_FAIL) { console.error("seal-secret: STUB_SEAL_FAIL"); process.exit(1); }
const app = get("--app") ?? "unknown";
if (process.env.STUB_SEAL_FOREIGN) writeFileSync("deploy/junk.yaml", "junk: 1\n");
if (!process.env.STUB_SEAL_NO_OUTPUT) {
  writeFileSync(`deploy/${app}-secrets.sealed.yaml`, `apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nspec:\n  encryptedData:\n    SECRET_KEY: ct-${randomBytes(6).toString("hex")}\n`);
}
TS
  git -C "$APP_WORK" add -A
  git -C "$APP_WORK" commit -q -m "init"
  git -C "$APP_WORK" remote add origin "https://github.com/ukyi-app/$app.git"
  git -C "$APP_WORK" config "url.$APP_REMOTE.insteadOf" "https://github.com/ukyi-app/$app.git"
  git -C "$APP_WORK" push -q origin main
}

# app init 하네스(보조 심 2 확장) — init은 gh repo create(동적 bare 생성)·canonical URL 클론
# (insteadOf 매핑)·bun run scaffold·gh secret set/list를 쓴다. 실물 git 레포 + init 전용 gh stub으로
# 재현한다. 사용: cli_stub_init 후 make_init_stub → INIT_GCFG(GIT_CONFIG_GLOBAL)·INIT_PARENT(클론 부모)
# 설정. 테스트는 run env에 GIT_CONFIG_GLOBAL="$INIT_GCFG" GIT_CONFIG_SYSTEM=/dev/null을 넘긴다.
#   실패 주입 env: STUB_GH_CREATE_FAIL / STUB_SCAFFOLD_FAIL / STUB_GH_SECRET_FAIL=<name>.
make_init_stub() {
  INIT_REMOTES="$BATS_TEST_TMPDIR/init-remotes"; mkdir -p "$INIT_REMOTES"
  INIT_SECRETS="$BATS_TEST_TMPDIR/init-secrets"; mkdir -p "$INIT_SECRETS"
  INIT_PARENT="$BATS_TEST_TMPDIR/init-parent"; mkdir -p "$INIT_PARENT"
  export INIT_REMOTES INIT_SECRETS INIT_PARENT

  # 격리 git 설정 — insteadOf 접두 매핑(canonical→로컬 bare) + 커밋 신원. 실제 ~/.gitconfig 미간섭.
  INIT_GCFG="$BATS_TEST_TMPDIR/init-gitconfig"
  export INIT_GCFG
  {
    printf '[user]\n\tname = init-fixture\n\temail = init@example.com\n'
    printf '[init]\n\tdefaultBranch = main\n'
    printf '[url "%s/"]\n\tinsteadOf = https://github.com/ukyi-app/\n' "$INIT_REMOTES"
  } > "$INIT_GCFG"

  # 템플릿 bare — gh repo create --template의 시드(스캐폴더 stub + scaffold 스크립트).
  tw="$BATS_TEST_TMPDIR/init-tpl-work"
  git -c init.defaultBranch=main init -q "$tw"
  git -C "$tw" config user.name init-fixture; git -C "$tw" config user.email init@example.com
  mkdir -p "$tw/scaffold"
  # 스캐폴더 stub — 비대화형 계약(--archetype·--name·--yes)을 해석, kind를 아키타입에서 유도,
  # .app-config.yml 생성 + scaffold/ 자가삭제, argv를 공용 원장에 기록. STUB_SCAFFOLD_FAIL시 실패.
  cat > "$tw/scaffold/scaffold.ts" <<'TS'
import { appendFileSync, writeFileSync, rmSync } from "node:fs";
const argv = process.argv.slice(2);
appendFileSync(process.env.CALLS!, ["scaffold", ...argv].join("\0") + "\0\x1e");
if (process.env.STUB_SCAFFOLD_FAIL) { console.error("scaffold: STUB_SCAFFOLD_FAIL"); process.exit(1); }
const get = (k: string) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
const arch = get("--archetype"); const name = get("--name");
if (!arch || !name || !argv.includes("--yes")) { console.error("scaffold: --archetype --name --yes 필수"); process.exit(1); }
const KIND: Record<string, string> = { fullstack: "web", api: "web", site: "site", worker: "worker" };
writeFileSync(".app-config.yml", `kind: ${KIND[arch] ?? "web"}\nresources:\n  requests:\n    cpu: 50m\n    memory: 64Mi\n`);
rmSync("scaffold", { recursive: true, force: true });
TS
  printf '{"name":"tpl","scripts":{"scaffold":"bun scaffold/scaffold.ts"}}\n' > "$tw/package.json"
  git -C "$tw" add -A; git -C "$tw" commit -q -m "template init"
  INIT_TPL_BARE="$INIT_REMOTES/homelab-app-template.git"
  git clone -q --bare "$tw" "$INIT_TPL_BARE"

  # 스캐폴더 계약 원료(preflight) — 기본 호환 소스는 cli_stub_init의 $FIX/scaffold.ts(3 마커 포함).
  # init gh stub이 이 파일을 base64로 낸다(doctor와 같은 소스).

  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
# ⚠️ PATH는 $STUB **대체**라 sed/sort 같은 외부 도구가 없다 — 인자 추출은 bash 파라미터 확장으로만.
{ printf '%s\0' gh "$@"; printf '\x1e'; } >> "$CALLS"
b64() { base64 < "$1"; }
case "$*" in
  # 레포 생성 — 템플릿 bare에서 <app> bare를 복사(private/public 플래그는 argv 원장으로 단언).
  # 인자: $1=repo $2=create $3=ukyi-app/<app> $4=--template $5=<tmpl> $6=--private|--public.
  "repo create ukyi-app/"*" --template ukyi-app/homelab-app-template "*)
    if [ -n "${STUB_GH_CREATE_FAIL:-}" ]; then echo "gh: repo create 실패" >&2; exit 1; fi
    app="${3#ukyi-app/}"
    git clone -q --bare "$INIT_REMOTES/homelab-app-template.git" "$INIT_REMOTES/$app.git"
    # 서버 반영 **뒤** 클라이언트만 죽는 창(appverbs-7) — bare는 만들어졌는데 gh는 비-0이다.
    # STUB_GH_CREATE_FAIL(서버에도 미생성)과 갈리는 축이라 별도 노브다.
    if [ -n "${STUB_GH_CREATE_FAIL_AFTER:-}" ]; then echo "gh: repo create — 서버 반영 후 클라이언트 실패" >&2; exit 1; fi
    ;;
  # 레포 존재 — bare 유무. 인자: $1=api $2=repos/ukyi-app/<app> $3=--jq $4=.name.
  "api repos/ukyi-app/"*" --jq .name")
    app="${2#repos/ukyi-app/}"
    if [ -d "$INIT_REMOTES/$app.git" ]; then printf '%s\n' "$app"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    ;;
  # invocation marker — bare main의 .homelab-init(있으면 base64, 없으면 404). ref는 main 고정이다
  # (init.ts readRemoteMarker와 같은 텍스트 — 어긋나면 계약 밖 호출로 exit 3).
  # $2=repos/ukyi-app/<app>/contents/.homelab-init?ref=main.
  "api repos/ukyi-app/"*"/contents/.homelab-init?ref=main --jq .content")
    rest="${2#repos/ukyi-app/}"; app="${rest%%/*}"
    if git -C "$INIT_REMOTES/$app.git" show main:.homelab-init >/dev/null 2>&1; then
      git -C "$INIT_REMOTES/$app.git" show main:.homelab-init | base64
    else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    ;;
  # 템플릿 스캐폴더 계약 원료(preflight) — 호환 소스($FIX/scaffold.ts, 3 마커).
  "api repos/ukyi-app/homelab-app-template/contents/scaffold/scaffold.ts --jq .content")
    b64 "$FIX/scaffold.ts"
    ;;
  # 시크릿 목록 — 설정된 이름(줄당 하나, 중복 무해: init이 Set으로 dedup). $4=ukyi-app/<app>.
  "secret list --repo ukyi-app/"*" --json name --jq "*)
    app="${4#ukyi-app/}"
    [ -f "$INIT_SECRETS/$app" ] && cat "$INIT_SECRETS/$app" || true
    ;;
  # 시크릿 설정 — 이름을 기록(값은 --body-file 경유라 argv/원장에 안 남는다). STUB_GH_SECRET_FAIL로 주입.
  # 인자: $1=secret $2=set $3=<name> $4=--repo $5=ukyi-app/<app> $6=--body-file $7=<path>.
  "secret set "*" --repo ukyi-app/"*" --body-file "*)
    name="$3"
    if [ "${STUB_GH_SECRET_FAIL:-}" = "$name" ]; then echo "gh: secret set $name 실패" >&2; exit 1; fi
    app="${5#ukyi-app/}"
    printf '%s\n' "$name" >> "$INIT_SECRETS/$app"
    ;;
  *)
    echo "stub gh(init): 계약 밖 호출: $*" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$STUB/gh"
}
