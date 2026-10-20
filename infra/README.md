# Terraform 운영

세 root는 owner가 로컬에서 실행한다. CI와 Argo CD는 apply하지 않는다.
외부 변경은 사람이 승인하고
[`approvals.md`](../docs/plans/2026-10-17-homelab-rebuild/approvals.md)에 기록한다.
이 문서는 공개 절차다. 실제 계정 식별자·정책 사본·DNS 사본·state 백업과 실행 기록은 저장소 밖에 둔다.
옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다.

## 1. 준비와 자격

`mise install`로 `.tool-versions`의 Terraform 1.16.6과 Infisical CLI 0.44.2를 설치하고, `infisical login`으로 owner 계정에 로그인한다(브라우저 인증, 토큰은 OS 키링).
Provider는 Cloudflare 5.28.0, Tailscale 0.29.2와 root별 `.terraform.lock.hcl`로 고정한다.
2026-10-20 확인한 최신 안정판이다:
[Terraform 릴리스](https://github.com/hashicorp/terraform/releases/tag/v1.16.6),
[Cloudflare 릴리스](https://github.com/cloudflare/terraform-provider-cloudflare/releases/tag/v5.28.0),
[Tailscale 릴리스](https://github.com/tailscale/terraform-provider-tailscale/releases/tag/v0.29.2).
Terraform은 아직 CI 설치 대상이 아니므로 `ci.yaml` sha256 변경이 없다.

Infisical에 로그인한 owner가 다음 키를 준비한다. 모두 `prod` 환경이다.

| 프로젝트 / 경로 | 키 | 값의 출처 |
|---|---|---|
| `homelab-admin` `/terraform/state` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | T09에서 만든 R2 `homelab-tfstate` Object Read & Write 자격 |
| `homelab-admin` `/terraform/cloudflare` | `CLOUDFLARE_API_TOKEN` | T09 Cloudflare Terraform용 토큰 |
| `homelab-admin` `/terraform/tailscale` | `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET` | T09 Terraform용 OAuth client |
| `homelab-admin` `/terraform/tailscale` | **새 키** `TF_VAR_nuc_expected_owner` | Tailscale Machines의 `nuc-15-pro` 소유자, provider device `user`와 일치하는 로그인 식별자 |
| `homelab-admin` `/terraform/tailscale` | **새 키** `TF_VAR_dns_adoption_snapshot` | 4절에서 확인한 현재 DNS 전체 설정의 JSON. 되돌리기용 최초 사본으로 보존 |
| `homelab` `/platform/cloudflared` | **터널 생성 후** `TUNNEL_TOKEN` | 5절의 sensitive Terraform output. ESO가 이 키를 읽도록 플랫폼 담당자와 맞춘다 |

Cloudflare account ID와 zone ID는 HCL에 저장하지 않는다.
옛 root는 account ID를 변수로 받았지만, 새 root는 공개 zone 이름 `ukyi.app`으로
[`cloudflare_zone`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.28.0/docs/data-sources/zone)을 찾아 `account.id`를 사용한다.
따라서 `TF_VAR_cloudflare_account_id`와 zone ID 변수는 필요 없다.
Backend 초기화는 provider 조회보다 먼저이므로 R2 콘솔의 S3 API endpoint를 실행 시 입력한다.
Endpoint에는 자격이 없지만 account ID가 포함되며 `.terraform` 캐시에 남는다. Git에는 넣지 않는다(D-23).

Terraform용 Tailscale OAuth에는 `policy_file`·`dns` 쓰기, `devices:posture_attributes`(쓰기), `devices:core:read`가 필요하다.
`policy_file` 쓰기는 `devices:posture_attributes`와 `devices:core:read`를 함께 요구한다([trust credentials 문서](https://tailscale.com/docs/reference/trust-credentials#scopes)).
ACL root는 이 셋을, DNS root는 `dns`와 `devices:core:read`만 요청한다. OAuth client에 하나라도 빠지면 그 root가 권한 오류로 멈춘다.
Tailnet은 OAuth 자격의 소유자로 추론하므로 `TAILSCALE_TAILNET`은 필요 없다.
Operator용 OAuth는 별개이며, `tag:k8s-operator`가 tagOwners에 있어야 사람이 발급할 수 있다(2026-10-20 현재 ACL에 이미 있다).
Operator용 값은 플랫폼 담당자가 `homelab` `/platform/tailscale`에 등록한다.
Cloudflare API 토큰과 Terraform용 OAuth를 클러스터에 넣지 않는다.

## 2. 명령 실행 환경과 backend

아래 명령은 **Bash**, 저장소 루트에서 실행한다. `TF_LOG`·셸 추적·터미널 녹화를 끈다.
자격은 `infisical run`이 환경변수로 주입한다. `tfvars`, `backend.hcl`, `-var` 인수에 넣지 않는다.

```bash
bash
set +x
set -o pipefail
unset TF_LOG TF_LOG_PATH TF_LOG_CORE TF_LOG_PROVIDER
unset TAILSCALE_API_KEY TAILSCALE_TAILNET CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
unset AWS_PROFILE AWS_SESSION_TOKEN TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply
unset TF_WORKSPACE
export TF_IN_AUTOMATION=1
# TF_INPUT=0은 넣지 않는다. -input=false와 같아서 apply가 승인 질문을 못 하고 변경을 거부한다.
# 변수 누락 때 질문하지 않고 실패하도록 init·plan에만 -input=false를 붙인다.
# 로그인 사용자로 infisical run을 하면 CLI 0.44.2가 가져온 값을 암호화해 ~/.infisical/secrets-backup/에 파일로 남긴다
# (packages/util/secrets.go WriteBackupSecrets). 호출부가 그 오류를 무시하므로 폴더를 쓰기 불가로 두어 파일을 만들지 못하게 한다.
mkdir -p ~/.infisical
if [ -d ~/.infisical/secrets-backup ]; then chmod 0700 ~/.infisical/secrets-backup; find ~/.infisical/secrets-backup -type f -delete; fi
mkdir -p ~/.infisical/secrets-backup && chmod 0500 ~/.infisical/secrets-backup
backup_files() { find ~/.infisical/secrets-backup -type f 2>/dev/null | wc -l; }  # 실행마다 0이어야 한다
read -r -p 'homelab-admin project ID: ' HOMELAB_ADMIN_PROJECT_ID
read -r -p 'R2 S3 API endpoint (https://...r2.cloudflarestorage.com): ' R2_ENDPOINT

tf() {
  local root="$1" provider_path
  shift
  case "$root" in
    cloudflare) provider_path=/terraform/cloudflare ;;
    tailscale|tailscale-dns) provider_path=/terraform/tailscale ;;
    *) printf '%s\n' '지원하지 않는 root' >&2; return 1 ;;
  esac
  infisical run --silent --log-level=error --projectId="$HOMELAB_ADMIN_PROJECT_ID" --env=prod --path=/terraform/state -- \
    infisical run --silent --log-level=error --projectId="$HOMELAB_ADMIN_PROJECT_ID" --env=prod --path="$provider_path" -- \
    terraform -chdir="infra/$root" "$@"
}
```

첫 초기화 전에 중첩 실행이 바깥 R2 자격을 보존하는지 **값을 출력하지 않고** 확인한다.
두 provider 경로에서 각각 실행한다.

```bash
for provider_path in /terraform/cloudflare /terraform/tailscale; do
  infisical run --silent --log-level=error --projectId="$HOMELAB_ADMIN_PROJECT_ID" --env=prod --path=/terraform/state -- \
    infisical run --silent --log-level=error --projectId="$HOMELAB_ADMIN_PROJECT_ID" --env=prod --path="$provider_path" -- \
    bash -c 'test -n "$AWS_ACCESS_KEY_ID" && test -n "$AWS_SECRET_ACCESS_KEY"'
  test "$?" -eq 0 || break
done
```

하나라도 실패하면 진행하지 않는다. 설계 C.3.9의 대안대로 owner가 R2 키를 각 provider 경로에도 등록하고 중복 키의 값을 맞춰 재확인한다.
같은 키 이름에 서로 다른 값이 들어 있으면 안 된다.

```bash
tf cloudflare init -input=false -reconfigure -lockfile=readonly \
  "-backend-config=endpoints={s3=\"$R2_ENDPOINT\"}"
tf tailscale init -input=false -reconfigure -lockfile=readonly \
  "-backend-config=endpoints={s3=\"$R2_ENDPOINT\"}"
tf tailscale-dns init -input=false -reconfigure -lockfile=readonly \
  "-backend-config=endpoints={s3=\"$R2_ENDPOINT\"}"
```

Backend 인수는 endpoint 하나뿐이다. 자격은 환경변수만 사용한다.
각 root의 state 키는 코드에 고정돼 있다:
`v2/cloudflare/terraform.tfstate`, `v2/tailscale/terraform.tfstate`,
`v2/tailscale-dns/terraform.tfstate`.
버킷 `homelab-tfstate` 자체는 이 root들이 관리하지 않는다.
Terraform workspace는 `default`만 사용한다. `-migrate-state`로 옛 state를 옮기지 않는다.

R2에는 state versioning이 없으므로 **state가 생긴 뒤부터 매 apply 전에** 저장소 밖 접근 제한 위치로 백업한다.
State는 토큰·기기 식별자를 포함할 수 있어 일반 로그로 취급하지 않는다.

```bash
read -r -p '저장소 밖 state 백업 디렉터리: ' TF_STATE_BACKUP_DIR
mkdir -p "$TF_STATE_BACKUP_DIR"
chmod 700 "$TF_STATE_BACKUP_DIR"
umask 077
# 해당 root만 선택한다. 최초 새 state에는 pull 대상이 없다.
tf cloudflare state pull > "$TF_STATE_BACKUP_DIR/cloudflare-$(date -u +%Y%m%dT%H%M%SZ).tfstate"
```

ACL·DNS도 `cloudflare` 부분을 각 root 이름으로 바꿔 백업한다.
실패한 빈 백업은 유효한 사본으로 세지 않는다. 백업은 암호화해 별도 복구 자산으로 보관한다.

## 3. Cloudflare와 ACL 적용 순서

1. 승인 기록을 남긴다. Cloudflare 콘솔에서 옛 터널·DNS·동일 phase WAF가 정리됐는지 확인한다.
   남은 자원이 있으면 생성 충돌을 강행하지 말고 소유권과 import 필요성을 검토한다.
2. Tailscale 콘솔 **Access controls**에서 현재 정책 전체를 저장소 밖 사본으로 보존한다.
   실제 사용자·기기 정보가 들어갈 수 있어 Git에 붙이지 않는다. NUC의 LAN/물리 복구 경로를 확보한다.
3. 아래 plan을 검토하고 사람이 apply한다. `-auto-approve`는 쓰지 않는다.

```bash
tf cloudflare plan -input=false -lock-timeout=0s
tf cloudflare apply -lock-timeout=0s
tf cloudflare plan -input=false -detailed-exitcode -lock-timeout=0s

tf tailscale plan -input=false -lock-timeout=0s
tf tailscale apply -lock-timeout=0s
tf tailscale plan -input=false -detailed-exitcode -lock-timeout=0s
tailscale ssh nuc-15-pro
```

Apply 후 plan의 exit 0이 무변경이다. Exit 1은 오류, 2는 변경이 남았다는 뜻이다.
Cloudflare 새 state의 zone 설정 9개 생성 표시는 zone 생성이 아니라 기존 설정값의 관리 시작이다.
값은 설계 F D-11과 옛 `zone_settings.tf`의 9개를 유지한다.
Free 플랜의 WAF·zone 설정 거절은 validate로 검출되지 않을 수 있으므로 실제 apply를 사람이 확인한다.
`homelab-backups`는 삭제 방지가 있고, lifecycle은 `valkey/`에만 1,209,600초(14일)를 적용한다.
PostgreSQL 14일 보존은 T11의 CNPG ObjectStore가 맡는다.

ACL root는 기존 정책을 import 블록으로 먼저 state에 가져온다. 빈 state에서 Create하면 provider가 `ts-default` ETag를 보내
기존 정책에 412(`Overwrite Protected`)로 실패하기 때문이다. 그래서 첫 plan은 **`1 to import, 0 to add, 1 to change, 0 to destroy`**이고,
change의 diff가 저장소 밖 사본(현재 정책)에서 `policy.hujson`으로 바뀌는 내용이다. diff를 읽고 apply한다.
`overwrite_existing_content`는 diff 없이 덮어써 쓰지 않는다.
ACL 적용 후 원격 SSH 성공과 `tag:k8s-operator` 선언을 확인한다. operator OAuth client는 이 태그가 tagOwners에 있으면 발급할 수 있다.
DNS 목표 전환은 AdGuard가 NUC의 tailnet 주소에서 TCP/UDP 53으로 응답하는 것을 확인한 뒤 한다.

### U02: R2 잠금 동시 실행

첫 Cloudflare state가 생긴 뒤 같은 root·같은 `default` workspace·같은 backend로
터미널 두 개에서 2절의 환경을 준비한다. 두 터미널에서 아래 명령을 동시에 실행한다.

```bash
tf cloudflare plan -input=false -lock-timeout=0s
```

한쪽은 plan 성공, 다른 쪽은 **Error acquiring the state lock**으로 exit 1이어야 한다.
둘 다 성공하면 실행 구간이 겹치지 않았을 수 있어 통과가 아니다. 실제 겹칠 때까지 다시 시험한다.
Lock ID와 성공/오류·종료 코드만 비공개 실행 기록에 남기고, 자격·state 본문은 남기지 않는다.
`-lock=false`나 `force-unlock`으로 통과시키지 않는다.
중첩 자격 확인과 이 시험이 모두 끝나기 전에는 T10의 `infra/github` 첫 apply로 넘어가지 않는다.

## 4. Tailscale DNS: 현재 값 인수 후 목표 전환

이 root는 DNS 전체를 소유한다. 다른 `tailscale_dns_*` 자원과 함께 관리하지 않는다.
NUC가 없거나 재등록 중이면 실행하지 않는다. 재등록 후에는 키 만료를 다시 해제하고 소유자·태그를 확인한다.
`prevent_destroy`는 선언이 남아 있을 때의 삭제를 막는다. root/리소스 선언을 지우는 방식으로 우회하지 않는다.

### (a) 현재 설정 그대로 import

`tailscale-dns/main.tf`의 `dns_phase = "adopt"`를 유지한다.
사람이 Tailscale DNS 콘솔과 아래 명령을 대조해 현재 값을 기록한다.

```bash
tailscale dns status --all
```

CLI만으로 Override 상태를 확정하지 않는다. 콘솔에서 다음을 모두 읽는다.

- Override local DNS와 MagicDNS의 실제 토글 값.
- 전역 nameserver 전부와 각각의 `use_with_exit_node`. C-05 Cloudflare IPv4 2개·IPv6 2개도 유지한다.
- 사용자가 설정한 split DNS 도메인과 그 서버들, 사용자 search path.
  MagicDNS가 자동으로 보이는 tailnet 검색 도메인·`ts.net.` 라우트는 수동 split DNS와 구별한다.
  Provider가 읽는 원격 설정과 차이가 나면 import 계획에서 확인하고 사본을 수정한다.

다음은 **입력 구조**다. 문자열 자리는 실제 자료형으로 바꾼다.
기본값을 추측해서 빈 배열이나 `false`를 넣지 않는다.
전체 JSON을 Infisical `homelab-admin` `/terraform/tailscale`의
`TF_VAR_dns_adoption_snapshot`에 넣는다. 실제 JSON은 HCL·tfvars·문서에 넣지 않는다.

```json
{
  "override_local_dns": "<콘솔의 true 또는 false, 문자열이 아닌 boolean>",
  "magic_dns": "<콘솔의 true 또는 false, 문자열이 아닌 boolean>",
  "nameservers": [
    {
      "address": "<현재 전역 서버 주소>",
      "use_with_exit_node": "<콘솔의 true 또는 false, 문자열이 아닌 boolean>"
    }
  ],
  "split_dns": [
    {
      "domain": "<사용자가 설정한 도메인>",
      "nameservers": [
        {
          "address": "<해당 서버 주소>",
          "use_with_exit_node": "<콘솔의 true 또는 false, 문자열이 아닌 boolean>"
        }
      ]
    }
  ],
  "search_paths": ["<사용자가 설정한 검색 도메인>"]
}
```

사용자 split DNS와 search path가 **실제로 없으면** 각각 `[]`다.
`TF_VAR_nuc_expected_owner`도 Machines의 소유자로 채운다.
NUC는 정확히 1대, 태그 없음, 키 만료 해제, `100.`으로 시작하는 IPv4 1개여야 한다.
IPv6가 주소 목록 첫 항목이어도 HCL은 IPv4만 고른다.

```bash
tf tailscale-dns plan -input=false -lock-timeout=0s
```

HCL의 import 블록이 기존 singleton 설정을 읽는다.
Import ID `dns_configuration`은 tailnet 이름이 아니라
[provider가 허용하는 임의 ID](https://registry.terraform.io/providers/tailscale/tailscale/0.29.2/docs/resources/dns_configuration)다.
**첫 계획은 `1 to import, 0 to add, 0 to change, 0 to destroy`여야 한다.**
변경이 하나라도 있으면 apply하지 않고 콘솔과 입력 JSON을 다시 대조한다.
값이 sensitive라 세부 차이가 가려지더라도 변경 건수가 0인지 확인할 수 있다.
처음 import가 있다는 이유로 `-detailed-exitcode`가 2일 수 있으므로 이것을 무변경 판정에 쓰지 않는다.

```bash
tf tailscale-dns apply -lock-timeout=0s
tf tailscale-dns plan -input=false -detailed-exitcode -lock-timeout=0s
```

Apply가 다시 보여 주는 계획도 **import만** 있는지 보고 승인한다.
이어지는 plan이 exit 0이어야 인수가 끝난다. import 블록은 state에 같은 주소가 있으면 재실행되지 않아 남겨 둔다.
원래 JSON 사본과 이 무변경 결과는 비공개 복구 기록으로 보존한다.

### (b) D-08 (b′)로 전환

단계 (a)의 무변경 확인, U02 통과, AdGuard 준비와 승인 기록 후,
**별도 PR에서** `dns_phase = "target"`으로 한 줄을 바꾼다.
목표 선언은 이미 같은 파일에 있다:
Override·MagicDNS 켬, NUC IPv4 + `94.140.14.14` + `94.140.15.15`,
세 서버 모두 `use_with_exit_node = false`.
전역 C-05 Cloudflare 4개는 이 교체로 제거한다.
사용자 split DNS·search path는 인수 사본대로 보존하며, 별도 변경이 필요하면 별도 검토한다.
HTTPS 인증서는 이 리소스의 속성이 아니므로 사람이 콘솔에서 따로 켜고 승인 기록에 남긴다.

```bash
tf tailscale-dns plan -input=false -lock-timeout=0s
# 2절대로 tailscale-dns state를 저장소 밖에 백업한 뒤 실행한다.
tf tailscale-dns apply -lock-timeout=0s
tf tailscale-dns plan -input=false -detailed-exitcode -lock-timeout=0s
tailscale dns status --all
```

Plan이 `0 to add, 1 to change, 0 to destroy`이고 의도한 전환인지 검토한다.
적용 후 exit 0, 전역 서버 셋과 Cloudflare 부재를 확인한다.
시나리오 14의 집 Wi-Fi·셀룰러·NUC 장애 시험까지 통과해야 DNS 실환경 검증 U34를 완료로 기록한다.
NUC 자신은 `accept-dns=false`를 유지한다.

**Provider 주의:** 설계는 v0.29.2를 정식이라고 적었지만,
[고정 버전 소스의 Read](https://github.com/tailscale/terraform-provider-tailscale/blob/v0.29.2/tailscale/resource_dns_configuration.go)는
아직 `Alpha Resource` 경고를 낸다. 실제 import·무변경 plan은 미검증(U34)이다.
실패하면 목표 apply를 멈춘다. 설계의 대안대로 사람이 콘솔에서 한 번 설정하고,
플랫폼 담당자가 `bootstrap.md`에 값의 출처·확인 명령과 IaC 밖 관리임을 기록한다.
이때 선언을 그냥 삭제하거나 destroy하지 말고 state 소유권 전환을 별도로 검토한다.

## 5. 터널 토큰 전달

`tunnel_token`은 sensitive output으로 정했다.
보통 plan/apply에는 값이 가려지지만 **state에는 토큰이 저장된다**.
R2 state와 백업의 읽기 권한을 owner로 제한한다.
`terraform output -raw`를 화면에 직접 실행하거나 파일·로그로 리다이렉트하지 않는다.
[Cloudflare의 토큰 조회 방식](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/)을
전용 data source가 사용한다.

사람이 로그인한 로컬 데스크톱에서, 클립보드 기록·동기화와 터미널 녹화를 끈다.
Infisical 웹에서 `homelab` / `prod` / `/platform/cloudflared`의 `TUNNEL_TOKEN` 입력을
**마스킹 상태**로 준비한다. Linux Wayland의 `wl-copy`가 있는 환경에서는:

```bash
# 2절의 tf 함수와 pipefail을 설정한 셸에서 실행한다.
tf cloudflare output -raw tunnel_token | wl-copy
```

성공한 경우에만 마스킹 입력란에 붙여넣고 저장한 뒤 `wl-copy --clear`로 지운다.
macOS에서는 같은 파이프 끝을 `pbcopy`로 바꾸고, 저장 후 `printf '' | pbcopy`로 지운다.
터미널/Infisical 로그에 값이 나오지 않았는지 확인하되 값을 다시 표시하지 않는다.
클립보드 프로그램이 없거나 원격 세션에 클립보드가 연결되지 않으면 해당 로컬 환경에서 진행한다.
이 방법은 **추출 과정에서 추가 평문 파일을 만들지 않으며**, 기존 Terraform state의 보관 문제까지 없애지는 않는다.
클러스터에는 이 터널 토큰만 전달하고 Cloudflare API 토큰은 전달하지 않는다.

## 6. 되돌리기와 미검증

- **ACL:** 먼저 남긴 정책 사본을 사람이 콘솔에서 복원하고 새 root의 `policy.hujson`을 같은 정책으로 맞춘다.
  실제 사용자 값이 포함된 사본은 공개 Git에 넣지 말고 복구 담당자가 참조 구조를 검토한다.
  승인 기록을 남기고 SSH·plan을 재확인한다. 옛 root는 쓰지 않는다.
- **DNS:** 단계 (b)의 한 줄 변경을 revert PR로 `adopt`로 되돌리고,
  최초 `TF_VAR_dns_adoption_snapshot`을 유지한 채 새 DNS root에서 plan → apply → 무변경 plan을 확인한다.
  급하면 사람이 콘솔에서 C-05 사본 전체를 복구한 뒤 HCL 단계를 맞춘다. **destroy로 복구하지 않는다.**
- **Cloudflare:** 이전 선언의 revert PR과 owner plan/apply로 복구한다.
  버킷 삭제·터널 삭제는 일반 복구 절차가 아니다. 특히 `prevent_destroy`는 객체 lifecycle 만료를 막지 않는다.
  state 백업을 복원하는 것만으로 실제 외부 설정이 되돌아가지는 않는다.

U01(원격 터널 와일드카드), U02(R2 잠금과 중첩 자격), U34(실제 DNS 인수·전환)는
자격 없는 fmt/init/validate로 확인할 수 없다. 사람 검증 결과를 따로 남긴다.
U01은 시험 host 200·없는 host 404·cloudflared `/ready` 200을 확인한다.
WAF는 `GET https://hooks.ukyi.app/github`와 다른 경로 POST를 차단하고,
정상 경로 POST의 HMAC 검증은 봇/시험 수신기가 담당한다.

## 7. 자격 없는 로컬 검사

```bash
for root in cloudflare tailscale tailscale-dns; do
  terraform -chdir="infra/$root" fmt -check -recursive
  terraform -chdir="infra/$root" init -backend=false -input=false -lockfile=readonly
  terraform -chdir="infra/$root" validate
done
pre-commit run --files .tool-versions infra/README.md \
  infra/cloudflare/*.tf infra/cloudflare/.terraform.lock.hcl \
  infra/tailscale/*.tf infra/tailscale/policy.hujson infra/tailscale/.terraform.lock.hcl \
  infra/tailscale-dns/*.tf infra/tailscale-dns/.terraform.lock.hcl
```

현재 gitleaks pre-commit 훅은 파일 인수를 무시하고 staged diff만 검사한다.
아직 stage하지 않은 작업은 별도로 `gitleaks dir infra --redact --config .gitleaks.toml`로 검사한다.
Mock 시험은 v0.29.2의 `devices` 중첩 블록이 `override_data`로 채워지지 않아 채택하지 않았다.
실제 NUC precondition의 정상·오류 경계 검증은 U34에 남아 있다.
