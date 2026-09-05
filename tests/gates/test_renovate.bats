#!/usr/bin/env bats
# Renovate self-hosted 도입 게이트 — 설정/워크플로의 핵심 불변식을 강제한다.
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)
R="renovate.json"
WF=".github/workflows/renovate.yaml"

@test "renovate.json is valid JSON with the homelab guardrails" {
  command -v jq >/dev/null || skip "jq required"
  jq -e . "$R" >/dev/null
  jq -e '.pinDigests == true' "$R" >/dev/null                    # 서드파티 이미지 digest 핀(supply-chain)
  jq -e '.["github-actions"].enabled == false' "$R" >/dev/null   # workflows:write 토큰 전까지 비활성
  jq -e 'any(.ignorePaths[]; . == "**/charts/**")' "$R" >/dev/null # 벤더 helm 캐시 제외
  # pre-commit manager는 Renovate 기본 비활성 — 명시 opt-in이라야 gitleaks rev(.pre-commit-config.yaml)에
  # freshness 소유자가 생긴다. ci.yaml secret-guard 주석이 그 소유를 사실로 적으므로 여기서 fail-closed.
  jq -e '.["pre-commit"].enabled == true' "$R" >/dev/null
}

@test "renovate custom managers cover the homelab version pins" {
  command -v jq >/dev/null || skip "jq required"
  jq -e 'any(.customManagers[]; .depNameTemplate == "k3s-io/k3s")' "$R" >/dev/null
  grep -q 'argo-cd' "$R"        # argocd CHART_VERSION
  grep -q 'helmrelease' "$R"    # HelmChartInflationGenerator(sealed-secrets/tailscale/…)
}

@test "helmrelease custom manager actually extracts ALL charts incl sealed-secrets (no silent miss)" {
  # 존재 단언만으로는 정규식이 실제 차트를 잡는지 모른다 — name↔repo 사이 주석이 있으면 매치 0이 돼
  # sealed-secrets(보안 컨트롤러)가 silent 미추적됐던 버그. renovate.json 실제 matchString으로 추출 검증.
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  ms="$(jq -r '.customManagers[] | select(.description|test("HelmChartInflationGenerator")) | .matchStrings[0]' "$R")"
  [ -n "$ms" ]
  MS="$ms" python3 - <<'PY'
import re, os, glob, sys
# Renovate/RE2 명명그룹 (?<name>) → python (?P<name>)로 변환(매치 여부만 확인).
pat = re.compile(re.sub(r"\(\?<", "(?P<", os.environ["MS"]))
files = sorted(glob.glob("platform/*/prod/helmrelease.yaml")) + sorted(glob.glob("platform/*/helmrelease.yaml"))
missed = [f for f in files if not pat.search(open(f).read())]
assert files, "helmrelease 파일 0개?"
assert not missed, "helmrelease 정규식 미매치(silent 미추적): %s" % missed
assert any("sealed-secrets" in f for f in files), "sealed-secrets helmrelease 부재"
print("ok: %d helmrelease 전부 추출" % len(files))
PY
}

@test "renovate workflow is preflight-gated and writes via a SHA-pinned App token" {
  grep -q 'HOMELAB_WRITER_APP_ID' "$WF"               # Phase-0 preflight skip(미설정 시 clean skip)
  grep -q 'create-github-app-token@bcd2ba4' "$WF"     # 액션 full SHA 핀(레포 규약)
  grep -q 'renovatebot/github-action@8217b3fc' "$WF"  # 액션 full SHA 핀
  grep -q 'permission-contents: write' "$WF"
  grep -q 'permission-pull-requests: write' "$WF"
  grep -q 'permission-issues: write' "$WF"   # Dependency Dashboard(#92) 쓰기 — 미요청 시 ensureIssue 실패
}

@test "renovate token does NOT request workflows:write (consistent with github-actions manager disabled)" {
  # 실제 indented 요청 키만 검사(주석의 Phase-0 안내 언급은 허용). 미요청이라야 App 미보유 시 토큰 민팅이 안 깨진다.
  run grep -qE '^[[:space:]]+permission-workflows:' "$WF"
  # rc 2(파일 부재)를 통과로 읽지 않는다 — grep 무매치는 정확히 rc 1이다.
  [ "$status" -eq 1 ]
}

@test "renovate tracks ArgoCD inline helm charts (cnpg-operator, cert-manager)" {
  command -v jq >/dev/null || skip "jq required"
  # argocd manager가 apps 경로에 활성 — kubernetes(image)·custom(helmrelease) manager가 못 잡는 인라인 차트 핀 커버.
  jq -e '.argocd.managerFilePatterns | any(test("argocd/root/apps"))' "$R" >/dev/null
  # manager가 잡을 입력(인라인 chart 핀)이 실제로 존재해야 한다.
  grep -q 'chart: cloudnative-pg' platform/argocd/root/apps/cnpg-operator.yaml
  grep -q 'chart: cert-manager' platform/argocd/root/apps/cert-manager.yaml
}

