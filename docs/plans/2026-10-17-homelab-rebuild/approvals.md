# 외부 변경 승인 기록

[spec.md](spec.md) §11의 외부 변경을 실행할 때마다 한 줄씩 남긴다(AC-X2). 외부 변경의 전제가 되는 사용자 확인(예: T06의 돌아갈 수 없는 지점 확인)과 결정 기록도 여기에 남긴다. 이 문서는 공개 저장소에 들어갈 수 있으므로 토큰·비밀번호·개인 식별 정보는 쓰지 않는다. App ID, PR 번호, 커밋 SHA 같은 식별자만 쓴다.

| 시각 (Asia/Seoul) | 승인 | 대상 | 작업 | 명령 또는 링크 | 티켓·결정 |
|---|---|---|---|---|---|
| 2026-10-17 | 사용자 수행 | Tailscale 전역 DNS | Cloudflare Public DNS를 전역 nameserver에 임시 추가 | Tailscale 관리 콘솔 | C-05 (소급 기록) |
| 2026-10-17 | 사용자 요청 | GitHub `ukyi-app/homelab` Actions | 저장소 Actions 비활성화 (이전 값 `enabled=true`, `allowed_actions=all`) | 이전 세션에서 수행(명령 기록 없음). 2026-10-17 `gh api repos/ukyi-app/homelab/actions/permissions`가 `enabled:false`를 돌려줌 | C-06, T01 (소급 기록) |
| 2026-10-17 | 사용자 결정 | GitHub `ukyi-app/homelab` 공개 범위 | public 유지, 계획·설계 문서 공개 수용(D-23). 이 결정에 따른 push는 T02에서 따로 승인받는다 | 대화 기록 | D-23 |
| 2026-10-17 21:47 | 사용자 승인 | GitHub `ukyi-app/homelab` 태그 | annotated `legacy` 태그 생성. 태그 객체 `594b3839b15a01d34eb2b36128bf30deb3aa79b9` → 커밋 `2d2054aa294b3862de1b1af6eada88fb15e656e6` | `gh api repos/ukyi-app/homelab/git/tags`, `gh api repos/ukyi-app/homelab/git/refs` | T01, AC-P1 |
| 2026-10-17 21:48 | 사용자 승인 | GitHub `ukyi-app/homelab` PR | 열린 PR 10개 닫기(#749, #740, #739, #737, #730, #729, #726, #725, #721, #720). 브랜치는 유지 | `gh pr close <n> --comment "Frozen for rebuild (tag legacy)"` | T01, AC-P1 |
| 2026-10-17 21:48 | 사용자 승인 | GitHub `ukyi-app/homelab` 브랜치 | `rebuild` 브랜치 push(계획 문서 공개, D-23). 원격 `rebuild` = `4bb61ef`. main은 `2d2054a` 그대로 | `git push -u origin refs/heads/rebuild:refs/heads/rebuild` | T02, D-23 |
| 2026-10-18 | 사용자 결정 | Tailscale 전역 DNS, 내부 UI 이름 | D-08 확정: 내부 UI는 Tailscale operator Ingress `<서비스>.<tailnet>.ts.net`, Tailscale DNS (b′)(Override 켬, 전역 nameserver를 NUC AdGuard Home + AdGuard 공용 DNS 2개로, C-05 Cloudflare 4개 삭제, Terraform `tailscale_dns_configuration`). 콘솔·Terraform 변경은 T08에서 따로 승인받는다 | 대화 기록 | D-08 |
| 2026-10-18 | 사용자 결정 | GitHub 보호 설정 관리 방식 | D-28 신규 확정: Terraform root `infra/github`(개선안 T1), owner 로컬 래퍼, `github_rest_api` guard. 적용은 T06·T07(`gh api`)과 T10(import)에서 따로 승인받는다 | 대화 기록 | D-28 |
| 2026-10-18 | 사용자 결정 | Infisical 요금제·identity, 병합 App 키 전달 | D-04 확정: Infisical Cloud Free, identity 4/5(`gha-homelab-merge` 없음). 병합 키는 Secret Sync로 environment `automerge`에 사본 1개(App Connection은 `homelab` 하나로 좁힌 fine-grained PAT). 가입·sync 설정은 T09·T10에서 따로 승인받는다 | 대화 기록 | D-04 |
| 2026-10-18 | 사용자 결정 | org 저장소 공개 정책 | D-29 신규 확정: 앱 저장소는 public만 허용, 앱이 아닌 저장소는 공개하지 않음(`aiops-autodeploy-canary`·`mac-uptime-guard`는 private 보관, 실행 T22) | 대화 기록 | D-29 |
| 2026-10-18 | 사용자 결정 | 봇 저장소 가시성, 옛 aiops 저장소·App | D-13 일부 확정: 봇 코드 저장소 public, 운영 산출물은 저장소 밖이나 private 위치, `ukyi-app/aiops` 저장소와 `ukyi-homelab-aiops` App 제거. 삭제 실행은 T22에서 따로 승인받는다 | 대화 기록 ("aiops는 사용안할거긴해. 참고해. 제거예정.") | D-13(일부) |
| 2026-10-18 | 사용자 결정 | GitHub `ukyi-app/page`, `ukyi-app/trip-mate-api` 저장소와 GHCR 패키지 | 삭제 결정. 실행 대기: 자동 권한 검사가 에이전트의 org·저장소 설정 변경을 막아 사람이 스크립트로 실행할 예정이다. 실행하면 실행 줄을 따로 남긴다 | 대화 기록 ("page, trip-mate-api는 제거예정이야. 제거해버리자.") | D-29 |
| 2026-10-18 | 사용자 결정 | GitHub `ukyi-app/files`, `ukyi-app/homelab-app-template`, org Actions 설정 | 결정 5 확정: `.github/CODEOWNERS`(`* @ukkiee`)와 `app-main` ruleset, secret scanning·push protection, 저장소와 org의 fork PR 승인 `all_external_contributors`. 실행 대기: 자동 권한 검사가 에이전트의 org·저장소 설정 변경을 막아 사람이 저장소 밖 스크립트 `github-hardening.sh`로 실행할 예정이다. 실행 줄에는 출력의 `current_user_can_bypass`(U08 셋째 조건의 첫 실측)를 남긴다 | 대화 기록 | 결정 5 (spec §5.1), D-29 |
| 2026-10-18 11:14 | 사용자 승인 | GitHub `ukyi-app/homelab` 브랜치 | `rebuild` 브랜치 push(T04 설계 문서 공개, D-23). 커밋 `06a080d`, `fd4dca1`, `360f629`. 원격 `rebuild` = `360f629`(이전 `4bb61ef`에서 fast-forward). main은 `2d2054a` 그대로 | `git push --no-follow-tags --recurse-submodules=no origin 360f629:refs/heads/rebuild` | T02, T04, D-23 |
