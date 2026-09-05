#!/usr/bin/env bats
# apps/<name>/deploy/prod 배포 계약 가드 — 필수 4산출물(values.yaml·.bindings.json·source-repo·
# kustomization.yaml) + source-repo 발견 계약 + **봉인 배선 all-or-none 불변식**(sealed-wiring #01).
# 인레포 배포앱 0개라 양성/음성 fixture로 체커를 검증. bash 3.2: 중간 단언은 [ ]만(check-bats-style).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CHECK="$ROOT/scripts/check-app-deploy.sh"
  # 비공허 바닥값 — 이 파일의 음성 fixture는 전부 `run bash "$CHECK"` + 비-0이라, 체커가 리네임되면
  # bash가 127로 죽고 **전부 초록**이 된다(rc가 체커 규약이라 `-eq 1` 전환은 대상이 아니다 —
  # 실재 단언만이 닫는 수단이다). cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  [ -f "$CHECK" ]
}

# 봉인본 원본 바이트 sha256 앞 16자 — 게이트 재산출 규약(create-app/update-secrets와 동일)
sha16() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-16; else sha256sum "$1" | cut -c1-16; fi; }

# 봉인 배선 상태 fixture — S·E·K·C_present 4비트를 받아 apps/<app>/deploy/prod 레이아웃을 조립한다.
#   S=봉인본 존재 · E=envFrom에 <app>-secrets · K=kustomization.resources에 봉인본 · C=checksum/secrets annotation
# 필수 4산출물은 항상 존재(필수-산출물 검사와 배선 불변식을 분리). C=1 & S=1이면 checksum을 **일치**시켜
# 불변식 ②(S→C_match)가 ①의 진리표를 오염시키지 않게 한다(S=0이면 ②는 vacuous라 더미 hex 허용).
build_state() {
  s="$1"; e="$2"; k="$3"; c="$4"; d="$5"; app="myapp"
  mkdir -p "$d"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/$app" > "$d/source-repo"
  if [ "$s" -eq 1 ]; then
    printf 'kind: SealedSecret\nmetadata:\n  name: %s-secrets\n  namespace: prod\nspec:\n  encryptedData:\n    FOO: AgABC\n' "$app" > "$d/$app-secrets.sealed.yaml"
  fi
  if [ "$k" -eq 1 ]; then
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources:\n  - %s-secrets.sealed.yaml\n' "$app" > "$d/kustomization.yaml"
  else
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources: []\n' > "$d/kustomization.yaml"
  fi
  {
    echo "image: {}"
    if [ "$e" -eq 1 ]; then
      printf 'envFrom:\n  - secretRef:\n      name: %s-secrets\n' "$app"
    fi
    if [ "$c" -eq 1 ]; then
      if [ "$s" -eq 1 ]; then csum="$(sha16 "$d/$app-secrets.sealed.yaml")"; else csum="deadbeefdeadbeef"; fi
      printf 'podAnnotations:\n  checksum/secrets: %s\n' "$csum"
    fi
  } > "$d/values.yaml"
}

# ── 필수-산출물 계약(배선 불변식과 직교) ──────────────────────────────────────────────

@test "check-app-deploy passes on the real tree (in-repo deploy apps satisfy contract)" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "negative fixture: missing source-repo fails (poll-ghcr would never discover the app)" {
  d="$BATS_TEST_TMPDIR/bad/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  echo "resources: []" > "$d/kustomization.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'source-repo'
}

@test "negative fixture: empty source-repo fails" {
  d="$BATS_TEST_TMPDIR/empty/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  echo "resources: []" > "$d/kustomization.yaml"
  : > "$d/source-repo"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
}

@test "negative fixture: missing kustomization.yaml fails (appset kustomize render needs it)" {
  d="$BATS_TEST_TMPDIR/nokust/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/myapp" > "$d/source-repo"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'kustomization.yaml'
}

@test "app-deploy .bindings.json contract is autoDeploy-centric (db/redis dropped)" {
  run jq -e '.properties.".bindings.json".description | test("autoDeploy") and (test("db/redis") | not)' \
    "$ROOT/tools/app-deploy-schema.json"
  [ "$status" -eq 0 ]
}

