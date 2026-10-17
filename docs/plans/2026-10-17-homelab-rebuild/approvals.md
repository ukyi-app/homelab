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
