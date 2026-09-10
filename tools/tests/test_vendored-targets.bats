#!/usr/bin/env bats
# 동봉 계약(tools/vendored-contract.json) target 행의 **앱 축** 편집 커널 단위.
# create-app(추가)·teardown-app(제거)이 이 커널을 공유한다 — 종전에는 앱 온보딩(#691)·철거(#698)
# 때마다 사람이 이 파일에 행 2개를 손으로 넣고 뺐고, 빠뜨리면 contract-drift의 로스터 등식이
# missing-target/stale-target으로 gate를 red로 만들어서야 알았다(비용 = gate 1사이클 ≈11분).
# 이 파일이 잠그는 것 = **앱 행 문법 전부**: 행 위치(source별 targets 말미) · path 유도
# (`tools/<source basename>` — 기존 행의 뒷받침 필수 · 항목 간 유일) · ref(`main`) · normalize 상속
# (같은 source의 기존 행) · 직렬화(2칸 들여쓰기 + 말미 개행) · 멱등 · 드리프트 복구 · 대칭(add∘remove = 항등).
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
  # 이 레인의 정확 문자열 대조가 `ref: "main"` 상수 가정도 함께 잠근다 — 매니페스트에 브랜치를
  # 고를 축이 없다는 커널 헤더의 주장이 여기서만 증인을 갖는다(다른 ref면 이 grep이 빗나간다).
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

@test "parse rejects a target row missing repo, ref or path (the Target type had no runtime witness)" {
  # `parse`는 owner/source/targets 형상만 봤고 target **원소**는 안 봤다 — `Target` 타입이 런타임
  # 증인 없이 참을 주장하던 자리다. 세 키를 하나씩 지워 전부 거부되는지 잰다(한 분기의 세 절).
  run bun -e "
    import { addAppTargets } from '$ROOT/tools/lib/vendored-targets.ts';
    import { readFileSync } from 'node:fs';
    const orig = readFileSync('$M','utf8');
    for (const k of ['repo','ref','path']) {
      const mf = JSON.parse(orig);
      delete mf.vendored[0].targets[0][k];
      let threw = '';
      try { addAppTargets(JSON.stringify(mf, null, 2) + '\n', 'orders'); } catch (e) { threw = String(e); }
      if (threw.indexOf('repo/ref/path') < 0) { console.error('키 ' + k + ' 부재가 통과했다: ' + threw); process.exit(1); }
    }
    console.log('shape-locked');
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'shape-locked'
  # 양성 대조 — 손대지 않은 같은 매니페스트는 통과한다(거부가 상수가 아니다).
  run run_lib "t = addAppTargets(t,'orders');"
  [ "$status" -eq 0 ]
}