@test "required roster is the 4-artifact deploy contract (schema is SSOT)" {
  # untouched-d-2(5라운드) — .required 배열의 원소 수·멤버십에 증인이 없어, values.yaml·
  # .bindings.json을 로스터에서 빼도(real-tree 레인이 4비트 배선 전부 0으로 접혀) 23/23 초록이었다.
  # 정렬·조인 등식은 추가·삭제 양방향을 한 줄로 잠근다(jq sort는 코드포인트 순 — 로케일 콜레이션
  # 함정 밖, `-e` 미사용이라 yq/jq -e false=exit1 함정도 비껴간다).
  [ "$(jq -r '.required | sort | join(",")' "$ROOT/tools/app-deploy-schema.json")" = ".bindings.json,kustomization.yaml,source-repo,values.yaml" ]
}

@test "poll-ghcr discovers apps by source-repo (contract: missing source-repo = never polled)" {
  # 경로는 app-surface module(appPaths(...).sourceRepo — d4) 경유다 — 그 필드를 검사한 행이 continue로
  # 걸러야 한다(source-repo 부재 = 폴링 대상 아님).
  run grep -nE '\.sourceRepo' "$ROOT/tools/poll-ghcr.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'continue'
}

# ── 봉인 배선 all-or-none 불변식 ① — 16상태 진리표(0000·1111만 PASS, 혼합 14 FAIL) ──────────

@test "wiring invariant: 16-state truth table — only 0000 and 1111 pass" {
  bits=0
  while [ "$bits" -le 15 ]; do
    s=$(( (bits >> 3) & 1 )); e=$(( (bits >> 2) & 1 )); k=$(( (bits >> 1) & 1 )); c=$(( bits & 1 ))
    d="$BATS_TEST_TMPDIR/tt-$bits/myapp/deploy/prod"
    build_state "$s" "$e" "$k" "$c" "$d"
    run bash "$CHECK" "$d"
    sum=$(( s + e + k + c ))
    if [ "$sum" -eq 0 ] || [ "$sum" -eq 4 ]; then
      [ "$status" -eq 0 ] || { echo "상태 S$s E$e K$k C$c 은 PASS여야 함 (status=$status): $output"; return 1; }
    else
      [ "$status" -ne 0 ] || { echo "상태 S$s E$e K$k C$c 은 FAIL여야 함(부분 상태): $output"; return 1; }
    fi
    bits=$(( bits + 1 ))
  done
}

# 대표 혼합 상태 — 진리표 루프가 이미 덮지만 회귀 진단을 위해 이름을 남긴다.

@test "wiring invariant: S=0 E=1 K=0 C=0 fails (design-r3 R-3 counterexample — old biconditional passed this)" {
  d="$BATS_TEST_TMPDIR/r3/myapp/deploy/prod"
  build_state 0 1 0 0 "$d"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '부분 상태'
}

@test "wiring invariant: S=0 E=0 K=1 C=0 fails (dangling resources entry breaks kustomize render)" {
  d="$BATS_TEST_TMPDIR/dangling/myapp/deploy/prod"
  build_state 0 0 1 0 "$d"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '부분 상태'
}

@test "wiring invariant: S=1 E=0 K=1 C=1 fails (sealed present but not consumed via envFrom)" {
  d="$BATS_TEST_TMPDIR/unconsumed/myapp/deploy/prod"
  build_state 1 0 1 1 "$d"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '부분 상태'
}

# ── 불변식 ② — S → C_match (checksum 값 정합, 기존 #277 회귀 보존) ───────────────────────

