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

@test "app DNS is a distinct resource (cloudflare_dns_record.app) — destroy-guard allow targets the app resource, not public" {
  # apex/www=cloudflare_dns_record.public(site_hosts, 구조적·가드 보호), 앱 host=cloudflare_dns_record.app
  # (app_hosts, 자동 관리). allow 정규식 ^cloudflare_dns_record\.app\[ 가 앱 DNS만 자동 허용하는 전제.
  d=infra/cloudflare/dns.tf
  grep -qE 'resource "cloudflare_dns_record" "app"' "$d" \
    && grep -qE 'resource "cloudflare_dns_record" "public"' "$d" \
    && grep -qE 'for_each = local\.site_hosts' "$d" \
    && grep -qE 'for_each = local\.app_hosts' "$d"
  # [infra-b-2] 위 네 리터럴은 존재만 잰다 — resource↔for_each **결합**에 앵커가 없어 두 for_each를
  # 맞바꿔도(신원 교체, 리소스별 신원은 그대로 남아 위 grep 4개는 잔존) 전건 초록이었다(6라운드 실측).
  # 같은 파일 :16-19 r2 앵커 관용구(awk 블록)를 리소스별로 복사해 신원을 확정한다.
  # [7라운드 tfval-cloudflare-2] 세 리소스 전부의 proxied=true(Cloudflare 프록시 — WAF/캐시/DDoS
  # 보호의 전제 조건)가 무증인이었다(public 리소스만 false로 뒤집어도 24/25 ok — 실측, 유일 not ok는
  # 환경 전제 terraform validate). 블록을 한 번만 추출해 for_each 결합과 proxied 값을 함께 앵커한다.
  for pair in public:site_hosts platform:platform_hosts app:app_hosts; do
    res="${pair%%:*}"; loc="${pair##*:}"
    block="$(awk -v r="$res" '$0 ~ "^resource \"cloudflare_dns_record\" \""r"\"" {f=1} f{print} f&&/^}/{exit}' "$d")"
    printf '%s' "$block" | grep -qF "for_each = local.$loc" || { echo "FAIL: dns_record $res <-> local.$loc 결합 부재"; false; }
    printf '%s' "$block" | grep -qE 'proxied[[:space:]]*=[[:space:]]*true' || { echo "FAIL: dns_record $res proxied != true"; false; }
  done
  # [infra-b-3] tunnel ingress SSOT(public_hosts 합집합)에서 platform_hosts가 빠져도(reserved-hosts.json
  # 소비 체인 단절) 정적 게이트가 전건 초록이었다(6라운드 실측) — 합집합 원소·platform 리소스 for_each를
  # 함께 앵커한다.
  line="$(grep -E '^[[:space:]]*public_hosts[[:space:]]*=' "$d")"
  for l in site_hosts platform_hosts app_hosts; do
    printf '%s' "$line" | grep -qF "local.$l" \
      || { echo "FAIL: public_hosts 합집합에 local.$l 부재 — tunnel ingress에서 그 host군이 빠진다"; false; }
  done
  grep -qE 'for_each = local\.platform_hosts' "$d"
}

@test "cloudflared tunnel ingress backends are exactly traefik + the 404 catch-all (no admin/app backend)" {
  # exact-tests-4: 라우팅 권위는 여기다 — tunnel.tf:10 config_src="cloudflare"라 cloudflared의
  # ConfigMap ingress 블록은 원격(API) config에 밀려 비관여다(posture 쪽 @test는 죽은 표면을
  # 읽고 있었다). for-loop라 host 수를 늘려도 `service =` **개수**는 늘지 않아(호스트마다 같은
  # traefik URL을 재사용) 정당한 host 추가마다 손 갱신을 부르지 않는다.
  # ⚠️ 행두 앵커(옵션 `[{ ` 접두)는 「행두 = 곧 service」를 가정하는데, 새 backend가
  # `[{ hostname = "...", service = "..." }]`처럼 **다른 키 뒤**에 service를 두면 그 줄은
  # 행두 매치에서 완전히 빠져 카운트가 그대로 2 — 침묵 통과(실측). 행 위치가 아니라 **개수**로
  # 잰다: \bservice[[:space:]]*= 를 파일 전역에서 grep -o로 뽑아 라인이 아니라 매치 건수를 센다.
  d=infra/cloudflare/tunnel.tf
  [ "$(grep -oE '\bservice[[:space:]]*=' "$d" | wc -l)" -eq 2 ]
  grep -qF 'http://traefik.gateway.svc.cluster.local:80' "$d"
  grep -qF 'http_status:404' "$d"
}

