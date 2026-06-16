# 호스트 툴체인 — 최소 설치 가이드 (tracked)

신규 체크아웃에서 로컬 검증(`make ci`/`make verify`/`make chart-test`)을 돌리는 데 필요한
호스트 도구와 **고정 버전**을 정리한다. 상세 운영 런북(`docs/runbooks/toolchain.md`)은
gitignored(owner 로컬 전용)이므로, **도구 설치 단계에 한해** 이 문서가 자급 대체본이다.

> 버전 SSOT는 두 곳이다 — 둘은 정합한다:
> - **CI 핀**: `.github/actions/setup-toolchain/action.yml`(차트/정책/시크릿 도구의 정확한 버전)
> - **로컬 최소 버전 게이트**: `Makefile`의 `m6-tools` 타겟(설치 후 `make m6-tools`로 검증)
>
> k3s/local-path 등 **클러스터·런타임** 버전은 `infra/k3s-bootstrap/versions.env`에 있다
> (호스트 dev 도구가 아니므로 아래 목록과 별개 — 부트스트랩 시에만 필요).

## 필수 도구와 핀

| 도구 | CI 핀(`setup-toolchain`) | 로컬 최소(`m6-tools`) | 용도 | 설치 힌트 |
|---|---|---|---|---|
| **Node.js** | (러너 기본) | `>=22` | tools/`*.mjs` 실행 | `mise use -g node@22` 또는 `brew install node` |
| **pnpm** | (별도) | `11` (핀 `pnpm@11.6.0`) | 워크스페이스/스크립트 | `corepack enable && corepack prepare pnpm@11.6.0 --activate` 또는 `mise use -g pnpm@11.6.0` |
| **helm** | `v3.16.4` | `>=3.16` | 공유 차트 렌더(chart-test) | `brew install helm` (버전 확인 — major 변동 시 chart-test 파손 위험) |
| **kustomize** | `v5.4.3` | (게이트 없음) | KSOPS 풀 렌더(`make render`) | `brew install kustomize` |
| **kubeconform** | `v0.6.7` | `>=0.6.7` | 매니페스트 스키마 검증(chart-test) | `brew install kubeconform` |
| **conftest** | `v0.56.0` | (게이트 없음, 필수) | 메모리 원장 OPA 정책(`verify:ledger`) | `brew install conftest` (Open Policy Agent) |
| **bats** | apt(`>=1.11`) | `>=1.11` | bats 테스트 게이트(`run-bats.sh`) | `brew install bats-core` (1.11+ 확인 — macOS 기본 bash 3.2 함정 주의) |
| **shellcheck** | `v0.11.0` | (게이트 없음) | `*.sh` 린트(`make ci`) | `brew install shellcheck` (버전이 다르면 info 체크가 CI와 드리프트) |
| **yq** | `v4.44.6` | `v4` | YAML 파싱(여러 스크립트/게이트) | `brew install yq` (mikefarah v4 — go-yq) |
| **jq** | (러너 기본) | 임의 버전 | JSON 처리 | `brew install jq` |
| **sops** | `v3.9.4` | (게이트 없음) | 플랫폼 `*.enc.yaml` 복호/봉인 | `brew install sops` |
| **age** | latest | (게이트 없음) | sops age 키(복호화) | `brew install age` |

추가로 필요(게이트엔 없지만 실사용):

- **terraform** — `make tf-validate`/IaC 루트용. 버전 핀은 각 루트 `.terraform.lock.hcl` 참고
  (lock 첫 커밋은 라이브 state writer 버전 이상으로 핀해야 한다 — `AGENTS.md` 함정 참고). (확인 필요: 정확한 코어 버전 핀은 별도 문서 없음)
- **kubeseal** — 앱/리소스 시크릿 봉인(`seal-secret.mjs`·provision-*). 컨트롤러 버전과 정합 권장. (확인 필요: 명시 핀 없음 — 라이브 컨트롤러 cert로 봉인)
- **docker**(OrbStack) — telegram-render-e2e 게이트·로컬 dev Postgres(`pnpm db:up`). 없으면 해당 게이트 스킵.
- **kubectl** — 라이브 클러스터 운영 타겟(`make argo-*`/`render`/posture). 클러스터 minor와 ±1 권장.
- **pre-commit** — 평문 시크릿 가드 + gitleaks(`pre-commit run -a`). `brew install pre-commit` 후 `pre-commit install`.

## 설치 후 검증

```bash
make m6-tools        # helm/kubeconform/bats/node/pnpm/yq/jq 최소 버전 게이트
pnpm -w install      # 워크스페이스 의존성
pre-commit install   # 시크릿 가드 훅
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # 로컬 복호화(age 키는 owner 보관)
make ci              # required check(gate) 8스텝을 로컬 재현 — 통과하면 머지 게이트 통과
```

`make`/git hook/Claude Bash는 셸 rc를 source하지 않아 mise 활성화 PATH가 없을 수 있다 —
Makefile이 mise shim(`~/.local/share/mise/shims`)이 있으면 PATH 앞에 멱등 보강한다(node/pnpm
exit 127 방지). mise를 쓰지 않으면 무영향.

> 이 레포에는 `.tool-versions`/`mise.toml`이 커밋돼 있지 않다 — 위 표가 버전의 1차 출처다.
