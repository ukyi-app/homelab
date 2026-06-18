# 기여 가이드 — Homelab Platform

이 레포는 GitOps 모노레포(SSOT)다: git이 문자 그대로의 단일 진실 공급원이고,
ArgoCD가 클러스터를 수렴시킨다. 클러스터에서 손으로 바꾸는 것은 아무것도 없다.

## 황금률
1. **검증 우선.** 모든 변경은 "변경 전에는 실패하고 변경 후에는 통과하는" 체크와
   함께 나간다. push 전에 로컬에서 `make verify`를 실행한다.
2. **평문 시크릿은 절대 금지.** 플랫폼 시크릿은 `*.enc.yaml`이며, 두 age recipient
   (cluster + recovery, `docs/runbooks/age-keys.md` 참고 — gitignored, owner 로컬 전용이라
   신규 체크아웃에선 이 링크가 열리지 않는다)로 SOPS 암호화한다.
   앱 시크릿은 controller가 봉인하는 **SealedSecrets**를 쓴다(하이브리드 모델 —
   `docs/decisions/0001-secret-management-hybrid.md`). pre-commit 가드 + gitleaks가
   실수를 막는다. 개인키는 절대 커밋하지 않는다
   (`.gitignore`가 `*.agekey`, `keys.txt`, `.env*`를 커버).
3. **환경(env)은 경로에 산다.** `<env>`(`prod`, 이후 `staging`)는 디렉토리
   세그먼트다: `platform/<svc>/<env>/...`, `apps/<name>/deploy/<env>/values.yaml`.
   env 추가 = 디렉토리 추가 + `.sops.yaml` 규칙 블록 추가 — 리팩터링 불필요.
4. **메모리 원장을 존중한다.** 새 워크로드나 리소스 변경은
   `docs/memory-ledger.md`를 갱신한다; limit 합계가 예산을 넘으면 CI가 실패한다
   (`bun run verify:ledger`). 예산은 OOM에서가 아니라 경계에서 고친다.
5. **앱은 불투명한 컨테이너다.** 온보딩 = 공유 `platform/charts/app` 차트용
   `values.yaml`. 이미지 계약: `/healthz`, `/readyz`, :8080 http, :9090 metrics,
   non-root, `migrate` 커맨드. 런타임별 메모리는 강제 온보딩 게이트다.

## 커밋 메시지 (한국어 conventional commits)
`type: 설명` — type ∈ `feat | fix | refactor | style | docs | test | chore`.
AI 마커 금지, Co-Authored-By 금지. 커밋 하나에 논리적 변경 하나.

## 로컬 셋업
- 호스트 툴 설치: **`docs/runbooks-public/toolchain-setup.md`**(tracked — 최소 핀/설치 가이드).
  전체 운영 런북 `docs/runbooks/toolchain.md`은 gitignored(owner 로컬 전용).
- `bun install`
- `pre-commit install`
- 로컬 복호화: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`

## push 전에
```
make ci              # ci.yaml job 'gate'(유일 required check) 8스텝을 로컬에서 그대로 재현
make verify          # (보조) skeleton + 메모리 원장 + sops 왕복 — 로컬 age 키 필요
pre-commit run -a    # (보조) 평문 시크릿 가드 + gitleaks
```
`make ci`가 통과하면 머지를 막는 required check는 통과한다(branch protection `contexts=[gate]`).
verify·pre-commit은 sops/시크릿 안전망이다. `make ci`는 시스템 PATH의 `bun`(1.3.10 핀)을 쓴다 —
설치는 `docs/runbooks-public/toolchain-setup.md` 참고(`m6-tools`가 버전 게이트).
