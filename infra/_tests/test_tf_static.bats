#!/usr/bin/env bats
# terraform 비의존 IaC 정적 계약 — 순수 grep/awk라 gate(required check)에서 돈다.
# ⚠️ 이 파일이 test_tf_validate.bats에서 갈라져 나온 이유: 그쪽 첫 @test가 `make tf-validate`를 불러
#    terraform을 요구해 파일 전체가 tests/.ci-exclude에 있었고, 그래서 아래 두 계약의 red가
#    required check를 막은 적이 없었다(유일 실행처가 advisory iac.yaml). test_tf_reconcile.bats가
#    같은 이유로 gate에 편입된 선례를 따른다.
# bash 3.2: 중간 단언은 [ ]만. @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "DR R2 buckets are guarded by prevent_destroy (offsite backup + media origin)" {
  # pg_backups(오프사이트 3차 사본)·media(유일 내구 origin)는 무인 apply의 destroy로부터 보호돼야 한다.
  # ⚠️ 건수 등식만으로는 **보호 대상의 신원**에 증인이 없다 — media에서 lifecycle을 떼고
  #    cache_backups로 옮기면 `grep -c`는 그대로 2이고 `terraform fmt -check`도 rc 0이다(실측).
  #    그래서 자원별 앵커를 함께 둔다. 건수는 바닥값(전체 삭제·과잉 추가)으로 남긴다.
  [ "$(grep -c 'prevent_destroy = true' infra/cloudflare/r2.tf)" -eq 2 ]
  for r in pg_backups media; do
    awk -v r="$r" '$0 ~ "^resource \"cloudflare_r2_bucket\" \""r"\"" {f=1} f{print} f&&/^}/{exit}' infra/cloudflare/r2.tf \
      | grep -qF 'prevent_destroy = true' || { echo "FAIL: r2 bucket $r prevent_destroy 부재"; false; }
  done
  # cache_backups에 prevent_destroy가 없다는 반대 방향(r2.tf:31 주석의 설계 의도)은 위 등식이 진다 —
  # 그 버킷이 얻으려면 pg_backups·media 중 하나가 잃어야 하고, 그건 앵커 루프가 잡는다.
}

@test "app DNS is a distinct resource (cloudflare_dns_record.app) — destroy-guard allow targets app hosts only" {
  # apex/www=cloudflare_dns_record.public(site_hosts, 구조적·가드 보호), 앱 host=cloudflare_dns_record.app
  # (app_hosts, 자동 관리). allow 정규식 ^cloudflare_dns_record\.app\[ 가 앱 DNS만 자동 허용하는 전제.
  d=infra/cloudflare/dns.tf
  grep -qE 'resource "cloudflare_dns_record" "app"' "$d" \
    && grep -qE 'resource "cloudflare_dns_record" "public"' "$d" \
    && grep -qE 'for_each = local\.site_hosts' "$d" \
    && grep -qE 'for_each = local\.app_hosts' "$d"
}
