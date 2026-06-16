#!/usr/bin/env bash
# sealing-key DR 게이트 (sourceable lib). top-level 실행 없음(source-safe).
# 불변식: SealedSecret 소비자(라이브 ∪ origin/main) 또는 committed cert가 있으면 DR 드릴은
#   파괴 전에 백업·실복원(키쌍)을 증명하고, 재구축 후 전수 unseal + cert 일치를 검증한다.
# fail-closed: 권위 소스(kubectl/git/yq) 조회·파싱 실패 시 0으로 단정하지 않고 ABORT/FAIL
#   (SEALED_DR_ALLOW_OFFLINE=1 명시 오버라이드만 예외). 파서: yq(핀) + kubectl jsonpath(live).
# 최신 백업 선택은 ss-keys.<epoch>.enc.yaml(통제 파일명)을 ls|sort|tail로 고른다 — 비알파뉴메릭
# 위험이 없어 find 대신 ls가 의도된 선택(SC2012 파일 전역 면제).
# shellcheck disable=SC2012
CERT_REL="tools/sealed-secrets-cert.pem"
SS_NS="sealed-secrets"; SS_DEPLOY="deploy/sealed-secrets-controller"
UNSEAL_RETRIES="${SEALED_UNSEAL_RETRIES:-40}"; CTRL_WAIT_RETRIES="${SEALED_CTRL_WAIT_RETRIES:-60}"

assert_dr_tools_present() {
  local missing="" t
  for t in kubectl kubeseal sops openssl yq git; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] || { echo "DR ABORT: DR 경로 필수 도구 부재 →$missing"; return 1; }
}

sealed_consumers_count_local() { git -C "${1:?}" ls-files -- '*.sealed.yaml' 2>/dev/null | grep -c . || true; }

# 백업 List의 서버관리 메타 제거(fresh-cluster create 견고 — P5-3). stdin→stdout.
sanitize_backup_yaml() {
  yq e '(.items[].metadata) |= (del(.uid) | del(.resourceVersion) | del(.creationTimestamp) | del(.managedFields) | del(.ownerReferences) | del(.selfLink) | del(.generation))' -
}

