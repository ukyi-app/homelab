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
  BUN="$(command -v bun)"
  for t in bun bash base64 cat git; do
    ln -s "$(command -v "$t")" "$STUB/$t"
  done

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
  printf '[]\n' > "$FIX/db-run-jobs.json"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
  printf 'identical\n' > "$FIX/db-compare.txt"
  printf '{"status":{"sync":{"status":"Synced","revision":"feedbee"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"feedbee"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"

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
  printf '{"status":{"sync":{"status":"Synced","revision":"abc1234"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"

  # 앱 배포 산출물 픽스처 루트 — status의 --root 주입 대상(레포 밖 hermetic 검증).
  APPS_ROOT="$BATS_TEST_TMPDIR/repo-root"
  export APPS_ROOT
  mkdir -p "$APPS_ROOT/apps"

  # 원장 파서 — NUL/RS 레코드를 배열로 복원해 질의한다. 모드:
  #   count <argv...>  : 접두 일치 레코드 수
  #   gh-readonly      : 모든 gh 레코드가 `gh api` + 변이 수단 없음인지 (위반 시 비-0)
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
elif mode == "gh-readonly":
    # doctor는 관측 전용 — 모든 gh 레코드는 `gh api`이고 변이 수단이 없어야 한다.
    MUTATION = {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input"}
    bad = [r for r in records if r[:1] == ["gh"] and (r[1:2] != ["api"] or set(r) & MUTATION)]
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
# STUB_GH_HANDLE_404. 템플릿 파일·status 응답 내용은 $FIX 픽스처가 SSOT.
make_gh_stub() {
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
{ printf '%s\0' gh "$@"; printf '\x1e'; } >> "$CALLS"
b64() { base64 < "$1"; }
case "$*" in
  "api -i user")
    if [ -n "${STUB_GH_UNAUTH:-}" ]; then
      echo "gh: To get started with GitHub CLI, please run:  gh auth login" >&2
      exit 4
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
  # ── app secrets 케이스 — update-secrets 디스패처·runs 목록 ──
  "workflow run update-secrets.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/update-secrets.yaml/runs?per_page=20 --jq "*)
    cat "$FIX/secrets-runs.json"
    ;;
  # ── cache create 케이스 — db와 같은 엔진, 디스패처·runs 목록만 cache 것 ──
  "workflow run create-cache.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/create-cache.yaml/runs?per_page=20 --jq "*)
    cat "$FIX/cache-runs.json"
    ;;
  # ── db create 변이 엔진 케이스 — 유일하게 허용되는 변이 argv는 workflow run 하나뿐 ──
  "workflow run create-database.yaml -R ukyi-app/homelab "*)
    if [ -n "${STUB_GH_DISPATCH_FAIL:-}" ]; then echo "gh: workflow dispatch 실패" >&2; exit 1; fi
    ;;
  "api repos/ukyi-app/homelab/actions/workflows/create-database.yaml/runs?per_page=20 --jq "*)
    cat "$FIX/db-runs.json"
    ;;
  "api repos/ukyi-app/homelab/actions/runs/"*"/jobs --jq "*)
    cat "$FIX/db-run-jobs.json"
    ;;
  "api repos/ukyi-app/homelab/actions/runs/"*" --jq {status, conclusion, html_url}")
    cat "$FIX/db-run.json"
    ;;
  "api repos/ukyi-app/homelab/pulls?state=all&head="*" --jq "*)
    cat "$FIX/db-prs.json"
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
  # 표면 blob sha(3상) — ref=feedbee(머지 SHA)는 요청값, 그 외 ref는 관측 리비전.
  "api repos/ukyi-app/homelab/contents/"*" --jq .sha")
    case "$*" in
      *"?ref=feedbee --jq .sha"|*"?ref=main --jq .sha")
        # feedbee=머지 SHA(변이 요청값) · main=no-op 기준(디스패처가 비교한 HEAD)
        if [ -n "${STUB_SURFACE_MERGE_ABSENT:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
        printf 'blobsha-request\n'
        ;;
      *)
        if [ -n "${STUB_SURFACE_ABSENT:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
        if [ -n "${STUB_SURFACE_ERROR:-}" ]; then echo "gh: connect: connection reset" >&2; exit 1; fi
        if [ -n "${STUB_SURFACE_CHANGED:-}" ]; then printf 'blobsha-other\n'; else printf 'blobsha-request\n'; fi
        ;;
    esac
    ;;
  # ── status 동사 케이스 — 응답 픽스처는 $FIX/*.json이 SSOT, 오류 시나리오는 STUB_* env ──
  "api repos/ukyi-app/homelab/pulls?state=open&per_page=100 --jq "*)
    if [ -n "${STUB_GH_PRS_FAIL:-}" ]; then echo "gh: API 오류" >&2; exit 1; fi
    cat "$FIX/homelab-prs.json"
    ;;
  "api repos/"*"/actions/runs?per_page=3 --jq "*)
    if [ -n "${STUB_GH_RUNS_FAIL:-}" ]; then echo "gh: API 오류" >&2; exit 1; fi
    cat "$FIX/runs.json"
    ;;
  "api repos/"*"/actions/runs/"*" --jq "*)
    if [ -n "${STUB_GH_HANDLE_404:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    cat "$FIX/run-handle.json"
    ;;
  "api repos/"*"/pulls/"*" --jq "*)
    if [ -n "${STUB_GH_HANDLE_404:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
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
# STUB_KUBECTL_FAIL 설정 시 클러스터 접근 실패를 재현한다.
make_kubectl_stub() {
  cat > "$STUB/kubectl" <<'SH'
#!/usr/bin/env bash
{ printf '%s\0' kubectl "$@"; printf '\x1e'; } >> "$CALLS"
case "$*" in
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
# 사용: make_ledger_row <name> <reqMi> <limitMi>
make_ledger_row() {
  mkdir -p "$APPS_ROOT/docs"
  printf '| <!-- ledger:row --> %s | prod | %s | %s |\n' "$1" "$2" "$3" >> "$APPS_ROOT/docs/memory-ledger.md"
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
  git init -q --bare "$APP_REMOTE"
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
  cat > "$APP_WORK/tools/seal-secret.mts" <<'TS'
import { appendFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
const argv = process.argv.slice(2);
appendFileSync(process.env.CALLS!, ["seal-secret", ...argv].join("\0") + "\0\x1e");
const get = (k: string) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
if (!get("--config") || !get("--env")) { console.error("seal-secret: --config <.app-config.yml> --env <.env> 필수"); process.exit(1); }
const app = get("--app") ?? "unknown";
writeFileSync(`deploy/${app}-secrets.sealed.yaml`, `apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nspec:\n  encryptedData:\n    SECRET_KEY: ct-${randomBytes(6).toString("hex")}\n`);
TS
  git -C "$APP_WORK" add -A
  git -C "$APP_WORK" commit -q -m "init"
  git -C "$APP_WORK" remote add origin "https://github.com/ukyi-app/$app.git"
  git -C "$APP_WORK" config "url.$APP_REMOTE.insteadOf" "https://github.com/ukyi-app/$app.git"
  git -C "$APP_WORK" push -q origin main
}
