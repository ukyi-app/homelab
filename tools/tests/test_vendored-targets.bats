#!/usr/bin/env bats
# 동봉 계약(tools/vendored-contract.json) target 행의 **앱 축** 편집 커널 단위.
# create-app(추가)·teardown-app(제거)이 이 커널을 공유한다 — 종전에는 앱 온보딩(#691)·철거(#698)
# 때마다 사람이 이 파일에 행 2개를 손으로 넣고 뺐고, 빠뜨리면 contract-drift의 로스터 등식이
# missing-target/stale-target으로 gate를 red로 만들어서야 알았다(비용 = gate 1사이클 ≈11분).
# 이 파일이 잠그는 것 = **앱 행 문법 전부**: 행 위치(source별 targets 말미) · path 유도
# (`tools/<source basename>`) · ref(`main`) · normalize 상속(같은 source의 기존 행) · 직렬화
# (2칸 들여쓰기 + 말미 개행) · 멱등 · 대칭(add∘remove = 항등).
# ⚠️ 중간 단언은 단일 대괄호만(bash 3.2 [[ ]] 침묵 통과) · @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  M="$TMP/manifest.json"
  seed_shipped_shape
}
teardown() { rm -rf "$TMP"; }

# 실 매니페스트와 같은 형상(2칸 들여쓰기 · _note/_roster · scaffoldRepos · vendored 2건).
# 실 파일을 복사하지 않는 이유: 픽스처가 SSOT의 산문 변경에 묶이면 안 되고, 아래 대칭 레인이
# **실 파일 자체**를 따로 판다(픽스처 형상과 실 형상의 등식은 그 레인이 진다).
seed_shipped_shape() {
  cat > "$M" <<'JSON'
{
  "_note": "동봉 계약 SSOT(픽스처)",
  "_roster": "로스터 주석(픽스처)",
  "owner": "ukyi-app",
  "scaffoldRepos": [
    "homelab-app-template"
  ],
  "vendored": [
    {
      "source": "tools/seal-secret.mts",
      "targets": [
        {
          "repo": "homelab-app-template",
          "ref": "main",
          "path": "scaffold/common/tools/seal-secret.mts",
          "normalize": "typescript"
        }
      ]
    },
    {
      "source": "tools/sealed-secrets-cert.pem",
      "targets": [
        {
          "repo": "homelab-app-template",
          "ref": "main",
          "path": "scaffold/common/tools/sealed-secrets-cert.pem",
          "normalize": "exact"
        }
      ]
    }
  ]
}
JSON
}