@test "pg_backups and cache_backups R2 lifecycles pin enabled=true, prefix=\"\", max_age=1209600 (owner decision 2026-09-04: bucket-wide 14d expiry stays)" {
  # 티켓 60 r2-1 — owner 결정: pg_backups의 `prefix = ""`(버킷 전체 만료, ADR-0006 정정 문단·r2.tf:14-18
  # 주석이 이미 적은 사실)를 **증인으로 잠근다**. 존재 단언(위 prevent_destroy @test)은 리소스가
  # 있다는 것만 재지 값 축은 무증인이었다 — max_age를 86400으로 바꿔도(만료 주기 변경, 데이터 보존
  # 정책 실질 변경) 위 @test들은 전건 초록이다(실측). 같은 파일 :17의 awk 블록 추출 관용구를
  # `cloudflare_r2_bucket_lifecycle`에 재사용해 리소스별로 세 값을 앵커한다.
  for r in pg_backups cache_backups; do
    block="$(awk -v r="$r" '$0 ~ "^resource \"cloudflare_r2_bucket_lifecycle\" \""r"\"" {f=1} f{print} f&&/^}/{exit}' infra/cloudflare/r2.tf)"
    [ -n "$block" ] || { echo "FAIL: r2 bucket_lifecycle $r 블록 부재"; false; }
    printf '%s' "$block" | grep -qE 'enabled[[:space:]]*=[[:space:]]*true' \
      || { echo "FAIL: r2 bucket_lifecycle $r enabled != true"; false; }
    printf '%s' "$block" | grep -qE 'prefix[[:space:]]*=[[:space:]]*""' \
      || { echo "FAIL: r2 bucket_lifecycle $r prefix != \"\" (버킷 전체 만료 계약 이탈)"; false; }
    printf '%s' "$block" | grep -qE 'max_age[[:space:]]*=[[:space:]]*1209600' \
      || { echo "FAIL: r2 bucket_lifecycle $r max_age != 1209600(14일)"; false; }
  done
}

@test "each cloudflare output pins the correct sensitive value (tunnel_token is the only live secret)" {
  # [7라운드 c71-1] 티켓 65 「다음 라운드 입력」 — outputs.tf 6개 output 중 tunnel_token(실
  # cloudflared run token)만 sensitive=true여야 하고 나머지 5개(tunnel_id·r2 버킷명·엔드포인트 URL)는
  # 정당하게 false다. infra/tailscale/test_provider_scopes.bats의 "블록 수==sensitive=true 수" 건수
  # 등식은 **여기 그대로 못 옮긴다** — tailscale은 전 output이 true라 건수만 세도 신원이 잠기지만,
  # 이 파일은 6개 중 1개만 true라 "아무 출력이나 하나만 true"여도 건수 등식은 속는다(값이 이질적).
  # 그래서 output 이름별로 기대 sensitive 값을 앵커한다(pair 분할 관용구는 :38-43 dns_record 루프와
  # 동형 — declare -A는 bash 3.2 미지원이라 쓰지 않는다). 목록 크기==전체 output 블록 수 등식으로
  # 신규 output 추가(무증인 상태로 섞여 들어오는 회귀)도 함께 닫는다.
  d=infra/cloudflare/outputs.tf
  for pair in tunnel_token:true tunnel_id:false r2_account_endpoint:false \
    r2_pg_backups_bucket:false r2_cache_backups_bucket:false r2_media_bucket:false; do
    name="${pair%%:*}"; want="${pair##*:}"
    block="$(awk -v r="$name" '$0 ~ "^output \""r"\"" {f=1} f{print} f&&/^}/{exit}' "$d")"
    [ -n "$block" ] || { echo "FAIL: output $name 블록 부재"; false; }
    printf '%s' "$block" | grep -qE "sensitive[[:space:]]*=[[:space:]]*${want}" \
      || { echo "FAIL: output $name sensitive != ${want}"; false; }
  done
  [ "$(grep -cE '^output "' "$d")" -eq 6 ]
}