@test "the terraform core custom manager extracts every equality pin (no partial-bump PR)" {
  # 병(캠페인 잔여): `required_version = "= X"` 등식은 fail-closed로 잠겨 있지만 **올리는 주체가
  # 사람**이었다 — customManager가 없었고 github-actions manager도 비활성이다. 등식 사본이 여러
  # 파일에 흩어져 있어, 한 사본만 매치 밖이면 Renovate PR이 부분 갱신이 되고 그 PR은 init에서
  # 죽는다. 존재 단언("매니저가 있다")으로는 그 부분성을 못 본다 — **파일별 건수 등식**이 본다.
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  python3 - <<'PY'
import json, re, glob

cfg = json.load(open("renovate.json"))
mgrs = [m for m in cfg.get("customManagers", []) if m.get("depNameTemplate") == "hashicorp/terraform"]
assert len(mgrs) == 1, "terraform customManager는 정확히 1개여야 한다: %d개" % len(mgrs)
m = mgrs[0]
assert m.get("datasourceTemplate") == "github-releases", "datasource 불일치: %r" % m.get("datasourceTemplate")

def rx(s):   # Renovate/RE2 명명그룹 (?<x>) -> python (?P<x>)
    return re.compile(re.sub(r"\(\?<", "(?P<", s))

pats = [rx(s) for s in m["matchStrings"]]
filepats = [re.compile(p[1:-1] if p.startswith("/") and p.endswith("/") else p)
            for p in m["managerFilePatterns"]]

# -- (1) 독립 열거: 함께 움직여야 하는 등식 핀 집합 --------------------------------------------
roots = sorted(glob.glob("infra/*/versions.tf"))
assert roots, "infra/*/versions.tf 0개 — 열거 붕괴(등식 자체가 사라졌다)"
versions, want = set(), {}
for f in roots:
    for line in open(f, encoding="utf-8"):
        mm = re.search(r'required_version\s*=\s*"=\s*([0-9][0-9.]*)"', line)
        if mm:
            versions.add(mm.group(1)); want[f] = want.get(f, 0) + 1
assert len(versions) == 1, "등식 루트의 코어 버전이 갈렸다(부분 갱신 상태): %r" % sorted(versions)
V = versions.pop()

# [7라운드 tfval-cloudflare-3 + tfval-tailscale-github-3] `total >= 5` 집계 바닥값은 한 루트의
# 등식 핀이 통째로 삭제되거나(파일 재작성 실수) 연산자가 `=`->`>=`로 완화돼도(주석이 스스로
# "정확 핀이다"라고 선언하는 fail-closed 계약 이탈) want/got 양쪽에서 그 파일 키가 대칭적으로
# 빠져 무증인이었다(cloudflare 삭제 실측 7/7 ok, github `>=` 완화 실측 7/7 ok). tailscale 루트만
# 의도적으로 `>= 1.9.0`(drift 잡이 헤드룸으로 1.15.5를 씀 — versions.tf 자체 주석)이라 정규식
# 미매치가 정상이라 exempt. 파일별 최소 1건 존재 단언으로 신원까지 닫는다.
EXEMPT = {"infra/tailscale/versions.tf"}
for f in roots:
    if f in EXEMPT:
        continue
    assert want.get(f, 0) >= 1, "%s: 등식 핀 부재(삭제/완화 회귀)" % f

wfs = sorted(glob.glob(".github/workflows/*.yaml"))
for f in wfs:
    for line in open(f, encoding="utf-8"):
        if re.search(r'terraform_version:\s*"%s"' % re.escape(V), line):
            want[f] = want.get(f, 0) + 1
total = sum(want.values())
assert total >= 5, "등식 핀 열거가 %d건 — 붕괴 의심(사본은 5건 이상이어야 한다)" % total

# -- (2) 매니저가 실제로 추출하는 집합 ---------------------------------------------------------
got, values = {}, set()
for f in sorted(set(roots + wfs)):
    text = open(f, encoding="utf-8").read()
    for p in pats:
        for mm in p.finditer(text):
            got[f] = got.get(f, 0) + 1
            values.add(mm.group("currentValue"))

assert got == want, "매치 집합 != 등식 사본 집합\n  등식: %r\n  매치: %r" % (want, got)
assert values == {V}, "매치가 등식 밖 값을 끌어왔다: %r (등식=%s)" % (sorted(values), V)

# -- (3) managerFilePatterns가 매치 파일 전량을 덮는가(패턴이 좁으면 Renovate는 못 본다) -------
for f in got:
    assert any(fp.search(f) for fp in filepats), "managerFilePatterns 밖의 매치 파일: %s" % f

# -- (4) 헤드룸 핀(등식과 일부러 다른 값)은 끌어오지 않는다 ------------------------------------
head = set()
for f in wfs:
    for line in open(f, encoding="utf-8"):
        mm = re.search(r'terraform_version:\s*"([0-9][0-9.]*)"', line)
        if mm and mm.group(1) != V:
            head.add(mm.group(1))
assert head, "헤드룸 핀이 0건 — (4)의 양성 대조가 사라졌다(등식 밖 값이 실재해야 이 축이 의미를 갖는다)"
assert not (head & values), "헤드룸 핀이 등식 PR에 섞였다: %r" % sorted(head & values)

print("ok: 등식 핀 %d건(%s) 전량 매치 · 헤드룸 %r 제외" % (total, V, sorted(head)))
PY
}
