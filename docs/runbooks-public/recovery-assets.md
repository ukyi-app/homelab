# 복구 자산: 보관 위치와 항목 이름

클러스터, Infisical, 계정을 잃었을 때 처음 손에 쥐어야 하는 것들이다. 근거는 설계 [C.6.4](../plans/2026-10-17-homelab-rebuild/platform/design.md)(최초 연결과 재해 복구)다.

저장소가 public이라(D-23) 이 문서에는 **보관 위치 이름과 항목 이름만** 둔다. 값, 계정 이름, 보관 경로, 각 항목의 세부는 저장소 밖 목록에 있다. 복구 순서는 설계 C.6.4의 "복구 순서" 표를 따른다.

## 보관 위치 (NUC 밖 두 곳)

1. 비밀번호 관리자(1Password)
2. 오프라인 암호화 USB

한 곳만 두지 않는다. 단일 디스크 단일 사본은 매체 유실에 무방비였다(설계 C.6.4).

## 항목

| 항목 | 쓰는 상황 | 바뀌는 때 |
|---|---|---|
| 계정 접근 수단: GitHub org owner, Infisical, Cloudflare, Tailscale의 로그인과 2FA 복구 코드 | 모든 복구의 출발점 | 계정 설정을 바꿀 때. healthchecks.io는 T08b가 체크를 만들 때 더한다 |
| ESO 부트스트랩 자격: `eso-homelab` Universal Auth Client ID와 운영 Client Secret | 클러스터 재구축([bootstrap.md](bootstrap.md) 2.2) | 연 1회 회전([rotate.md](rotate.md) 1절) |
| Terraform state 버킷 자격 사본: R2 `homelab-tfstate` 키 | Infisical 없이 Cloudflare·Tailscale 설정 복구 | 회전할 때 |
| Infisical 암호화 내보내기: `homelab`, `homelab-admin`(App 키는 GitHub에서 새로 발급하므로 뺀다) | Infisical 계정 잠김·영구 손실, Infisical 장애 중 급한 재구축 | 분기 1회 |
| 관리자 비밀번호 원문: Argo CD `owner`, Grafana, AdGuard | 로그인. Argo CD·AdGuard는 Infisical에 bcrypt 해시만 있다 | 회전할 때([rotate.md](rotate.md) 2절) |
| R2 백업 읽기 자격 사본(운영 백업 버킷만, 읽기 전용) | Infisical 없이 DB 복원, 시나리오 13의 VM 복구 원본 | T11이 백업 버킷을 만들 때 더한다 |
| AdGuard 라이브 설정 내보내기(선택) | UI에서만 바꾼 규칙 복구 | T08a 뒤, 규칙을 바꿀 때 |

## 신선도 확인 (분기 1회)

"사본이 있다"가 아니라 "지금 값과 맞다"를 본다.

- 운영 ESO 자격으로 Infisical Universal Auth 로그인이 200인지 본다. 명령은 [rotate.md](rotate.md) 1절 2단계와 같고, 응답 코드만 본다. 2026-10-20 T09 시나리오 7의 장애 주입 뒤에도 200이었다.
- Infisical 암호화 내보내기를 새로 만들어 두 곳의 옛 사본을 바꾼다.
- 시나리오 13(VM 재구축)이 이 자산과 VM 준비 자산으로 실제 복구를 검증한다. VM은 운영 ESO 자격 대신 `eso-homelab-dev`를 쓰므로 운영 자격은 위 로그인으로 따로 본다.
- 자격을 회전하면 그 자리에서 두 곳을 함께 바꾼다. 한쪽만 바꾸면 복구 때 어느 값이 맞는지 모른다.
