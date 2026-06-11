# 기여 가이드 — Homelab Platform

이 레포는 GitOps 모노레포(SSOT)다: git이 문자 그대로의 단일 진실 공급원이고,
ArgoCD가 클러스터를 수렴시킨다. 클러스터에서 손으로 바꾸는 것은 아무것도 없다.

## 황금률
1. **검증 우선.** 모든 변경은 "변경 전에는 실패하고 변경 후에는 통과하는" 체크와
   함께 나간다. push 전에 로컬에서 `make verify`를 실행한다.
2. **평문 시크릿은 절대 금지.** 시크릿은 `*.enc.yaml`이며, 두 age recipient
   (cluster + recovery, `docs/runbooks/age-keys.md` 참고)로 SOPS 암호화한다.
   pre-commit 가드 + gitleaks가 실수를 막는다. 개인키는 절대 커밋하지 않는다
   (`.gitignore`가 `*.agekey`, `keys.txt`, `.env*`를 커버).
3. **환경(env)은 경로에 산다.** `<env>`(`prod`, 이후 `staging`)는 디렉토리
   세그먼트다: `platform/<svc>/<env>/...`, `apps/<name>/deploy/<env>/values.yaml`.
   env 추가 = 디렉토리 추가 + `.sops.yaml` 규칙 블록 추가 — 리팩터링 불필요.
4. **메모리 원장을 존중한다.** 새 워크로드나 리소스 변경은
   `docs/memory-ledger.md`를 갱신한다; limit 합계가 예산을 넘으면 CI가 실패한다
   (`pnpm verify:ledger`). 예산은 OOM에서가 아니라 경계에서 고친다.
5. **앱은 불투명한 컨테이너다.** 온보딩 = 공유 `platform/charts/app` 차트용
   `values.yaml`. 이미지 계약: `/healthz`, `/readyz`, :8080 http, :9090 metrics,
   non-root, `migrate` 커맨드. 런타임별 메모리는 강제 온보딩 게이트다.

## 커밋 메시지 (한국어 conventional commits)
`type: 설명` — type ∈ `feat | fix | refactor | style | docs | test | chore`.
AI 마커 금지, Co-Authored-By 금지. 커밋 하나에 논리적 변경 하나.

## 로컬 셋업
- 호스트 툴 설치: `docs/runbooks/toolchain.md`.
- `pnpm -w install`
- `pre-commit install`
- 로컬 복호화: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`

## push 전에
```
make verify          # skeleton + ledger + sops round-trip
pnpm verify:ledger   # memory budget gate
pre-commit run -a    # secret guard + gitleaks
```