@test "parse rejects a normalize outside typescript|exact, an absent key included (no silent loosening)" {
  # 🔴 적대 검토 실측: 상속(rowFor)이 값 집합의 **크기**만 재서 `[undefined]`(키 부재)도
  #    `["Exact"]`(오타)도 길이 1로 통과했다. 그렇게 만든 앱 행을 소비자(contract-drift-check의
  #    normalize())는 `mode === "exact"`가 아니라는 이유로 **typescript(느슨한 쪽)** 로 접는다 —
  #    cert 사본의 바이트 위변조가 원본과 같다고 읽히는 방향이다.
  run run_lib "
    const mf = JSON.parse(t);
    delete mf.vendored[1].targets[0].normalize;
    t = JSON.stringify(mf, null, 2) + '\n';
    appTargetRows(t,'orders');
  "
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'tools/sealed-secrets-cert.pem'
  printf '%s\n' "$output" | grep -qF 'normalize'
  # 열거 밖 값도 같은 축이다 — 상속은 값을 복사할 뿐 검사하지 않았다.
  run run_lib "
    const mf = JSON.parse(t);
    mf.vendored[1].targets[0].normalize = 'Exact';
    t = JSON.stringify(mf, null, 2) + '\n';
    t = addAppTargets(t,'orders');
  "
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'Exact'
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

@test "rowFor refuses a source whose derived app path no existing row corroborates" {
  # 🔴 적대 검토 실측: path는 `tools/<basename(source)>`를 **무조건** 유도했고 검증이 0이었다
  #    (형제 축 normalize는 유도 불가면 throw인데). 잘못 유도한 행은 라이브 fetch에서 404가 되고
  #    classifyStatus가 그것을 absent-or-private로 접어 **drift로 승격하지 않는다** — 로스터 등식은
  #    repo 이름만 보므로 그 행은 영원히 감시 밖이다(발견이 아니라 침묵이 된다).
  run run_lib "
    const mf = JSON.parse(t);
    mf.vendored.push({ source: 'docs/policy.md', targets: [ { repo: 'homelab-app-template', ref: 'main', path: 'scaffold/common/docs/policy.md', normalize: 'typescript' } ] });
    t = JSON.stringify(mf, null, 2) + '\n';
    t = addAppTargets(t,'orders');
  "
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'docs/policy.md'
  printf '%s\n' "$output" | grep -qF 'tools/policy.md'
  # 양성 대조 — tools/ 아래 source는 앵커 행이 유도를 뒷받침하므로 그대로 통과한다(거부가 상수가 아니다).
  run run_lib "
    const mf = JSON.parse(t);
    mf.vendored.push({ source: 'tools/third-file.ts', targets: [ { repo: 'homelab-app-template', ref: 'main', path: 'scaffold/common/tools/third-file.ts', normalize: 'typescript' } ] });
    t = JSON.stringify(mf, null, 2) + '\n';
    t = addAppTargets(t,'orders');
  "
  [ "$status" -eq 0 ]
  [ "$(rows_for orders)" = "3" ]
}

@test "parse refuses two sources whose app rows would collide on one path (basename is the derivation)" {
  # 유도가 basename이므로 서로 다른 source 둘이 같은 파일명이면 앱 레포에서 **한 경로**를 다툰다 —
  # 두 항목이 같은 사본을 감시하고 어느 쪽도 red가 아니다(둘 다 fetch에 성공한다).
  # 부재 판정(hasAppTargets)으로 호출한다: 이 거부가 편집 함수가 아니라 **parse**에 산다는 것 —
  # 즉 커널의 모든 진입점이 같은 문법을 지난다는 것 — 을 같은 레인에서 확인한다.
  run run_lib "
    const mf = JSON.parse(t);
    mf.vendored.push({ source: 'other/tools/seal-secret.mts', targets: [ { repo: 'homelab-app-template', ref: 'main', path: 'scaffold/common/other/tools/seal-secret.mts', normalize: 'typescript' } ] });
    t = JSON.stringify(mf, null, 2) + '\n';
    console.error(hasAppTargets(t,'orders'));
  "
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'tools/seal-secret.mts'
}

@test "addAppTargets repairs an existing app row that drifted from the derivation (plan == diff)" {
  # 🔴 적대 검토 실측: 멱등 skip이 행의 **존재**만 봐서 어긋난 기존 앱 행을 그대로 뒀다. 그때
  #    `appTargetRows`(create-app plan → PR 본문 JSON)는 정본 행을 예고하는데 파일은 다른 행을
  #    갖는다 — 승인자가 읽는 계획과 diff가 갈린다. 로스터 등식은 repo 이름만 보므로 침묵하고
  #    내용 diff는 404 → absent-or-private로 접힌다. "도구가 쓴다"는 계약이면 도구가 정본을 쥔다.
  run run_lib "
    const mf = JSON.parse(t);
    mf.vendored[1].targets.push({ repo: 'orders', ref: 'main', path: 'scaffold/common/tools/sealed-secrets-cert.pem', normalize: 'exact' });
    t = JSON.stringify(mf, null, 2) + '\n';
    const before = t;
    t = addAppTargets(t,'orders');
    if (t === before) { console.error('드리프트한 앱 행이 그대로다 — 계획과 diff가 갈린다'); process.exit(1); }
  "
  [ "$status" -eq 0 ]
  # 교체지 추가가 아니다 — 앱 행 수는 source 수 그대로다.
  [ "$(rows_for orders)" = "2" ]
  [ "$(printf '%s\n' "$output" | grep -c '"path": "tools/sealed-secrets-cert.pem"' || true)" = "1" ]
  # 앵커 행은 같은 path를 그대로 유지한다(복구는 앱 축만 만진다).
  [ "$(printf '%s\n' "$output" | grep -c '"path": "scaffold/common/tools/sealed-secrets-cert.pem"' || true)" = "1" ]
}
