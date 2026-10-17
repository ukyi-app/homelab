# T09 시크릿 체계

- 단계: P2 플랫폼 구축 (잠정)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T07
- 선행 결정: D-04 (확정(사용자 2026-10-18): Infisical Cloud Free, identity 4/5), D-20 (옛 시크릿 값 재사용 여부), D-23 (확정: public 유지, 운영 민감 문서는 저장소 밖)
- 연결 AC: AC-P10
- 수행: 에이전트 + 사람 (Infisical 가입, 토큰 재발급, 재발급 뒤 옛 토큰 폐기)

## 목표

시크릿 원본을 Infisical 한곳에 두고, 클러스터에는 ESO로 자동 전달한다.

## 범위

- Infisical 프로젝트, 환경(개발·운영), identity (D-04). Free 요금제다. identity는 5개 한도 중 4개를 쓴다: 사람, `eso-homelab`(운영 ESO), `eso-homelab-vm`(VM 시험 ESO), `gha-homelab-deploy`(배포 App 키, OIDC). `gha-homelab-merge`는 만들지 않는다.
  - 병합 App 키의 원본 자리는 프로젝트 `homelab-ci-merge`다. GitHub environment `automerge`로 가는 Secret Sync와 그 App Connection(fine-grained PAT)은 environment를 만드는 T10에서 설정한다.
  - 더 필요하면 Pro(identity당 월 $20 연간, $23 월간)로 바꾼다. 옛 비상안(VM identity를 시험 때만 만듦)은 영구 여유를 만들지 못해 쓰지 않는다.
  - D-07에서 자동 병합을 하지 않기로 하면 병합 키와 sync가 사라지고 identity는 그대로 4/5다.
- ESO 설치와 Infisical 연결 (Universal Auth 우선).
- ESO 최초 접속 자격증명의 별도 암호화 보관.
- 복구 자산 목록과 복구 순서 (Infisical 장애, 계정 잠김, 클러스터 유실). 저장소가 public이므로(D-23) 목록은 저장소 밖 비공개 위치에 두고, 저장소 문서에는 위치와 항목 이름만 둔다.
- 외부 토큰 재발급과 등록: Cloudflare API, Tailscale OAuth, R2 등. 옛 값을 재사용하지 않는 것이 D-20 추천이며 T05 결정을 따른다. 옛 자격 폐기는 T06의 자격 폐기 표가 맡는다. T06이 `보류(…, T09)`로 넘긴 줄(재사용하는 자산의 자격)은 이 티켓이 새 자격을 등록한 뒤 옛 자격을 폐기해 닫는다. 새 구조에 대응 자격이 없는 것은 새로 발급하지 않는다: cert-manager DNS-01용 Cloudflare 토큰(D-08), GHCR pull PAT(D-29).
- 옛 SOPS age 개인 키: NUC에 `~/.config/sops/age/keys.txt`가 있다. 옛 SOPS 파일의 recipient와 맞으면 옛 공개 저장소 히스토리의 SOPS 파일을 풀 수 있다(일치 여부 미확인). 보존할지 폐기할지는 복구 자산 판단과 D-20에서 정한다. 키 값은 다루지 않는다.
- 같은 앱 안의 시크릿 범위 분리. 같은 봇 안에서도 게시 서버와 작업자의 시크릿 범위를 나눌 수 있는 구조를 이 티켓이 준비한다(명세 §4.2). 작업자 쪽은 T08 격리 작업 공간이 받는 모델 자격 범위다. 봇 시크릿(Discord 토큰, 봇 GitHub App 키, 모델 자격) 등록 자체는 T16~T18에서 한다.
- 회전 절차 초안(`docs/runbooks-public/rotate.md`)에 병합 App 키 회전 순서를 넣는다: (T10 뒤) `homelab github verify` exit 0 확인 → 새 키 발급 → Infisical 값 교체 → environment secret `updated_at`이 교체 시각 이후인지 확인 → 옛 키 삭제. App 키는 만료가 없고 25개까지 동시에 유효해 `deploy-merge` 성공만으로는 새 키 반영을 증명하지 못한다. sync 실패 알림은 프로젝트 Admin 메일로 온다.

## 완료 조건

- identity가 4개(사람, `eso-homelab`, `eso-homelab-vm`, `gha-homelab-deploy`)다.
- 시나리오 6(필수 키 누락 시 명확한 실패), 7(Infisical 장애 중 기존 서비스 유지)을 통과한다.
- 복구 자산 목록이 있다. 저장소가 public이면 목록은 저장소 밖에 있고, 저장소 문서에는 위치와 항목 이름만 있다.
- T06 자격 폐기 표의 `보류(…, T09)` 줄이 모두 `삭제됨` 또는 `유지(이유)`로 바뀌었다. 실행은 [approvals.md](../approvals.md)에 있다. 옛 Telegram 봇 토큰 줄(`보류(D-10, T22)`)은 D-10이 옛 봇을 다시 쓰기로 정한 경우에만 이 티켓이 `mac-uptime-guard` 설정 변경과 함께 닫는다.

## 검증

- 필수 키를 일부러 빼고 배포해 실패 메시지를 확인한다.
- ESO의 Infisical 접근을 끊고 기존 Secret과 서비스가 유지되는지 확인한다.
