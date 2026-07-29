#!/usr/bin/env bats
# 질의 로그 보존이 **시드에 명시**돼 있는지 — 부재는 AdGuard 기본값(90d)으로 되돌아가는 경로다.
#
# 병(라이브 실측 2026-07-29): 시드 ConfigMap에 `querylog:` 절이 **아예 없었다**. 그래서 첫 부팅에서
# AdGuard 기본값이 적용됐고 라이브는 `interval: 30d`로 굳어 있었다. 증가율 ~28.5MB/일 ×
# (현재 파일 + 회전본 `querylog.json.1`) = 정상상태 **~1.7GB**로 PVC 선언(1Gi)을 **구조적으로** 초과했다.
# 실측 점유 1.2GB = **115%**. 이 상태를 감시하는 알림도 없었다(`pvc_dir_size_bytes`는 수집만 되고
# 어떤 alert expr도 소비하지 않는다).
#
# ⚠️ **시드는 첫 부팅 전용**(`cp -n`)이라 이 파일을 고쳐도 **라이브는 안 바뀐다**. 그럼에도 강제하는
#    이유는 **DR 재구축**이다 — 절이 없으면 재구축된 AdGuard가 기본값(90d)으로 되돌아가고, 그건
#    지금보다 3배 나쁘다. 라이브 반영은 PVC의 conf/AdGuardHome.yaml 편집 + 재시작이 별도로 필요하다.
#
# ⚠️ 점유는 **interval 분량의 약 2배**다 — AdGuard가 `querylog.json`과 회전본 `.1`을 함께 유지한다.
#    이 2배를 빼먹으면 예산이 절반으로 잘못 잡힌다(원 D-4 조사에서 실제로 그 착시가 있었다).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; cd "$ROOT" || exit 1
  CM="platform/adguard/prod/adguardhome.yaml"
  PVC="platform/adguard/prod/pvc.yaml"
}

inner() { yq -r '.data["AdGuardHome.yaml"]' "$ROOT/$CM"; }

@test "the seed declares querylog retention explicitly (absence means AdGuard's 90d default)" {
  run bash -c "yq -r '.data[\"AdGuardHome.yaml\"]' '$ROOT/$CM' | yq -r '.querylog.interval'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "the declared retention fits the PVC with the rotated copy accounted for" {
  iv="$(inner | yq -r '.querylog.interval')"
  # "14d" → 14
  days="${iv%d}"
  case "$days" in ''|*[!0-9]*) echo "interval '$iv'을 일 단위로 읽을 수 없다"; return 1 ;; esac

  decl="$(yq -r '.spec.resources.requests.storage' "$ROOT/$PVC")"
  # "1Gi" → MiB
  case "$decl" in
    *Gi) decl_mib=$(( ${decl%Gi} * 1024 )) ;;
    *Mi) decl_mib=${decl%Mi} ;;
    *) echo "PVC 선언 '$decl' 단위 미인식"; return 1 ;;
  esac

  # 관측 증가율(2026-07-29 실측: 427MB / 15일). 상수지만 **근거가 있는 상수**이고, 초과하면
  # 이 테스트가 red를 내 재측정을 강제한다 — 조용히 넘어가는 것보다 낫다.
  rate_mib_per_day=29
  # ★ 회전본을 포함해 **2배**로 잡는다.
  need=$(( days * rate_mib_per_day * 2 ))

  # 핵심 단언(마지막): 예상 정상상태가 선언 안에 들어와야 한다.
  [ "$need" -le "$decl_mib" ] || {
    echo "querylog interval ${iv} → 정상상태 ~${need}MiB(회전본 포함) > PVC 선언 ${decl}(${decl_mib}MiB)"
    echo "  → interval을 줄이거나 PVC를 키워라. ⚠️ PVC requests.storage는 축소 불가(확장 전용)다."
    return 1
  }
}

@test "statistics retention is declared too (same default-drift path)" {
  run bash -c "yq -r '.data[\"AdGuardHome.yaml\"]' '$ROOT/$CM' | yq -r '.statistics.interval'"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}