# git ref의 SealedSecret → ns/name(stdout). 파싱 실패는 rc=4(fail-closed), 파일 0은 rc=0.
consumers_from_ref() {
  local repo="$1" ref="${2:-origin/main}" files f doc ns nm rc=0
  files="$(git -C "$repo" ls-tree -r --name-only "$ref" 2>/dev/null)" || return 4  # ref 누락 등
  files="$(printf '%s\n' "$files" | grep '\.sealed\.yaml$' || true)"  # ls-tree pathspec는 *가 /를 안 넘어 접미사 필터(ls-files와 정합)
  [ -n "$files" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    doc="$(git -C "$repo" show "$ref:$f" 2>/dev/null)" || { echo "ref parse 실패(git show): $f" >&2; rc=4; continue; }
    ns="$(printf '%s' "$doc" | yq e '.metadata.namespace' - 2>/dev/null)" || { echo "ref parse 실패(yq ns): $f" >&2; rc=4; continue; }
    nm="$(printf '%s' "$doc" | yq e '.metadata.name' - 2>/dev/null)" || { echo "ref parse 실패(yq name): $f" >&2; rc=4; continue; }
    if [ -z "$ns" ] || [ "$ns" = "null" ] || [ -z "$nm" ] || [ "$nm" = "null" ]; then
      echo "ref parse 실패(메타 null/누락): $f" >&2; rc=4; continue; fi
    printf '%s/%s\n' "$ns" "$nm"
  done <<< "$files"
  return "$rc"
}

# 라이브 SealedSecret → ns/name(stdout). kubectl 실패 시 rc=3.
consumers_from_live() {
  local out
  out="$(kubectl get sealedsecrets.bitnami.com -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || return 3
  printf '%s\n' "$out" | grep -E '.+/.+' || true
}

# 합집합(정렬·중복제거). ref(4)/live(3) 실패를 전파(fail-closed).
merge_consumers() {
  local repo="$1" ref="${2:-origin/main}" ref_list live_list rc_ref=0 rc_live=0
  ref_list="$(consumers_from_ref "$repo" "$ref")" || rc_ref=$?
  live_list="$(consumers_from_live)" || rc_live=$?
  printf '%s\n%s\n' "$ref_list" "$live_list" | grep -E '.+/.+' | sort -u || true
  [ "$rc_ref" -ne 0 ] && return "$rc_ref"; [ "$rc_live" -ne 0 ] && return "$rc_live"; return 0
}

# 파괴 전: 도구 + fail-closed 검출 + (소비자 ≥1 또는 committed cert) 시 --verify + 키쌍 실복원 증명.
assert_recoverable_before_destroy() {
  local repo="$1" backup_dir="${2:-}" ref="${3:-origin/main}"
  assert_dr_tools_present || return 1
  if ! git -C "$repo" fetch -q origin main 2>/dev/null; then
    [ "${SEALED_DR_ALLOW_OFFLINE:-0}" = "1" ] || { echo "DR ABORT: git fetch origin main 실패(fail-closed; SEALED_DR_ALLOW_OFFLINE=1로 오버라이드)"; return 1; }
    echo "    (오프라인 오버라이드: git fetch 생략)"
  fi
  local merged rc=0; merged="$(merge_consumers "$repo" "$ref")" || rc=$?
  if [ "$rc" -ne 0 ] && [ "${SEALED_DR_ALLOW_OFFLINE:-0}" != "1" ]; then
    echo "DR ABORT: 권위 소스 조회/파싱 실패(kubectl 또는 origin/main yq) — fail-closed(소비자 0 단정 안 함)"; return 1; fi
  local n cert=0; n="$(printf '%s' "$merged" | grep -c . || true)"; [ -f "$repo/$CERT_REL" ] && cert=1
  echo "    sealing-key DR 검출(라이브 ∪ $ref): 소비자 $n개, committed_cert=$cert"
  if [ "$n" -eq 0 ] && [ "$cert" -eq 0 ]; then
    echo "    sealing-key DR: dormant (소비자 0 + committed cert 없음)"; return 0; fi
  # 소비자 ≥1 또는 cert 존재 → 파괴 전 키 연속성 증명 강제
  [ -n "$backup_dir" ] || { echo "DR ABORT: 키 연속성 필요(소비자 $n, cert $cert) — export SEALED_KEY_BACKUP_DIR=<git 밖 디렉토리>"; return 1; }
  "$repo/scripts/backup-sealed-secrets-key.sh" --verify "$backup_dir" || { echo "DR ABORT: 백업이 라이브와 불일치/부재"; return 1; }
  prove_backup_restorable "$repo" "$backup_dir" || { echo "DR ABORT: 백업 키쌍 실복원 증명 실패"; return 1; }
  rehearse_restore_on_live "$repo" "$backup_dir" || { echo "DR ABORT: 라이브 canary 복원 리허설 실패"; return 1; }
}

# 비파괴 키쌍 증명: committed cert와 fingerprint 일치 + 그 항목의 tls.crt modulus == tls.key modulus.
prove_backup_restorable() {
  local repo="$1" backup_dir="$2"
  local latest; latest="$(ls -1 "$backup_dir"/ss-keys.*.enc.yaml 2>/dev/null | sort | tail -1)"
  [ -n "$latest" ] || { echo "    실복원 증명: 백업 없음"; return 1; }
  local decrypted; decrypted="$(sops -d --input-type binary --output-type binary "$latest" 2>/dev/null)" \
    || { echo "    실복원 증명: 백업 복호 실패"; return 1; }
  local fp_committed; fp_committed="$(openssl x509 -in "$repo/$CERT_REL" -noout -fingerprint -sha256 2>/dev/null || true)"
  [ -n "$fp_committed" ] || { echo "    실복원 증명: committed cert($CERT_REL) 읽기 실패"; return 1; }
  local match=0 crt key fp mod_c mod_k
  while IFS=$'\t' read -r crt key; do
    [ -n "$crt" ] && [ "$crt" != "null" ] && [ -n "$key" ] && [ "$key" != "null" ] || continue
    fp="$(printf '%s' "$crt" | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
    [ "$fp" = "$fp_committed" ] || continue
    mod_c="$(printf '%s' "$crt" | base64 -d 2>/dev/null | openssl x509 -noout -modulus 2>/dev/null || true)"
    mod_k="$(printf '%s' "$key" | base64 -d 2>/dev/null | openssl rsa -noout -modulus 2>/dev/null || true)"
    if [ -n "$mod_c" ] && [ "$mod_c" = "$mod_k" ]; then match=1; break; fi
    echo "    실복원 증명: cert는 일치하나 tls.key modulus 불일치(키쌍 손상)" >&2
  done < <(printf '%s' "$decrypted" | yq e '.items[] | select(.kind=="Secret") | (.data["tls.crt"] + "\t" + .data["tls.key"])' - 2>/dev/null || true)
  [ "$match" -eq 1 ] || { echo "    실복원 증명: committed cert와 일치하고 키쌍(modulus)도 맞는 백업 키 없음"; return 1; }
  echo "    실복원 증명 OK: committed cert 일치 + tls.key/tls.crt modulus 일치(유효 키쌍)"
}

# 비파괴 라이브 리허설(파괴 전, 라이브 클러스터 생존 시): 백업 List 적용성 + committed cert canary unseal.
rehearse_restore_on_live() {
  local repo="$1" backup_dir="$2"
  local latest; latest="$(ls -1 "$backup_dir"/ss-keys.*.enc.yaml 2>/dev/null | sort | tail -1)"
  [ -n "$latest" ] || { echo "    리허설: 백업 없음"; return 1; }
  # (1) sanitize 후 복호 백업 List가 fresh-cluster에 create 가능한지 비변경 검증(P5-3)
  sops -d --input-type binary --output-type binary "$latest" | sanitize_backup_yaml \
    | kubectl apply --dry-run=server -f - >/dev/null 2>&1 \
    || { echo "    리허설: 백업 List가 server dry-run apply 실패(메타데이터 등)"; return 1; }
  # (2) committed cert로 run-unique 랜덤 canary 봉인 → 임시 ns → 라이브 컨트롤러가 그 값을 unseal하는지(P5-2)
  local ns="sealed-dr-rehearsal" rnd name want
  rnd="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; name="dr-canary-$rnd"; want="v-$rnd"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
  trap 'kubectl delete namespace "sealed-dr-rehearsal" --ignore-not-found --wait=false >/dev/null 2>&1' RETURN
  kubectl -n "$ns" create secret generic "$name" --from-literal=v="$want" --dry-run=client -o yaml \
    | kubeseal --cert "$repo/$CERT_REL" --format yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 \
    || { echo "    리허설: committed cert로 canary 봉인/적용 실패"; return 1; }
  local got=""
  for _ in $(seq 1 24); do
    got="$(kubectl -n "$ns" get secret "$name" -o jsonpath='{.data.v}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ "$got" = "$want" ] && break
    sleep 5
  done
  [ "$got" = "$want" ] || { echo "    리허설: 라이브 컨트롤러가 이번 run canary 값을 unseal 못 함(stale/단절)"; return 1; }
  echo "    리허설 OK: 백업(sanitized) apply 가능 + run-unique canary가 라이브에서 값 일치 unseal"
}

wait_for_controller() {
  for _ in $(seq 1 "$CTRL_WAIT_RETRIES"); do kubectl -n "$SS_NS" get "$SS_DEPLOY" >/dev/null 2>&1 && break; sleep 5; done
  kubectl -n "$SS_NS" get "$SS_DEPLOY" >/dev/null 2>&1 || { echo "DR DRILL FAIL: sealed-secrets 컨트롤러 Deployment 미생성"; return 1; }
  kubectl -n "$SS_NS" rollout status "$SS_DEPLOY" --timeout=300s
}

# [4.5] 전: 모든 ArgoCD Application Healthy 대기(소비자 App data-conn·apps의 SealedSecret CR 싱크 보장).
wait_all_applications_healthy() {
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application --all --timeout="${1:-900s}"
}

restore_sealing_key() {
  local repo="$1" backup_dir="${2:-}"
  wait_for_controller || return 1
  local latest=""; [ -n "$backup_dir" ] && latest="$(ls -1 "$backup_dir"/ss-keys.*.enc.yaml 2>/dev/null | sort | tail -1)"
  [ -n "$latest" ] || { echo "    sealing-key DR: 복원할 백업 없음 — skip(cert 검증이 stale 판단)"; return 0; }
  echo "    sealing-key 복원: $latest"
  sops -d --input-type binary --output-type binary "$latest" | sanitize_backup_yaml | kubectl apply -f - || { echo "DR DRILL FAIL: 복호/sanitize/apply 실패"; return 1; }
  kubectl -n "$SS_NS" rollout restart "$SS_DEPLOY"; kubectl -n "$SS_NS" rollout status "$SS_DEPLOY" --timeout=300s
}

assert_committed_cert_matches_live() {
  local repo="$1" committed="$1/$CERT_REL"
  [ -f "$committed" ] || { echo "    cert 검증: committed cert 없음 — skip"; return 0; }
  local live; live="$(kubeseal --controller-namespace "$SS_NS" --fetch-cert 2>/dev/null)" || { echo "DR DRILL FAIL: 라이브 cert fetch 실패"; return 1; }
  local fp_live fp_have
  fp_live="$(printf '%s' "$live" | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
  fp_have="$(openssl x509 -in "$committed" -noout -fingerprint -sha256 2>/dev/null || true)"
  if [ -z "$fp_live" ] || [ "$fp_live" != "$fp_have" ]; then
    echo "DR DRILL FAIL: committed cert($CERT_REL)가 라이브 컨트롤러 cert와 불일치(stale)."
    echo "  → 향후 secret:seal/provision-db/provision-cache 봉인본을 새 컨트롤러가 복호 못 한다(PR #9)."
    echo "  복구책: (a) 백업 키 복원으로 active 승격, 또는 (b) kubeseal --fetch-cert > $CERT_REL 갱신·재커밋·전파."
    return 1; fi
  echo "    cert 검증 OK: committed cert == 라이브 cert"
}

# 수렴 후 전수 검증. live 조회 실패는 fail-closed(PASS 금지).
verify_all_sealedsecrets_unsealed() {
  local repo="$1" ref="${2:-origin/main}" merged rc=0
  merged="$(merge_consumers "$repo" "$ref")" || rc=$?
  if [ "$rc" -ne 0 ]; then   # 재구축 후엔 클러스터 생존 전제 — offline override 무관 무조건 fail-closed(P5-1)
    echo "DR DRILL FAIL: [4.5] 소비자 목록 조회 실패(kubectl/ref) — fail-closed, PASS 금지(offline override 미적용)"; return 1; fi
  [ -n "$merged" ] || { echo "    unseal 검증: 소비자 0개 — skip"; return 0; }
  local fail=0 line ns name ok
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ns="${line%%/*}"; name="${line#*/}"; ok=0
    for _ in $(seq 1 "$UNSEAL_RETRIES"); do kubectl -n "$ns" get secret "$name" >/dev/null 2>&1 && { ok=1; break; }; sleep 5; done
    if [ "$ok" -eq 1 ]; then echo "    unseal OK: $ns/$name"; else echo "DR DRILL FAIL: $ns/$name 미생성"; fail=1; fi
  done <<< "$merged"
  return "$fail"
}