# $1 = 커널 호출 본문. `t`가 매니페스트 텍스트, 마지막에 stdout으로 흘린다(digest-exporter lib 테스트와 같은 관용구).
run_lib() { bun -e "
  import { addAppTargets, removeAppTargets, hasAppTargets, appTargetRows } from '$ROOT/tools/lib/vendored-targets.ts';
  import { readFileSync } from 'node:fs';
  let t = readFileSync('$M','utf8');
  $1
  process.stdout.write(t);
"; }
# 행 수 세기 — `[ "$(...)" = "n" ]` 형태(부재도 0이라는 값으로 읽는다).
rows_for() { printf '%s\n' "$output" | grep -c "\"repo\": \"$1\"" || true; }

@test "addAppTargets appends exactly one row per vendored source, idempotently" {
  run run_lib "t = addAppTargets(t,'orders'); t = addAppTargets(t,'orders');"
  [ "$status" -eq 0 ]
  # 상한 등식 — source 2건이므로 앱 행도 정확히 2개다(두 번 불러도 늘지 않는다).
  [ "$(rows_for orders)" = "2" ]
  [ "$(rows_for homelab-app-template)" = "2" ]
  # path는 source의 파일명에서 유도된다(앱 레포 사본은 tools/ 하나에 산다).
  [ "$(printf '%s\n' "$output" | grep -c '"path": "tools/seal-secret.mts"' || true)" = "1" ]
  [ "$(printf '%s\n' "$output" | grep -c '"path": "tools/sealed-secrets-cert.pem"' || true)" = "1" ]
}

@test "the appended rows serialize byte-exactly like the hand-written rows they replace" {
  # 종전 손 편집(PR #691의 diff)이 낸 바이트와 같아야 한다 — 커널이 파일을 재포맷하면
  # 앱 생성 PR마다 무관한 diff가 실린다.
  run run_lib "t = addAppTargets(t,'orders');"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP/got.json"
  cat > "$TMP/want.json" <<'JSON'
{
  "_note": "동봉 계약 SSOT(픽스처)",
  "_roster": "로스터 주석(픽스처)",
  "owner": "ukyi-app",
  "scaffoldRepos": [
    "homelab-app-template"
  ],
  "vendored": [
    {
      "source": "tools/seal-secret.mts",
      "targets": [
        {
          "repo": "homelab-app-template",
          "ref": "main",
          "path": "scaffold/common/tools/seal-secret.mts",
          "normalize": "typescript"
        },
        {
          "repo": "orders",
          "ref": "main",
          "path": "tools/seal-secret.mts",
          "normalize": "typescript"
        }
      ]
    },
    {
      "source": "tools/sealed-secrets-cert.pem",
      "targets": [
        {
          "repo": "homelab-app-template",
          "ref": "main",
          "path": "scaffold/common/tools/sealed-secrets-cert.pem",
          "normalize": "exact"
        },
        {
          "repo": "orders",
          "ref": "main",
          "path": "tools/sealed-secrets-cert.pem",
          "normalize": "exact"
        }
      ]
    }
  ]
}
JSON
  diff -u "$TMP/want.json" "$TMP/got.json"
}

@test "removeAppTargets drops that app's rows idempotently and leaves the other repos alone" {
  run run_lib "t = addAppTargets(t,'orders'); t = addAppTargets(t,'billing'); t = removeAppTargets(t,'orders'); t = removeAppTargets(t,'orders');"
  [ "$status" -eq 0 ]
  [ "$(rows_for orders)" = "0" ]
  [ "$(rows_for billing)" = "2" ]
  [ "$(rows_for homelab-app-template)" = "2" ]
}

@test "add then remove returns the shipped manifest byte-identical (create/teardown symmetry)" {
  # 앱-외부 표면의 대칭은 app-surface처럼 디렉토리 통째 rm이 아니다 — 커널의 역함수성이 유일한
  # 구조적 보증이고, 실 SSOT 파일 위에서 재야 픽스처 형상과 실 형상의 드리프트도 함께 잡힌다.
  run bun -e "
    import { addAppTargets, removeAppTargets } from '$ROOT/tools/lib/vendored-targets.ts';
    import { readFileSync } from 'node:fs';
    const orig = readFileSync('$ROOT/tools/vendored-contract.json','utf8');
    const back = removeAppTargets(addAppTargets(orig,'orders'), 'orders');
    if (back !== orig) { console.error('대칭 깨짐'); process.exit(1); }
    if (addAppTargets(orig,'orders') === orig) { console.error('추가가 무변경 — 대칭이 항진이다'); process.exit(1); }
    console.log('symmetric');
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'symmetric'
}

@test "a third vendored source grows the app row set with it (rows are derived, not a literal pair)" {
  run run_lib "
    const mf = JSON.parse(t);
    mf.vendored.push({ source: 'tools/third-file.ts', targets: [ { repo: 'homelab-app-template', ref: 'main', path: 'scaffold/common/tools/third-file.ts', normalize: 'typescript' } ] });
    t = JSON.stringify(mf, null, 2) + '\n';
    t = addAppTargets(t,'orders');
  "
  [ "$status" -eq 0 ]
  [ "$(rows_for orders)" = "3" ]
  [ "$(printf '%s\n' "$output" | grep -c '"path": "tools/third-file.ts"' || true)" = "1" ]
}

@test "an app row inherits the normalize of its own source, not of a sibling" {
  run run_lib "console.error(JSON.stringify(appTargetRows(t,'orders')));"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF '{"source":"tools/seal-secret.mts","repo":"orders","ref":"main","path":"tools/seal-secret.mts","normalize":"typescript"}'
  printf '%s\n' "$output" | grep -qF '{"source":"tools/sealed-secrets-cert.pem","repo":"orders","ref":"main","path":"tools/sealed-secrets-cert.pem","normalize":"exact"}'
}

@test "appTargetRows is a pure projection — it announces the write without doing it" {
  before="$(cat "$M")"
  run run_lib "appTargetRows(t,'orders');"
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$before" ]
}

@test "hasAppTargets separates absence (false) from format drift (throw)" {
  run run_lib "console.error([hasAppTargets(t,'orders'), hasAppTargets(addAppTargets(t,'orders'),'orders'), hasAppTargets(t,'order')].join(','));"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'false,true,false'
  echo '{"owner":"ukyi-app"}' > "$M"
  run run_lib "console.error(hasAppTargets(t,'orders'));"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'vendored'
}

@test "the kernel throws fail-loud on a manifest it cannot edit (bad JSON, no vendored, empty vendored)" {
  printf 'not json' > "$M"
  run run_lib "t = addAppTargets(t,'orders');"
  [ "$status" -ne 0 ]
  echo '{"owner":"ukyi-app","vendored":[]}' > "$M"
  run run_lib "t = addAppTargets(t,'orders');"
  [ "$status" -ne 0 ]
  # 0건은 "추가할 것이 없다"가 아니라 열거 붕괴다 — 조용한 no-op이면 다음 리컨실이 missing-target을 낸다.
  printf '%s\n' "$output" | grep -qF '0건'
}

@test "addAppTargets refuses a source whose normalize cannot be derived from an existing row" {
  run run_lib "
    const mf = JSON.parse(t);
    mf.vendored[0].targets = [];
    t = JSON.stringify(mf, null, 2) + '\n';
    t = addAppTargets(t,'orders');
  "
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'normalize'
}

@test "removeAppTargets refuses to empty a source's target list (the anchor row is not an app row)" {
  # 템플릿 행까지 지우면 그 source의 벤더 감시가 통째로 꺼지는데 로스터 등식은 여전히 성립한다
  # (앱 축만 보므로) — 조용히 계약이 사라지는 유일한 경로라 여기서 fail-closed로 막는다.
  run run_lib "t = removeAppTargets(t,'homelab-app-template');"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'tools/seal-secret.mts'
}
