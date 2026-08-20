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
  for t in bun bash base64 cat; do
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

# gh stub — doctor가 낼 수 있는 읽기 호출의 완전 목록(계약 밖 호출은 exit 3).
# 응답은 STUB_* env로 제어: STUB_GH_UNAUTH / STUB_LOGIN / STUB_SCOPES / STUB_NO_SCOPES_HEADER /
# STUB_OWNER / STUB_OWNER_404 / STUB_IS_TEMPLATE. 템플릿 파일 내용은 $FIX 픽스처가 SSOT.
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
  *)
    echo "stub gh: 계약 밖 호출: $*" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$STUB/gh"
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
