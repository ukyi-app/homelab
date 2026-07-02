# 아키텍처 리팩토링 캠페인 구현 계획 (2026-07-02)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 15차원 감사 확정 결함(HIGH 2·MEDIUM ~20)을 해소하고 4대 페인포인트(변이 경로 복잡도·tools/scripts 이원화·시크릿 2원화·골든패스 한계)의 구조적 원인을 3-웨이브 13배치로 제거한다.

**Architecture:** 설계 SSOT = `docs/plans/2026-07-02-arch-refactor-campaign-design.md`(A.5 적대 리뷰 반영 확정본). 디렉토리 재배치 없음 — 계약·파이프라인·가드 수준 리팩토링. Wave 1(정지혈+내구성 B1~B5) → Wave 2(구조 4테마+메모리 헤드룸 B6~B10) → Wave 3(cross-repo 계약+하드닝 B11~B13). 각 배치 섹션은 대상 파일 실측 기반이며 "⚠️ 설계 보정"은 실측이 설계 스냅샷을 이긴 지점이다.

**Tech Stack:** GitHub Actions(reusable/composite) · Bun+TS(`tools/`) · bash+bats · Helm/kustomize/KSOPS · Terraform · ArgoCD · VictoriaMetrics/vmalert · SealedSecrets/SOPS

---

## 캠페인 실행 규범 (전 배치 공통)

- **브랜치·PR**: 배치당 브랜치 `refactor/b<N>-<slug>`, 배치=1~3 PR, **직렬 머지**(스택 PR squash 함정 — base 브랜치를 `--delete-branch`로 머지하면 의존 PR 자동 CLOSE). 각 PR은 required check `gate` 통과 필수, 머지 직전 main 위로 rebase.
- **게이트**: 각 PR 전 `make ci` 로컬 통과. 호스트 bun은 레포 핀 1.3.14 필수 — `mise install bun@1.3.14` 후 `export PATH="$HOME/.local/share/mise/installs/bun/1.3.14/bin:$PATH"`. 라이브 검증은 `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig` 전제.
- **배치 완료 조건**: 해당 배치의 "게이트·라이브 검증" 절차 전부 green → 다음 배치 착수. 라이브 리스크 배치(B2·B5·B6·B10·B11)는 명시된 관찰·카나리 절차 완료가 조건.
- **순서·의존성**:
  - Wave 1: B1 → B2(B1 선행) → B3 → B4 → B5. B3·B4·B5는 상호 독립이나 머지는 직렬.
  - Wave 2: B6·B7·B8·B9는 Wave 1 완료 후 상호 독립. B10은 B7 이후(GOMEMLIMIT 게이트 TS 경로 전제). **GOMEMLIMIT 검사는 정확히 한쪽 구현**: B2(셸) → B7(TS 1:1 이식) — 이중 구현 금지.
  - Wave 3: B11은 **B6(actor 가드) 선행 필수** + 템플릿 로컬 체크아웃 pull(2커밋 뒤). B12 → B13(B3·B8·B12 흡수 항목을 실측 재확인 후 잔여만 실행).
- **커밋**: 한국어 conventional(`feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`만), AI 마커 금지. 각 태스크의 커밋 스텝을 따른다.
- **owner-local 절차**(라이브 SC 마이그레이션, launchd 배선, 시크릿 재봉인, 앱 레포 시크릿·설치 설정)는 각 배치에 표기 — 실행 세션은 해당 지점에서 절차를 안내하고 owner 확인 후 진행한다.
- **시크릿 규율**: 시크릿 값 stdout·로그 출력 금지, `*.enc.yaml` 직접 수정 금지(sops 왕복만).

---

## B1. 변이 파이프라인 fail-closed (Wave 1)

**목표** GHA run 기본 셸(`bash -e {0}`)의 pipefail 부재로 변이 reusable의 `bun 도구 | tee` 파이프 좌변 실패가 삼켜져 부분 변이 산출물이 PR·auto-merge로 새는 fail-open(M1)을 구조적으로 봉쇄하고, 재발 가드(bats)와 트랩 원장 등재로 고정한다.

**선행 조건** 없음(Wave 1 첫 배치). 워크트리 `main` 최신에서 작업 브랜치 생성: `git checkout -b refactor/b1-mutation-pipefail`.

**PR 구성**: PR-1a "fix: 변이 파이프라인 fail-closed — defaults.run.shell(pipefail) + digest 가드 파이프 분리 + 재발 가드" (단일 PR, 커밋 3개 직렬).

⚠️ 설계 보정:
- 설계 인용 앵커는 전부 실측 일치 — `_create-database.yaml:61,63`·`_create-cache.yaml:61`·`_create-app.yaml:70-72,96-98`·`audit.yaml:24`·`_teardown-app.yaml:47` 현행 파일에서 그대로 확인됨.
- **`_update-secrets.yaml`은 현재 run 스텝에 파이프 0개** — 그래도 fleet 균일성·미래 스텝 커버를 위해 defaults를 예방 적용한다(조사 결과를 근거로 명시).
- 전수 조사에서 동류 fail-open 1건 추가 발견: `audit.yaml:25`의 `echo "count=$(jq …)"` — jq 실패가 echo의 exit 0에 삼켜진다. 같은 클래스라 B1.2에 포함.
- 스펙에 없는 **필수 동반 변경**: 신규 트랩 등재는 traps.md+traps-detail만으로는 gate가 깨진다 — `tests/gates/test_traps-sync.bats`가 AGENTS.md 한줄 인덱스의 **존재+개수 일치**를 강제하므로 AGENTS.md 불릿을 반드시 함께 추가(B1.3).

**택1 근거 (per-step `set -euo pipefail` vs 워크플로 `defaults.run.shell: bash`) — defaults 채택:**
1. 스텝별 삽입 규율은 이번 결함의 발생 기전 그 자체다 — `_teardown-app`에만 있고 형제 5개가 누락된 것이 M1. 스텝 단위 규율은 복제 시 또 갈라진다.
2. 명시 `shell: bash`는 GHA 문서상 `bash --noprofile --norc -eo pipefail {0}` — 워크플로 레벨 1키로 현재+미래 전 run 스텝을 커버.
3. 가드 bats가 워크플로 레벨 단일 키(`defaults.run.shell`)로 결정 가능하게 검사할 수 있다(yq 버전차 함정 회피 — bun+yaml 파서 사용, `test_workflow-yaml.bats` 선례).
4. `-u`는 defaults에 없으나, 유일하게 이미 갖춘 `_teardown-app`의 in-step `set -euo pipefail`은 유지(파괴 경계 belt-and-suspenders + `-u` 추가분).

**파이프 전수 조사 결과 (레포 전체 `| tee`는 아래 6파일이 전부, `defaults:`/`shell:` 선언은 현재 0):**

| 파일:라인 | 파이프 | pipefail 후 동작 변화 |
|---|---|---|
| `_create-app.yaml:70-72` | `docker … \| jq -r .digest \|\| {…}` | docker 실패가 `\|\|` 핸들러에 정상 도달(현재는 jq exit 0에 삼켜져 digest 빈값 유출) — 추가로 B1.2에서 파이프 분리 |
| `_create-app.yaml:96-98` | `bun tools/create-app.ts … \| tee` | bun 실패 시 스텝 실패(의도) |
| `_create-app.yaml:100-101` | `helm template \| kubeconform` | helm 실패 시 스텝 실패(의도 — 현재는 빈 입력 kubeconform green) |
| `_create-database.yaml:43,45` | `printf \| grep -Eq \|\| {…}` / `printf \| jq` | 무변화(grep 실패는 기존 `\|\|` 핸들러 동일) |
| `_create-database.yaml:61,63` | `bun tools/provision-db.ts \| tee` | bun 실패 시 스텝 실패(의도) |
| `_create-cache.yaml:61` | `bun tools/provision-cache.ts \| tee` | bun 실패 시 스텝 실패(의도) |
| `_update-secrets.yaml` | (파이프 없음) | 무변화 — 예방 적용 |
| `audit.yaml:24` | `bun tools/audit-orphans.ts \| tee` | bun 크래시 시 스텝 실패 → 기존 `outcome == 'failure'` 폴백 경로(C-F2)가 처리. **드리프트 발견은 exit 0**(`--ci`/`--strict` 미사용 — `tools/audit-orphans.ts:130-133` 실측)이라 드리프트 알림 경로 무변화 |
| `_teardown-app.yaml:51` | `bun tools/teardown-app.ts \| tee` | 무변화(in-step `set -euo pipefail` 기보유) — 주석만 정정 |

### B1.1 defaults.run.shell 일괄 삽입 + 재발 가드 bats + teardown 오해 주석 정정

**Files:**
- Create: `tests/gates/test_workflow-pipefail.bats`
- Modify: `.github/workflows/_create-app.yaml:12-14` · `_create-database.yaml:13-15` · `_create-cache.yaml:13-15` · `_update-secrets.yaml:12-14` · `_teardown-app.yaml:12-13,47` · `audit.yaml:14-15` (각각 마지막 top-level 키와 `jobs:` 사이에 defaults 삽입)
- Test: `tests/gates/test_workflow-pipefail.bats` (git tracked → run-bats 자동 수집, CI-safe — bun+yaml만 필요)

**Step 1** — 실패 테스트 작성:

```bash
#!/usr/bin/env bats
# 변이 파이프라인 fail-closed 가드 — GHA run 기본 셸은 `bash -e {0}`(pipefail 없음).
# `bun 도구 | tee` 파이프의 좌변 실패가 tee exit 0에 삼켜지면 부분 변이 산출물이
# PR·auto-merge로 샐 수 있다(M1). 명시 shell: bash = `bash --noprofile --norc -eo pipefail {0}`.
# ① 변이 계열 6종은 defaults.run.shell=bash 선언 강제(신규 스텝 자동 커버),
# ② 전 워크플로: `| tee` run 스텝은 defaults/스텝 shell(bash) 또는 in-step pipefail 필수.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정. yq 비사용(CI/로컬 버전차 함정) — bun+yaml 파서.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "mutation-family workflows declare defaults.run.shell bash (structural pipefail)" {
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const fleet = ["_create-app", "_create-database", "_create-cache", "_update-secrets", "_teardown-app", "audit"];
    const bad = [];
    for (const w of fleet) {
      const p = process.argv[1] + "/.github/workflows/" + w + ".yaml";
      const doc = y.parse(fs.readFileSync(p, "utf8"));
      const sh = doc?.defaults?.run?.shell ?? "";
      if (!/^bash\b/.test(sh)) bad.push(w + ".yaml: defaults.run.shell != bash");
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}

@test "every workflow run step piping into tee is pipefail-covered" {
  # tee 클래스만 검사 — 일반 파이프 탐지는 jq/yq 필터 문자열 속 |와 구분 불가(오탐원)라 비대상.
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const dir = process.argv[1] + "/.github/workflows";
    const bad = [];
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ya?ml$/.test(f)) continue;
      const doc = y.parse(fs.readFileSync(dir + "/" + f, "utf8"));
      const wfBash = /^bash\b/.test(doc?.defaults?.run?.shell ?? "");
      for (const [jn, job] of Object.entries(doc?.jobs ?? {})) {
        const jobBash = /^bash\b/.test(job?.defaults?.run?.shell ?? "");
        (job?.steps ?? []).forEach((st, i) => {
          if (typeof st?.run !== "string" || !/\|\s*tee\b/.test(st.run)) return;
          const stepBash = /^bash\b/.test(st?.shell ?? "");
          const inStep = /set\s+-\w*o\s+pipefail/.test(st.run);
          if (!(wfBash || jobBash || stepBash || inStep))
            bad.push(f + " jobs." + jn + ".steps[" + i + "]: tee 파이프에 pipefail 부재");
        });
      }
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}
```

**Step 2** — 실행, 실패 확인:

```bash
bats tests/gates/test_workflow-pipefail.bats
```

기대: `2 tests, 2 failures` — 테스트 1은 6파일 전부 `defaults.run.shell != bash`, 테스트 2는 `_create-app`·`_create-database`·`_create-cache`·`audit`의 tee 스텝 미커버(`_teardown-app`은 in-step set으로 통과, `_update-secrets`는 tee 없음).

**Step 3** — 최소 구현. 6개 워크플로 각각, 마지막 top-level 키와 `jobs:` 사이에 아래 동일 블록 삽입:

```yaml
# 기본 셸(bash -e {0})은 pipefail 부재 — 명시 bash로 전 run 스텝에 -eo pipefail 강제
# (가드: tests/gates/test_workflow-pipefail.bats)
defaults:
  run:
    shell: bash
```

삽입 앵커(각 파일 1곳, 현행 라인 기준):
- `_create-app.yaml`: `type: string`(12행)과 `jobs:`(14행) 사이 빈 줄 자리
- `_create-database.yaml`: `type: string`(13행)과 `jobs:`(15행) 사이
- `_create-cache.yaml`: `type: string`(13행)과 `jobs:`(15행) 사이
- `_update-secrets.yaml`: `type: string`(12행)과 `jobs:`(14행) 사이
- `_teardown-app.yaml`: confirm 블록 `type: string`(12행)과 `jobs:`(13행) 사이
- `audit.yaml`: `cancel-in-progress: false`(14행)와 `jobs:`(15행) 사이

이어서 `_teardown-app.yaml:47`의 오해 주석 한 줄을 아래 3줄로 교체:

기존(47행):
```yaml
          set -euo pipefail   # 파괴 단계 명시 fail-closed(GHA 기본 -eo pipefail에 더한 belt-and-suspenders — bun|tee 실패가 PR 생성으로 새지 않게)
```

교체:
```yaml
          set -euo pipefail   # 파괴 단계 belt-and-suspenders — ⚠️ GHA 기본 셸은 bash -e {0}(pipefail 없음).
          # defaults(shell: bash)가 -eo pipefail을 이미 주고, 여기선 -u(미정의 변수 차단)까지 추가한다.
          # 과거 주석의 "GHA 기본 -eo pipefail"은 반대 오해였다 — 기본(-e만)과 명시 bash를 혼동하지 말 것.
```

**Step 4** — 게이트:

```bash
bats tests/gates/test_workflow-pipefail.bats          # 기대: 2 tests, 0 failures
bats tests/gates/test_workflow-yaml.bats              # 기대: YAML 파싱 전부 통과(삽입이 문법 안 깨뜨림)
bats tools/tests/test_mutation-dispatch.bats          # 기대: 기존 계약 불변(auto-merge 부재 단언 포함) 통과
./scripts/run-bats.sh --list | grep workflow-pipefail # 기대: 신규 테스트가 gate 수집에 자동 편입
command -v actionlint >/dev/null && actionlint || echo "actionlint 로컬 부재 — gate가 강제"
```

**Step 5** — 커밋:

```bash
git add tests/gates/test_workflow-pipefail.bats \
  .github/workflows/_create-app.yaml .github/workflows/_create-database.yaml \
  .github/workflows/_create-cache.yaml .github/workflows/_update-secrets.yaml \
  .github/workflows/_teardown-app.yaml .github/workflows/audit.yaml
```

커밋 메시지(/commit 스킬 사용): `fix: 변이 워크플로 fail-closed — defaults.run.shell=bash(pipefail) 일괄 + 재발 가드 bats + teardown 오해 주석 정정`

### B1.2 _create-app digest 가드 파이프 분리 + audit count 대입 분리

**Files:**
- Modify: `.github/workflows/_create-app.yaml:70-72` (id: img 스텝), `.github/workflows/audit.yaml:25`
- Test: 기존 `tests/gates/test_workflow-yaml.bats`(파싱) + actionlint(gate) — 셸 조각이라 전용 bats 없음, 형식 가드는 case 문 자체가 수행

**Step 1** — `_create-app.yaml` id: img 스텝의 파이프(70-72행)를 교체.

기존:
```yaml
          digest=$(docker buildx imagetools inspect "ghcr.io/ukyi-app/${app}:${tag}" \
            --format '{{json .Manifest}}' | jq -r .digest) \
            || { echo "::error::이미지 미존재 — 앱 레포에서 빌드(GHCR push) 먼저"; exit 1; }
```

교체(파이프 분리 — docker 실패와 jq 파싱 실패를 구분, 빈/이상 digest는 형식 검사로 차단):
```yaml
          # 파이프 분리 — docker 실패/jq 파싱 실패를 구분하고, 성공-빈출력(digest="" 또는 null)도 형식 검사로 차단
          manifest=$(docker buildx imagetools inspect "ghcr.io/ukyi-app/${app}:${tag}" \
            --format '{{json .Manifest}}') \
            || { echo "::error::이미지 미존재 — 앱 레포에서 빌드(GHCR push) 먼저"; exit 1; }
          digest=$(jq -r .digest <<<"$manifest") \
            || { echo "::error::manifest JSON 파싱 실패"; exit 1; }
          case "$digest" in
            sha256:?*) ;;
            *) echo "::error::digest 형식 이상: '${digest}'"; exit 1;;
          esac
```

**Step 2** — `audit.yaml:25` 인라인 명령치환을 대입으로 분리(동류 fail-open — jq 실패가 echo exit 0에 삼켜짐).

기존:
```yaml
          echo "count=$(jq -r .count /tmp/audit.json)" >> "$GITHUB_OUTPUT"
```

교체:
```yaml
          # 명령치환을 echo 인자에 인라인하면 jq 실패가 echo exit 0에 삼켜진다 → 대입 분리(-e가 잡음)
          count=$(jq -r .count /tmp/audit.json)
          echo "count=$count" >> "$GITHUB_OUTPUT"
```

**Step 3** — 게이트:

```bash
bats tests/gates/test_workflow-yaml.bats tests/gates/test_workflow-pipefail.bats  # 기대: 전부 통과
bash -n <(sed -n '/id: img/,/GITHUB_OUTPUT/p' .github/workflows/_create-app.yaml | grep -E '^\s{10}' | sed 's/^ *//') \
  || true  # 참고용 셸 문법 스모크 — 권위 검사는 gate actionlint(shellcheck 통합)
```

**Step 4** — 커밋:

```bash
git add .github/workflows/_create-app.yaml .github/workflows/audit.yaml
```

커밋 메시지: `fix: _create-app digest 가드 파이프 분리(형식 검사 추가) + audit count 대입 분리`

### B1.3 traps 원장·SSOT·AGENTS 인덱스 등재

**Files:**
- Modify: `docs/traps.md`(표 말미, 현행 41행 뒤), `docs/traps-detail.md`(파일 말미 — 현행 마지막 섹션 "상주 워크로드 자원 limit 블라인드스팟" 뒤), `AGENTS.md:98`("- 상주 워크로드 자원 limit 블라인드스팟" 불릿 바로 아래)
- Test: `make verify-traps` + `bats tests/gates/test_traps-sync.bats tests/gates/test_verify-traps.bats`

**Step 1** — `docs/traps-detail.md` 말미에 섹션 추가(첫 컬럼·헤드라인에 `|` 문자 금지 — 마크다운 표/grep 회피):

```markdown
### GHA run 기본 셸 pipefail 부재(bash -e {0})
- GitHub Actions run 스텝의 기본 셸은 `bash -e {0}` — **pipefail이 없다**. `bun 도구 | tee 로그` 류
  파이프는 좌변(도구) 실패가 tee의 exit 0에 삼켜져 스텝이 green — 변이 reusable에선 부분 산출물이
  PR·auto-merge로 샐 수 있다(fail-open). 명시 `shell: bash`는 `bash --noprofile --norc -eo pipefail {0}`로
  실행되므로 워크플로 `defaults.run.shell: bash`가 구조적 해법(신규 스텝 자동 커버). 스텝별
  `set -euo pipefail` 삽입 규율은 이 결함의 발생 기전 그 자체(_teardown-app만 있고 형제 5개 누락)라
  비채택. 과거 _teardown-app 주석의 "GHA 기본 -eo pipefail"은 **반대 오해**였다 — 기본(-e만)과
  명시 bash(-eo pipefail)를 혼동하지 말 것. 명령치환 인라인(`echo "x=$(jq …)"`)도 동류 fail-open —
  대입으로 분리해야 -e가 잡는다.
> 가드: `tests/gates/test_workflow-pipefail.bats`
```

**Step 2** — `docs/traps.md` 표 말미(homepage 행 뒤)에 원장 행 추가:

```markdown
| GHA run 기본 셸 pipefail 부재(bash -e {0}) — tee 파이프 fail-open | gate | `tests/gates/test_workflow-pipefail.bats` |
```

**Step 3** — `AGENTS.md:98` `- 상주 워크로드 자원 limit 블라인드스팟` 바로 아래에 불릿 추가(헤드라인과 **문자 단위 동일** — test_traps-sync가 `grep -Fq` + 개수 일치로 강제):

```markdown
- GHA run 기본 셸 pipefail 부재(bash -e {0})
```

**Step 4** — 검증:

```bash
make verify-traps
# 기대: "verify-traps: 원장 guard 실재 + SSOT 가드주석↔원장 일치 OK"
bats tests/gates/test_traps-sync.bats tests/gates/test_verify-traps.bats
# 기대: 전부 통과(AGENTS 인덱스 존재+개수 일치, 역방향 guard-path-tie)
make verify
# 기대: skeleton/원장/sops 라운드트립 통과(문서 변경 무영향 확인)
```

**Step 5** — 커밋:

```bash
git add docs/traps.md docs/traps-detail.md AGENTS.md
```

커밋 메시지: `docs: GHA 기본 셸 pipefail 부재 함정 등재(traps 원장·SSOT·AGENTS 인덱스)`

**게이트·라이브 검증**

```bash
# 1) 풀 게이트 재현 (PR 필수)
make ci
# 기대: m6-tools OK → chart-test → typecheck → verify:ledger → audit-orphans --ci →
#       check-skeleton → run-bats(신규 test_workflow-pipefail.bats 포함 전부 green) → shellcheck → sops-guard

# 2) PR 생성 → required check `gate` green → 머지 (/pr 스킬, 직렬 머지)

# 3) 머지 후 라이브-경로 검증: audit 워크플로 수동 디스패치(비변이 reconciler — 안전)
gh workflow run audit.yaml
sleep 30 && gh run list --workflow=audit.yaml --limit 1
gh run watch "$(gh run list --workflow=audit.yaml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
# 기대: conclusion=success + 로그에 "드리프트 0건 — 알림 skip"(현 드리프트 0 전제) —
#       defaults(shell: bash) 하에서 bun|tee·jq 대입 경로가 실런에서 정상 동작함을 확인
```

변이 reusable 4종의 실사용 라이브 검증은 실제 변이가 필요하므로 **B6 카나리 변이(비파괴 update-secrets) 시점으로 이월** — B1 자체는 정적 게이트 + audit 디스패치 1회로 완결(클러스터 무영향 배치, `KUBECONFIG` 불요).

**롤백 노트** 전 변경이 additive/엄격화(정적 워크플로 + 문서 + 테스트)라 라이브 리소스 무영향 — `git revert <merge-sha>` 1회로 원상 복귀(가드 bats와 원장 행이 같은 PR이라 revert 후에도 verify-traps 정합 유지). 만약 pipefail 엄격화로 정상 변이가 오탐 차단되는 사례가 발견되면(예: 도구가 관행적으로 비-0 종료) revert가 아니라 해당 도구의 종료코드를 고치는 것이 옳다 — fail-open 복원은 금지.

**다음 배치 진행 조건** PR-1a 머지 + `gate` green + audit 디스패치 1회 success 확인 → B2(감시 소생) 진행. B1의 가드 스타일(bun+yaml 파서 기반 워크플로 구조 검사)은 B6의 DISPATCHERS 동적 파생 테스트가 재사용할 선례임을 인수인계에 명시.
## B2. 감시 소생 (R6·NotReady·GOMEMLIMIT·CacheBackupStale) (Wave 1)

**목표** 사문화된 R6 알림 그룹(ArgoCDOutOfSync·ImageDigestDrift)을 실제 발화 가능 상태로 되살리고, 구독 라벨 없는 플랫폼 컴포넌트(files·adguard·homepage)의 NotReady 공백·vmalert GOMEMLIMIT 역전·cache-backup staleness 비대칭을 vmalert 룰/가드로 메운다. 구조 변화 최소, 위험 노출 순으로 3 PR 직렬 머지.

**선행 조건** B1(변이 파이프라인 fail-closed) 머지 완료. 라이브 검증은 `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig` 전제. PR-2b의 seal 단계는 owner-local(`.env.secrets`의 `GHCR_PULL_TOKEN` + `kubeseal` + `tools/sealed-secrets-cert.pem` 필요).

**PR 구성** (직렬 머지 — 스택 squash 함정 회피):
- **PR-2a** "R6 ArgoCDOutOfSync 소생 — controller scrape 배선 + absent 가드" (B2.1). 라이브: argocd controller 재시작 수반.
- **PR-2b** "R6 ImageDigestDrift 소생 — digest-exporter 자격·격리·APPS + recording-rule 정정 + 변이 체인 배선" (B2.2·B2.3). owner-local seal 1회.
- **PR-2c** "워크로드-불가용·GOMEMLIMIT·캐시백업 알림" (B2.4·B2.5·B2.6). 순수 룰/가드 추가.

---

### ⚠️ 설계 보정 (실파일 우선 — 설계 §1.1·§3 B2 스냅샷과의 어긋남)

설계 §1.1 H1의 digest 절반("digest-exporter APPS에 page·trip-mate-api 추가")은 실파일 검증 결과 **그대로는 silent no-op**이다. 세 독립 블로커를 확인했다:

1. **private 패키지 (신규 발견)** — 공유차트 `platform/charts/app/values.yaml:10`이 `imagePullSecrets: [{ name: ghcr-pull }]`를 기본으로 박고, 주석이 "인레포 앱은 전부"라고 명시한다. 즉 page·trip-mate-api는 **private GHCR** 패키지다. `digest-exporter.yaml`의 CronJob에는 어�any auth/secret도 없어(`grep secret|auth` 0건) 자격 없는 `skopeo inspect`는 401 → `DIGEST` 공백 → `continue`(digest-exporter.yaml:15) → 여전히 0 시리즈. **APPS만 채우면 아무 일도 안 일어난다.** → B2.2에서 observability NS `ghcr-read` SealedSecret + skopeo `--authfile` 필수.

2. **recording-rule join 이중 파손 (신규 발견)** — `r6-ci-staleness.yaml:20-28`의 `app:image_digest_drift`는 (a) 좌변 `max by (app)`이 `digest` 라벨을 떨구고, (b) 우변 `kube_pod_container_info`에 `app` 라벨이 없어 `unless on (app, digest)` 매칭이 **영구 미스** → APPS가 채워지는 순간 drift가 **상시 1(오발화)**. 입력이 늘 비어 있어 라이브로 한 번도 검증된 적 없는 죽은 식이다. → B2.2에서 좌변 `by (app, digest)` 보존 + 우변 `image` 라벨에서 `app` 추출로 양변 정렬.

3. **immutable sha 태그 + 스냅샷 APPS** — 앱 빌드는 `sha-<gitsha>` 불변 태그만 push한다(`reusable-app-build.yaml:35,48`). 정정된 rule은 정상상태(steady-state)에서 clean(ghcr_latest==pod digest → drift 없음)이나, **이미지 bump 직후** 파드는 NEW·exporter는 OLD를 가리켜 일시 오발화한다. → `ImageDigestDrift`는 `for: 20m` 유지 + **B2→B9 경성 의존**: B9 `bump-tag` 인라인 핀 편집이 digest-exporter APPS 태그도 함께 갱신해야 한다(또는 B11에서 빌드가 moving 태그 `:main`을 push하고 exporter가 그걸 추적하는 것이 근본 해). 게이트는 **태그 무관 name-parity**만 검사해 bump 신선도와 커플링하지 않는다.

또한 정정된 ArgoCDOutOfSync(B2.1, 자격 불요)가 "배포 이미지 ≠ git desired" 클래스를 앱 수준에서 이미 커버하므로, ImageDigestDrift의 고유 가치는 얇다. **owner 결정점**: 위 3블로커의 유지비(ghcr-read 봉인 + bump 커플링)가 과하다고 판단되면 설계 §1.1 옵션 ③(R6 digest 절반을 명시 제거 + 런북 문구 갱신)으로 축소 가능. 본 계획은 스펙이 "create-app/teardown-app 배선(도구 코드 수정+테스트)"을 명시하므로 **완전 구현**을 택한다.

기타 스냅샷 앵커 보정:
- 설계는 controller port를 "8082"라 적었고 실파일 확인 결과 argo-helm 10.0.1 controller는 8082가 metrics 기본 — `controller.podAnnotations`로 배선(맞음).
- files Deployment는 namespace `files`(kustomization.yaml:3), adguard=`edge`, homepage=`homepage` — NotReady 룰은 시스템 ns 블랙리스트로 3종 모두 자동 커버(설계 의도대로).
- observability NS는 ns-wide default-deny egress가 **없다**(networkpolicy.yaml:4-11 주석: metrics 평면 불간섭, 외부-egress 워크로드만 셀렉터 격리). digest-exporter는 현재 pod 라벨이 없어 격리 대상에서 제외돼 있다 — 활성화 시 자격 보유 워크로드가 무제한 egress가 되므로 **pod 라벨 + 전용 egress netpol 추가**(관측성 netpol 철학 준수).

---

### B2.1 ArgoCD controller metrics scrape 배선 + ArgoCDOutOfSync absent 가드 (PR-2a)

**Files:** Modify: `platform/argocd/bootstrap-values.yaml`(controller 블록 :14-23), `platform/victoria-stack/prod/rules/r6-ci-staleness.yaml`(:12-18), `platform/argocd/test_argocd_values.bats`(신규 @test), `tests/gates/test_vmalert-config.bats`(신규 @test). Test: `platform/argocd/test_argocd_values.bats`(gate-collected), `tests/gates/test_vmalert-config.bats`.

**Step 1 — 실패 테스트 작성.** `platform/argocd/test_argocd_values.bats` 말미에 추가:
```bash
@test "application-controller is scraped by pod-annotations (R6 argocd_app_info source)" {
  V="platform/argocd/bootstrap-values.yaml"
  run yq '.controller.podAnnotations."prometheus.io/scrape"' "$V"; [ "$output" = "true" ]
  run yq '.controller.podAnnotations."prometheus.io/port"' "$V"; [ "$output" = "8082" ]
}
```
`tests/gates/test_vmalert-config.bats` 말미에 추가:
```bash
@test "R6 ArgoCDOutOfSync has an absent() fail-closed guard like the other R-rules" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  grep -q 'alert: ArgoCDOutOfSync' "$R"
  grep -q 'absent(argocd_app_info)' "$R"   # scrape 재단절 시 silent 무발화 방지
}
```

**Step 2 — 실행(기대 실패).**
```
bats platform/argocd/test_argocd_values.bats tests/gates/test_vmalert-config.bats
```
기대: 새 @test 2건 `not ok`(`podAnnotations`=null, `absent(argocd_app_info)` 미존재), 기존 통과.

**Step 3 — 최소 구현.** `bootstrap-values.yaml`의 `controller:` 블록에서 `replicas: 1`(:17) 다음 줄에 삽입:
```yaml
  # application-controller metrics(8082)를 pod-annotations job이 scrape → argocd_app_info 공급(R6).
  # argocd ns는 netpol 격리 없음(chart netpol OFF·prod netpol은 prod 한정)이라 vmagent(observability)가 자유 scrape.
  podAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8082"
```
`r6-ci-staleness.yaml`의 ArgoCDOutOfSync expr(:13) `expr: argocd_app_info{sync_status="OutOfSync"} == 1`를 absent 가드 포함 블록으로 교체:
```yaml
            expr: |
              argocd_app_info{sync_status="OutOfSync"} == 1
              or absent(argocd_app_info)
```
그리고 description(:18)에 scrape-단절 문구 1문장 추가: `" 메트릭이 통째로 사라지면(scrape 단절) absent 가드가 fail-closed로 페이징한다."`

**Step 4 — 게이트.**
```
bats platform/argocd/test_argocd_values.bats tests/gates/test_vmalert-config.bats
make ci
```
기대: 전부 `ok`. `make ci`의 skeleton/원장/자원가드/bats 통과.

**Step 5 — 커밋.**
```
git add platform/argocd/bootstrap-values.yaml platform/victoria-stack/prod/rules/r6-ci-staleness.yaml \
        platform/argocd/test_argocd_values.bats tests/gates/test_vmalert-config.bats
git commit -m "fix: ArgoCD controller metrics scrape 배선 + ArgoCDOutOfSync absent 가드 (R6 소생)"
```

---

### B2.2 digest-exporter GHCR 자격·egress 격리·APPS 시드 + drift recording-rule join 정정 (PR-2b)

**Files:** Create: `scripts/seal-ghcr-read.sh`, `platform/victoria-stack/prod/ghcr-read.sealed.yaml`(owner seal 산출), `tests/gates/test_digest-exporter.bats`. Modify: `Makefile`(seal 타겟 블록 :134 부근), `platform/victoria-stack/prod/kustomization.yaml`(:resources), `platform/victoria-stack/prod/digest-exporter.yaml`(:14,:30-31,:42,:50-51), `platform/victoria-stack/prod/networkpolicy.yaml`(:11 주석+말미), `platform/victoria-stack/prod/rules/r6-ci-staleness.yaml`(:20-28). Test: `tests/gates/test_digest-exporter.bats`(gate-collected).

**Step 1 — 실패 테스트 작성.** `tests/gates/test_digest-exporter.bats` 신규:
```bash
#!/usr/bin/env bats
# R6 ImageDigestDrift 소생: digest-exporter가 (a) private GHCR 자격으로 inspect하고, (b) recording-rule
# join이 양변 라벨(app,digest) 정렬돼 오발화하지 않으며, (c) egress가 격리되고, (d) APPS가 apps/와 parity.
# (@test 이름 영어, 중간 단언 run+[ ] — bash 3.2 함정)
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; D="$ROOT/platform/victoria-stack/prod/digest-exporter.yaml"; }

@test "digest-exporter authenticates to private GHCR via ghcr-read authfile" {
  grep -q -- '--authfile /auth/config.json' "$D"          # skopeo가 자격 사용
  grep -q 'secretName: ghcr-read' "$D"                    # observability ns dockerconfigjson 마운트
  # SealedSecret 소스 존재(owner seal 산출) + kustomization 배선
  [ -f "$ROOT/platform/victoria-stack/prod/ghcr-read.sealed.yaml" ]
  grep -q 'ghcr-read.sealed.yaml' "$ROOT/platform/victoria-stack/prod/kustomization.yaml"
}

@test "digest-exporter pod is egress-isolated (label + default-deny + ghcr/vmsingle allow)" {
  N="$ROOT/platform/victoria-stack/prod/networkpolicy.yaml"
  grep -q 'app.kubernetes.io/name: digest-exporter' "$D"   # netpol 셀렉터용 pod 라벨
  grep -q 'digest-exporter-default-deny-egress' "$N"
  grep -q 'digest-exporter-allow-egress' "$N"
}

@test "drift recording-rule aligns both join sides on (app,digest) (no permanent false fire)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  grep -q 'max by (app, digest) (ghcr_latest_digest)' "$R"   # 좌변 digest 보존
  grep -q '"app", "$1", "image"' "$R"                        # 우변 image→app 추출
  run grep -q 'max by (app) (ghcr_latest_digest)' "$R"; [ "$status" -ne 0 ]  # 파손식 회귀 금지
}

@test "digest-exporter APPS tracks exactly the deployed apps/ set (variant-chain parity)" {
  val="$(yq 'select(.kind=="CronJob").spec.jobTemplate.spec.template.spec.containers[].env[] | select(.name=="APPS").value' "$D")"
  got="$(printf '%s' "$val" | tr ' ' '\n' | sed -n 's/=.*//p' | grep -v '^$' | sort | tr '\n' ' ')"
  want="$(ls -1 "$ROOT/apps" | grep -vx 'README.md' | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || { echo "APPS names='$got' != apps/='$want'"; false; }
}
```

**Step 2 — 실행(기대 실패).**
```
bats tests/gates/test_digest-exporter.bats
```
기대: 4건 모두 `not ok`(authfile 없음·pod 라벨 없음·`max by (app)` 잔존·APPS="" 파리티 불일치).

**Step 3 — 최소 구현.**

(3a) seal 도구 — `scripts/seal-ghcr-read.sh` 신규(seal-ghcr-pull.sh 미러, ns만 observability·name만 ghcr-read):
```bash
#!/usr/bin/env bash
# GHCR read 토큰(.env.secrets GHCR_PULL_TOKEN)을 observability NS dockerconfigjson SealedSecret(ghcr-read)로
# 봉인 — digest-exporter가 private GHCR 패키지(page·trip-mate-api)를 skopeo inspect하기 위한 read 자격.
# strict-scope라 prod ghcr-pull 재사용 불가(seal-files-secrets와 동일 사유). 회전 시 재실행 → 결과를 PR로.
set -euo pipefail
: "${GHCR_PULL_TOKEN:?set GHCR_PULL_TOKEN in .env.secrets}"
user="$(gh api user --jq .login)"
out="platform/victoria-stack/prod/ghcr-read.sealed.yaml"
kubectl create secret docker-registry ghcr-read \
  --docker-server=ghcr.io --docker-username="$user" --docker-password="$GHCR_PULL_TOKEN" \
  --namespace observability --dry-run=client -o yaml \
  | kubeseal --cert tools/sealed-secrets-cert.pem --scope strict --format yaml >"$out"
echo "sealed -> $out (ghcr-read, ns observability, dockerconfigjson)"
```
`chmod +x scripts/seal-ghcr-read.sh`. `Makefile`의 seal 타겟 블록(:134 `seal-ghcr-pull` 다음)에 추가:
```makefile
.PHONY: seal-ghcr-read
seal-ghcr-read: ## GHCR read 토큰을 observability NS ghcr-read SealedSecret로 봉인(digest-exporter private inspect)
	@scripts/seal-ghcr-read.sh
```

(3b) **owner-local seal 1회**(값 stdout 금지·산출물만):
```
set -a; . .env.secrets; set +a
make seal-ghcr-read
```
→ `platform/victoria-stack/prod/ghcr-read.sealed.yaml` 생성.

(3c) kustomization 배선 — `platform/victoria-stack/prod/kustomization.yaml`의 `- digest-exporter.yaml` 바로 앞 줄에 `  - ghcr-read.sealed.yaml` 삽입.

(3d) `digest-exporter.yaml` — 3곳 편집:
- run.sh의 skopeo 라인(:14) `skopeo inspect --no-tags "docker://$REF"` → `skopeo inspect --authfile /auth/config.json --no-tags "docker://$REF"`.
- CronJob pod template(:30 `template:` 다음)에 metadata/labels 삽입:
```yaml
      template:
        metadata:
          labels: { app.kubernetes.io/name: digest-exporter } # observability egress netpol 셀렉터
        spec:
```
- APPS value(:42) `value: ""` → 배포 앱 시드(values.yaml 실측 태그):
```yaml
                  value: "page=ghcr.io/ukyi-app/page:sha-cd4815ca409992f56bf72d324d0806acb97010e2 trip-mate-api=ghcr.io/ukyi-app/trip-mate-api:sha-e072580bea97f20a71591e7bc85c129f93f5e9e9" # 공개 git SHA 이미지 태그(시크릿 아님) — gitleaks:allow
```
- 컨테이너 volumeMounts(:50)·volumes(:51)에 auth 마운트 추가:
```yaml
              volumeMounts:
                - { name: script, mountPath: /script }
                - { name: ghcr-auth, mountPath: /auth, readOnly: true }
          volumes:
            - { name: script, configMap: { name: digest-exporter-script } }
            - name: ghcr-auth
              secret:
                secretName: ghcr-read
                items: [{ key: .dockerconfigjson, path: config.json }]
```

(3e) egress netpol — `networkpolicy.yaml:11` 주석을 "digest-exporter도 ghcr.io로 나가나 … 제외" → "digest-exporter → ghcr.io(443)/vmsingle(8428) 격리(아래)"로 정정하고, 파일 말미에 추가:
```yaml
---
# === digest-exporter: ghcr.io(외부 443, skopeo inspect) + vmsingle import(내부 8428) ===
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: digest-exporter-default-deny-egress }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: digest-exporter } }
  policyTypes: [Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: digest-exporter-allow-egress }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: digest-exporter } }
  policyTypes: [Egress]
  egress:
    - to: # DNS — ghcr.io/vmsingle 해석(CoreDNS)
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
    - to: # vmsingle import(같은 ns) — ghcr_latest_digest push. ClusterIP→pod IP(kube-router DNAT후) 평가
        - podSelector: { matchLabels: { app.kubernetes.io/name: vmsingle } }
      ports: [{ protocol: TCP, port: 8428 }]
    - to: # 외부 ghcr.io(443) — 사설 대역 except로 내부 lateral 차단
        - ipBlock: { cidr: 0.0.0.0/0, except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16] }
      ports: [{ protocol: TCP, port: 443 }]
```

(3f) recording-rule 정정 — `r6-ci-staleness.yaml`의 record 블록(:20-28)을 교체(YAML block scalar라 백슬래시 리터럴 → PromQL regex는 단일 `\.`):
```yaml
          # Recording rule: 실행 중인 이미지 digest가 최신 GHCR digest와 다르면 1.
          # ⚠️ 정정(B2): (a) max by (app)은 digest 라벨을 떨궈 join 키 소실, (b) 우변(pod info)에 app 라벨
          #    부재 → on(app,digest) 매칭 영구 미스 → 채우면 drift 상시 1(오발화). 좌변은 by(app,digest)로 digest
          #    보존, 우변은 image 라벨에서 app 추출해 양변 라벨을 정렬한다(라이브 미검증 죽은 식 → 발화 검증 필수).
          - record: app:image_digest_drift
            expr: |
              max by (app, digest) (ghcr_latest_digest)
              unless on (app, digest) (
                label_replace(
                  label_replace(
                    kube_pod_container_info{namespace="prod", image=~"ghcr\.io/ukyi-app/.*"},
                    "digest", "$1", "image_id", ".*@(sha256:[a-f0-9]+)$"
                  ),
                  "app", "$1", "image", ".*/([a-z0-9-]+)[@:].*"
                )
              )
```
그리고 ImageDigestDrift(:29-35) description 말미에 bump 오발화 주의 1문장 추가: `" ⚠️ 이미지 bump 직후 digest-exporter APPS 갱신 전까지 일시 오발화 가능(B9 bump-tag 배선 후 해소)."` (`for: 20m` 유지).

**Step 4 — 게이트.**
```
bats tests/gates/test_digest-exporter.bats tests/gates/test_vmalert-config.bats
make ci
```
기대: 전부 `ok`(parity: APPS names `page trip-mate-api` == apps/ 디렉토리). `make verify`의 sops 라운드트립·skeleton 통과(신규 SealedSecret은 `*.enc.yaml` 아님 — SOPS 가드 무관).

**Step 5 — 커밋.**
```
git add scripts/seal-ghcr-read.sh Makefile platform/victoria-stack/prod/ghcr-read.sealed.yaml \
        platform/victoria-stack/prod/kustomization.yaml platform/victoria-stack/prod/digest-exporter.yaml \
        platform/victoria-stack/prod/networkpolicy.yaml platform/victoria-stack/prod/rules/r6-ci-staleness.yaml \
        tests/gates/test_digest-exporter.bats
git commit -m "fix: digest-exporter GHCR 자격·egress 격리·APPS 시드 + drift recording-rule join 정정"
```

---

### B2.3 create-app/teardown-app이 digest-exporter APPS를 함께 갱신 (PR-2b)

**Files:** Create: `tools/lib/digest-exporter.ts`, `tools/tests/test_digest-exporter-lib.bats`. Modify: `tools/create-app.ts`(:6,:10,:170-192 산출 블록), `tools/teardown-app.ts`(:6-8,:39-53 산출 블록), `tools/tests/test_create-app.bats`(setup+@test), `tools/tests/test_teardown.bats`(setup+@test). Test: 세 tools bats(gate-collected).

**Step 1 — 실패 테스트 작성.** `tools/tests/test_digest-exporter-lib.bats` 신규(lib 단위 — 멱등·정렬·fail-loud):
```bash
#!/usr/bin/env bats
# digest-exporter APPS 편집 lib(create-app/teardown-app 공용) 단위: add/remove 멱등·이름 정렬·fail-loud.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; TMP="$(mktemp -d)"
  printf '            env:\n                - name: APPS\n                  value: ""\n' > "$TMP/de.txt"; }
teardown() { rm -rf "$TMP"; }
run_lib() { bun -e "
  import { addApp, removeApp } from '$ROOT/tools/lib/digest-exporter.ts';
  import { readFileSync } from 'node:fs';
  let t = readFileSync('$TMP/de.txt','utf8');
  $1
  process.stdout.write(t);
"; }
@test "addApp inserts a name=ref token, idempotent and name-sorted" {
  run run_lib "t = addApp(t,'trip-mate-api','ghcr.io/o/trip-mate-api:sha-b'); t = addApp(t,'page','ghcr.io/o/page:sha-a'); t = addApp(t,'page','ghcr.io/o/page:sha-a');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "page=ghcr.io/o/page:sha-a trip-mate-api=ghcr.io/o/trip-mate-api:sha-b"'
}
@test "removeApp drops the token idempotently" {
  run run_lib "t = addApp(t,'page','ghcr.io/o/page:sha-a'); t = removeApp(t,'page'); t = removeApp(t,'page');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: ""'
}
@test "edit throws fail-loud when APPS value line is missing (format drift)" {
  echo 'no apps here' > "$TMP/de.txt"
  run run_lib "t = addApp(t,'page','x');"
  [ "$status" -ne 0 ]
}
```
`tools/tests/test_create-app.bats`의 setup() 말미(:26 `}` 직전)에 digest-exporter 픽스처 시드 추가:
```bash
  mkdir -p "$FR/platform/victoria-stack/prod"
  printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata: { name: digest-exporter }\nspec:\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n            - name: digest-exporter\n              env:\n                - name: APPS\n                  value: ""\n' > "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
```
그리고 신규 @test:
```bash
@test "create-app wires the app into digest-exporter APPS (R6 drift tracking)" {
  gen
  [ "$status" -eq 0 ]
  grep -q 'orders=ghcr.io/ukyi-app/orders:sha-aaa1111' "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
}
```
`tools/tests/test_teardown.bats`의 setup()에 동일 픽스처(단, APPS에 orders 선존재)를 시드하고 신규 @test:
```bash
@test "teardown-app removes the app from digest-exporter APPS" {
  # setup에서 APPS='orders=ghcr.io/ukyi-app/orders:sha-x' 시드 전제
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  run grep -q 'orders=' "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
  [ "$status" -ne 0 ]
}
```
(teardown setup에 시드: `... value: "orders=ghcr.io/ukyi-app/orders:sha-x"` 형태로.)

**Step 2 — 실행(기대 실패).**
```
bats tools/tests/test_digest-exporter-lib.bats tools/tests/test_create-app.bats tools/tests/test_teardown.bats
```
기대: lib 3건 `not ok`(모듈 없음), create/teardown 신규 @test `not ok`(도구가 파일 미갱신).

**Step 3 — 최소 구현.** `tools/lib/digest-exporter.ts` 신규:
```ts
// digest-exporter APPS(공백 구분 "name=ref" 목록) 편집 SSOT — create-app/teardown-app 공용.
// APPS는 digest-exporter.yaml CronJob env의 단일 문자열 value. R6 ImageDigestDrift가 이 목록의 각 앱
// 최신 GHCR digest를 조회하므로, 앱 생성/철거 시 목록을 함께 갱신해야 drift 감시가 정확하다(parity 게이트가 강제).
// value 라인을 정규식으로 겨냥, 매치 0이면 throw(fail-loud — 포맷 드리프트로 silent no-op 차단). 이름 정렬 결정론.
const APPS_RE = /(- name: APPS\n\s+value: ")([^"]*)(")/;
type Entry = { name: string; ref: string };

function splitApps(val: string): Entry[] {
  return val.trim().split(/\s+/).filter(Boolean).map((e) => {
    const i = e.indexOf("=");
    return { name: e.slice(0, i), ref: e.slice(i + 1) };
  });
}
function edit(text: string, fn: (a: Entry[]) => Entry[]): string {
  const m = text.match(APPS_RE);
  if (!m) throw new Error("digest-exporter APPS(value) 라인을 찾지 못함 — 포맷 드리프트로 갱신 불가");
  const next = fn(splitApps(m[2])).sort((a, b) => a.name.localeCompare(b.name))
    .map((a) => `${a.name}=${a.ref}`).join(" ");
  return text.replace(APPS_RE, `$1${next}$3`);
}
export function addApp(text: string, name: string, ref: string): string {
  return edit(text, (a) => (a.some((x) => x.name === name) ? a : [...a, { name, ref }]));
}
export function removeApp(text: string, name: string): string {
  return edit(text, (a) => a.filter((x) => x.name !== name));
}
```
`create-app.ts:10`(import 구역)에 `import { addApp } from "./lib/digest-exporter.ts";` 추가하고, `if (!DRY) { … }` 블록 안 원장 갱신(:189-191) **다음**에 삽입:
```ts
  // R6 digest 감시: digest-exporter APPS에 이 앱 추가(create-app/teardown-app이 SSOT 유지 — parity 게이트)
  const dePath = `${ROOT}/platform/victoria-stack/prod/digest-exporter.yaml`;
  if (!existsSync(dePath)) fail(`digest-exporter.yaml 부재: ${dePath} — APPS 배선 불가`);
  writeFileSync(dePath, addApp(readFileSync(dePath, "utf8"), app, `ghcr.io/${owner}/${app}:${tag}`));
```
`teardown-app.ts:8`에 `import { removeApp } from "./lib/digest-exporter.ts";` 추가하고, `if (!DRY) { … }` 블록(:39-53) 안에 삽입(멱등 — 파일 부재면 skip):
```ts
    const dePath = `${ROOT}/platform/victoria-stack/prod/digest-exporter.yaml`;
    if (existsSync(dePath)) writeFileSync(dePath, removeApp(readFileSync(dePath, "utf8"), app));
```
`plan.remove`에 존재 시 `digest-exporter APPS 항목` 문자열 push(가시성).

**Step 4 — 게이트.**
```
bats tools/tests/test_digest-exporter-lib.bats tools/tests/test_create-app.bats tools/tests/test_teardown.bats
bun run typecheck && make ci
```
기대: 전부 `ok`. typecheck(신규 lib 편입) 통과.

**Step 5 — 커밋.**
```
git add tools/lib/digest-exporter.ts tools/create-app.ts tools/teardown-app.ts \
        tools/tests/test_digest-exporter-lib.bats tools/tests/test_create-app.bats tools/tests/test_teardown.bats
git commit -m "feat: create-app/teardown-app이 digest-exporter APPS를 함께 갱신 (R6 parity)"
```

---

### B2.4 워크로드-불가용(NotReady) vmalert 룰 + files 알림 구독 (PR-2c)

**Files:** Modify: `platform/victoria-stack/prod/rules/core.yaml`(infra 그룹 말미 :180 이후), `platform/argocd/root/appset.yaml`(:48 주석·:51 templatePatch), `tests/gates/test_vmalert-config.bats`(신규 @test), `platform/argocd/root/test_render.bats`(기존 @test 확장). Test: 두 bats(gate-collected).

**Step 1 — 실패 테스트 작성.** `tests/gates/test_vmalert-config.bats` 말미에:
```bash
@test "workload-unavailable alert covers subscription-less platform components (files/adguard/homepage gap)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: WorkloadUnavailable' "$C"
  grep -q 'kube_deployment_status_condition{condition="Available", status="false"' "$C"
  # 블랙리스트(namespace!~)여야 files(files ns)·adguard(edge)·homepage(homepage) 자동 포함
  grep -qE 'kube_deployment_status_condition\{condition="Available", status="false", namespace!~' "$C"
}
```
`platform/argocd/root/test_render.bats`의 "telegram-notify subscription label …" @test 내 `has "$output" 'data-conn'; has "$output" 'cache'; …` 라인에 `has "$output" 'files'` 추가.

**Step 2 — 실행(기대 실패).**
```
bats tests/gates/test_vmalert-config.bats platform/argocd/root/test_render.bats
```
기대: 신규/확장 @test `not ok`(WorkloadUnavailable 부재·templatePatch에 files 없음).

**Step 3 — 최소 구현.** `core.yaml`의 KubeJobFailed description(:180) 다음, `- name: deadmanswitch`(:181) **앞**에 룰 추가(infra 그룹 소속, 들여쓰기 동일):
```yaml
          # 워크로드-불가용(NotReady) — Deployment Available=False. 구독 라벨 없는 플랫폼 컴포넌트
          # (files·adguard·homepage)의 1차 실패모드(재시작 없는 NotReady)는 PodCrashLooping·TargetDown·
          # ArgoCD on-health-degraded 어디에도 안 잡히던 공백(M13). Available 조건은 KSM이 Deployment에만
          # 노출하고 honor_labels로 namespace가 실제값 → 시스템 ns 블랙리스트로 전 워크로드 커버.
          # status="false"==1이 not-available(condition×status 매트릭스). files /readyz 저하(스토리지)도 여기서 페이징.
          - alert: WorkloadUnavailable
            expr: kube_deployment_status_condition{condition="Available", status="false", namespace!~"kube-system|kube-public|kube-node-lease"} == 1
            for: 10m
            labels: { severity: warning }
            annotations:
              summary: "워크로드 불가용: {{ $labels.namespace }}/{{ $labels.deployment }}"
              description: "Deployment가 10분 이상 Available=False입니다(NotReady 파드가 minAvailable 미달) — 재시작이 없어 CrashLoop/OOM 알림에 안 잡히는 실패모드입니다. files는 /readyz 스토리지 저하, 그 외는 probe/스케줄/이미지를 확인하세요."
```
`appset.yaml`의 templatePatch(:50-55) 리스트에 files 추가 + 주석 정정:
- :48 주석 `# data-conn/cache Application에만 …` → `# data-conn/cache/files Application에만 알림 라벨 — 데이터서비스 + files(NotReady 구독).`
- :51 `{{- if has (index .path.segments 1) (list "data-conn" "cache") }}` → `{{- if has (index .path.segments 1) (list "data-conn" "cache" "files") }}`

**Step 4 — 게이트.**
```
bats tests/gates/test_vmalert-config.bats platform/argocd/root/test_render.bats
make ci
```
기대: 전부 `ok`.

**Step 5 — 커밋.**
```
git add platform/victoria-stack/prod/rules/core.yaml platform/argocd/root/appset.yaml \
        tests/gates/test_vmalert-config.bats platform/argocd/root/test_render.bats
git commit -m "feat: 워크로드-불가용(NotReady) vmalert 룰 + files 알림 구독 (M13)"
```

---

### B2.5 vmalert GOMEMLIMIT 57MiB 정정 + GOMEMLIMIT≤limit×0.95 가드 (PR-2c)

**목표** limit(64Mi)보다 큰 GOMEMLIMIT(115MiB) 역전을 정정하고, 동종 재발(right-size 시 GOMEMLIMIT 미동반)을 기존 자원 가드에 검사로 편입. **B7 순서 충돌 회피**: 본 배치는 기존 셸(`check-resource-limits.sh` 내장 python)에 **최소 추가**한다. 설계 §2·B7의 python→bun 이관은 이 검사를 TS로 재구현하며 승계한다(순서: B2 Wave1 → B7 Wave2). B7 계획에 "GOMEMLIMIT 검사 이관" 항목을 명시한다(본 계획이 선행 SSOT). traps.md는 기존 "상주 워크로드 자원 limit 블라인드스팟" 행(:28, 동일 가드 파일 `check-resource-limits.sh`+`tests/test_resource_limits.bats`)이 이미 커버 — 신규 행 불요(traps-detail 갱신은 B12/M9 소관).

**Files:** Modify: `platform/victoria-stack/prod/vmalert.yaml`(:34), `scripts/check-resource-limits.sh`(python 블록 :20-54), `tests/test_resource_limits.bats`(신규 red-green @test). Test: `tests/test_resource_limits.bats`(gate-collected).

**Step 1 — 실패 테스트 작성.** `tests/test_resource_limits.bats`에 red-green 추가(현행 vmalert 115MiB에서 red):
```bash
@test "GOMEMLIMIT must not exceed 0.95x the memory limit (right-size coupling)" {
  # 실 매니페스트: vmalert 정정(57MiB) 후 통과. 이 @test가 red면 GOMEMLIMIT 드리프트가 남아있는 것.
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "resource guard flags a container whose GOMEMLIMIT exceeds 0.95x limit (red-green)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  cat > "$tmp/platform/probe/prod/deploy.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: probe, namespace: probe }
spec:
  template:
    spec:
      containers:
        - name: probe
          image: busybox
          env: [{ name: GOMEMLIMIT, value: "115MiB" }]
          resources: { requests: { cpu: 25m, memory: 16Mi }, limits: { memory: 64Mi } }
YAML
  run bash "$tmp/scripts/check-resource-limits.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'GOMEMLIMIT'
  rm -rf "$tmp"
}
```

**Step 2 — 실행(기대 실패).**
```
bats tests/test_resource_limits.bats
```
기대: 첫 @test `not ok`(vmalert 115MiB > 64×0.95=60.8), 둘째 @test `not ok`(가드에 GOMEMLIMIT 검사 부재 → probe가 통과해버림).

**Step 3 — 최소 구현.**

(3a) `vmalert.yaml:34` `- { name: GOMEMLIMIT, value: "115MiB" }` → `- { name: GOMEMLIMIT, value: "57MiB" } # 64Mi limit의 ~90%(정정: 구 128Mi 기준 115MiB 잔류 버그 — right-size 시 GOMEMLIMIT 미동반)`.

(3b) `check-resource-limits.sh` python(heredoc `PY`) 상단(:21 `import os, json` 다음)에 바이트 파서 추가:
```python
import re
def to_bytes(v):
    m = re.match(r'^\s*(\d+(?:\.\d+)?)\s*([A-Za-z]*)\s*$', str(v))
    if not m: return None
    u = {"":1,"B":1,"Ki":2**10,"Mi":2**20,"Gi":2**30,"Ti":2**40,
         "KiB":2**10,"MiB":2**20,"GiB":2**30,"TiB":2**40,
         "k":1e3,"K":1e3,"M":1e6,"G":1e9,"T":1e12}
    return float(m.group(1)) * u[m.group(2)] if m.group(2) in u else None
```
그리고 컨테이너 루프에서 `limits = res.get("limits") or {}`(:41) **다음**, `missing = []`(:42) **앞**에 삽입(정상 컨테이너에도 실행되도록 `if not missing: continue` 이전에 위치):
```python
        # GOMEMLIMIT ≤ limit×0.95 (right-size 시 GOMEMLIMIT 미동반 갱신 → GC 소프트리밋이 cgroup limit
        # 위로 올라가 OOMKill 직행. vmalert 드리프트가 이 검사로 자동 포착 — 원장이 못 보는 2차 축).
        gomem = None
        for e in c.get("env", []) or []:
            if isinstance(e, dict) and e.get("name") == "GOMEMLIMIT":
                gomem = e.get("value")
        if gomem and "memory" in limits:
            gb, lb = to_bytes(gomem), to_bytes(limits["memory"])
            if gb is not None and lb is not None and gb > lb * 0.95:
                print("%s/%s/%s [GOMEMLIMIT %s > limit×0.95 (%s)]" % (
                    o.get("kind"), name, c.get("name"), gomem, limits["memory"]))
```
(정합 확인 — 정정 후 전 워크로드: vmalert 57/64·vmagent 200/224·KSM 57/64·vlogs 115/128·vmsingle 920/1024·cloudflared 86/96 모두 ≤0.95. sealed-secrets는 charts/라 스캔 제외.)

**Step 4 — 게이트.**
```
bats tests/test_resource_limits.bats
bash scripts/check-resource-limits.sh
make ci
```
기대: `check-resource-limits OK (…스캔, … 위반 0)`, 두 @test `ok`.

**Step 5 — 커밋.**
```
git add platform/victoria-stack/prod/vmalert.yaml scripts/check-resource-limits.sh tests/test_resource_limits.bats
git commit -m "fix: vmalert GOMEMLIMIT 57MiB 정정 + GOMEMLIMIT≤limit×0.95 가드 (M7)"
```

---

### B2.6 CacheBackupStale staleness 알림 (PR-2c)

**목표** cache-backup은 실패-존재(KubeJobFailed)만 잡혀 Job 오브젝트 소실·미스케줄 시 침묵하는 fail-open. pg 4사본 패턴(absent 가드 fail-closed)을 복제. KubeJobFailed는 그대로 둔다(감사가 "수용 가능한 이중화"로 판정 — 즉시-실패 신호 유지).

**Files:** Modify: `platform/victoria-stack/prod/rules/r4-storage-backup.yaml`(:119 이후), `tests/gates/test_vmalert-config.bats`(신규 @test). Test: `tests/gates/test_vmalert-config.bats`(gate-collected).

**Step 1 — 실패 테스트 작성.** `tests/gates/test_vmalert-config.bats` 말미:
```bash
@test "cache backup has a staleness alert like the four pg backups (fail-open asymmetry fixed)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  grep -q 'alert: CacheBackupStale' "$R"
  grep -q 'job_name=~"cache-backup' "$R"
  grep -q 'absent(kube_job_status_completion_time{job_name=~"cache-backup' "$R"   # fail-closed 가드
}
```

**Step 2 — 실행(기대 실패).**
```
bats tests/gates/test_vmalert-config.bats
```
기대: 신규 @test `not ok`.

**Step 3 — 최소 구현.** `r4-storage-backup.yaml`의 PgDumpHedgeStale description(:119) **다음**에 룰 추가(storage-backup 그룹 소속, 들여쓰기 동일):
```yaml
          # 백업 생존성: 공용 캐시(Valkey) 백업 CronJob(cache-backup, 매일 03:45 KST)이 완료돼야 한다.
          # pg 4사본과 달리 KubeJobFailed(존재-시-발화)만 있어 Job 오브젝트 소실/미스케줄 시 침묵(fail-open)이던
          # 비대칭 해소 — pg staleness 패턴 복제(absent 가드 fail-closed). 캐시는 LRU 휘발 티어라 warning.
          # ⚠️ absent 설계: cache-backup CronJob은 platform/cache/prod 상주 컴포넌트라 항상 존재하고, valkey
          #    인스턴스 0개여도 discover 루프가 0회 돌고 성공 완료해 completion_time을 갱신한다(backup-cronjob.yaml)
          #    → absent()는 CronJob 자체 소멸(=cache 컴포넌트 철거) 시에만 발화. 그 경우 이 룰도 제거한다
          #    (죽은 알림 금지 규약). 신규/DR 배포 첫 실행 전(03:45 KST 이전) 일시 absent는 pg 4룰과 동일 수용.
          - alert: CacheBackupStale
            expr: |
              (time() - max(kube_job_status_completion_time{job_name=~"cache-backup.*"})) > 100000
              or absent(kube_job_status_completion_time{job_name=~"cache-backup.*"})
            for: 15m
            labels: { severity: warning }
            annotations:
              summary: "캐시 백업이 stale(27시간 초과)이거나 누락됨"
              description: "공용 Valkey 백업(cache-backup CronJob → R2)이 갱신되지 않았습니다 — Job 오브젝트 소실/CronJob suspend/미스케줄 가능. last_success.json 신선도는 teardown 시점에만 검사되므로 이 룰이 상시 backstop입니다. 캐시는 LRU 휘발 티어라 warning."
```

**Step 4 — 게이트.**
```
bats tests/gates/test_vmalert-config.bats
make ci
```
기대: 전부 `ok`.

**Step 5 — 커밋.**
```
git add platform/victoria-stack/prod/rules/r4-storage-backup.yaml tests/gates/test_vmalert-config.bats
git commit -m "feat: CacheBackupStale staleness 알림(r4, pg 패턴 복제 — fail-open 비대칭 해소)"
```

---

### 게이트·라이브 검증

**게이트(각 PR 공통, 머지 전).** `make ci`(gate 재현: skeleton + 원장 conftest + 자원가드(GOMEMLIMIT 포함) + bats 전수 + chart-test). PR-2b는 추가로 `bun run typecheck`.

**라이브(`export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`, ArgoCD 싱크 후):**

- **PR-2a (argocd scrape).** controller StatefulSet 파드가 어노테이션 변경으로 롤(재시작) — selfHeal 수렴 확인:
  ```
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=120s
  kubectl -n observability port-forward svc/vmsingle 8428:8428 >/dev/null 2>&1 &
  curl -s 'http://localhost:8428/api/v1/query?query=argocd_app_info' | jq '.data.result | length'
  ```
  기대: rollout complete, `argocd_app_info` 시리즈 **> 0**(0이면 fallback: `controller.metrics.enabled: true` 병행 후 재검증). vmalert 룰 로드:
  ```
  kubectl -n observability port-forward deploy/vmalert 8880:8880 >/dev/null 2>&1 &
  curl -s http://localhost:8880/api/v1/rules | jq '[.data.groups[].rules[].name] | map(select(.=="ArgoCDOutOfSync"))'
  ```
  기대: `["ArgoCDOutOfSync"]`. 발화 시뮬(비파괴, 관찰만): 임의 앱을 잠깐 OutOfSync로 두면 `argocd_app_info{sync_status="OutOfSync"}==1` 관측(실행 불필요 — 식만 확인).

- **PR-2b (digest 소생).** digest-exporter CronJob 수동 트리거 후 시리즈·오발화 확인:
  ```
  kubectl -n observability create job digest-exporter-verify --from=cronjob/digest-exporter
  kubectl -n observability wait --for=condition=complete job/digest-exporter-verify --timeout=120s
  curl -s 'http://localhost:8428/api/v1/query?query=ghcr_latest_digest' | jq '.data.result | length'
  curl -s 'http://localhost:8428/api/v1/query?query=app:image_digest_drift' | jq '.data.result | length'
  ```
  기대: `ghcr_latest_digest` = **2**(page·trip-mate-api, 자격 동작 확정 — 0이면 ghcr-read 자격/egress netpol 문제), `app:image_digest_drift` = **0**(정정된 join이 정상상태 오발화 없음 — >0이면 recording-rule/APPS 태그 드리프트). 검증 Job 정리: `kubectl -n observability delete job digest-exporter-verify`.

- **PR-2c.** 룰 3종 로드 확인:
  ```
  curl -s http://localhost:8880/api/v1/rules | jq '[.data.groups[].rules[].name] | map(select(.=="WorkloadUnavailable" or .=="CacheBackupStale"))'
  ```
  기대: `["WorkloadUnavailable","CacheBackupStale"]`. files 구독 라벨:
  ```
  kubectl -n argocd get application files-prod -o jsonpath='{.metadata.labels.notify\.homelab/telegram}'
  ```
  기대: `true`. WorkloadUnavailable 발화 시뮬(비파괴): `kubectl -n observability query`로 `kube_deployment_status_condition{condition="Available",status="false"}` 시리즈 존재/평가 무에러 확인(정상상태 = 0 매치).

포트포워드 정리: `pkill -f 'port-forward'`.

### 롤백 노트

- **PR-2a:** controller podAnnotations 되돌리면 다음 reconcile에 controller 재롤(무데이터 손실). ArgoCDOutOfSync absent 가드 제거는 룰 파일 revert만(configCheckInterval 30s로 자동 reload).
- **PR-2b:** 가장 리스크 큰 PR. digest-exporter APPS를 `""`로 되돌리면 즉시 무해화(0 시리즈, 알림 정지). netpol/자격 revert는 순수 additive라 제거해도 기존 기능 무영향. recording-rule은 정정 전 파손식으로 되돌리지 말 것(파손식 = 상시 오발화). `ghcr-read` SealedSecret은 잔존해도 무해(미참조 Secret).
- **PR-2c:** 전 항목 룰/라벨 additive — 파일 revert로 즉시 복구. GOMEMLIMIT 57MiB는 라이브 peak 37.5Mi 대비 충분(롤백 사유 없음). check-resource-limits GOMEMLIMIT 검사는 셸 revert만(B7 이관 전이라 단일 파일).

### 다음 배치 진행 조건

1. 3 PR 전부 `gate` 통과 + 위 라이브 검증 통과(특히 PR-2b: `argocd_app_info>0` **AND** `ghcr_latest_digest=2` **AND** `app:image_digest_drift=0`). 하나라도 미충족 시 B3 진행 보류.
2. 정정된 R6 룰이 라이브 TSDB에서 실입력으로 평가됨을 확인(감사가 지적한 "죽은 알림 착시" 해소 확정).
3. **B9 인수인계 항목 기록**: bump-tag 인라인 핀 편집 모드는 digest-exporter APPS 태그도 동반 갱신해야 ImageDigestDrift bump 오발화가 해소됨(경성 의존). **B7 인수인계**: `check-resource-limits.sh`의 GOMEMLIMIT≤limit×0.95 검사를 python→bun 이관 시 TS로 재구현·승계.
4. owner 결정 확인: ImageDigestDrift 유지비(ghcr-read 봉인 + bump 커플링) 수용 vs 설계 §1.1 옵션 ③ 축소 — 본 계획은 완전 구현을 전제하나, owner가 ③을 택하면 B2.2·B2.3을 "R6 digest 절반 제거 + 런북 문구 갱신"으로 대체(ArgoCDOutOfSync/PR-2a는 무관하게 유지).
## B3. 가드 소생 — posture vacuous · bats 부정단언 · KSOPS harness (Wave 1)

> ⚠️ **설계 보정** (실파일 실측이 설계 스냅샷과 어긋난 지점 — 실파일 우선):
> 1. **bats 중간 `! cmd` 부정단언은 6곳이 아니라 8곳이다.** 설계·감사(§1.2 M4)는 6곳(`test_seal-secret.bats:76,168`·`test_provision-db.bats:136`·`test_alertmanager-template.bats:63`·`test_run-bats.bats:11`·`test_dns-drift-check.bats:14`)을 주장하나, 블록-인지 탐지기로 전수 스캔한 결과 **`platform/cnpg/prod/test_pooler.bats:10`**(예약 파라미터 `pool_mode:` 재발 가드 — 문서화된 CNPG Pooler 함정!)와 **`tools/tests/test_update-secrets.bats:111`**(update-secrets가 `.app-config.yml`을 안 당겨오는지)가 감사 누락분이다. 계획은 8곳 전수를 고친다.
> 2. **posture jq/부정단언은 `[ ]`(단일 대괄호)로 두면 안전하나 `[[ ]]`·`! `는 라이브 확증상 중간 위치에서 침묵 통과한다.** 실험(bats 1.13, 이 환경): `[ 1 -eq 2 ]; [ 1 -eq 1 ]`→**FAIL**(정상), 그러나 `[[ 1 == 2 ]]; …`→**PASS**(침묵), `! true; …`→**PASS**(침묵). 즉 `! `는 모든 bash에서, `[[ ]]`는 bash 3.2 변종으로 죽는다. 중간 `[[ ]]`는 레포 전체 **65곳**(다줄 @test 기준) — B3에서 전부 전환하는 것은 B13(`구본 bats [[ ]] 정비`)와 중복이고 저영향 원칙에 반한다. 따라서 lint는 **중간 `! `는 hard-zero 강제**, **중간 `[[ ]]`는 baseline(65) ratchet**(신규 증가만 차단)으로 설계하고 baseline 소진은 B13에 위임한다.
> 3. **KSOPS 그룹 `.ci-exclude` 주석은 실행처를 명시하지 않으며, `platform/cache/prod/test_ksops_render.bats:3`은 "로컬 `make ci`가 실행"이라 **허위 주장**한다**(run-bats.sh가 .ci-exclude를 제외하므로 `make ci`는 이들을 절대 안 돌린다). 이 둘을 `make verify-ksops`로 정정한다.

**목표** internal-by-default의 유일 자동검증인 posture '공개 HTTPRoute 금지' 가드의 vacuous jq를 교정(+argocd-webhook `/api/webhook` allowlist)하고, bats 중간 부정단언 8곳을 `run …; [ "$status" -ne 0 ]`로 소생시킨 뒤 재발을 막는 스타일 lint를 신설하며, 어느 harness에도 안 묶인 KSOPS bats 4종을 `make verify-ksops`로 배선한다. 전부 죽어 있던 가드를 되살리는 순수 테스트/게이트 작업 — 라이브 워크로드 무변경(posture는 라이브 read-only 검증).

**선행 조건** 없음(Wave 1 독립 배치). 단 lint의 BB baseline(65)은 **설계 스냅샷 트리 기준 실측값**이므로, 같은 Wave의 B1/B2/B4/B5가 먼저 머지돼 bats가 늘면 baseline이 변한다 → **구현 시점에 `scripts/check-bats-style.sh`를 한 번 돌려 방출된 BB 수를 재확인·핀한다**(B3.3 Step 3).

**PR 구성** (직렬 머지 — 스택 PR squash 함정 회피):
- **PR-3a** "test: posture 공개 HTTPRoute 가드 vacuous jq 교정 + argocd-webhook allowlist" — B3.1
- **PR-3b** "test: bats 중간 부정단언 8곳 소생 + 스타일 lint 신설" — B3.2(commit 1) + B3.3(commit 2, 순서 필수)
- **PR-3c** "chore: make verify-ksops 신설 + KSOPS bats 4종 배선·실행처 주석 정정" — B3.4

---

### B3.1 posture '공개 HTTPRoute 금지' 가드 vacuous jq 교정 (PR-3a)

**Files:** Modify: `tests/posture/test_internal-by-default.bats:19-27`(ArgoCD/Grafana 두 테스트). Test: posture는 라이브 전용(`.ci-exclude` → `make verify-posture`) — 오프라인 fixture로 vacuity/수정을 증명하고 라이브로 최종 검증.

**근거(실측):** `platform/argocd/extras/httproute-webhook.yaml`은 `sectionName: web-public`에 `argocd-server` 백엔드를 **정당하게** 붙인다(단, `rules[].matches[].path = /api/webhook` 한정). 현재 테스트 jq는 `.spec.backendRefs[]?.name`을 조회하는데 HTTPRoute의 backendRefs는 **`.spec.rules[].backendRefs`**에 있다 — 존재하지 않는 경로라 항상 empty → `grep -c '^argocd'`=0 → **위반이 있어도 무조건 통과**(라이브 fixture로 CONFIRMED). 경로만 고치면 webhook 라우트가 오탐으로 걸리므로 `/api/webhook` allowlist가 동반돼야 한다.

**Step 1 — 현재 vacuity 실증(실패해야 할 테스트가 통과함을 증명).** 스크래치 fixture로 위반(argocd-server가 web-public path `/`에)을 만들어 **구 jq**에 통과시킨다:
```bash
cat > /tmp/routes.json <<'JSON'
{"items":[{"metadata":{"name":"evil"},"spec":{"parentRefs":[{"sectionName":"web-public"}],
 "rules":[{"matches":[{"path":{"value":"/"}}],"backendRefs":[{"name":"argocd-server"}]}]}}]}
JSON
jq -r '.items[] | select(.spec.parentRefs[].sectionName=="web-public") | .spec.backendRefs[]?.name' /tmp/routes.json | grep -c '^argocd' || true
```
기대: **`0`** — 명백한 위반인데도 0(가드 사문). 이것이 고쳐야 할 상태다.

**Step 2 — 최소 구현.** `tests/posture/test_internal-by-default.bats`의 두 테스트(현재 19-22, 24-27)를 아래로 교체한다. jq는 단일 인용(escape 불요)이며 `[ ]`만 사용(BB 미증가):

`"ArgoCD server has no public HTTPRoute"`(19-22) → 제목·본문 교체:
```bash
@test "ArgoCD server is public only via the /api/webhook allowlist" {
  # HTTPRoute backendRefs는 .spec.rules[].backendRefs에 있다(.spec.backendRefs는 부재 — 옛 vacuous 버그).
  # web-public 리스너의 argocd-* 백엔드는 오직 argocd-webhook 라우트의 /api/webhook prefix만 허용한다.
  # matches 생략 시 Gateway API 기본값은 PathPrefix '/'(전면 노출)이므로 위반으로 센다.
  run kubectl get httproute -A -o json
  [ "$status" -eq 0 ]
  count="$(jq '[
      .items[]
      | select(any(.spec.parentRefs[]?; .sectionName=="web-public"))
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("argocd")))
      | (if (.matches // [] | length)==0 then ["/"] else (.matches | map(.path.value // "/")) end) as $paths
      | select(any($paths[]; . != "/api/webhook"))
    ] | length' <<<"$output")"
  [ "$count" = "0" ]   # /api/webhook 이외 경로로 argocd를 web-public에 노출하는 rule 0
}
```

`"Grafana has no public HTTPRoute"`(24-27) → 동일 jq 경로 교정(grafana는 web-internal-tls라 allowlist 불요 — 어떤 web-public rule에도 grafana 백엔드가 있으면 실패):
```bash
@test "Grafana has no public HTTPRoute" {
  run kubectl get httproute -A -o json
  [ "$status" -eq 0 ]
  count="$(jq '[
      .items[]
      | select(any(.spec.parentRefs[]?; .sectionName=="web-public"))
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("grafana")))
    ] | length' <<<"$output")"
  [ "$count" = "0" ]   # grafana 백엔드는 web-public 리스너에 절대 없어야 한다(내부 전용)
}
```

**Step 3 — 수정 jq 오프라인 증명.** (a) 위반 fixture → non-zero, (b) 실제 baseline(webhook narrow) → 0:
```bash
JQ='[ .items[] | select(any(.spec.parentRefs[]?; .sectionName=="web-public")) | .spec.rules[]? | select(any(.backendRefs[]?; (.name // "") | startswith("argocd"))) | (if (.matches // [] | length)==0 then ["/"] else (.matches | map(.path.value // "/")) end) as $paths | select(any($paths[]; . != "/api/webhook")) ] | length'
jq "$JQ" /tmp/routes.json                                   # 기대: 1 (위반 포착)
printf '{"items":[{"spec":{"parentRefs":[{"sectionName":"web-public"}],"rules":[{"matches":[{"path":{"value":"/api/webhook"}}],"backendRefs":[{"name":"argocd-server"}]}]}}]}' | jq "$JQ"   # 기대: 0 (webhook allowlist 통과)
```

**Step 4 — 라이브 게이트.**
```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
make verify-posture      # 기대: test_internal-by-default.bats 전 케이스 ok (ArgoCD/Grafana 포함)
```
(KUBECONFIG 없으면 `make verify-posture`가 skip 안내 — 그 경우 owner가 라이브에서 별도 실행. 오프라인 Step 3가 jq 정확성을 이미 증명.)

**Step 5 — 게이트 재현·커밋.** posture는 `.ci-exclude`라 gate 미수집이지만 accounting/naming/skeleton은 통과해야 한다:
```bash
make verify && ./scripts/run-bats.sh >/dev/null   # 기대: 전부 green (BB/NEG 미증가 — [ ]만 사용)
git add tests/posture/test_internal-by-default.bats
git commit -m "test: posture 공개 HTTPRoute 가드 vacuous jq 교정(.spec.rules[].backendRefs) + argocd-webhook /api/webhook allowlist"
```

---

### B3.2 bats 중간 부정단언 8곳 소생 + 오해 주석 정정 (PR-3b, commit 1)

**Files:** Modify: `platform/cnpg/prod/test_pooler.bats:10`, `tests/gates/test_alertmanager-template.bats:62-64`, `tests/gates/test_run-bats.bats:5-13`, `tools/tests/test_dns-drift-check.bats:14-15`, `tools/tests/test_update-secrets.bats:107-113`, `tools/tests/test_provision-db.bats:133-139`, `tools/tests/test_seal-secret.bats:76-77·162-169`, `tests/gates/test_telegram-notify.bats`(주석 5곳). Test: 각 파일 자체가 테스트 — gate/`make ci`가 회귀 검증.

**공통 재작성 패턴:** 중간 `! <cmd>` → `run <cmd>; [ "$status" -ne 0 ]`. 캡처 변수를 grep할 땐 `run grep … <<<"$VAR"`(here-string은 `run`이 재할당하기 전의 값으로 확장 — clobber 안전), `$output`을 이후 재사용하면 로컬 변수로 보존한다. `bash -c` 대신 here-string을 쓰는 이유: `$MSG` 등 큰따옴표 포함 값에서 `bash -c` 보간이 구문을 깨뜨린다(alertmanager 주석이 이미 경고).

**Step 1 — 실패 실증(선택, 대표 1곳).** `test_pooler.bats`의 pool_mode 가드가 죽어 있음을 증명 — parameters에 `pool_mode:`를 넣어도 통과함을 보인다:
```bash
sed 's/poolMode: transaction/poolMode: transaction\n      pool_mode: session/' platform/cnpg/prod/pooler.yaml > /tmp/pooler.yaml
f=/tmp/pooler.yaml bats <(printf '#!/usr/bin/env bats\n@test t {\n  ! grep -q "pool_mode:" "%s"\n  grep -q "max_client_conn:" "%s"\n}\n' /tmp/pooler.yaml /tmp/pooler.yaml)
# 기대: ok (금지 문자열이 있는데도 중간 `! grep`이 침묵 통과 → 버그 재현)
```

**Step 2 — 최소 구현(파일별 정밀 편집).**

`platform/cnpg/prod/test_pooler.bats` — 10행 `! grep -q 'pool_mode:' "$f"`를 교체:
```bash
  # 중간 위치라 `! grep`은 bats가 침묵 통과 → run+status로 강제(check-bats-style.sh).
  run grep -q 'pool_mode:' "$f"
  [ "$status" -ne 0 ]
```

`tests/gates/test_alertmanager-template.bats` — 62-64행(주석+2 부정)을 교체:
```bash
  # 중간 negate는 bats가 침묵 통과 → run+status로 강제(check-bats-style.sh). MSG는 큰따옴표를
  # 포함하므로 bash -c 보간 대신 here-string(<<<)으로 원문 그대로 grep에 전달한다.
  run grep -q 'reReplaceAll' <<<"$MSG"
  [ "$status" -ne 0 ]
  run grep -qE '\|[[:space:]]*safeHtml|safeHtml[[:space:]]+\.' <<<"$MSG"
  [ "$status" -ne 0 ]
```

`tests/gates/test_run-bats.bats` — 첫 테스트 본문(6-12행)을 교체($output이 두 부정 사이에서 재사용되므로 `list`에 보존):
```bash
  run bash "$ROOT/scripts/run-bats.sh" --list
  [ "$status" -eq 0 ]
  list="$output"   # run 재호출이 $output을 덮으므로 로컬에 보존
  # 포함: 일반 게이트 테스트
  echo "$list" | grep -q 'platform/argocd/root/test_render.bats'
  # 제외: .ci-exclude 멤버 (중간 negate는 침묵 통과 → run+status로 강제)
  run grep -q 'tests/posture/test_internal-by-default.bats' <<<"$list"
  [ "$status" -ne 0 ]
  run grep -q 'tools/tests/test_dev-postgres.bats' <<<"$list"
  [ "$status" -ne 0 ]
```

`tools/tests/test_dns-drift-check.bats` — 14-15행 교체(`$out`은 일반 변수라 보존됨):
```bash
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh). $out은 일반 변수라 보존.
  run grep -q 'draft.ukyi.app' <<<"$out"
  [ "$status" -ne 0 ]
  run grep -q 'old.ukyi.app' <<<"$out"
  [ "$status" -ne 0 ]
```

`tools/tests/test_update-secrets.bats` — 마지막 테스트 본문(108-112행) 교체($output이 이후 `deploy` grep에 재사용 → `block` 보존):
```bash
  run grep -A8 'path: .apprepo' "$ROOT/.github/workflows/_update-secrets.yaml"

  [ "$status" -eq 0 ]
  block="$output"   # run 재호출이 $output을 덮으므로 보존
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh)
  run grep -q ".app-config.yml" <<<"$block"
  [ "$status" -ne 0 ]
  echo "$block" | grep -q "deploy"
```

`tools/tests/test_provision-db.bats` — `"never prints raw connection URLs"` 본문(135-138행) 교체:
```bash
  [ "$status" -eq 0 ]
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh)
  run grep -qiE "postgres://|password=" <<<"$output"
  [ "$status" -ne 0 ]
  # 산출 파일 어디에도 평문 Secret 없음 (스텁이 stringData를 그대로 출력하지 않음을 포함 검증)
  run grep -rqE "postgres://|stringData" "$FIX/platform"
  [ "$status" -ne 0 ]
```

`tools/tests/test_seal-secret.bats` — 76-77행 교체($seal_output 보존 변수):
```bash
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh). $seal_output 보존됨.
  run grep -q "hello" <<<"$seal_output"
  [ "$status" -ne 0 ]
  run grep -q "topsecret" <<<"$seal_output"
  [ "$status" -ne 0 ]
```
그리고 162-169행(마지막 봉인 테스트 꼬리) 교체($output이 파일 grep 뒤 재사용 → `seal_output` 보존):
```bash
  [ "$status" -eq 0 ]
  seal_output="$output"   # run 재호출이 $output을 덮으므로 보존
  grep -q "kind: SealedSecret" "$TMP/demo-secrets.sealed.yaml"
  # 평문 값이 산출/출력 어디에도 없다 (중간 negate는 침묵 통과 → run+status로 강제)
  run grep -rq "sealme" "$TMP/demo-secrets.sealed.yaml"
  [ "$status" -ne 0 ]
  run grep -q "sealme" <<<"$seal_output"
  [ "$status" -ne 0 ]
```

`tests/gates/test_telegram-notify.bats` — **오해 주석만 정정**(62·69·78·98·106행의 부정단언은 각 @test의 **마지막 명령**이라 유효하므로 그대로 두되, 근거를 오도하는 `set-e safe negate` 문구를 교체). 리터럴 문자열 `set-e safe negate`를 전 파일 치환:
- old: `set-e safe negate`
- new: `마지막 명령이라 유효 — 중간이면 침묵 통과(check-bats-style.sh 강제)`

**Step 3 — 게이트 실행.**
```bash
./scripts/run-bats.sh                 # 기대: 전 gate bats green (pooler/alertmanager/run-bats/… 소생 확인)
bats tools/tests/test_provision-db.bats tools/tests/test_seal-secret.bats tools/tests/test_update-secrets.bats tools/tests/test_dns-drift-check.bats   # 기대: green
```
검증 포인트: Step 1의 pool_mode 재현 fixture를 이제 새 패턴에 통과시키면 **not ok**가 나와야 한다(가드 소생 증명).

**Step 4 — 커밋.**
```bash
git add platform/cnpg/prod/test_pooler.bats tests/gates/test_alertmanager-template.bats \
  tests/gates/test_run-bats.bats tools/tests/test_dns-drift-check.bats tools/tests/test_update-secrets.bats \
  tools/tests/test_provision-db.bats tools/tests/test_seal-secret.bats tests/gates/test_telegram-notify.bats
git commit -m "test: bats 중간 부정단언 8곳 run+status 재작성(침묵 통과 해소) + set-e-safe 오해 주석 정정"
```

---

### B3.3 bats 단언-스타일 lint 신설 (PR-3b, commit 2 — B3.2 뒤에 와야 gate green)

**Files:** Create: `scripts/check-bats-style.sh`, `tests/gates/test_bats-style.bats`. Test: `tests/gates/test_bats-style.bats`(자기 자신 + fixture). 선례: `tests/gates/test_bats-naming.bats`(가드 스크립트 실행 + 위반 fixture).

**설계:** 블록-인지 awk 탐지기가 다줄 @test 본문에서 '마지막 명령이 아닌' 중간 `! `(NEG)·중간 `[[ `(BB)를 잡는다(pending 방식 — 후보 뒤에 명령이 또 오면 중간 확정, `}`에서 폐기=마지막 면제, heredoc 본문 스킵). **NEG=hard-zero**(모든 bash에서 죽음), **BB=baseline(65) ratchet**(bash3.2 변종 — 잔량은 B13). 인자로 파일을 주면 그 파일만 스캔하고 NEG·BB 아무거나 있으면 실패(fixture 탐지 모드). 라이브·age 무관(git+awk) → gate 자동수집. shellcheck 클린 검증 완료.

**Step 1 — 실패 테스트 작성.** `tests/gates/test_bats-style.bats`:
```bash
#!/usr/bin/env bats
# bats 단언-스타일 가드의 gate 테스트 — 탐지기가 스스로 vacuous하지 않음을 fixture로 증명(선례: test_bats-naming.bats).
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과 — 이 파일이 막으려는 바로 그 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "check-bats-style passes on the current tree (no middle negations, [[ ]] within baseline)" {
  run bash "$ROOT/scripts/check-bats-style.sh"
  [ "$status" -eq 0 ]   # B3.2가 NEG를 0으로 만든 뒤 통과
}

@test "detector catches a MIDDLE negation and a MIDDLE [[ ]] (not vacuous)" {
  cat > "$BATS_TEST_TMPDIR/test_bad.bats" <<'EOF'
@test "bad middle assertions" {
  run echo hi
  ! echo "$output" | grep -q zzz
  [[ "$output" == *hi* ]]
  [ "$status" -eq 0 ]
}
EOF
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_bad.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[NEG\]'
  echo "$output" | grep -q '\[BB\]'
}

@test "detector allows a LAST-command negation (valid bats idiom)" {
  cat > "$BATS_TEST_TMPDIR/test_good.bats" <<'EOF'
@test "good last-line negation" {
  run echo hi
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q zzz
}
EOF
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_good.bats"
  [ "$status" -eq 0 ]
}
```
실행(스크립트 부재 → 실패):
```bash
bats tests/gates/test_bats-style.bats   # 기대: 'check-bats-style.sh: No such file' 3케이스 실패
```

**Step 2 — 최소 구현.** `scripts/check-bats-style.sh` 생성(검증 완료된 전문 — shellcheck CLEAN):
```bash
#!/usr/bin/env bash
# bats 단언-스타일 가드 — @test 본문에서 '마지막 명령이 아닌'(중간) 부정(`! `)·조건(`[[ `)을 잡는다.
# bats는 negated/[[ 명령의 실패를 errexit/ERR-trap 면제로 침묵 통과시킨다(라이브 확증: bats 1.13에서
# 중간 `! echo x|grep -q x`가 'ok'). 그런 중간 단언은 죽은(false-green) 가드다.
#   NEG(중간 `! `)  = 모든 bash에서 발생(negated pipeline은 set -e 면제) → hard-zero.
#   BB (중간 `[[ `) = bash 3.2 함정 변종. 현재 재고(BB_BASELINE)는 B13이 정비 → 0 수렴. 그때까지 ratchet.
# 휴리스틱: 다줄 @test 규약 가정("@test … {" 한 줄 시작, 0열 "}" 종료). heredoc 본문은 명령으로 안 센다.
# (레포 단일 한줄 @test는 단일 명령이라 무해 — 신규 한줄 본문은 다줄로 작성할 것.)
# 인자로 파일을 주면 그 파일만 스캔하고 NEG·BB 아무거나 있으면 실패(픽스처/ad-hoc 탐지 모드).
# bash 3.2 호환: mapfile 금지(while read). shellcheck 클린.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BB_BASELINE="${BB_BASELINE_OVERRIDE:-65}"   # 현재 트리 중간 [[ ]] 수(B13 정비 대상). 신규 증가 차단.
FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.bats')
fi
[ "${#FILES[@]}" -gt 0 ] || { echo "check-bats-style: 대상 bats 없음"; exit 0; }
DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
function flush(){ if(pend!=""){ print pend; pend="" } }
FNR==1 { intest=0; pend=""; inhere=0; delim="" }
{
  line=$0
  if (inhere){ if(line ~ ("^[ \t]*"delim"[ \t]*$")) inhere=0; next }
  if (match(line, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
    d=substr(line,RSTART,RLENGTH); gsub(/.*<<-?[ \t]*['"]?/,"",d); delim=d; inhere=1; next
  }
  if (line ~ /^@test .*\{[ \t]*$/){ intest=1; pend=""; next }
  if (!intest) next
  if (line ~ /^\}[ \t]*$/){ intest=0; pend=""; next }
  t=line; sub(/^[ \t]+/,"",t)
  if (t=="" || t ~ /^#/) next
  flush()
  if (t ~ /^![ \t]/)    pend=FILENAME":"FNR": [NEG] "t
  else if (t ~ /^\[\[/) pend=FILENAME":"FNR": [BB] "t
}
AWK
findings="$(awk "$DETECT" "${FILES[@]}" || true)"
neg="$(printf '%s\n' "$findings" | grep -c '\[NEG\]' || true)"; neg="${neg//[^0-9]/}"; neg="${neg:-0}"
bb="$(printf '%s\n' "$findings" | grep -c '\[BB\]' || true)"; bb="${bb//[^0-9]/}"; bb="${bb:-0}"
printf '%s\n' "$findings" | grep -E '\[(NEG|BB)\]' || true   # gate bats가 [NEG]/[BB] 검증
rc=0
if [ "$neg" -gt 0 ]; then
  echo "FAIL: 마지막 명령이 아닌 부정 단언 ${neg}곳 — bats가 침묵 통과. 'run …; [ \"\$status\" -ne 0 ]'로 재작성." >&2; rc=1
fi
if [ "$#" -gt 0 ]; then
  [ "$bb" -eq 0 ] || { echo "FAIL: (명시 파일) 중간 [[ ]] ${bb}곳 탐지." >&2; rc=1; }
else
  echo "check-bats-style: 중간 [[ ]] ${bb} (baseline ${BB_BASELINE} — B13 정비 대상)"
  [ "$bb" -le "$BB_BASELINE" ] || { echo "FAIL: 중간 [[ ]]가 baseline(${BB_BASELINE}) 초과(${bb}) — 신규는 'run …; [ … ]'로." >&2; rc=1; }
fi
[ "$rc" -eq 0 ] && echo "check-bats-style: 중간 부정 0곳 + [[ ]] ratchet OK"
exit "$rc"
```
`chmod +x scripts/check-bats-style.sh`.

**Step 3 — baseline 재확인·핀.** 다른 Wave-1 배치가 먼저 머지됐을 수 있으므로 실측 BB를 다시 잰다:
```bash
BB_BASELINE_OVERRIDE=0 scripts/check-bats-style.sh 2>/dev/null | sed -n 's/.*중간 \[\[ \]\] \([0-9]*\).*/\1/p'
# 방출된 수가 65가 아니면 스크립트의 BB_BASELINE=65를 그 수로 교체(설계 스냅샷 기준 65).
```
그리고 NEG가 0인지(=B3.2 완료 확인):
```bash
scripts/check-bats-style.sh; echo "rc=$?"   # 기대: 'OK' + rc=0 (NEG 0, BB<=baseline)
```

**Step 4 — 게이트 실행.**
```bash
bats tests/gates/test_bats-style.bats     # 기대: 3케이스 ok
bash scripts/check-bats-accounting.sh     # 기대: 신규 test_bats-style.bats가 gate 도메인에 정확히 1회 배정
shellcheck scripts/check-bats-style.sh    # 기대: 무경고
./scripts/run-bats.sh                     # 기대: 신규 lint 포함 전 gate green
```

**Step 5 — 커밋.**
```bash
git add scripts/check-bats-style.sh tests/gates/test_bats-style.bats
git commit -m "test: bats 단언-스타일 lint 신설(중간 !/[[ 탐지, NEG hard-zero·[[ ]] ratchet)"
```

---

### B3.4 make verify-ksops 신설 + KSOPS bats 4종 배선 (PR-3c)

**Files:** Modify: `Makefile:120-124`(verify-posture 뒤에 verify-ksops 추가), `tests/.ci-exclude:16`(KSOPS 그룹 주석), `platform/cache/prod/test_ksops_render.bats:3`(허위 실행처 주석). Test: `tests/test_makefile.bats`(make verify-ksops -n 위임 확인 — 신규 케이스). Modify(선택): `AGENTS.md`(핵심 명령에 verify-ksops).

**근거(실측):** `tests/.ci-exclude:16-20`의 KSOPS 그룹(`platform/cnpg/prod/test_creds_reference.bats`·`test_drill_alerting.bats`·`test_kustomize_build.bats`·`platform/cache/prod/test_ksops_render.bats`)은 어느 Makefile 타겟·워크플로에도 안 묶여 있고(레포 grep 0), `test_ksops_render.bats:3`은 "로컬 `make ci`가 실행"이라 **허위 주장**한다. verify-posture(`Makefile:120-124`) 패턴으로 age 키 존재 시 실행/부재 시 skip하는 `make verify-ksops`를 신설한다. 이 bats들은 `sops --decrypt`/KSOPS(`kustomize --enable-exec`)가 `SOPS_AGE_KEY_FILE`을 요구하며 cnpg 3종은 레포 루트 상대경로라 루트에서 실행돼야 한다(Makefile cwd=루트).

**Step 1 — 실패 테스트 작성.** `tests/test_makefile.bats`에 케이스 추가(이 파일은 `.ci-exclude`=age 의존이지만 `-n` dry-run은 age 불요이므로 로컬 검증 가능):
```bash
@test "make verify-ksops wires the four KSOPS bats and gates on the age key" {
  run make -n verify-ksops
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'test_ksops_render.bats'
  echo "$output" | grep -q 'test_kustomize_build.bats'
  echo "$output" | grep -q 'SOPS_AGE_KEY_FILE'
}
```
실행(타겟 부재 → 실패):
```bash
bats tests/test_makefile.bats   # 기대: 'No rule to make target verify-ksops' 신규 케이스 실패
```

**Step 2 — 최소 구현.** `Makefile`의 verify-posture 블록(124행) 직후에 추가:
```makefile
.PHONY: verify-ksops
verify-ksops: ## [local] KSOPS 렌더 bats(cnpg×3·cache×1) — 실 age 키 있으면 실행/없으면 skip(.ci-exclude 그룹)
	@if [ -f "$(SOPS_AGE_KEY_FILE)" ]; then \
	  SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) bats \
	    platform/cnpg/prod/test_creds_reference.bats \
	    platform/cnpg/prod/test_drill_alerting.bats \
	    platform/cnpg/prod/test_kustomize_build.bats \
	    platform/cache/prod/test_ksops_render.bats; \
	else echo "verify-ksops: $(SOPS_AGE_KEY_FILE) 없음 — 실 age 키 필요(skip). SOPS_AGE_KEY_FILE 지정 후 재실행"; fi
```
그리고 `.PHONY: verify-posture` 선언 근처에 `verify-ksops`가 이미 위 블록에서 `.PHONY`로 선언됨(중복 불요).

`tests/.ci-exclude:16` KSOPS 그룹 주석 교체:
- old: `# KSOPS 실 age 시드 복호 의존`
- new: `# KSOPS 실 age 시드 복호 의존 — 실행처: owner-local 'make verify-ksops'(age 키 있으면 실행/없으면 skip)`

`platform/cache/prod/test_ksops_render.bats:3` 허위 실행처 교체:
- old: `# 그래서 .ci-exclude(gate엔 age 키 없음) — 로컬 `make ci`/owner가 실행(cnpg test_kustomize_build.bats 선례).`
- new: `# 그래서 .ci-exclude(gate엔 age 키 없음) — owner-local `make verify-ksops`가 실행(age 키 있으면; cnpg KSOPS bats 선례).`

**Step 3 — 게이트 실행.**
```bash
make -n verify-ksops                       # 기대: 4 bats 경로 + SOPS_AGE_KEY_FILE 노출
bats tests/test_makefile.bats              # 기대: 신규 verify-ksops 케이스 ok (age 무관 dry-run)
make help | grep verify-ksops              # 기대: 정렬 목록에 verify-ksops 등장(test_make-help sort 불변)
bash scripts/check-bats-accounting.sh      # 기대: KSOPS 4종 여전히 .ci-exclude 단일 도메인 OK
```

**Step 4 — 라이브 검증(owner-local, age 키 보유 시).**
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
make verify-ksops    # 기대: cnpg KSOPS 렌더(Cluster/ObjectStore/Pooler/ScheduledBackup) + cache 렌더 전 케이스 ok
```

**Step 5 — 커밋.**
```bash
git add Makefile tests/.ci-exclude platform/cache/prod/test_ksops_render.bats tests/test_makefile.bats
git commit -m "chore: make verify-ksops 신설 + KSOPS bats 4종 배선·실행처 주석 정정"
```

**선택(스트레치, 별도 커밋 가능):** `.ci-exclude:3`은 "각 그룹 주석이 실행처를 명시(accounting 가드가 강제)"라 하지만 `check-bats-accounting.sh`는 주석 내용을 검사하지 않는다(M8 지적). 여력 시 `check-bats-accounting.sh`에 '각 `.ci-exclude` 그룹 헤더 주석에 실행처 토큰(`make `/`manual`/`iac.yaml`/`verify-`) 존재' 정적 검사를 추가하고 `tools/tests/test_bats-accounting.bats`에 케이스 1개를 얹으면 허위 실행처 재발을 봉쇄한다. 미채택 시 최소한 `.ci-exclude:3`의 "가드가 강제" 문구를 실태에 맞게 완화한다.

---

### 게이트·라이브 검증

**게이트(각 PR 필수 — `make ci`가 gate 재현):**
```bash
make ci   # m6-tools·chart-test·typecheck·verify:ledger·audit-orphans·check-skeleton·run-bats·shellcheck·sops-guard
```
- PR-3a: posture 파일만 변경(`.ci-exclude`라 run-bats 미수집) → skeleton/accounting/naming green, run-bats 집합 불변.
- PR-3b: `./scripts/run-bats.sh`에 신규 `test_bats-style.bats` 편입 + 소생된 8곳 회귀 검증. `scripts/check-bats-style.sh` → `NEG 0 / BB ≤ baseline` OK. `shellcheck scripts/check-bats-style.sh` 무경고.
- PR-3c: `make -n verify-ksops` 위임 확인, `check-bats-accounting` KSOPS 단일도메인 유지, `make help` 정렬 불변.

**라이브(`export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig` 전제):**
```bash
make verify-posture   # PR-3a: internal-by-default(ArgoCD /api/webhook allowlist·Grafana) + netpol + e2e 전 케이스 ok
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
make verify-ksops     # PR-3c: cnpg 풀 KSOPS 렌더(DR 경로) + cache 렌더 ok
```
기대: 두 스위트 모두 실패 케이스 0. posture는 라이브 워크로드 변경 없이 read-only 검증(재싱크·재시작 불요).

### 롤백 노트
- 각 PR은 순수 테스트/게이트/Makefile 추가·수정 — **라이브 클러스터·워크로드 무변경**. 되돌림은 커밋 revert 1개로 완결(부작용 없음).
- PR-3b의 lint가 예상외로 다른 배치가 추가한 신규 bats에서 BB baseline 초과로 red면: (a) `scripts/check-bats-style.sh`의 `BB_BASELINE`을 재실측값으로 올리거나(신규가 정당한 마지막-명령 `[[ ]]`가 아니라 중간이면 `run …; [ … ]`로 교정), (b) 급하면 `BB_BASELINE_OVERRIDE` env로 임시 상향 후 후속 정리. NEG는 절대 완화 금지(모든 bash에서 죽는 클래스).
- posture jq가 라이브에서 예상외 위반(예: 신규 앱이 argocd/grafana 접두 백엔드를 공개)으로 red면 — 그건 **진짜 노출**이므로 롤백이 아니라 라우트를 고쳐야 한다(가드가 제 역할).

### 다음 배치 진행 조건
- 3 PR 전부 `gate` 통과 + 직렬 머지 완료(3a→3b→3c, 스택 금지).
- 라이브 `make verify-posture`(ArgoCD/Grafana ok) 및 owner-local `make verify-ksops`(age 키 보유 시) 통과 확인.
- **B13 인계 사항 명시**: `scripts/check-bats-style.sh`의 `BB_BASELINE`(중간 `[[ ]]` 65곳)을 B13 "구본 bats `[[ ]]` 정비"에서 0으로 수렴시키고 BB ratchet 분기를 hard-zero로 승격(또는 제거). B13 착수 시 `BB_BASELINE_OVERRIDE=0 scripts/check-bats-style.sh`로 잔량 목록을 뽑아 일괄 전환한다.
## B4. 시크릿/DR 결함 — seed ns·envFrom 갭·dr-drill 핀 (Wave 1)

**목표** 재시드/DR 시 tailnet 인증 회귀를 일으키는 seed-secrets ns 드리프트(M3), 앱 envFrom 미배선 침묵 배포(M5), dr-drill PG 이미지 하드코딩(M6)을 수리하고 각각에 정적 재발 가드를 세운다. 전부 정적 변경 — 라이브 워크로드 무영향.

**선행 조건** 없음(B1~B3와 파일 겹침 0 — 독립 진행 가능). 각 PR은 머지 직전 main 위로 rebase.

**PR 구성** (직렬 머지 — 스택 금지):
- PR-4a "fix: seed-secrets operator-oauth ns 교정 + seed↔커밋본 metadata 정합 가드" (B4.1)
- PR-4b "fix: create-db/cache envFrom 배선 갭 — checklist 명시 + audit unreferenced-conn" (B4.2·B4.3)
- PR-4c "fix: dr-drill PG 이미지 SSOT 파생 + 핀 정합 가드" (B4.4·B4.5)

**⚠️ 설계 보정 / 실측 노트**
1. **seed-secrets 전수 점검 완료**: `write_enc` 8블록 전수 대조 결과 드리프트는 **operator-oauth 1건뿐**(`scripts/seed-secrets.sh:59` `namespace: edge` vs 커밋본 `platform/tailscale/prod/operator-oauth.enc.yaml` `namespace: tailscale`). cloudflared-tunnel의 `edge`는 정합(cloudflared는 edge ns 상주). 나머지 6블록(cnpg-r2-creds/cache-r2-creds/pg-app-credentials/alerting-secrets/restore-drill-alerting/cloudflare-api-token)도 name/ns 전부 일치. 커밋본 `pg-admin-credentials.enc.yaml`은 seed 스크립트 산출물이 아님(1회 시드) — 가드 방향은 "seed 블록→커밋본"만으로 충분.
2. **restore-drill-script.sh:95 핀은 파생 불가**: 이 스크립트는 configMapGenerator(`platform/cnpg/prod/kustomization.yaml:28-31`)로 인클러스터 CronJob에 마운트되어 실행 — 런타임에 레포가 없다. `basebackup-cronjob.yaml:29`도 동일(매니페스트 인라인). 따라서 **yq 파생은 dr-drill.sh(owner 로컬, 레포 루트 실행)만** 적용하고, 인클러스터 2핀은 B4.5 bats 정합 가드로 커버한다. 파생 후 하드코딩 소비자는 4→3.
3. **provision-cache checklist에는 이미 envFrom 언급 존재**(`tools/provision-cache.ts:239`) — 단 "소비 시점 안내" 문구라 배선 액션이 아니다. 설계의 "항목 추가"를 cache 쪽은 "기존 항목을 배선 지시로 강화(교체)"로 보정. db 쪽(`tools/provision-db.ts:109-113`)은 항목 자체가 없어 신규 추가.
4. **unreferenced-conn은 `*-ro-conn` 제외 필수**: 실레포 data-conn 등록 6건 중 ro-conn 3건(`db-page-ro-conn`·`db-trip-mate-ro-conn`·`cache-trip-mate-ro-conn`)은 모드2 디버깅 전용으로 **의도적 미참조** — 제외하지 않으면 상시 오탐 3건. 제외 시 실레포 발화 0건(page/trip-mate conn 3건 전부 envFrom 배선 확인).
5. checklist 항목은 `_create-database.yaml:83`·`_create-cache.yaml:83`이 `jq -r '.checklist[]'`로 PR 본문 체크박스로 렌더 — **워크플로 무변경**으로 새 항목이 자동 반영된다.

---

### B4.1 seed-secrets operator-oauth ns 교정 + seed↔커밋본 metadata 정합 bats (PR-4a)

**Files:**
- Create: `tests/test_seed-secrets-metadata.bats`
- Modify: `scripts/seed-secrets.sh:59` (operator-oauth heredoc의 `namespace: edge`)
- Test: 위 신규 bats (git tracked → run-bats 자동 수집, age 키 불필요 — sops 파일의 metadata.name/namespace는 평문)

**Step 1 — 실패 테스트 작성** (`tests/test_seed-secrets-metadata.bats`):

```bash
#!/usr/bin/env bats
# seed-secrets.sh heredoc 산출물 metadata(name/namespace) ↔ 커밋본 *.enc.yaml 평문 metadata 정합 가드.
# 컴포넌트 ns 이동(#102 tailscale 분리 등) 시 seed 스크립트 미동기 → 재시드/DR에서 구 ns로
# 재생성되는 클래스(M3)를 정적으로 차단한다. sops는 metadata를 암호화하지 않으므로 age 키 불필요(CI-safe).
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

sh=scripts/seed-secrets.sh

# write_enc 블록 파서: "path<TAB>name<TAB>namespace" 행 출력 (heredoc 내 첫 name:/namespace:만 — metadata가 최상단)
seed_blocks() {
  awk '
    $1 == "write_enc" && $3 == "<<EOF" { path = $2; inblk = 1; n = ""; ns = ""; next }
    inblk && $1 == "EOF"               { print path "\t" n "\t" ns; inblk = 0; next }
    inblk && $1 == "name:"      && n  == "" { n  = $2 }
    inblk && $1 == "namespace:" && ns == "" { ns = $2 }
  ' "$sh"
}

@test "seed_blocks parser extracts every write_enc heredoc target (>=8, includes operator-oauth)" {
  run seed_blocks
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -ge 8 ]   # 파서 자체가 빈 결과로 침묵 통과하는 것 방지
  echo "$output" | grep -q "platform/tailscale/prod/operator-oauth.enc.yaml"
}

@test "every seed heredoc target matches the committed enc.yaml metadata (name and namespace)" {
  count=0
  while IFS=$'\t' read -r path name ns; do
    count=$((count + 1))
    [ -f "$path" ]   # enc 커밋본은 DR SSOT — seed 블록만 있고 커밋본이 없으면 fail-closed
    committed_name=$(awk '$1 == "name:"      { print $2; exit }' "$path")
    committed_ns=$(awk   '$1 == "namespace:" { print $2; exit }' "$path")
    [ "$name" = "$committed_name" ]
    [ "$ns" = "$committed_ns" ]
  done < <(seed_blocks)
  [ "$count" -ge 8 ]
}
```

**Step 2 — 실행(red)**:

```bash
bats tests/test_seed-secrets-metadata.bats
# 기대: 2 tests, 1 failure — 두 번째 테스트가 operator-oauth에서 실패
#   ([ "edge" = "tailscale" ] 단언 실패 — 진짜 결함이 red를 만든다)
```

**Step 3 — 최소 구현**: `scripts/seed-secrets.sh`의 아래 두 줄(operator-oauth heredoc 내부, 파일 전체에서 유일한 조합)을 교체:

```
  name: operator-oauth
  namespace: edge
```
→
```
  name: operator-oauth
  namespace: tailscale
```

(주의: `namespace: edge` 단독으로는 tunnel 블록 `:48`과 중복 — 반드시 `name: operator-oauth` 컨텍스트 포함 교체. 커밋본 `operator-oauth.enc.yaml`은 이미 tailscale이라 재시드 불필요 — 스크립트만 어긋나 있었다.)

**Step 4 — 게이트**:

```bash
bats tests/test_seed-secrets-metadata.bats      # 기대: 2 tests, 0 failures
shellcheck scripts/seed-secrets.sh              # 기대: exit 0 (무변경 수준 편집이나 확인)
make ci                                         # 기대: 전체 green (run-bats가 신규 bats 자동 수집)
```

**Step 5 — 커밋** (/commit 스킬):

```bash
git add scripts/seed-secrets.sh tests/test_seed-secrets-metadata.bats
# 메시지: fix: seed-secrets operator-oauth ns를 tailscale로 교정 + seed↔커밋본 metadata 정합 가드
```

---

### B4.2 provision-db/cache plan.checklist에 envFrom 배선 항목 (PR-4b)

**Files:**
- Modify: `tools/provision-db.ts:109-113` (checklist 배열), `tools/provision-cache.ts:237-241` (checklist 배열)
- Test: `tools/tests/test_provision-db.bats` (신규 @test 추가, `:254` dry-run 테스트 뒤), `tools/tests/test_provision-cache.bats` (신규 @test 추가)

**Step 1 — 실패 테스트 작성**. `tools/tests/test_provision-db.bats` 말미에 추가:

```bash
@test "provision-db checklist surfaces the app values.yaml envFrom wiring step" {
  # trip-mate 실재발(#211): conn이 봉인·커밋돼도 앱 values.yaml envFrom 미배선이면 DB 없이 배포된다.
  provision --name orders --repo-root "$FIX" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -re '.checklist[]' | grep -q "values.yaml"
  echo "$output" | jq -re '.checklist[]' | grep -q "envFrom"
  echo "$output" | jq -re '.checklist[]' | grep -q "db-orders-conn"
  # ro-conn은 모드2 디버깅 전용 — 배선 대상이 아님이 checklist에 명시된다
  echo "$output" | jq -re '.checklist[]' | grep -q "db-orders-ro-conn"
}
```

`tools/tests/test_provision-cache.bats` 말미에 추가:

```bash
@test "provision-cache checklist surfaces the app values.yaml envFrom wiring step" {
  # 기존 항목은 '소비 시점 안내'였다 — 배선 액션(values.yaml 경로 명시)으로 강화됐는지 단언(#211 클래스).
  provision --name demo --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -re '.checklist[]' | grep -q "values.yaml"
  echo "$output" | jq -re '.checklist[]' | grep -q "cache-demo-conn"
}
```

**Step 2 — 실행(red)**:

```bash
bats tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats
# 기대: 신규 2개만 실패 — db는 checklist에 envFrom 항목 자체가 없고, cache는 "values.yaml" 문자열 부재
```

**Step 3 — 최소 구현**. `tools/provision-db.ts`의 checklist 배열(`:109`) 첫 항목 앞에 삽입:

```ts
    `apps/<app>/deploy/prod/values.yaml envFrom에 secretRef 'db-${name}-conn' 배선 필요 — 미배선 시 앱이 DB 없이 그대로 배포된다(#211 재발 클래스). 'db-${name}-ro-conn'은 모드2 디버깅 전용이라 배선하지 않는다`,
```

`tools/provision-cache.ts:239`의

```ts
  `소비 앱은 envFrom secretRef cache-${name}-conn — envFrom 변경 반영은 파드 재시작 필요`,
```
를 다음으로 교체:

```ts
  `apps/<app>/deploy/prod/values.yaml envFrom에 secretRef 'cache-${name}-conn' 배선 필요 — 미배선 시 앱이 캐시 없이 그대로 배포된다(#211 재발 클래스). envFrom 변경(회전 포함) 반영은 파드 재시작 필요`,
```

(디스패처는 무변경 — `_create-database.yaml:83`·`_create-cache.yaml:83`이 checklist를 PR 본문 체크박스로 자동 렌더.)

**Step 4 — 게이트**:

```bash
bats tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats  # 기대: 전부 green
bun run typecheck                                                              # 기대: exit 0
```

**Step 5 — 커밋** (/commit 스킬):

```bash
git add tools/provision-db.ts tools/provision-cache.ts \
        tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats
# 메시지: fix: provision-db/cache checklist에 apps values.yaml envFrom 배선 항목 명시
```

---

### B4.3 audit-orphans `unreferenced-conn` 정보성 유형 (PR-4b)

**Files:**
- Modify: `tools/audit-orphans.ts` — 헤더 유형 목록(`:4-10`)에 1줄, 섹션 4 종료(`:126`)와 `const blocking`(`:128`) 사이에 섹션 5 삽입
- Test: `tools/tests/test_audit-orphans.bats` (신규 @test 2개)

**Step 1 — 실패 테스트 작성**. `tools/tests/test_audit-orphans.bats` 말미에 추가:

```bash
@test "audit reports unreferenced conn handles and skips ro-conn (mode-2 debug handles)" {
  # data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 참조 안 함 → 정보성 발화(#211 클래스).
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-orders-conn.sealed.yaml
  - db-orders-ro-conn.sealed.yaml
  - db-lonely-conn.sealed.yaml
EOF
  printf 'image: {repo: x, tag: sha-abc1234}\nroute: {public: true, host: orders.example.com}\nenvFrom:\n  - secretRef:\n      name: orders-secrets\n  - secretRef:\n      name: db-orders-conn\n' \
    > "$FR/apps/orders/deploy/prod/values.yaml"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn" and .subject == "db-lonely-conn")'
  # 참조된 conn과 ro-conn(의도적 미참조)은 미발화
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"unreferenced-conn\" and (.subject == \"db-orders-conn\" or .subject == \"db-orders-ro-conn\"))'"
  [ "$status" -ne 0 ]
}

@test "unreferenced-conn is informational and never blocks --ci" {
  # ghost(orphan-dns, 차단 유형)를 제거해 --ci 판정을 unreferenced-conn만으로 격리
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-lonely-conn.sealed.yaml
EOF
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn" and .subject == "db-lonely-conn")'
}
```

(기존 픽스처 setup은 data-conn `kustomization.yaml`을 만들지 않으므로 기존 테스트 8개는 새 섹션을 스킵 — 무영향. `"audit no longer emits dangling-binding/unreferenced-resource"` 테스트(`:38`)는 유형명이 달라 계속 green.)

**Step 2 — 실행(red)**:

```bash
bats tools/tests/test_audit-orphans.bats
# 기대: 신규 2개 실패 (unreferenced-conn 유형 미존재 → jq any() false), 기존 전부 green
```

**Step 3 — 최소 구현**. `tools/audit-orphans.ts` 헤더 유형 목록의 `dangling-role` 줄(`:8`) 다음에 추가:

```ts
//   unreferenced-conn     : data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 미참조 (정보성; *-ro-conn 제외)
```

섹션 4의 닫는 `}`(`:126`)와 `const blocking = …`(`:128`) 사이에 삽입:

```ts
// 5) unreferenced-conn — data-conn kustomization의 conn 항목인데 어느 apps/*/values.yaml
//    envFrom도 참조하지 않음(정보성, 비차단). *-ro-conn은 모드2 디버깅 전용(의도적 미참조)이라 제외.
//    trip-mate 실재발(#211): conn이 봉인·커밋돼도 앱이 envFrom을 배선 안 하면 어떤 게이트도 안 잡았다.
//    (이름 재사용/공유 등 이름≠앱 케이스가 있어 차단하지 않는다 — 정보로만 표면화.)
const connKustPath = `${ROOT}/platform/data-conn/prod/kustomization.yaml`;
if (existsSync(connKustPath)) {
  const connKust = parseYaml(readFileSync(connKustPath, "utf8")) ?? {};
  const connEntries: string[] = (connKust.resources ?? [])
    .map((r: any) => String(r))
    .filter((r: string) => /^(db|cache)-.+-conn\.sealed\.yaml$/.test(r) && !r.endsWith("-ro-conn.sealed.yaml"));
  const referenced = new Set<string>();
  for (const a of appDirs) {
    const values = parseYaml(readFileSync(`${appsRoot}/${a}/deploy/prod/values.yaml`, "utf8")) ?? {};
    for (const e of values.envFrom ?? []) {
      const n = e?.secretRef?.name;
      if (n) referenced.add(String(n));
    }
  }
  for (const entry of connEntries) {
    const handle = entry.replace(/\.sealed\.yaml$/, "");
    if (!referenced.has(handle))
      add("unreferenced-conn", handle,
        "data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 참조하지 않음 — 앱이 DB/캐시 없이 배포 중일 수 있음(#211 클래스, 정보성)");
  }
}
```

(`BLOCKING` 집합 무변경 — 정보성. 실레포 발화 0건은 보정 노트 4의 실측으로 확인됨.)

**Step 4 — 게이트**:

```bash
bats tools/tests/test_audit-orphans.bats        # 기대: 전부 green
bun run typecheck                               # 기대: exit 0
bun tools/audit-orphans.ts --ci                 # 기대: exit 0, 실레포 unreferenced-conn 0건
make ci                                         # 기대: green
```

**Step 5 — 커밋** (/commit 스킬):

```bash
git add tools/audit-orphans.ts tools/tests/test_audit-orphans.bats
# 메시지: feat: audit-orphans에 unreferenced-conn 정보성 유형 추가 — data-conn↔envFrom 대조
```

---

### B4.4 dr-drill PG 이미지를 cluster.yaml에서 파생 (PR-4c)

**Files:**
- Modify: `scripts/dr-drill.sh` — `:22`(`KUBECONFIG_PATH=…`) 직후에 파생 블록 삽입, `:43` 하드코딩 핀 교체
- Test: `tests/test_dr-drill.bats` (신규 @test 추가)

**Step 1 — 실패 테스트 작성**. `tests/test_dr-drill.bats` 말미에 추가:

```bash
@test "dr-drill derives the PG image from cluster.yaml instead of hardcoding a pin" {
  # 하드코딩 핀은 PG 메이저 갱신 시 cross-major 물리복구 불가로 드릴을 조용히 죽인다(M6).
  # SSOT = platform/cnpg/prod/cluster.yaml spec.imageName — 파생 실패는 fail-closed.
  run grep -c 'cloudnative-pg/postgresql:[0-9]' "$sh"
  [ "$output" -eq 0 ]                                  # 리터럴 태그 핀 0
  grep -q 'platform/cnpg/prod/cluster.yaml' "$sh"      # SSOT 참조
  grep -q 'imageName: ${PG_IMAGE}' "$sh"               # heredoc이 파생 변수 사용
  grep -q 'PG 이미지 파생 실패' "$sh"                   # fail-closed 분기 존재
}
```

**Step 2 — 실행(red)**:

```bash
bats tests/test_dr-drill.bats
# 기대: 10 tests, 1 failure — 신규 테스트만 실패 (리터럴 핀 1개 존재, PG_IMAGE 미정의)
```

**Step 3 — 최소 구현**. `scripts/dr-drill.sh:22`(`KUBECONFIG_PATH=…`) 바로 아래에 삽입:

```bash
# PG 이미지는 cluster.yaml(SSOT)에서 파생 — 하드코딩 핀은 PG 메이저 갱신 시 cross-major
# 물리복구 불가로 드릴을 조용히 죽인다(M6). 인클러스터 소비자(basebackup·restore-drill)는
# 런타임에 레포가 없어 파생 불가 → tests/test_pg-image-pin.bats가 핀 정합을 강제한다.
command -v yq >/dev/null || { echo "DR DRILL FAIL: yq 필요(docs/runbooks/toolchain.md 핀)"; exit 1; }
PG_IMAGE="$(yq '.spec.imageName' platform/cnpg/prod/cluster.yaml)"
case "$PG_IMAGE" in
  ghcr.io/cloudnative-pg/postgresql:[0-9]*) ;; # yq 버전차 방어 — 값 형태를 직접 검증
  *) echo "DR DRILL FAIL: cluster.yaml에서 PG 이미지 파생 실패 (got: '${PG_IMAGE}')"; exit 1 ;;
esac
```

`scripts/dr-drill.sh:43`의 (파일 내 유일한) 리터럴 핀 줄

```
  imageName: ghcr.io/cloudnative-pg/postgresql:18.4
```
을 다음으로 교체 (heredoc `<<YAML`은 비인용이라 변수 확장됨 — 같은 heredoc의 `${NS}`와 동일):

```
  imageName: ${PG_IMAGE}
```

**Step 4 — 게이트**:

```bash
bats tests/test_dr-drill.bats               # 기대: 10 tests, 0 failures
shellcheck scripts/dr-drill.sh              # 기대: exit 0
bash -n scripts/dr-drill.sh                 # 기대: 문법 OK
```

**Step 5 — 커밋** (/commit 스킬):

```bash
git add scripts/dr-drill.sh tests/test_dr-drill.bats
# 메시지: fix: dr-drill PG 이미지를 cluster.yaml에서 파생 — 하드코딩 핀 제거
```

---

### B4.5 PG 이미지 핀 정합 bats 가드 (PR-4c)

**Files:**
- Create: `tests/test_pg-image-pin.bats` (CI-safe — git grep만, run-bats 자동 수집)
- Test: 자기 자신 (가드 테스트 — 현재 3핀 일치라 즉시 green이 정상; red 검증은 일시 변조로 수행)

**Step 1 — 테스트 작성** (`tests/test_pg-image-pin.bats`):

```bash
#!/usr/bin/env bats
# PG 이미지 핀 정합 가드(M6) — SSOT는 platform/cnpg/prod/cluster.yaml spec.imageName.
# 인클러스터 소비자(basebackup-cronjob.yaml·restore-drill-script.sh)는 런타임에 레포가 없어
# 파생 불가 → 하드코딩을 허용하되 이 게이트가 SSOT 일치를 강제한다(PG 메이저 3-이미지 동시
# 갱신 함정 클래스 — PgDumpHedgeStale #178 낙진과 동일 계열). dr-drill.sh는 파생이라 리터럴 0.
# 신규 하드코딩 소비자는 git grep 스코프(docs/plans 제외 전 레포)로 자동 편입된다.

PIN_RE='ghcr\.io/cloudnative-pg/postgresql:[0-9][A-Za-z0-9._-]*'
SSOT_FILE=platform/cnpg/prod/cluster.yaml

@test "cluster.yaml exposes exactly one PG image pin (SSOT sanity)" {
  run bash -c "grep -Eo '$PIN_RE' $SSOT_FILE | sort -u"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "all hardcoded PG image pins repo-wide match the cluster.yaml SSOT" {
  ssot="$(grep -Eo "$PIN_RE" "$SSOT_FILE" | sort -u)"
  [ -n "$ssot" ]
  # docs/plans는 역사 기록(구버전 핀 잔존)이라 제외 — 그 외 전 레포의 리터럴 핀은 SSOT와 동일해야 한다
  run bash -c "git grep -h -Eo '$PIN_RE' -- ':(exclude)docs/plans' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "$ssot" ]
}
```

**Step 2 — red 검증(일시 변조 후 원복)**:

```bash
bats tests/test_pg-image-pin.bats                # 기대: 2 tests, 0 failures (B4.4 이후 3핀 전부 일치)
sed -i '' 's|postgresql:18\.4|postgresql:19.0|' platform/cnpg/prod/basebackup-cronjob.yaml
bats tests/test_pg-image-pin.bats                # 기대: 1 failure — 핀 불일치 검출(가드 실효 증명)
git checkout -- platform/cnpg/prod/basebackup-cronjob.yaml
bats tests/test_pg-image-pin.bats                # 기대: 2 tests, 0 failures
```

**Step 3 — 게이트**:

```bash
make ci   # 기대: green — run-bats가 tests/test_pg-image-pin.bats 자동 수집(.ci-exclude 비대상)
```

**Step 4 — 커밋** (/commit 스킬):

```bash
git add tests/test_pg-image-pin.bats
# 메시지: test: PG 이미지 핀 정합 가드 추가 — cluster.yaml SSOT와 전 소비자 일치 강제
```

---

**게이트·라이브 검증**

```bash
# 각 PR 머지 전 (로컬 gate 재현)
make ci                                   # 기대: 전체 green — 신규 bats 3파일 수집 확인은 아래로
./scripts/run-bats.sh --list | grep -E 'seed-secrets-metadata|pg-image-pin'
# 기대: 두 파일 모두 출력 (gate 편입 확인)

# 라이브 (읽기 전용 — 시크릿 값 미출력, metadata만)
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl -n tailscale get secret operator-oauth -o jsonpath='{.metadata.namespace}{"\n"}'
# 기대: tailscale (커밋본과 라이브 정합 — seed 수정은 다음 재시드부터 유효)
kubectl -n edge get secret operator-oauth --ignore-not-found
# 기대: 출력 없음 (구 ns 잔재 0)
bun tools/audit-orphans.ts | jq '[.findings[] | select(.type == "unreferenced-conn")] | length'
# 기대: 0 (실레포 conn 3건 전부 envFrom 배선 — 보정 노트 4)
```

dr-drill 자체는 파괴적 owner-local 드릴이라 본 배치에서 실행하지 않는다 — 파생 로직은 bats(문법·fail-closed 분기·핀 부재)로 검증하고, 실효 확인은 다음 정기 드릴 때 `==> [0.5]` 단계의 verify 클러스터 기동 성공으로 갈음한다.

**롤백 노트**
- 전 태스크 정적 변경 — 커밋 revert로 완전 롤백, 라이브 조치 불요.
- B4.1: seed-secrets 수정은 다음 `make seed-secrets` 실행 전까지 어떤 효과도 없음(커밋본이 이미 정답). revert 시 가드 bats가 다시 red가 되므로 반드시 쌍으로 revert.
- B4.2/B4.3: checklist는 안내 텍스트, unreferenced-conn은 비차단 — 오탐 발생 시(예: 미래의 의도적 미참조 conn) revert 없이 해당 유형 필터에 예외 추가로 대응 가능.
- B4.4/B4.5: dr-drill revert 시 test_dr-drill·test_pg-image-pin 둘 다 갱신 필요(리터럴 핀 부활은 pin bats에 걸리지 않지만 dr-drill bats에 걸림) — 쌍으로 revert.

**다음 배치 진행 조건**
- PR-4a→4b→4c 직렬 머지 완료, 각 PR required check `gate` green.
- main에서 `./scripts/run-bats.sh --list`에 신규 bats 3파일 편입 + `bun tools/audit-orphans.ts --ci` exit 0.
- 라이브 검증 3항목(위) 통과 — 이후 B5(files 데이터 내구성 체인, 파일 겹침 없음)로 진행.
## B5. files 데이터 내구성 체인 (SC Retain·백업 필수·관측·DR) (Wave 1)

**목표** files-data(git+R2+age로 재구축 불가한 유일한 비재생성 사용자 데이터)의 삭제·침묵유실·매체유실 3중 방어를 git SSOT로 승격한다: bulk-ssd `reclaimPolicy: Retain` 성문화 + 라이브 드리프트 가드, 호스트 오프-SSD rsync 백업(복원 스모크·RPO 일1회) 필수화, 용량/백업 신선도 관측, DR 재결합 검증.

**선행 조건** 없음(Wave 1, B2와 독립 — B2는 워크로드-불가용 룰로 files NotReady를 커버하고, B5는 데이터 자체의 내구성을 커버. 겹침 없음). 라이브 SC 마이그레이션·백업 launchd 배선은 owner-local 후속 절차로, PR 머지와 분리.

**PR 구성** (직렬 머지 — 스택 squash 함정 회피):
- PR-5a "refactor(storage): bulk-ssd reclaimPolicy Retain 승격 + posture reclaim 단언" — SC git 승격 + 오프라인 렌더 가드 + 라이브 reclaim posture 테스트 + pvc.yaml 내구성 등급 헤더.
- PR-5b "feat(scripts): files-data 오프-SSD rsync 백업 + 복원 스모크 + 용량/신선도 관측" — `backup-files-data.sh` 신설 + 헤르메틱 bats + scripts/README 등재 + r4 vmalert 룰 2종 + test_vmalert-config 단언.
- PR-5c "feat(dr): dr-drill files 카탈로그 재결합 검증" — dr-drill.sh 재결합 스텝 + test_dr-drill 단언 (+ owner-local 런북 갱신 지시).

> ⚠️ **설계 보정**:
> - 설계 §1.1 H2가 인용한 `storageclass-bulk-ssd.yaml:7-8`는 실측과 **일치**(line 7 = 주석 `# 여기서는 Delete가 적절하다: media/backup-staging 볼륨은 R2에서 재생성 가능하다.`, line 8 = `reclaimPolicy: Delete`). 단 주석은 "media/backup-staging"을 전제하는데 files 온보딩(2026-07-01) 후 **거짓 전제**가 됨 — files-data는 재생성 불가. 주석 전문 교체 필요.
> - 설계 §3 B5의 "bulk-ssd 용량 관측: 앱 /readyz export **또는** 호스트 launchd push — 택1"에서 배치 스펙이 **호스트 launchd push 채택**. 근거: (a) files 앱 레포 무변경(경계 보존), (b) files 파드에 `prometheus.io/scrape` 어노테이션 부재(H1과 동형 갭 — 앱이 메트릭을 export해도 vmagent가 못 긁음), (c) restore-drill push 패턴(`platform/cnpg/prod/restore-drill-script.sh:64-68`) 재사용으로 신규 표면 최소.
> - SC는 **apply-storage.sh(부트스트랩)가 apply — ArgoCD 관리 아님**(substrate 계층). 따라서 이 배치의 SC 변경은 ArgoCD 드리프트 무관이며, 라이브 반영은 owner의 `kubectl`/재부트스트랩 수동 절차.
> - `reclaimPolicy`는 StorageClass **immutable 필드**다(k8s: provisioner·parameters·reclaimPolicy·volumeBindingMode 변경 금지 → `kubectl apply`가 `forbidden`으로 거부). 라이브 인플레이스 반영은 **SC delete+recreate** 필요(기존 PV/PVC는 SC 객체 삭제에 영향 없음 — 바인딩은 이름 참조이며 PV가 자기 reclaimPolicy를 이미 복제 보유). DR(신규 클러스터)은 fresh apply라 무영향.
> - bulk-ssd **소비자 2**: `platform/files/prod/pvc.yaml`(files-data, Retain 필수) + `platform/cnpg/prod/basebackup-pvc.yaml:8`(pg-basebackup-local, 그 자체가 백업이라 Retain 무해·재생성 가능). 둘 다 외장 SSD(`/Volumes/homelab/k3s-bulk/`) 공유 — 백업 rsync는 **files-data PV만** 겨냥(claimRef 필터로 basebackup 제외).

---

### B5.1 bulk-ssd StorageClass reclaimPolicy Retain 승격 + 오프라인 가드

**Files:** Modify: `infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml:7-8`(주석+정책), `infra/k3s-bootstrap/tests/test_06-storage-manifests.bats:27-32`(bulk @test 확장) / Test: 위 bats(gate 수집 — k3s-bootstrap/tests는 `.ci-exclude` 미포함, run-bats 자동 편입).

**Step 1 — 실패 테스트 작성.** `test_06-storage-manifests.bats`의 bulk @test에 reclaim 단언을 추가한다(현재 이 @test는 default/WFC/provisioner만 검사 — reclaim 무단언이라 회귀 무방비). 다음을 `@test "bulk-ssd is NOT default, WaitForFirstConsumer, external path"` 블록 끝(라인 32 `}` 직전)에 삽입:

```bash
  # files-data는 비재생성 사용자 데이터 — Retain 필수(git SSOT). Delete면 PVC 삭제/reclaim이 SSD 데이터를 파괴.
  run yq -e '.reclaimPolicy' "$BULK"; [ "$output" = "Retain" ]
```

**Step 2 — 실행(기대 실패).**
```
bats infra/k3s-bootstrap/tests/test_06-storage-manifests.bats
# 기대: "bulk-ssd is NOT default…" FAIL — output "Delete" != "Retain"
```

**Step 3 — 최소 구현.** `storageclass-bulk-ssd.yaml`의 라인 7 주석과 라인 8 정책을 교체:

- 라인 7 `# 여기서는 Delete가 적절하다: media/backup-staging 볼륨은 R2에서 재생성 가능하다.` →
```yaml
# Retain: bulk-ssd 소비자 files-data는 유일한 비재생성 사용자 데이터다(git+R2+age로 재구축 불가). Delete면
# PVC 삭제/reclaim이 외장 SSD의 실데이터를 파괴한다. (다른 소비자 pg-basebackup-local은 그 자체가 백업이라
# Retain 무해 — Released 잔존은 scripts/audit-orphan-pv.sh가 나열.) 라이브 인플레이스 반영은 reclaimPolicy가
# SC immutable이라 delete+recreate 필요(런북 external-ssd.md); DR 신규 클러스터는 fresh apply라 무영향.
```
- 라인 8 `reclaimPolicy: Delete` → `reclaimPolicy: Retain`

**Step 4 — 게이트.**
```
bats infra/k3s-bootstrap/tests/test_06-storage-manifests.bats   # 기대: all pass
make ci                                                          # 기대: gate green (run-bats 전수)
```

**Step 5 — 커밋.**
```
git add infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml infra/k3s-bootstrap/tests/test_06-storage-manifests.bats
git commit -m "refactor(storage): bulk-ssd reclaimPolicy를 Retain으로 승격

files-data는 유일한 비재생성 사용자 데이터인데 SC가 Delete라 PV Retain이
라이브 kubectl patch에만 의존했다(드리프트 가드 0). git SSOT로 승격하고
stale 주석(R2 재생성 전제)을 교체한다."
```

---

### B5.2 라이브 reclaim posture 단언 (git↔라이브 드리프트 가드)

**Files:** Create: `tests/posture/test_storage-reclaim.bats`, Modify: `tests/.ci-exclude`(라이브 그룹에 등재) / Test: 신규 posture bats(라이브 — `make verify-posture`가 `tests/posture/test_*.bats` glob 수집; gate 제외).

**Step 1 — 실패 테스트 작성.** posture 스위트에 라이브 단언 추가(SC Retain + files-data PV Retain 둘 다 — SC만 검사하면 기존 PV가 Delete로 남은 케이스를 놓침). `tests/posture/test_storage-reclaim.bats`:

```bash
#!/usr/bin/env bats
# files 데이터 내구성 posture (H2/M14): bulk-ssd SC와 files-data PV가 둘 다 라이브에서 Retain인지.
# git 승격(B5.1)이 라이브에 실제 반영됐고 인플레이스 마이그레이션(SC delete+recreate)이 완료됐는지 확인한다.
# LIVE: KUBECONFIG = files-prod가 sync된 k3s VM 필요. @test 이름은 영어.

@test "bulk-ssd StorageClass is Retain live (git↔live drift guard)" {
  run bash -c "kubectl get sc bulk-ssd -o jsonpath='{.reclaimPolicy}'"
  [ "$status" -eq 0 ]
  [ "$output" = "Retain" ]
}

@test "the bound files-data PV carries Retain (existing PV migrated, not only new ones)" {
  # SC를 Retain으로 바꿔도 이미 프로비저닝된 PV는 provision 시점 정책을 보유한다 — 라이브 patch 여부를 직접 확인.
  pv="$(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="files-data")]}{.metadata.name}{"\n"}{end}' | head -1)"
  [ -n "$pv" ]
  run bash -c "kubectl get pv '$pv' -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'"
  [ "$status" -eq 0 ]
  [ "$output" = "Retain" ]
}
```

**Step 2 — 실행(라이브 부재 시 skip / 라이브서 현 상태 확인).**
```
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
bats tests/posture/test_storage-reclaim.bats
# 라이브서: SC 미마이그레이션 상태면 첫 @test FAIL(output "Delete") — 인플레이스 절차 필요를 노출.
# files-data PV는 기존 라이브 patch(H2 서술)로 이미 Retain일 것 — 둘째 @test는 그 사실을 고정.
```

**Step 3 — `.ci-exclude` 등재.** `tests/.ci-exclude`의 "라이브 클러스터 의존 (수동: make verify-posture)" 그룹(현재 3줄: internal-by-default/network-policy/networking-e2e) 끝에 추가:
```
tests/posture/test_storage-reclaim.bats
```

**Step 4 — 게이트.**
```
make ci   # 기대: gate green. check-bats-accounting가 신규 posture bats를 .ci-exclude 소유로 인정(고아 아님).
```
> ⚠️ `.ci-exclude` 미등재 시 run-bats가 gate에서 수집해 라이브 kubectl 부재로 실패 → check-bats-accounting(모든 tracked bats는 정확히 한 도메인) 강제로 반드시 등재.

**Step 5 — 커밋.**
```
git add tests/posture/test_storage-reclaim.bats tests/.ci-exclude
git commit -m "test(posture): bulk-ssd SC·files-data PV Retain 라이브 단언

git 승격(B5.1)이 라이브에 반영됐는지 + 기존 PV 마이그레이션까지 확인하는
드리프트 가드. verify-posture 수동 스위트에 편입(gate 제외)."
```

**라이브 인플레이스 마이그레이션 (owner-local, PR 머지 후 별도 절차 — 커밋 아님):**
```
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl get sc bulk-ssd -o jsonpath='{.reclaimPolicy}'; echo   # 현재값 확인(Delete면 마이그레이션 필요)
# reclaimPolicy는 immutable → delete+recreate. 기존 PV/PVC는 무영향(이름 참조·정책 자가보유).
# 짧은 창(SC 부재) 동안 신규 bulk PVC 프로비저닝만 대기 — files는 이미 바운드라 무영향.
kubectl delete sc bulk-ssd
kubectl apply -f infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml   # 게이트 없는 단일 SC apply
kubectl get sc bulk-ssd -o jsonpath='{.reclaimPolicy}'; echo   # 기대: Retain
bats tests/posture/test_storage-reclaim.bats                   # 기대: 2 pass
```

---

### B5.3 pvc.yaml 내구성 등급 헤더 (RPO·백업 provenance 성문화)

**Files:** Modify: `platform/files/prod/pvc.yaml:1-2`(헤더 주석) / Test: 기존 `platform/files/prod/test_files_storage.bats`(spec 필드만 검사 — 주석 변경 무영향, 회귀 확인용).

**Step 1 — 구현.** `pvc.yaml` 라인 1-2를 교체:
```yaml
# 사용자 파일 저장 — 2TB 외장 SSD(bulk-ssd, virtiofs). storageClassName 명시 필수(opt-in;
# 누락 시 standard=VM 디스크로 조용히 착지). Prune=false + SC bulk-ssd reclaimPolicy=Retain
# (git SSOT: infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml)로 삭제민감 데이터 보호.
# 내구성 등급 = 비재생성(non-regenerable): files-data는 git+R2+age로 재구축 불가한 유일 자산.
#   · 오삭제/침묵유실 방어: Retain + Prune=false + /readyz free-space + FilesBackup/FilesBulkSSD 알림(r4).
#   · 매체(SSD) 유실 방어: 호스트 오프-SSD rsync 사본(scripts/backup-files-data.sh, RPO=일1회/24h launchd).
#   · R2 미사용(무료티어)은 '백업 없음'이 아니라 '백업 = 호스트 내장 디스크 사본'. DR 재결합=external-ssd.md.
```

**Step 2 — 게이트.**
```
bats platform/files/prod/test_files_storage.bats   # 기대: 3 pass(주석 무관)
make ci                                            # 기대: green
```

**Step 3 — 커밋.**
```
git add platform/files/prod/pvc.yaml
git commit -m "docs(files): pvc 헤더에 내구성 등급·RPO·백업 provenance 성문화

files-data가 비재생성 등급임과 3중 방어(Retain·호스트 rsync 사본·관측)를
매니페스트에 명시. R2 미사용을 '백업=호스트 사본'으로 기록(백업 없음 아님)."
```

*(B5.1~B5.3 = PR-5a. 라이브 SC 마이그레이션은 PR-5a 머지 후 owner 절차.)*

---

### B5.4 files-data 오프-SSD rsync 백업 스크립트 (복원 스모크 + 용량/신선도 push)

**Files:** Create: `scripts/backup-files-data.sh`, `tests/gates/test_backup-files-data.bats`, Modify: `scripts/README.md`(DR/owner 전용 섹션 등재) / Test: 헤르메틱 bats(gate 수집 — 스텁 kubectl/diskutil/rsync/curl/df).

**Step 1 — 실패 테스트 작성.** `tests/gates/test_backup-files-data.bats`(test_07-apply-storage.bats 스텁 패턴 미러 — kubectl/diskutil/rsync/curl/df 밀폐). CI-safe(클러스터·SSD 불요):

```bash
#!/usr/bin/env bats
# backup-files-data.sh 헤르메틱 가드(스텁으로 밀폐). @test 이름은 영어. ⚠️ 중간 부정 단언은 run+[ ]로만.
load ../test_helper 2>/dev/null || true
S="scripts/backup-files-data.sh"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  STUB="$(mktemp -d)"; DEST="$(mktemp -d)"; SRC="$(mktemp -d)"
  PATH="$STUB:$PATH"; export PATH STUB DEST SRC
  echo "hello-files" > "$SRC/a.txt"; mkdir -p "$SRC/sub"; echo "beta" > "$SRC/sub/b.txt"
  export FILES_DATA_HOST_PATH="$SRC"          # kubectl 파생 우회(테스트 밀폐)
  export METRICS_PUSH_URL="http://127.0.0.1:59999"   # push 대상 스텁(비면 port-forward 경로)
  # diskutil: 기본 Internal(허용). DISKUTIL_EXTERNAL=1 이면 External(dest 거부 케이스).
  cat >"$STUB/diskutil" <<'EOF'
#!/usr/bin/env bash
[ "$1" = info ] && { [ "${DISKUTIL_EXTERNAL:-0}" = 1 ] && echo "   Device Location: External" || echo "   Device Location: Internal"; }
exit 0
EOF
  # rsync 스텁: 실제 복사(--dry-run이면 미복사)로 매니페스트 경로를 커버.
  cat >"$STUB/rsync" <<'EOF'
#!/usr/bin/env bash
dry=0; for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; done
s="${@: -2:1}"; d="${@: -1}"
[ "$dry" = 1 ] && exit 0
mkdir -p "$d"; cp -a "$s". "$d" 2>/dev/null || cp -a "$s"/. "$d"; exit 0
EOF
  # curl 스텁: RSYNC_PUSH_FAIL=1 이면 push 실패(백업은 그래도 성공해야 함).
  cat >"$STUB/curl" <<'EOF'
#!/usr/bin/env bash
[ "${CURL_PUSH_FAIL:-0}" = 1 ] && exit 22
cat >/dev/null 2>&1; exit 0
EOF
  chmod +x "$STUB"/{diskutil,rsync,curl}
}
teardown() { rm -rf "$STUB" "$DEST" "$SRC"; }

@test "backup stages, promotes, and writes a sha256 manifest, then exits 0" {
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  [ -f "$DEST/data/a.txt" ]
  run bash -c "ls '$DEST'/files-data.*.sha256"; [ "$status" -eq 0 ]
  run bash -c "ls -d '$DEST/data.new'"; [ "$status" -ne 0 ]   # 스테이징 잔재 없음
}
@test "REFUSES an external-disk dest (media-loss copy is useless)" {
  DISKUTIL_EXTERNAL=1 run bash "$S" "$DEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "매체 유실 무방비"
}
@test "--dry-run makes no changes and pushes no metric" {
  run bash "$S" --dry-run "$DEST"; [ "$status" -eq 0 ]
  run bash -c "ls '$DEST'/files-data.*.sha256 2>/dev/null"; [ "$status" -ne 0 ]
}
@test "--verify restores one file and passes sha256, fails on corruption" {
  bash "$S" "$DEST" >/dev/null
  run bash "$S" --verify "$DEST"; [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--verify 통과"
  # 손상 주입: 백업 파일 1개 변조 → --verify FAIL
  echo tampered >> "$DEST/data/a.txt"
  run bash "$S" --verify "$DEST"; [ "$status" -ne 0 ]
  echo "$output" | grep -q "sha256 불일치"
}
@test "EMPTY source aborts promotion and preserves the previous copy" {
  bash "$S" "$DEST" >/dev/null                       # 1차 백업으로 사본 확보
  EMPTY="$(mktemp -d)"
  FILES_DATA_HOST_PATH="$EMPTY" run bash "$S" "$DEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "승격 중단"
  [ -f "$DEST/data/a.txt" ]                          # 기존 사본 무손상
  rm -rf "$EMPTY"
}
@test "sharp shrink aborts unless FORCE_SHRINK=1, which promotes and keeps data.prev" {
  for i in 1 2 3 4 5; do echo "f$i" > "$SRC/f$i.txt"; done
  bash "$S" "$DEST" >/dev/null                       # 7파일 백업
  rm -f "$SRC"/f*.txt "$SRC/sub/b.txt"               # 7→1 급감
  run bash "$S" "$DEST"; [ "$status" -ne 0 ]
  echo "$output" | grep -q "급감"
  [ -f "$DEST/data/f1.txt" ]                         # 승격 중단 — 기존 사본 유지
  FORCE_SHRINK=1 run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  [ -f "$DEST/data.prev/f1.txt" ]                    # 직전 스냅샷 보존
}
@test "metric push failure does NOT fail the backup (staleness alert is the backstop)" {
  CURL_PUSH_FAIL=1 run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  echo "$output" | grep -q "WARN: 메트릭 push 실패"
}
@test "fails loud when the source path does not exist" {
  FILES_DATA_HOST_PATH="/no/such/dir" run bash "$S" "$DEST"; [ "$status" -ne 0 ]
}
@test "passes shellcheck" { run shellcheck "$S"; [ "$status" -eq 0 ]; }
```

**Step 2 — 실행(기대 실패).**
```
bats tests/gates/test_backup-files-data.bats
# 기대: 전부 FAIL — scripts/backup-files-data.sh 부재.
```

**Step 3 — 최소 구현.** `scripts/backup-files-data.sh`(backup-sealed-secrets-key.sh의 owner-local·직접실행·`--verify` 모드 규약 미러):

```bash
#!/usr/bin/env bash
# files-data 오프-SSD rsync 백업 (H2/M14 — files는 git+R2+age 재구축 불변식의 유일 예외).
#
# 왜: bulk-ssd(외장 SSD) files-data PV는 Retain·Prune=false·관측으로 오삭제/침묵유실은 막지만
# 매체(SSD) 자체가 죽으면 전손이다. files-data를 Mac 내장 디스크(오프-SSD 사본)로 rsync해 매체
# 유실에 대비한다. R2 미사용(무료티어)이라 이 호스트 사본이 유일한 2차 매체다.
#
# 불변식: (1) source=라이브 files/files-data PV 호스트 경로(kubectl claimRef 파생; VM /mnt/mac* → 호스트 /Volumes*).
#   (2) dest=반드시 내장 디스크(외장이면 거부 — 같은 매체 사본 무의미, diskutil Device Location).
#   (3) 성공 시 sha256 매니페스트 + files_backup_last_success_timestamp·용량을 vmsingle에 push(r4 게이트).
#   (4) fail-loud: source 파생 실패·dest 외장·rsync 실패는 비-0 종료. push 실패는 WARN(신선도 알림이 backstop).
#
# 사용:
#   scripts/backup-files-data.sh <dest(내장 디스크, git 밖)>      # 백업 + 매니페스트 + 메트릭 push
#   scripts/backup-files-data.sh --dry-run <dest>                # rsync -n (무변경, push 없음)
#   scripts/backup-files-data.sh --verify  <dest>                # 최신 백업서 파일 1개 복원 + sha256 대조(매체 판독성 게이트)
# launchd 배선(일1회, RPO=24h)은 owner-local — docs/runbooks/external-ssd.md.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE=backup
case "${1:-}" in
  --dry-run) MODE=dryrun; shift ;;
  --verify)  MODE=verify; shift ;;
esac
dest="${1:?usage: backup-files-data.sh [--dry-run|--verify] <dest(내장 디스크, git 밖)>}"
mkdir -p "$dest"; dest="$(cd "$dest" && pwd)"

export KUBECONFIG="${KUBECONFIG:-$ROOT/infra/k3s-bootstrap/kubeconfig}"
PUSHGW="${METRICS_PUSH_URL:-}"   # 비면 vmsingle로 port-forward. 셋이면 그 URL로 직접 push.
PF_NS=observability; PF_SVC=vmsingle; PF_PORT=8428

sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
latest_manifest() { ls -1 "$dest"/files-data.*.sha256 2>/dev/null | sort | tail -1; }

# --- --verify: 최신 매니페스트 첫 항목을 복원 위치로 꺼내 sha256 재대조 ---
if [ "$MODE" = verify ]; then
  man="$(latest_manifest)"; [ -n "$man" ] || { echo "ERROR: 매니페스트 없음 — 먼저 백업 생성" >&2; exit 1; }
  read -r want rel < "$man" || true
  [ -n "${rel:-}" ] || { echo "ERROR: 매니페스트 비어있음: $man" >&2; exit 1; }
  file="$dest/data/$rel"; [ -f "$file" ] || { echo "ERROR: 백업에 파일 부재: $rel" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cp "$file" "$tmp/restored"                       # 복원 시뮬레이션(매체서 판독)
  got="$(sha256 "$tmp/restored" | awk '{print $1}')"
  [ "$got" = "$want" ] || { echo "ERROR: 복원 sha256 불일치($rel): want=$want got=$got — 백업 매체 손상 의심" >&2; exit 1; }
  echo "OK: --verify 통과($rel 복원+sha256 일치, $man)"
  exit 0
fi

# --- source 파생: files/files-data PV 호스트 경로 ---
vmpath="${FILES_DATA_HOST_PATH:-}"
if [ -z "$vmpath" ]; then
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl 부재 — source PV 파생 불가" >&2; exit 2; }
  command -v yq >/dev/null 2>&1 || { echo "ERROR: yq 부재" >&2; exit 2; }
  vmpath="$(kubectl get pv -o json \
    | yq -r '.items[] | select(.spec.claimRef.namespace=="files" and .spec.claimRef.name=="files-data") | (.spec.hostPath.path // .spec.local.path // "")' \
    | head -1 || true)"
  vmpath="${vmpath#/mnt/mac}"                      # VM /mnt/mac/Volumes/... → 호스트 /Volumes/...
fi
[ -n "$vmpath" ] || { echo "ERROR: files/files-data PV 호스트 경로 파생 실패(바운드 PV 없음?)" >&2; exit 2; }
[ -d "$vmpath" ] || { echo "ERROR: source 디렉토리 부재: $vmpath" >&2; exit 2; }

# --- dest 매체 검사: 반드시 내장 디스크(외장 SSD 사본은 매체 유실 무방비) ---
command -v diskutil >/dev/null 2>&1 || { echo "ERROR: diskutil 부재 — dest 매체 판별 불가" >&2; exit 2; }
loc="$(diskutil info "$dest" 2>/dev/null | awk -F': *' '/Device Location/{print $2}' | tr -d '[:space:]' || true)"
[ "$loc" = "Internal" ] || { echo "ERROR: dest($dest) Device Location='${loc:-?}' — 외장 SSD 위 사본은 매체 유실 무방비. 내장 디스크 경로를 쓰라." >&2; exit 1; }

if [ "$MODE" = dryrun ]; then
  echo "==> DRY-RUN rsync $vmpath/ → $dest/data.new/ (스테이징 — 승격 없음)"
  rsync -a --dry-run "$vmpath/" "$dest/data.new/"
  exit 0
fi

# --- 1) 스테이징: 기존 사본($dest/data)에 직접 --delete 금지 ---
# 소스가 빈 상태(잘못된 PV 재바인딩·빈 카탈로그)면 --delete가 유일한 오프-SSD 사본을
# 그대로 비워버린다(침묵 유실 전파). 스테이징 → sanity → 승격(rotate)로만 반영한다.
rm -rf "$dest/data.new"
if [ -d "$dest/data" ]; then
  rsync -a --link-dest="$dest/data" "$vmpath/" "$dest/data.new/"   # 불변 파일은 hardlink(공간 절약)
else
  rsync -a "$vmpath/" "$dest/data.new/"
fi

# --- 2) 승격 전 sanity: 비어있지 않음 + 급감 가드 ---
new_count="$(find "$dest/data.new" -type f | wc -l | tr -d ' ')"
[ "$new_count" -gt 0 ] || { echo "ERROR: 스테이징 0파일($vmpath 소스 비어있음?) — 승격 중단, 기존 사본 보존. PV 재바인딩/빈 카탈로그 의심." >&2; rm -rf "$dest/data.new"; exit 1; }
if [ -d "$dest/data" ]; then
  old_count="$(find "$dest/data" -type f | wc -l | tr -d ' ')"
  if [ "$old_count" -gt 0 ] && [ $((new_count * 2)) -lt "$old_count" ] && [ "${FORCE_SHRINK:-0}" != 1 ]; then
    echo "ERROR: 파일 수 급감($old_count → $new_count, >50% 축소) — 승격 중단, 기존 사본 보존. 의도된 대량 삭제면 FORCE_SHRINK=1로 재실행." >&2
    rm -rf "$dest/data.new"; exit 1
  fi
fi

# --- 3) sha256 매니페스트: 스테이징 기준, 승격 전 생성 ('<sha> <상대경로>' — 복원 검증 입력) ---
man="$dest/files-data.$(date +%s).sha256"
: > "$man"
( cd "$dest/data.new" && find . -type f -print ) | while IFS= read -r f; do
  printf '%s %s\n' "$(sha256 "$dest/data.new/${f#./}" | awk '{print $1}')" "${f#./}" >> "$man"
done
[ -s "$man" ] || { echo "ERROR: 매니페스트 비어있음 — 승격 중단" >&2; rm -f "$man"; rm -rf "$dest/data.new"; exit 1; }

# --- 4) 승격(rotate): 직전 스냅샷 1개(data.prev) 보존 ---
rm -rf "$dest/data.prev"
if [ -d "$dest/data" ]; then mv "$dest/data" "$dest/data.prev"; fi
mv "$dest/data.new" "$dest/data"
echo "==> 승격 완료: $man (${new_count}개 파일, 직전 스냅샷 data.prev 보존, RPO=24h)"

# --- 성공/용량 메트릭 push (FilesBackupStale·FilesBulkSSDLow 게이트) ---
push_metrics() {
  local url="$1" avail size
  avail="$(df -k "$vmpath" 2>/dev/null | awk 'NR==2{print $4*1024}')"   # 외장 SSD 여유 bytes
  size="$(df -k "$vmpath" 2>/dev/null | awk 'NR==2{print $2*1024}')"    # 총량 bytes
  printf 'files_backup_last_success_timestamp %s\nfiles_data_bulk_avail_bytes %s\nfiles_data_bulk_size_bytes %s\n' \
    "$(date -u +%s)" "${avail:-0}" "${size:-0}" \
    | curl -fsS --data-binary @- "${url}/api/v1/import/prometheus"
}
if [ -n "$PUSHGW" ]; then
  push_metrics "$PUSHGW" || echo "WARN: 메트릭 push 실패($PUSHGW) — FilesBackupStale가 페이징할 것(백업 자체는 성공)" >&2
else
  # 호스트→클러스터: vmsingle는 ClusterIP라 port-forward 경유(이 Mac은 *.home 미해석).
  kubectl -n "$PF_NS" port-forward "svc/$PF_SVC" "$PF_PORT:$PF_PORT" >/dev/null 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' EXIT
  for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$PF_PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
  push_metrics "http://127.0.0.1:$PF_PORT" || echo "WARN: 메트릭 push 실패(port-forward) — FilesBackupStale가 페이징할 것(백업 자체는 성공)" >&2
fi
echo "OK: files-data 백업 완료 → $dest/data (오프-SSD 사본, RPO=24h)"
```

> 설계 노트: ① 성공 메트릭은 **승격·매니페스트 검증 후에만** push된다 — 스테이징/승격(rotate) 모델이라 빈 소스·급감 소스는 기존 사본을 건드리지 못하고(적대 리뷰 P1-1 수용), 직전 스냅샷 1개(`data.prev`)가 항상 보존된다. ② push 실패는 **비치명(WARN)** — 백업(rsync+매니페스트+승격) 성공이 1차 산출물이고, push 실패는 `FilesBackupStale`(absent/staleness) 알림이 fail-closed로 잡는다. 이는 sealing-key 백업의 `--verify` 게이트가 회전을 잡는 것과 동형(도구는 산출·알림/게이트가 강제).

**Step 4 — 게이트.**
```
chmod +x scripts/backup-files-data.sh
bats tests/gates/test_backup-files-data.bats   # 기대: 9 pass(shellcheck·스테이징 가드 포함)
make ci                                        # 기대: green
```

**Step 5 — scripts/README 등재.** `scripts/README.md`의 "## DR / owner 전용 — 파괴적" 섹션, `backup-sealed-secrets-key.sh` 항목(라인 55-58) 뒤에 추가(M10 check-doc-index 일반화는 B12 — 여기선 선제 등재로 드리프트 예방):
```
- **`backup-files-data.sh`** — **owner 전용(내구성 불변식, 비파괴)**. files-data(비재생성 사용자 데이터)를
  외장 SSD → Mac 내장 디스크로 rsync 오프-SSD 백업. `<dest>`(백업)/`--dry-run <dest>`/`--verify <dest>`
  (백업서 파일 1개 복원+sha256 대조 — 매체 판독성 게이트). dest는 반드시 내장 디스크(외장이면 거부),
  성공 시 `files_backup_last_success_timestamp`·용량을 vmsingle에 push(r4의 FilesBackupStale/FilesBulkSSDLow).
  launchd 일1회 배선(RPO=24h)은 owner-local(external-ssd.md). Makefile 배선 없음 — 직접 실행.
```

**Step 6 — 커밋.**
```
git add scripts/backup-files-data.sh tests/gates/test_backup-files-data.bats scripts/README.md
git commit -m "feat(scripts): files-data 오프-SSD rsync 백업 + 복원 스모크

매체(SSD) 유실 방어 — Retain·Prune·관측은 오삭제/침묵유실만 막는다. dest는
내장 디스크 강제(외장 사본 무의미), --verify로 백업서 파일 1개 복원+sha256 대조.
성공 시 신선도·용량 메트릭을 vmsingle에 push(restore-drill 패턴 재사용)."
```

---

### B5.5 용량/백업신선도 vmalert 룰 (호스트 push 소비)

**Files:** Modify: `platform/victoria-stack/prod/rules/r4-storage-backup.yaml`(storage-backup 그룹에 알림 2종 append), `tests/gates/test_vmalert-config.bats`(단언 추가) / Test: 기존 test_vmalert-config(gate) + vmalert-rules-validate.sh(CI 렌더 검증).

**Step 1 — 실패 테스트 작성.** `test_vmalert-config.bats`에 @test 추가(파일 끝 근처, r4 참조 패턴 미러):
```bash
@test "files off-SSD backup freshness + bulk-ssd capacity alerts are defined (host push)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  grep -q 'alert: FilesBackupStale' "$R"     # 오프-SSD 백업 신선도(백업 필수화 강제)
  grep -q 'alert: FilesBulkSSDLow' "$R"       # bulk-ssd 용량 임계
  # 주간/일간 단발 push라 bare absent()는 영구 오발화 — last_over_time 윈도로 판정(restore-drill 패턴).
  grep -q 'last_over_time(files_backup_last_success_timestamp' "$R"
}
```

**Step 2 — 실행(기대 실패).**
```
bats tests/gates/test_vmalert-config.bats   # 기대: 신규 @test FAIL(알림 미정의)
```

**Step 3 — 최소 구현.** `r4-storage-backup.yaml`의 `storage-backup` 그룹 끝(라인 119 `PgDumpHedgeStale` 블록 뒤, 파일 최하단)에 append(들여쓰기 = 기존 `- alert:` 8스페이스):
```yaml
          # files 오프-SSD 백업 생존성(H2/M14): 호스트 launchd(scripts/backup-files-data.sh, 일1회)가
          # rsync 성공 시 files_backup_last_success_timestamp를 vmsingle에 단발 import한다. instant query는
          # staleness 윈도(~분) 밖의 단발 샘플을 못 봐 bare absent()가 영구 오발화하므로(CNPGRestoreDrillStale과
          # 동형), [10d] last_over_time으로 마지막 성공을 찾아 임계(180000s≈2.08일 — 일1회 RPO의 2배 여유)로 판정.
          # 값 없음(첫 push 전)은 absent가로 fail-loud — launchd 미설치/미실행을 페이징(백업 필수화 강제).
          - alert: FilesBackupStale
            expr: |
              (time() - last_over_time(files_backup_last_success_timestamp[10d])) > 180000
              or absent(last_over_time(files_backup_last_success_timestamp[10d]))
            for: 30m
            labels: { severity: critical }
            annotations:
              summary: "files 오프-SSD 백업이 stale(≈2일 초과)이거나 없음"
              description: "files-data(비재생성 사용자 데이터)의 유일한 2차 매체(Mac 내장 디스크 rsync 사본)가 갱신되지 않았습니다 — launchd 미실행 또는 외장 SSD 미마운트. 매체 유실 시 전손 위험(R2 미사용). scripts/backup-files-data.sh를 확인하세요."
          # bulk-ssd(외장 SSD) 용량: 호스트 df를 백업 잡이 함께 push(files_data_bulk_avail/size_bytes). VM node-exporter는
          # 외장 virtiofs(/mnt/mac 하위)를 별도 series로 못 봐(r4 상단 주석) 직접 측정 불가 — 호스트 push가 유일 관측.
          - alert: FilesBulkSSDLow
            expr: |
              (files_data_bulk_avail_bytes / files_data_bulk_size_bytes) < 0.10
            for: 30m
            labels: { severity: warning, disk: bulk }
            annotations:
              summary: "외장 bulk SSD 여유 공간 10% 미만"
              description: "files-data·pg-basebackup-local이 공유하는 2TB 외장 SSD 여유가 부족합니다 — files 쓰기 실패(/readyz NotReady) 및 로컬 base-backup 적체 위험. 최대 소비자를 정리하세요."
```

> 설계 노트(오발화 방지): `FilesBulkSSDLow`는 값이 있어야 평가된다 — 첫 push 전엔 series 부재라 발화 안 함(용량은 정보성·warning). 반면 `FilesBackupStale`은 absent 가드로 첫 push 전에도 발화(백업 필수화 강제). 배포 시점 오발화를 피하려면 **launchd 설치+1회 수동 실행을 PR-5b 머지와 함께**(라이브 검증 참조).

**Step 4 — 게이트.**
```
bats tests/gates/test_vmalert-config.bats   # 기대: all pass
tests/gates/vmalert-rules-validate.sh       # 기대: r4 문법 유효(promtool/vmalert 렌더)
make ci                                     # 기대: green
```

**Step 5 — 커밋.**
```
git add platform/victoria-stack/prod/rules/r4-storage-backup.yaml tests/gates/test_vmalert-config.bats
git commit -m "feat(observability): files 백업 신선도·bulk-ssd 용량 알림(r4)

호스트 backup-files-data.sh가 push하는 files_backup_last_success_timestamp·
용량을 소비. FilesBackupStale(absent 가드 fail-closed=백업 필수화 강제) +
FilesBulkSSDLow(외장 SSD 여유 — node-exporter 사각 대체). restore-drill 윈도 패턴."
```

*(B5.4~B5.5 = PR-5b. 메트릭 producer+consumer 원자 배포.)*

---

### B5.6 dr-drill files 카탈로그 재결합 검증 (M14)

**Files:** Modify: `scripts/dr-drill.sh`(스텝 [6.5] 추가), `tests/test_dr-drill.bats`(grep 단언 추가) / Test: 기존 test_dr-drill(오프라인 grep + shellcheck).

**Step 1 — 실패 테스트 작성.** `tests/test_dr-drill.bats`에 @test 추가(기존 grep 패턴 미러):
```bash
@test "dr-drill re-attaches files data and refuses a silently-empty catalog (M14)" {
  grep -q 'rollout status deploy/files' "$sh"
  grep -q 'files-data PV 미바운드' "$sh"
  grep -q 'files 카탈로그 비어있음' "$sh"
}
```

**Step 2 — 실행(기대 실패).**
```
bats tests/test_dr-drill.bats   # 기대: 신규 @test FAIL(마커 문자열 부재)
```

**Step 3 — 최소 구현.** `dr-drill.sh`의 스텝 [6](라인 ~`kubectl -n edge rollout status deploy/adguard`) 직후, `DR DRILL PASS` echo 직전에 삽입:
```bash
echo "==> [6.5] files 데이터 재결합 검증: files pod Ready + 재바운드 PV 백킹 디렉토리 비어있지 않음(침묵 빈-복귀 모드 차단, M14)"
# 외장 SSD(virtiofs)는 VM 파괴에도 살아남지만, 동적 PV 메타데이터(etcd)는 유실된다 → 신규 PVC가 빈 디렉토리를
# 새로 파 조용히 '빈 카탈로그'로 정상 복귀할 수 있다. owner는 재부팅 후 external-ssd.md의 재결합 절차(기존 SSD
# 데이터 디렉토리에 정적 PV 바인딩)를 수행해야 하며, 이 단언이 그 수행 여부를 fail-loud로 검증한다.
kubectl -n files rollout status deploy/files --timeout=300s
FILES_VMPATH="$(kubectl get pv -o json | yq -r '.items[] | select(.spec.claimRef.namespace=="files" and .spec.claimRef.name=="files-data") | (.spec.hostPath.path // .spec.local.path // "")' | head -1)"
[ -n "$FILES_VMPATH" ] || { echo "DR DRILL FAIL: files-data PV 미바운드 — 재결합 런북(external-ssd.md) 미수행"; exit 1; }
orb -m k3s -u root env FILES_VMPATH="$FILES_VMPATH" sh -c 'test -n "$(ls -A "$FILES_VMPATH" 2>/dev/null)"' \
  || { echo "DR DRILL FAIL: files 카탈로그 비어있음($FILES_VMPATH) — 재결합이 기존 데이터를 복원하지 못함(침묵 유실 모드)"; exit 1; }
echo "    files 카탈로그 비어있지 않음 — 외장 SSD 데이터 재결합 확인"
```

**Step 4 — 게이트.**
```
bats tests/test_dr-drill.bats   # 기대: all pass(shellcheck 포함 — env-via-orb 패턴은 SC 클린)
make ci                         # 기대: green
```

**Step 5 — 커밋.**
```
git add scripts/dr-drill.sh tests/test_dr-drill.bats
git commit -m "feat(dr): dr-drill에 files 카탈로그 재결합 검증 추가

VM 파괴 후 동적 PV 메타 유실 → 신규 PVC가 빈 디렉토리로 조용히 정상복귀하는
침묵 유실 모드(M14)를 fail-loud로 차단. files pod Ready + 재바운드 PV 백킹
디렉토리 비어있지 않음을 orb 서브스트레이트 probe로 단언."
```

**Step 6 — DR 재결합 런북 갱신 지시 (owner-local, 커밋 아님 — `docs/runbooks/`는 gitignored).**
> `docs/runbooks/external-ssd.md`(또는 `restore.md`)에 "files-data 재결합" 절을 owner가 추가한다. git status에 나타나지 않으며 별도 백업 권장. 초안:
```markdown
## files-data DR 재결합 (dr-drill [6.5] 선행)
VM 파괴/재구축 후 외장 SSD의 files 데이터는 살아있으나 동적 PV 바인딩은 유실된다.
1) 기존 데이터 디렉토리 확인: `orb -m k3s -u root ls -la /mnt/mac/Volumes/homelab/k3s-bulk/ | grep files-data`
2) 정적 PV를 그 hostPath로 생성(reclaimPolicy=Retain, storageClassName=bulk-ssd, claimRef=files/files-data)
   → 신규 동적 프로비저닝을 선점해 files-data PVC가 기존 데이터에 바인딩되게 한다.
3) files-prod 재싱크 후 `kubectl -n files rollout status deploy/files` Ready 확인.
4) dr-drill [6.5]가 카탈로그 비어있지 않음을 자동 검증.

## files-data 백업 launchd 배선 (RPO=24h)
`~/Library/LaunchAgents/app.homelab.files-backup.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>app.homelab.files-backup</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>/Users/ukyi/workspace/homelab/scripts/backup-files-data.sh</string>
    <string>/Users/ukyi/homelab-backups/files-data</string>   <!-- 내장 디스크 -->
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>/Users/ukyi/Library/Logs/files-backup.log</string>
  <key>StandardErrorPath</key><string>/Users/ukyi/Library/Logs/files-backup.err.log</string>
</dict></plist>
```
설치: `launchctl load ~/Library/LaunchAgents/app.homelab.files-backup.plist`
1회 수동 실행(첫 push — FilesBackupStale 배포 오발화 방지): `scripts/backup-files-data.sh ~/homelab-backups/files-data`
주간 복원 스모크: `scripts/backup-files-data.sh --verify ~/homelab-backups/files-data`
```

*(B5.6 = PR-5c. 런북은 owner-local 후속 — PR에 미포함.)*

---

### 정적/결정론적 PV 전환: 보류 결정 유지 (설계 §2.5·§3 B5 재평가 항목)

files-data를 동적 local-path PV에서 **정적/결정론적 hostPath PV**로 전환하면 DR 재결합(B5.6)이 자동화된다(신규 클러스터도 고정 PV 이름·hostPath로 즉시 재바인딩). 그러나 **이번 캠페인에선 보류**한다. 근거: (1) 라이브 재바인딩 리스크 — 현 files-data PV(라이브 바운드, Retain, 실사용 데이터)를 정적 PV로 이행하려면 PVC 재생성·재바인딩이 필요하고 이는 실데이터 파드의 볼륨 detach/attach를 수반(단일 노드 RWO·Recreate 전략과 겹쳐 교착 위험). (2) B5.4~B5.6이 제공하는 오프-SSD 사본 + `--verify` + DR 카탈로그 단언이 "침묵 빈-복귀"를 이미 fail-loud로 차단 — 정적 PV는 재결합 *자동화*지 *안전성* 자체는 아님(수동 재결합도 안전). (3) 소비자 n=1(rule-of-two 미달). **재평가 트리거**: ① 두 번째 stateful bulk-ssd 소비자 온보딩(재결합 수동 절차가 반복 비용화), 또는 ② DR 드릴에서 B5.6 수동 재결합이 실패-취약으로 실증될 때. 그 시점에 별도 배치로 라이브 재바인딩 리허설(드릴 클러스터 선행) 후 전환.

---

### 게이트·라이브 검증

**오프라인(각 PR gate):**
```
make ci
# 기대: gate green — run-bats 전수(test_06 bulk Retain, test_backup-files-data 7건,
#        test_vmalert-config files 알림, test_dr-drill 재결합 단언 포함), chart-test, check-bats-accounting.
```

**라이브(owner-local — PR 머지 후):**
```
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig

# 1) SC 인플레이스 마이그레이션(B5.2 절차) 후 posture:
bats tests/posture/test_storage-reclaim.bats
# 기대: 2 pass — SC bulk-ssd=Retain, files-data PV=Retain.

# 2) 백업 1회 수동 실행 + 복원 스모크(FilesBackupStale 배포 오발화 방지 = 첫 push):
scripts/backup-files-data.sh ~/homelab-backups/files-data
# 기대: "OK: files-data 백업 완료 → …/data (오프-SSD 사본, RPO=24h)"
scripts/backup-files-data.sh --verify ~/homelab-backups/files-data
# 기대: "OK: --verify 통과(… 복원+sha256 일치 …)"

# 3) 메트릭 적재 확인(vmsingle):
kubectl -n observability port-forward svc/vmsingle 8428:8428 >/dev/null 2>&1 &
sleep 2
curl -s 'http://127.0.0.1:8428/api/v1/query?query=files_backup_last_success_timestamp' | grep -q '"result":\[{' && echo METRIC_OK
# 기대: METRIC_OK — series 존재(FilesBackupStale absent 가드 해소).
kill %1 2>/dev/null

# 4) 룰 발화 억제 확인(정상 상태):
# ArgoCD victoria-stack 재싱크 후 vmalert에서 FilesBackupStale/FilesBulkSSDLow = inactive.
kubectl -n observability get cm vmalert-rules-r4 -o yaml | grep -c 'FilesBackupStale\|FilesBulkSSDLow'
# 기대: 2 — 룰 배포됨.
```

### 롤백 노트

- **PR-5a(SC Retain)**: git revert 후 재머지. 라이브 인플레이스는 되돌릴 이유 없음(Retain은 안전한 방향 — 되돌려도 데이터 무손실, 신규 PV만 Delete 회귀). SC delete+recreate 절차 중 실패 시 재부트스트랩(`infra/k3s-bootstrap/apply-storage.sh` — 외장 SSD 게이트 통과 필요)로 복구.
- **PR-5b(백업+룰)**: `backup-files-data.sh`는 비파괴·additive — revert해도 라이브 무영향(launchd 미설치면 무동작). 룰 revert 시 `FilesBackupStale`/`FilesBulkSSDLow` 제거로 관측만 축소(데이터 위험 무변). launchd는 owner가 `launchctl unload`로 즉시 중단.
- **PR-5c(dr-drill)**: dr-drill.sh는 owner-manual 전용이라 라이브 상주 영향 0. 스텝 [6.5] revert는 grep 단언과 함께 되돌림.

### 다음 배치 진행 조건

- 3 PR(5a→5b→5c) 직렬 머지 완료, 각 `gate` green.
- 라이브: SC 마이그레이션 완료(posture 2 pass) + 백업 1회 실행·`--verify` 통과 + `files_backup_last_success_timestamp` series 적재 확인(FilesBackupStale inactive).
- launchd 배선 + DR 재결합 런북 갱신(owner-local — git 무추적, 완료 자기확인).
- B5는 Wave 1 내 B1~B4와 독립(공유 파일 0 — SC/files/dr-drill/r4는 다른 배치 미터치). 병렬 가능하나 라이브 검증은 배치별 직렬 권장(§7 공통 규칙).
## B6. 변이 프레임 composite화 + actor 가드 (Wave 2)

**목표** 5개 변이 디스패처의 notify 잡(≈24줄 5중 복제)과 5개 reusable의 PR-first 커밋 시퀀스(git config 봇 identity 리터럴 포함 5중 복제)를 composite 2개로 수렴하고, 경계 재검증을 `validate-mutation.ts` 재호출 단일 방식으로 통일하며, 변이 디스패처에 owner-only actor 가드를 신설한다(B11 deploy-trigger 흡수 선행 조건). 새 변이 추가 시 터치 파일 7→4로 축소.

**선행 조건**
- B1(Wave 1, `set -euo pipefail`) 머지 완료 가정 — 본 배치가 `_create-app`/`_create-cache`/`_teardown-app` 등의 파이프라인 run 스텝을 분리할 때 그 스텝의 pipefail을 새 run 스텝에 **보존**한다(아래 각 태스크가 명시적으로 재기입 — B1 선후 무관하게 멱등).
- 카나리(B6.5 이후 라이브 검증)는 **owner가 repo variable `vars.HOMELAB_OWNER`를 먼저 설정**해야 통과(actor 가드 fail-closed). 이는 owner-local 1회 셋업 — gate/bats는 스텝 존재만 구조 검증한다.

**⚠️ 설계 보정:**
- 설계 §4 B6은 pr-first-commit 시퀀스를 "5곳"이라 하나, 실측 결과 PR-first 시퀀스는 **6곳**(5 reusable + `bump-poll.yaml:77-117`)에 있다. 본 배치는 스펙대로 **5 reusable에만** 적용하고 `bump-poll`은 제외한다 — bump-poll은 actor-가드 비대상 reconciler이고 그 커밋 시퀀스는 per-app while-loop(descendant/digest 게이팅) 안에 있어 mutation-frame 경계 밖이다(향후 배치로 이월, 근거 기록).
- 설계는 pr-first-commit이 "auto-merge 선택적"이라 하나, 실측상 **update-secrets의 멱등 no-op**(`_update-secrets.yaml:65-69` `git diff --cached --quiet` 조기 종료)도 이 시퀀스에 얽혀 있다. composite에 `skip-if-empty` 입력을 추가해 흡수한다(update-secrets가 별도 no-op 블록을 버림).
- 설계 §4 B6은 "identity.ts 인라인 사본 2곳 소멸"이라 하나, 실측상 사본은 `_create-cache.yaml:43`(인라인 bun JS regex)와 `_create-database.yaml:43`(defensive `grep -Eq '{0,28}'`)의 **2곳**이 맞다. 단 `test_mutation-dispatch.bats:99-105`가 **현재 이 두 사본의 존재를 강제**하므로, 사본 제거와 함께 그 테스트를 "사본 부재 + validate-mutation 재호출 존재"로 반전해야 한다(설계 미언급 — 실측 보정).
- CONTRACT 사문행: 실측 grep 결과 `validate-mutation --action`의 활성 호출처는 create-app/create-cache/create-database/update-secrets/teardown-app(워크플로) + teardown-resource(`scripts/teardown.sh`)뿐. `activate-app`(owner-local `tools/activate-app.ts` 자체 검증)·`audit`(`audit.yaml`은 검증기 미호출) 두 행이 사문. **처분 = 제거가 아니라 주석 정정(보존)** — 근거는 B6.4에 명시.
- actor 값: repo variable은 현재 `vars.HOMELAB_DOMAIN` 하나뿐(`HOMELAB_*` 규약 확립됨). owner의 정확한 GitHub 로그인을 하드코딩하면 오기 리스크가 있어 **`vars.HOMELAB_OWNER`(fail-closed on empty)** 채택 — 기존 `vars.HOMELAB_DOMAIN` 선례와 정합, owner가 자신의 로그인을 1회 설정.

**PR 구성** (직렬 머지 — 스택 squash 함정 회피)
- **PR-6a** "refactor: 변이 notify 프레임 composite화 (mutation-notify)" — B6.1
- **PR-6b** "refactor: 변이 PR-first 프레임 composite화 + 경계 재검증 통일" — B6.2 · B6.3 · B6.4
- **PR-6c** "feat: 변이 디스패처 actor 가드 (owner-only)" — B6.5 · B6.6

---

### B6.1 mutation-notify composite + 5 디스패처 notify 수렴 + DISPATCHERS 동적 파생 (PR-6a)

**Files:**
- Create: `.github/actions/mutation-notify/action.yml`
- Modify: `.github/workflows/create-app.yaml`(notify 잡 47-71), `update-secrets.yaml`(43-66), `create-database.yaml`(97-120), `create-cache.yaml`(63-86), `teardown-app.yaml`(50-73) — 각 notify 잡의 `id: norm` run 스텝 + 인라인 telegram-notify를 composite 호출로 치환
- Modify: `tools/tests/test_mutation-dispatch.bats`(setup() 8행 + notify 테스트 77-84)
- Test: `tools/tests/test_mutation-dispatch.bats` (gate 도메인 — run-bats 자동 수집)

**Step 1 — 실패 테스트 작성.** `test_mutation-dispatch.bats`의 `setup()`(현재 6-9행)을 동적 파생으로 교체하고, notify 정규화 테스트(77-84)를 composite 위임 단언으로 반전 + 신규 단언 추가.

setup() 교체(6-9행):
```bash
setup() {
  ROOT="$(git rev-parse --show-toplevel)"; WF="$ROOT/.github/workflows"
  # 디스패처 목록 동적 파생 — 하드코딩 열거는 6번째 디스패처를 조용히 빠뜨린다(fail-open, arch-meta finding).
  # 규칙: workflow_dispatch 보유 + 동명 reusable(uses: ./.github/workflows/_<self>.yaml) 참조.
  DISPATCHERS=""
  for f in "$WF"/*.yaml; do
    base="$(basename "$f" .yaml)"
    case "$base" in _*) continue;; esac
    grep -q 'workflow_dispatch:' "$f" || continue
    grep -q "uses: ./.github/workflows/_${base}.yaml" "$f" || continue
    DISPATCHERS="$DISPATCHERS $base"
  done
}
```

`@test "each dispatcher notify normalizes status from needs (not its own job.status)"`(77-84)를 삭제하고 아래 3개로 교체:
```bash
@test "dynamic DISPATCHERS derivation is non-empty and includes the known five" {
  [ -n "$DISPATCHERS" ]
  for d in create-app update-secrets create-database create-cache teardown-app; do
    case " $DISPATCHERS " in *" $d "*) : ;; *) false ;; esac
  done
}

@test "each dispatcher notify delegates to the mutation-notify composite" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q 'uses: ./.github/actions/mutation-notify' "$f"
    run grep -nE 'results:[[:space:]]*\$\{\{[[:space:]]*toJSON\(needs\)' "$f"; [ "$status" -eq 0 ]
    # norm 로직은 composite로 이동 — 디스패처엔 job.status 직접 참조가 없어야 한다
    run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$f"; [ "$status" -ne 0 ]
  done
}

@test "mutation-notify composite normalizes cancelled over failure and labels source 변이" {
  a="$ROOT/.github/actions/mutation-notify/action.yml"
  [ -f "$a" ]
  grep -q 'status=cancelled' "$a"
  grep -q 'source: 변이' "$a"
}
```

**Step 2 — 실행(기대 실패).**
```
bats tools/tests/test_mutation-dispatch.bats
```
기대: 신규 3 테스트 실패(`mutation-notify/action.yml` 부재, 디스패처가 아직 인라인 norm 사용). `DISPATCHERS` 파생 자체는 통과(현행 5 디스패처 매치).

**Step 3 — composite 생성.** `.github/actions/mutation-notify/action.yml`:
```yaml
# mutation-notify composite — 변이 디스패처 실패/취소 알림 공통화.
# needs 결과를 정규화(취소>실패)해 telegram-notify(source=변이)로 송신 — 5개 디스패처 notify 잡이
# title 한 단어 차이로 동일했던 것을 SSOT로 수렴한다.
# 비신뢰 입력 없음: results=needs 컨텍스트(GHA 신뢰), title=디스패처 리터럴.
# telegram-notify는 중첩 composite로 호출 — 로컬 액션 경로는 워크스페이스 체크아웃 기준 해석(notify 잡이 checkout 선행).
name: mutation-notify
description: 변이 디스패처 실패/취소 알림(needs 정규화 + telegram 송신)
inputs:
  results:   { description: "toJSON(needs) — 상류 잡 결과 JSON", required: true }
  title:     { description: "한국어 제목(예: create-app 실행)", required: true }
  run-url:   { description: "액션 run 링크 URL", required: true }
  bot-token: { description: "Telegram bot token", required: true }
  chat-id:   { description: "Telegram chat id", required: true }
runs:
  using: composite
  steps:
    - id: norm
      shell: bash
      env:
        RESULTS: ${{ inputs.results }}
      run: |
        # notify 잡의 job.status는 자기 자신(success)이라 거짓 — 상류 needs로 정규화(취소>실패)
        if printf '%s' "$RESULTS" | grep -q '"result": *"cancelled"'; then
          echo "status=cancelled" >> "$GITHUB_OUTPUT"
        else
          echo "status=failure" >> "$GITHUB_OUTPUT"
        fi
    - uses: ./.github/actions/telegram-notify
      with:
        status: ${{ steps.norm.outputs.status }}
        source: 변이
        title: ${{ inputs.title }}
        link: ${{ inputs.run-url }}
        bot-token: ${{ inputs.bot-token }}
        chat-id: ${{ inputs.chat-id }}
```

**Step 4 — 5 디스패처 notify 잡 치환.** 각 파일의 notify 잡에서 `- id: norm` run 스텝 + 인라인 `- uses: ./.github/actions/telegram-notify …` 블록을 삭제하고 단일 composite 호출로 대체. `actions/checkout` 스텝은 **유지**(로컬 composite·중첩 composite가 레포 체크아웃 필요). `create-app.yaml` 예(47-71행 → 아래):
```yaml
  notify:
    needs: [validate, create-app]
    if: failure() || cancelled()
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0  # v7.0.0
      - uses: ./.github/actions/mutation-notify
        with:
          results: ${{ toJSON(needs) }}
          title: create-app 실행
          run-url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```
나머지 4개: `title:`만 각각 `update-secrets 실행`/`create-database 실행`/`create-cache 실행`/`teardown-app 실행`, `needs:`의 두 번째 잡 이름만 상이(`update-secrets`/`create-database`/`create-cache`/`teardown-app`). 나머지는 동일.

**Step 5 — 게이트 실행.**
```
bats tools/tests/test_mutation-dispatch.bats && actionlint .github/workflows/*.yaml
make ci
```
기대: bats 전건 통과(`each dispatcher notify fires on cancelled…` 70-75 포함 그대로 통과 — `if: failure() || cancelled()` 유지), actionlint clean(중첩 composite `uses:` 참조 해석 OK), `make ci` gate green.

**Step 6 — 커밋.**
```
git add .github/actions/mutation-notify/action.yml \
        .github/workflows/create-app.yaml .github/workflows/update-secrets.yaml \
        .github/workflows/create-database.yaml .github/workflows/create-cache.yaml \
        .github/workflows/teardown-app.yaml tools/tests/test_mutation-dispatch.bats
git commit -m "refactor: 변이 디스패처 notify를 mutation-notify composite로 수렴 + DISPATCHERS 동적 파생"
```

---

### B6.2 pr-first-commit composite + 5 reusable PR-first 시퀀스 수렴 (PR-6b)

**Files:**
- Create: `.github/actions/pr-first-commit/action.yml`
- Modify: `_create-database.yaml`(65-87 PR 스텝), `_create-app.yaml`(80-122 생성+PR 스텝), `_create-cache.yaml`(64-87), `_update-secrets.yaml`(51-80), `_teardown-app.yaml`(41-72)
- Modify: `tools/tests/test_mutation-dispatch.bats`(teardown auto-merge 테스트 123-127 + 신규 auto-merge 대칭 단언)
- Test: `tools/tests/test_mutation-dispatch.bats`

**auto-merge-or-fail.sh 호출 관계(보존 계약):** create-database=`true` · create-cache=`true` · update-secrets=`true` · create-app=`false`(수동 머지) · teardown-app=`false`(파괴 수동 머지).

**Step 1 — 실패 테스트 작성.** teardown 불변식 테스트(123-127)에 composite 위임 후에도 유지되는 `auto-merge: 'false'` 단언 추가 + 5 reusable auto-merge 대칭 테이블 테스트 신설:
```bash
@test "teardown-app reusable does NOT auto-merge (destruction = manual merge)" {
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -q 'auto-merge-or-fail'"; [ "$status" -ne 0 ]
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -qE 'gh pr merge.*--auto'"; [ "$status" -ne 0 ]
  grep -qE "auto-merge:[[:space:]]*'false'" "$WF/_teardown-app.yaml"   # composite 위임 후 파괴 경계 불변식
}

@test "every mutation reusable routes its PR through the pr-first-commit composite" {
  for wf in _create-app _create-database _create-cache _update-secrets _teardown-app; do
    grep -q 'uses: ./.github/actions/pr-first-commit' "$WF/$wf.yaml"
  done
}

@test "auto-merge policy is preserved per reusable (db/cache/secrets=true, app/teardown=false)" {
  for wf in _create-database _create-cache _update-secrets; do
    grep -qE "auto-merge:[[:space:]]*'true'" "$WF/$wf.yaml"
  done
  for wf in _create-app _teardown-app; do
    grep -qE "auto-merge:[[:space:]]*'false'" "$WF/$wf.yaml"
  done
}

@test "the bot commit identity lives only in the pr-first-commit composite (no 5x literal copies)" {
  a="$ROOT/.github/actions/pr-first-commit/action.yml"
  grep -q 'ukyi-homelab-writer\[bot\]' "$a"
  # reusable 어디에도 봇 email 리터럴 사본이 없어야 한다(SSOT)
  run grep -l '293311924+ukyi-homelab-writer' "$WF"/_create-*.yaml "$WF/_update-secrets.yaml" "$WF/_teardown-app.yaml"
  [ "$status" -ne 0 ]
}
```

**Step 2 — 실행(기대 실패).** `bats tools/tests/test_mutation-dispatch.bats` → 신규 4 테스트 실패(composite 부재, reusable이 아직 인라인 git 시퀀스 사용).

**Step 3 — composite 생성.** `.github/actions/pr-first-commit/action.yml`:
```yaml
# pr-first-commit composite — writer 봇 자격으로 브랜치→커밋→PR→(선택) auto-merge.
# 5개 변이 reusable의 동일 시퀀스(봇 identity 리터럴·checkout -b·add·commit·push·gh pr create·
# auto-merge-or-fail.sh)를 SSOT로 수렴. auto-merge 여부는 입력 분기(create-app/teardown=false).
# 멱등(update-secrets): skip-if-empty=true면 staged diff 없을 때 no-op(result=noop, PR 없음).
# gh-token은 composite가 secrets 직접 접근 불가라 입력으로 받는다(writer App 토큰).
name: pr-first-commit
description: PR-first 변이 커밋(브랜치·커밋·PR·선택적 auto-merge, 멱등 no-op 지원)
inputs:
  branch:         { description: "브랜치명", required: true }
  add-paths:      { description: "git add 대상(공백 구분 pathspec)", required: true }
  commit-message: { description: "커밋 메시지(한국어 conventional)", required: true }
  pr-title:       { description: "PR 제목", required: true }
  pr-body-file:   { description: "PR 본문 파일 경로", required: true }
  auto-merge:     { description: "true면 auto-merge-or-fail.sh 호출(create-app/teardown은 false)", required: false, default: "false" }
  skip-if-empty:  { description: "true면 staged diff 없을 때 no-op(멱등 update-secrets)", required: false, default: "false" }
  gh-token:       { description: "writer App 토큰(gh/PR 인증)", required: true }
outputs:
  result:
    description: "pr(생성) | noop(멱등 무변경)"
    value: ${{ steps.commit.outputs.result }}
runs:
  using: composite
  steps:
    - id: commit
      shell: bash
      env:
        GH_TOKEN:      ${{ inputs.gh-token }}
        BRANCH:        ${{ inputs.branch }}
        ADD_PATHS:     ${{ inputs.add-paths }}
        MSG:           ${{ inputs.commit-message }}
        PR_TITLE:      ${{ inputs.pr-title }}
        PR_BODY:       ${{ inputs.pr-body-file }}
        AUTO_MERGE:    ${{ inputs.auto-merge }}
        SKIP_IF_EMPTY: ${{ inputs.skip-if-empty }}
      run: |
        set -euo pipefail
        git config user.name "ukyi-homelab-writer[bot]"
        git config user.email "293311924+ukyi-homelab-writer[bot]@users.noreply.github.com"
        # shellcheck disable=SC2086  # ADD_PATHS는 공백 구분 다중 pathspec — 의도적 분할(값은 검증된 경로)
        git add $ADD_PATHS
        # 신규(미추적) 파일은 `git diff --quiet`가 항상 0이므로 staged diff로 검사(첫 시크릿 추가도 감지)
        if [ "$SKIP_IF_EMPTY" = "true" ] && git diff --cached --quiet; then
          echo "동일 콘텐츠 — 멱등 no-op(PR 없음)"
          echo "result=noop" >> "$GITHUB_OUTPUT"
          exit 0
        fi
        git checkout -b "$BRANCH"
        git commit -m "$MSG"
        git push -u origin "$BRANCH"
        gh pr create --base main --head "$BRANCH" --title "$PR_TITLE" --body-file "$PR_BODY"
        echo "result=pr" >> "$GITHUB_OUTPUT"
        if [ "$AUTO_MERGE" = "true" ]; then
          bash scripts/auto-merge-or-fail.sh "$BRANCH"
        fi
```
(add→noop-check→checkout -b 순서 = 현행 `_update-secrets.yaml:61-73` 순서와 일치 — noop이면 브랜치 미생성.)

**Step 4 — 5 reusable 치환.** 각 reusable의 "PR 생성" 스텝을 [본문 작성 run 스텝] + [pr-first-commit composite 스텝]으로 분리. `git config`/`checkout -b`/`add`/`commit`/`push`/`gh pr create`/`auto-merge-or-fail.sh`를 composite로 이관.

`_create-database.yaml`(65-87 대체):
```yaml
      - name: PR 본문 작성 (plan.json + 체크리스트)
        run: |
          set -euo pipefail
          {
            echo "create-database 자동 생성 PR — 머지되면 ArgoCD가 cnpg-data(database NS)와 data-conn-prod(prod NS)를 싱크한다."
            echo
            echo '```json'; cat /tmp/plan.json; echo '```'
            echo; echo "### 머지 후 체크리스트"
            jq -r '.checklist[] | "- [ ] " + .' /tmp/plan.json
          } > /tmp/pr-body.md
      - name: PR-first 커밋 + auto-merge
        uses: ./.github/actions/pr-first-commit
        with:
          branch: create-database/${{ steps.spec.outputs.name }}-${{ github.run_id }}
          add-paths: platform/cnpg/prod platform/data-conn/prod
          commit-message: "feat: ${{ steps.spec.outputs.name }} 논리 DB 프로비저닝 (create-database)"
          pr-title: "feat: ${{ steps.spec.outputs.name }} DB 생성 (create-database)"
          pr-body-file: /tmp/pr-body.md
          auto-merge: 'true'
          gh-token: ${{ steps.writer.outputs.token }}
```
`_create-cache.yaml`(64-87): 동형 — `branch: create-cache/${{ steps.spec.outputs.name }}-${{ github.run_id }}`, `add-paths: platform/cache platform/data-conn docs/memory-ledger.md`, commit/pr-title는 현행 문구 유지, `auto-merge: 'true'`. 본문 문구는 현행 78-84행 유지. (ledger 게이트 `bun run verify:ledger`는 provision 스텝 54-63에 그대로 잔류 — 커밋 전 선행 검증.)

`_update-secrets.yaml`(51-80 대체): update-secrets.ts 실행과 노출 커밋을 분리, no-op은 composite `skip-if-empty`로 흡수:
```yaml
      - name: 검증 + 봉인본 복사 (main HEAD)
        env:
          APP: ${{ inputs.app }}
        run: |
          set -euo pipefail
          bun tools/update-secrets.ts --app "$APP" --repo-root . --app-repo-root .apprepo
          printf '%s\n' "update-secrets — 봉인본 검증 통과. gate 통과 시 auto-merge. (반영은 checksum annotation 롤링)" > /tmp/pr-body.md
      - name: PR-first 커밋 + auto-merge (멱등 no-op)
        id: commit
        uses: ./.github/actions/pr-first-commit
        with:
          branch: update-secrets/${{ inputs.app }}-${{ github.run_id }}
          add-paths: apps/${{ inputs.app }}/deploy/prod/${{ inputs.app }}-secrets.sealed.yaml apps/${{ inputs.app }}/deploy/prod/values.yaml apps/${{ inputs.app }}/deploy/prod/kustomization.yaml
          commit-message: "chore: ${{ inputs.app }} SealedSecret 갱신 (update-secrets)"
          pr-title: "chore: ${{ inputs.app }} 시크릿 갱신"
          pr-body-file: /tmp/pr-body.md
          auto-merge: 'true'
          skip-if-empty: 'true'
          gh-token: ${{ steps.writer.outputs.token }}
```
그리고 notify 스텝(81-92)의 `steps.rotate.outputs.result` → `steps.commit.outputs.result`로 갱신(2곳: title 87행·body 89행). `id: rotate` 소멸.

`_create-app.yaml`(80-122 대체): 렌더 게이트·verify:ledger·본문을 run 스텝에 두고(B1 pipefail 보존), 커밋은 composite(auto-merge=false):
```yaml
      - name: 생성 + 렌더 게이트 + PR 본문
        env:
          APP: ${{ steps.img.outputs.app }}
          TAG: ${{ steps.img.outputs.tag }}
          DIGEST: ${{ steps.img.outputs.digest }}
          DOMAIN: ${{ vars.HOMELAB_DOMAIN }}
        run: |
          set -euo pipefail
          [ -n "$DOMAIN" ] || { echo "::error::repo variable HOMELAB_DOMAIN 미설정"; exit 1; }
          [ -f .apprepo/.app-config.yml ] || { echo "::error::.app-config.yml 없음(앱 레포 ukyi-app/${APP}@${TAG#sha-})"; exit 1; }
          sealed_arg=""
          if [ -f ".apprepo/deploy/${APP}-secrets.sealed.yaml" ]; then
            sealed_arg="--sealed .apprepo/deploy/${APP}-secrets.sealed.yaml"
          fi
          # shellcheck disable=SC2086
          bun tools/create-app.ts --config .apprepo/.app-config.yml --app "$APP" \
            --repo "ukyi-app/$APP" --domain "$DOMAIN" --tag "$TAG" --digest "$DIGEST" $sealed_arg \
            | tee /tmp/plan.json
          helm template "$APP" platform/charts/app -f "apps/$APP/deploy/prod/values.yaml" \
            | kubeconform -strict -ignore-missing-schemas \
                -schema-location default \
                -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
                -summary
          bun run verify:ledger
          {
            echo "create-app 자동 생성 PR입니다. **머지 = 첫 배포 승인 + 공개 승인** (DNS/tunnel은 머지 후 iac.yaml이 적용)."
            echo
            echo '```json'; cat /tmp/plan.json; echo '```'
            echo; echo "### ⚠️ 머지 전 체크리스트"
            jq -r '.checklist[] | "- [ ] " + .' /tmp/plan.json
          } > /tmp/pr-body.md
      - name: PR-first 커밋 (수동 머지 — create-app 패턴)
        uses: ./.github/actions/pr-first-commit
        with:
          branch: create-app/${{ steps.img.outputs.app }}-${{ github.run_id }}
          add-paths: apps/${{ steps.img.outputs.app }} docs/memory-ledger.md infra/cloudflare/apps.json
          commit-message: "feat: ${{ steps.img.outputs.app }} 앱 생성 (create-app — digest 핀, 공개 활성화)"
          pr-title: "feat: ${{ steps.img.outputs.app }} 앱 생성 (create-app)"
          pr-body-file: /tmp/pr-body.md
          auto-merge: 'false'
          gh-token: ${{ steps.writer.outputs.token }}
```
(원 스텝의 `GH_TOKEN` env는 삭제 — gh는 composite가 담당, create-app.ts는 미사용.)

`_teardown-app.yaml`(41-72 대체): 파괴 가드 + teardown.ts + 본문(active 변수 참조)을 run 스텝에, 커밋은 composite(auto-merge=false):
```yaml
      - name: 철거 plan + PR 본문 (수동 머지)
        env:
          APP: ${{ inputs.app }}
        run: |
          set -euo pipefail   # 파괴 단계 명시 fail-closed(bun|tee 실패가 PR 생성으로 새지 않게)
          [ -d "apps/$APP" ] || { echo "::error::apps/$APP 없음 — 이미 철거됐거나 이름 오류"; exit 1; }
          active=$(jq -r --arg a "$APP" '(map(select(.name==$a)) | .[0].active) // false' infra/cloudflare/apps.json 2>/dev/null || echo unknown)
          bun tools/teardown-app.ts --app "$APP" --repo-root . | tee /tmp/plan.json
          {
            echo "teardown-app 자동 생성 PR입니다. **머지 = 철거 승인** — ArgoCD가 Application/워크로드/SealedSecret prune; active였으면 머지 후 iac.yaml이 DNS/tunnel ingress를 **자동 제거**(app 공개 DNS는 destroy 가드 allowlist라 무인 apply 허용). 별도 수동 terraform apply 불필요."
            echo
            echo "**사전 상태**: active=${active} (롤백 시 DNS 복원 필요 여부 판단)"
            echo "**롤백**: 잘못 머지하면 이 PR을 git revert(또는 GitHub Revert) → apps/${APP}/(SealedSecret 포함)+apps.json 행+원장 행 복원 → ArgoCD 재생성 + (active였으면) iac DNS 재적용."
            echo
            echo '```json'; cat /tmp/plan.json; echo '```'
          } > /tmp/pr-body.md
      - name: PR-first 커밋 (auto-merge 안 함 — 파괴는 수동 머지)
        uses: ./.github/actions/pr-first-commit
        with:
          branch: teardown/teardown-app-${{ inputs.app }}-${{ github.run_id }}
          add-paths: apps docs/memory-ledger.md infra/cloudflare/apps.json platform
          commit-message: "chore: ${{ inputs.app }} 앱 철거 (teardown-app)"
          pr-title: "chore: ${{ inputs.app }} 앱 철거 (teardown-app)"
          pr-body-file: /tmp/pr-body.md
          auto-merge: 'false'
          gh-token: ${{ steps.writer.outputs.token }}
```

**Step 5 — 게이트.**
```
bats tools/tests/test_mutation-dispatch.bats tools/tests/test_update-secrets.bats && actionlint .github/workflows/*.yaml
make ci
```
기대: 전건 통과. `test_update-secrets.bats`가 result=noop/pr 신호를 grep으로 검증한다면 `steps.commit.outputs` 참조로 갱신 필요 여부 확인(현행 테스트가 reusable 문자열을 grep하면 조정).

**Step 6 — 커밋.**
```
git add .github/actions/pr-first-commit/action.yml \
        .github/workflows/_create-app.yaml .github/workflows/_create-database.yaml \
        .github/workflows/_create-cache.yaml .github/workflows/_update-secrets.yaml \
        .github/workflows/_teardown-app.yaml tools/tests/test_mutation-dispatch.bats
git commit -m "refactor: 변이 reusable PR-first 시퀀스를 pr-first-commit composite로 수렴"
```

---

### B6.3 경계 재검증 통일 (validate-mutation 재호출) (PR-6b)

**Files:** Modify: `_create-cache.yaml`(33-48 인라인 spec 스텝), `_create-database.yaml`(34-46 spec 스텝 42-44행), `_create-app.yaml`·`_update-secrets.yaml`(재검증 스텝 신설), `tools/tests/test_mutation-dispatch.bats`(99-105 인라인 regex 테스트 반전 + 대칭 재검증 테스트)

**목표:** `_create-cache` 인라인 bun JS regex(`identity.ts` 사본)를 `validate-mutation --action create-cache` 재호출로 통일(_create-database 방식), `_create-database`의 defensive `grep -Eq '{0,28}'` 사본 제거, `_create-app`/`_update-secrets`에 대칭 재검증 1스텝 추가. `identity.ts` SSOT 위반(인라인 사본 2곳) 소멸.

**Step 1 — 실패 테스트.** `@test "workflow inline name regex matches the <=30 SSOT policy (no stale copy)"`(99-105)를 삭제하고 SSOT 강제로 반전:
```bash
@test "reusables carry no inline RESOURCE_NAME_RE copy (identity.ts SSOT via validate-mutation)" {
  for wf in _create-cache _create-database; do
    run grep -Fq '{0,28}' "$WF/$wf.yaml"; [ "$status" -ne 0 ]   # 인라인 정규식 사본 소멸
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"       # 경계 재검증은 SSOT 검증기 재호출
  done
}

@test "every mutation reusable re-validates via validate-mutation at its boundary (symmetric defense-in-depth)" {
  for wf in _create-app _update-secrets _create-database _create-cache _teardown-app; do
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"
  done
}
```

**Step 2 — 실행(기대 실패).** `bats tools/tests/test_mutation-dispatch.bats` → 신규 2 테스트 실패(_create-cache 인라인 사본 잔존·`{0,28}` 존재, _create-app/_update-secrets 재검증 부재).

**Step 3 — 구현.**
- `_create-cache.yaml`: "spec 재검증" 스텝(33-48)의 인라인 `bun - <<'EOF' … EOF` 블록을 `_create-database.yaml:38-46` 패턴으로 교체 — validate-mutation 재호출 후 jq로 name/maxmemory 추출(정규식 사본 없이):
```yaml
      - name: spec 재검증 + name/maxmemory 추출 (defense-in-depth — 디스패처 외 호출 대비)
        id: spec
        env:
          SPEC: ${{ inputs.spec }} # 비신뢰 입력 — env 경유만, run 안 인라인 보간 금지
        run: |
          set -euo pipefail
          jq -n --arg action create-cache --arg spec "$SPEC" \
            '{action: $action, spec: $spec}' > /tmp/payload.json
          bun tools/validate-mutation.ts --action create-cache --payload-file /tmp/payload.json
          name=$(printf '%s' "$SPEC" | jq -r '.name')
          mm=$(printf '%s' "$SPEC" | jq -r '.maxmemory_mi // 64')
          { echo "name=$name"; echo "maxmemory=$mm"; } >> "$GITHUB_OUTPUT"
```
  (validate-mutation이 `spec.name`·`maxmemory_mi`를 이미 검증했으므로 추출값은 안전 — 동일 `$SPEC` 소스.)
- `_create-database.yaml`: 42-44행의 `name=$(…)` 다음 `printf … | grep -Eq '^[a-z]…{0,28}…'` **2줄 삭제**, `name=$(printf '%s' "$SPEC" | jq -r '.name')`만 유지(validate-mutation이 SSOT 검증). exts 추출(45-46)은 유지.
- `_create-app.yaml`: `- uses: ./.github/actions/setup-bun`(현재 56행) 직후 재검증 스텝 삽입:
```yaml
      - name: app 재검증 (경계 defense-in-depth — 디스패처 외 호출 대비)
        env:
          APP: ${{ inputs.app }}
        run: |
          set -euo pipefail
          jq -n --arg app "$APP" '{action:"create-app", app:$app}' > /tmp/mv-payload.json
          bun tools/validate-mutation.ts --action create-app --payload-file /tmp/mv-payload.json
```
- `_update-secrets.yaml`: `- uses: ./.github/actions/setup-bun`(현재 48-50행) 직후 동형 스텝 삽입(`--action update-secrets`, payload `{action:"update-secrets", app:$app}`).

**Step 4 — 게이트.**
```
bats tools/tests/test_mutation-dispatch.bats && actionlint .github/workflows/*.yaml
make ci
```
기대: 전건 통과. `test_provision-cache.bats`/`test_provision-db.bats`는 실행기 단위테스트라 무영향(경계 재검증은 워크플로 계층).

**Step 5 — 커밋.**
```
git add .github/workflows/_create-cache.yaml .github/workflows/_create-database.yaml \
        .github/workflows/_create-app.yaml .github/workflows/_update-secrets.yaml \
        tools/tests/test_mutation-dispatch.bats
git commit -m "refactor: 변이 경계 재검증을 validate-mutation 재호출로 통일(인라인 regex 사본 제거)"
```

---

### B6.4 validate-mutation CONTRACT 사문행 처분 — 주석 정정(보존) (PR-6b)

**처분 결정(실코드 근거):** `activate-app`·`audit` 두 CONTRACT 행은 활성 호출처 0(grep 실증: `--action`은 create-app/create-cache/create-database/update-secrets/teardown-app·teardown-resource만). 그러나 **제거가 아니라 주석 정정(보존)**을 택한다:
1. `tools/activate-app.ts`는 자체 게이트(validate-mutation 미참조) — `activate-app` 행은 라우팅 없는 선언적 아키타입. `audit`은 `audit.yaml` 스케줄 reconciler(검증기 미호출)로 `#59` 멀티플렉서 잔재.
2. 실제 결함은 행의 존재가 아니라 `validate-mutation.ts:15`의 **오해성 주석**("activate-app만 sha 유지" → activate-app이 이 검증기를 탄다는 오독 유발).
3. 두 행은 `test_validate-mutation.bats`(58-63·72-79)의 회귀 앵커. 제거 시 런북(gitignored, `app-platform.md` — 열람 불가)이 `--action activate-app`을 호출할 미검증 리스크가 있어 **zero-behavior-change 주석 정정이 안전**. (audit 전문가 평가도 "무해/정상".)

**Files:** Modify: `tools/validate-mutation.ts`(13-16행 주석 블록)

**Step 1 — 구현(주석만 교체).** `validate-mutation.ts`의 13-16행 주석을 아래로 교체(코드/행 무변경 — `docs:`):
```typescript
// 계약표: action → 필수 입력 (허용 입력 == 필수 입력; 그 외 비어 있지 않으면 거부)
// create-app/update-secrets는 sha를 입력으로 받지 않는다 — reusable이 앱 레포 main HEAD를
// 체크아웃해 해석한다(sha 입력은 거부). sha는 activate-app 행에만 남지만 그 액션은 이 검증기를 타지 않는다.
// ⚠️ activate-app·audit 행은 어떤 디스패처도 이 검증기로 라우팅하지 않는다(활성 호출처 0):
//   activate-app = owner-local CLI(tools/activate-app.ts 자체 검증), audit = 스케줄 reconciler(audit.yaml).
//   실제 --action 호출처는 create-app/create-cache/create-database/update-secrets/teardown-app(워크플로)
//   + teardown-resource(scripts/teardown.sh)뿐. 두 행은 선언적 아키타입 + 회귀 앵커(test_validate-mutation.bats)로만 보존한다.
// 모든 디스패처는 앱 이름만 받는다(repo는 ukyi-app/<app>로 reusable이 구성 — org는 코드에 고정).
```

**Step 2 — 검증.**
```
bun tools/validate-mutation.ts --action create-app --payload '{"app":"orders"}'   # {"ok":true,...}
bats tools/tests/test_validate-mutation.bats                                       # 전건 통과(행 유지라 무회귀)
grep -n 'activate-app만 sha 유지' tools/validate-mutation.ts || echo "오해 주석 제거 확인"
```
기대: validate-mutation 정상 출력, bats green, 오해 주석 부재.

**Step 3 — 커밋.**
```
git add tools/validate-mutation.ts
git commit -m "docs: validate-mutation CONTRACT 사문행(activate-app·audit) 미라우팅 주석 정정"
```

---

### B6.5 변이 디스패처 actor 가드 (owner-only) (PR-6c)

**목표:** actions:write 디스패치 자격은 homelab의 **모든** workflow_dispatch 진입점을 트리거할 수 있다(codex pass2 P2-1 — GitHub 권한은 워크플로 단위 스코프 불가). 따라서 가드 범위는 변이 디스패처 5개가 아니라 **workflow_dispatch 보유 워크플로 전수**이며, 허용목록은 `bump-poll` 단독(자체 fail-closed 검증기 — main reachable·descendant·digest·autoDeploy — 디스패치 자격의 의도된 유일 표적). 변이 디스패처 5개는 validate 잡 선두에 무조건 가드, 그 외 dispatch 보유 워크플로(구현 시점 전수 실측: `grep -l workflow_dispatch .github/workflows/*.yaml` — 스케줄/push 병용 워크플로 포함)는 `if: github.event_name == 'workflow_dispatch'` 한정 가드로 스케줄·push 경로 무영향. B11 deploy-trigger 흡수의 선행 조건.

**Files:** Modify: `create-app.yaml`·`update-secrets.yaml`·`create-database.yaml`·`create-cache.yaml`·`teardown-app.yaml`(각 validate 잡 `steps:` 선두) + **workflow_dispatch 보유 나머지 워크플로 전수**(구현 시점 실측, bump-poll 제외), `tools/tests/test_mutation-dispatch.bats`(actor 가드 동적 열거 테스트 신설)

**Step 1 — 실패 테스트.**
```bash
@test "every workflow_dispatch entrypoint is actor-guarded or explicitly allowlisted" {
  # 동적 열거(P2-1): 하드코딩 목록이 아니라 dispatch 보유 전수를 스캔 — 신규 워크플로 자동 편입(fail-open 차단).
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const dir = process.argv[1] + "/.github/workflows";
    const ALLOW = new Set(["bump-poll.yaml"]); // 자체 fail-closed 검증기 — 디스패치 자격의 의도된 유일 표적
    const bad = [];
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ya?ml$/.test(f)) continue;
      const src = fs.readFileSync(dir + "/" + f, "utf8");
      const doc = y.parse(src);
      const on = doc?.on ?? doc?.[true];   // 일부 YAML 파서의 on→true 키 함정 방어
      const hasDispatch = !!on && typeof on === "object" && Object.prototype.hasOwnProperty.call(on, "workflow_dispatch");
      if (!hasDispatch || ALLOW.has(f)) continue;
      const guarded = src.includes("vars.HOMELAB_OWNER") && src.includes("github.actor") && src.includes("HOMELAB_OWNER 미설정");
      if (!guarded) bad.push(f + ": workflow_dispatch 진입점에 actor 가드 부재(허용목록 아님)");
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}

@test "bump-poll stays allowlisted WITHOUT the actor guard (intended dispatch target)" {
  run grep -q 'HOMELAB_OWNER' "$WF/bump-poll.yaml"; [ "$status" -ne 0 ]
}
```

**Step 2 — 실행(기대 실패).** `bats tools/tests/test_mutation-dispatch.bats` → actor 테스트 실패(가드 부재). bump-poll/audit 음성 단언은 이미 통과.

**Step 3 — 구현.** 5개 디스패처 각각 `validate` 잡의 `steps:` **첫 스텝**(현재 checkout: create-app 27행·update-secrets 24행·create-database 52행·create-cache 31행·teardown-app 30행) 앞에 삽입:
```yaml
      - name: actor 가드 (owner 전용 변이 — bump-poll/audit는 비대상)
        env:
          ACTOR: ${{ github.actor }}
          OWNER: ${{ vars.HOMELAB_OWNER }}
        run: |
          # 변이 디스패처는 owner만 트리거 가능. 앱 레포 dispatch 자격(actions:write)이 변이까지
          # 트리거하는 표면을 차단(B11 선행 조건). vars.HOMELAB_OWNER 미설정 시 fail-closed(빈 값 거부 — vacuous 방지).
          [ -n "$OWNER" ] || { echo "::error::repo variable HOMELAB_OWNER 미설정 — actor 가드 fail-closed"; exit 1; }
          [ "$ACTOR" = "$OWNER" ] || { echo "::error::변이 디스패처는 owner($OWNER)만 실행 가능 — actor=$ACTOR 거부"; exit 1; }
```
(순수 셸 — checkout/setup-bun 불요라 선두 배치. create-database/create-cache는 assemble·validate-mutation 스텝보다 앞.)

이어서 **비-변이 dispatch 보유 워크플로 전수**(구현 시점 `grep -l workflow_dispatch .github/workflows/*.yaml`로 실측 — bump-poll 제외; 예상: audit·build 등 스케줄/push 병용)에는 첫 잡 `steps:` 선두에 **동일 블록 + 이벤트 한정 조건**을 삽입한다(스케줄·push·workflow_run 경로 무영향 — dispatch 이벤트에서만 발동):
```yaml
      - name: actor 가드 (workflow_dispatch 한정 — 스케줄/기타 트리거 무영향)
        if: github.event_name == 'workflow_dispatch'
        env:
          ACTOR: ${{ github.actor }}
          OWNER: ${{ vars.HOMELAB_OWNER }}
        run: |
          # 디스패치 자격(actions:write)은 워크플로 단위 스코프가 불가 — 허용목록(bump-poll) 외 전 진입점 가드(P2-1).
          [ -n "$OWNER" ] || { echo "::error::repo variable HOMELAB_OWNER 미설정 — actor 가드 fail-closed"; exit 1; }
          [ "$ACTOR" = "$OWNER" ] || { echo "::error::workflow_dispatch는 owner($OWNER)만 실행 가능 — actor=$ACTOR 거부"; exit 1; }
```

**설계 노트(SSOT 판단):** 5중 인라인(≈5줄×5) vs `assert-owner` composite 3번째 신설을 저울질 — 인라인 채택. 이유: (a) 보안 가드는 각 디스패처에서 가시적이라야 리뷰 가능, (b) 상단 bats가 5파일 균일성 강제(드리프트 차단), (c) 설계가 scoped한 composite는 2개(mutation-notify·pr-first-commit)뿐. 값은 하드코딩 아닌 `vars.HOMELAB_OWNER` — owner의 정확한 GitHub 로그인 오기 방지 + `vars.HOMELAB_DOMAIN` 선례 정합.

**Step 4 — 게이트.**
```
bats tools/tests/test_mutation-dispatch.bats && actionlint .github/workflows/*.yaml
make ci
```
기대: 전건 통과. `@test "each dispatcher triggers only on workflow_dispatch"`(41-46)·`@test "…references inputs only via env or with:"`(48-54)는 신규 스텝이 env 경유·비-트리거라 무회귀.

**Step 5 — 커밋.**
```
git add .github/workflows/create-app.yaml .github/workflows/update-secrets.yaml \
        .github/workflows/create-database.yaml .github/workflows/create-cache.yaml \
        .github/workflows/teardown-app.yaml tools/tests/test_mutation-dispatch.bats
# + 구현 시점 실측된 비-변이 dispatch 보유 워크플로 전수(예: audit.yaml build.yaml …)도 git add
git commit -m "feat: workflow_dispatch 진입점 actor 가드(owner-only, 허용목록=bump-poll, vars.HOMELAB_OWNER fail-closed)"
```

---

### B6.6 문서 반영 — 워크플로 인덱스 + AGENTS (PR-6c)

**Files:** Modify: `.github/workflows/README.md`(✨ 변이 섹션 마무리 문단), `AGENTS.md`(멀티레포 앱 플로우 "생성 변이" 불릿)

**Step 1 — 구현.**
- `.github/workflows/README.md`의 ✨ 변이 섹션 끝 문단("변이 로직은 동명 `_*.yaml` reusable에, 이 디스패처는 validate→route→실패 notify 셸.")을 아래로 교체:
```
전역 직렬화(`group: homelab-mutation`, `queue: max`, `cancel-in-progress: false`)로 bump-poll/iac/tf-reconcile과 한 줄로 직렬 실행. 변이 로직은 동명 `_*.yaml` reusable에, 이 디스패처는 **actor 가드(owner-only, `vars.HOMELAB_OWNER`)→validate→route→실패 notify(`.github/actions/mutation-notify`)** 셸. reusable의 PR-first 커밋은 `.github/actions/pr-first-commit`(브랜치·커밋·PR·선택적 auto-merge) 공통 사용. ⚠️ actor 가드는 `vars.HOMELAB_OWNER` 미설정 시 fail-closed — owner 로그인을 repo variable로 1회 설정해야 변이 실행 가능.
```
- `AGENTS.md`의 "생성 변이:" 불릿에 한 절 추가 — "owner가 homelab에서 액션별 디스패처(workflow_dispatch) 실행" 뒤에 " (변이 디스패처는 `vars.HOMELAB_OWNER` actor 가드로 owner 전용 — bump-poll/audit reconciler는 비대상)" 삽입.

**Step 2 — 검증.**
```
grep -q 'mutation-notify' .github/workflows/README.md && grep -q 'pr-first-commit' .github/workflows/README.md && grep -q 'HOMELAB_OWNER' .github/workflows/README.md && echo OK
grep -q 'HOMELAB_OWNER' AGENTS.md && echo OK
make verify   # skeleton/README 인덱스 게이트 무회귀 확인
```
기대: 두 OK, `make verify` green.

**Step 3 — 커밋.**
```
git add .github/workflows/README.md AGENTS.md
git commit -m "docs: 변이 프레임 composite·actor 가드 워크플로 인덱스/AGENTS 반영"
```

---

### 게이트·라이브 검증

**게이트(각 PR 머지 전, `make ci` = gate 재현):**
```
make ci
# 기대: bun typecheck · verify:ledger · audit-orphans --ci · check-skeleton · run-bats(전 CI-safe bats, test_mutation-dispatch/test_validate-mutation 포함) · shellcheck · sops-guard 전부 green
actionlint .github/workflows/*.yaml
# 기대: 중첩 composite(mutation-notify→telegram-notify) uses: 참조 해석 OK, 신규 스텝 shellcheck(SC2086 disable 처리) clean
bats tools/tests/test_mutation-dispatch.bats tools/tests/test_validate-mutation.bats
# 기대: DISPATCHERS 동적 파생 5, composite 위임·auto-merge 대칭·actor 가드·인라인 사본 부재·재검증 대칭 전건 pass
```
bats accounting: 신규 테스트는 전부 기존 `test_mutation-dispatch.bats`에 추가(신규 `.bats` 파일 0) → `check-bats-accounting.sh` 무변경. 신규 composite 2·action.yml은 `.bats` 아님(gate 도메인 영향 없음).

**라이브 카나리(3 PR 전부 머지 후 — 비파괴 update-secrets):**
```
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
# 0) 선행: owner가 repo variable 설정(1회) — actor 가드 fail-closed 해소
gh variable set HOMELAB_OWNER --body '<owner-github-login>'   # git user.name=ukkiee 참조, 정확 로그인 확인 필수
gh variable get HOMELAB_OWNER   # 값 확인(공백 아님)
# 1) 안정 앱(예: files — 커밋된 SealedSecret 보유, 업스트림 봉인본 무변경)에 update-secrets 재실행
gh workflow run "✨ update-secrets" -f app=files
# 2) 관찰(owner가 트리거 → actor 가드 통과)
run=$(gh run list --workflow=update-secrets.yaml -L1 --json databaseId -q '.[0].databaseId')
gh run watch "$run" --exit-status
```
기대 결과:
- actor 가드 통과(owner 트리거) → validate(재검증) 통과 → reusable rotate.
- 업스트림 봉인본 무변경 → `pr-first-commit`이 `skip-if-empty` no-op → `result=noop` → **PR 미생성**, reusable telegram 알림 "변경 없음(동일 봉인본)".
- 실패 시에만 dispatcher `mutation-notify` 발화(정상 경로는 미발화). 이로써 mutation-notify(중첩 composite)·pr-first-commit(멱등 no-op)·actor 가드·경계 재검증을 1회 라이브로 관통 검증.
- 음성 검증(선택, owner가 아닌 계정 접근 가능 시): 비-owner 트리거 → actor 가드 스텝에서 `::error::…owner…만 실행 가능` + validate 실패로 reusable 미실행.

**중첩 composite 리스크 확인:** `mutation-notify`가 로컬 `./.github/actions/telegram-notify`를 `uses:`하는 것은 GHA 중첩 composite(GA 지원)로 워크스페이스 체크아웃 기준 경로 해석 — 레포 내 선례는 없다(실측 `.github/actions/*/action.yml`에 `uses: ./` 0건). actionlint가 참조 유효성을 정적 검증하고, 카나리 실패-경로(강제 실패 주입 불필요 — 위 노op은 성공 경로라 mutation-notify 미발화)로는 커버 안 되므로 **별도 강제-실패 스모크 권장**: 임시 브랜치에서 create-cache를 잘못된 spec(예약 이름)으로 dispatch → validate 실패 → dispatcher notify(mutation-notify→telegram) 발화 확인. 실패 시 fallback = mutation-notify에서 `sh "$GITHUB_ACTION_PATH/../telegram-notify/notify.sh"` 직접 호출(동일 notify.sh SSOT 재사용, 중첩 composite 회피).

### 롤백 노트
- 각 PR은 독립 revert 가능(직렬 머지). PR-6a/6b는 순수 구조 리팩토링(behavior-preserving) — revert 시 인라인 사본으로 복귀, 라이브 무영향(composite는 additive, 변이 산출물 동일).
- PR-6c(actor 가드) revert 또는 즉시 완화: `vars.HOMELAB_OWNER` 삭제 시 **fail-closed로 전 변이 차단**됨(빈 값 거부) — 가드를 끄려면 변수 삭제가 아니라 PR revert. 오설정(로그인 오기)로 owner가 잠기면 repo variable 수정만으로 즉시 복구(코드 배포 불요).
- pr-first-commit 회귀 의심 시 `auto-merge` 입력 오분기 확인(db/cache/secrets=true, app/teardown=false — bats가 강제). teardown 파괴 경계는 `auto-merge: 'false'` 단언으로 이중 고정.

### 다음 배치 진행 조건
- 3 PR 전부 gate green + 직렬 머지 완료.
- 라이브 카나리(update-secrets no-op) + 강제-실패 스모크(mutation-notify 발화) 둘 다 확인 → 중첩 composite·pr-first-commit·actor 가드 관통 검증 완료.
- `vars.HOMELAB_OWNER` 설정·검증 완료(actor 가드 활성).
- 이 조건 충족이 **B11(deploy-trigger 흡수)의 선행 조건** — actor 가드가 dispatch 자격의 변이 트리거 표면을 차단해야 B11의 per-repo dispatch 시크릿 유지가 권한 상승 중립이 된다.
## B7. 실행 체계 경계 — ledger bun 단일화·lib 추출·python 제거 (Wave 2)

⚠️ 설계 보정 (실측):
- 설계 §4 B7의 "`tools/lib/ledger-totals.ts` parseLedgerRows 단일 파서 SSOT"는 **이미 절반 완료** 상태다 — `parseLedgerRows`/`addRow`/`removeRow`/`replaceTotals`는 `tools/lib/ledger-totals.ts`에 실재하고 create-app.ts:10·provision-cache.ts:17이 이미 소비한다. 잔여 작업 실측: ① `scripts/ledger-to-json.sh`(awk **제3 파서**) bun 이관, ② teardown-app.ts:36-50 인라인 **제2 파서** 제거(빈 줄 잔류 버그 — 감사에서 재현 확인), ③ `LEDGER_ROW_RE` env 클래스 확장(현재 `([a-z-]+)` — ledger-totals.ts:17, 숫자 포함 namespace 행이 TS 쪽만 침묵 드랍=예산 게이트 fail-open), ④ 예산 게이트 12줄 사본 수렴(create-app.ts:100-110 ↔ provision-cache.ts:61-73 — 설계 인용 라인과 실파일 일치 확인).
- `lib/cli.ts` `parseFlags`도 이미 존재(8/16 도구 채택, `test_cli-flag-guard.bats` 강제) — B7은 **신규 파서 제작이 아니라** typed accessor 추가 + 미채택 2곳(activate-app.ts:21-28·verify-db-marker.ts:15-21, 미지 플래그 침묵 수용) 이주다. 부수: provision-db.ts:33이 파싱 오류에 exit 1(형제들은 2) — 규약 정렬에 포함.
- `check-resource-limits.sh`에 GOMEMLIMIT 검사는 **아직 없음**(B2 미착수 시점 실측). verify:ledger 배선 실측: `package.json` → `scripts/verify-ledger.sh` → `scripts/ledger-to-json.sh`+conftest. 직접 호출 bats 3개(`tools/tests/test_ledger-gate.bats:15`·`tests/test_ledger.bats:4,13`·`tests/gates/test_verify-ledger-ssot.bats:11)도 동반 갱신 대상.

**목표** 원장 파이프라인(markdown→awk→JSON→rego 4-기술 관통)을 bun 단일 파서로 수렴하고, 게이트 언어를 셸(라인 지향)·TS(계약·계산) 2원으로 성문화하며, 내장 python3·인라인 파서 사본·미지-플래그 침묵 수용을 제거한다.

**선행 조건** Wave 1(B1~B5) 머지. 특히:
- **B2 순서 정합(스펙 교차 확인 결과)**: GOMEMLIMIT ≤ limit×0.95 검사는 **정확히 한쪽에서만 구현**한다. 기본 가정 = B2(Wave 1)가 먼저 셸(내장 python 블록)에 추가 + bats 케이스 동반 → B7.3이 TS로 1:1 이식(메시지 동일, B2의 bats는 인보케이션만 교체·단언 불변 = 이식 계약). 만약 일정상 B7이 B2보다 먼저 머지되면 B2 잔여분은 `tools/check-resource-limits.ts`에 직접 추가한다. 셸·TS 이중 구현 금지.
- B3의 bats 단언 스타일 lint 준수: 신규 bats는 중간 단언 `[ ]`만, 부정은 `run`+status.

**PR 구성** (직렬 머지 — 스택 아님, 상호 파일 겹침은 AGENTS.md:15 카운트 라인뿐):
- **PR-7a** "refactor: 원장 파이프라인 bun 단일 파서화 — ledger-to-json 이관·ledger-budget lib·teardown-app 빈 줄 버그"
- **PR-7b** "refactor: check-resource-limits 내장 python3 제거 — bun/TS 게이트 이관"
- **PR-7c** "refactor: CLI typed accessor·종료코드 규약 + 새 코드 배치 규칙 성문화"

### B7.1 ledger-to-json bun 이관 + LEDGER_ROW_RE env 클래스 확장 (PR-7a)

**Files:**
- Create: `tools/ledger-to-json.ts`, `tools/tests/test_ledger-to-json.bats`
- Modify: `tools/lib/ledger-totals.ts:17`, `scripts/verify-ledger.sh:2,7`, `tools/tests/test_ledger-gate.bats:15`, `tests/test_ledger.bats:4,13`, `tests/gates/test_verify-ledger-ssot.bats:11`, `tools/tests/test_ledger-totals.bats`(env 회귀 1건 추가), `scripts/README.md:27-28`, `tools/README.md`("정적 감사" 섹션), `AGENTS.md:15`
- Delete: `scripts/ledger-to-json.sh`
- Test: 신규 bats + 기존 ledger bats 3개

**Step 1** — 실패 테스트 작성. `tools/tests/test_ledger-to-json.bats`:

```bash
#!/usr/bin/env bats
# ledger-to-json bun 이관 — conftest 입력 JSON 형식 고정(구 awk 출력과 바이트 동일 계약).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TOOL="$ROOT/tools/ledger-to-json.ts"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "fixture ledger renders the exact legacy JSON shape (snapshot)" {
  cat > "$TMP/ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=1024 LIMIT_BUDGET_MIB=512 -->
| <!-- ledger:row --> aaa            | prod           |     10 |       20 |
| <!-- ledger:row --> k3s+os+coredns | kube-system    |     30 |       40 |
EOF
  run bun "$TOOL" "$TMP/ledger.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"budget":512,"rows":[{"component":"aaa","req":10,"limit":20},{"component":"k3s+os+coredns","req":30,"limit":40}]}' ]
}

@test "row with a digit-bearing namespace is not silently dropped (env class regression)" {
  cat > "$TMP/ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=1024 LIMIT_BUDGET_MIB=512 -->
| <!-- ledger:row --> aaa | pg18 | 10 | 20 |
EOF
  run bun "$TOOL" "$TMP/ledger.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"component":"aaa"'
}

@test "missing LIMIT_BUDGET_MIB meta fails loud (awk emitted malformed JSON instead)" {
  printf '| <!-- ledger:row --> aaa | prod | 10 | 20 |\n' > "$TMP/ledger.md"
  run bun "$TOOL" "$TMP/ledger.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'LIMIT_BUDGET_MIB'
}

@test "real ledger output passes the conftest budget policy end-to-end" {
  cd "$ROOT" || exit 1
  bun tools/ledger-to-json.ts docs/memory-ledger.md > "$TMP/ledger.json"
  run conftest test "$TMP/ledger.json" --policy policy/ledger.rego
  [ "$status" -eq 0 ]
}
```

`tools/tests/test_ledger-totals.bats` 말미에 추가:

```bash
@test "parseLedgerRows accepts a digit-bearing env (namespace class regression)" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const rows = m.parseLedgerRows("| <!-- ledger:row --> aaa | pg18 | 10 | 20 |\n");
      if (rows.length !== 1 || rows[0].env !== "pg18") { console.error(JSON.stringify(rows)); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}
```

**Step 2** — 실행: `bats tools/tests/test_ledger-to-json.bats tools/tests/test_ledger-totals.bats` → 기대: 신규 4건 전부 실패(도구 부재), env 회귀 실패(`env !== "pg18"` — 현 클래스가 숫자 불허).

**Step 3** — 최소 구현.
① `tools/lib/ledger-totals.ts:17`의 `*\| *([a-z-]+) *\|`를 `*\| *([a-z0-9-]+) *\|`로 교체(그 위 15-16행 주석에 "env 클래스는 숫자 허용 — 숫자 namespace 행 침묵 드랍=예산 과소합산 fail-open 방지" 1줄 추가).
② `tools/ledger-to-json.ts` 생성:

```ts
// 메모리 원장 → conftest 입력 JSON 변환기 — 행 파서 SSOT는 lib/ledger-totals.parseLedgerRows.
// 구 scripts/ledger-to-json.sh(awk 제3 파서)를 대체 — 출력 형식 100% 동일
// ({"budget":N,"rows":[{"component","req","limit"},…]}), 소비자는 scripts/verify-ledger.sh(conftest).
// awk와 달리 LIMIT_BUDGET_MIB 부재 시 기형 JSON 대신 fail-loud(exit 1).
import { readFileSync } from "node:fs";
import { parseLedgerRows } from "./lib/ledger-totals.ts";

const file = process.argv[2] ?? "docs/memory-ledger.md";
const text = readFileSync(file, "utf8");
const budget = Number(text.match(/LIMIT_BUDGET_MIB=(\d+)/)?.[1]);
if (!Number.isFinite(budget)) {
  console.error(`ledger-to-json: LIMIT_BUDGET_MIB 메타를 찾지 못함: ${file}`);
  process.exit(1);
}
const rows = parseLedgerRows(text).map((r) => ({ component: r.name, req: r.reqMi, limit: r.limitMi }));
console.log(JSON.stringify({ budget, rows }));
```

**Step 4** — 동치 검증(dev 전용, 삭제 전 1회 — 커밋 안 함):
`diff <(scripts/ledger-to-json.sh docs/memory-ledger.md) <(bun tools/ledger-to-json.ts docs/memory-ledger.md)` → 기대: 무출력(현 16행 원장에서 바이트 동일). 차이가 나오면 삭제 중단하고 원인(awk 관용 수용 행) 규명.

**Step 5** — 배선 교체 + 구본 삭제:
- `scripts/verify-ledger.sh:7`의 `"$ROOT/scripts/ledger-to-json.sh" "$ROOT/docs/memory-ledger.md" > /tmp/ledger.json`을 `bun "$ROOT/tools/ledger-to-json.ts" "$ROOT/docs/memory-ledger.md" > /tmp/ledger.json`으로 교체(2행 헤더 주석의 "ledger 마크다운을 JSON으로 변환" 뒤에 "— 변환은 bun(tools/ledger-to-json.ts, 행 파서 SSOT=lib/ledger-totals.ts)" 추가).
- `tests/gates/test_verify-ledger-ssot.bats:11` `grep -q 'ledger-to-json.sh'` → `grep -q 'ledger-to-json.ts'`.
- `tools/tests/test_ledger-gate.bats:15`·`tests/test_ledger.bats:4,13`의 `scripts/ledger-to-json.sh` → `bun tools/ledger-to-json.ts`.
- `git rm scripts/ledger-to-json.sh`.
- `scripts/README.md:27-28` `ledger-to-json.sh` 불릿을 다음으로 교체:

```markdown
- **`verify-ledger.sh`** — 메모리 원장 예산 게이트 SSOT: `bun tools/ledger-to-json.ts`(행 파서 SSOT =
  `tools/lib/ledger-totals.ts`)로 JSON을 만들어 `conftest test … policy/ledger.rego`로 검사.
  **`bun run verify:ledger`**·`make verify`·`ci.yaml`(gate)이 호출. 라이브 무관.
```

- `tools/README.md` "## 정적 감사 (읽기 전용)"의 audit-orphans 불릿 아래 추가:

```markdown
- **`ledger-to-json.ts`** — `docs/memory-ledger.md` 표 → conftest 입력 JSON(행 파서 SSOT=`lib/ledger-totals.ts`).
  `scripts/verify-ledger.sh`(= `bun run verify:ledger`, gate)가 호출. 라이브 무관.
```

- `AGENTS.md:15` "top-level 16개" → "top-level 17개".

**Step 6** — 게이트: `bats tools/tests/test_ledger-to-json.bats tools/tests/test_ledger-totals.bats tools/tests/test_ledger-gate.bats tests/test_ledger.bats tests/gates/test_verify-ledger-ssot.bats` 전부 green → `make ci` green(특히 `bun run verify:ledger`·shellcheck).

**Step 7** — 커밋:
`git add tools/ledger-to-json.ts tools/lib/ledger-totals.ts scripts/verify-ledger.sh tools/tests/test_ledger-to-json.bats tools/tests/test_ledger-totals.bats tools/tests/test_ledger-gate.bats tests/test_ledger.bats tests/gates/test_verify-ledger-ssot.bats scripts/README.md tools/README.md AGENTS.md && git rm scripts/ledger-to-json.sh`
메시지: `refactor: 원장 JSON 변환 bun 이관 — awk 제3 파서 제거·parseLedgerRows SSOT·env 클래스 확장`

### B7.2 ledger-budget lib 추출 + teardown-app 인라인 파서 교체 (PR-7a)

**Files:**
- Create: `tools/lib/ledger-budget.ts`, `tools/tests/test_ledger-budget.bats`
- Modify: `tools/create-app.ts:10,100-110,188-191`, `tools/provision-cache.ts:17,61-73,326-329`, `tools/teardown-app.ts:8,34-37,44-52`, `AGENTS.md:15`(lib 6→7)
- Test: 신규 bats + 기존 `test_create-app.bats`·`test_provision-cache.bats`(예산 메시지 grep 유지 확인)·`test_ledger-totals.bats`(teardown-app import 단언 무변경 통과)

**Step 1** — 실패 테스트 작성. `tools/tests/test_ledger-budget.bats`:

```bash
#!/usr/bin/env bats
# ledger-budget lib — 예산 게이트 12줄 사본(create-app/provision-cache) 수렴 + teardown-app 빈 줄 회귀.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/tools/lib/ledger-budget.ts"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "budgetViolation flags duplicate row and over-budget with the exact gate messages" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const text = "<!-- ledger:meta LIMIT_BUDGET_MIB=100 -->\n| <!-- ledger:row --> aaa | prod | 10 | 60 |\n**합계:** req ≈ 10 Mi · limit ≈ 60 Mi\n";
      const agg = m.analyzeLedger(text);
      const dup = m.budgetViolation(agg, "aaa", 10, "hint");
      const over = m.budgetViolation(agg, "bbb", 50, "hint");
      const ok = m.budgetViolation(agg, "bbb", 40, "hint");
      if (!/aaa.*이미 있다/.test(dup)) { console.error("dup:" + dup); process.exit(1); }
      if (!/원장 예산 초과: 현재 60Mi \+ bbb 50Mi > 100Mi/.test(over)) { console.error("over:" + over); process.exit(1); }
      if (ok !== null) { console.error("ok:" + ok); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "analyzeLedger throws fail-loud when LIMIT_BUDGET_MIB meta is missing" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      try { m.analyzeLedger("no meta\n"); console.log("DID-NOT-THROW"); }
      catch { console.log("threw"); }
    });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw$"
}

@test "teardown of a middle row leaves no blank line inside the table (blank-line regression)" {
  mkdir -p "$TMP/root/docs" "$TMP/root/infra/cloudflare"
  cat > "$TMP/root/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=1024 LIMIT_BUDGET_MIB=512 -->

| component | namespace | req_mi | limit_mi |
|---|---|---:|---:|
| <!-- ledger:row --> aaa            | prod           |     10 |       20 |
| <!-- ledger:row --> bbb            | prod           |     10 |       20 |
| <!-- ledger:row --> ccc            | prod           |     10 |       20 |

**합계:** req ≈ 30 Mi · limit ≈ 60 Mi (반드시 ≤ 512 Mi 유지).
EOF
  echo "[]" > "$TMP/root/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/teardown-app.ts" --app bbb --repo-root "$TMP/root"
  [ "$status" -eq 0 ]
  run bash -c "sed -n '/ledger:row --> aaa/,/ledger:row --> ccc/p' '$TMP/root/docs/memory-ledger.md' | grep -c '^$'"
  [ "$output" = "0" ]
  grep -q 'req ≈ 20 Mi · limit ≈ 40 Mi' "$TMP/root/docs/memory-ledger.md"
  run grep -c 'ledger:row --> bbb' "$TMP/root/docs/memory-ledger.md"
  [ "$output" = "0" ]
}

@test "teardown-app no longer carries an inline ledger row parser (lib SSOT adoption)" {
  run grep -c 'matchAll' "$ROOT/tools/teardown-app.ts"
  [ "$output" = "0" ]
  grep -q 'lib/ledger-budget' "$ROOT/tools/teardown-app.ts"
}
```

**Step 2** — `bats tools/tests/test_ledger-budget.bats` → 기대: 4건 전부 실패(lib 부재 / teardown-app 빈 줄 잔류·matchAll 존재).

**Step 3** — `tools/lib/ledger-budget.ts` 구현:

```ts
// 메모리 원장 예산 게이트 공용 — create-app·provision-cache의 12줄 사본 수렴 + teardown-app 행 제거.
// 행 파서·행 조작 프리미티브는 lib/ledger-totals.ts(SSOT) — 이 모듈은 집계·게이트·합계 동반 갱신만 얹는다.
// 실패는 throw(Error) — 종료코드/프리픽스(::error:: 등)는 콜사이트 fail()이 결정한다.
import { addRow, parseLedgerRows, removeRow, replaceTotals } from "./ledger-totals.ts";

export type LedgerAgg = {
  text: string;
  rows: ReturnType<typeof parseLedgerRows>;
  names: string[];
  sumReq: number;
  sumLimit: number;
  budget: number;
};

// 원장 텍스트 → 집계(행·합계·예산). LIMIT_BUDGET_MIB 부재는 throw(fail-loud).
export function analyzeLedger(text: string): LedgerAgg {
  const rows = parseLedgerRows(text);
  const budget = Number(text.match(/LIMIT_BUDGET_MIB=(\d+)/)?.[1]);
  if (!Number.isFinite(budget) || budget <= 0) throw new Error("원장 메타(LIMIT_BUDGET_MIB)를 찾지 못함");
  return {
    text, rows,
    names: rows.map((r) => r.name),
    sumReq: rows.reduce((a, r) => a + r.reqMi, 0),
    sumLimit: rows.reduce((a, r) => a + r.limitMi, 0),
    budget,
  };
}

// 예산 게이트 — 위반 시 사유 문자열, 통과 시 null. hint는 도구별 액션 안내("resources/replicas를 줄여라" 등).
export function budgetViolation(agg: LedgerAgg, component: string, limitMi: number, hint: string): string | null {
  if (agg.names.includes(component)) return `원장에 '${component}' 행이 이미 있다`;
  if (agg.sumLimit + limitMi > agg.budget)
    return `원장 예산 초과: 현재 ${agg.sumLimit}Mi + ${component} ${limitMi}Mi > ${agg.budget}Mi — ${hint}`;
  return null;
}

// 행 추가 + Totals 프로즈 동반 갱신(쓰기 측 수렴).
export function appendRowWithTotals(agg: LedgerAgg, row: { name: string; env: string; reqMi: number; limitMi: number }): string {
  const out = addRow(agg.text, row);
  return replaceTotals(out, agg.sumReq + row.reqMi, agg.sumLimit + row.limitMi);
}

// 행 제거 + Totals 재계산 — removeRow는 줄 splice라 빈 줄이 남지 않는다(구 인라인 replace 버그 소멸).
export function removeRowWithTotals(text: string, name: string): string {
  const out = removeRow(text, name);
  const rows = parseLedgerRows(out);
  return replaceTotals(out, rows.reduce((a, r) => a + r.reqMi, 0), rows.reduce((a, r) => a + r.limitMi, 0));
}
```

콜사이트 3곳 정밀 편집:
- **create-app.ts** — :10 import를 `import { analyzeLedger, appendRowWithTotals, budgetViolation, type LedgerAgg } from "./lib/ledger-budget.ts";`로 교체(ledger-totals direct import 제거). :100-110(`const ledger = readFileSync…`부터 `if (sumLimit + limitMi > budget) fail(…)`까지)을 다음으로 교체:

```ts
const ledger = readFileSync(ledgerPath, "utf8");
let agg: LedgerAgg;
try { agg = analyzeLedger(ledger); } catch (e) { fail(e instanceof Error ? e.message : String(e)); }
const viol = budgetViolation(agg, app, limitMi, "resources/replicas를 줄여라");
if (viol) fail(viol);
const { sumReq, sumLimit, budget } = agg;
```

:188-191의 `let out = addRow(…); out = replaceTotals(…); writeFileSync(ledgerPath, out);`를 `writeFileSync(ledgerPath, appendRowWithTotals(agg, { name: app, env: "prod", reqMi, limitMi }));`로 교체(plan의 `ledger: { before: sumLimit, … }`는 무변경).
- **provision-cache.ts** — :17 import 동일 교체, :63-73을 위와 동형(단 component=`cache-${name}`, hint="maxmemory를 줄여라" — `component` 선언은 기존 :68 위치 유지), :326-329를 `writeFileSync(ledgerPath, appendRowWithTotals(agg, { name: component, env: "cache", reqMi, limitMi }));`로 교체.
- **teardown-app.ts** — :8을 `import { parseLedgerRows } from "./lib/ledger-totals.ts";` + `import { removeRowWithTotals } from "./lib/ledger-budget.ts";`로, :36-37(rowRe 정의+test)을 `plan.ledgerRow = parseLedgerRows(ledger).some((r) => r.name === app);`로, :44-52의 `if (plan.ledgerRow) { … }` 블록 내부를 `writeFileSync(ledgerPath, removeRowWithTotals(ledger, app));` 1줄로 교체.

**Step 4** — 게이트: `bats tools/tests/test_ledger-budget.bats tools/tests/test_ledger-totals.bats tools/tests/test_create-app.bats tools/tests/test_provision-cache.bats tools/tests/test_teardown.bats` green(특히 test_provision-cache.bats:114 `grep -q "예산"` 메시지 보존) → `bun run typecheck` → `make ci`. `AGENTS.md:15` "`lib/` 6개" → "`lib/` 7개".

**Step 5** — 커밋:
`git add tools/lib/ledger-budget.ts tools/create-app.ts tools/provision-cache.ts tools/teardown-app.ts tools/tests/test_ledger-budget.bats AGENTS.md`
메시지: `fix: teardown-app 원장 행 제거 빈 줄 잔류 수정 — 예산 게이트를 ledger-budget lib로 수렴`

PR-7a 오픈(`gate` 통과 → auto-merge).

### B7.3 check-resource-limits 내장 python3 → bun/TS 이관 (PR-7b)

**Files:**
- Create: `tools/check-resource-limits.ts`
- Modify: `Makefile:32`, `tests/test_resource_limits.bats`(전 케이스 인보케이션 교체 — B2 추가분 포함·단언 불변), `docs/traps.md:28`, `docs/traps-detail.md:208,213`, `scripts/verify-traps.sh:14,27`(확장자 클래스에 `ts` 추가), `policy/memory-limit-allowlist.txt:1`, `tools/README.md`, `AGENTS.md:15`(17→18)
- Delete: `scripts/check-resource-limits.sh`
- Test: `tests/test_resource_limits.bats`(기존 스위트 = 이식 계약)

**Step 0** — B2 반영분 실측: 머지된 `scripts/check-resource-limits.sh`에서 GOMEMLIMIT 검사의 위치·값 파싱·메시지 문구와 B2가 추가한 bats 케이스를 확인한다. 이하 구현의 GOMEMLIMIT 부분은 그 실측을 1:1 이식한다(메시지 문자열 동일).

**Step 1** — 테스트 이행(red). `tests/test_resource_limits.bats`를 편집: 헤더 주석의 "yq(YAML→JSON…) + python3(stdlib json) 사용. bash 3.2 호환. shellcheck clean." → "bun/TS 단일(tools/check-resource-limits.ts) — yq/python3 불요."로 교체하고, 스크립트 복사 패턴을 도구 직접 호출로 전환:
- 실트리 케이스: `run bash "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh"` → `run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "${BATS_TEST_DIRNAME}/.."`
- 픽스처 케이스 5+건(B2 추가분 포함): `mkdir -p "$tmp/scripts"` + `cp …check-resource-limits.sh "$tmp/scripts/"` 2줄 삭제, `run bash "$tmp/scripts/check-resource-limits.sh"` → `run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"`. **단언(`[ "$status" … ]`·output grep)은 한 글자도 바꾸지 않는다.**

실행: `bats tests/test_resource_limits.bats` → 기대: 전부 실패(도구 부재).

**Step 2** — `tools/check-resource-limits.ts` 구현(동작·메시지·scan-floor 동일):

```ts
// 상주 워크로드(Deployment/DaemonSet/StatefulSet) main 컨테이너 자원 가드 — cpu·memory request +
// memory limit 필수(OR policy/memory-limit-allowlist.txt 명시 allowlist) + GOMEMLIMIT ≤ memory limit×0.95(B2).
// (cpu limit은 비요구: CFS quota 유휴 throttling 회피 — 의도적 생략이 SRE 권장. initContainer 비대상.)
// 구 scripts/check-resource-limits.sh(bash+yq+python3 3언어)를 bun/TS 단일로 이관 — 메시지·scan-floor 동일.
// 원격-helm 벤더(platform/*/prod/charts/)·barman-plugin은 스캔 밖. make verify가 호출, bats가 행동 검증.
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { parseAllDocuments } from "yaml";
import { parseFlags } from "./lib/cli.ts";

let f: Record<string, string | boolean>;
try { f = parseFlags(process.argv.slice(2), { value: ["--repo-root"], bool: [] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --repo-root`); process.exit(2); }
const ROOT = typeof f["--repo-root"] === "string" ? (f["--repo-root"] as string) : ".";

const KINDS = new Set(["Deployment", "DaemonSet", "StatefulSet"]);
const KIND_RE = /^kind:[ \t]*(Deployment|DaemonSet|StatefulSet)\b/m;
const MIN_SCAN = 10;

// allowlist: '#' 주석 제거 후 'Kind/name/container' 키
const allowPath = `${ROOT}/policy/memory-limit-allowlist.txt`;
const allowed = new Set(
  existsSync(allowPath)
    ? readFileSync(allowPath, "utf8").split("\n").map((l) => l.split("#", 1)[0].trim()).filter(Boolean)
    : [],
);

const toMi = (v: string): number => (v.endsWith("Gi") ? parseInt(v) * 1024 : parseInt(v));

const files = readdirSync(`${ROOT}/platform`, { recursive: true })
  .map(String)
  .filter((p) => p.endsWith(".yaml") && !p.includes("/charts/") && !p.includes("barman-plugin"))
  .map((p) => `platform/${p}`)
  .sort();

let count = 0;
const viol: string[] = [];
for (const rel of files) {
  const text = readFileSync(`${ROOT}/${rel}`, "utf8");
  if (!KIND_RE.test(text)) continue;
  count++;
  for (const doc of parseAllDocuments(text)) {
    if (doc.errors.length) { console.error(`FAIL: YAML 파싱 실패: ${rel}: ${doc.errors[0].message}`); process.exit(1); }
    const o = doc.toJS() as any;
    if (!o || typeof o !== "object" || !KINDS.has(o.kind)) continue;
    const name = o.metadata?.name ?? "?";
    for (const c of o.spec?.template?.spec?.containers ?? []) {
      const req = c.resources?.requests ?? {};
      const lim = c.resources?.limits ?? {};
      const missing: string[] = [];
      if (!("cpu" in req)) missing.push("requests.cpu");
      if (!("memory" in req)) missing.push("requests.memory");
      if (!("memory" in lim)) missing.push("limits.memory");
      const key = `${o.kind}/${name}/${c.name}`;
      if (missing.length && !allowed.has(key)) viol.push(`  ${key} [missing: ${missing.join(",")}]  (${rel})`);
      // GOMEMLIMIT ≤ memory limit×0.95 — B2가 셸에 넣은 검사의 1:1 이식(메시지 B2 실측과 동일하게 유지)
      const gomem = (c.env ?? []).find((e: any) => e?.name === "GOMEMLIMIT")?.value;
      const gm = typeof gomem === "string" ? gomem.match(/^(\d+)MiB$/) : null;
      if (gm && "memory" in lim && Number(gm[1]) > toMi(String(lim.memory)) * 0.95)
        viol.push(`  ${key} [GOMEMLIMIT ${gomem} > limits.memory ${lim.memory}×0.95]  (${rel})`);
    }
  }
}

// scan-floor: 셀렉터 붕괴 false-green 차단(fail-loud) — 구본과 동일 임계·메시지
if (count < MIN_SCAN) {
  console.error(`FAIL: 스캔 대상 ${count}건 < ${MIN_SCAN} — 셀렉터 회귀 의심(platform 재배치/kind 들여쓰기?)`);
  process.exit(1);
}
if (viol.length) {
  console.log(`FAIL: cpu·memory request 또는 memory limit 없는 상주 워크로드 main 컨테이너 — 선언 후 (memory는) 원장 행 동반, 또는 policy/memory-limit-allowlist.txt에 이유와 함께 등재:`);
  for (const v of viol) console.log(v);
  process.exit(1);
}
console.log(`check-resource-limits OK (${count} 워크로드 매니페스트 스캔, cpu·memory request + memory limit 위반 0)`);
```

(GOMEMLIMIT 분기 문구·형식은 Step 0 실측이 우선 — B2 bats의 grep 단언이 그대로 통과해야 한다.)

**Step 3** — 배선·원장 갱신:
- `Makefile:32` `@bash scripts/check-resource-limits.sh` → `@bun tools/check-resource-limits.ts`
- `git rm scripts/check-resource-limits.sh`
- `docs/traps.md:28`·`docs/traps-detail.md:208,213`의 `` `scripts/check-resource-limits.sh` `` → `` `tools/check-resource-limits.ts` ``
- `scripts/verify-traps.sh:14,27` 확장자 클래스 `\.(bats|sh|rego|mjs|ya?ml|json)$` → `\.(bats|sh|rego|mjs|ts|ya?ml|json)$` (원장이 가리키는 `.ts` 가드도 실재 검사 대상으로 — 미확장 시 traps 행이 침묵 비검사)
- `policy/memory-limit-allowlist.txt:1` 헤더의 `check-resource-limits.sh` → `check-resource-limits.ts`
- `tools/README.md` "정적 감사" 섹션 추가:

```markdown
- **`check-resource-limits.ts`** — 상주 워크로드 main 컨테이너 cpu·memory request + memory limit
  (+GOMEMLIMIT ≤ limit×0.95) 가드. **`make verify`**가 호출, `tests/test_resource_limits.bats`(gate)가
  행동 검증. `--repo-root`로 픽스처 트리 스캔. 라이브 무관.
```

- `AGENTS.md:15` "top-level 17개" → "top-level 18개"

**Step 4** — 게이트: `bats tests/test_resource_limits.bats` green(위반 0 + scan-floor + allowlist + B2 GOMEMLIMIT 케이스) → `make verify` green → `make verify-traps` → 기대 `verify-traps: 원장 guard 실재 + SSOT 가드주석↔원장 일치 OK` → `make ci` green(shellcheck 대상에서 .sh 1개 제거됨).

**Step 5** — 커밋:
`git add tools/check-resource-limits.ts Makefile tests/test_resource_limits.bats docs/traps.md docs/traps-detail.md scripts/verify-traps.sh policy/memory-limit-allowlist.txt tools/README.md AGENTS.md && git rm scripts/check-resource-limits.sh`
메시지: `refactor: check-resource-limits 게이트 bun/TS 이관 — 내장 python3 제거(게이트 언어 2원화)`

PR-7b 오픈(PR-7a 머지 후 — AGENTS.md:15 충돌 회피 직렬).

### B7.4 cli.ts typed accessor + activate-app·verify-db-marker 이주 + 종료코드 규약 (PR-7c)

**Files:**
- Modify: `tools/lib/cli.ts`, `tools/activate-app.ts:21-31,76,96,117`, `tools/verify-db-marker.ts:15-24`, `tools/provision-db.ts:33`, `tools/tests/test_cli-flag-guard.bats`
- Test: `test_cli-flag-guard.bats` 추가 케이스 + 기존 `test_activate-app.bats`·`test_verify-db-marker.bats`·`test_provision-db.bats` 무변경 green

**Step 1** — 실패 테스트: `tools/tests/test_cli-flag-guard.bats` 말미에 추가 + 기존 "migrated mutators import the shared parseFlags" 루프 목록에 `activate-app verify-db-marker` 2개 추가:

```bash
@test "activate-app rejects an unknown flag with usage exit code 2" {
  run bun tools/activate-app.ts --app orders --sha deadbee --synced-rev deadbee --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "verify-db-marker rejects an unknown flag with usage exit code 2" {
  run bun tools/verify-db-marker.ts --name shared --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "provision-db exits 2 on flag-parse errors (exit-code convention alignment)" {
  run bun tools/provision-db.ts --bogus x
  [ "$status" -eq 2 ]
}

@test "cli.ts documents the shared exit-code convention" {
  grep -q "종료코드 규약" tools/lib/cli.ts
}
```

실행: `bats tools/tests/test_cli-flag-guard.bats` → 기대: 신규 4건 실패(현재 activate-app은 `--bogus`를 침묵 수용해 게이트 단계까지 진행, provision-db는 exit 1).

**Step 2** — 구현.
① `tools/lib/cli.ts` 말미에 추가:

```ts
// 종료코드 규약(tools/*.ts 공통):
//   0=성공 · 1=검증/게이트 실패(fail()) · 2=사용법/플래그 파싱 오류(parseFlags catch) · 3=race(전제 상태
//   변동 — bump-tag expect-current). 워크플로는 비-0만 보지만 래퍼/사람이 원인 계층을 구분하도록 유지한다.
export type TypedFlags = {
  str: (k: string, d?: string) => string | undefined;
  bool: (k: string) => boolean;
};

// typed accessor — 콜사이트마다 복제되던 `const arg = (k,d)=>…` 헬퍼의 수렴형.
// 파싱 실패는 parseFlags와 동일하게 throw — 콜사이트가 usage 출력 + exit 2로 처리한다.
export function typedFlags(argv: string[], spec: FlagSpec): TypedFlags {
  const out = parseFlags(argv, spec);
  return {
    str: (k, d) => (typeof out[k] === "string" ? (out[k] as string) : d),
    bool: (k) => out[k] === true,
  };
}
```

② `tools/activate-app.ts` :21-31(수제 argv 루프 + `const { app, sha, syncedRev } = args;` + repoDir)을 다음으로 교체하고 import에 `typedFlags, type TypedFlags`(`./lib/cli.ts`) 추가:

```ts
// typedFlags: 미지 플래그 침묵 수용(예: --filp 오타 → 플립 없이 exit 0) 차단. 파싱=2 / 게이트 실패=1(규약).
let f: TypedFlags;
try {
  f = typedFlags(process.argv.slice(2), {
    value: ["--app", "--sha", "--synced-rev", "--repo-dir", "--status-file"],
    bool: ["--flip"],
  });
} catch (e) {
  console.error(`${e instanceof Error ? e.message : String(e)}\nusage: activate-app --app <name> --sha <merge-sha> --synced-rev <rev> [--repo-dir <dir>] [--status-file <json>] [--flip]`);
  process.exit(2);
}
const app = f.str("--app");
const sha = f.str("--sha");
const syncedRev = f.str("--synced-rev");
const repoDir = path.resolve(f.str("--repo-dir") ?? ".");
const statusFile = f.str("--status-file");
const flip = f.bool("--flip");
```

후속 참조 치환: :76 `args.statusFile` → `statusFile`(2회), :96 `args.flip` → `flip`, :117 `Boolean(args.flip)` → `flip`.
③ `tools/verify-db-marker.ts` :15-24(수제 루프+name/ns)를 다음으로 교체(import에 `typedFlags, type TypedFlags` 추가):

```ts
// typedFlags: 미지 플래그 침묵 수용(--namespcae 오타 → 기본 ns 무성 진행) 차단. 파싱 오류=exit 2(규약).
let f: TypedFlags;
try { f = typedFlags(process.argv.slice(2), { value: ["--name", "--namespace"], bool: [] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\nusage: verify-db-marker --name <db> [--namespace database]`); process.exit(2); }
const name = f.str("--name");
const ns = f.str("--namespace", "database")!;
```

④ `tools/provision-db.ts:33`의 `catch (e) { fail(e instanceof Error ? e.message : String(e)); }`를 형제 규약으로 교체: `catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --name --extensions --cluster --repo-root --dry-run`); process.exit(2); }`

**Step 3** — 게이트: `bats tools/tests/test_cli-flag-guard.bats tools/tests/test_activate-app.bats tools/tests/test_verify-db-marker.bats tools/tests/test_provision-db.bats` green + `bun run typecheck` + `make ci`.

**Step 4** — 커밋:
`git add tools/lib/cli.ts tools/activate-app.ts tools/verify-db-marker.ts tools/provision-db.ts tools/tests/test_cli-flag-guard.bats`
메시지: `refactor: parseFlags typed accessor 도입·activate-app/verify-db-marker 이주 — 종료코드 규약 명문화`

### B7.5 '새 코드 배치 규칙' CONTRIBUTING 성문화 (PR-7c)

**Files:** Modify: `CONTRIBUTING.md`(:26 `## 커밋 메시지` 섹션 바로 앞에 삽입)

**Step 1** — 초안 전문 삽입:

```markdown
## 새 코드 배치 규칙 — 셸 vs TS (게이트 언어 2원화)

게이트·도구가 bash+yq+python3처럼 한 파일 안에서 언어를 넘나들면 typecheck·lint·테스트가
전부 사각이 된다(구 `check-resource-limits.sh` 사례). 새 코드는 아래 기준으로 배치한다:

- **셸(`scripts/*.sh`)** — 라인 지향 검사(grep/yq/jq 필터, 파일 존재·인덱스 대조), 라이브 클러스터
  운영 절차(kubectl/argocd), 시크릿 봉인 파이프(kubeseal/sops stdin — 평문 비기록).
  bash 3.2 호환 + shellcheck clean 필수.
- **TS(`tools/*.ts`, bun 전용)** — 계약 검증(스키마·비즈니스 규칙), 구조 데이터 순회·계산
  (JSON/YAML 파싱·합산·레지스트리 조작), 산출물 생성. `bun run typecheck`에 자동 편입.
  공용 로직은 `tools/lib/`(SSOT) — 콜사이트 인라인 사본 금지(원장 행 파서 3벌 독립 구현 사례).
- **금지** — 셸 heredoc으로 python/node 등 제3 언어 내장(typecheck 사각), 같은 검사의 셸·TS
  이중 구현(원장 awk↔TS 파서 드리프트 사례 — 파서·계산은 TS 한 곳에만).
- **워크플로 인라인 셸 최소화** — run 스텝이 ~20줄을 넘거나 JSON/YAML 구조 파싱을 시작하면
  `tools/*.ts`(또는 `scripts/*.sh`)로 내려 테스트를 붙인다(bump-poll while-loop이 제4계층으로
  자라는 중 — 경계 사례로 기록).
- **종료코드 규약(tools 공통)** — `tools/lib/cli.ts` 주석이 SSOT: 0=성공 · 1=검증/게이트 실패 ·
  2=사용법/플래그 파싱 · 3=race.
```

**Step 2** — 검증: `grep -q '새 코드 배치 규칙' CONTRIBUTING.md && grep -q '게이트 언어 2원화' CONTRIBUTING.md` → exit 0, `make ci` green(문서 변경 — 게이트 무영향 확인용).

**Step 3** — 커밋: `git add CONTRIBUTING.md`
메시지: `docs: CONTRIBUTING에 새 코드 배치 규칙(셸 vs TS·게이트 언어 2원화) 성문화`

PR-7c 오픈(PR-7b 머지 후).

### 게이트·라이브 검증

```bash
make ci                    # 기대: typecheck·verify:ledger(bun 경로)·run-bats(신규 test_ledger-to-json/ledger-budget 포함)·shellcheck 전부 green
make verify                # 기대: check-resource-limits(bun) 포함 전 단계 통과, 마지막 "check-resource-limits OK (…스캔…)" 출력
make verify-traps          # 기대: "verify-traps: 원장 guard 실재 + SSOT 가드주석↔원장 일치 OK"
scripts/run-bats.sh --list | grep -c 'ledger'   # 기대: ledger 계열 bats 4개(gate/totals/to-json/budget) 수집
bun run verify:ledger      # 기대: conftest "0 failures" — 산출 JSON은 bun 파서 단일 경로
```

라이브: 이 배치는 클러스터 표면 변경 0(게이트·도구 전용). 캠페인 규율상 무영향만 확인:

```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl -n argocd get applications --no-headers | grep -vc 'Synced.*Healthy'   # 기대: 0 (배치 전과 동일)
```

### 롤백 노트

- PR 3개 각각 단일 관심사라 `git revert`(머지 커밋, `-m 1`) 단독 롤백 가능. PR-7a·7b는 각각 삭제한 `.sh`를 revert가 원자 복원하며 배선(bats·Makefile·verify-ledger.sh)도 같은 커밋이라 반쪽 상태가 없다.
- 주의: `AGENTS.md:15` 카운트 라인은 7a·7b가 연속 수정 — 7b 머지 후 7a만 revert하면 이 라인은 충돌로 수동 해소(카운트 17로).
- 라이브 영향 0이므로 롤백에 재싱크·재시작 불요. conftest 정책(`policy/ledger.rego`)·원장 데이터는 전 구간 무변경 — 예산 게이트 자체는 어느 시점에도 죽지 않는다(이관 중에도 gate가 verify:ledger를 계속 실행).

### 다음 배치 진행 조건

- PR-7a/7b/7c 전부 `gate` 통과 + 직렬 머지, 로컬 `make ci`·`make verify`·`make verify-traps` green.
- `bats tools/tests/ tests/` 재실행에서 ledger·resource-limits·cli-flag 스위트 회귀 0.
- B8(시크릿 채널)은 B7과 파일 겹침 없음 — 즉시 착수 가능. B10(메모리 right-size)은 B7.3이 이식한 GOMEMLIMIT 게이트가 이 시점부터 TS 경로로 동작함을 전제(각 right-size PR이 `make verify`에서 GOMEMLIMIT 역전을 차단받는지 첫 PR에서 확인).
## B8. 시크릿 채널 (ADR-0001 개정·seal 단일화·preflight fail-closed) (Wave 2)

⚠️ **설계 보정(실측):**
- 설계 §4 B8은 SOPS 채널을 "enc 10"이라 하나 tracked `*.enc.yaml`은 **9개**다(`git ls-files '*.enc.yaml' | wc -l == 9`). sealed 19는 일치. ADR 문구는 **9 vs 19**로 잡는다.
- `secret-cert-check.sh`의 종료코드는 **0=일치 / 1=stale·cert 부재·커밋본 판독불가 / 2=오프라인(kubeseal 부재 또는 fetch·parse 실패)**로 실측 확인(`scripts/secret-cert-check.sh:20,22,26,28,33,34,41`). fail-closed는 **호출부(seal-batch)** 정책으로 넣는다 — `secret-cert-check.sh` 자체 의미는 바꾸지 않는다(기존 `tests/gates/test_secret-cert-check.bats:36-42`가 오프라인=exit 2를 단언하므로 그 계약을 깨면 회귀).
- `scripts/README.md`는 4개 중 **`seal-adguard-auth.sh`만** 등재(`:38-39`)·나머지 3종은 미등재(M10). 제거 시 이 2줄만 정리.
- make 타깃 이름 `seal-*`는 `.env.secrets.example:94`·`platform/charts/app/values.yaml:8`·`platform/ghcr-pull/README.md:9`가 참조 → **타깃 이름은 별칭으로 보존**(스크립트만 제거, 타깃은 seal-batch 위임)해 이 참조들을 깨지 않는다. `docs/plans/*`의 참조는 역사 기록이라 손대지 않는다.
- `--all` 재봉인의 실제 사정거리는 **선언 테이블 5봉인본(= owner-local `.env.secrets` 파생분)**이다. 나머지 14봉인본(data-conn·db-*·cache acl·argocd-accounts·앱 레포 `*-secrets`)은 provision-db/cache·create-app·앱 레포 `secret:seal`이 권위 산출한다 — sealing key 회전 전수 드릴은 `--all`(owner-local 5) + provisioning 재실행(14)의 합집합이며, 이 경계를 회전 런북에 성문화한다(설계 "19개 일괄 재봉인"의 정확한 스코프).

**목표** seal 스크립트 4종(`seal-adguard-auth`·`seal-argocd-notify`·`seal-files-secrets`·`seal-ghcr-pull`)을 선언 테이블 + 변환 플러그인 기반 단일 도구 `tools/seal-batch.ts`로 통합하고(일괄 재봉인 `--all`·GHCR 단일 회전 타깃 확보), 봉인 전 `secret-cert-check` preflight를 **fail-closed**(exit 1·2 모두 중단, `--offline-ok`/`SEAL_OFFLINE=1` break-glass, dry-run 비대상)로 배선한다. 시크릿 채널 선택 기준을 ADR-0001에 개정 성문화하고 크리덴셜→평면 매트릭스를 tracked 문서 + owner-local 런북으로 분리 기록한다.

**선행 조건** Wave 1(B1~B5) 게이트 통과. `tools/lib/cli.ts`(parseFlags)·`tools/lib/seal.ts`(sealManifest, 기본 strict scope)는 현존 — 재사용, 수정 없음. B6/B7과 하드 의존 없음(같은 Wave 병렬 가능).

**PR 구성** (직렬 머지 — 스택 squash 함정 회피):
- **PR-8a** "docs: ADR-0001 시크릿 채널 선택 기준 개정 + 크리덴셜→평면 매트릭스" (docs-only, 무위험 · 선머지)
- **PR-8b** "refactor: seal 스크립트 4종을 seal-batch 단일 도구로 통합 (테이블 기반·preflight fail-closed·GHCR 단일 회전)" (도구 + bats + Makefile 재배선 + 4스크립트 제거 + README 정합)

---

### B8.1 ADR-0001 채널 선택 기준 개정 + 크리덴셜→평면 매트릭스 (tracked)

**Files:** Modify: `docs/decisions/0001-secret-management-hybrid.md`(현재 `:1-29`, append-only 개정 섹션 추가) / Test: grep 기반 정합 + `make verify`

**Step 1 — 개정 초안 append**: `docs/decisions/0001-secret-management-hybrid.md` 끝(`:29` `## 결과` 블록 뒤)에 아래 전문을 이어 붙인다. 개정 섹션은 append-only(README 규약 `docs/decisions/README.md:3` "MADR-lite, append-only") — 기존 본문은 수정하지 않는다.

```markdown

## 개정 2026-07 — 채널 선택 기준(de-facto)의 성문화

원 결정("하이브리드 유지")은 *유지 근거*만 담았고 "새 시크릿을 어느 채널에 둘지"의 판단 기준은
암묵이었다. 실태를 조사해 de-facto 기준을 명문화한다.

**기준 = 부트스트랩 임계성 / DR 복구 독립성.**
- **SOPS(`*.enc.yaml`, 9개)** — 클러스터를 *세우는 데* 필요하거나, 컨트롤러 없이 age 개인키만으로
  복호돼야 하는 시크릿. `scripts/seed-secrets.sh`가 terraform output·`.env.secrets`에서 시드한다:
  tunnel·operator-oauth·r2-creds(pg/cache)·pg-app-credentials·alerting·restore-drill-alerting·
  cloudflare-api-token(cert-manager). 이들이 SealedSecret이면 "클러스터를 세우려면 클러스터가
  필요한" 순환(원 결정 근거)에 빠진다.
- **SealedSecrets(`*.sealed.yaml`, 19개)** — 클러스터가 이미 선 뒤 자동화가 산출하거나(provision-db/
  cache·create-app·앱 레포 `secret:seal`) owner가 라이브 컨트롤러 공개키로 봉인하는 앱·부가 시크릿:
  앱 `*-secrets`·data-conn·adguard-auth·argocd-notifications·files-keys·ghcr-pull. 라이브 컨트롤러
  sealing key에 종속돼도 무방한(DR은 sealing key 백업 체인이 커버) 등급.

**판정 규칙(신규 시크릿):** "부트스트랩/DR bring-up 경로가 이 값을 컨트롤러 없이 요구하는가?"
→ 예: SOPS(seed-secrets 배선). 아니오(앱·부가·자동화 산출): SealedSecrets(`make seal-*` 또는
`secret:seal`). 회색지대는 SOPS로(DR 안전측).

### 부록 — 크리덴셜 → 소비자 평면 매트릭스(토폴로지, 값 아님)

토큰 1개가 여러 봉인/시드 평면에 흩어져 회전 시 일부 평면이 stale로 남는 클래스(GHCR·telegram
실증). 아래는 값이 아니라 *어느 파일이 같은 크리덴셜을 소비하는가*의 지도다(출처: `seed-secrets.sh`
heredoc·sealed 산출물 경로 — 비-secret). 실제 회전 절차·revoke 확인은 owner-local 런북(비커밋).

| 크리덴셜 | SOPS(`*.enc.yaml`) | SealedSecret(`*.sealed.yaml`) | Actions secret / 기타 |
|---|---|---|---|
| telegram 봇 토큰 | `victoria-stack/prod/alerting.enc.yaml`, `cnpg/prod/restore-drill-alerting.enc.yaml` (2) | `argocd/extras/argocd-notifications-secret.sealed.yaml` (1) | `TELEGRAM_BOT_TOKEN`(github tf) (1) |
| R2 pg/cache 키 | `cnpg/prod/r2-creds.enc.yaml`, `cache/prod/cache-r2-creds.enc.yaml` (2) | — | `R2_*`(github tf)·`infra/*/backend.hcl` state 버킷 재사용 |
| GHCR_PULL_TOKEN | — | `ghcr-pull/prod/ghcr-pull.sealed.yaml`, `files/prod/ghcr-pull.sealed.yaml` (2) | — (owner-local `.env.secrets`) |
| cert-manager CF 토큰 | `traefik/prod/cloudflare-api-token.enc.yaml` (1) | — | (broad `TF_VAR_cloudflare_api_token`은 별개 토큰 — tf provider 전용) |

**회전 원칙:** 크리덴셜 회전 = 그 행의 *모든* 평면 재생성. 클러스터 평면(SOPS+Sealed)은 `make
seed-secrets`(SOPS) + `make seal-*`(Sealed)로, Actions/backend 평면은 owner-local(tf apply·backend.hcl)로.
CI측 telegram은 실패 시에만 발화하므로 Actions 평면 stale이 조용히 알림 공백을 만든다(회전 PR
체크리스트가 owner-local 평면 확인을 강제 — 아래 런북).
```

**Step 2 — 검증(gate 재현)**:
```bash
make verify        # skeleton + ledger(conftest) + sops 라운드트립 — docs-only라 green 유지
grep -q "부트스트랩 임계성" docs/decisions/0001-secret-management-hybrid.md
grep -q "크리덴셜 → 소비자 평면 매트릭스" docs/decisions/0001-secret-management-hybrid.md
grep -Fq "argocd-notifications-secret.sealed.yaml" docs/decisions/0001-secret-management-hybrid.md
./scripts/run-bats.sh --list | grep -q .   # 수집 정상(문서 변경이 bats 수집을 깨지 않음)
```
기대: 종료 0, grep 3건 매치.

**Step 3 — 커밋**:
```bash
git add docs/decisions/0001-secret-management-hybrid.md
git commit -m "docs: ADR-0001 시크릿 채널 선택 기준 개정 + 크리덴셜→평면 매트릭스"
```

---

### B8.2 회전 런북 갱신 (owner-local — 커밋·게이트 비대상)

> `docs/runbooks/`는 gitignored(로컬 전용, AGENTS.md 런북 인덱스). 이 태스크는 **커밋 산출물이 없다** — owner 머신에서만 적용하고, tracked ADR(B8.1)이 이 런북을 포인터로 참조한다. 아래는 owner가 로컬 런북에 붙일 초안이며 계획은 **적용 지시**만 남긴다(값·경로 민감분은 로컬에만).

**적용 지시(owner-local):** `docs/runbooks/db-cache-access.md`(F3 자격 회수 런북) 또는 신규 `docs/runbooks/secret-rotation.md`에 아래 절차 append. 이후 `make verify-runbook-index`(로컬 fail-closed)로 인덱스 정합만 확인(비커밋).

```markdown
## 시크릿 회전 절차 (owner-local)

### 크리덴셜별 평면(=ADR-0001 부록 매트릭스, 실경로)
- telegram 봇 토큰: SOPS 2(alerting·restore-drill-alerting) + Sealed 1(argocd-notifications) + Actions 1
- R2 pg/cache: SOPS 2(cnpg r2-creds·cache-r2-creds) + Actions/backend
- GHCR_PULL_TOKEN: Sealed 2(prod·files) — **`make seal-ghcr-pull` 단일 타깃이 둘 다 재봉인**
- cert-manager CF: SOPS 1(traefik cloudflare-api-token)

### 절차
1. 새 토큰 발급(제공자 콘솔) → `.env.secrets` 갱신.
2. 클러스터 평면: SOPS → `make seed-secrets`(해당 enc 재시드) · Sealed → `make seal-<name>`
   (또는 sealing key 회전이면 `make seal-all`). 봉인 전 preflight는 seal-batch가 자동 실행(fail-closed).
3. Actions/backend 평면: `terraform -chdir=infra/github apply`(TELEGRAM_BOT_TOKEN/R2_* 시크릿),
   backend.hcl 재사용 키는 owner 로컬 확인.
4. 산출된 `*.enc.yaml`/`*.sealed.yaml`을 PR(회전 PR 체크리스트: 위 평면 전수 + 구 토큰 provider
   revoke 1회 확인 — 레포에서 검증 불가분).
5. sealing key 전수 회전 드릴: `make seal-all`(owner-local 5봉인본) + provision-db/cache 재-seal
   (data-conn·db-* 14봉인본) → `bats tests/test_sealed-secrets-restore.bats`(DR fail-closed 게이트) 재실행.
```

**검증(owner-local, 비커밋)**: `make verify-runbook-index` 종료 0. (커밋 없음.)

---

### B8.3 seal-batch 단일 도구 + preflight fail-closed + bats

**Files:** Create: `tools/seal-batch.ts`, `tools/tests/test_seal-batch.bats` / Reuse(무수정): `tools/lib/seal.ts`(sealManifest — 기본 strict scope), `tools/lib/cli.ts`(parseFlags), `scripts/secret-cert-check.sh`(preflight lib) / Test: `tools/tests/test_seal-batch.bats`(CI-safe: kubeseal·docker·gh 스텁 + 실 `secret-cert-check.sh` 오프라인/일치 분기)

**Step 1 — 실패 테스트 작성**: `tools/tests/test_seal-batch.bats` 신설. `@test` 이름 영어, 중간 단언 `[ ]`만(bash 3.2), 평문 비노출 단언 필수. 도구 부재라 전 케이스 실패한다.

```bash
#!/usr/bin/env bats
# seal-batch — 선언 테이블 기반 단일 봉인 도구. kubeseal/docker/gh 스텁으로 CI-safe(gate 수집).
# preflight(secret-cert-check.sh)는 실 스크립트를 돌리되 kubeseal --fetch-cert 스텁으로 오프라인/일치 분기.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. 평문/해시/토큰은 어떤 경로로도 미노출.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"
  openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out "$TMP/certA.pem" -days 1 -nodes -subj "/CN=a" 2>/dev/null
  # kubeseal 스텁: --fetch-cert → certA(preflight 일치), 그 외(--format yaml) → SealedSecret 모양
  cat > "$TMP/bin/kubeseal" <<EOF
#!/bin/sh
case "\$*" in
  *--fetch-cert*) cat "$TMP/certA.pem" ;;
  *) printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: STUB\nspec:\n  encryptedData:\n    STUB: xxx\n' ;;
esac
EOF
  chmod +x "$TMP/bin/kubeseal"
  # docker 스텁(bcrypt): htpasswd 출력 형식 'x:$2y$10$...' 모사(평문 미반영)
  printf '#!/bin/sh\nprintf "x:$2y$10$abcdefghijklmnopqrstuv\\n"\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
  printf '#!/bin/sh\necho testuser\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
}
teardown() { rm -rf "$TMP"; }

@test "dry-run lists targeted secrets and keys without invoking kubeseal or leaking values" {
  export ADGUARD_PASSWORD="p-secret-xyz"
  run bun tools/seal-batch.ts --only adguard-auth --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "adguard-auth"
  echo "$output" | grep -q "PASSWORD_HASH"
  [ "$(printf '%s' "$output" | grep -c "p-secret-xyz")" -eq 0 ]   # 부정 단언은 카운트 패턴(B3 lint-safe)
}

@test "unknown flag exits 2 (usage/parse per cli convention)" {
  run bun tools/seal-batch.ts --bogus
  [ "$status" -eq 2 ]
}

@test "missing env var fails closed with exit 1 (no partial seal)" {
  unset ADGUARD_PASSWORD
  run bun tools/seal-batch.ts --only adguard-auth --dry-run
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "ADGUARD_PASSWORD"
}

@test "seals a bcrypt secret through kubeseal, writing under --out-dir, never printing plaintext/hash" {
  export ADGUARD_PASSWORD="p-secret-xyz"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only adguard-auth --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
  grep -q "kind: SealedSecret" "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml"
  [ "$(grep -c "p-secret-xyz" "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml")" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c "p-secret-xyz")" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '\$2y\$10')" -eq 0 ]
}

@test "dockerconfig transform builds a dockerconfigjson secret without leaking the token" {
  export GHCR_PULL_TOKEN="dummy-ghcr-pull"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only prod-ghcr-pull --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml" ]
  [ "$(grep -c "dummy-ghcr-pull" "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml")" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c "dummy-ghcr-pull")" -eq 0 ]
}

@test "file transform rejects a FILES_KEYS_JSON that violates the contract" {
  export FILES_KEYS_JSON='{"not":"an-array"}'
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only files-keys --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "FILES_KEYS_JSON"
}

@test "file transform accepts a valid keys registry and never prints its contents" {
  export FILES_KEYS_JSON='[{"id":"admin","sha256":"deadbeef","service":"files"}]'
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only files-keys --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/files/prod/files-keys.sealed.yaml" ]
  [ "$(printf '%s' "$output" | grep -c "deadbeef")" -eq 0 ]
}

@test "group ghcr-pull seals BOTH prod and files planes (single rotation target)" {
  export GHCR_PULL_TOKEN="dummy-ghcr-pull"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --group ghcr-pull --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml" ]
  [ -f "$TMP/platform/files/prod/ghcr-pull.sealed.yaml" ]
}

@test "all seals every declared owner-local secret (rotation drill scope)" {
  export ADGUARD_PASSWORD="p1"; export TELEGRAM_BOT_TOKEN="t1"
  export GHCR_PULL_TOKEN="g1"; export FILES_KEYS_JSON='[{"id":"a","sha256":"b","service":"files"}]'
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --all --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
  [ -f "$TMP/platform/argocd/extras/argocd-notifications-secret.sealed.yaml" ]
  [ -f "$TMP/platform/files/prod/files-keys.sealed.yaml" ]
  [ -f "$TMP/platform/files/prod/ghcr-pull.sealed.yaml" ]
  [ -f "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml" ]
}

@test "preflight fails closed when the live cert cannot be fetched (offline exit 2 -> abort)" {
  export ADGUARD_PASSWORD="p1"
  # --fetch-cert가 실패(빈 출력)하도록 kubeseal 스텁 교체 → secret-cert-check exit 2
  printf '#!/bin/sh\ncase "$*" in *--fetch-cert*) exit 1;; *) cat;; esac\n' > "$TMP/bin/kubeseal"; chmod +x "$TMP/bin/kubeseal"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only adguard-auth --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
  echo "$output" | grep -qiE "preflight|중단|offline-ok"
}

@test "break-glass --offline-ok proceeds despite an offline preflight" {
  export ADGUARD_PASSWORD="p1"
  printf '#!/bin/sh\ncase "$*" in *--fetch-cert*) exit 1;; *) printf "apiVersion: bitnami.com/v1alpha1\\nkind: SealedSecret\\nmetadata:\\n  name: STUB\\nspec:\\n  encryptedData:\\n    STUB: xxx\\n";; esac\n' > "$TMP/bin/kubeseal"; chmod +x "$TMP/bin/kubeseal"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only adguard-auth --cert "$TMP/certA.pem" --out-dir "$TMP" --offline-ok
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
}
```

**Step 2 — 실행(기대 실패)**:
```bash
bats tools/tests/test_seal-batch.bats
```
기대: 전 케이스 실패(`bun tools/seal-batch.ts` 모듈 부재 → non-zero). "no such file" 류.

**Step 3 — 최소 구현**: `tools/seal-batch.ts` 신설. 선언 테이블 SSOT + 변환 플러그인(bcrypt/dockerconfig/literal/file) + preflight fail-closed. 경로는 `import.meta.url`로 레포 루트 해석(cwd 무관), 산출물은 `--out-dir`로 리디렉션(테스트 격리·기본=루트). `sealManifest`(lib/seal.ts, 기본 strict scope=구 스크립트 `--scope strict`와 동치)·`parseFlags`(lib/cli.ts) 재사용.

```typescript
#!/usr/bin/env bun
// seal-* 4종 통합 봉인 도구(owner-local). 선언 테이블 + 변환 플러그인.
// 평문/해시/토큰은 어떤 경로로도 stdout·예외메시지에 싣지 않는다(봉인 YAML만 산출).
// 종료코드: 2=사용법/파싱, 1=검증/게이트/preflight, 0=성공 (lib/cli 규약).
import { spawnSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { sealManifest } from "./lib/seal.ts";     // 기본 strict scope(=구 스크립트 --scope strict)
import { parseFlags } from "./lib/cli.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

type Transform = "bcrypt" | "dockerconfig" | "literal" | "file";
interface Entry {
  id: string;
  groups: string[];       // make 별칭 매핑(예: files=keys+ghcr, ghcr-pull=prod+files)
  name: string;           // Secret metadata.name
  namespace: string;
  out: string;            // 봉인 YAML 상대경로(--out-dir 기준)
  transform: Transform;
  env: string;            // .env.secrets 변수명
  key?: string;           // stringData 단일 키(literal/file/bcrypt)
  validate?: (raw: string) => void; // file 유형 계약 검증
}

// ── 선언 테이블(SSOT) — 구 4스크립트 실측 재현 ──────────────────────────────
const TABLE: Entry[] = [
  { id: "adguard-auth", groups: ["adguard-auth"], name: "adguard-auth", namespace: "edge",
    out: "platform/adguard/prod/adguard-auth.sealed.yaml", transform: "bcrypt",
    env: "ADGUARD_PASSWORD", key: "PASSWORD_HASH" },
  { id: "argocd-notify", groups: ["argocd-notify"], name: "argocd-notifications-secret", namespace: "argocd",
    out: "platform/argocd/extras/argocd-notifications-secret.sealed.yaml", transform: "literal",
    env: "TELEGRAM_BOT_TOKEN", key: "telegram-token" },
  { id: "files-keys", groups: ["files"], name: "files-keys", namespace: "files",
    out: "platform/files/prod/files-keys.sealed.yaml", transform: "file",
    env: "FILES_KEYS_JSON", key: "keys.json", validate: validateKeysJson },
  { id: "files-ghcr-pull", groups: ["files", "ghcr-pull"], name: "ghcr-pull", namespace: "files",
    out: "platform/files/prod/ghcr-pull.sealed.yaml", transform: "dockerconfig",
    env: "GHCR_PULL_TOKEN" },
  { id: "prod-ghcr-pull", groups: ["ghcr-pull"], name: "ghcr-pull", namespace: "prod",
    out: "platform/ghcr-pull/prod/ghcr-pull.sealed.yaml", transform: "dockerconfig",
    env: "GHCR_PULL_TOKEN" },
];

function fail(msg: string): never { console.error(`seal-batch: ${msg}`); process.exit(1); }

function validateKeysJson(raw: string): void {
  let doc: unknown;
  try { doc = JSON.parse(raw); } catch { fail("FILES_KEYS_JSON 파싱 실패(JSON 아님)"); }
  const ok = Array.isArray(doc) && doc.every((k) =>
    k && typeof k === "object" && "id" in k && "sha256" in k && "service" in k);
  if (!ok) fail("FILES_KEYS_JSON 형식 오류(배열·id/sha256/service 필수)");
}

// ── 변환 플러그인: env 값 → 평문 Secret manifest 객체(값은 메모리에만) ──────────
function buildManifest(e: Entry, val: string): object {
  const meta = { name: e.name, namespace: e.namespace };
  if (e.transform === "bcrypt") {
    const r = spawnSync("docker",
      ["run", "--rm", "-i", "httpd:2.4-alpine", "htpasswd", "-niBC", "10", "x"],
      { input: val, encoding: "utf8" });
    if (r.status !== 0) fail("bcrypt 해시 생성 실패(docker httpd)");
    const hash = (r.stdout.split(":")[1] ?? "").trim();
    if (!hash.startsWith("$2")) fail("bcrypt 해시 형식 불량");
    return { apiVersion: "v1", kind: "Secret", metadata: meta, type: "Opaque",
             stringData: { [e.key!]: hash } };
  }
  if (e.transform === "dockerconfig") {
    const u = spawnSync("gh", ["api", "user", "--jq", ".login"], { encoding: "utf8" });
    if (u.status !== 0) fail("gh api user 실패(GHCR username 조회)");
    const user = u.stdout.trim();
    const auth = Buffer.from(`${user}:${val}`).toString("base64");
    const cfg = JSON.stringify({ auths: { "ghcr.io": { username: user, password: val, auth } } });
    return { apiVersion: "v1", kind: "Secret", metadata: meta,
             type: "kubernetes.io/dockerconfigjson",
             stringData: { ".dockerconfigjson": cfg } };
  }
  // literal | file — 동일 opaque 빌더(file은 호출 전 validate 수행)
  return { apiVersion: "v1", kind: "Secret", metadata: meta, type: "Opaque",
           stringData: { [e.key!]: val } };
}

// ── preflight: fail-closed(exit 1·2 모두 중단) + break-glass ─────────────────
function preflight(cert: string, offlineOk: boolean): void {
  const r = spawnSync("bash", [join(ROOT, "scripts/secret-cert-check.sh"), "--cert", cert],
    { stdio: "inherit" });
  const code = r.status ?? 1;
  if (code === 0) return;
  if (offlineOk) { console.error(`⚠️ seal-batch: preflight code ${code} — break-glass 진행(--offline-ok/SEAL_OFFLINE=1)`); return; }
  console.error(`seal-batch: preflight 실패(code ${code}) — 봉인 중단(fail-closed). ` +
    `stale(1)=cert 갱신·재커밋, offline(2)=클러스터 접근 후 재시도, 불가피시 --offline-ok`);
  process.exit(1);
}

// ── CLI ─────────────────────────────────────────────────────────────────────
let flags: Record<string, string | boolean>;
try {
  flags = parseFlags(process.argv.slice(2), {
    value: ["--only", "--group", "--cert", "--out-dir"],
    bool: ["--all", "--dry-run", "--offline-ok"],
  });
} catch (e) {
  console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --only <id> | --group <name> | --all [--dry-run] [--offline-ok] [--cert <pem>] [--out-dir <dir>]`);
  process.exit(2);
}
const only = typeof flags["--only"] === "string" ? flags["--only"] as string : undefined;
const group = typeof flags["--group"] === "string" ? flags["--group"] as string : undefined;
const all = flags["--all"] === true;
const dryRun = flags["--dry-run"] === true;
const offlineOk = flags["--offline-ok"] === true || process.env.SEAL_OFFLINE === "1";
const cert = typeof flags["--cert"] === "string" ? flags["--cert"] as string : join(ROOT, "tools/sealed-secrets-cert.pem");
const outDir = typeof flags["--out-dir"] === "string" ? flags["--out-dir"] as string : ROOT;

const selected =
  all ? TABLE :
  only ? TABLE.filter((e) => e.id === only) :
  group ? TABLE.filter((e) => e.groups.includes(group)) :
  [];
if (selected.length === 0) fail(`대상 없음 — --only <id> | --group <name> | --all 중 하나 필요(id: ${TABLE.map((e) => e.id).join(", ")})`);

if (!dryRun) preflight(cert, offlineOk);   // dry-run은 preflight 비대상

for (const e of selected) {
  const val = process.env[e.env];
  if (!val) fail(`${e.env} 미설정(.env.secrets) — ${e.id} 봉인 불가(fail-closed)`);
  if (e.validate) e.validate(val);          // file 유형 계약 검증(값 미출력)
  if (dryRun) {
    const keys = e.transform === "dockerconfig" ? [".dockerconfigjson"] : [e.key];
    console.log(JSON.stringify({ id: e.id, out: e.out, name: e.name, namespace: e.namespace, keys }));
    continue;
  }
  const manifest = buildManifest(e, val);   // 평문은 메모리에만
  const sealed = sealManifest(manifest, cert); // kubeseal stdin — 평문 미기록, strict scope
  const dst = join(outDir, e.out);
  mkdirSync(dirname(dst), { recursive: true });
  writeFileSync(dst, sealed);
  console.log(`sealed -> ${e.out} (${e.name}, ns=${e.namespace}, scope=strict)`);
}
```

**Step 4 — 게이트 실행**:
```bash
bun run typecheck                       # tsconfig include tools/**/*.ts → seal-batch.ts 편입
bats tools/tests/test_seal-batch.bats   # 12 케이스 PASS
./scripts/run-bats.sh --list | grep -q 'tools/tests/test_seal-batch.bats'  # gate 자동 수집(tracked)
shellcheck $(git ls-files '*.sh')       # 셸 변경 없음 — green 유지
```
기대: typecheck 0, bats 전 케이스 PASS, run-bats 수집 확인.

**Step 5 — 커밋**:
```bash
git add tools/seal-batch.ts tools/tests/test_seal-batch.bats
git commit -m "feat: 선언 테이블 기반 seal-batch 봉인 도구 (bcrypt/dockerconfig/literal/file + preflight fail-closed + 일괄 재봉인)"
```

---

### B8.4 Makefile 재배선 + 구 스크립트 4종 제거 + README 정합

**Files:** Modify: `Makefile`(`:48` .PHONY, `:130-144` seal 타깃), `scripts/README.md`(`:38-39` seal-adguard-auth 행 제거), `tools/README.md`(seal-batch 행 추가), `tests/gates/test_make-secret-targets.bats`(seal 타깃 소싱 단언 추가) / Delete: `scripts/seal-adguard-auth.sh`·`scripts/seal-argocd-notify.sh`·`scripts/seal-files-secrets.sh`·`scripts/seal-ghcr-pull.sh` / Test: `tests/gates/test_make-secret-targets.bats`

**Step 1 — 실패 테스트 작성**: `tests/gates/test_make-secret-targets.bats` 끝(`:26`)에 seal 타깃 소싱 규약 단언 추가(seed-secrets 패턴 미러). 아직 Makefile 미개정이라 실패한다.

```bash

@test "seal targets source .env.secrets and delegate to seal-batch (seed-secrets pattern)" {
  for t in seal-adguard-auth seal-argocd-notify seal-files-secrets seal-ghcr-pull seal-all; do
    run make -n "$t"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q ".env.secrets"
    echo "$output" | grep -q "seal-batch.ts"
  done
}

@test "seal-ghcr-pull rotates BOTH prod and files planes via one target" {
  run make -n seal-ghcr-pull
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--group ghcr-pull"
}

@test "seal-all is the sealing-key rotation drill (owner-local table)" {
  run make -n seal-all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--all"
}
```

**Step 2 — 실행(기대 실패)**:
```bash
bats tests/gates/test_make-secret-targets.bats
```
기대: 신규 3케이스 실패(현재 타깃이 `@scripts/seal-*.sh` 위임 + `--all`/`--group` 미존재).

**Step 3 — 최소 구현**:

(a) `Makefile:130-144`의 4개 seal 타깃 블록을 아래로 **교체**(타깃 이름 별칭 보존, seed-secrets 소싱 패턴 통일, seal-batch 위임, `seal-all` 신설, `seal-ghcr-pull`은 `--group ghcr-pull`로 prod+files 동시). `.PHONY`도 seal-all 추가.

```make
.PHONY: seal-adguard-auth seal-argocd-notify seal-files-secrets seal-ghcr-pull seal-all

# 봉인 타깃은 seed-secrets 패턴으로 .env.secrets를 소싱해 seal-batch에 위임한다(preflight fail-closed 내장).
seal-adguard-auth: ## AdGuard UI 비밀번호(.env.secrets ADGUARD_PASSWORD)를 bcrypt 봉인 → adguard-auth SealedSecret
	@[ -f .env.secrets ] || { echo "seal-adguard-auth: .env.secrets 없음"; exit 1; }
	@set -a; . ./.env.secrets; set +a; bun tools/seal-batch.ts --only adguard-auth

seal-argocd-notify: ## telegram 봇 토큰(.env.secrets)을 argocd-notifications-secret SealedSecret로 봉인(argocd NS)
	@[ -f .env.secrets ] || { echo "seal-argocd-notify: .env.secrets 없음"; exit 1; }
	@set -a; . ./.env.secrets; set +a; bun tools/seal-batch.ts --only argocd-notify

seal-files-secrets: ## files 컴포넌트 SealedSecret 2종(keys 레지스트리 + files-ns ghcr-pull) 봉인(owner-local)
	@[ -f .env.secrets ] || { echo "seal-files-secrets: .env.secrets 없음"; exit 1; }
	@set -a; . ./.env.secrets; set +a; bun tools/seal-batch.ts --group files

seal-ghcr-pull: ## GHCR read 토큰 회전 단일 타깃 — prod+files 두 ghcr-pull 봉인본 동시 재봉인
	@[ -f .env.secrets ] || { echo "seal-ghcr-pull: .env.secrets 없음"; exit 1; }
	@set -a; . ./.env.secrets; set +a; bun tools/seal-batch.ts --group ghcr-pull

seal-all: ## [secret] sealing key 회전 드릴 — owner-local 선언 테이블 전수 재봉인(preflight fail-closed)
	@[ -f .env.secrets ] || { echo "seal-all: .env.secrets 없음"; exit 1; }
	@set -a; . ./.env.secrets; set +a; bun tools/seal-batch.ts --all
```

(b) 구 스크립트 4종 삭제:
```bash
git rm scripts/seal-adguard-auth.sh scripts/seal-argocd-notify.sh scripts/seal-files-secrets.sh scripts/seal-ghcr-pull.sh
```

(c) `scripts/README.md:38-39` seal-adguard-auth.sh 불릿 제거(secret-cert-check.sh 불릿 `:40-41`은 유지 — preflight lib은 존속). `secret-cert-check.sh` 불릿 끝에 한 줄 추가: "봉인 도구(`bun tools/seal-batch.ts`)가 봉인 전 이 검사를 fail-closed로 호출한다(`--offline-ok`/`SEAL_OFFLINE=1` break-glass)."

(d) `tools/README.md` homelab `.ts` 목록에 seal-batch 행 추가(예: `seal-secret.mts` 항목 `:89` 인근):
```markdown
- **`seal-batch.ts`** — owner-local 봉인 4종(adguard-auth·argocd-notify·files·ghcr-pull) 통합. 선언 테이블 + 변환 플러그인(bcrypt/dockerconfig/literal/file). `make seal-<name>`(별칭)·`make seal-all`(회전 드릴)이 호출. 봉인 전 `secret-cert-check` preflight fail-closed. 평문은 `kubeseal` stdin 전용(값 미출력).
```

**Step 4 — 게이트 실행(gate 재현)**:
```bash
make ci                                  # m6-tools+chart-test+typecheck+ledger+audit+skeleton+run-bats+shellcheck+sops
# 핵심 하위체크 개별 확인:
shellcheck $(git ls-files '*.sh')        # 삭제된 4스크립트는 ls-files에서 사라짐 → green
bats tests/gates/test_make-secret-targets.bats   # seal 타깃 소싱/단일회전/회전드릴 PASS
grep -q "seal-batch.ts" tools/README.md
! grep -q "seal-adguard-auth.sh" scripts/README.md   # 제거 확인(secret-cert-check.sh는 잔존)
```
기대: `make ci` 종료 0, test_make-secret-targets 전 케이스 PASS, README 정합 grep 통과.

**Step 5 — 커밋**:
```bash
git add Makefile scripts/README.md tools/README.md tests/gates/test_make-secret-targets.bats
git rm scripts/seal-adguard-auth.sh scripts/seal-argocd-notify.sh scripts/seal-files-secrets.sh scripts/seal-ghcr-pull.sh
git commit -m "refactor: seal 스크립트 4종 제거·seal-batch 위임 + Makefile 소싱 통일 + GHCR 단일 회전 타깃"
```

---

### 게이트·라이브 검증

**게이트(각 PR tip에서 `make ci` green 필수):**
```bash
make ci
# 개별:
bun run typecheck && bats tools/tests/test_seal-batch.bats tests/gates/test_make-secret-targets.bats
./scripts/run-bats.sh --list | grep -E 'test_seal-batch|test_make-secret-targets'  # gate 자동 수집 확인
make verify   # docs(ADR) 변경이 skeleton/ledger/sops 게이트 무영향
```
기대: 종료 0, 신규 bats 전 케이스 PASS.

**신구 산출물 diff 검증(owner-local — PR-8b 머지 전 필수, 리스크 매트릭스 B8):**
> B8.3 커밋 시점(도구 추가·구 스크립트 아직 존속)에 owner 머신에서 실행. 라이브 cert·`.env.secrets` 전제. kubeseal 암호문은 매 실행 비결정적이므로 **구조**(name/ns/template.type/scope 어노테이션/encryptedData 키집합)만 대조 — ciphertext는 비교 대상 아님.

```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
set -a; . ./.env.secrets; set +a
struct() { yq e '{"n":.metadata.name,"ns":.metadata.namespace,"a":.metadata.annotations,"t":.spec.template.type,"k":(.spec.encryptedData|keys)}' "$1"; }
# 예: adguard — 구 스크립트 산출 vs 신 도구 산출 구조 동치
scripts/seal-adguard-auth.sh                                   # 구: platform/adguard/prod/adguard-auth.sealed.yaml
struct platform/adguard/prod/adguard-auth.sealed.yaml > /tmp/old.txt
git checkout -- platform/adguard/prod/adguard-auth.sealed.yaml # 커밋본 복원(작업트리 오염 방지)
bun tools/seal-batch.ts --only adguard-auth --out-dir /tmp/newseal
struct /tmp/newseal/platform/adguard/prod/adguard-auth.sealed.yaml > /tmp/new.txt
diff /tmp/old.txt /tmp/new.txt && echo "STRUCT-MATCH adguard"
# 5봉인본 각각 반복(argocd-notify·files-keys·files-ghcr-pull·prod-ghcr-pull) — 전부 STRUCT-MATCH여야 머지
```
기대: 5봉인본 모두 `diff` 빈 출력 + `STRUCT-MATCH`. 특히 dockerconfig 2종은 `t: kubernetes.io/dockerconfigjson` + `k: ['.dockerconfigjson']`, adguard는 `t: Opaque`·`k: ['PASSWORD_HASH']`·`a: null`(strict scope=어노테이션 없음, 실측 확인).

**라이브 봉인·배포 검증(owner-local, 회전 시):**
```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
make seal-ghcr-pull            # preflight OK 후 prod+files 두 봉인본 재봉인
git add platform/ghcr-pull/prod/ghcr-pull.sealed.yaml platform/files/prod/ghcr-pull.sealed.yaml
# PR → gate → 머지 → ArgoCD 싱크 후:
kubectl -n prod get secret ghcr-pull -o name && kubectl -n files get secret ghcr-pull -o name
# files·prod 파드 ImagePullBackOff 부재 확인(회전 완결성 — M-low 재발 방지)
```
기대: 두 ns의 ghcr-pull Secret 존재 + 파드 Running(Pull 성공).

### 롤백 노트
- **PR-8a(docs)**: `git revert`로 ADR 개정 되돌림 — 라이브 무영향(문서 전용).
- **PR-8b(도구)**: 구 4스크립트는 git 히스토리에 존속 — `git revert`로 스크립트 복원 + Makefile 원복. 봉인본 자체는 불변(도구 교체는 *생성 경로*만 바꿈, 산출물 구조 동치가 diff 검증으로 보증됨)이라 라이브 SealedSecret·파드 무영향. 회전 중 preflight가 오탐 차단하면 `--offline-ok`(break-glass) 또는 구 스크립트 revert로 우회.
- seal-batch 결함 발견 시: 별칭 make 타깃만 구 스크립트로 되돌리면 되고(1커밋 revert), ADR/매트릭스는 유지 가능.

### 다음 배치 진행 조건
- PR-8a·PR-8b **직렬 머지**(스택 squash 함정 — base `--delete-branch` 머지가 의존 PR을 CLOSE시키므로 8a 머지 후 8b를 main에 rebase).
- 신구 산출물 STRUCT-MATCH 5/5 + `make ci` green + (회전 실행 시) 라이브 ghcr-pull 양 ns Pull 성공.
- B8은 B6/B7과 하드 의존 없음 — Wave 2 내 병렬 가능하나, B7의 `lib/cli` 종료코드 규약(2=파싱/1=검증)을 seal-batch가 이미 준수하므로 B7 선착 시 규약 일치 재확인만.
## B9. 골든패스/베스포크 (ADR-0004·베스포크 핀 레인·예약 host SSOT) (Wave 2)

⚠️ 설계 보정 (실파일 대조로 확인된 어긋남):
- **`test_apps_structure.bats` 위치**: 설계 §B9는 경로를 명시하지 않으나 실파일은 `infra/cloudflare/test_apps_structure.bats`(jq-only·gate 수집)이고, terraform 의존 검사는 `infra/cloudflare/test_apps_data.bats`(`.ci-exclude`)로 분리돼 있다. 예약 host SSOT의 구조 검사는 전자(gate), dns.tf 소비 grep은 후자(advisory)에 둔다.
- **베스포크 핀 디스크립터 확정**: files 인라인 핀은 `deployment.yaml:28`의 단일 YAML 스칼라 `ghcr.io/ukyi-app/files:sha-<gitsha>@sha256:<digest>`(trailing lineComment 포함)다. apps/의 `values.yaml`은 `image.tag`/`image.digest` **분리 키**라 편집 시맨틱이 다르다. 따라서 디스크립터는 `platform/<comp>/prod/.image-pin.json`(`{file, path, autoDeploy}`) + apps/와 동일한 `source-repo` 파일(org 바인딩·발견 키)로 확정. files엔 현재 **둘 다 없음** → B9.5에서 신설.
- **reserved-hosts.json은 FQDN 저장(zone-파라미터화 미승계)**: dns.tf:19는 현재 `"argocd-webhook.${var.zone_name}"`로 zone을 보간하나, `apps.json`이 이미 FQDN(`page.ukyi.app`)을 저장하고 dns.tf:6이 그걸 직접 소비하는 선례가 있다. 4소비자(dns.tf·create-app·bats·dns-drift)가 zone 없이도 쓰게 FQDN을 저장하고 dns.tf가 소비한다. `var.zone_name`은 site_hosts/data.tf에 잔존.
- **files autoDeploy=true(propose-pr PR-스팸 회피)**: bump-poll의 브랜치는 `bump-poll/<app>-<RUN_ID>`라 propose-pr(autoDeploy:false)은 머지 전까지 10분마다 **새 PR**을 연다(page·trip-mate 둘 다 true라 잠복). files 이미지 bump는 데이터 위험이 아니고(데이터 내구성은 B5의 Retain+백업이 담당) 파드만 롤링하므로, 디스크립터는 `autoDeploy:true`로 두어 완전 자동화한다. fail-closed 로직(누락/false→propose-pr)은 그대로 보존.
- **dns-drift는 `--reserved <path>`(SSOT 파일 소비)로 구현** — 설계 B13의 `--extra-hosts`(리스트 플래그) 대신 파일을 직접 소비해 SSOT 단일 소스 원칙을 지킨다. 기본 경로는 `--apps` 형제(`dirname(appsPath)/reserved-hosts.json`)라 기존 tmp-fixture 테스트는 형제 부재→빈 목록으로 무영향(회귀 0).

**목표** files 베스포크의 구조적 실비용 2가지(릴리스마다 수동 이미지 bump·컴포넌트 규약 재발견)를 제거하고, 노출 레지스트리 이원화(apps.json vs platform_hosts)를 living doc·SSOT로 승격한다 — 골든패스 5축 확장은 하지 않는다(rule-of-two).

**선행 조건** 없음(Wave 2 독립 배치 — B2의 알림/렌더 룰과 상호 비의존). B6·B5와 병렬 가능하나 배치 내 PR은 직렬 머지.

**PR 구성** (직렬 머지 — 스택 squash 함정 회피):
- **PR-9a** "docs: 골든패스 rule-of-two ADR + 베스포크 체크리스트" (B9.1·B9.2 — docs-only, 무-라이브)
- **PR-9b** "feat: bump-poll 베스포크 이미지 핀 레인 + files 합류" (B9.3·B9.4·B9.5)
- **PR-9c** "feat: 예약 host JSON SSOT 4소비자 배선" (B9.6·B9.7)

---

### B9.1 ADR-0004 골든패스 rule-of-two 성문화

**Files:**
- Create: `docs/decisions/0004-golden-path-rule-of-two.md`
- Modify: `docs/decisions/README.md`(인덱스 표 — 현재 0001~0003, 라인 11 다음에 0004 행 추가)
- Test: grep 기반 존재·상호참조 검증(신규 ADR은 전용 bats 불필요 — decisions/에 index 가드 부재 확인됨)

**Step 1** — ADR 초안 전문 작성(`docs/decisions/0004-golden-path-rule-of-two.md`, MADR-lite·0001 형식 미러):

```markdown
# 0004 — 골든패스 확장 대신 베스포크 컴포넌트 유지 (rule-of-two)

- 상태: 수용(accepted)
- 관련: `AGENTS.md`(멀티레포 앱 플로우), `platform/files/`, `infra/cloudflare/dns.tf`,
  `docs/bespoke-component-checklist.md`, `docs/decisions/0001-secret-management-hybrid.md`

## 맥락
공유 Helm 차트(`platform/charts/app`)는 web/worker/site 3 kind의 골든패스를 제공한다. files
파일 스토어는 이 표면 밖의 5축을 요구한다: ① stateful PVC(bulk-ssd), ② 복수 리스너(internal
8080 + public 8081), ③ HTTP method 매치, ④ 시크릿 파일 마운트(keys.json), ⑤ 평문 env. files를
골든패스에 흡수하려면 닫힌 차트 스키마(`values.schema.json`)를 5축 확장해야 하는데, 현재 이
수요의 소비자는 files 단 하나(n=1)다.

## 결정
**골든패스를 확장하지 않는다.** files는 `platform/files/` 베스포크 컴포넌트로 유지한다. 대신
베스포크의 실비용 2가지(릴리스마다 수동 이미지 bump, 컴포넌트 규약 재발견)를 구조로 제거한다:
bump-poll 베스포크 핀 레인 + 본 ADR + `docs/bespoke-component-checklist.md`.

## 근거 (rule-of-two)
- **소비자 n=1엔 추상화하지 않는다.** 닫힌 스키마를 5축 확장하면 web/worker/site 3 kind 전부의
  표면·검증·문서 비용이 늘고, 회귀 위험(SSA atomic list 영구 OutOfSync·스키마 밖 필드 거부)이
  golden-path 앱 전체로 번진다. 베스포크는 그 위험을 files 디렉토리에 격리한다.
- **노출 레지스트리 이원화가 이미 이 경계를 코드로 표현한다.** 앱 host는 `apps.json`(데이터 합류
  — create-app이 등록, teardown이 무인 자동 회수)로, 플랫폼 공개 host(argocd-webhook·files)는
  코드 고정 레지스트리(`reserved-hosts.json`→dns.tf `platform_hosts`)로 관리한다. 후자는 destroy
  가드 allowlist(`^cloudflare_dns_record\.app\[`) 비대상이라 apex/www처럼 무인 삭제로부터 보호된다.
  앱은 자동 수명주기, 플랫폼 컴포넌트는 owner 고정 — 두 부류를 한 레지스트리에 섞으면 files가
  teardown 자동 회수에 휩쓸릴 수 있다.
- **appset 경계도 같은 결론.** files를 `apps/`로 편입하면 appset destination.namespace=prod
  하드코딩과 충돌하고 차트 백도어를 재개방해야 한다(역행).

## 기각된 대안
- **공유차트 5축 확장**: n=1 수요에 닫힌 스키마 표면 확대 — 비용 > 이득.
- **files의 apps/ 편입**: appset·차트 계약 역행(위 근거).

## 재평가 트리거
**두 번째 stateful 컴포넌트 수요가 생기면(n=2) 이 결정을 재검토한다.** 그때의 흡수 우선순위(비용
낮은 축부터): ⑤평문 env > ④시크릿 파일 마운트 > ③method 매치. ①stateful PVC·②복수 리스너는
그때도 별도 차트/베스포크로 유지한다(상태·리스너 토폴로지는 앱마다 달라 공유 스키마화 이득이 작다).

## 결과
- 새 베스포크 컴포넌트는 `docs/bespoke-component-checklist.md`를 따른다(files가 4번째 손복제:
  adguard→homepage→cache→files. 5번째부터는 체크리스트 기반).
- files는 bump-poll 베스포크 핀 레인(`platform/files/prod/source-repo` + `.image-pin.json`)으로
  자동 이미지 bump에 합류한다(apps/ 레인과 동일 fail-closed autoDeploy 게이트).
```

**Step 2** — README 인덱스 표에 행 추가. `docs/decisions/README.md`의 라인 11(`| [0003](0003-single-required-check.md) | required status check는 \`gate\` 단일 |`) 다음에 삽입:

```markdown
| [0004](0004-golden-path-rule-of-two.md) | 골든패스 확장 대신 베스포크 유지(rule-of-two) |
```

**Step 3** — 검증(grep + 상호참조 무결성):

```bash
grep -q "rule-of-two" docs/decisions/0004-golden-path-rule-of-two.md
grep -q "0004-golden-path-rule-of-two.md" docs/decisions/README.md
# 관련 링크 대상 실존(bespoke-checklist는 B9.2에서 생성 — 이 커밋 시점엔 아직 없음, PR 단위로 함께 머지)
```
기대: 앞 2줄 exit 0. (`docs/bespoke-component-checklist.md`는 B9.2 커밋에서 생성 — 동일 PR-9a 내 후속 커밋이라 PR 머지 시점엔 존재.)

**Step 4** — gate 재현:

```bash
make ci
```
기대: `run-bats.sh` 전 CI-safe bats PASS(신규 ADR은 파서 대상 아님 — check-skeleton은 platform 컴포넌트만 검사, decisions/ 무-가드 확인됨).

**Step 5** — 커밋:

```bash
git add docs/decisions/0004-golden-path-rule-of-two.md docs/decisions/README.md
git commit -m "docs: ADR-0004 골든패스 대신 베스포크 유지(rule-of-two) 성문화"
```

---

### B9.2 베스포크 플랫폼 컴포넌트 체크리스트 문서

**Files:**
- Create: `docs/bespoke-component-checklist.md`
- Test: grep 존재 검증(체크리스트는 산문 — 항목이 실코드 규약과 어긋나지 않는지 grep 교차)

**Step 1** — 초안 전문 작성(files/adguard/homepage 실측 최소셋 — 각 항목이 라이브 검증된 함정에 대응):

```markdown
# 베스포크 플랫폼 컴포넌트 체크리스트

공유 차트(`platform/charts/app`) 골든패스 밖의 컴포넌트를 `platform/<comp>/`로 손복제할 때 최소셋.
계보: adguard → homepage → cache → files(4번째). 근거는 `docs/decisions/0004-golden-path-rule-of-two.md`.
각 항목은 라이브에서 검증된 함정에 대응한다(누락 시 재발) — `docs/traps-detail.md` 교차참조.

## 1. 네임스페이스 · PSA · Prune
- [ ] `platform/namespaces/prod/namespaces.yaml`에 전용 NS + `pod-security.kubernetes.io/enforce:
      restricted` + `argocd.argoproj.io/sync-options: Prune=false`(appset 대상 NS는 platform/namespaces
      소유 — 컴포넌트가 prune하지 못하게).
- [ ] NS 회귀 가드 bats(`platform/namespaces/prod/test_<comp>_ns.bats`, homepage/files 패턴).

## 2. 워크로드 · 보안 컨텍스트
- [ ] `runAsNonRoot`·`readOnlyRootFilesystem`·`allowPrivilegeEscalation:false`·`drop:[ALL]`·
      `seccompProfile:RuntimeDefault`. 쓰기 필요 시 PVC/emptyDir만. RWO PVC면 `strategy: Recreate`
      (단일 노드 볼륨 교착 회피). 비루트 PVC 쓰기엔 `fsGroup`.
- [ ] private GHCR면 `imagePullSecrets:[{name: ghcr-pull}]` + `ghcr-pull.sealed.yaml`.

## 3. 노출 (netpol 트리오 + 공개 host)
- [ ] NetworkPolicy 트리오: default-deny egress + allow-dns egress(kube-system/kube-dns) +
      allow-ingress-from-gateway(namespaceSelector gateway). 함정: NetworkPolicy egress 포트는
      DNAT 후 targetPort.
- [ ] 내부 host는 `<comp>.home.<도메인>`(Gateway web-internal 리스너 규약). HTTPRoute internal.
- [ ] 공개 노출은 **`infra/cloudflare/reserved-hosts.json`→dns.tf `platform_hosts`**(apps.json 아님
      — apps.json은 audit-orphans가 apps/ 부재를 차단한다). 공개 HTTPRoute + reserved-hosts.json 등록.

## 4. 이미지 핀 레인 (자동 bump 합류)
- [ ] `platform/<comp>/prod/source-repo`(= `ukyi-app/<comp>`) + `.image-pin.json`
      (`{file, path, autoDeploy}`) — bump-poll 2차 순회가 발견해 인라인 핀을 자동 bump한다.
      누락 시 릴리스마다 수동 bump PR로 회귀.
- [ ] 이미지는 `<repo>:sha-<gitsha>@sha256:<digest>` 인라인 핀(불변). autoDeploy=false면 fail-closed
      승인 PR(단, propose-pr은 주기마다 새 PR을 여니 사용자-데이터 무변이 컴포넌트는 true 권장).

## 5. 원장 · 알림 · 렌더 가드
- [ ] `docs/memory-ledger.md`에 컴포넌트 행 추가(limit 합계 ≤ 예산, CI 강제).
- [ ] ArgoCD notifications 구독(배포/저하 telegram) + 워크로드-불가용 vmalert 룰 커버
      (files/adguard/homepage 공백 클래스 — `kube_deployment_status_condition` 일괄 룰).
- [ ] 렌더 bats(homepage 패턴: kustomize build + kubeconform) + 컴포넌트 기능 bats 최소셋.
```

**Step 2** — 검증(항목이 실코드 규약과 정합한지 grep 교차 — 예: files 실측):

```bash
grep -q "reserved-hosts.json" docs/bespoke-component-checklist.md
grep -q "0004-golden-path-rule-of-two.md" docs/bespoke-component-checklist.md
# files가 체크리스트 규약을 실제로 따르는지(계보 4번째 증명): Prune=false·netpol 트리오
grep -q "Prune=false" platform/namespaces/prod/namespaces.yaml
grep -c "kind: NetworkPolicy" platform/files/prod/networkpolicy.yaml   # 기대: 3(트리오)
```
기대: grep 3줄 exit 0, netpol count == 3.

**Step 3** — gate:

```bash
make ci
```
기대: PASS(체크리스트는 산문 — 가드 미대상).

**Step 4** — 커밋:

```bash
git add docs/bespoke-component-checklist.md
git commit -m "docs: 베스포크 플랫폼 컴포넌트 체크리스트 신설"
```

**PR-9a 생성·머지** — 두 커밋을 담아 PR 생성, gate 통과 후 머지(docs-only·무-라이브).

---

### B9.3 poll-ghcr 베스포크 핀 레인 2차 순회

**목표** apps/ 순회(`poll-ghcr.ts:166-176`)와 별도로 `platform/<comp>/prod/.image-pin.json` 디스크립터가 있는 베스포크 컴포넌트를 순회한다. 공통 compute(compare/manifest/candidate/descendant)는 추출해 두 레인이 공유(fail-closed autoDeploy 게이트 동일).

**Files:**
- Modify: `tools/poll-ghcr.ts` (Plan 타입 94-101·planApp 103-163·apps 루프 166-176)
- Test: `tools/tests/test_poll-ghcr.bats` (2 케이스 추가 — bump·fail-closed)

**Step 1** — 실패 테스트 작성. `tools/tests/test_poll-ghcr.bats` 말미에 추가(기존 setup의 `$TMP`/`$FX`/`$P` 재사용, apps/orders와 공존해 `.app=="files"`로 선택):

```bash
@test "a bespoke platform component (image-pin descriptor) joins the bump lane with pin+writePath" {
  PD="$TMP/platform/files/prod"; mkdir -p "$PD"
  printf 'ukyi-app/files' > "$PD/source-repo"
  cat > "$PD/.image-pin.json" <<'JSON'
{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }
JSON
  cat > "$PD/deployment.yaml" <<'YAML'
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-aaa1111000000000000000000000000000000000@sha256:1111111111111111111111111111111111111111111111111111111111111111
YAML
  cat > "$FX/files.commits.json" <<'EOF'
[ { "sha": "bbb2222000000000000000000000000000000000" }, { "sha": "aaa1111000000000000000000000000000000000" } ]
EOF
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-main.json"
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-bbb2222.json"
  printf '{ "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222" }\n' > "$FX/files.manifest-sha-bbb2222.json"
  run bun "$P" --root "$TMP" --fixtures "$FX" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .action == "bump"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .pin == "platform/files/prod/.image-pin.json"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .writePath == "platform/files/prod/deployment.yaml"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .candidate.tag == "sha-bbb2222000000000000000000000000000000000"'
}

@test "bespoke descriptor without autoDeploy is fail-closed (propose-pr, never auto bump)" {
  PD="$TMP/platform/files/prod"; mkdir -p "$PD"
  printf 'ukyi-app/files' > "$PD/source-repo"
  printf '{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"] }\n' > "$PD/.image-pin.json"
  cat > "$PD/deployment.yaml" <<'YAML'
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-aaa1111000000000000000000000000000000000@sha256:1111111111111111111111111111111111111111111111111111111111111111
YAML
  cat > "$FX/files.commits.json" <<'EOF'
[ { "sha": "bbb2222000000000000000000000000000000000" }, { "sha": "aaa1111000000000000000000000000000000000" } ]
EOF
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-main.json"
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-bbb2222.json"
  printf '{ "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222" }\n' > "$FX/files.manifest-sha-bbb2222.json"
  run bun "$P" --root "$TMP" --fixtures "$FX" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .action == "propose-pr"'
}
```

**Step 2** — 실행(구현 전, 기대 실패):

```bash
bats tools/tests/test_poll-ghcr.bats
```
기대: 신규 2 케이스 FAIL(현재 platform/ 순회 없음 → `.app=="files"` 항목 부재 → jq select 결과 없음).

**Step 3** — 최소 구현. `tools/poll-ghcr.ts`:

(a) Plan 타입에 필드 추가 — 라인 94-101을 아래로 교체:

```ts
type Plan = {
  app: string;
  action: string;
  reason: string;
  current: { tag: string; digest: any } | null;
  candidate: { gitsha: string; tag: string; digest: any } | null;
  src?: string;
  writePath?: string; // git add 대상(apps: values.yaml / 베스포크: deployment.yaml)
  pin?: string;       // 베스포크 핀 디스크립터 경로(apps 레인은 미설정 → bump-poll이 apps 분기)
};

// 인라인 핀 스칼라 경로 추적용(yaml parse는 순수 객체/배열 반환 — 배열 인덱스 포함 traverse)
const getIn = (obj: any, p: (string | number)[]) => p.reduce((o: any, k) => (o == null ? o : o[k]), obj);
```

(b) 공통 compute 추출 — 기존 `planApp`(103-163) 앞에 삽입:

```ts
// 배포된 tag/digest·autoDeploy·src를 받아 bump/propose-pr/refuse/noop을 계산(두 레인 공유).
// key = 데이터소스 조회 키(app 또는 컴포넌트 이름 — fixtures 파일명 접두).
function computeBump(result: Plan, s: { key: string; src: string; repo: string; deployed: string; digest: any; autoDeploy: boolean }): Plan {
  const q = makeQuery(s.key);
  // (a) 배포 SHA가 main의 조상인가 — 아니면 수동 rollback/이력 조작 상황: 자동 폴링 거부
  const baseCmp = q.compare(s.src, s.deployed, "main");
  if (!baseCmp || !["ahead", "identical"].includes(baseCmp.status))
    return { ...result, action: "refuse", reason: `배포 SHA(${short(s.deployed)})가 main 조상이 아님(status=${baseCmp?.status ?? "?"}) — 명시적 rollback 작업으로만` };
  if (baseCmp.status === "identical") return { ...result, reason: "배포 SHA == main tip" };
  // (b) main 최신→과거로 걸으며 이미지 실존하는 첫 커밋 = 후보 (배포 SHA 도달 시 중단)
  let candidate: { gitsha: string; tag: string; digest: any } | null = null;
  for (const c of q.commits(s.src)) {
    if (c.sha.startsWith(s.deployed) || s.deployed.startsWith(short(c.sha))) break;
    const m = q.manifest(s.repo, `sha-${c.sha}`);
    if (m?.digest) { candidate = { gitsha: c.sha, tag: `sha-${c.sha}`, digest: m.digest }; break; }
  }
  if (!candidate) return { ...result, reason: "배포 이후 빌드된 main 커밋 없음" };
  // (c) 후보가 배포 SHA의 descendant임을 재증명 (merge 커밋 목록의 비선형성 방어)
  const candCmp = q.compare(s.src, s.deployed, candidate.gitsha);
  if (!candCmp || candCmp.status !== "ahead")
    return { ...result, action: "refuse", reason: `후보(${short(candidate.gitsha)})가 배포 SHA의 descendant가 아님(status=${candCmp?.status ?? "?"})` };
  if (candidate.digest === s.digest) return { ...result, reason: "동일 digest — 멱등 no-op" };
  return { ...result, action: s.autoDeploy ? "bump" : "propose-pr", candidate, reason: s.autoDeploy ? "" : "autoDeploy 아님(fail-closed) — 승인 PR만" };
}
```

(c) `planApp` 본문(103-163)을 아래로 교체(current 읽기 + writePath 설정 + computeBump 위임):

```ts
function planApp(dir: string, app: string): Plan {
  const read = (f: string) => readFileSync(path.join(dir, f), "utf8");
  const result: Plan = { app, action: "noop", reason: "", current: null, candidate: null };

  const src = read("source-repo").trim();
  result.src = src;
  if (!new RegExp(`^${args.owner}/[A-Za-z0-9._-]+$`).test(src))
    return { ...result, action: "refuse", reason: `source-repo가 ${args.owner} org 밖: ${src}` };

  const values = parse(read("values.yaml"));
  const repo = values?.image?.repo ?? "";
  const tag = String(values?.image?.tag ?? "");
  const digest = values?.image?.digest ?? null;
  result.current = { tag, digest };
  result.writePath = path.join("apps", app, "deploy", "prod", "values.yaml");
  if (!/^sha-[0-9a-f]{7,40}$/.test(tag))
    return { ...result, action: "refuse", reason: `배포 tag가 sha-* 형식이 아니라 조상 증명 불가: ${tag}` };

  // 승인 정책: autoDeploy === true만 자동, 그 외(false/누락/파싱 불가)는 전부 fail-closed
  let autoDeploy = false;
  const bindingsPath = path.join(dir, ".bindings.json");
  if (existsSync(bindingsPath)) {
    try { autoDeploy = JSON.parse(readFileSync(bindingsPath, "utf8")).autoDeploy === true; } catch { autoDeploy = false; }
  }
  return computeBump(result, { key: app, src, repo, deployed: tag.slice(4), digest, autoDeploy });
}

// 베스포크 핀 레인: platform/<comp>/prod/.image-pin.json이 인라인 이미지 핀(values.yaml image.tag/
// digest 분리 키 대신 deployment.yaml의 <repo>:<tag>@<digest> 단일 스칼라)의 위치·autoDeploy를 담는다.
// source-repo = org 바인딩(apps/와 동일). GHCR repo는 source-repo에서 파생(ghcr.io/<src>)해 인라인 파싱본과 대조.
function planComponent(dir: string, name: string): Plan {
  const read = (f: string) => readFileSync(path.join(dir, f), "utf8");
  const result: Plan = { app: name, action: "noop", reason: "", current: null, candidate: null };

  const src = read("source-repo").trim();
  result.src = src;
  if (!new RegExp(`^${args.owner}/[A-Za-z0-9._-]+$`).test(src))
    return { ...result, action: "refuse", reason: `source-repo가 ${args.owner} org 밖: ${src}` };

  const pin = JSON.parse(read(".image-pin.json"));
  const image = String(getIn(parse(read(pin.file)), pin.path) ?? "");
  const m = /^(.+?):(sha-[0-9a-f]{7,40})@(sha256:[0-9a-f]{64})$/.exec(image);
  if (!m) return { ...result, action: "refuse", reason: `인라인 핀 형식 불량(repo:sha-*@sha256:*): ${image}` };
  const [, repo, tag, digest] = m;
  if (repo !== `ghcr.io/${src}`) return { ...result, action: "refuse", reason: `핀 repo(${repo})가 source-repo(${src})와 불일치` };
  result.current = { tag, digest };
  result.pin = path.join("platform", name, "prod", ".image-pin.json");
  result.writePath = path.join("platform", name, "prod", pin.file);
  return computeBump(result, { key: name, src, repo, deployed: tag.slice(4), digest, autoDeploy: pin.autoDeploy === true });
}
```

(d) 순회 확장 — 기존 apps 루프(166-176) 뒤에 platform 루프 삽입:

```ts
// platform/*/prod 중 베스포크 핀 디스크립터(.image-pin.json)가 있는 컴포넌트 2차 순회
const platformRoot = path.join(args.root, "platform");
for (const name of existsSync(platformRoot) ? readdirSync(platformRoot) : []) {
  const dir = path.join(platformRoot, name, "prod");
  if (!existsSync(path.join(dir, ".image-pin.json"))) continue;
  try {
    plans.push(planComponent(dir, name));
  } catch (e: any) {
    plans.push({ app: name, action: "refuse", reason: `플랜 실패: ${e.message}` });
  }
}
```

**Step 4** — 재실행 + 회귀 gate:

```bash
bats tools/tests/test_poll-ghcr.bats     # 신규 2 + 기존 10 전부 PASS(apps/orders는 [0] 유지)
bun tools/poll-ghcr.ts --help            # 파싱 무영향 확인
make ci
```
기대: 전 케이스 PASS. 기존 `.[0]` 단언은 apps 루프 우선이라 불변.

**Step 5** — 커밋:

```bash
git add tools/poll-ghcr.ts tools/tests/test_poll-ghcr.bats
git commit -m "feat: poll-ghcr 베스포크 핀 레인 2차 순회(platform/*/prod .image-pin.json)"
```

---

### B9.4 bump-tag 인라인 핀 편집 모드

**목표** `--pin <디스크립터>`가 주어지면 apps/ values.yaml(분리 키) 대신 디스크립터가 가리키는 `deployment.yaml`의 인라인 스칼라(`<repo>:<tag>@<digest>`)를 편집한다. TOCTOU(`--expect-current`)·no-op·path-traversal 가드 동일. 스칼라 노드 직접 수정으로 flow 서식·lineComment 보존.

**Files:**
- Modify: `tools/bump-tag.ts` (import 2-3·VALUE_FLAGS 9·app/tag/digest 검증 26-37 직후 분기 삽입)
- Test: `tools/tests/test_bump.bats` (인라인 모드 5 케이스 추가)

**Step 1** — 실패 테스트 작성. `tools/tests/test_bump.bats` 말미에 추가(`$FIX`·`$DIG` 재사용):

```bash
# ── 인라인 핀 편집 모드(베스포크 platform 컴포넌트: deployment.yaml repo:tag@digest 단일 스칼라) ──
seed_pin() {
  mkdir -p "$FIX/platform/files/prod"
  cat > "$FIX/platform/files/prod/.image-pin.json" <<'JSON'
{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }
JSON
  cat > "$FIX/platform/files/prod/deployment.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-0000000@$DIG # sha-0000000 + digest 인라인 핀(불변)
EOF
}
NEWDIG="sha256:1111111111111111111111111111111111111111111111111111111111111111"

@test "bump --pin edits the inline repo:tag@digest scalar in a bespoke deployment.yaml" {
  seed_pin
  f="$FIX/platform/files/prod/deployment.yaml"
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 0 ]
  run yq '.spec.template.spec.containers[0].image' "$f"
  [ "$output" == "ghcr.io/ukyi-app/files:sha-feedbee@$NEWDIG" ]
}

@test "bump --pin without --digest is refused (bespoke pins are always digest-pinned)" {
  seed_pin
  run bun tools/bump-tag.ts files sha-feedbee --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "인라인 핀 모드는 --digest 필수"
}

@test "bump --pin --expect-current aborts on a tag mismatch (TOCTOU, exit 3)" {
  seed_pin
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --expect-current sha-aaaaaaa --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "expect-current"
}

@test "bump --pin is idempotent (same tag+digest is a no-op)" {
  seed_pin
  bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "bump --pin refuses a descriptor outside platform/ (path traversal guard)" {
  seed_pin
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin ../outside.json --repo-root "$FIX"
  [ "$status" -eq 2 ]
}
```

**Step 2** — 실행(기대 실패):

```bash
bats tools/tests/test_bump.bats
```
기대: 인라인 5 케이스 FAIL(현재 `--pin`은 미인식 옵션 → exit 2로 죽거나 values.yaml 경로만 탐).

**Step 3** — 최소 구현. `tools/bump-tag.ts`:

- 라인 2 `import { resolve, sep } from "node:path";` → `import { resolve, sep, dirname } from "node:path";`
- 라인 3 `import { parseDocument } from "yaml";` → `import { parseDocument, isScalar } from "yaml";`
- 라인 9 `const VALUE_FLAGS = new Set(["--repo-root", "--digest", "--expect-current"]);` → `--pin` 추가:
  ```ts
  const VALUE_FLAGS = new Set(["--repo-root", "--digest", "--expect-current", "--pin"]);
  ```
- digest 형식 검증 직후(라인 37과 38 사이, `const path = ...` 앞)에 인라인 분기 삽입:

```ts
// ── 인라인 핀 편집 모드(베스포크 platform 컴포넌트) ──
// apps/의 values.yaml image.tag/digest(분리 키) 전제와 달리, 디스크립터(.image-pin.json)가
// deployment.yaml의 <repo>:<tag>@<digest> 단일 스칼라 위치를 가리킨다. TOCTOU·no-op·path-traversal 동일.
const pinArg = opts["--pin"];
if (pinArg !== undefined) {
  if (digest === undefined) { console.error("인라인 핀 모드는 --digest 필수(베스포크 핀은 태그+digest 불변)"); process.exit(2); }
  const platRoot = resolve(repoRoot, "platform");
  const descPath = resolve(repoRoot, pinArg);
  if (!descPath.startsWith(platRoot + sep)) { console.error(`refusing pin outside platform/: ${pinArg}`); process.exit(2); }
  const desc = JSON.parse(readFileSync(descPath, "utf8"));
  const targetPath = resolve(dirname(descPath), desc.file);
  if (!targetPath.startsWith(platRoot + sep)) { console.error(`refusing to write outside platform/: ${desc.file}`); process.exit(2); }
  const doc = parseDocument(readFileSync(targetPath, "utf8"));
  const node = doc.getIn(desc.path, true); // keepScalar: flow 서식·lineComment 보존
  if (!isScalar(node)) { console.error(`핀 경로가 스칼라가 아님: ${JSON.stringify(desc.path)}`); process.exit(2); }
  const cur = String(node.value ?? "");
  const m = /^(.+?):(sha-[0-9a-f]{7,40})@(sha256:[0-9a-f]{64})$/.exec(cur);
  if (!m) { console.error(`인라인 핀 형식 불량(repo:sha-*@sha256:*): ${cur}`); process.exit(2); }
  const [, pinRepo, curTag, curDigest] = m;
  if (expectCurrent !== undefined && curTag !== expectCurrent) {
    console.error(`expect-current 불일치: 기대 ${expectCurrent}, 실제 ${curTag} — bump 중단(race)`); process.exit(3);
  }
  if (curTag === tag && curDigest === digest) { console.log(`bump: ${targetPath} already ${tag}@${digest} (no-op)`); process.exit(0); }
  node.value = `${pinRepo}:${tag}@${digest}`;
  node.comment = ` sha-${tag.slice(4, 11)} + digest 인라인 핀(불변)`; // lineComment 갱신(stale short-sha 방지)
  writeFileSync(targetPath, doc.toString());
  console.log(`bump(inline): ${targetPath} ${cur} -> ${node.value}`);
  process.exit(0);
}
```

(기존 라인 38-69 values.yaml 경로는 그대로 — 인라인 분기가 `process.exit`으로 종료하므로 non-pin에만 도달.)

**Step 4** — 재실행 + 회귀 gate:

```bash
bats tools/tests/test_bump.bats     # 인라인 5 + 기존 apps/ 케이스 전부 PASS
bun tools/bump-tag.ts               # usage(exit 2) — 인자 파서 무회귀
make ci
```
기대: 전 PASS.

**Step 5** — 커밋:

```bash
git add tools/bump-tag.ts tools/tests/test_bump.bats
git commit -m "feat: bump-tag 인라인 핀 편집 모드(--pin 디스크립터)"
```

---

### B9.5 bump-poll.yaml 배선 + files 디스크립터/source-repo 생성

**목표** bump-poll의 bump 루프가 plan의 `.pin`/`.writePath`를 소비해 apps·베스포크 레인을 단일 코드로 처리하게 하고, files에 실제 디스크립터·source-repo를 심어 자동 bump에 합류시킨다.

**Files:**
- Modify: `.github/workflows/bump-poll.yaml` (bump 루프 88-105)
- Create: `platform/files/prod/source-repo`, `platform/files/prod/.image-pin.json`, `platform/files/prod/test_files_imagepin.bats`
- Test: `tools/tests/test_bump-poll-toctou.bats` (배선 grep 2 케이스), `platform/files/prod/test_files_imagepin.bats` (계약 4 케이스)

**Step 1** — 실패 테스트 작성.

(a) `tools/tests/test_bump-poll-toctou.bats` 말미에 배선 grep 추가:

```bash
@test "bump-poll branches on the bespoke pin descriptor and passes --pin to bump-tag" {
  run grep -E "pin=\\\$\(echo .*jq -r '\.pin // empty'\)" "$F"
  [ "$status" -eq 0 ]
  run grep -E 'bump-tag\.ts .*--pin' "$F"
  [ "$status" -eq 0 ]
}

@test "bump-poll git-adds the planner writePath (unifies apps and bespoke lanes)" {
  run grep -E 'git add "\$writePath"' "$F"
  [ "$status" -eq 0 ]
}
```

(b) files 계약 가드 `platform/files/prod/test_files_imagepin.bats` (신규 — jq/yq-only·CI-safe·gate 자동 수집):

```bash
#!/usr/bin/env bats
# files 베스포크 이미지 핀 레인 계약: source-repo + .image-pin.json이 deployment.yaml 인라인 핀을
# 정확히 가리키는지 회귀 가드(bump-poll 2차 순회 전제). jq/yq-only(CI-safe). @test 이름 영어.
setup() { C="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "source-repo binds files to its ukyi-app repo (poll-ghcr discovery key)" {
  run cat "$C/source-repo"
  [ "$output" == "ukyi-app/files" ]
}

@test "image-pin descriptor points at the deployment inline image scalar" {
  run jq -r '.file' "$C/.image-pin.json"
  [ "$output" == "deployment.yaml" ]
  run jq -c '.path' "$C/.image-pin.json"
  [ "$output" == '["spec","template","spec","containers",0,"image"]' ]
}

@test "descriptor path resolves to a repo:sha@digest inline pin in deployment.yaml" {
  run yq '.spec.template.spec.containers[0].image' "$C/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '^ghcr\.io/ukyi-app/files:sha-[0-9a-f]{7,40}@sha256:[0-9a-f]{64}$'
}

@test "descriptor autoDeploy is a boolean the fail-closed gate can read" {
  run jq -e '.autoDeploy | type == "boolean"' "$C/.image-pin.json"
  [ "$status" -eq 0 ]
}
```

**Step 2** — 실행(기대 실패):

```bash
bats tools/tests/test_bump-poll-toctou.bats tools/tests/test_bump.bats platform/files/prod/test_files_imagepin.bats
```
기대: 배선 grep FAIL(bump-poll 미수정)·files 계약 FAIL(source-repo/.image-pin.json 부재).

**Step 3** — 최소 구현.

(a) files 데이터 파일 생성:
- `platform/files/prod/source-repo` (내용, 개행 포함):
  ```
  ukyi-app/files
  ```
- `platform/files/prod/.image-pin.json`:
  ```json
  {
    "file": "deployment.yaml",
    "path": ["spec", "template", "spec", "containers", 0, "image"],
    "autoDeploy": true
  }
  ```
  (`autoDeploy: true` — 이미지 bump는 데이터 무변이·파드 롤링뿐이라 auto-merge 채택. 데이터 내구성은 B5 Retain+백업 담당. false로 두면 propose-pr이 10분마다 새 PR을 여니 부적합 — ⚠️ 설계 보정 참조.)

(b) `.github/workflows/bump-poll.yaml` bump 루프 수정. 현재 88-91의 필드 추출 다음에 `pin`/`writePath` 추가하고, 102-104의 bump-tag 호출·git add를 분기화. 라인 88-105 블록을 아래로 교체:

```yaml
            app=$(echo "$item" | jq -r .app)
            tag=$(echo "$item" | jq -r .candidate.tag)
            digest=$(echo "$item" | jq -r .candidate.digest)
            action=$(echo "$item" | jq -r .action)
            pin=$(echo "$item" | jq -r '.pin // empty')          # 베스포크 레인만 세팅(apps는 empty)
            writePath=$(echo "$item" | jq -r .writePath)          # git add 대상(두 레인 통일)
            # 플래너 출력도 한 번 더 정제(심층 방어) — bump-tag.ts가 재검증한다
            case "$app" in ''|*[!a-z0-9-]*) echo "skip suspicious app: '$app'"; continue ;; esac
            git checkout main
            branch="bump-poll/${app}-${RUN_ID}"
            git checkout -b "$branch"
            # races-4 TOCTOU 가드: 플래너가 증명한 from-tag는 plan JSON의 `.current.tag`(plan 시점 스냅샷)다.
            # ⚠️ codex pass1 F2: checkout main 후 values/deployment에서 다시 읽으면 main이 움직여도 그 값이
            # 같이 움직여 "자기 자신과 비교"가 돼 가드가 no-op이 된다 → 반드시 플래너 스냅샷($item.current.tag)을 쓴다.
            expect=$(echo "$item" | jq -r '.current.tag')
            if [ -n "$pin" ]; then
              bun tools/bump-tag.ts "$app" "$tag" --digest "$digest" --expect-current "$expect" --pin "$pin"
            else
              bun tools/bump-tag.ts "$app" "$tag" --digest "$digest" --expect-current "$expect"
            fi
            # digest-exporter APPS 신선도(codex pass2 P2-2): sha-* 태그는 불변이라 배포 핀만 갱신하면
            # ImageDigestDrift(B2)가 stale 참조로 거짓 드리프트를 낸다 — bump-tag.ts가 같은 실행에서
            # APPS의 동일 앱 항목 태그를 동기 갱신(항목 부재=no-op), 같은 커밋에 포함한다.
            git add "$writePath" platform/victoria-stack/prod/digest-exporter.yaml
            git commit -m "chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)"
            git push -u origin "$branch"
```

(라인 107 이후 `if [ "$action" = "bump" ]` PR 생성/auto-merge 블록은 불변.)

(c) **`tools/bump-tag.ts`에 digest-exporter APPS 동기 추가**(codex pass2 P2-2): 핀 갱신 성공 시 `platform/victoria-stack/prod/digest-exporter.yaml`의 APPS에서 같은 앱(`ghcr.io/ukyi-app/<app>`) 항목의 태그를 동일 값으로 갱신(항목 부재=no-op — 정보성 로그만). 회귀 테스트 2개를 `tools/tests/test_bump.bats`에 추가: ① APPS 항목 보유 앱 bump → 배포 핀과 APPS 태그가 **같은 값**으로 동시 갱신, ② APPS 항목 없는 앱 bump → exporter 파일 바이트 불변. (B2의 APPS 태스크에 상호참조 주석 1줄: "bump 경로의 신선도 동기는 bump-tag.ts가 담당 — B9(c)".)

**Step 4** — 재실행 + 전체 gate + 라이브 렌더 무회귀:

```bash
bats tools/tests/test_bump-poll-toctou.bats tools/tests/test_bump.bats platform/files/prod/test_files_imagepin.bats
# 신규 데이터 파일이 kustomize 렌더를 깨지 않는지(source-repo/.image-pin.json은 resources 미포함 → 무시)
kustomize build platform/files/prod >/dev/null && echo "render OK"
make ci
```
기대: 배선·계약 케이스 PASS, `render OK`(kustomization.yaml resources 명시라 비-매니페스트 무시), gate 전체 PASS.

**Step 5** — 커밋:

```bash
git add .github/workflows/bump-poll.yaml \
  platform/files/prod/source-repo platform/files/prod/.image-pin.json \
  platform/files/prod/test_files_imagepin.bats
git commit -m "feat: files 베스포크 이미지 핀 레인 배선(source-repo·.image-pin.json·bump-poll)"
```

**PR-9b 생성·머지** — 3 커밋(B9.3·B9.4·B9.5). ⚠️ 머지 즉시 라이브 bump-poll(10분 주기)이 files를 플랜에 편입 — 아래 라이브 검증 참조.

---

### B9.6 reserved-hosts.json SSOT + dns.tf 소비

**목표** dns.tf:19의 하드코딩 `platform_hosts`를 `reserved-hosts.json`(FQDN 배열)에서 소비하도록 이관 — 예약 host의 단일 SSOT를 만든다(4소비자 공유의 근원).

**Files:**
- Create: `infra/cloudflare/reserved-hosts.json`
- Modify: `infra/cloudflare/dns.tf` (locals 15-19)
- Test: `infra/cloudflare/test_apps_data.bats` (dns.tf 소비 grep — terraform 의존이라 이 파일에), `make tf-validate`

**Step 1** — 실패 테스트 작성. `infra/cloudflare/test_apps_data.bats`의 "dns.tf consumes apps.json" 테스트(라인 13-18) 다음에 추가:

```bash
@test "dns.tf consumes reserved-hosts.json as the platform_hosts SSOT" {
  run grep -E 'jsondecode\(file\(.*reserved-hosts\.json' "$C/dns.tf"
  [ "$status" -eq 0 ]
}
```

**Step 2** — 실행(기대 실패):

```bash
bats infra/cloudflare/test_apps_data.bats
```
기대: 신규 케이스 FAIL(dns.tf가 아직 reserved-hosts.json 미소비). (이 파일은 `.ci-exclude`라 gate 밖·advisory iac-validate에서 실행 — terraform 필요.)

**Step 3** — 최소 구현.

(a) `infra/cloudflare/reserved-hosts.json` 생성(현 dns.tf:19의 2 host를 FQDN으로):

```json
{
  "platform_hosts": [
    "argocd-webhook.ukyi.app",
    "files.ukyi.app"
  ]
}
```

(b) `infra/cloudflare/dns.tf` locals 라인 15-19를 아래로 교체(주석은 소비 SSOT로 갱신, dns.tf:6의 `jsondecode(file())` 패턴 미러):

```hcl
  # 플랫폼 공개 host — 코드 고정(구조적), 앱이 아님. reserved-hosts.json이 SSOT(dns.tf·create-app·
  # test_apps_structure·dns-drift 4소비자 공유). apps.json(앱 레지스트리, 데이터 합류·자동 회수)과
  # 분리한다 — 예약 host는 자동 회수 대상이 아니라 destroy 가드 allowlist(^cloudflare_dns_record\.app\[)
  # 비대상이라 apex/www처럼 무인 삭제로부터 보호된다.
  # argocd-webhook: ArgoCD /api/webhook만 공개(UI는 내부 전용). files: 베스포크 컴포넌트 다운로드 표면.
  site_hosts     = toset([var.zone_name, "www.${var.zone_name}"])
  platform_hosts = toset(jsondecode(file("${path.module}/reserved-hosts.json")).platform_hosts)
```

(주의: 기존 라인 14의 `site_hosts` 정의를 위 블록으로 함께 옮겨 순서 유지 — `public_hosts`(라인 21)가 site/platform/app 합집합을 참조하므로 정의 순서 불변 확인.)

**Step 4** — 재실행 + terraform 정합:

```bash
bats infra/cloudflare/test_apps_data.bats     # 소비 grep PASS + terraform validate PASS
make tf-validate                               # 3 루트 fmt+validate
# plan 무-diff 확인(값 동일: argocd-webhook + files — 소스만 JSON으로 이동)
cd infra/cloudflare && terraform plan -detailed-exitcode || echo "plan exit=$? (2=diff)"
```
기대: validate PASS. `platform_hosts` 값이 이전과 동일(같은 2 host)이라 terraform plan은 **no-op**(exit 0) — 라이브 DNS 무영향.

**Step 5** — 커밋:

```bash
git add infra/cloudflare/reserved-hosts.json infra/cloudflare/dns.tf infra/cloudflare/test_apps_data.bats
git commit -m "refactor: dns.tf platform_hosts를 reserved-hosts.json SSOT로 이관"
```

---

### B9.7 예약 host SSOT 3소비자 배선 (create-app · apps-structure · dns-drift)

**목표** 나머지 3소비자가 `reserved-hosts.json`을 인지하게 배선 — create-app 예약어 검사(M11: files/argocd-webhook 무인지 해소), apps.json 충돌 가드, dns-drift의 platform_hosts 감시(M11 dns-drift 갭).

**Files:**
- Modify: `tools/create-app.ts` (예약 검사 블록 115-119)
- Modify: `infra/cloudflare/test_apps_structure.bats` (구조 검사 2 케이스 추가)
- Modify: `tools/dns-drift-check.ts` (imports 4·appsPath 8 직후·apps 루프 34-39 뒤)
- Test: `tools/tests/test_create-app.bats` (setup 픽스처 + 예약 거부 1 케이스), `tools/tests/test_dns-drift-check.bats` (1 케이스), `infra/cloudflare/test_apps_structure.bats`

**Step 1** — 실패 테스트 작성.

(a) `tools/tests/test_create-app.bats` setup()에 reserved-hosts.json 픽스처 추가(라인 19 `echo '[]' > ...apps.json` 다음):

```bash
  echo '{"platform_hosts":["argocd-webhook.ukyi.app","files.ukyi.app"]}' > "$FR/infra/cloudflare/reserved-hosts.json"
```
그리고 예약 거부 케이스 추가(말미):

```bash
@test "create-app rejects a reserved platform host (reserved-hosts.json SSOT)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: files.ukyi.app }
EOF
  run bun "$ROOT/tools/create-app.ts" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain ukyi.app --repo-root "$FR" \
    --digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    --tag sha-aaa1111000000000000000000000000000000000
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "예약 host"
}
```
(기존 케이스는 `--domain example.com`·public host가 `*.example.com`이라 ukyi.app 예약과 무충돌 → green 유지.)

(b) `infra/cloudflare/test_apps_structure.bats` 말미에 구조 검사 추가:

```bash
@test "reserved-hosts.json is valid and lists fully-qualified platform hosts" {
  run jq -e '(.platform_hosts | type) == "array" and (.platform_hosts | length) > 0 and (.platform_hosts | all(test("\\.ukyi\\.app$")))' "$C/reserved-hosts.json"
  [ "$status" -eq 0 ]
}

@test "apps.json hosts do not collide with reserved platform hosts (reserved-hosts.json SSOT)" {
  # 예약 host(platform_hosts)를 앱이 등록하면 Gateway 오라우팅 — apps.json은 예약 host를 못 가진다.
  run jq -e -n --slurpfile a "$C/apps.json" --slurpfile r "$C/reserved-hosts.json" \
    '($r[0].platform_hosts // []) as $rh | all($a[0][]; .host as $h | ($rh | index($h)) == null)'
  [ "$status" -eq 0 ]
}
```

(c) `tools/tests/test_dns-drift-check.bats` 말미에 예약 host 감시 추가:

```bash
@test "reserved platform hosts from the SSOT are checked for drift (M11 platform_hosts gap)" {
  d="$BATS_TEST_TMPDIR"
  printf '[]\n' > "$d/apps.json"
  printf '{"platform_hosts":["files.ukyi.app","argocd-webhook.ukyi.app"]}\n' > "$d/reserved.json"
  # files는 NXDOMAIN(미apply), argocd-webhook은 resolve
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --reserved "$d/reserved.json" \
    --fixture '{"argocd-webhook.ukyi.app":["104.21.0.1"]}')
  echo "$out" | jq -e '.drift[] | select(.host=="files.ukyi.app" and (.reason|test("예약 platform host")))'
  echo "$out" | jq -e '.drift | length == 1'
}
```

**Step 2** — 실행(기대 실패):

```bash
bats tools/tests/test_create-app.bats infra/cloudflare/test_apps_structure.bats tools/tests/test_dns-drift-check.bats
```
기대: create-app 예약 거부 FAIL(현재 files.ukyi.app는 apex/www/home-suffix 검사 통과 → 미거부)·apps_structure 신규 FAIL(reserved-hosts.json 미참조)·dns-drift 신규 FAIL(`--reserved` 미인식·예약 루프 없음).

**Step 3** — 최소 구현.

(a) `tools/create-app.ts` 예약 검사 블록(라인 115-119)을 아래로 교체(reserved-hosts.json 소비 추가):

```ts
if (served && pub) {
  const reserved = new Set<string>(
    JSON.parse(readFileSync(`${ROOT}/infra/cloudflare/reserved-hosts.json`, "utf8")).platform_hosts ?? [],
  );
  if ([DOMAIN, `www.${DOMAIN}`].includes(host) || host.endsWith(`.home.${DOMAIN}`) || reserved.has(host)) fail(`예약 host: ${host}`);
  if (registry.some((r: any) => r.name === app)) fail(`apps.json에 name '${app}' 이미 존재`);
  if (registry.some((r: any) => r.host === host)) fail(`apps.json에 host '${host}' 이미 존재(오라우팅 차단)`);
}
```

(b) `tools/dns-drift-check.ts`:
- 라인 4 `import { readFileSync } from "node:fs";` 다음에 추가:
  ```ts
  import { dirname, join } from "node:path";
  ```
- 라인 8-9(`const appsPath = ...` / `const fixture = ...`) 다음에 예약 경로 파생(--apps 형제 기본 — tmp-fixture 회귀 0):
  ```ts
  const reservedPath = arg("--reserved") ?? join(dirname(appsPath), "reserved-hosts.json");
  ```
- apps 루프 종료(라인 39) 다음, `console.log`(라인 41) 앞에 예약 host 루프 삽입:
  ```ts
  // 예약 platform host(reserved-hosts.json SSOT) — 구조적으로 항상 public&&active라 반드시 resolve돼야
  // 한다. M11: apps.json만 감시하던 dns-drift가 argocd-webhook/files를 놓치던 갭 해소. 파일 부재는
  // 빈 목록(tmp-fixture 테스트 무영향 — 형제 파일 없음).
  let reservedHosts: string[] = [];
  try { reservedHosts = JSON.parse(readFileSync(reservedPath, "utf8")).platform_hosts ?? []; } catch { reservedHosts = []; }
  for (const host of reservedHosts) {
    const recs = await resolve(host);
    if (recs === null) drift.push({ host, name: "platform", reason: "NXDOMAIN — 예약 platform host인데 DNS 레코드 미존재(apply 누락 의심)" });
    else if (recs === undefined) transient.push({ host, name: "platform", reason: "resolve 일시 실패(SERVFAIL/timeout) — drift 아님, 재확인 필요" });
  }
  ```

**Step 4** — 재실행 + 전체 gate:

```bash
bats tools/tests/test_create-app.bats infra/cloudflare/test_apps_structure.bats tools/tests/test_dns-drift-check.bats
bun tools/dns-drift-check.ts --help 2>/dev/null; bun tools/create-app.ts 2>&1 | grep -q usage   # 파서 무회귀
make ci
```
기대: 신규 3 케이스 PASS + 기존 dns-drift 3·create-app 다수 PASS(형제 부재→예약 빈 목록·example.com 무충돌), gate 전체 PASS.

**Step 5** — 커밋:

```bash
git add tools/create-app.ts tools/dns-drift-check.ts \
  tools/tests/test_create-app.bats tools/tests/test_dns-drift-check.bats \
  infra/cloudflare/test_apps_structure.bats
git commit -m "feat: 예약 host SSOT 3소비자 배선(create-app·apps-structure·dns-drift)"
```

**PR-9c 생성·머지** — 2 커밋(B9.6·B9.7). tf 변경은 무-diff(plan no-op)라 라이브 DNS 무영향.

---

### 게이트·라이브 검증

**게이트(각 PR 필수)**:
```bash
make ci            # gate 재현 — run-bats CI-safe 전수 + chart-test
make tf-validate   # PR-9c: cloudflare 루트 fmt+validate
```
기대: 전 PASS. PR-9b는 `platform/files/prod/test_files_imagepin.bats`(신규·git tracked)가 run-bats에 자동 편입돼 gate가 files 핀 계약을 보호.

**라이브(owner-local, `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`)**:
- PR-9b 머지 후, 다음 bump-poll 주기(≤10분) 또는 수동 dispatch에서 files가 플랜에 편입되는지:
  ```bash
  # owner-local: reader/writer App 토큰 환경에서 플래너만 dry-run(부작용 0)
  GH_TOKEN=<reader> bun tools/poll-ghcr.ts --dry-run | jq '.[] | select(.app=="files")'
  # 라이브 현재 핀 == git 핀 확인(드리프트 0)
  kubectl -n files get deploy files -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
  ```
  기대: files 플랜이 `noop`(main tip == 배포 SHA)이거나, 신규 릴리스가 있으면 `bump`+auto-merge PR 1건. 라이브 image == `deployment.yaml:28` 핀.
- PR-9c 머지 후 예약 host 감시·DNS 해석:
  ```bash
  bun tools/dns-drift-check.ts --apps infra/cloudflare/apps.json | jq '.drift, .transient'
  dig +short files.ukyi.app; dig +short argocd-webhook.ukyi.app
  ```
  기대: `.drift == []`(argocd-webhook·files 둘 다 anycast IP resolve), dig가 Cloudflare IP 반환.

### 롤백 노트
- **PR-9a(docs)**: revert만 — 라이브 영향 0.
- **PR-9b**: revert 시 `platform/files/prod/source-repo`·`.image-pin.json` 제거 → poll-ghcr platform 루프가 files를 발견 못 함 → 수동 bump PR 체제 복귀(deployment.yaml:28 직접 편집). 이미 머지된 auto-bump는 정상 배포본이라 되돌릴 필요 없음. bump-poll.yaml/`poll-ghcr.ts`/`bump-tag.ts` 코드 revert는 apps/ 레인 무영향(추가만·apps 경로 불변).
- **PR-9c**: `platform_hosts` 값이 이관 전후 **동일**(argocd-webhook + files)이라 terraform plan no-op — DNS 무변경. revert 시 dns.tf 하드코딩 복귀(reserved-hosts.json 삭제)도 plan no-op. create-app/dns-drift 소비자는 파일 부재 시 fail-closed(create-app은 read 실패→exit)이므로 revert는 3파일 동시.

### 다음 배치 진행 조건
- PR-9a·9b·9c 전부 gate 통과 + 직렬 머지 완료.
- 라이브: bump-poll이 files를 플랜에 편입(noop 또는 정상 bump 관측), files 라이브 image == git 핀, dns-drift `.drift == []`.
- B10(메모리 헤드룸)·B11(cross-repo)와 독립 — B9 완료가 그들의 선행 조건은 아니나, B11의 files 관련 계약 정합(reusable thin-caller)은 B9 핀 레인과 무간섭임을 확인 후 진행.
## B10. 메모리 헤드룸 캠페인 (~288Mi 회수) (Wave 2)

⚠️ **설계 보정** (실파일 실측 — 설계 §4 B10·§7 리스크와 어긋나는 지점):

1. **GOMEMLIMIT 처리가 워크로드마다 다르다.** 설계는 "GOMEMLIMIT 동반 조정(Go 워크로드 limit의 90%)"을 3종 전부에 균일 적용하는 듯 서술하나, 실측 결과:
   - **vmsingle** — 리터럴 `GOMEMLIMIT: "920MiB"`(`platform/victoria-stack/prod/vmsingle.yaml:40`). limit 축소 시 **수동 동반 갱신 필수**. B2가 `check-resource-limits.sh`에 `GOMEMLIMIT ≤ limit×0.95` 검사를 추가하므로(선행 배치), 미갱신 시 gate FAIL.
   - **argocd repo-server** — **GOMEMLIMIT 미설정**(`platform/argocd/bootstrap-values.yaml:67-69`). argo-helm 차트는 repo-server에 GOMEMLIMIT을 배선하지 않는다. repo-server 메모리는 Go 힙이 아니라 **하위 프로세스(kustomize/helm inflation/ksops exec 렌더)** 지배적이라 GOMEMLIMIT은 효과가 제한적 → **신규 추가하지 않는다**(추가 시 렌더 버스트는 못 잡고 Go GC만 과격해져 오히려 렌더 지연). limit만 축소.
   - **sealed-secrets** — 차트가 `resourceFieldRef: {resource: limits.memory, divisor: "1"}`로 GOMEMLIMIT을 **limit에서 자동 파생**(`platform/sealed-secrets/prod/charts/sealed-secrets-2.19.0/sealed-secrets/templates/deployment.yaml:174-180`). 즉 GOMEMLIMIT = limit(바이트, **100%** — 90% 아님)이며 limit 축소 시 **자동으로 따라 내려간다 → env 수동 편집 불요**. (100%는 차트 고정 동작이라 override하려면 차트 env 블록을 꺼야 하는데 비목표.)

2. **check-resource-limits.sh 스캔 범위**: `platform/**/*.yaml` 중 `/charts/`·barman 제외(`scripts/check-resource-limits.sh:64`). 따라서 3 대상 중 **vmsingle.yaml만 스캔 대상**(raw StatefulSet). repo-server(helm values)·sealed-secrets(차트 렌더본)는 스캔 밖 — 원장 산문의 "local-helm 등은 check-resource-limits 스캔 밖이라 수기 계상"(`docs/memory-ledger.md:27`)과 일치. ⇒ **vmsingle만** B2 GOMEMLIMIT 게이트의 자동 검증을 받는다.

3. **원장 행은 집계 행**이다. `observability`(2208)·`argocd`(1472)는 서브워크로드 합, `sealed-secrets`(128)만 단일. 개별 워크로드 회수는 해당 **집계 행에서 delta를 차감**한다(예: vmsingle −128 → observability 행 2208→2080).

4. **원장 산문에 선재 드리프트 2건 — B10 범위 아님**: (a) 모델 주석 "limit 합(현재 8892)/잔여 324"(`memory-ledger.md:12,20`)는 files 온보딩(+128) 전 수치라 표 합계(9020)·게이트 실측과 불일치. (b) observability 집계 행(2208)도 라이브 서브워크로드 합(~2272, glances는 별도 행이라 제외)과 ~64Mi 드리프트. **둘 다 B12(원장 산문 수치 정합) 소관**. B10은 vmsingle delta만 집계 행에 반영하고, "합계" 행(line 51)과 회수-완료 주석만 갱신한다.

5. **명목 잔여 실측 = 196Mi.** 표 합계 limit=9020, budget=9216(`memory-ledger.md:30`) ⇒ 9216−9020 = **196Mi**(설계 §0 성공기준·§4 B10 서술과 일치; 게이트가 읽는 값은 행 합계이지 산문 8892가 아님). 목표 회수 288Mi ⇒ 잔여 **484Mi**(성공기준 450Mi+ 충족).

---

**목표**: medium-risk 상주 워크로드 3종(sealed-secrets·argocd repo-server·vmsingle)의 memory limit을 라이브 peak 실측 기반으로 축소해 원장 명목 잔여를 **196Mi → 484Mi**로 회복, 다음 앱 온보딩(256Mi 프로필)부터의 게이트 차단을 해소한다. 회수 총합은 원장이 식별한 **안전 마진 상한 ~288Mi**를 넘지 않는다(그 이상은 working 헤드룸 잠식).

**선행 조건**:
- **B2 머지 완료** — `check-resource-limits.sh`의 `GOMEMLIMIT ≤ limit×0.95` 검사 + vmalert GOMEMLIMIT(64→57MiB) 정정. B10의 vmsingle PR은 이 게이트로 GOMEMLIMIT 정합을 자동 검증받는다(선행이 아니면 GOMEMLIMIT>limit 역전이 gate를 통과해 런타임 OOM 위험).
- **라이브 클러스터 접근** — `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`(kubeconfig는 gitignored라 **메인 체크아웃에서만** 존재, 이 워크트리엔 부재). vmsingle TSDB 히스토리 질의·`kubectl top`·OOM 관측에 필수.
- **직렬 머지**(스택 squash 함정 회피): PR-10a 머지 + 라이브 관측 안정 확인 → PR-10b → PR-10c. 각 PR은 **직전 PR 머지 후의 main에서 분기**한다(원장 "합계" 행이 순차 갱신되므로 미분기 시 line 51 충돌).

**회수 배분**(리스크 낮은 순 — blast-radius 기준: sealed-secrets < repo-server < vmsingle):

| 순서 | 워크로드 | 파일 | limit 축소 | GOMEMLIMIT | 원장 집계 행 |
|---|---|---|---|---|---|
| PR-10a | sealed-secrets | `values-sealed-secrets.yaml:7` | 128→**64Mi**(−64) | 자동(resourceFieldRef→64Mi) | `sealed-secrets` 128→64 |
| PR-10b | argocd repo-server | `bootstrap-values.yaml:69` | 384→**288Mi**(−96) | 없음(미설정 유지) | `argocd` 1472→1376 |
| PR-10c | vmsingle | `vmsingle.yaml:45` | 1Gi(1024)→**896Mi**(−128) | 920→**800MiB** | `observability` 2208→2080 |

합계 −288Mi → 표 합계 limit 9020→**8732**, 명목 잔여 **484Mi**.

**PR 구성**:
- PR-10a "refactor: sealed-secrets 메모리 limit 128→64Mi right-size(원장 헤드룸 회복)"
- PR-10b "refactor: argocd repo-server 메모리 limit 384→288Mi right-size"
- PR-10c "refactor: vmsingle 메모리 limit 1Gi→896Mi right-size(GOMEMLIMIT 800MiB 동반)"

> **Test 방침**(전 태스크 공통): B10은 config 튜닝(신규 로직 0)이므로 **신규 bats 미추가**(과잉 세분화 금지). 재발 가드 SSOT는 **B2의 `GOMEMLIMIT ≤ limit×0.95` 검사**(vmsingle에 적용)와 기존 `verify:ledger`(예산·limit≥req)다 — B10이 그 게이트의 첫 실사용. 각 PR의 **red-first 게이트 = 라이브 pre-flight 안전 단언**(peak×1.5 ≤ 제안 limit; 미달 시 축소 중단/보수화). green 확인 = `check-resource-limits.sh` + `verify:ledger` + 머지 후 ≥48h 라이브 모니터.

---

### 공통 도구: 라이브 working_set 질의 헬퍼 (커밋 안 함 — ephemeral)

메인 체크아웃에서 실행. vmsingle TSDB에 cadvisor `container_memory_working_set_bytes`가 있다(vmagent가 스크레이프). 아래는 **7일 peak(Mi)** 를 뽑고 제안 limit 대비 헤드룸을 단언한다.

```bash
# 메인 체크아웃(gitignored kubeconfig 존재) 전제
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl -n observability port-forward svc/vmsingle 8428:8428 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT; sleep 3

# 인자: $1=namespace, $2=pod regex, $3=제안 limit(Mi). peak×1.5 ≤ limit 이면 PASS.
headroom_assert() {
  local ns="$1" pod="$2" lim="$3"
  local q="max_over_time(container_memory_working_set_bytes{namespace=\"$ns\",pod=~\"$pod\",container!=\"\",container!=\"POD\"}[7d])/1024/1024"
  # yq/jq 버전차 방어: 값만 정확히 추출(.data.result[0].value[1]), 없으면 빈값→FAIL
  local peak
  peak=$(curl -sG 'http://localhost:8428/api/v1/query' --data-urlencode "query=$q" \
           | jq -r '.data.result[0].value[1] // "NaN"')
  awk -v p="$peak" -v l="$lim" 'BEGIN{
    if (p=="NaN"||p==""){print "FAIL: peak 질의 결과 없음(메트릭 부재/포트포워드 실패)"; exit 1}
    hr=l/p;
    printf "peak=%.1fMi  제안limit=%dMi  헤드룸=%.2fx  ", p, l, hr;
    if (p*1.5<=l){print "PASS(≥1.5x)"} else {print "FAIL(<1.5x — 보수화 필요)"; exit 1}
  }'
}
```

각 태스크 Step 1이 이 헬퍼로 red-first 안전 단언을 수행한다.

---

### B10.1 sealed-secrets 메모리 limit right-size (PR-10a)

**Files:** Modify: `platform/sealed-secrets/prod/values-sealed-secrets.yaml:5-7`(resources), `docs/memory-ledger.md:43`(sealed-secrets 행), `docs/memory-ledger.md:51`(합계). Test: 라이브 pre-flight 단언(red-first) + `check-resource-limits.sh`(스캔 밖이라 무영향 확인) + `verify:ledger`.

리스크 최저: sealed-secrets는 소형 stateless 컨트롤러(작동 중 재시작=기존 Secret 유지, 신규 SealedSecret 복호화만 순간 중단). GOMEMLIMIT은 차트가 limit에서 자동 파생하므로 **values의 limit 한 줄만** 내리면 GOMEMLIMIT(=64Mi)도 함께 내려간다.

**Step 1 — red-first 라이브 안전 단언**. 메인 체크아웃에서:
```bash
headroom_assert sealed-secrets 'sealed-secrets-controller.*' 64
```
기대: `peak=~20Mi 제안limit=64Mi 헤드룸=~3x PASS(≥1.5x)`. 만약 peak×1.5 > 64면 96Mi로 보수화(회수 −32)하고 아래 수치를 조정.

**Step 2 — manifest 축소**. `platform/sealed-secrets/prod/values-sealed-secrets.yaml`의
```yaml
resources:
  requests: { cpu: 10m, memory: 32Mi }
  limits: { cpu: 200m, memory: 128Mi }
```
에서 `limits` 줄을 다음으로 교체(req 32Mi 유지 — 64≥32 정합):
```yaml
  limits: { cpu: 200m, memory: 64Mi } # right-size 2026-07(B10): peak ~20Mi, 원장 sealed-secrets 행과 일치. GOMEMLIMIT은 차트가 limits.memory에서 자동 파생(=64Mi)
```

**Step 3 — 원장 행 + 합계 갱신**. `docs/memory-ledger.md` line 43을 열 정렬 보존하며 교체:
- 기존: `| <!-- ledger:row --> sealed-secrets | sealed-secrets |     32 |      128 |`
- 신규: `| <!-- ledger:row --> sealed-secrets | sealed-secrets |     32 |       64 |`

line 51(합계) 교체(직전 PR 없음 → 9020 기준):
- 기존: `**합계:** req ≈ 4815 Mi · limit ≈ 9020 Mi (반드시 ≤ 9216 Mi 유지).`
- 신규: `**합계:** req ≈ 4815 Mi · limit ≈ 8956 Mi (반드시 ≤ 9216 Mi 유지).`

**Step 4 — 게이트**. 워크트리/체크아웃 어디서든(라이브 불요):
```bash
bash scripts/check-resource-limits.sh   # 기대: "check-resource-limits OK (…스캔…)" — sealed-secrets는 /charts/ 렌더라 스캔 밖, 위반 0 불변
bun run verify:ledger                    # 기대: conftest 통과(총합 8956 ≤ 9216, sealed-secrets 64 ≥ req 32)
```
교차 확인(선재 드리프트 아님을 입증 — 행 합이 8956인가):
```bash
bun tools/ledger-to-json.ts docs/memory-ledger.md | jq '[.rows[].limit]|add'   # 기대: 8956
```

**Step 5 — 커밋**:
```bash
git add platform/sealed-secrets/prod/values-sealed-secrets.yaml docs/memory-ledger.md
git commit -m "refactor: sealed-secrets 메모리 limit 128→64Mi right-size

라이브 peak ~20Mi(7일) 대비 3x 헤드룸. GOMEMLIMIT은 차트가 limits.memory에서
자동 파생하므로 별도 갱신 불요. 원장 sealed-secrets 행·합계 동반 갱신(명목 잔여 196→260Mi)."
```

**Step 6 — 머지 후 라이브 모니터**(≥48h, 다음 PR 진행 전). 아래 롤백 노트 판정 기준 참조.

---

### B10.2 argocd repo-server 메모리 limit right-size (PR-10b)

**Files:** Modify: `platform/argocd/bootstrap-values.yaml:67-69`(repoServer.resources), `docs/memory-ledger.md:35`(argocd 행), `docs/memory-ledger.md:51`(합계). Test: 라이브 pre-flight(렌더 버스트 포함 peak) + `verify:ledger`.

리스크 중간: repo-server 메모리는 **kustomize/helm inflation/ksops exec 하위 프로세스** 지배적이라 full re-sync 시 버스트한다(GOMEMLIMIT 미배선 — §설계보정 1). 따라서 peak 질의는 **최근 sync 활동을 포함한 창**이어야 하고, 필요 시 축소 직후 수동 full re-sync로 버스트 peak을 강제 관측한다.

**Step 1 — red-first 라이브 안전 단언**(렌더 버스트 반영):
```bash
headroom_assert argocd 'argocd-repo-server.*' 288
```
기대: `peak=~150-190Mi 제안limit=288Mi 헤드룸=~1.5-1.9x PASS`. peak가 애매하면(1.5x 미달) 축소를 320Mi(−64)로 보수화하거나, 축소 전 강제 렌더 버스트를 유발해 진짜 peak 확인:
```bash
# 최대 렌더 컴포넌트(KSOPS+helm inflation) hard-refresh로 버스트 유도 후 재질의
argocd app get victoria-stack --hard-refresh >/dev/null 2>&1 || true
# 60초 후 headroom_assert 재실행([7d]가 방금 버스트를 포함)
```

**Step 2 — manifest 축소**. `platform/argocd/bootstrap-values.yaml`의 `repoServer:` 블록(line 67-69):
```yaml
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { cpu: 500m, memory: 384Mi }
```
에서 `limits` 줄을 교체(req 128Mi 유지 — 288≥128):
```yaml
    limits: { cpu: 500m, memory: 288Mi } # right-size 2026-07(B10): 렌더 버스트 peak ~180Mi 대비 1.6x. GOMEMLIMIT 미배선(메모리=kustomize/helm/ksops 하위프로세스 지배 → Go 힙 한정 GOMEMLIMIT 부적합)
```

**Step 3 — 원장 행 + 합계 갱신**. line 35(argocd 집계 행: repoServer −96 반영):
- 기존: `| <!-- ledger:row --> argocd         | argocd         |    640 |     1472 |`
- 신규: `| <!-- ledger:row --> argocd         | argocd         |    640 |     1376 |`

line 51(합계, 직전 PR-10a 머지 후 8956 기준):
- 기존: `**합계:** req ≈ 4815 Mi · limit ≈ 8956 Mi (반드시 ≤ 9216 Mi 유지).`
- 신규: `**합계:** req ≈ 4815 Mi · limit ≈ 8860 Mi (반드시 ≤ 9216 Mi 유지).`

**Step 4 — 게이트**:
```bash
bash scripts/check-resource-limits.sh   # repo-server는 helm values라 스캔 밖 — 위반 0 불변
bun run verify:ledger                    # 기대: 총합 8860 ≤ 9216, argocd 1376 ≥ req 640
bun tools/ledger-to-json.ts docs/memory-ledger.md | jq '[.rows[].limit]|add'   # 기대: 8860
```

**Step 5 — 커밋**:
```bash
git add platform/argocd/bootstrap-values.yaml docs/memory-ledger.md
git commit -m "refactor: argocd repo-server 메모리 limit 384→288Mi right-size

렌더 버스트 peak ~180Mi(hard-refresh 포함 7일) 대비 1.6x. repo-server 메모리는
kustomize/helm/ksops 하위 프로세스 지배라 GOMEMLIMIT 미배선 유지. 원장 argocd
집계 행·합계 동반 갱신(명목 잔여 260→356Mi)."
```

**Step 6 — 머지 후 라이브 모니터**. repo-server 재시작(argocd 자기관리 sync) 중 전 앱 매니페스트 생성이 수 초 정지 후 회복 — full re-sync 1회 유발해 OOM 없음·렌더 성공 확인. 롤백 노트 참조.

---

### B10.3 vmsingle 메모리 limit right-size (PR-10c, 최종)

**Files:** Modify: `platform/victoria-stack/prod/vmsingle.yaml:40`(GOMEMLIMIT), `:45`(limit), `docs/memory-ledger.md:38`(observability 행), `:51`(합계), `:23-24`(회수-완료 주석). Test: 라이브 pre-flight + **B2 GOMEMLIMIT 게이트(vmsingle는 스캔 대상)** + `verify:ledger`.

리스크 최고(blast-radius): vmsingle는 중앙 TSDB — OOM 시 전 메트릭·알림 정지. 단 `--memory.allowedPercent=60`(vmsingle.yaml:36)로 **캐시를 cgroup limit에 자동 튜닝**하므로, limit 축소는 in-memory 캐시가 함께 줄어 하드-OOM보다 graceful degradation(캐시 축소)로 흡수된다 — active series working set이 새 예산에 들면 안전. **vmsingle.yaml은 check-resource-limits.sh 스캔 대상**이므로 B2 게이트가 `GOMEMLIMIT(800) ≤ 896×0.95=851.2` 를 자동 검증한다.

**Step 1 — red-first 라이브 안전 단언**:
```bash
headroom_assert observability 'vmsingle.*' 896
```
기대: `peak=~400-500Mi 제안limit=896Mi 헤드룸=~1.8-2.2x PASS`. peak가 597Mi 초과면(1.5x 미달) 축소를 960Mi(−64) 등으로 보수화 — 이 경우 총 회수가 288 미만이 되므로 명목 잔여를 재계산해 ≥450Mi 성공기준 충족 여부 확인(예: 960이면 잔여 452, 여전히 충족).

**Step 2 — manifest 축소(GOMEMLIMIT 동반)**. `platform/victoria-stack/prod/vmsingle.yaml`:
- line 40 교체:
  - 기존: `            - { name: GOMEMLIMIT, value: "920MiB" } # 1Gi limit의 약 90%`
  - 신규: `            - { name: GOMEMLIMIT, value: "800MiB" } # 896Mi limit의 약 89%(B2 게이트 ≤limit×0.95 준수, right-size 2026-07 B10)`
- line 45 교체(req 512Mi 유지 — 896≥512):
  - 기존: `            limits: { memory: 1Gi }`
  - 신규: `            limits: { memory: 896Mi } # right-size 2026-07(B10): peak ~450Mi 대비 ~2x, allowedPercent=60이 캐시를 새 예산에 자동 튜닝`

**Step 3 — 원장 행 + 합계 + 회수-완료 주석 갱신**.
- line 38(observability 집계 행, vmsingle −128 반영):
  - 기존: `| <!-- ledger:row --> observability  | observability  |   1152 |     2208 |`
  - 신규: `| <!-- ledger:row --> observability  | observability  |   1152 |     2080 |`
- line 51(합계, 직전 PR-10b 머지 후 8860 기준):
  - 기존: `**합계:** req ≈ 4815 Mi · limit ≈ 8860 Mi (반드시 ≤ 9216 Mi 유지).`
  - 신규: `**합계:** req ≈ 4815 Mi · limit ≈ 8732 Mi (반드시 ≤ 9216 Mi 유지).`
- line 23-24(모델 주석 회수-완료 반영). 기존 문장
  `회수=vmsingle·repo-server·sealed-secrets ~288Mi, critical-path라 머지 후 모니터 필수).`
  를 다음으로 교체:
  `회수=vmsingle·repo-server·sealed-secrets ~288Mi는 2026-07 B10 캠페인에서 회수 완료(라이브 ≥48h 모니터 통과, 명목 잔여 196→484Mi). 추가 medium-risk 회수분 없음 — 이후 헤드룸은 VM RAM 증설로만).`

**Step 4 — 게이트**(vmsingle는 스캔 대상 → GOMEMLIMIT 검사 실사용):
```bash
bash scripts/check-resource-limits.sh   # 기대: OK. B2 게이트가 GOMEMLIMIT 800 ≤ 896×0.95=851 확인(vmsingle는 raw StatefulSet 스캔 대상)
bun run verify:ledger                    # 기대: 총합 8732 ≤ 9216, observability 2080 ≥ req 1152
bun tools/ledger-to-json.ts docs/memory-ledger.md | jq '[.rows[].limit]|add'   # 기대: 8732
make ci                                  # gate 재현(typecheck+verify:ledger+audit-orphans+skeleton+run-bats) — 전체 green
```

**Step 5 — 커밋**:
```bash
git add platform/victoria-stack/prod/vmsingle.yaml docs/memory-ledger.md
git commit -m "refactor: vmsingle 메모리 limit 1Gi→896Mi right-size(GOMEMLIMIT 800MiB 동반)

라이브 peak ~450Mi(7일) 대비 ~2x. allowedPercent=60이 캐시를 새 cgroup 예산에
자동 튜닝. GOMEMLIMIT 920→800MiB 동반(B2 게이트 ≤limit×0.95 준수). 원장
observability 집계 행·합계·회수-완료 주석 갱신(명목 잔여 356→484Mi)."
```

**Step 6 — 머지 후 라이브 모니터**(캠페인 최종 확인). 롤백 노트 판정 기준 + 알림 파이프 생존 확인.

---

## 게이트·라이브 검증 (배치 말미)

**정적 게이트**(각 PR + 최종, 라이브 불요):
```bash
bash scripts/check-resource-limits.sh    # 기대: "check-resource-limits OK (…스캔…, 위반 0)"
bun run verify:ledger                     # 기대: conftest 통과(무출력·exit 0)
bun tools/ledger-to-json.ts docs/memory-ledger.md | jq '[.rows[].limit]|add'  # 최종 기대: 8732
make ci                                   # 최종 PR에서 gate 전체 재현 green
```
명목 잔여 재계산 단언: `9216 - 8732 = 484 ≥ 450`(성공기준 충족). 회수 총합 = 9020−8732 = **288Mi**(원장 안전 마진 상한 준수).

**라이브 검증**(메인 체크아웃, 각 PR 머지 후 ≥48h — 다음 PR 진행 전):
```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
# 1) OOM 0건 (restartCount 증가·lastState OOMKilled 부재)
kubectl -n sealed-secrets get pod -l app.kubernetes.io/name=sealed-secrets \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
kubectl -n observability get pod -l app.kubernetes.io/name=vmsingle \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
# 기대: restartCount 증가 없음(sync로 인한 1회 rollout 재시작은 정상), reason 칸 공란(OOMKilled 아님)

# 2) working_set이 새 limit의 ≤80% 유지 (헤드룸 소진 없음) — 헬퍼 재사용, [48h] 창
#    sealed-secrets: ≤51Mi / repo-server: ≤230Mi / vmsingle: ≤717Mi

# 3) 워크로드별 기능 생존
#   - vmsingle: /health 200 + 알림 파이프 생존(vmalert 룰 발화 가능·최근 스크레이프 신선)
kubectl -n observability exec deploy/vmalert -- wget -qO- localhost:8880/health 2>/dev/null || true
#     TSDB 신선도(최근 1분 내 데이터 존재):
#     query=count(up)  결과 non-empty & timestamp 최근
#   - repo-server: full re-sync 1회 성공(렌더 OOM/타임아웃 없음)
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
#     기대: 전 앱 Synced/Healthy
#   - sealed-secrets: 신규 SealedSecret 복호화 가능(kubeseal --fetch-cert 성공)
```
판정 기준(다음 PR 진행 조건): **OOMKilled 0 + working_set ≤ 80% limit + 워크로드 기능 정상** 이 ≥48h 유지.

## 롤백 노트

- **1차(권위) 롤백 = PR revert**. 3 대상 모두 GitOps·selfHeal 관리라 라이브 `kubectl patch`는 ArgoCD가 곧 되돌린다(selfHeal flip-flop 트랩). 따라서 정상 롤백은 해당 PR을 `git revert` → ArgoCD가 이전 limit으로 재수렴.
- **긴급(OOM CrashLoop 진행 중, revert 머지 대기 불가)**: selfHeal을 잠깐 끄고 라이브 limit 복구 → revert 머지 후 재활성.
  ```bash
  argocd app set <app> --sync-policy none                 # selfHeal 정지(sealed-secrets|argocd|victoria-stack)
  kubectl -n <ns> patch <deploy|statefulset>/<name> --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"<원값>"}]'
  # 원값: sealed-secrets 128Mi / repo-server 384Mi / vmsingle 1Gi (+ vmsingle GOMEMLIMIT 920MiB 동반 복구)
  # revert PR 머지 후: argocd app set <app> --sync-policy automated --self-heal
  ```
  ⚠️ vmsingle 긴급 복구 시 limit과 GOMEMLIMIT을 **함께** 되돌린다(GOMEMLIMIT만 stale하면 역전).
- **부분 롤백**: 워크로드당 1 PR이라 문제 워크로드만 독립 revert(다른 2건 회수분 유지). revert 시 원장 행·합계도 함께 되돌아가야 정합(revert가 doc 편집도 되돌리므로 자동).

## 다음 배치 진행 조건

- PR-10a → PR-10b → PR-10c **직렬 머지**, 각 사이 라이브 판정 기준 통과(≥48h). 앞 PR 라이브 불안정 시 뒤 PR 착수 금지.
- 최종(PR-10c) 후: `make ci` green + `9216 − (행 합계 8732) = 484Mi ≥ 450` 단언 + 3 워크로드 ≥48h OOM 0 → **B10 종료**. 이 시점에서 원장 산문 재정합(모델 주석 8892/324, observability 집계 ~64Mi 드리프트)은 **B12로 이월**(본 배치 범위 아님 — 설계보정 4).
- B10은 Wave 2 독립 배치(B6~B9와 파일 비중첩 — workflow/tools/docs vs manifest+ledger). 병행 가능하나 **원장 행을 동시 편집하는 배치와는 순차화**(B12가 원장 산문 갱신 시 line 51 합계 충돌 회피 — B10 완료 후 B12 착수 권장).
## B11. cross-repo 계약 (deploy-trigger 흡수·계약 가드·버전 정합) (Wave 3)

**목표** 앱 레포의 `deploy-trigger` 잡을 homelab `reusable-app-build.yaml`으로 흡수해 앱 `release.yaml`을 영구 불변 thin-caller로 축소하고, vendored 사본(seal-secret.mts·cert) 드리프트를 스케줄 리컨실러로 상시 감시하며, bun 핀·배포 계약·문서 표기의 cross-repo 정합을 회복한다.

**선행 조건**
- **B6 머지 완료** — **workflow_dispatch 전수 actor 가드(허용목록=bump-poll)**가 main에 있어야 한다(설계 F1 + codex pass2 P2-1: actions:write는 워크플로 단위 스코프 불가 → 전 진입점 가드가 흡수의 보안 전제). B6 미완이면 이 배치 착수 금지.
- 템플릿 로컬 체크아웃 최신화: `git -C ~/workspace/homelab-app-template fetch origin`(완료 확인 — origin/main에 deploy-trigger 잡·template-ci 존재).

### ⚠️ 설계 보정 (실측이 설계와 어긋난 지점 — 이하 계획은 실측 우선)

1. **`reusable-app-build.yaml`은 이미 build-only다.** 설계 §5 문구("deploy-trigger를 reusable 안으로 흡수")는 맞지만, 현재 deploy-trigger 잡은 homelab이 아니라 **앱 레포 `release.yaml`(page + 템플릿 scaffold)** 에 산다. trip-mate·files는 deploy-trigger가 아예 없는 build-only다. 따라서 "흡수" = deploy-trigger 잡을 앱 `release.yaml`→homelab `reusable-app-build.yaml`으로 **이동**하고 앱 caller는 secrets passthrough만 남긴다.

2. **기존 `test_reusable-app-build.bats:15`가 흡수를 직접 막는다.** 현재 `[ "$(yq -r '.on.workflow_call.secrets // "null"' "$f")" = "null" ]`로 secrets 블록 부재를 단언한다. 흡수는 secrets 블록을 요구하므로 이 테스트는 **재작성**해야 한다(설계의 "reusable inputs 계약 bats 고정"은 이 파일 재작성으로 구현). → B11.1의 test-first 앵커.

3. **vendored 드리프트 매니페스트는 4레포가 아니라 3위치다.** 실측: `seal-secret.mts`·`sealed-secrets-cert.pem`은 **템플릿 scaffold(`scaffold/common/tools/`)·page(`tools/`)·trip-mate-api(`tools/`)** 3곳에만 있다. **files는 Rust 앱(Cargo.lock)이라 seal 도구·cert가 없다**(`secret:seal` 스크립트도 없음). 설계의 "× 템플릿/page/trip-mate/files"에서 files는 제외.

4. **`pnpm secret:seal`→`bun run secret:seal` 정정은 옳다** — 앱 레포는 실측상 bun(`"packageManager": "bun@1.3.10"`, `bun.lock`, `"secret:seal": "bun tools/seal-secret.mts …"`)을 쓴다. 다만 동일 stale `pnpm` 표기가 AGENTS.md:127 외에 **`tools/README.md:85(헤더)·88·16`·`env-example.mts:17`** 에도 있다 — 같은 클래스로 일괄 정정.

5. **흡수 시 `secrets: inherit` 대신 명시 선언을 쓴다.** 설계의 "per-repo 유지·노출면 불변" 요구는 `secrets: inherit`(caller의 전 시크릿을 reusable에 노출 = 노출면 확대)가 아니라 **`on.workflow_call.secrets`에 2개 optional 선언 + caller가 그 2개만 passthrough**로 구현해야 정확히 충족된다(현 release.yaml 노출면=바로 그 2개).

6. **homelab 게이트/호스트 bun은 이미 1.3.14다**(`.github/actions/setup-bun/action.yml:13` + `docs/runbooks-public/toolchain-setup.md:18`). 뒤처진 곳만 정합: template-ci(1.3.10)·trip-mate ci(`latest`)·아키타입 Dockerfile(`oven/bun:1`)·page packageManager(`bun@1.3.10`).

**PR 구성** (직렬 머지 — 스택 squash 함정 회피)
- **PR-11a** "refactor: reusable-app-build에 deploy-trigger 흡수 + 계약 bats 재작성" (homelab) — **최우선 머지**. 앱 caller가 `@main`의 secrets 계약에 의존하므로 이게 main에 없으면 앱 PR이 "secret not defined"로 startup 실패.
- **PR-11b** "feat: 동봉 계약(vendored) 드리프트 리컨실러" (homelab).
- **PR-11c** "chore: cross-repo 계약 정합 — 배포 스키마·renovate 스코프·문서 표기" (homelab).
- **PR-T** (템플릿 레포) "refactor: release.yaml thin-caller화 + bun 1.3.14 정합 + 계약 주간 cron". PR-11a 이후.
- **PR-page / PR-trip / PR-files** (각 앱 레포) thin-caller화 + 버전 정합. 각각 PR-11a 이후, 상호 독립.

---

### B11.1 reusable-app-build deploy-trigger 흡수 + 계약 bats 재작성

**Files:**
- Modify: `.github/workflows/reusable-app-build.yaml` (`on.workflow_call` 블록 14-18행 뒤 `secrets:` 추가 / `jobs.build` 종료 53행 뒤 `deploy-trigger` 잡 추가)
- Modify: `tools/tests/test_reusable-app-build.bats` (전면 재작성 — 5-16행)
- Test: `tools/tests/test_reusable-app-build.bats`

**Step 1 — 실패 테스트(계약 재작성)**: `tools/tests/test_reusable-app-build.bats` 전체를 아래로 교체.

```bash
#!/usr/bin/env bats
# reusable-app-build.yaml cross-repo 계약 가드. deploy-trigger를 앱 release.yaml에서 흡수(B11) —
# 앱 caller는 영구 thin-caller(uses + with.app + dispatch secret 2개 passthrough)로 축소된다.
# ⚠️ 중간 부정 단언은 run+[ ]만(bash3.2 침묵 통과 함정). yq는 CI/로컬 버전차 방어적 추출.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; F="$ROOT/.github/workflows/reusable-app-build.yaml"; }

@test "reusable-app-build: workflow_call build stage present (arm64 GHCR push)" {
  grep -q 'workflow_call' "$F"
  grep -q 'linux/arm64' "$F"
}

@test "reusable-app-build: v1 dispatch path stays retired (no repository_dispatch / dispatch-pat / environment)" {
  run grep -E "repos/.*/dispatches|app-onboard|app-image|environment: production" "$F"
  [ "$status" -ne 0 ]
  run grep -q 'dispatch-pat' "$F"
  [ "$status" -ne 0 ]
}

@test "reusable-app-build: inputs contract is exactly [app] with app required" {
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.on.workflow_call.inputs.app.required // "null"' "$F")" = "true" ]
  keys="$(yq -o=json -r '.on.workflow_call.inputs | keys' "$F" | jq -c 'sort')"
  [ "$keys" = '["app"]' ]
}

@test "reusable-app-build: absorbed deploy-trigger declares exactly 2 optional dispatch secrets (per-repo, no org secret)" {
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.on.workflow_call.secrets.HOMELAB_DISPATCH_APP_ID.required // "null"' "$F")" = "false" ]
  [ "$(yq -r '.on.workflow_call.secrets.HOMELAB_DISPATCH_APP_PRIVATE_KEY.required // "null"' "$F")" = "false" ]
  skeys="$(yq -o=json -r '.on.workflow_call.secrets | keys' "$F" | jq -c 'sort')"
  [ "$skeys" = '["HOMELAB_DISPATCH_APP_ID","HOMELAB_DISPATCH_APP_PRIVATE_KEY"]' ]
}

@test "reusable-app-build: deploy-trigger job absorbed (needs build + preflight-skip + App token + bump-poll dispatch)" {
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.jobs.deploy-trigger.needs // "null"' "$F")" = "build" ]
  grep -q 'create-github-app-token' "$F"
  grep -q 'gh workflow run bump-poll.yaml' "$F"
  grep -q 'configured=false' "$F"   # 시크릿 부재 시 clean skip(preflight)
}
```

**Step 2 — 실행(RED)**: `bats tools/tests/test_reusable-app-build.bats`
기대: `inputs contract`·`declares 2 optional dispatch secrets`·`deploy-trigger job absorbed` 3개 FAIL(현 reusable은 build-only, secrets/deploy-trigger 없음). 앞 2개(build stage·v1 retired)는 PASS.

**Step 3 — 최소 구현**: `.github/workflows/reusable-app-build.yaml` 수정.

(a) `on.workflow_call.inputs` 블록(14-18행) 바로 뒤, 같은 들여쓰기로 `secrets:` 추가:

```yaml
    secrets:
      HOMELAB_DISPATCH_APP_ID:
        description: "homelab bump-poll 즉시 디스패치용 App ID (미전달/미설정 시 즉시 디스패치 skip — homelab 크론이 백스톱). per-repo 유지, org secret 아님."
        required: false
      HOMELAB_DISPATCH_APP_PRIVATE_KEY:
        description: "동 App private key (ID와 쌍)"
        required: false
```

(b) 파일 말미(`jobs.build`의 마지막 주석 53행 뒤)에 `deploy-trigger` 잡 추가:

```yaml
  # 빌드 성공 직후 homelab bump-poll 1회 디스패치(크론 ~60-90분 지연 제거). 앱 release.yaml에서 흡수(thin-caller화).
  # secrets 쌍(ID+KEY) 미전달이면 preflight로 clean skip — bump-poll 크론이 백스톱이라 안전. 하나만 오면 설정 오류 fail(부분 설정이 빌드 후 실패로 새는 것 차단).
  # ⚠️ workflow_call은 caller 컨텍스트 실행 — 노출면은 caller가 넘긴 2개 시크릿 뿐(흡수는 보안 중립).
  #    디스패치 자격 오용 방어는 homelab의 workflow_dispatch 전수 actor 가드(B6, 허용목록=bump-poll)가 담당한다.
  deploy-trigger:
    needs: build
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - id: pre
        env:
          APP_ID: ${{ secrets.HOMELAB_DISPATCH_APP_ID }}
          APP_KEY: ${{ secrets.HOMELAB_DISPATCH_APP_PRIVATE_KEY }}
        run: |
          # 쌍 검증: 둘 다 있어야 진행, 둘 다 없으면 clean skip(크론 백스톱),
          # 하나만 있으면 설정 오류로 즉시 실패 — 부분 설정이 토큰 발급 단계 실패로 새는 것 차단.
          if [ -n "$APP_ID" ] && [ -n "$APP_KEY" ]; then
            echo "configured=true" >> "$GITHUB_OUTPUT"
          elif [ -z "$APP_ID" ] && [ -z "$APP_KEY" ]; then
            echo "configured=false" >> "$GITHUB_OUTPUT"
            echo "::notice::HOMELAB_DISPATCH_APP 미설정 — 즉시 디스패치 skip(homelab 크론 폴링이 백스톱). owner가 앱 레포에 App ID·private key 쌍 추가 시 자동 활성."
          else
            echo "::error::HOMELAB_DISPATCH_APP_ID/PRIVATE_KEY 중 하나만 설정됨 — 쌍으로 설정하거나 둘 다 제거하라."
            exit 1
          fi
      - if: steps.pre.outputs.configured == 'true'
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        id: token
        with:
          app-id: ${{ secrets.HOMELAB_DISPATCH_APP_ID }}
          private-key: ${{ secrets.HOMELAB_DISPATCH_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: homelab
          permission-actions: write
      - if: steps.pre.outputs.configured == 'true'
        name: dispatch homelab bump-poll
        env:
          GH_TOKEN: ${{ steps.token.outputs.token }}
        run: |
          gh workflow run bump-poll.yaml -R ${{ github.repository_owner }}/homelab
          echo "::notice::homelab bump-poll 디스패치 완료 — 곧 digest bump/배포."
```

(c) 파일 상단 계약 주석(6-10행)에서 "homelab dispatch는 없음"·"caller는 secrets 블록을 넘기지 않는다"를 정정: deploy-trigger가 흡수됐고 caller는 dispatch 시크릿 2개를 passthrough함을 명시. 정확 편집: 8-10행의 "빌드 직후 즉시 반영은 앱 release의 bump-poll 디스패치다."·"caller는 secrets 블록을 넘기지 않는다." 문장을 "빌드 직후 즉시 반영은 이 워크플로의 deploy-trigger 잡(흡수됨) — caller는 HOMELAB_DISPATCH_APP_ID/KEY 2개만 passthrough(미전달=크론 백스톱)."로 교체.

**Step 4 — 게이트(GREEN)**: `bats tools/tests/test_reusable-app-build.bats`
기대: 5 tests, 0 failures. 이어 `./scripts/run-bats.sh` 전체 PASS(신규 계약이 다른 가드와 무충돌).

**Step 5 — 커밋**:
```
git add .github/workflows/reusable-app-build.yaml tools/tests/test_reusable-app-build.bats
```
메시지: `refactor: reusable-app-build에 deploy-trigger 흡수(앱 release.yaml thin-caller 계약)`

> **전환 안전성(무 double/zero dispatch)**: PR-11a 머지 후 아직 옛 release.yaml인 page는 caller에서 시크릿을 안 넘기므로 reusable의 deploy-trigger는 skip되고 page 자체 deploy-trigger 잡만 발화(정확히 1회). page/trip/files PR로 thin-caller 전환 시 reusable 쪽 1회로 깔끔히 인계. trip/files는 흡수 후에도 시크릿 미프로비저닝이면 크론-only(현행 무변경).

---

### B11.2 동봉 계약 매니페스트 + 드리프트 리컨실러

**목표** vendored 2파일(seal-secret.mts·cert)이 다운스트림 3위치와 어긋나는지 스케줄 감시(alert-and-report). 라이브 fetch는 워크플로 전용, 게이트는 순수 로직만.

**Files:**
- Create: `tools/vendored-contract.json` (매니페스트 SSOT)
- Create: `tools/contract-drift-check.ts` (bun 체커 — fetch+정규화 diff, `--self-test` 오프라인 모드 포함)
- Create: `.github/workflows/contract-drift.yaml` (dns-drift.yaml 패턴 미러)
- Create: `tools/tests/test_contract-drift.bats` (CI-safe — 매니페스트·정규화 로직만)
- Test: `tools/tests/test_contract-drift.bats`

**Step 1 — 실패 테스트**: `tools/tests/test_contract-drift.bats` 작성.

```bash
#!/usr/bin/env bats
# 동봉 계약 매니페스트·정규화 로직 가드 (CI-safe — 라이브 raw fetch는 contract-drift.yaml 워크플로 전용).
# ⚠️ 중간 부정 단언은 run+[ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; M="tools/vendored-contract.json"; }

@test "vendored-contract manifest is valid JSON with existing local sources" {
  jq -e '.vendored | length > 0' "$M"
  for s in $(jq -r '.vendored[].source' "$M"); do
    [ -f "$s" ] || { echo "누락 source: $s"; return 1; }
  done
}

@test "vendored-contract excludes files repo (Rust — no vendored seal tooling)" {
  run jq -e '[.vendored[].targets[].repo] | index("files")' "$M"
  [ "$status" -ne 0 ]
}

@test "cert targets require exact normalization (public sealing cert must be byte-identical)" {
  n=$(jq -r '[.vendored[] | select(.source|endswith(".pem")) | .targets[] | select(.normalize!="exact")] | length' "$M")
  [ "$n" -eq 0 ]
}

@test "drift checker self-test passes (offline normalize unit — ts whitespace-insensitive, pem exact)" {
  run bun tools/contract-drift-check.ts --self-test
  [ "$status" -eq 0 ]
}
```

**Step 2 — 실행(RED)**: `bats tools/tests/test_contract-drift.bats`
기대: 4개 전부 FAIL(매니페스트·체커 부재).

**Step 3 — 구현**:

`tools/vendored-contract.json`:
```json
{
  "_note": "동봉 계약(vendored) SSOT. homelab tools/*가 원본, 다운스트림은 복사본. files(Rust)는 seal 도구 없어 제외. cert는 exact(공개 봉인 cert 바이트 일치 필수), .mts는 typescript(포매터 재포맷 허용).",
  "owner": "ukyi-app",
  "vendored": [
    {
      "source": "tools/seal-secret.mts",
      "targets": [
        { "repo": "homelab-app-template", "ref": "main", "path": "scaffold/common/tools/seal-secret.mts", "normalize": "typescript" },
        { "repo": "page", "ref": "main", "path": "tools/seal-secret.mts", "normalize": "typescript" },
        { "repo": "trip-mate-api", "ref": "main", "path": "tools/seal-secret.mts", "normalize": "typescript" }
      ]
    },
    {
      "source": "tools/sealed-secrets-cert.pem",
      "targets": [
        { "repo": "homelab-app-template", "ref": "main", "path": "scaffold/common/tools/sealed-secrets-cert.pem", "normalize": "exact" },
        { "repo": "page", "ref": "main", "path": "tools/sealed-secrets-cert.pem", "normalize": "exact" },
        { "repo": "trip-mate-api", "ref": "main", "path": "tools/sealed-secrets-cert.pem", "normalize": "exact" }
      ]
    }
  ]
}
```

`tools/contract-drift-check.ts`:
```ts
// 동봉 계약(vendored 사본) 드리프트 리컨실러. homelab SSOT ↔ 다운스트림 사본 정규화 diff.
// alert-and-report: 하드 실패 아님 — {drift, errors} JSON 출력, contract-drift.yaml이 telegram 알림.
// 라이브 raw fetch는 이 CLI에서만(게이트 bats는 --self-test 오프라인 유닛만 검증).
import { readFileSync } from "node:fs";

type Norm = "typescript" | "exact";
type Target = { repo: string; ref: string; path: string; normalize: Norm };
type Entry = { source: string; targets: Target[] };
type Manifest = { owner: string; vendored: Entry[] };

// 정규화: exact=CRLF만 통일(그 외 바이트 일치), typescript=모든 공백 제거(포매터 재포맷 허용).
const normalize = (s: string, mode: Norm) =>
  mode === "exact" ? s.replace(/\r\n/g, "\n") : s.replace(/\s+/g, "");

if (process.argv.includes("--self-test")) {
  const ok =
    normalize("const a = 1 ;\n", "typescript") === normalize("const   a=1;", "typescript") &&
    normalize("AAAA\r\nBBBB\n", "exact") === "AAAA\nBBBB\n" &&
    normalize("AAAA\nBBBB\n", "exact") !== normalize("AAAAx\nBBBB\n", "exact");
  process.exit(ok ? 0 : 1);
}

const arg = (k: string, d: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const mf: Manifest = JSON.parse(readFileSync(arg("--manifest", "tools/vendored-contract.json"), "utf8"));
const raw = (o: string, t: Target) => `https://raw.githubusercontent.com/${o}/${t.repo}/${t.ref}/${t.path}`;

const drift: unknown[] = [];
const errors: unknown[] = [];
for (const e of mf.vendored) {
  const src = readFileSync(e.source, "utf8");
  for (const t of e.targets) {
    const url = raw(mf.owner, t);
    try {
      const res = await fetch(url);
      if (!res.ok) { errors.push({ url, status: res.status }); continue; }
      const remote = await res.text();
      if (normalize(src, t.normalize) !== normalize(remote, t.normalize))
        drift.push({ source: e.source, repo: t.repo, path: t.path });
    } catch (err) { errors.push({ url, error: String(err) }); }
  }
}
process.stdout.write(JSON.stringify({ drift, errors }, null, 2) + "\n");
```

`.github/workflows/contract-drift.yaml`:
```yaml
# 동봉 계약(vendored: seal-secret.mts·sealed-secrets-cert.pem) 드리프트 리컨실러 (opt-in 스케줄).
# homelab SSOT ↔ 다운스트림(template scaffold·page·trip-mate-api) 정규화 diff. files(Rust)는 대상 아님.
# alert-and-report: 하드 실패 아님 — 드리프트/fetch 실패 시 telegram. 라이브 raw fetch는 이 워크플로 안에서만.
name: "🔁 contract-drift"
run-name: "🔁 contract-drift — ${{ github.event_name == 'schedule' && '스케줄' || format('수동({0})', github.actor) }}"
on:
  schedule:
    - cron: "37 6 * * 1"   # 매주 월 06:37 UTC (vendored는 거의 안 변함)
  workflow_dispatch: {}
permissions:
  contents: read
concurrency:
  group: contract-drift
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-24.04-arm
    steps:
      - name: actor 가드 (workflow_dispatch 한정 — 스케줄 무영향, B6 전수 가드 불변식)
        if: github.event_name == 'workflow_dispatch'
        env:
          ACTOR: ${{ github.actor }}
          OWNER: ${{ vars.HOMELAB_OWNER }}
        run: |
          # B6가 확립한 불변식(codex pass3 P3-1): dispatch 진입점은 허용목록(bump-poll) 외 전부 actor 가드.
          [ -n "$OWNER" ] || { echo "::error::repo variable HOMELAB_OWNER 미설정 — actor 가드 fail-closed"; exit 1; }
          [ "$ACTOR" = "$OWNER" ] || { echo "::error::workflow_dispatch는 owner($OWNER)만 실행 가능 — actor=$ACTOR 거부"; exit 1; }
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0  # v7.0.0 — 로컬 telegram-notify 액션 resolve
      - uses: ./.github/actions/setup-bun
        with: { install: 'false' }     # 체커는 fetch+fs만 — deps 불요
      - id: check
        run: |
          bun tools/contract-drift-check.ts --manifest tools/vendored-contract.json > /tmp/drift.json
          d=$(bun -e 'const o=JSON.parse(require("fs").readFileSync("/tmp/drift.json","utf8"));process.stdout.write(String(o.drift.length))')
          e=$(bun -e 'const o=JSON.parse(require("fs").readFileSync("/tmp/drift.json","utf8"));process.stdout.write(String(o.errors.length))')
          echo "drift=$d" >> "$GITHUB_OUTPUT"
          echo "errors=$e" >> "$GITHUB_OUTPUT"
          [ "$e" -gt 0 ] && echo "::warning::계약 사본 fetch 실패 ${e}건(transient 가능 — 재확인)"
          cat /tmp/drift.json
      - name: telegram notify (드리프트·fetch 실패 시)
        # fetch 실패도 알림(codex pass3 P3-2): errors만 있고 무소음이면 체커가 blind pass — 감시의 감시 공백.
        if: failure() || steps.check.outputs.drift != '0' || steps.check.outputs.errors != '0'
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ steps.check.outputs.drift != '0' && 'drift' || (steps.check.outputs.errors != '0' && 'fetch-error' || job.status) }}
          source: cross-repo계약
          title: 동봉 계약 드리프트
          ident: "vendored 불일치 ${{ steps.check.outputs.drift }}건 · fetch 실패 ${{ steps.check.outputs.errors }}건"
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Step 4 — 게이트**: `bats tools/tests/test_contract-drift.bats` (4 pass) → `bun run typecheck`(신규 .ts 편입) → `./scripts/run-bats.sh`(신규 bats 자동 수집 — git-tracked·CI-safe).
라이브 스모크(선택, 네트워크): `bun tools/contract-drift-check.ts --manifest tools/vendored-contract.json | jq '.drift, .errors'` — 기대 `drift: []`(현재 실드리프트 0, 설계 M18 확인). trip-mate가 포매터로 재포맷돼 있어도 typescript 정규화(공백 제거)로 흡수됨.

**Step 5 — 커밋**:
```
git add tools/vendored-contract.json tools/contract-drift-check.ts .github/workflows/contract-drift.yaml tools/tests/test_contract-drift.bats
```
메시지: `feat: 동봉 계약(vendored 사본) 드리프트 리컨실러 추가`

> **release.yaml 미포함 근거**: 앱 caller `release.yaml`은 files(paths-ignore)·`app:` 리터럴 차이로 바이트-동일이 아니라 벤더 diff 대상이 아니다. caller 계약의 진짜 가드는 B11.1의 reusable 계약 bats(SSOT)이며, thin-caller가 드리프트해도 최악은 크론 백스톱(안전).

---

### B11.3 app-deploy 계약 required에 kustomization.yaml 추가

**Files:**
- Modify: `tools/app-deploy-schema.json` (`.required` 6행 + `.properties` 추가)
- Modify: `tools/tests/test_app-deploy.bats` (positive fixture 14-21행 + 신규 negative)
- Modify: `scripts/check-app-deploy.sh` (34행 산문 메시지만 — 필수목록은 `.required` 동적 소비라 로직 무변)
- Test: `tools/tests/test_app-deploy.bats`

> 소비자 영향 실측: `check-app-deploy.sh:10`은 `.required[]`를 동적으로 읽어 자동 편입(하드코딩 없음). 라이브 in-repo 앱 2곳(page·trip-mate) `deploy/prod`에 이미 `kustomization.yaml` 존재 → 강화 후에도 PASS. `create-app.ts:175-177`이 항상 생성 → 신규 앱 산출물도 계약 충족. **단 `test_app-deploy.bats:14-21` positive fixture는 3파일만 써서 강화 시 깨진다** — 이 태스크가 test-first로 고침.

**Step 1 — 실패 테스트**: `tools/tests/test_app-deploy.bats` 수정.
- 파일 상단 주석(2-3행) "필수 3산출물" → "필수 4산출물(+kustomization.yaml)".
- `@test "positive fixture: deploy/prod with all 3 artifacts passes"`(14행) 이름을 `...all 4 artifacts...`로, 본문(15-18행)에 한 줄 추가:
```bash
  echo "resources: []" > "$d/kustomization.yaml"
```
- 32행(`empty source-repo`) 뒤에 신규 negative 추가:
```bash
@test "negative fixture: missing kustomization.yaml fails (appset kustomize render needs it)" {
  d="$BATS_TEST_TMPDIR/nokust/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/myapp" > "$d/source-repo"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'kustomization.yaml'
}
```

**Step 2 — 실행(RED)**: `bats tools/tests/test_app-deploy.bats`
기대: `missing kustomization.yaml fails` FAIL(현 스키마는 3필수라 kustomization 없어도 통과→status 0→`[0 -ne 0]` 실패). positive fixture는 kustomization 추가로 아직 GREEN(체커가 required-only 검사).

**Step 3 — 구현**: `tools/app-deploy-schema.json`.
- 6행 `"required": ["values.yaml", ".bindings.json", "source-repo"],` → `"required": ["values.yaml", ".bindings.json", "source-repo", "kustomization.yaml"],`
- `.properties`에 항목 추가(`source-repo` properties 블록 뒤, 16행 이후):
```json
    ,"kustomization.yaml": {
      "description": "appset source #3가 kustomize 렌더(namespace: prod + 봉인본 resources). create-app.ts:175-177이 항상 생성 — 없으면 ArgoCD kustomize build 실패."
    }
```
- `scripts/check-app-deploy.sh:34` 성공 메시지 산문을 `...(values.yaml·.bindings.json·source-repo·kustomization.yaml) OK`로.

**Step 4 — 게이트**: `bats tools/tests/test_app-deploy.bats`(전 pass) → `bash scripts/check-app-deploy.sh`(실트리, `... OK`) → `make verify`(skeleton+원장+sops 무영향 확인).

**Step 5 — 커밋**:
```
git add tools/app-deploy-schema.json tools/tests/test_app-deploy.bats scripts/check-app-deploy.sh
```
메시지: `feat: app-deploy 계약 required에 kustomization.yaml 추가`

---

### B11.4 renovate 스코프에 템플릿 추가 + 문서 표기 정정

> B11.3와 같은 PR-11c. 두 응집 변경(renovate 스코프 / 문서 표기)을 한 태스크로 묶되 커밋은 분리.

**Files:**
- Modify: `.github/workflows/renovate.yaml:57` (`RENOVATE_REPOSITORIES`)
- Modify: `AGENTS.md:127`·`tools/README.md:85,88,16`·`tools/env-example.mts:17` (pnpm→bun / env-example 의도)

**Step 1 — renovate 스코프**: `.github/workflows/renovate.yaml:57`
현재: `RENOVATE_REPOSITORIES: ${{ github.repository }} # 자기 레포만 — autodiscover 금지`
교체:
```yaml
          # homelab + 템플릿(oven/bun·setup-bun·@types/bun 핀 갱신). autodiscover는 여전히 금지(명시 목록).
          RENOVATE_REPOSITORIES: "${{ github.repository }},${{ github.repository_owner }}/homelab-app-template"
```
검증: `yq -r '.jobs.renovate.steps[] | select(.env).env.RENOVATE_REPOSITORIES' .github/workflows/renovate.yaml`가 두 레포 포함.

> **owner 수동 절차(주석·런북 기록, 코드 아님)**: (1) writer App(`HOMELAB_WRITER_APP`)의 설치 범위에 `ukyi-app/homelab-app-template` 추가(Contents+PR write). (2) `RENOVATE_ONBOARDING=false`이므로 템플릿 레포에 `renovate.json`이 있어야 스캔됨 → PR-T가 템플릿 레포에 최소 `renovate.json` 동봉(아래). 미완이면 renovate 잡이 템플릿을 skip할 뿐 homelab은 무영향(fail-safe).

**Step 2 — 커밋**:
```
git add .github/workflows/renovate.yaml
```
메시지: `chore: renovate 스코프에 homelab-app-template 추가(bun·액션 핀 갱신)`

**Step 3 — 문서 표기 정정(pnpm→bun + env-example 의도 확정 = (b) homelab SSOT·앱 미배포)**:
실측 근거: 앱 레포는 bun(`packageManager: bun@1.3.10`, `secret:seal → bun tools/seal-secret.mts`). env-example.mts는 homelab `package.json`의 `env:example`만 소비하고 다운스트림 배포 0(설계 원칙 #3=벤더 표면 최소화). 처분 **(b): homelab-resident SSOT·앱 미배포(YAGNI). 배포 필요 시 seal-secret.mts 벤더 패턴 재사용.**

정확 편집:
- `AGENTS.md:127`: `` `pnpm secret:seal`(.env→ `` → `` `bun run secret:seal`(.env→ `` (앞 문장 "앱 레포에서"는 유지).
- `tools/README.md:85` 헤더 `## 앱 시크릿 봉인 (앱 레포 측 — `pnpm` 경유)` → `## 앱 시크릿 봉인 (앱 레포 측 — bun 경유)`.
- `tools/README.md:88`: "앱 레포는 **`pnpm secret:seal`**, homelab은 **`bun run secret:seal`**" → 양쪽 모두 bun: "앱 레포·homelab 모두 **`bun run secret:seal`**(= `bun tools/seal-secret.mts`; `.mts`라 node≥22.18 strip-types 백업 양립)".
- `tools/README.md:16`: `seal-secret.mts`·`env-example.mts`(앱 레포 측)` → `seal-secret.mts`(앱 레포 벤더)·`env-example.mts`(homelab 로컬 전용)`.
- `tools/README.md:111` env-example 설명에 `— homelab 로컬 전용(앱 미배포)` 부기.
- `tools/env-example.mts:17`: 문자열 `"# SealedSecret encryptedData에서 자동 생성 (pnpm env:example) — …"` 의 `(pnpm env:example)` → `(bun run env:example)`.

검증: `! grep -rn 'pnpm secret:seal\|pnpm env:example' AGENTS.md tools/README.md tools/env-example.mts`(매치 0). `make verify`(check-doc-index 등 무영향).

**Step 4 — 커밋**:
```
git add AGENTS.md tools/README.md tools/env-example.mts
```
메시지: `docs: 앱 시크릿 봉인 표기 pnpm→bun 정정 + env-example 처분 명시(homelab 전용)`

---

### B11.5 (템플릿 레포 PR-T) release.yaml thin-caller화 + bun 1.3.14 정합 + 계약 주간 cron

> 별도 레포(`~/workspace/homelab-app-template`). 브랜치에서 작업 → template-ci 통과 후 머지. **PR-11a 머지 후** 착수(scaffold가 `@main`의 secrets 계약에 의존).

**Files (템플릿 레포):**
- Modify: `scaffold/common/.github/workflows/release.yaml` (deploy-trigger 잡 제거 → thin-caller + secrets passthrough)
- Modify: `.github/workflows/template-ci.yaml` (bun 1.3.10→1.3.14 2곳 + `schedule` cron 추가)
- Modify: `scaffold/archetypes/{api,fullstack,site,worker}/Dockerfile` (`FROM oven/bun:1`→`oven/bun:1.3.14`)
- Create: `renovate.json` (최소 — Renovate 스캔 활성)

**Step 1 — thin-caller**: `scaffold/common/.github/workflows/release.yaml` 전체 교체(deploy-trigger 잡 20-49행 삭제, secrets passthrough 추가):
```yaml
# main 머지 = 빌드 + GHCR push. 빌드 로직·즉시 디스패치는 homelab reusable-app-build.yaml이 SSOT(deploy-trigger 흡수).
# 이 파일은 영구 thin-caller — dispatch 시크릿 2개만 passthrough(미설정이면 reusable이 clean skip, 크론 백스톱).
name: release
on:
  push:
    branches: [main]
permissions:
  contents: read
  packages: write
jobs:
  release:
    uses: ukyi-app/homelab/.github/workflows/reusable-app-build.yaml@main
    with:
      app: ${{ github.event.repository.name }}
    secrets:
      HOMELAB_DISPATCH_APP_ID: ${{ secrets.HOMELAB_DISPATCH_APP_ID }}
      HOMELAB_DISPATCH_APP_PRIVATE_KEY: ${{ secrets.HOMELAB_DISPATCH_APP_PRIVATE_KEY }}
```

**Step 2 — bun 정합 + 주간 cron(M18 휴면 해소)**: `.github/workflows/template-ci.yaml`
- 19-20행·84-85행 두 `bun-version: 1.3.10` → `1.3.14`(homelab setup-bun 핀과 정렬).
- `on:`(4-7행)에 `schedule` 추가(push-트리거 전용 → 주1회 `@main` homelab 스키마 재검증으로 단방향 휴면 해소):
```yaml
on:
  push:
    branches: [main]
  pull_request: {}
  schedule:
    - cron: "41 6 * * 1"   # 매주 월 — homelab @main app-config-schema 드리프트 상시 재검증(M18)
```

**Step 3 — 아키타입 base 핀 처분(확정: 버전 태그 핀 + Renovate digest 위임)**: 4개 `scaffold/archetypes/*/Dockerfile:2` `FROM oven/bun:1 AS build` → `FROM oven/bun:1.3.14 AS build`.
> **digest 핀 권장 여부 판단**: 지금 손으로 digest를 박지 않는다 — 스냅샷은 즉시 stale·수기 검증 불가. 대신 (a) 버전 태그 `1.3.14`로 재현성 확보 + (b) 본 PR이 템플릿을 RENOVATE_REPOSITORIES에 편입(B11.4)하므로, `renovate.json`의 `pinDigests:true`가 다음 실행에서 `oven/bun:1.3.14@sha256:…`로 승격·유지. 즉 digest 핀은 **Renovate 유지 레인**으로만 도입(미유지 수기 digest 금지 = 설계 M16 방향).

**Step 4 — 템플릿 `renovate.json`(최소)**: RENOVATE_ONBOARDING=false에서 스캔되려면 config 필요.
```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "pinDigests": true,
  "schedule": ["* 0-6 * * 1"],
  "automerge": false
}
```

**Step 5 — 게이트(템플릿 CI)**: 브랜치 push → `template-ci`(scaffold-build 4아키타입 + scaffold-args) GREEN. 로컬 사전검증: `cd ~/workspace/homelab-app-template && bun install && bun run scaffold --archetype api --name ci-api --yes`(정상) + `docker build scaffold/archetypes/api`가 `oven/bun:1.3.14`로 빌드.

**Step 6 — 커밋(템플릿 레포)**:
```
git add scaffold/common/.github/workflows/release.yaml .github/workflows/template-ci.yaml scaffold/archetypes/api/Dockerfile scaffold/archetypes/fullstack/Dockerfile scaffold/archetypes/site/Dockerfile scaffold/archetypes/worker/Dockerfile renovate.json
```
메시지: `refactor: release.yaml thin-caller화 + bun 1.3.14 정합 + 계약 주간 cron`

> **계약 왕복 스모크 채택 판단(확정: homelab gate 미채택 / template-ci cron 최소안)**: 왕복(template scaffold→create-app --dry-run→helm render)을 homelab required `gate`에 넣으면 (1) 외부 템플릿 `@main` 네트워크 fetch를 required 체크에 편입(hermetic 게이트 원칙 위반)·(2) bun install+helm까지 게이트 시간 수 분 증가. 이득(스키마·비즈니스규칙·차트 3층)은 이미 template-ci의 ajv 검증이 상당부 커버. → **채택하지 않는다.** 최소안=**Step 2의 template-ci 주간 cron**(homelab `@main` 스키마를 주1회 재검증 = M18 단방향 휴면 해소). 왕복 강화는 이득>비용 재평가 시 template-ci cron 잡으로 추가(homelab gate 아님).

---

### B11.6 (앱 레포 PR) page / trip-mate-api / files thin-caller화 + 버전 정합

> 각 앱 레포 브랜치에서 작업. **PR-11a 머지 후** 착수(secrets 계약 `@main` 존재). 앱별 독립·상호 무순서.

#### PR-page (`~/workspace/page`)
**Files:** `.github/workflows/release.yaml`(thin-caller·잔존 가드 제거)·삭제 `tools/scaffold-kind.mts`+`tools/scaffold-kind.test.ts`(폐기 v1 어휘 `service|static|worker` 확인됨)·`package.json`(packageManager 1.3.10→1.3.14).

- `release.yaml` 전체 교체(deploy-trigger 잡 19-52행 + 두 `if: github.repository != …` 잔존 가드 제거 → B11.5 Step1의 thin-caller와 동일 본문. page는 템플릿 레포가 아니라 가드 무의미).
- `git rm tools/scaffold-kind.mts tools/scaffold-kind.test.ts` (page CI에 scaffold-kind 참조 없음 — 실측: homelab tools/scripts에도 참조 0).
- `package.json:6` `"packageManager": "bun@1.3.10"` → `"bun@1.3.14"`.
- 커밋:
```
git add .github/workflows/release.yaml package.json
git rm tools/scaffold-kind.mts tools/scaffold-kind.test.ts
```
메시지: `refactor: release.yaml thin-caller화(deploy-trigger 흡수) + 죽은 scaffold-kind 제거 + bun 1.3.14`

#### PR-trip (`~/workspace/trip-mate-api`)
**Files:** `.github/workflows/release.yaml`(build-only → thin-caller + secrets)·`.github/workflows/ci.yml`(`bun-version: latest`→`1.3.14` 3곳: 17-19·27-29·39-41 라인대).
- `release.yaml`: `jobs.release`에 `secrets:` passthrough 2줄 추가(B11.5 Step1 본문과 동일화 — `app: ${{ github.event.repository.name }}` 유지).
- `ci.yml`: 3개 `bun-version: latest` → `bun-version: 1.3.14`.
- 커밋:
```
git add .github/workflows/release.yaml .github/workflows/ci.yml
```
메시지: `refactor: release.yaml thin-caller화(즉시 디스패치 합류) + bun 핀 정합(latest→1.3.14)`

#### PR-files (`~/workspace/files`)
**Files:** `.github/workflows/release.yaml`(build 잡에 secrets passthrough 2줄 — paths-ignore·workflow_dispatch·`app: files`는 files 고유라 유지).
- `jobs.build`(19-23행)에 추가:
```yaml
    secrets:
      HOMELAB_DISPATCH_APP_ID: ${{ secrets.HOMELAB_DISPATCH_APP_ID }}
      HOMELAB_DISPATCH_APP_PRIVATE_KEY: ${{ secrets.HOMELAB_DISPATCH_APP_PRIVATE_KEY }}
```
> files는 시크릿 미프로비저닝이라 흡수된 deploy-trigger는 항상 clean skip(현행 무변경·크론/bespoke bump 유지). B9(files bump-poll 인라인 핀 레인) + owner의 files 레포 dispatch 시크릿 프로비저닝 후 자동 활성. 본 PR은 계약 형태 정합만(inert).
- 커밋:
```
git add .github/workflows/release.yaml
```
메시지: `refactor: release.yaml 디스패치 시크릿 passthrough 정합(reusable 계약)`

**앱별 라이브 검증(각 PR 머지 후 1회씩)**: 앱 main에 무해 커밋 push →
```
gh run list -R ukyi-app/<app> --workflow release.yaml -L 1        # release 잡 success + GHCR push
gh run list -R ukyi-app/<app> --workflow release.yaml --json …    # deploy-trigger: (시크릿 有) success / (無) skip 확인
gh run list -R ukyi-app/homelab --workflow bump-poll.yaml -L 1    # (시크릿 有 레포만) 디스패치로 bump-poll 발화 확인
```
기대: page(시크릿 有)=deploy-trigger success→homelab bump-poll 새 run. trip/files(시크릿 無)=deploy-trigger skip, 크론 백스톱 유지. GHCR 이미지 `sha-<commit>` 태그 생성.

---

### 게이트·라이브 검증 (배치 말미)

**게이트(homelab, PR-11a~c 각각)**
```
make ci                    # gate 재현: m6-tools + chart-test + run-bats.sh(신규 bats 자동 수집)
bats tools/tests/test_reusable-app-build.bats tools/tests/test_contract-drift.bats tools/tests/test_app-deploy.bats
bun run typecheck          # contract-drift-check.ts 편입
make verify                # skeleton + 원장 + sops 라운드트립
```
기대: 전 PASS. `./scripts/run-bats.sh --list`에 `test_contract-drift.bats` 포함(git-tracked·비-.ci-exclude).

**라이브(옵션 — 네트워크만, 클러스터 불요)**
```
bun tools/contract-drift-check.ts --manifest tools/vendored-contract.json | jq '{drift:.drift|length, errors:.errors|length}'
```
기대: `{"drift":0,"errors":0}`(설계 M18 실드리프트 0 확인). trip-mate 재포맷 사본도 typescript 정규화로 흡수.

**호스트 bun 정합(owner-local, 1줄)**
```
mise use -g bun@1.3.14     # 호스트 1.3.10→1.3.14(게이트/toolchain-setup.md 핀과 정렬); 확인: bun --version
```

**cross-repo 라이브**: B11.6 앱별 검증표(release success·deploy-trigger 발화/skip·bump-poll 발화) 참조. reusable 흡수는 additive(preflight-skip)라 앱별 1회 빌드 검증으로 충분(설계 §7 B11 리스크).

### 롤백 노트
- **PR-11a**: reusable에서 `deploy-trigger` 잡·`secrets:` 블록 revert + bats 원복. 앱 caller가 이미 secrets를 넘기고 있으면 "secret not defined" 발생 → **역순 롤백 필수**(앱 PR 먼저 revert, 그다음 PR-11a). 그래서 PR-11a는 앱/템플릿 PR보다 **먼저 머지·나중 롤백**.
- **PR-11b**: 순수 additive(신규 파일 4개). revert = 파일 삭제, 다른 게이트 무영향.
- **PR-11c**: 스키마 required는 실앱이 이미 충족 → revert해도 라이브 무영향(계약 완화일 뿐). renovate 스코프 revert 시 템플릿 미스캔(무해).
- **템플릿/앱 PR**: 각 레포 독립 revert. thin-caller revert 시 옛 deploy-trigger 잡 복원(reusable 흡수분과 공존 시 caller가 시크릿 미passthrough면 reusable 쪽 skip → double 발화 없음, 안전).

### 다음 배치 진행 조건
- PR-11a~c 전부 required `gate` GREEN + main 머지.
- 템플릿 PR-T template-ci GREEN + 머지, 앱 3레포 PR 머지 후 각 release+deploy-trigger 라이브 검증 완료(page 즉시 디스패치→bump-poll 발화 관측).
- `contract-drift` 워크플로 1회 수동 `workflow_dispatch` 실행 후 drift=0·errors=0 확인(리컨실러 배선 라이브 증명).
- (owner-manual, 비차단) writer App의 템플릿 레포 설치 확장 완료 시 renovate가 템플릿 bun/액션 핀 갱신 개시 — 미완이어도 homelab 무영향이라 B12 착수 차단 아님.
## B12. 게이트/문서 하드닝 (doc-index·traps·런북 백업·bump 재목적화) (Wave 3)

> ⚠️ **설계 보정** (실파일 실측 — 설계 §5 B12 스냅샷과 어긋남, 실파일 우선):
> 1. **SYNC-WAVES.md 위치**: `docs/`가 아니라 `platform/argocd/root/SYNC-WAVES.md`다.
> 2. **verify-traps는 CI 게이트가 아니다** — `make verify-traps`(owner-local)뿐, `ci.yaml`/`verify.yaml`/pre-commit 어디에도 미배선. traps 원장↔가드 드리프트 검사는 로컬 전용이므로, traps.md 행 추가의 검증은 배치 말미 owner-local `make verify-traps`로 한다. 정작 **가드의 실제 enforcement는 가드 bats가 `run-bats.sh`에 자동 수집(gate)**되는 것으로 걸린다.
> 3. **memory-ledger 산문 드리프트 실측**: `docs/memory-ledger.md:12` `limit 합(현재 8892)` · `:20` `명목 잔여(9216−8892 = 324)` vs 표 합계 `:51` `limit ≈ 9020`(files 행 128Mi 추가 #215가 표만 갱신, 산문 미갱신). 정정값 = 9020 / 196.
> 4. **check-skeleton `dirs` 배열 자체가 stale**: platform 항목에 `ghcr-pull`·`cert-manager-netpol`·`homepage`·`files` 누락(기존 `for d in platform/*/` 정방향 루프가 이미 동적 커버 중이라 무해했음) — 양방향 전환의 근거.
> 5. **build.yaml basename은 이미 prose 등장**(`bump | build 완료`) — check-doc-index 워크플로 arm(거친 basename 존재검사)은 build을 통과시킨다. 전용 행 추가는 문서 완전성 수기 보정이며, 가드의 실효는 향후 제로-언급 워크플로 차단이다(한계 명시).
> 6. **pg-tools digest 소비처 = 5-site / 4-file**(cache `backup-cronjob.yaml`가 init+main 2회). 설계 "5-manifest"는 5-site를 뜻함.
> 7. **`bump-tag.ts`는 values.yaml 전용**(YAML `image.tag`/`image.digest` setIn) — pg-tools 인라인 핀 재핀에는 부적합, 별도 도구 필요.
> 8. **check-doc-index 자기참조**: PR-12a부터 게이트가 걸리므로 이후 배치가 추가하는 신규 `scripts/*.sh`·`tools/*.ts`는 **같은 PR에서 README 등재 필수**(B12.7 `backup-local-asset.sh`·B12.8 `repin-pgtools.ts` 포함).

**목표** 가드 없는 문서 인덱스 드리프트 클래스(scripts/tools/workflows README)를 소멸시키고, 6/22 이후 라이브 함정 3계열·SYNC-WAVES·원장 산문을 SSOT에 정합화하며, `LOCAL_PATH_PROVISIONER_VERSION` silent no-op·런북 단일 사본·pg-tools digest skew·서드파티 digest 미핀을 가드/자동화로 막는다.

**선행 조건** Wave 1·2 머지 완료(특히 B4 dr-drill PG 이미지 파생·B9 예약 host SSOT — 본 배치의 traps 섹션이 상호참조하나 파일 존재 의존은 없음). 본 배치는 라이브 클러스터 무변경(문서·게이트·owner-local 스크립트만; bump.yaml은 build→PR 경로라 라이브 직접 변경 아님).

**PR 구성** (직렬 머지 — 스택 squash 함정 회피):
- **PR-12a** `feat: 디렉토리 인덱스 가드 + 등재 누락분` — check-doc-index 신설·11+3+build 등재·check-skeleton 양방향.
- **PR-12b** `docs: 함정·원장 현행화` — traps-detail 3계열 + pg-tools 일관성 가드 + AGENTS 인덱스 + SYNC-WAVES + ledger 산문 + .rgignore + CONTRIBUTING.
- **PR-12c** `chore: 게이트·자동화 하드닝` — LOCAL_PATH 일치 가드 + verify-cluster k3s 단언 + backup-local-asset 체인 + verify-runbook-index 양방향 + bump.yaml pg-tools 재핀 + renovate digest 절차(owner 수동).

---

### B12.1 check-doc-index 신설 (PR-12a)

**Files:** Create: `scripts/check-doc-index.sh`, `tests/gates/test_check-doc-index.bats` · Modify: `Makefile:28-35`(verify 타겟), `scripts/README.md`(자기 등재) · Test: `tests/gates/test_check-doc-index.bats`(gate 자동수집)

**Step 1 — 실패 테스트 작성.** `tests/gates/test_check-doc-index.bats`:
```bash
#!/usr/bin/env bats
# check-doc-index 게이트: scripts/·tools/·workflows README 등재 드리프트 차단.
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "check-doc-index passes on the current tree (all artifacts registered)" {
  run ./scripts/check-doc-index.sh
  [ "$status" -eq 0 ]
}

@test "check-doc-index FAILS when a script is missing from scripts/README.md" {
  tmp="scripts/zz_docindex_probe.sh"; : > "$tmp"; chmod +x "$tmp"
  run ./scripts/check-doc-index.sh
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "zz_docindex_probe.sh"
}

@test "check-doc-index runs in the required gate via make verify" {
  run awk '/^verify:/{v=1} v && /check-doc-index/{print}' Makefile
  [ -n "$output" ]
}
```

**Step 2 — 실행(기대 실패).** `bats tests/gates/test_check-doc-index.bats` → 3건 모두 실패(스크립트·Makefile 배선 부재: `check-doc-index.sh: command not found`).

**Step 3 — 최소 구현.** `scripts/check-doc-index.sh`:
```bash
#!/usr/bin/env bash
# 디렉토리 인덱스 드리프트 가드 — scripts/·tools/·.github/workflows/ 의 각 산출물이 해당
# README에 문자열로 등재됐는지 검사(가드 없는 인덱스 드리프트 소멸). check-skeleton.sh(디렉토리
# 지도)·verify-runbook-index.sh(런북 인덱스)와 동일 불변식. 순수 파일/문자열 검사(CI-safe).
# bash 3.2 안전(glob 루프, 배열 미사용).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BT='`'   # 백틱 리터럴(명령치환 회피)
rc=0

# scripts/*.sh ↔ scripts/README.md (백틱 감싼 파일명 — README 규약)
for f in scripts/*.sh; do
  b="$(basename "$f")"
  grep -Fq "${BT}${b}${BT}" scripts/README.md || { echo "FAIL: scripts/README.md 미등재: $b"; rc=1; }
done

# tools/*.ts·*.mts ↔ tools/README.md (스키마 .json은 표로 별도 문서화 → 제외)
for f in tools/*.ts tools/*.mts; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  grep -Fq "${BT}${b}${BT}" tools/README.md || { echo "FAIL: tools/README.md 미등재: $b"; rc=1; }
done

# .github/workflows/*.yaml ↔ workflows README (친화명 표기라 basename 존재검사)
# ⚠️ 거친 검사: prose 언급도 통과(build은 'build 완료'에 이미 등장). 제로-언급 신규 워크플로 차단이 목적.
for f in .github/workflows/*.yaml; do
  b="$(basename "$f" .yaml)"
  grep -Fq "$b" .github/workflows/README.md || { echo "FAIL: workflows README 미등재: ${b}.yaml"; rc=1; }
done

[ "$rc" -eq 0 ] && echo "check-doc-index: scripts·tools·workflows 인덱스 정합 OK"
exit "$rc"
```
`chmod +x scripts/check-doc-index.sh`. `Makefile:28-35` verify 블록에 한 줄 추가(`check-skeleton` 다음, `check-bats-accounting` 앞):
```
	@./scripts/check-skeleton.sh
	@bash scripts/check-doc-index.sh
	@bash scripts/check-bats-accounting.sh
```
`scripts/README.md` "## CI 게이트" 섹션에 자기 등재(B12.2에서 나머지 10건과 함께 — 순서상 이 커밋에 최소 `check-doc-index.sh` 1건만이라도 포함해야 자기검사 통과).

**Step 4 — 게이트.** `bats tests/gates/test_check-doc-index.bats`(3/3 pass) → `shellcheck scripts/check-doc-index.sh`(clean) → `bash scripts/check-doc-index.sh`(OK; 단 B12.2 미완이면 11+3+... FAIL — 따라서 B12.1·B12.2를 같은 PR 연속 커밋으로).

**Step 5 — 커밋.** `git add scripts/check-doc-index.sh tests/gates/test_check-doc-index.bats Makefile scripts/README.md` → `feat: check-doc-index 게이트 신설 — scripts·tools·workflows README 등재 드리프트 차단`

---

### B12.2 인덱스 누락분 등재 (scripts 11 · tools 3 · build.yaml) (PR-12a)

**Files:** Modify: `scripts/README.md`, `tools/README.md`, `.github/workflows/README.md` · Test: 없음(가드는 B12.1이 제공 — `bash scripts/check-doc-index.sh` 통과가 검증)

**실측 전수 목록**(각 산출물 → 등재 섹션 → 호출경로 → 파괴성):

| 산출물 | README | 섹션/카테고리 | 호출경로 | 파괴성 |
|---|---|---|---|---|
| `check-app-netpol.sh` | scripts | CI 게이트 | `make verify` | 읽기전용 |
| `check-resource-limits.sh` | scripts | CI 게이트 | `make verify`·gate | 읽기전용 |
| `verify-ledger.sh` | scripts | CI 게이트 | `make verify`(ledger-to-json→conftest) | 읽기전용 |
| `verify-runbook-index.sh` | scripts | CI 게이트(local) | `make verify-runbook-index`(런북 gitignored→CI skip) | 읽기전용 |
| `audit-orphan-pv.sh` | scripts | CI 게이트(진단) | `test_audit-orphan-pv.bats`·make 타겟(B13) | 읽기전용 |
| `auto-merge-or-fail.sh` | scripts | 워크플로 헬퍼 | `bump.yaml`·변이 auto-merge | 비파괴(머지) |
| `seal-argocd-notify.sh` | scripts | 시크릿/부트스트랩 | `make seal-argocd-notify` | 봉인본 산출 |
| `seal-files-secrets.sh` | scripts | 시크릿/부트스트랩 | `make seal-files-secrets` | 봉인본 산출 |
| `seal-ghcr-pull.sh` | scripts | 시크릿/부트스트랩 | `make seal-ghcr-pull` | 봉인본 산출 |
| `netpol-rehearsal.sh` | scripts | DR/owner | 직접 실행(B13 처분 대상) | 라이브 리허설 |
| **`teardown.sh`** | scripts | **DR/owner 파괴적** | `make teardown-app`/`teardown-resource` | **파괴적(앱·리소스 철거)** |
| `check-doc-index.sh` | scripts | CI 게이트 | `make verify`·gate(bats) | 읽기전용 |
| `activate-app.ts` | tools | 정적 감사/재활성 | owner-local(런북 app-platform) | 게이트만 |
| `dns-drift-check.ts` | tools | 정적 감사 | `dns-drift.yaml`(6h) | 읽기전용 |
| `verify-db-marker.ts` | tools | 검증 | `_create-database.yaml` PostSync 검증 | 읽기전용 |
| `build.yaml` | workflows | 🤖 자동 | push(`ops/**`)·workflow_dispatch | 이미지 빌드 |

**Step 1 — 등재 초안.** `scripts/README.md` "## CI 게이트" 말미에(예):
```markdown
- **`check-doc-index.sh`** — scripts/·tools/·workflows 산출물이 해당 README에 등재됐는지 검사(인덱스 드리프트 차단). **`make verify`**·gate(`tests/gates/test_check-doc-index.bats`)가 호출. 순수 문자열 검사.
- **`check-app-netpol.sh`** — `apps/<name>/deploy/prod`의 NetworkPolicy 계약 가드. **`make verify`**가 호출. 인레포 앱 0개면 vacuous pass.
- **`check-resource-limits.sh`** — 상주 워크로드 main 컨테이너의 cpu·memory request + memory limit 강제(+GOMEMLIMIT≤limit×0.95, B2). **`make verify`**·gate가 호출. `policy/memory-limit-allowlist.txt` 예외.
- **`verify-ledger.sh`** — `bun tools/ledger-to-json.ts`(B7 이관) 출력을 `conftest … policy/ledger.rego`로 파이프(메모리 원장 예산 게이트). **`make verify`**가 호출.
- **`verify-runbook-index.sh`** — `docs/runbooks/`(gitignored) ↔ AGENTS 런북 인덱스 정합(owner 머신 전용, 런북 부재 시 skip). **`make verify-runbook-index`**가 호출.
- **`audit-orphan-pv.sh`** — Released/Available PV 나열(고아 PV 진단, 읽기전용). `tests/gates/test_audit-orphan-pv.bats`가 가드. make 타겟 노출은 B13.
```
"## 시크릿 / 부트스트랩"에 `seal-argocd-notify.sh`·`seal-files-secrets.sh`·`seal-ghcr-pull.sh`(각 `make seal-*` 호출, 평문·해시 stdout 비출력·봉인본만 산출). "## DR / owner 전용 — 파괴적"에:
```markdown
- **`teardown.sh`** — **파괴적(owner 전용)**. `make teardown-app`/`teardown-resource` 래퍼가 호출 — clean-worktree·fresh-main 전용브랜치·allowlist staging·PR 강제 후 `teardown-app.ts`/`teardown-resource.ts`를 실행. 앱/리소스 매니페스트·apps.json·원장 행을 제거(리소스 purge는 상태머신·런북 전용). 잘못 쓰면 배포/데이터 유실.
- **`netpol-rehearsal.sh`** — **owner-local**. NetworkPolicy 변경 리허설(라이브 적용 검증). Makefile/워크플로 배선 없음(B13 인자화/처분 대상).
- **`auto-merge-or-fail.sh`** — 워크플로 헬퍼. `bump.yaml`·변이 경로가 PR 생성 후 auto-merge 설정, 실패 시 non-zero. `make`/직접 실행 아님.
```
`tools/README.md` "## 정적 감사" 등에 `activate-app.ts`(재활성/노출 재승인 게이트, owner-local)·`dns-drift-check.ts`(`dns-drift.yaml` active&&public DNS resolve 체크)·`verify-db-marker.ts`(`_create-database.yaml` PostSync 마커 검증). `.github/workflows/README.md` "## 🤖 자동" 표에:
```markdown
| build | push(`ops/**`)·수동 | 플랫폼 ops 이미지 빌드(pg-tools → GHCR, `:sha-<sha>`+`:18-rclone`) — 배포-전용 apps/는 외부 레포에서 빌드 |
```

**Step 2 — 검증.** `bash scripts/check-doc-index.sh` → `check-doc-index: … 정합 OK`(exit 0). `bats tests/gates/test_check-doc-index.bats`(pass).

**Step 3 — 커밋.** `git add scripts/README.md tools/README.md .github/workflows/README.md` → `docs: scripts·tools·workflows 인덱스 누락분 등재(teardown/netpol 파괴성 표기)`

---

### B12.3 check-skeleton 컴포넌트 양방향 검사 (PR-12a)

**Files:** Modify: `scripts/check-skeleton.sh`(dirs 배열 `:3-11`·platform 정방향 루프 말미) · Test: `tests/gates/test_check-skeleton-gate.bats`에 역방향 케이스 추가

**Step 1 — 실패 테스트.** `tests/gates/test_check-skeleton-gate.bats`에 추가:
```bash
@test "check-skeleton FAILS when README component table lists a nonexistent platform dir (reverse tie)" {
  run bash -c 'sed "s/| \`files\`/| \`ghostcomp\`/" README.md > /tmp/ck_readme_$$ && CK_README=/tmp/ck_readme_$$ ./scripts/check-skeleton.sh; rc=$?; rm -f /tmp/ck_readme_$$; exit $rc'
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ghostcomp"
}
```
(check-skeleton이 `README.md`를 `CK_README` env로 오버라이드 가능해야 함 — 아래 구현에서 배선.)

**Step 2 — 실행(기대 실패).** `bats tests/gates/test_check-skeleton-gate.bats` → 역방향 케이스 실패(현재 정방향만 존재; phantom 항목 미탐지).

**Step 3 — 구현.** `scripts/check-skeleton.sh`:
(a) 상단 README 경로 변수화(테스트 오버라이드): 스크립트 앞부분에 `README="${CK_README:-README.md}"` 추가, 기존 `grep -q "$c" README.md`·`grep -vE … README.md`를 `"$README"`로 교체.
(b) `dirs` 배열(`:3-11`)에서 **stale·중복 platform 컴포넌트 항목 제거**(`platform/traefik platform/adguard platform/cloudflared platform/tailscale platform/cnpg platform/victoria-stack platform/sealed-secrets platform/data-conn platform/cache platform/network-policies platform/namespaces`) — 양방향 검사가 동적 커버. `platform/argocd/root`·`platform/charts/app`(서브경로 스켈레톤)은 유지.
(c) 기존 정방향 platform 루프(`for d in platform/*/`) 뒤에 역방향 추가:
```bash
# 역방향(README 컴포넌트 표 → 디렉토리): 표에 나열된 각 컴포넌트가 platform/<c>/로 실재하는지.
# 정방향(dir→표)과 합쳐 양방향 — phantom/리네임 항목·신규 컴포넌트 자동 편입.
comps="$(sed -n '/### platform 컴포넌트/,/^## /p' "$README" | grep -oE "^\| ${BT}[a-z0-9-]+${BT}" | tr -d "${BT}|" | tr -d ' ')"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ -d "platform/$c" ] || { echo "FAIL: README 컴포넌트 표에 있으나 platform/ 디렉토리 부재: $c"; rc=1; }
done <<< "$comps"
```
(상단에 `BT='`'` 정의 추가.)

**Step 4 — 게이트.** `bats tests/gates/test_check-skeleton-gate.bats`(전건 pass) → `./scripts/check-skeleton.sh`(OK) → `shellcheck scripts/check-skeleton.sh`(clean).

**Step 5 — 커밋.** `git add scripts/check-skeleton.sh tests/gates/test_check-skeleton-gate.bats` → `refactor: check-skeleton 컴포넌트 검사를 README 표↔디렉토리 양방향으로(신규 컴포넌트 자동 편입)`

**PR-12a 머지 후**: `make ci` 재현 통과 확인(check-doc-index·check-skeleton 게이트 편입).

---

### B12.4 traps-detail 3계열 + AGENTS 인덱스 + pg-tools 일관성 가드 (PR-12b)

**Files:** Modify: `docs/traps-detail.md:213`(append), `AGENTS.md:98`(인덱스 append), `docs/traps.md:40`(원장 행) · Create: `tests/gates/test_pgtools-digest.bats` · Test: `tests/gates/test_pgtools-digest.bats`(gate)

**Step 1 — 실패 테스트.** `tests/gates/test_pgtools-digest.bats`:
```bash
#!/usr/bin/env bats
# PG 메이저 3-이미지 함정 가드: pg-tools:18-rclone 소비처 5-site가 단일 digest로 일관되게 핀됐는지.
# 부분 갱신(skew)이 PgDumpHedgeStale를 재발시킨다. 순수 grep(CI-safe). ⚠️ [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }
FILES="platform/cache/prod/backup-cronjob.yaml platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml"

@test "all pg-tools:18-rclone consumers pin one identical digest (major-skew guard)" {
  digests="$(grep -hoE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' $FILES | sort -u)"
  n="$(printf '%s\n' "$digests" | grep -c .)"
  [ "$n" -eq 1 ]
}

@test "each expected consumer site is present (5-site registry drift guard)" {
  run grep -cE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' platform/cache/prod/backup-cronjob.yaml
  [ "$output" -eq 2 ]
  for f in platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml; do
    run grep -cE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' "$f"; [ "$output" -eq 1 ]
  done
}
```

**Step 2 — 실행(기대: pass now).** `bats tests/gates/test_pgtools-digest.bats` → **현재 트리 pass**(전 5-site가 `@sha256:9c4cb35…` 동일). 이 가드는 향후 skew를 차단하는 회귀 게이트다. (TDD 역행 아님 — 가드-우선 원칙; drift 주입으로 실패 재현: 한 파일 digest 1자 변경 후 재실행 → `n==2` FAIL 확인 후 원복.)

**Step 3 — 문서/원장.** `docs/traps-detail.md:213` 뒤 append(3섹션):
```markdown
### ArgoCD Notifications telegram native 함정
- ArgoCD Notifications v3.4.x telegram은 함정이 겹친다(#213→#217→#224 라이브 확정): **webhook 방식은 봇
  토큰을 retryablehttp DEBUG 로그로 URL에 실어 VictoriaLogs로 유출**한다 → native(tgbotapi, 미로깅)로 회피.
  native recipient는 **음수 그룹 chatId만** 유효(양수 DM은 @channel로 오해석→전송 실패), **parseMode가
  Markdown 하드코딩**(HTML 무시 → `*bold*` 리터럴), recipient에 `$secret` 확장 없음(chatId 리터럴). oncePer는
  관측 HEAD(`sync.revision`)가 아니라 **실제 sync 작업 revision(`operationState.syncResult.revision(s)`)**에 걸어야
  한다 — 모노레포는 main 머지마다 구독 앱 전부가 같은 HEAD를 관측해 거짓 "배포 완료" 버스트(#224). supergroup
  승격 시 chatId가 바뀐다(전송 조용히 실패).

### PG 메이저 업그레이드 3-이미지 동시 갱신
- PG 메이저 업그레이드는 **서버(CNPG Cluster) + basebackup(barman) + pg-tools(ops 이미지)를 한꺼번에** 올려야
  한다 — `pg_dump`는 서버보다 낮은 major를 거부한다(ops/pg-tools Dockerfile). 라이브 2회 발현: PgDumpHedgeStale
  (pg_dump16 vs 서버18, #178/#180)·dr-drill 이미지 16.4 잔류(#206). pg-tools digest는 5개 소비처(cache
  backup-cronjob ×2·cnpg ensure-role-password/restore-drill/pgdump-hedge)에 인라인 핀돼 부분 갱신이 skew를
  만든다 — 전 소비처 단일 digest 일관성을 게이트로 강제하고 bump.yaml이 빌드 시 자동 재핀한다.
> 가드: `tests/gates/test_pgtools-digest.bats`, `tests/test_dr-drill.bats`

### 베스포크 공개 노출은 platform_hosts(apps.json 아님)
- 골든패스 앱의 공개 DNS는 `infra/cloudflare/apps.json`(active&&public)이 SSOT지만, **베스포크 플랫폼
  컴포넌트(files·argocd-webhook 등)의 공개 노출은 `infra/cloudflare/dns.tf`의 `platform_hosts` locals**가 권위다
  — apps.json에 넣으면 audit-orphans가 apps/ 매니페스트 부재로 차단한다(files 온보딩서 실증). 예약 host 검사·
  dns-drift·create-app 예약어가 apps.json만 인지해 platform_hosts를 모르는 갭이 있다(예약 host SSOT 통합=B9).
```
`AGENTS.md:98`(마지막 인덱스 `상주 워크로드 자원 limit 블라인드스팟`) 뒤 3줄:
```markdown
- ArgoCD Notifications telegram native 함정
- PG 메이저 업그레이드 3-이미지 동시 갱신
- 베스포크 공개 노출은 platform_hosts
```
`docs/traps.md:40`(원장 마지막 행) 뒤 1행(guard-path-tie: `> 가드:` 경로 ⊆ 원장):
```markdown
| PG 메이저 업그레이드 3-이미지 동시 갱신(pg-tools digest 일관성) | gate | `tests/gates/test_pgtools-digest.bats`, `tests/test_dr-drill.bats` |
```
(telegram native·베스포크는 **doc-only** — `> 가드:` 없음, 원장 행 없음. traps.md 규약 "여기 없는 함정 = doc-only" 준수.)

**Step 4 — 게이트.** `bats tests/gates/test_pgtools-digest.bats`(pass) → `make verify-traps`(owner-local: `verify-traps: 원장 guard 실재 + SSOT 가드주석↔원장 일치 OK` — PG `> 가드:` 두 경로가 원장에 존재+파일 실재) → `grep -c '^- ' AGENTS.md`(인덱스 3줄 증가 확인) → `make ci`.

**Step 5 — 커밋.** `git add docs/traps-detail.md AGENTS.md docs/traps.md tests/gates/test_pgtools-digest.bats` → `docs: traps 3계열(telegram native·PG 3-이미지·베스포크 platform_hosts) + pg-tools digest 일관성 가드`

---

### B12.5 SYNC-WAVES 현행화 + memory-ledger 산문 정합 (PR-12b)

**Files:** Modify: `platform/argocd/root/SYNC-WAVES.md`(전역 순서 표), `docs/memory-ledger.md:12,20` · Test: 없음(문서 — grep 검증)

**Step 1 — SYNC-WAVES 편집(앵커 기반).** `platform/argocd/root/SYNC-WAVES.md` 전역 순서 표:
- `-8 traefik` 행 뒤에 **-7 행 추가**: `|  -7  | traefik whoami 스모크 (gateway ns — Gateway attach 배포 검증; `whoami-smoke.yaml`) | M3 |`.
- `0 edge` 행의 컴포넌트 나열을 현행 appset 기본-0 전수로 갱신: 기존 `edge: cloudflared, tailscale-operator, adguard`를 `edge + 앱-지원: cloudflared, tailscale-operator, adguard, cache, data-conn, ghcr-pull, network-policies, cert-manager-netpol, homepage, files (sync-wave 미지정 → platform-components ApplicationSet이 기본 wave 0로 발견; appset 제외 = argocd/cnpg/victoria-stack/charts/sealed-secrets/namespaces)`로 교체.
- 상단 산문 "그 다음 stateful 계층…" 문단은 -7 whoami를 반영해 1구 보정(선택).

**Step 2 — memory-ledger 산문 정정.** `docs/memory-ledger.md`:
- `:12` `limit 합(현재 8892)` → `limit 합(현재 9020)`.
- `:20` `명목 잔여(9216−8892 = 324)` → `명목 잔여(9216−9020 = 196)`(`−`=U+2212 유지).
- (선택) `## 갱신 방법` 아래 산문-표 정합 관례 1줄: "산문의 구체 수치(limit 합·명목 잔여)는 표 합계(`:51`)·cap과 동반 갱신 — files 행 #215가 산문 누락시킨 드리프트 재발 방지." (근본 가드=B7 `ledger-totals.ts` 산문==표합 검사, 본 배치 범위 밖.)

**Step 3 — 검증.** `grep -n '현재 9020\|9216−9020 = 196' docs/memory-ledger.md`(2건) · `grep -c '8892\|= 324' docs/memory-ledger.md`(0 — 잔존 stale 없음, 단 `:12`의 `6586`·`10724` 등 라이브 실측치는 불변) · `grep -n '\-7' platform/argocd/root/SYNC-WAVES.md`(-7 행 존재) · `make verify`(skeleton 등 무영향 통과).

**Step 4 — 커밋.** `git add platform/argocd/root/SYNC-WAVES.md docs/memory-ledger.md` → `docs: SYNC-WAVES 현행화(-7 whoami·appset 기본0 컴포넌트) + memory-ledger 산문 수치 정합(9020/196)`

---

### B12.6 docs/plans 검색 제외 + 계획문서 크기 관례 (PR-12b)

**Files:** Create: `.rgignore` · Modify: `CONTRIBUTING.md`(말미) · Test: 없음

**Step 1 — `.rgignore`(레포 루트, 신규):**
```
# ripgrep 기본 제외 — 에이전트/도구 검색 노이즈 축소(git 추적엔 영향 없음, 검색 가시성만).
# docs/plans/는 역사 기록(수정 금지 — AGENTS 컨벤션·설계 §6): 히스토리 재작성 대신 검색 제외로 갈음.
docs/plans/
```
(renovate.json은 이미 `docs/plans/**` ignorePaths — 정합.)

**Step 2 — CONTRIBUTING 관례 1줄.** `CONTRIBUTING.md` 말미 신규 소절:
```markdown
## 문서 관례
- **계획 문서 크기**: `docs/plans/`는 검색 노이즈를 줄이기 위해 간결히(권장 상한 ~1500줄/문서). 대형
  산출물은 요약 SSOT + 링크로 분리한다. 히스토리 재작성은 하지 않고 `.rgignore`가 검색에서 제외한다.
```

**Step 3 — 검증.** `command -v rg >/dev/null && rg --files docs/plans/ | head`(빈 출력 — 제외 확인; rg 부재 시 skip) · `grep -q '문서 관례' CONTRIBUTING.md`.

**Step 4 — 커밋.** `git add .rgignore CONTRIBUTING.md` → `chore: .rgignore로 docs/plans 검색 제외 + CONTRIBUTING 계획문서 크기 관례`

**PR-12b 머지 후**: `make ci` + `make verify-traps` 통과 확인.

---

### B12.7 LOCAL_PATH_PROVISIONER 일치 가드 + verify-cluster k3s 단언 (PR-12c)

> **결정(설계 §M12 "택1")**: **일치 bats(옵션 b)** 채택 — manifest 하드코딩 태그 유지 + `versions.env` 일치 게이트. 근거: `apply-storage.sh render()`가 envsubst를 2변수로 의도적 제한("다른 것이 덮어써지지 않게", `:60-63`)하는 계약을 건드리지 않고, Renovate가 `versions.env`만 bump해도 **게이트가 red**여서 owner가 manifest 동반 갱신하게 강제(silent no-op → loud). 플레이스홀더화(옵션 a)는 라이브 render 경로 변경이라 본 저위험 배치에서 회피.

**Files:** Modify: `infra/k3s-bootstrap/tests/test_06-storage-manifests.bats`, `infra/k3s-bootstrap/verify-cluster.sh`(step 추가), `infra/k3s-bootstrap/tests/test_09-verify-cluster.bats`(stub+케이스) · Test: 위 두 bats(둘 다 gate 자동수집 — hermetic stub)

**Step 1 — 실패 테스트(LOCAL_PATH).** `test_06-storage-manifests.bats`에 추가:
```bash
@test "local-path-provisioner image tag matches versions.env (Renovate bump non-silent)" {
  # M12: LOCAL_PATH_PROVISIONER_VERSION 소비자 0 → versions.env bump가 silent no-op였다.
  # 하드코딩 태그가 versions.env와 일치하는지 게이트해 드리프트를 loud하게. (setup()이 versions.env source)
  run grep -cE "rancher/local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}([[:space:]]|\$)" "$PROV"
  [ "$output" -ge 2 ]   # provisioner Deployment 2 아키타입(:60,:134) 모두 핀
}
```

**Step 2 — 실패 테스트(k3s 버전).** `test_09-verify-cluster.bats` setup()에 픽스처+stub 케이스 추가, 신규 @test:
```bash
# setup() 내 — versions.env source해 핀 버전을 픽스처로
source "$BOOTSTRAP_DIR/versions.env"; echo "$K3S_VERSION" > "$STUBDIR/kubeletversion.txt"
# kubectl stub case에 추가(‘get nodes’보다 먼저 — jsonpath가 더 구체):
#   *"nodeInfo.kubeletVersion"*) cat "$STUBDIR/kubeletversion.txt" ;;

@test "fails when live k3s version drifts from versions.env K3S_VERSION" {
  echo "v1.99.9+k3s1" > "$STUBDIR/kubeletversion.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version"* ]]
}
```

**Step 3 — 실행(기대 실패).** `bats infra/k3s-bootstrap/tests/test_06-storage-manifests.bats infra/k3s-bootstrap/tests/test_09-verify-cluster.bats` → LOCAL_PATH 케이스 pass(현재 일치)이나 k3s drift 케이스 **실패**(verify-cluster에 [6] 단언 부재라 healthy stub만 반환 → drift 미탐지). (LOCAL_PATH는 가드-우선 회귀 게이트 — drift 주입으로 실패 재현 가능.)

**Step 4 — 구현(verify-cluster).** `infra/k3s-bootstrap/verify-cluster.sh` `[5] secrets-encryption` 블록 뒤, 최종 `OK:` echo 앞에 step [6]:
```bash
echo "==> [6] k3s version pinned to versions.env (K3S_VERSION)?"
kver="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"
[ "$kver" = "$K3S_VERSION" ] || fail "k3s version drift: live '${kver:-<none>}' != pinned '$K3S_VERSION' (versions.env)"
```
최종 `OK:` 메시지에 `k3s ver pinned` 추가(선택).

**Step 5 — 게이트.** `bats infra/k3s-bootstrap/tests/test_06-storage-manifests.bats infra/k3s-bootstrap/tests/test_09-verify-cluster.bats`(전건 pass) → `shellcheck infra/k3s-bootstrap/verify-cluster.sh`(clean) → `./scripts/run-bats.sh --list | grep -c 'test_0[69]'`(gate 수집 확인).

**Step 6 — 커밋.** `git add infra/k3s-bootstrap/tests/test_06-storage-manifests.bats infra/k3s-bootstrap/tests/test_09-verify-cluster.bats infra/k3s-bootstrap/verify-cluster.sh` → `feat: local-path 태그↔versions.env 일치 가드 + verify-cluster 라이브 k3s 버전 핀 단언(silent no-op·drift 차단)`

---

### B12.8 backup-local-asset 체인 + verify-runbook-index 양방향 (PR-12c)

**Files:** Create: `scripts/backup-local-asset.sh`, `tests/test_backup-local-asset.bats` · Modify: `scripts/verify-runbook-index.sh`, `Makefile`(seal-* 인근 타겟 추가), `scripts/README.md`(등재 — check-doc-index 자기참조), `docs/traps.md`(원장 행), `docs/traps-detail.md`(섹션) · Test: `tests/test_backup-local-asset.bats`(gate — stub hermetic)

**Step 1 — 실패 테스트.** `tests/test_backup-local-asset.bats`(sops/tar stub, 실 age 무관 → gate):
```bash
#!/usr/bin/env bats
# backup-local-asset 로직 가드(hermetic — sops stub). 실 age 왕복은 owner-local DR 드릴. ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBDIR="$(mktemp -d)"; PATH="$STUBDIR:$PATH"; export PATH STUBDIR
  cat >"$STUBDIR/sops" <<'EOF'
#!/usr/bin/env bash
# encrypt: stdin→stdout 그대로; decrypt(-d): 그대로 되돌림(왕복 항등 stub)
cat
EOF
  chmod +x "$STUBDIR/sops"
  OUT="$(mktemp -d)"   # git 밖
}
teardown() { rm -rf "$STUBDIR" "$OUT"; }

@test "usage error when outdir missing" {
  run scripts/backup-local-asset.sh
  [ "$status" -ne 0 ]
}

@test "refuses an outdir inside the git work tree" {
  run scripts/backup-local-asset.sh "$ROOT/scratch_backup_$$"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "git 작업트리"
}

@test "errors when runbooks are absent (owner-only)" {
  # fresh-checkout엔 docs/runbooks 부재 — CI/러너에서 loud하게(fail-closed)
  [ -d "$ROOT/docs/runbooks" ] && skip "런북 실재(owner 머신) — 부재 케이스 검증 불가"
  run scripts/backup-local-asset.sh "$OUT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "런북 부재"
}
```

**Step 2 — 실행(기대 실패).** `bats tests/test_backup-local-asset.bats` → `backup-local-asset.sh: No such file`.

**Step 3 — 구현.** `scripts/backup-local-asset.sh`(`backup-sealed-secrets-key.sh` 미러):
```bash
#!/usr/bin/env bash
# 로컬 전용 자산(런북) 백업 (DR 불변식) — sealing key 백업과 대칭.
# docs/runbooks/(gitignored)는 단일 Mac 디스크 단일 사본이라 매체 유실에 무방비다. tarball을 age(sops
# binary)로 암호화해 git 밖 매체에 버전드 보관하고 --verify로 신선도를 게이트한다.
#   scripts/backup-local-asset.sh <outdir>          # 백업 생성(outdir는 git 밖 — 외장 SSD 등)
#   scripts/backup-local-asset.sh --verify <outdir> # 최신 백업이 현재 런북 셋을 담는지(신선도 게이트)
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/docs/runbooks"

verify=0
if [ "${1:-}" = "--verify" ]; then verify=1; shift; fi
outdir="${1:?usage: backup-local-asset.sh [--verify] <outdir(git 밖)>}"
mkdir -p "$outdir"; outdir="$(cd "$outdir" && pwd)"

if (cd "$outdir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
  echo "ERROR: outdir($outdir)가 git 작업트리 안이다 — 레포 밖에 보관하라" >&2; exit 1
fi
{ [ -d "$SRC" ] && ls "$SRC"/*.md >/dev/null 2>&1; } || { echo "ERROR: 런북 부재($SRC) — owner 머신에서만 실행" >&2; exit 1; }
cd "$ROOT"

# 파일명은 runbooks.<epoch>.enc.tar로 통제 — ls 정렬 안전
# shellcheck disable=SC2012
latest_backup() { ls -1 "$outdir"/runbooks.*.enc.tar 2>/dev/null | sort | tail -1; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
# 내용 인지 매니페스트(codex pass3 P3-3): '<sha256> <파일명>'. 파일명 셋 비교만으로는
# 내용만 바뀐 stale 백업이 OK 통과한다 — 신선도 게이트가 무력해지는 구멍.
src_hash_manifest() { (cd "$SRC" && for f in *.md; do printf '%s %s\n' "$(sha256 "$f" | awk '{print $1}')" "$f"; done | sort -k2); }

if [ "$verify" -eq 1 ]; then
  latest="$(latest_backup)"; [ -n "$latest" ] || { echo "ERROR: 백업 없음 — 먼저 생성하라" >&2; exit 1; }
  tmpv="$(mktemp -d)"; trap 'rm -rf "$tmpv"' EXIT
  sops -d --input-type binary --output-type binary "$latest" | tar -xf - -C "$tmpv"
  [ -f "$tmpv/runbooks.sha256" ] || { echo "ERROR: 백업에 매니페스트(runbooks.sha256) 부재 — 구형/불완전 백업. 재생성하라." >&2; exit 1; }
  if [ "$(src_hash_manifest)" != "$(sort -k2 "$tmpv/runbooks.sha256")" ]; then
    echo "ERROR: 런북 드리프트(파일명+내용 sha256) — 최신 백업($latest)이 현재 런북과 불일치. 재생성하라." >&2; exit 1
  fi
  echo "OK: 최신 백업($latest)이 현재 런북과 일치(파일명+내용 sha256 대조)"; exit 0
fi

# ⚠️ 기존 백업 truncate 금지: 임시파일에 쓰고 복호 검증 후에만 버전드 rename.
tmp="$(mktemp "$outdir/runbooks.tmp.XXXXXX")"; stage="$(mktemp -d)"; trap 'rm -f "$tmp"; rm -rf "$stage"' EXIT
# 매니페스트 동봉(P3-3): 스테이징에 runbooks.sha256('<sha> <파일명>')을 넣어 --verify가 내용 대조 가능하게.
cp -a "$ROOT/docs/runbooks" "$stage/runbooks"
src_hash_manifest > "$stage/runbooks.sha256"
# --filename-override runbooks.enc.yaml: .sops.yaml catch-all(*.enc.yaml, age 2-recipient) 규칙으로 recipient
# 선택(backup-sealed-secrets-key.sh와 동일 패턴). binary라 encrypted_regex 무시, 전체를 불투명 blob 암호화.
tar -cf - -C "$stage" runbooks runbooks.sha256 \
  | sops --encrypt --filename-override runbooks.enc.yaml --input-type binary --output-type binary /dev/stdin > "$tmp"
# 복구 검증(평문 메모리만): 실제 복호되고 tar가 온전한지
sops -d --input-type binary --output-type binary "$tmp" | tar -tf - >/dev/null
dest="$outdir/runbooks.$(date +%s).enc.tar"
mv -f "$tmp" "$dest"; trap - EXIT
echo "OK: $dest (기존 백업 보존 — 버전드, git 밖 보관)"
```
`chmod +x`. `scripts/verify-runbook-index.sh` 정방향 루프 뒤(최종 echo 앞)에 역방향 fail-closed 추가:
```bash
# 역방향(AGENTS 인덱스 → 런북 파일): 인덱스 표에 나열된 각 *.md가 docs/runbooks/에 실재하는지.
# owner 머신(런북 실재)에서만 도달 — 위 skip 가드가 CI/fresh-checkout 배제. fail-closed(양방향).
idx_md="$(sed -n '/## 런북/,$p' "$ROOT/AGENTS.md" | grep -oE '`[A-Za-z0-9./-]+\.md`' | tr -d '`' | sed 's#.*/##' | sort -u)"
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ -f "$RB/$m" ] || { echo "FAIL: AGENTS 인덱스에 있으나 런북 파일 부재: $m"; fail=1; }
done <<< "$idx_md"
```
`Makefile`에 owner-local 타겟(seal-* 인근):
```
.PHONY: backup-local-asset
backup-local-asset: ## [DR] 런북 tarball을 age 백업(OUT=<git 밖 경로>). --verify는 ARGS=--verify
	@test -n "$(OUT)" || { echo "OUT=<git 밖 outdir> 필요"; exit 1; }
	@bash scripts/backup-local-asset.sh $(ARGS) "$(OUT)"
```
`scripts/README.md`에 `backup-local-asset.sh` 등재(DR/owner — 비파괴, git 밖 백업; check-doc-index 자기참조 충족). `docs/traps.md` 원장 행 + `docs/traps-detail.md:213` 뒤 섹션:
```markdown
### 로컬 자산 백업 체인
- 런북 13종은 gitignored 로컬 전용 — 단일 Mac 디스크 단일 사본은 매체 유실에 무방비다(age-keys.md가 recovery
  키 보관처 포인터인데 그 문서 자체가 로컬 전용인 순환 의존). sealing key 백업(`backup-sealed-secrets-key.sh
  --verify`)과 대칭으로 런북 tarball을 age 암호화해 git 밖 매체에 버전드 보관하고(`backup-local-asset.sh`),
  `--verify`로 신선도를 게이트한다. verify-runbook-index는 owner 머신(런북 실재)에서 **양방향 fail-closed**
  (런북↔AGENTS 인덱스)로 드리프트를 차단한다.
> 가드: `scripts/backup-local-asset.sh`, `scripts/verify-runbook-index.sh`, `tests/test_backup-local-asset.bats`
```
원장(`docs/traps.md`):
```markdown
| 로컬 자산 백업 체인(런북 tarball age 백업·인덱스 양방향) | gate | `scripts/backup-local-asset.sh`, `scripts/verify-runbook-index.sh`, `tests/test_backup-local-asset.bats` |
```

**Step 4 — 게이트.** `bats tests/test_backup-local-asset.bats`(pass; runbooks 부재 케이스는 owner 머신에선 skip) → `shellcheck scripts/backup-local-asset.sh scripts/verify-runbook-index.sh`(clean) → `bash scripts/check-doc-index.sh`(OK — backup-local-asset 등재됨) → `make verify-traps`(원장 3경로 실재 + tie OK) → owner 머신: `make verify-runbook-index`(양방향 OK) + `make backup-local-asset OUT=/Volumes/homelab/backups`(생성) → `make backup-local-asset ARGS=--verify OUT=/Volumes/homelab/backups`(신선도 OK).

**Step 5 — 커밋.** `git add scripts/backup-local-asset.sh tests/test_backup-local-asset.bats scripts/verify-runbook-index.sh Makefile scripts/README.md docs/traps.md docs/traps-detail.md` → `feat: backup-local-asset 신설(런북 tarball age 백업) + verify-runbook-index 양방향 fail-closed + traps 원장 행`

---

### B12.9 bump.yaml pg-tools digest 자동 재핀 (PR-12c)

> **설계 §M20/B12 "A안 채택"**: build가 pg-tools를 재빌드하면 bump.yaml이 새 digest를 해석해 5-site를 자동 재핀(기존 apps/ 스킵 로직 대체). B12.4의 일관성 가드가 회귀 안전망.

**Files:** Create: `tools/repin-pgtools.ts`, `tests/gates/test_repin-pgtools.bats`(fixture) · Modify: `.github/workflows/bump.yaml`(loop `:90-100`·git add `:110`), `tools/README.md`(등재 — 자기참조) · Test: `tests/gates/test_repin-pgtools.bats`(gate)

**Step 1 — 실패 테스트.** `tests/gates/test_repin-pgtools.bats`:
```bash
#!/usr/bin/env bats
# repin-pgtools 도구 가드(fixture — 라이브 무관). ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  FX="$(mktemp -d)"; mkdir -p "$FX/platform/cache/prod" "$FX/platform/cnpg/prod"
  OLD="sha256:$(printf 'a%.0s' {1..64})"; NEW="sha256:$(printf 'b%.0s' {1..64})"
  for f in platform/cache/prod/backup-cronjob.yaml platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml; do
    printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" > "$FX/$f"
  done
  printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\ninit: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" "$OLD" > "$FX/platform/cache/prod/backup-cronjob.yaml"
}
teardown() { rm -rf "$FX"; }

@test "rejects malformed digest" {
  run bun tools/repin-pgtools.ts "notadigest" --root "$FX"
  [ "$status" -ne 0 ]
}
@test "repins every site to the new digest" {
  run bun tools/repin-pgtools.ts "$NEW" --root "$FX"
  [ "$status" -eq 0 ]
  run grep -rc "$OLD" "$FX"; [ "$output" -eq 0 ] || false
  run grep -rhoE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' "$FX"
  echo "$output" | grep -q "$NEW"
}
@test "idempotent no-op when already pinned" {
  bun tools/repin-pgtools.ts "$NEW" --root "$FX" >/dev/null
  run bun tools/repin-pgtools.ts "$NEW" --root "$FX"
  [ "$status" -eq 0 ]; echo "$output" | grep -q "no-op"
}
```

**Step 2 — 실행(기대 실패).** `bats tests/gates/test_repin-pgtools.bats` → `Cannot find module … repin-pgtools.ts`.

**Step 3 — 구현.** `tools/repin-pgtools.ts`(consumer 레지스트리 = 5-site 4-file 실측):
```ts
// pg-tools 인라인 digest 재핀 — 5개 소비처(4파일)의 pg-tools:18-rclone@sha256 핀을 새 digest로.
// bump.yaml이 build 완료 후 호출(기존 apps/ 스킵 로직 대체). digest는 형식 검증. 멱등(불변 시 no-op).
import { readFileSync, writeFileSync } from "node:fs";

const CONSUMERS = [
  "platform/cache/prod/backup-cronjob.yaml",            // init+main 2-site
  "platform/cnpg/prod/ensure-role-password-job.yaml",
  "platform/cnpg/prod/restore-drill-cronjob.yaml",
  "platform/cnpg/prod/pgdump-hedge-cronjob.yaml",
] as const;
const REF = /(ghcr\.io\/[a-z0-9-]+\/pg-tools:18-rclone@)sha256:[0-9a-f]{64}/g;

const argv = process.argv.slice(2);
const rootIdx = argv.indexOf("--root");
const root = rootIdx >= 0 ? argv[rootIdx + 1] : ".";
const digest = argv.find((a) => !a.startsWith("--") && a !== root);
if (!/^sha256:[0-9a-f]{64}$/.test(digest ?? "")) {
  console.error(`bad digest: ${digest ?? "<none>"}`); process.exit(2);
}
let changed = 0;
for (const rel of CONSUMERS) {
  const f = `${root}/${rel}`;
  const cur = readFileSync(f, "utf8");
  const next = cur.replace(REF, `$1${digest}`);
  if (next !== cur) { writeFileSync(f, next); changed++; console.log(`repin: ${rel}`); }
}
console.log(changed ? `repin: ${changed}/${CONSUMERS.length} 파일 갱신 (${digest})` : `repin: 이미 ${digest} (no-op)`);
```
`.github/workflows/bump.yaml` "verify digests + bump" 스텝의 for 루프(`:90` 인근) 개조 — apps values 분기 유지 + pg-tools 재핀 분기 추가:
```bash
for app in $APPS; do
  case "$app" in ''|*[!a-z0-9-]*) echo "skip suspicious app name: '$app'"; continue ;; esac
  if [ -f "apps/$app/deploy/prod/values.yaml" ]; then
    echo "verify ghcr.io/$OWNER/$app:$SHA exists BEFORE bumping"
    docker manifest inspect "ghcr.io/$OWNER/$app:$SHA" >/dev/null 2>&1 \
      || { echo "::error::ghcr.io/$OWNER/$app:$SHA missing — refusing to bump"; exit 1; }
    bun tools/bump-tag.ts "$app" "$SHA"
  elif [ "$app" = "pg-tools" ]; then
    # ops 이미지: values.yaml 없음 — 5-site 인라인 digest 핀을 새 :18-rclone digest로 재핀
    digest="$(docker buildx imagetools inspect "ghcr.io/$OWNER/pg-tools:18-rclone" --format '{{.Manifest.Digest}}')"
    case "$digest" in sha256:*) : ;; *) echo "::error::pg-tools digest 해석 실패: '$digest'"; exit 1 ;; esac
    bun tools/repin-pgtools.ts "$digest"
  else
    echo "skip $app (no deploy values.yaml, no re-pin registry)"; continue
  fi
done
```
git add 라인(`:110`)을 pg-tools 소비처까지 확장:
```bash
git add apps/*/deploy/prod/values.yaml \
        platform/cache/prod/backup-cronjob.yaml \
        platform/cnpg/prod/ensure-role-password-job.yaml \
        platform/cnpg/prod/restore-drill-cronjob.yaml \
        platform/cnpg/prod/pgdump-hedge-cronjob.yaml
```
커밋 메시지 라인은 일반화(`chore: 빌드 산출물 이미지 핀 갱신 (${APPS})` 등 — pg-tools/앱 혼재 대응). `tools/README.md` "## update-image 폴링" 인근에 `repin-pgtools.ts` 등재(bump.yaml이 pg-tools digest 재핀 시 호출; check-doc-index 자기참조 충족).

> ⚠️ **digest 해석 명령 라이브 검증 필요**: `docker buildx imagetools inspect … --format '{{.Manifest.Digest}}'`가 GHCR single-arch(build.yaml `provenance:false`, `platforms:linux/arm64`) 태그에서 top digest를 반환하는지 구현 중 실측(대안: `docker manifest inspect -v … | jq -r '.Descriptor.digest'`). bump.yaml runner에 buildx 프리인스톨 확인.

**Step 4 — 게이트.** `bun run typecheck`(repin-pgtools 포함) → `bats tests/gates/test_repin-pgtools.bats`(3/3) → `actionlint .github/workflows/bump.yaml`(clean) → `bats tests/gates/test_pgtools-digest.bats`(재핀 후에도 일관성 유지 확인) → `bash scripts/check-doc-index.sh`(repin-pgtools 등재) → `make ci`.

**Step 5 — 커밋.** `git add tools/repin-pgtools.ts tests/gates/test_repin-pgtools.bats .github/workflows/bump.yaml tools/README.md` → `feat: bump.yaml pg-tools digest 자동 재핀(repin-pgtools) — PgDumpHedgeStale 재발 방지`

---

### B12.10 (부록, owner 수동) 서드파티 digest 그룹 PR 처리 (M16)

**커밋 없음** — Renovate Dependency Dashboard의 'image digests' 그룹 PR 확인·머지(owner 판단). gh 명령:
```bash
# 1) Renovate가 연 digest 핀 PR 목록(주1회 스케줄, automerge:false)
gh pr list --repo ukkiee/homelab --label dependencies --search 'digest in:title' --state open
# 2) 미생성이면 kubernetes manager 파일매칭·pinDigests 동작을 수동 트리거로 검증
gh workflow run renovate.yaml --repo ukkiee/homelab
gh run watch --repo ukkiee/homelab   # Dependency Dashboard 재생성 후 재확인
# 3) 리뷰 후 머지(자동머지 금지 — 리뷰 후):
gh pr checks <PR> && gh pr merge <PR> --squash
```
검증: 머지 후 `grep -rL 'sha256:' platform/victoria-stack/*/prod/*.yaml`(digest 미핀 파일 수 감소) — 완전 소거는 반복 스케줄에 위임(신규 컴포넌트는 files 패턴대로 인라인 digest 핀을 기본 규약으로).

---

### 게이트·라이브 검증

- **각 PR**: `make ci`(required `gate` 재현) 통과 — 신규 bats(`test_check-doc-index`·`test_pgtools-digest`·`test_repin-pgtools`·`test_backup-local-asset`·test_06/09 확장)가 `run-bats.sh`에 자동 수집되고 `check-bats-accounting`이 각 정확히 1도메인(gate) 배정 확인. `shellcheck $(git ls-files '*.sh')`·`bun run typecheck` clean.
- **owner-local**: `make verify`(check-doc-index·check-skeleton 양방향 포함) · `make verify-traps`(PG·백업 원장 3+2경로 실재 + SSOT↔원장 tie OK) · `make verify-runbook-index`(양방향 fail-closed OK) · `make backup-local-asset OUT=<외장 SSD>` 생성 후 `ARGS=--verify` 신선도 OK.
- **라이브**(선택, `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`): `infra/k3s-bootstrap/verify-cluster.sh` → `[6] k3s version pinned … OK`(라이브 kubeletVersion == `v1.36.2+k3s1`). bump.yaml 재핀은 다음 pg-tools 소스 변경(`ops/pg-tools/**`) push 시 build→bump PR로 라이브 관측(수동 카나리: `gh workflow run build.yaml` → bump PR에 5-site digest 갱신 확인 → `test_pgtools-digest` 일관성 유지).

### 롤백 노트

- 순수 문서·게이트·owner-local 스크립트 추가라 **라이브 클러스터 롤백 리스크 0**. PR 리버트로 원복(직렬 머지라 스택 의존 없음).
- **check-doc-index/check-skeleton 양방향**: false-positive 시 즉시 red이나 라이브 무영향 — 가드 로직만 hotfix. dirs 배열 축소로 스켈레톤 커버 공백 우려 시, 역방향 검사가 대체 커버함을 `test_check-skeleton-gate` 역방향 케이스가 증명.
- **bump.yaml 재핀(최고위험)**: digest 해석 실패 시 스텝 non-zero(fail-closed — 잘못된 핀 push 없음). 재핀 오작동 시 bump.yaml의 elif 분기만 리버트(apps values 경로는 불변). 잘못 재핀된 digest는 PR 리뷰(사람 머지)가 최종 게이트.
- **verify-cluster [6]/LOCAL_PATH 가드**: Renovate가 `versions.env`만 bump해 red가 되면 정상 동작(manifest 동반 갱신 유도) — 게이트를 끄지 말고 manifest를 versions.env에 맞춰 갱신.

### 다음 배치 진행 조건

- PR-12a·12b·12c 순차 머지 + 각 `gate` green.
- `make verify-traps`·`make verify-runbook-index` owner-local OK(원장·인덱스 tie 무드리프트).
- B12는 Wave 3 문서·게이트 하드닝의 종착 — 후속은 B13(잔손질 스윕). B12 산출 가드(check-doc-index·check-skeleton 양방향)는 B13이 추가/삭제하는 scripts·tools·컴포넌트에 즉시 적용되므로, B13 각 항목은 **같은 PR에서 README 등재/컴포넌트 표 동반 갱신** 필수(자기참조 게이트가 강제).
```
## B13. 잔손질 스윕 (선별 low 확정 목록) (Wave 3)

**목표** 감사에서 low로 확정됐거나 B1~B12에 흡수되지 않은 잔여 결함 19항목을 항목별 미니 태스크로 청소한다. 전부 저위험(주석·스키마 락·테스트 추가·미사용 제거)이며 라이브 영향은 사실상 0(신규 PV/변이 없음). **선행 조건**: B3(가드 소생)·B8(시크릿 채널)·B12(doc-index)가 먼저 머지돼야 중복·순서 충돌이 없다(항목별 명시). **PR 구성**(직렬 머지 — 스택 squash 함정 회피): PR-13a "차트·플랫폼 잔손질"(①②③④⑤⑥), PR-13b "tools 잔손질"(⑧⑨⑩⑪), PR-13c "infra·scripts·docs 잔손질"(⑫⑬⑭⑮⑯⑰⑲). 코드 없는 처분 2건(⑦⑱)은 PR 밖.

### ⚠️ 설계 보정 (실파일 실측 vs 설계 스냅샷)

- **⑦ (ghcr-pull 상호참조)**: B8 §178-188이 "GHCR_PULL_TOKEN 회전 단일 타겟(prod+files 두 봉인본 동시)"를 명시 제공한다. B8이 Wave 2로 B13보다 먼저 머지되므로 상호참조 주석은 **불요 → 제외(B8 흡수)**. B8이 ghcr-pull 단일화를 descope할 때만 fallback(주석 배선) 발동 — 아래 B13.D1.
- **⑬ (internal_suffix)**: 설계는 "미사용 정리"만 언급하나, 실측 결과 `internal_suffix`는 **cloudflare + tailscale 두 루트에 선언**되고 어느 `.tf`에서도 `var.internal_suffix` 소비 0(둘 다 dead), 게다가 `iac.yaml`(2줄)·`tf-reconcile.yaml`(2줄)이 `TF_VAR_internal_suffix`를 주입한다. 즉 완전 제거는 tf+workflow 4파일을 함께 건드려야 한다(순수 tf 주석보다 큼) — 태스크에 전 touch-point 열거.
- **⑨ (내부 host 유일성)**: 파생 내부 host `${app}.home.${DOMAIN}`은 app 이름 유일성(디렉토리+원장 가드)으로 **이미 유일**하다. 실제 갭은 *명시 override host* 충돌뿐 — 내부 앱은 apps.json 미등록이라 `apps/*/values.yaml` route.host 스캔이 유일한 검사 수단. 좁은 방어로 구현.
- **④ (차트 구본 [[ ]])**: 중간(silent-pass) `[[ ]]`는 `test_route.bats`(11-13)·`test_deployment.bats`(10-16, 41-42)에만 존재. `test_schema.bats`(23, 31)·`test_image-digest.bats`(38)의 `[[ ]]`는 **마지막 명령**(테스트 결과 = last exit)이라 안전 — B3 lint(위치 인지: 중간 `[[ ]]`만 탐지)도 통과. 따라서 ④ 대상은 2파일. B3/B13 순서 충돌은 아래 B13.4 서두에서 조건 처분.
- **⑲ (README stale)**: 실측상 유일한 *서술* stale = `verify-secrets.sh` 설명의 "recipient 정확히 2개"(scripts/README:23)·"recipient 2개"(Makefile:60) — 코드는 count→**identity(canonical cluster+recovery 집합 일치)**로 하드닝됨(개수 무의미). adguard "edge NS"는 **정확**(미이동)이라 stale 아님. 미등재 항목(scripts 11·tools 3)은 **B12 check-doc-index 소관** → ⑲는 서술 교정만.
- **①**: `check-resource-limits.sh`는 `platform/`만 스캔(apps/ 미포함, charts/ 제외)한다 — 차트 스키마(apps 지배)와 **게이트 충돌 없음**. 판단은 아래 B13.1.

---

### B13.1 ① 차트 cpu limit — 의도 문서화(required 유지) [PR-13a]
**Files:** Modify: `platform/charts/app/values.schema.json:29-35`(resources 블록 주석), `platform/charts/app/tests/test_schema.bats`(락 단언 1건). **Test:** test_schema.bats.

**판단(택1 = 의도 문서화, required 제외 아님)**: check-resource-limits.sh는 `platform/`(베스포크)만 스캔하고 "cpu limit 비요구(CFS throttling 회피)"는 그 **런타임 SRE 정책**이다. 반면 공유 차트의 `limits.required:["cpu","memory"]`는 apps/를 지배하는 **온보딩 사이징-디시플린**(values.yaml:21 "런타임별 메모리는 강제 온보딩 게이트" — 앱 저자가 4값을 전부 명시하게 강제)이다. 두 정책은 **분리 트리(platform/ vs apps/)를 지배**하며 게이트 충돌이 없다. 필드를 강제해도 *값*은 저자 자유(넉넉한 cpu limit로 throttling 회피 가능)라 "필드 명시 강제 ≠ 타이트값 강제". 따라서 **required 제외(스키마 계약 완화 + app-config-schema/create-app/테스트 3파일 캐스케이드)는 비용>이득**, 저-스윕엔 부적합. → **의도를 성문화**해 리뷰어의 "왜 다른가"를 0-리스크로 해소.

- **Step 1** — values.schema.json:29의 `"resources"` 앞 줄에 주석 필드 추가(draft-07은 미지 키 무시):
  ```json
  "resources": {
    "comment": "cpu·memory request + cpu·memory limit 4값 전부 required — 온보딩 사이징 디시플린(값 상속 금지, 앱 저자가 명시 선언). platform/ 베스포크의 check-resource-limits.sh는 cpu limit 비요구(런타임 SRE=CFS throttling 회피)지만 이 차트는 apps/를 지배하는 별개 레이어라 정책이 다르다(분리 트리·게이트 무충돌). cpu limit 값은 저자 자유(넉넉히 두면 throttling 회피).",
    "type": "object", "required": ["requests", "limits"],
  ```
- **Step 2** — test_schema.bats 말미에 의도 락 단언(회귀 시 재검토 강제):
  ```bash
  @test "schema keeps cpu+memory required on both requests and limits (onboarding sizing-discipline; divergence from platform SRE policy is intentional and documented)" {
    S="$CHART/values.schema.json"
    run jq -e '.properties.resources.properties.limits.required == ["cpu","memory"]' "$S"; [ "$status" -eq 0 ]
    run jq -e '.properties.resources.comment | test("사이징 디시플린")' "$S"; [ "$status" -eq 0 ]
  }
  ```
- **게이트**: `make chart-test` → 기대 PASS(신규 test + 기존 렌더 무변). `bun run typecheck` 무관.
- **커밋**: `git add platform/charts/app/values.schema.json platform/charts/app/tests/test_schema.bats` → `docs(chart): cpu limit required 의도 성문화 — 온보딩 사이징 디시플린 vs platform SRE 정책 분리 명시`

### B13.2 ② app.validate host↔public `.home.` 규칙 + bats 2케이스 [PR-13a]
**Files:** Modify: `platform/charts/app/templates/_helpers.tpl:42-46`(app.validate), `platform/charts/app/tests/test_route.bats`(+2 @test). **Test:** test_route.bats(렌더 fail 단언). **근거**: 현재 create-app.ts:85-86만 `.home.`↔public 정합을 검사 — 차트 자체(모든 소비자 렌더/배포 SSOT, deployment.yaml:1이 app.validate include)는 미검사. 도메인 무지식이라 `.home.` 존재↔public XOR만 강제(Sprig `contains`). 실측: page(public·비-.home.)·trip-mate-api(내부·.home.)·fixtures 전부 규칙 만족 → 무회귀.

- **Step 1** — 실패 테스트를 test_route.bats에 추가(렌더가 fail해야):
  ```bash
  @test "app.validate rejects a public route bound to an internal .home. host" {
    run tpl --set kind=web --set route.public=true --set route.host=admin.home.example.com
    [ "$status" -ne 0 ]
    echo "$output" | grep -q '.home.'
  }
  @test "app.validate rejects an internal route (public=false) whose host is not a .home. host" {
    run tpl --set kind=web --set route.public=false --set route.host=api.example.com
    [ "$status" -ne 0 ]
    echo "$output" | grep -q '.home.'
  }
  ```
- **Step 2** — 실행: `bats platform/charts/app/tests/test_route.bats` → 기대 **실패**(app.validate에 규칙 부재라 렌더 성공→status 0).
- **Step 3** — _helpers.tpl:42-46 `app.validate` 정의를 교체(served·host 있을 때만 XOR 검사):
  ```
  {{- define "app.validate" -}}
  {{- if and (include "app.isServed" .) (not .Values.route.host) -}}
  {{- fail (printf "route.host is required for kind=%s" .Values.kind) -}}
  {{- end -}}
  {{- if and (include "app.isServed" .) .Values.route.host -}}
    {{- if and .Values.route.public (contains ".home." .Values.route.host) -}}
    {{- fail (printf "공개 route는 내부 .home. host를 쓸 수 없다: %s" .Values.route.host) -}}
    {{- end -}}
    {{- if and (not .Values.route.public) (not (contains ".home." .Values.route.host)) -}}
    {{- fail (printf "내부 route(public=false)는 .home. host여야 한다: %s" .Values.route.host) -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
  ```
- **게이트**: `make chart-test` → 기대 PASS(신규 2 + 기존 test_route/test_deployment 무회귀).
- **커밋**: `git add platform/charts/app/templates/_helpers.tpl platform/charts/app/tests/test_route.bats` → `feat(chart): app.validate에 host↔public .home. 정합 강제 — 공개 route의 내부 host·내부 route의 공개 host 렌더 차단`

### B13.3 ③ values.yaml sectionName 주석 교정 [PR-13a]
**Files:** Modify: `platform/charts/app/values.yaml:33`. **근거**: httproute.yaml:29의 실 매핑은 `web-public`(true)/**`web-internal-tls`**(false)인데 주석은 `web-internal (false)`로 오기(접미사 `-tls` 누락). test_route.bats:19가 실값 `web-internal-tls`를 이미 단언.
- **Step 1** — values.yaml:33 `public: false # sectionName 매핑: web-public (true) / web-internal (false)`의 `web-internal (false)`를 `web-internal-tls (false)`로 교체.
- **검증**: `grep -n 'web-internal-tls (false)' platform/charts/app/values.yaml`(존재) + `grep -c 'web-internal ' platform/charts/app/values.yaml`(0). `make chart-test` PASS.
- **커밋**: `git add platform/charts/app/values.yaml` → `docs(chart): values.yaml sectionName 주석 오기 교정(web-internal→web-internal-tls, 실 리스너명 일치)`

### B13.4 ④ 차트 구본 bats 중간 `[[ ]]` 정비 [PR-13a]
**Files:** Modify: `platform/charts/app/tests/test_route.bats:11-14`, `platform/charts/app/tests/test_deployment.bats:10-16,41-43`. **조건 처분(B3 선행)**: B3(Wave 1)의 assertion-lint(test_bats-naming 선례, 위치 인지: 중간 `[[ ]]`+`^\s*! ` 탐지)가 **platform/charts/app/tests를 스캔하면** — B3가 green 머지하려면 이 중간 `[[ ]]`를 이미 청소했어야 하므로 **④=제외(B3 흡수)**, B13 시점 재스캔으로 확인. **스캔하지 않으면**(B3가 tools/scripts로 스코프 한정) ④가 청소 + B3 lint glob에 `platform/charts/app/tests` 편입. 아래는 후자(청소) 실코드 — 실측 시 이미 clean이면 "제외(B3 흡수)"로 마감.
- **Step 1** — test_route.bats:11-14의 4개 `[[ "$rt" == *"…"* ]]`를 `echo "$rt" | grep -qF '…'` 4줄로 교체(단순 명령 = bash 3.2에서도 set -e 게이트). 예: `[[ "$rt" == *"name: homelab"* ]]` → `echo "$rt" | grep -qF 'name: homelab'`.
- **Step 2** — test_deployment.bats "web Deployment is wave2…"(10-17): 양성 `[[ == ]]`(10-13,17)→`grep -qF`, 음성 `[[ != ]]`(14-16)→`run grep -qF '…'; [ "$status" -ne 0 ]`. "static Deployment…"(41-43): 41-43→`grep -qF`. (line 22 `[[ != httpGet ]]`는 단일=last라 안전 — 선택적 통일.)
- **게이트**: `make chart-test` PASS + (B3 lint 배선 시) `./scripts/run-bats.sh` 중 lint bats PASS. macOS bash 3.2에서 실행해 중간 단언 실효 확인.
- **커밋**: `git add platform/charts/app/tests/test_route.bats platform/charts/app/tests/test_deployment.bats` → `test(chart): 중간 [[ ]] 단언을 grep 단순명령으로 정비 — bash 3.2 silent-pass 함정 제거`

### B13.5 ⑤ platform/files/prod 렌더 bats(homepage 패턴 복제) [PR-13a]
**Files:** Create: `platform/files/prod/test_files_render.bats`. **Test:** 신규(gate 자동 수집 — charts 밖·비 .ci-exclude). **근거**: files/prod 6개 bats는 전부 개별 소스 YAML을 grep(`$BATS_TEST_DIRNAME/deployment.yaml`) — `kustomize build` 조립 출력 검증 0. files는 SealedSecret(KSOPS 아님)이라 렌더가 **CI-safe**(age 불요, homepage와 동형·cache test_ksops_render와 대비).
- **Step 1** — homepage/prod/test_homepage_render.bats setup 패턴(CI면 skip 금지·fail-closed, 로컬만 skip)을 복제해 신규 파일 작성:
  ```bash
  #!/usr/bin/env bats
  # files kustomize render 가드 — grep-on-source가 못 잡는 조립 출력(namespace 주입·sealed 포함). @test 영어. ⚠️ 중간단언 [ ]만.
  setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    if ! command -v kustomize >/dev/null || ! command -v yq >/dev/null; then
      [ -z "${CI:-}" ] || { echo "FAIL: CI인데 kustomize/yq 부재 — gate setup-toolchain 회귀"; return 1; }
      skip "kustomize/yq 미설치(로컬만)"
    fi
    RENDERED="$BATS_TEST_TMPDIR/files-render.yaml"
    ( cd "$ROOT" && kustomize build platform/files/prod ) > "$RENDERED" 2>/dev/null
  }
  @test "files kustomize build succeeds and emits core kinds under namespace files" {
    [ -s "$RENDERED" ]
    for kind in PersistentVolumeClaim Deployment Service HTTPRoute NetworkPolicy SealedSecret; do
      run yq -e "select(.kind == \"$kind\") | .kind" "$RENDERED"; [ "$status" -eq 0 ]
    done
    run yq -e 'select(.kind == "Deployment") | .metadata.namespace' "$RENDERED"; [ "$output" = "files" ]
    run yq -e 'select(.kind == "SealedSecret") | .metadata.namespace' "$RENDERED"; [ "$output" = "files" ]
  }
  @test "two HTTPRoutes render (internal + public listeners)" {
    run bash -c "yq 'select(.kind==\"HTTPRoute\") | .metadata.name' '$RENDERED' | grep -c ."
    [ "$output" -eq 2 ]
  }
  ```
- **Step 2** — 실행: `bats platform/files/prod/test_files_render.bats` → 기대 PASS(로컬 kustomize 존재 시).
- **게이트**: `make verify`(check-bats-accounting: 신규 bats가 gate 도메인 단일 배정) + `./scripts/run-bats.sh --list | grep files_render`(수집 확인).
- **커밋**: `git add platform/files/prod/test_files_render.bats` → `test(files): kustomize 조립 렌더 가드 추가(homepage 패턴 — 코어 kind·namespace 주입·2 리스너)`

### B13.6 ⑥ test_argocd_values.bats #224 회귀 단언 [PR-13a]
**Files:** Modify: `platform/argocd/test_argocd_values.bats`(+1 @test). **근거**: bootstrap-values.yaml:119-120이 #224 수정(oncePer를 `operationState.syncResult.revision(s)`에 게이팅 + `syncResult != nil` 가드)인데 현 테스트(81-82)는 'Healthy'·'oncePer' 존재만 확인 — 실 needle 미고정. `sync.revision`(구본)으로 회귀 시 모노레포 거짓 "배포 완료" 버스트 재발.
- **Step 1** — 신규 @test 추가(comment/prose 오탐 회피 위해 양성 needle 2개만 — `operationState.syncResult != nil`은 119행에만, `operationState.syncResult.revision`은 120행에만 등장):
  ```bash
  @test "on-deployed oncePer gates on the actual sync-job revision, not observed HEAD (#224 noise regression guard)" {
    v=platform/argocd/bootstrap-values.yaml
    run yq '.notifications.triggers."trigger.on-deployed"' "$v"
    printf '%s' "$output" | grep -qF 'operationState.syncResult != nil'      # #224 nil 가드
    printf '%s' "$output" | grep -qF 'operationState.syncResult.revision'    # oncePer가 실 sync 작업 revision(sync.revision 아님)
  }
  ```
- **Step 2** — 실행: `bats platform/argocd/test_argocd_values.bats` → 기대 PASS(현 값이 #224 반영).
- **게이트**: `./scripts/run-bats.sh --list | grep argocd_values`(gate 수집·grep 기반 CI-safe) + 실행 PASS.
- **커밋**: `git add platform/argocd/test_argocd_values.bats` → `test(argocd): on-deployed oncePer가 syncResult revision에 게이팅됨을 고정(#224 노이즈 회귀 가드)`

---

### B13.7 ⑧ create-app 미니 검증기 미지 키워드 화이트리스트 [PR-13b]
**Files:** Modify: `tools/tests/test_app-config.bats`(+1 정적 가드), `tools/create-app.ts:46`(주석 1줄). **근거**: create-app.ts:48-72 `check()`가 구현하는 키워드는 유한(enum/type/pattern/minimum/maximum/minItems/uniqueItems/required/properties/additionalProperties/items/$ref). 스키마가 `maxLength`·`const`·`oneOf`·`format` 등 **미구현 제약**을 추가하면 조용히 미검증(false-green). 스키마는 `new URL(...)`로 고정 경로 로드라 런타임 부정 테스트 불가 → `check()` 순회 위치(root·properties[*]·items·definitions[*])에서만 키를 수집해 화이트리스트 ⊆ 검사하는 **정적 bats**로 고정.
- **Step 1** — test_app-config.bats에 화이트리스트 가드 추가(순회를 check()와 동형으로):
  ```bash
  @test "app-config-schema uses only keywords the create-app mini-validator implements (unimplemented constraint = silent under-validation)" {
    run bun -e '
      const s = JSON.parse(require("fs").readFileSync(process.env.S,"utf8"));
      const OK = new Set(["$schema","$id","title","description","$ref","definitions","default","comment",
        "type","enum","pattern","minimum","maximum","minItems","uniqueItems","required","properties","additionalProperties","items"]);
      const bad = [];
      const visit = (n) => { if (!n || typeof n!=="object") return;
        for (const k of Object.keys(n)) if (!OK.has(k)) bad.push(k);
        if (n.properties) for (const v of Object.values(n.properties)) visit(v);
        if (n.items) visit(n.items);
        if (n.definitions) for (const v of Object.values(n.definitions)) visit(v);
      };
      visit(s);
      if (bad.length) { console.error("미구현 키워드:", [...new Set(bad)].join(",")); process.exit(1); }
    '
    [ "$status" -eq 0 ]
  }
  ```
  (setup의 `S`를 env로 넘김: `run` 앞에 `S="$S"` export — 기존 setup이 `S`를 이미 설정하므로 `env S="$S" bun -e ...` 형태로 호출.)
- **Step 2** — create-app.ts:46 스키마 로드 줄 위에 SSOT 주석: `// 미니 검증기 지원 키워드 SSOT는 test_app-config.bats 화이트리스트 — 스키마에 미구현 제약(maxLength/const/oneOf 등) 추가 시 그 가드가 fail-closed로 잡는다.`
- **게이트**: `bats tools/tests/test_app-config.bats` PASS(현 스키마 clean) + `bun run typecheck`.
- **커밋**: `git add tools/tests/test_app-config.bats tools/create-app.ts` → `test(create-app): app-config 스키마가 미니 검증기 미구현 키워드를 쓰면 fail-closed 정적 가드 추가`

### B13.8 ⑨ create-app 내부 host 유일성 [PR-13b]
**Files:** Modify: `tools/create-app.ts:82-87`(내부 분기), `tools/tests/test_create-app.bats`(+1 @test). **근거**: name/host 유일성(115-119)은 `served && pub`(공개·apps.json)만. 내부 앱은 apps.json 미등록 — 파생 host는 app명 유일성으로 자동 유일하나 *명시 override host*는 충돌 가능(오라우팅). 유일 검사원은 `apps/*/deploy/prod/values.yaml` route.host 스캔.
- **Step 1** — 실패 테스트: `$FR/apps/other/deploy/prod/`에 `route: {host: shared.home.example.com, public: false}` values 선배치 후, 내부 앱 config `route: {public: false, host: shared.home.example.com}`로 gen → 기대 status≠0(현재는 통과).
- **Step 2** — create-app.ts served 분기(86 직후, non-pub일 때) 내부 host 스캔 추가:
  ```ts
  else {
    if (!host.endsWith(`.home.${DOMAIN}`)) fail(`internal host는 *.home.${DOMAIN}: '${host}'`);
    // 내부 host 유일성 — 내부 앱은 apps.json 미등록이라 기존 apps/*/values.yaml route.host를 스캔(명시 override 충돌=오라우팅)
    const appsDir = `${ROOT}/apps`;
    if (existsSync(appsDir)) for (const d of readdirSync(appsDir)) {
      const vp = `${appsDir}/${d}/deploy/prod/values.yaml`;
      if (d === app || !existsSync(vp)) continue;
      const rh = (parseYaml(readFileSync(vp, "utf8")) ?? {})?.route?.host;
      if (rh === host) fail(`내부 host '${host}'가 apps/${d}에 이미 배선됨(오라우팅 차단)`);
    }
  }
  ```
  (`readdirSync`를 line 6 import에 추가: `import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";`)
- **게이트**: `bats tools/tests/test_create-app.bats` PASS + `bun run typecheck`.
- **커밋**: `git add tools/create-app.ts tools/tests/test_create-app.bats` → `feat(create-app): 내부 앱 명시 host 유일성 검사 추가(apps/ route.host 스캔 — 오라우팅 차단)`

### B13.9 ⑩ db-url/cache-url 라이브 경로 kubectl 스텁 bats [PR-13b]
**Files:** Modify: `tools/tests/test_db-url.bats`(+1 @test), `tools/tests/test_cache-url.bats`(+1 @test). **근거**: 두 테스트 모두 dry-run만(주석 명시) — 라이브 경로(kubectl→env 파일 write, host 치환, **평문 stdout 비노출**)가 무검증. test_verify-db-marker.bats(15-33)의 PATH 스텁 패턴 재사용 → CI-safe.
- **Step 1** — test_db-url.bats에 스텁 테스트 추가(env 파일 기록·값 미노출·host 치환 검증):
  ```bash
  @test "db-url live path writes the env key to file, substitutes tailscale host, and never prints plaintext" {
    TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"
    cat > "$TMP/bin/kubectl" <<'STUB'
  #!/usr/bin/env bash
  # ro-conn의 ORDERS_RO_DATABASE_URL 값을 base64로 반환(라이브 무접근)
  printf '%s' "cG9zdGdyZXM6Ly91Om5AcGctcncucHJvZDo1NDMyL29yZGVycw=="  # postgres://u:n@pg-rw.prod:5432/orders
  STUB
    chmod +x "$TMP/bin/kubectl"
    run env PATH="$TMP/bin:$PATH" bun "$ROOT/tools/db-url.ts" --name orders --host 100.99.0.1 --env-local "$TMP/.env.local"
    [ "$status" -eq 0 ]
    grep -q '^ORDERS_RO_DATABASE_URL=postgres://u:n@100.99.0.1:5432/orders$' "$TMP/.env.local"   # host 치환 + 키 기록
    [ "$(printf '%s' "$output" | grep -c 'postgres://')" -eq 0 ]    # 평문 URL stdout 비노출(카운트 패턴 — B3 lint-safe)
    rm -rf "$TMP"
  }
  ```
- **Step 2** — test_cache-url.bats에 대칭 테스트 추가(기본 host 127.0.0.1, `<NAME>_REDIS_RO_URL`, `@host:6379` 치환, stdout 비노출). base64는 `redis://...@cache-sessions:6379` 상당값.
- **게이트**: `bats tools/tests/test_db-url.bats tools/tests/test_cache-url.bats` PASS + `./scripts/run-bats.sh --list | grep -E 'db-url|cache-url'`(gate 유지).
- **커밋**: `git add tools/tests/test_db-url.bats tools/tests/test_cache-url.bats` → `test(db-url/cache-url): 라이브 경로 kubectl 스텁 테스트 추가(host 치환·env 파일 기록·평문 stdout 비노출 고정)`

### B13.10 ⑪ DB_RESERVED_NAMES export 정리 [PR-13b]
**Files:** Modify: `tools/lib/identity.ts:18`. **근거**: `DB_RESERVED_NAMES`는 `export`이나 외부 importer 0(grep 확인) — 동일 파일 `resourceNameError`(25)만 소비. test_identity.bats는 `resourceNameError` 경유 검증(직접 import 아님)이라 무영향. 불필요 공개 표면 축소.
- **Step 1** — identity.ts:18 `export const DB_RESERVED_NAMES = new Set([...` → `const DB_RESERVED_NAMES = new Set([...`(export 제거).
- **검증**: `bun run typecheck`(무오류) + `bats tools/tests/test_identity.bats`(resourceNameError 예약어 케이스 PASS) + `grep -rn 'import.*DB_RESERVED_NAMES' tools/`(0건).
- **커밋**: `git add tools/lib/identity.ts` → `refactor(identity): DB_RESERVED_NAMES를 모듈 프라이빗화(외부 소비 0 — resourceNameError 전용)`

---

### B13.11 ⑫ destroy-guard.sh:10 주석 오기 교정 [PR-13c]
**Files:** Modify: `.github/actions/tf-destroy-guard/destroy-guard.sh:10`. **근거**: 자동 관리 app DNS 표면은 `cloudflare_dns_record.app[*]`(dns.tf:49 실재, 34행 본문·test_tf-destroy-guard.bats ALLOW=`^cloudflare_dns_record\.app\[`가 확증)인데 line 10 주석만 `cloudflare_dns_record.public[*]`로 오기(public[*]=apex/www는 끝까지 차단 대상 — 정반대).
- **Step 1** — line 10 `= app 공개 DNS, cloudflare_dns_record.public[*])` → `= app 공개 DNS, cloudflare_dns_record.app[*])`.
- **검증**: `grep -n 'cloudflare_dns_record.app\[\*\]' .github/actions/tf-destroy-guard/destroy-guard.sh`(10·34 둘 다) + `bats tools/tests/test_tf-destroy-guard.bats` PASS + `shellcheck .github/actions/tf-destroy-guard/destroy-guard.sh`.
- **커밋**: `git add .github/actions/tf-destroy-guard/destroy-guard.sh` → `docs(tf-destroy-guard): ALLOW 예시 주석 오기 교정(public[*]→app[*], 본문·테스트와 일치)`

### B13.12 ⑬ cloudflare/tailscale internal_suffix 처분(제거) [PR-13c]
**Files:** Modify: `infra/cloudflare/variables.tf:18-21`, `infra/tailscale/variables.tf:9-11`, `infra/cloudflare/terraform.tfvars.example:16`, `infra/tailscale/terraform.tfvars.example:12-13`, `.github/workflows/iac.yaml:86,134`, `.github/workflows/tf-reconcile.yaml:47,221`. **판단(제거)**: 두 루트 모두 `var.internal_suffix` 소비 0(dead), tailscale의 "tfvars 호환 유지" 주석은 참조한 전역 nameserver 전환이 **완료된 obsolete 결정**. 선언·TF_VAR 주입을 동반 제거하면 CI에서 undeclared-var 경고 없음(양쪽 동시 제거).
- **Step 1** — cloudflare/variables.tf의 `variable "internal_suffix" { ... }` 블록 삭제. tailscale/variables.tf의 동 블록 삭제.
- **Step 2** — 두 terraform.tfvars.example의 `internal_suffix = ...` 줄(및 tailscale의 상단 안내 주석 12행) 삭제.
- **Step 3** — iac.yaml:86,134 및 tf-reconcile.yaml:47,221의 `TF_VAR_internal_suffix: home.${{ secrets.TF_DOMAIN }}` 줄 삭제.
- **검증**: `grep -rn internal_suffix infra/ .github/`(0건) + `make tf-validate`(3루트 fmt+validate PASS — terraform 필요, 로컬/owner). **리스크 노트**: owner-local(gitignored) `terraform.tfvars`에 잔존 시 terraform이 undeclared-var **경고**(비치명) — owner가 로컬 줄 삭제.
- **커밋**: `git add infra/cloudflare/variables.tf infra/tailscale/variables.tf infra/cloudflare/terraform.tfvars.example infra/tailscale/terraform.tfvars.example .github/workflows/iac.yaml .github/workflows/tf-reconcile.yaml` → `refactor(infra): 미사용 internal_suffix 변수·TF_VAR 주입 제거(양 루트 소비 0, 전역 nameserver 전환 후 obsolete)`

### B13.13 ⑭ k3s-install 무효 플래그 제거 + test_05 갱신 [PR-13c]
**Files:** Modify: `infra/k3s-bootstrap/k3s-install.sh:32-33`, `infra/k3s-bootstrap/versions.env:25`, `infra/k3s-bootstrap/tests/test_05-k3s-flags.bats`(+1 @test). **근거**: `--disable=...,local-storage,...`(23행)로 내장 local-path-provisioner를 끈 상태에서 `--default-local-storage-path=${INTERNAL_STORAGE_PATH}`(33행)는 **no-op**(끈 provisioner의 경로 지정). `INTERNAL_STORAGE_PATH`(versions.env:25)의 유일 소비자가 이 dead 플래그 → 함께 제거.
- **Step 1** — 실패(회귀) 테스트를 test_05에 추가(단일 `[[ ]]`=last, 안전):
  ```bash
  @test "does NOT pass --default-local-storage-path (built-in local-storage provisioner is disabled → flag is a no-op)" {
    [[ "$EXEC" != *"--default-local-storage-path"* ]]
  }
  ```
  실행: `bats infra/k3s-bootstrap/tests/test_05-k3s-flags.bats` → 기대 **실패**(현재 플래그 존재).
- **Step 2** — k3s-install.sh: 32행 `--write-kubeconfig-mode=0600 \`의 trailing `\` 유지하되 33행 `--default-local-storage-path=${INTERNAL_STORAGE_PATH}"`를 삭제하고 32행 끝을 `--write-kubeconfig-mode=0600"`로 닫는다(연속 문자열 종료). versions.env:25 `export INTERNAL_STORAGE_PATH=...` 줄 삭제.
- **게이트**: `bats infra/k3s-bootstrap/tests/` PASS + `K3S_PRINT_EXEC=1 infra/k3s-bootstrap/k3s-install.sh | grep -c default-local-storage-path`(0) + `shellcheck infra/k3s-bootstrap/k3s-install.sh`.
- **커밋**: `git add infra/k3s-bootstrap/k3s-install.sh infra/k3s-bootstrap/versions.env infra/k3s-bootstrap/tests/test_05-k3s-flags.bats` → `fix(k3s): local-storage 비활성 상태의 no-op --default-local-storage-path 플래그·orphan INTERNAL_STORAGE_PATH 제거 + 회귀 가드`

### B13.14 ⑮ netpol-rehearsal.sh 처분(인자화) [PR-13c]
**Files:** Modify: `scripts/netpol-rehearsal.sh`, `scripts/README.md`(B12가 등재한 항목 서술 조정 — 없으면 신규 1줄). **판단(인자화)**: 헤더가 "머지 전 필수 — netpol candidate 리허설"로 **재사용 하네스**를 표방하나 pooler 변경(`allow-egress-to-database`·`cnpg.io/poolerName`·`COMP=network-policies`)에 하드코딩 → 향후 netpol 변경에 재사용 불가. owner-local(라이브)이라 gate 테스트 없음 → env override로 일반화 + 문서화.
- **Step 1** — 하드코딩을 env 기본값으로: line 6 `APP=network-policies-prod; NS=prod` 아래에 `COMP="${COMP:-network-policies}"; NETPOL="${NETPOL:-allow-egress-to-database}"; NEEDLE="${NEEDLE:-cnpg.io/poolerName}"` 추가하고, 16·24행 `allow-egress-to-database`·`cnpg.io/poolerName`을 `"$NETPOL"`·`"$NEEDLE"`로, 23행 `make -s render COMP=network-policies`를 `make -s render COMP="$COMP"`로 치환.
- **Step 2** — 헤더 주석에 "재사용: COMP/NETPOL/NEEDLE env override(기본=CNPG pooler netpol)" 1줄 추가. scripts/README(파괴성/호출경로 표기 규약)에 owner-local·live 표기.
- **검증**: `bash -n scripts/netpol-rehearsal.sh`(문법) + `shellcheck scripts/netpol-rehearsal.sh`(clean) + `grep -c 'allow-egress-to-database' scripts/netpol-rehearsal.sh`(0 — 전부 변수화).
- **커밋**: `git add scripts/netpol-rehearsal.sh scripts/README.md` → `refactor(netpol-rehearsal): COMP/NETPOL/NEEDLE env 인자화 — 특정 pooler 변경 하드코딩 제거(재사용 하네스화)`

### B13.15 ⑯ audit-orphan-pv make 타겟 노출 [PR-13c]
**Files:** Modify: `Makefile:147-172`(ops 그룹). **근거**: `scripts/audit-orphan-pv.sh`(라이브 read-only, Released PV 누수 감사)가 make 타겟 없이 방치 — `audit`(정적 bun)과 구분되는 라이브 감사. ops 패턴(KUBECONFIG_LIVE) 미러.
- **Step 1** — Makefile:147 `.PHONY: argo-status ... audit` 줄 끝에 `audit-orphan-pv` 추가. `audit:` 타겟(171-172) 뒤에 신규:
  ```makefile
  audit-orphan-pv: ## [ops][live] 고아 Released PV 감사(PVC 삭제+Retain hostPath 누수 나열, 파괴 없음)
  	@KUBECONFIG=$(KUBECONFIG_LIVE) bash scripts/audit-orphan-pv.sh
  ```
- **검증**: `make help | grep audit-orphan-pv`(1건) + `grep -n 'audit-orphan-pv' Makefile`. (라이브 실행은 KUBECONFIG 전제 — 스크립트 자체가 cluster-info fail-closed exit 3.) **B12 조정**: B12 check-doc-index가 audit-orphan-pv.sh를 scripts/README에 등재하므로 그 항목 서술에 `make audit-orphan-pv` 호출 경로 표기(중복 방지 — 타겟만 여기서 추가).
- **커밋**: `git add Makefile` → `feat(make): audit-orphan-pv 라이브 감사 ops 타겟 노출(고아 Released PV hostPath 누수 나열)`

### B13.16 ⑰ sops-guard↔verify-secrets recipient 추출 일원화 [PR-13c]
**Files:** Create: `scripts/lib/sops-recipients.sh`; Modify: `scripts/sops-guard.sh:16-19,40`, `scripts/verify-secrets.sh:14-16,29`. **근거**: 두 스크립트가 (a).sops.yaml 경로 해석, (b)`yq '._recipients[]' | sort`(canonical), (c)`yq '.sops.age[].recipient' | sort`(파일)를 **바이트 동형 중복** — 한쪽 하드닝 시 드리프트 위험(DR 복호 불능 가드가 갈라짐). §1.3의 "합치면 회귀" 경고는 provision-db/seal-secret 대상이지 이 boilerplate 아님.
- **Step 1** — 신규 source 전용 lib(shellcheck: `# shellcheck shell=bash`):
  ```bash
  # SOPS recipient 추출 SSOT — sops-guard.sh·verify-secrets.sh 공유(canonical↔파일 recipient 신원 검증 일원화).
  # source 전용(top-level 실행 없음). yq만 필요(age 키 불요).
  sops_yaml_path() {
    local p; p="$(git rev-parse --show-toplevel 2>/dev/null)/.sops.yaml"
    [ -f "$p" ] || p=".sops.yaml"; printf '%s' "$p"
  }
  sops_canonical_recipients() { yq '._recipients[]' "$(sops_yaml_path)" 2>/dev/null | sort; }
  sops_file_recipients() { yq '.sops.age[].recipient' "$1" 2>/dev/null | sort; }
  ```
- **Step 2** — sops-guard.sh: 16-19를 `# shellcheck source=scripts/lib/sops-recipients.sh` + `. "$(dirname "$0")/lib/sops-recipients.sh"` + `CANON="$(sops_canonical_recipients)"`로, 40행 `got="$(yq '.sops.age[].recipient' "$f" ... | sort)"`를 `got="$(sops_file_recipients "$f")"`로 교체. verify-secrets.sh: 14-16·29 동일 교체(경로는 `$(dirname "$0")/lib/...`).
- **게이트**: `make ci`(102행 sops-guard가 실 enc.yaml·.sops.yaml에서 CANON 경로 실행 → 일원화 검증) + `make verify-secrets`(owner-local, age) + `shellcheck $(git ls-files '*.sh')`(신규 lib source 지시자 clean). (test_sops-guard.bats는 .ci-exclude — owner-local 재확인.)
- **커밋**: `git add scripts/lib/sops-recipients.sh scripts/sops-guard.sh scripts/verify-secrets.sh` → `refactor(scripts): SOPS recipient 추출을 sops-recipients.sh lib로 일원화(sops-guard·verify-secrets 중복 제거·드리프트 차단)`

### B13.17 ⑲ verify-secrets recipient 서술 stale 교정 [PR-13c]
**Files:** Modify: `scripts/README.md:23-24`, `Makefile:60`. **근거**: 코드는 recipient **identity(canonical cluster+recovery 집합 일치)** 검사(verify-secrets.sh:12-13,29-31)인데 문서는 "recipient 정확히 2개"/"recipient 2개"(count) — 하드닝(count→identity) 미반영 서술 stale. 미등재 항목(scripts 11·tools 3)은 B12 소관이라 여기선 서술만.
- **Step 1** — scripts/README:23 `... + age recipient 정확히 2개 + 복호 가능)` → `... + age recipient 신원이 canonical(.sops.yaml cluster+recovery)과 일치 + 복호 가능)`.
- **Step 2** — Makefile:60 help `(암호화 + recipient 2개 + 복호가능)` → `(암호화 + recipient 신원 canonical 일치 + 복호가능)`.
- **검증**: `grep -rn 'recipient.*2개\|정확히 2' scripts/README.md Makefile`(0건) + `make help | grep verify-secrets`(신 서술) + `make verify`(check-skeleton·문서 무결성 무회귀).
- **커밋**: `git add scripts/README.md Makefile` → `docs(secrets): verify-secrets 서술 stale 교정(recipient 개수→canonical 신원 일치, 코드와 정합)`

---

### B13.D1 ⑦ ghcr-pull 상호참조 — 처분: 제외(B8 흡수)
**판단**: B8(Wave 2, §178-188)이 "seal 도구 테이블 기반 단일화 + **GHCR_PULL_TOKEN 회전 단일 타겟(prod+files 두 봉인본 동시)**"를 제공한다. 실측상 `seal-ghcr-pull.sh`(prod NS)와 `seal-files-secrets.sh`(files NS)가 동일 `GHCR_PULL_TOKEN`을 각각 봉인해, 토큰 회전 시 한쪽만 재봉인하면 files NS가 stale 토큰으로 pull하는 갭이 상호참조 주석의 원 동기다. B8이 두 봉인본을 한 타겟으로 회전시키면 이 갭이 **구조적으로 소멸** → 상호참조 주석 불요. **⑦ = 제외(B8 흡수)**. **Fallback(B8이 ghcr-pull 단일화를 descope할 경우에만)**: seal-ghcr-pull.sh·seal-files-secrets.sh 각 헤더에 "GHCR_PULL_TOKEN 회전 시 **양쪽 재실행 필수**(prod NS ↔ files NS 동일 토큰)" 1줄 상호참조 추가 + Makefile 두 타겟 help에 교차 표기. 이 fallback은 B8 머지 후 실산출물 실측으로 발동 여부 결정.

### B13.D2 ⑱ ~/workspace/example-api 고아 체크아웃 — 처분: owner-local 절차(코드 없음)
**근거**: §1.3 확인 — 레포 내부 청정(tombstone 의도적 증적), 원격 레포·GHCR 완전 소거, **로컬 `~/workspace/example-api` 체크아웃만 고아**(실측: 디렉토리 존재, `.app-config.yml` 등 잔존). 이 레포 밖 owner 머신 자산이라 PR·커밋 대상 아님 — **owner 확인 후 삭제하는 절차만 기록**.
- **owner-local 절차**(런북/구두 — 커밋 없음): ① `git -C ~/workspace/example-api status --porcelain`(미커밋 변경 0 확인) + `git -C ~/workspace/example-api log --branches --not --remotes`(미푸시 커밋 0 확인) → ② 원격 부재 확인(`git -C ~/workspace/example-api remote -v`; teardown으로 삭제됐으면 fetch 실패) → ③ 둘 다 clean이면 `rm -rf ~/workspace/example-api`. ④ 미커밋/미푸시 잔존 시 owner 판단(보존 or 폐기). **검증**: `[ -d ~/workspace/example-api ] && echo REMAINS || echo CLEARED`.

---

### 게이트·라이브 검증 (배치 종료 기준)

- **정적 게이트(전 PR 필수)**: `make ci` → 기대 `check-skeleton OK`·`run-bats`(신규 test_files_render·db-url/cache-url 라이브·argocd #224·app.validate·app-config 키워드 가드 전부 수집·PASS)·`shellcheck`(신규 lib·인자화 스크립트 clean)·`check-resource-limits OK`·`typecheck` 무오류·sops-guard(recipient 일원화 경로) 통과. `make chart-test` → 3 kind 렌더 + 신규 route/schema/deployment bats PASS.
- **tf 검증(PR-13c ⑬)**: `make tf-validate` → `cloudflare: validated`·`tailscale: validated`·`github: validated`(terraform 필요 — owner-local/CI iac.yaml advisory).
- **라이브(owner-local, `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`)**: ⑯ `make audit-orphan-pv` → `고아 없음(쿼리 성공, Released 0건)` 또는 나열(파괴 없음). ⑮ netpol-rehearsal은 candidate 변경 있을 때만(무변경이면 비실행). files 렌더는 정적이라 라이브 무영향(신규 PV/변이 0 — 전 항목 라이브 리스크 없음).
- **누적 회귀 확인**: `make verify` + `bats tools/tests/ infra/k3s-bootstrap/tests/` → 신규 가드 포함 전건 PASS, check-bats-accounting가 신규 bats의 단일 도메인 배정 확인.

### 롤백 노트
- 전 항목 **additive/무-라이브-변이**(테스트·주석·스키마 락·미사용 제거·make 타겟) → PR revert로 완전 롤백, 라이브 재싱크 불요.
- ② app.validate 규칙: 렌더 게이트만 강화(기존 앱 page/trip-mate-api·fixtures 실측 무회귀). 예기치 못한 소비자 fail 시 _helpers.tpl 규칙 블록만 revert.
- ⑬ internal_suffix 제거: owner-local tfvars 잔존 줄이 undeclared-var **경고**(비치명) — 롤백은 변수 재선언(4파일 revert). ⑭ k3s 플래그: 다음 VM bringup에만 영향(라이브 노드 무변경) — revert로 원복.
- ⑰ recipient lib: 산출 recipient 신원 검증 로직 불변(추출만 이동) — 신구 동작 diff 0이 정상. 이상 시 인라인 복귀.

### 다음 배치 진행 조건
- B13은 캠페인의 **말미 청소** — 후속 배치 없음. 완료 기준: (1) PR-13a/13b/13c 3PR 직렬 머지 + 각 `gate` PASS, (2) ⑦=제외(B8 실산출물 확인), ⑱=owner-local 처분 완료 기록, (3) 라이브 `make audit-orphan-pv` 1회 실행으로 신규 ops 타겟 동작 확인.
- **선행 의존 재확인**(머지 순서): B3(assertion-lint) → B13.4 조건 처분 확정, B8(seal 단일화) → B13.D1 ⑦ 제외 확정, B12(check-doc-index) → B13.15/B13.17 README 중복 회피. 세 선행이 미머지면 해당 항목만 보류하고 나머지 진행.
---

## Adversarial review dispositions (Phase C 감사 추적)

codex 3-pass working-tree 리뷰(2026-07-02). 최종 pass 3 verdict = `needs-attention`
(summary: "No-ship: the plan would fail its own B6 gate in B11, and two proposed safety checks
can pass while blind.") — 3-pass 캡 도달 후 해당 3건을 전건 수용·반영, **미수용 high/critical 0**
상태로 owner가 미해결 목록 확인 후 확정을 승인했다. 기각된 발견 0.

| pass | 발견 | 판정 → 반영 |
|---|---|---|
| 1 | [critical] 백업이 빈 소스를 유일 오프-SSD 사본에 미러(`rsync --delete` 단일 목적지) | 수용 — B5.4를 스테이징→sanity(0파일 중단·>50% 급감 가드+FORCE_SHRINK)→승격(rotate) 모델로, `data.prev` 1개 보존, 성공 메트릭은 승격 후에만 push. 가드 테스트 3종 추가 |
| 1 | [high] B8 시크릿 유출 가드가 스스로 금지한 중간 `! grep` 패턴(false-green) | 수용 — `grep -c` 카운트 패턴으로 전환(B13.9 동류 1건 포함 스윕) |
| 1 | [medium] deploy-trigger preflight가 APP_ID만 검사 — 부분 설정이 빌드 후 실패 | 수용 — ID+KEY 쌍 검증(둘 다 無=clean skip / 하나만=설정 오류 fail / 둘 다 有=진행) |
| 2 | [high] actions:write 디스패치 자격은 전 workflow_dispatch 트리거 가능 — 가드가 변이 5개뿐 | 수용(확장) — actor 가드를 dispatch 진입점 **전수**로(허용목록=bump-poll 단독), 동적 열거 bats로 신규 워크플로 자동 편입 |
| 2 | [medium] B9 bump 경로가 digest-exporter APPS 미갱신 → ImageDigestDrift 거짓 드리프트 | 수용 — bump-tag.ts가 APPS 태그를 같은 커밋에서 동기(항목 부재=no-op), 회귀 테스트 2종 |
| 2 | [medium] B10이 B7이 삭제하는 `scripts/ledger-to-json.sh`를 호출 | 수용 — `bun tools/ledger-to-json.ts`로 전량 스윕(B12 README 서술 포함) |
| 3 | [high] 신설 contract-drift.yaml에 actor 가드 누락 — B6 자기 게이트 위반 | 수용 — 이벤트 한정(`workflow_dispatch`) 가드 스텝 삽입 |
| 3 | [medium] contract-drift fetch 실패가 무알림(blind pass) | 수용 — notify 조건에 `errors != '0'` + 메시지에 실패 건수 표기 |
| 3 | [medium] 런북 백업 `--verify`가 파일명 셋만 비교 — 내용 변경 미감지 | 수용 — `runbooks.sha256`(path+sha256) 매니페스트 동봉·내용 대조로 전환 |

설계 단계 리뷰(Phase A.5, `--kind design` 1-pass, high 3건 전건 수용)의 dispositions는
설계 문서 `2026-07-02-arch-refactor-campaign-design.md` §8에 별도 기록.

## Execution directives

- **Skill:** implement via `executing-plans` in a **separate session, in this worktree**
  (`/Users/ukyi/workspace/homelab/.claude/worktrees/refactor-campaign-2026-07`).
- **Run continuously:** do NOT stop between batches for routine review. Stop ONLY on a genuine
  blocker — missing dependency, a verification that keeps failing, an unclear/contradictory
  instruction, a critical plan gap, or the plan's own **owner-local 지점**(라이브 SC 마이그레이션,
  launchd 배선, 시크릿 재봉인, 앱 레포 시크릿·App 설치, B10 라이브 모니터링 판정) — there,
  guide the owner and wait. Otherwise proceed through every batch to completion.
- **Gate per PR:** `make ci` green 필수(bun 1.3.14 — `export PATH="$HOME/.local/share/mise/installs/bun/1.3.14/bin:$PATH"`),
  배치별 "게이트·라이브 검증" 절차 완료 후 다음 배치. 라이브는 `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`.
- **Commits — apply these rules directly; do NOT invoke `Skill(commit)`** (its interactive
  confirmation would break continuous execution):
  - **Language:** commit message in **Korean**. **No AI markers** — never include
    `🤖 Generated with`, `Co-Authored-By: Claude`, or similar.
  - **Format:** `<type>(<scope>): 한국어 설명` (optional `- 상세` body lines below).
  - **Type — use ONLY these:** `feat` (새 기능), `fix` (버그 수정), `refactor` (리팩토링/성능),
    `docs` (문서), `style` (포맷팅), `test` (테스트), `chore` (빌드/설정). Do **not** use `perf`/`build`/`ci`/etc.
  - **Grouping (priority order):** ① same feature/module dir together; ② separate by purpose
    (refactor vs fix vs feature); ③ files that import/reference each other go together; ④ split by
    change type — config (`package.json`/`tsconfig`…), tests, docs, and standalone style/CSS each
    as their **own** commit.
  - **Judgment:** same dir + same purpose → one commit; a change meaningless without another file →
    same commit; an independently explainable change → its own commit.
  - **Where:** commit at each plan `Commit` step, directly on the current feature-branch worktree
    (you are already off `main`, so no new branch for the campaign itself — 배치 브랜치
    `refactor/b<N>-<slug>`는 이 워크트리 안에서 생성).