@test "checksum gate: fully wired app with matching checksum passes (1111)" {
  d="$BATS_TEST_TMPDIR/match/myapp/deploy/prod"
  build_state 1 1 1 1 "$d"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "checksum gate: fully wired app with mismatched checksum fails (re-sealed w/o bumping = #277)" {
  d="$BATS_TEST_TMPDIR/mism/myapp/deploy/prod"
  build_state 1 0 1 0 "$d"
  printf 'image: {}\nenvFrom:\n  - secretRef:\n      name: myapp-secrets\npodAnnotations:\n  checksum/secrets: deadbeefdeadbeef\n' > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '불일치'
}

@test "checksum gate: comment lines above checksum/secrets are tolerated (trip-mate-api layout)" {
  # build_state로 S(봉인본)+K(kustomization)만 스캐폴딩하고 values.yaml은 직접 조립(E·C를 이 테스트가 소유).
  d="$BATS_TEST_TMPDIR/comments/myapp/deploy/prod"
  build_state 1 0 1 0 "$d"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'image: {}\nenvFrom:\n  - secretRef:\n      name: myapp-secrets\npodAnnotations:\n  # 재봉인 주석 1\n  # 재봉인 주석 2\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "E/K axes tolerate quoted YAML values (hand-edited but validly wired app passes)" {
  # 게이트는 손편집 표면을 정찰하므로 name: \"myapp-secrets\" 같은 정당한 따옴표 변형에 false-FAIL하면 안 된다.
  d="$BATS_TEST_TMPDIR/quoted/myapp/deploy/prod"
  build_state 1 0 0 0 "$d"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources:\n  - "myapp-secrets.sealed.yaml"\n' > "$d/kustomization.yaml"
  printf 'image: {}\nenvFrom:\n  - secretRef:\n      name: "myapp-secrets"\npodAnnotations:\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

# ── E 판정 정밀 — envFrom은 공유 리스트(conn 시크릿과 공존) ────────────────────────────

@test "E axis: <app>-secrets among other secretRefs still counts (shared envFrom with conn secret)" {
  d="$BATS_TEST_TMPDIR/shared/myapp/deploy/prod"
  build_state 1 0 1 0 "$d"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'image: {}\nenvFrom:\n  - secretRef:\n      name: myapp-secrets\n  - secretRef:\n      name: db-myapp-conn\npodAnnotations:\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "E axis: merely a conn secretRef (no <app>-secrets) does not satisfy E — sealed present is a partial state" {
  d="$BATS_TEST_TMPDIR/connonly/myapp/deploy/prod"
  build_state 1 0 1 0 "$d"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'image: {}\nenvFrom:\n  - secretRef:\n      name: db-myapp-conn\npodAnnotations:\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '부분 상태'
}

# ── strict scope 강제(sealed-wiring #02, design-r1 R-2) ────────────────────────────────
# 완전 배선(1111) 앱을 조립하되 봉인본 metadata.annotations에 $anno 줄을 넣는다(checksum은 정합) —
# 배선 불변식은 통과시키고 scope 검사만 태우기 위함.
build_wired_with_anno() {
  d="$1"; anno="$2"; app="myapp"; mkdir -p "$d"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/$app" > "$d/source-repo"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources:\n  - %s-secrets.sealed.yaml\n' "$app" > "$d/kustomization.yaml"
  {
    echo "apiVersion: bitnami.com/v1alpha1"
    echo "kind: SealedSecret"
    echo "metadata:"
    printf '  name: %s-secrets\n' "$app"
    echo "  namespace: prod"
    if [ -n "$anno" ]; then
      echo "  annotations:"
      printf '    %s\n' "$anno"
    fi
    printf 'spec:\n  encryptedData:\n    FOO: AgABC\n'
  } > "$d/$app-secrets.sealed.yaml"
  want="$(sha16 "$d/$app-secrets.sealed.yaml")"
  printf 'image: {}\nenvFrom:\n  - secretRef:\n      name: %s-secrets\npodAnnotations:\n  checksum/secrets: %s\n' "$app" "$want" > "$d/values.yaml"
}

@test "scope: cluster-wide annotation is rejected (ciphertext reusable outside the intended Secret)" {
  d="$BATS_TEST_TMPDIR/cw/myapp/deploy/prod"
  build_wired_with_anno "$d" 'sealedsecrets.bitnami.com/cluster-wide: "true"'
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'scope'
}

@test "scope: namespace-wide annotation is rejected (name isolation broken within the namespace)" {
  d="$BATS_TEST_TMPDIR/nw/myapp/deploy/prod"
  build_wired_with_anno "$d" 'sealedsecrets.bitnami.com/namespace-wide: "true"'
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'scope'
}

@test "scope: patch annotation passes (patch mode is not scope — argocd extras precedent)" {
  d="$BATS_TEST_TMPDIR/patch/myapp/deploy/prod"
  build_wired_with_anno "$d" 'sealedsecrets.bitnami.com/patch: "true"'
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "scope: cluster-wide with false value is not scope-widening (strict, passes)" {
  d="$BATS_TEST_TMPDIR/cwf/myapp/deploy/prod"
  build_wired_with_anno "$d" 'sealedsecrets.bitnami.com/cluster-wide: "false"'
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "scope: a trailing YAML comment does not let a scope annotation evade the check" {
  # E/K 축과 동일한 주석 관용 — scope 확대가 손편집 주석 하나로 우회되면 안 된다(fail-open 방지).
  d="$BATS_TEST_TMPDIR/cwcomment/myapp/deploy/prod"
  build_wired_with_anno "$d" 'sealedsecrets.bitnami.com/cluster-wide: "true"  # 손편집 주석'
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'scope'
}

@test "scope: annotation under spec.template.metadata is also caught (not merely top-level metadata)" {
  # kubeseal은 scope 어노테이션을 SealedSecret metadata에 두지만, whole-file 검사라 template 배치도 잡아야 한다.
  d="$BATS_TEST_TMPDIR/tmplscope/myapp/deploy/prod"; app="myapp"; mkdir -p "$d"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/$app" > "$d/source-repo"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources:\n  - %s-secrets.sealed.yaml\n' "$app" > "$d/kustomization.yaml"
  printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: %s-secrets\n  namespace: prod\nspec:\n  encryptedData:\n    FOO: AgABC\n  template:\n    metadata:\n      name: %s-secrets\n      namespace: prod\n      annotations:\n        sealedsecrets.bitnami.com/namespace-wide: "true"\n' "$app" "$app" > "$d/$app-secrets.sealed.yaml"
  want="$(sha16 "$d/$app-secrets.sealed.yaml")"
  printf 'image: {}\nenvFrom:\n  - secretRef:\n      name: %s-secrets\npodAnnotations:\n  checksum/secrets: %s\n' "$app" "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'scope'
}

# ── K/E 경로 앵커(grep-a-3) — 문자열이 파일 어딘가에 있는 것과 그 키 아래에 있는 것은 다르다ㅡ

@test "K axis: the sealed filename under patches: does not satisfy K (resources membership alone counts)" {
  # 예전 줄 정규식은 어느 키 아래인지 안 보고 시퀀스 항목 모양이면 등재로 오인했다 —
  # `resources: []`로 비우고 같은 파일명을 `patches:` 아래 두면 kustomize는 그 자리에서
  # SealedSecret을 안 만든다(K는 여전히 0이어야 한다).
  d="$BATS_TEST_TMPDIR/patched/myapp/deploy/prod"
  build_state 1 1 0 1 "$d"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources: []\npatches:\n  - myapp-secrets.sealed.yaml\n' > "$d/kustomization.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '부분 상태'
}

@test "E axis: a configMapRef typo with the same name does not satisfy E (secretRef key required)" {
  # envFrom 항목이 secretRef가 아니라 configMapRef면 Secret이 아니라 ConfigMap을 참조한다 —
  # 이름이 같아도 배선은 안 된 것이다. 예전 줄 정규식은 `name:` 줄만 봐서 키를 구별 못 했다.
  d="$BATS_TEST_TMPDIR/cmref/myapp/deploy/prod"
  build_state 1 0 1 1 "$d"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'image: {}\nenvFrom:\n  - configMapRef:\n      name: myapp-secrets\npodAnnotations:\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '부분 상태'
}

@test "E axis: a secretRef outside envFrom (e.g. livenessProbe) does not satisfy E (path-anchored, not the whole document)" {
  # reg-a2-ops-guards-1 — 예전 표현식은 `..`(문서 전체 재귀 하강)라 envFrom 경로 밖 아무
  # 자유형 맵(platform/charts/app/values.schema.json의 livenessProbe·strategy.rollingUpdate가
  # additionalProperties 미제한)에 놓인 secretRef.name도 배선 증거로 오인했다. envFrom을 아예
  # 비우고 livenessProbe 아래 같은 이름의 secretRef만 두면 여전히 부분 상태(E=0)여야 한다.
  d="$BATS_TEST_TMPDIR/nonenvfrom/myapp/deploy/prod"
  build_state 1 0 1 1 "$d"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'image: {}\nlivenessProbe:\n  secretRef:\n    name: myapp-secrets\npodAnnotations:\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '부분 상태'
}

@test "filename convention: a non-<app>-secrets *.sealed.yaml in the deploy dir is rejected" {
  d="$BATS_TEST_TMPDIR/rogue/myapp/deploy/prod"
  build_state 1 1 1 1 "$d"
  echo "kind: SealedSecret" > "$d/rogue.sealed.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '규약 외'
}
