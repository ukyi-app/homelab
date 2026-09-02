# 호스트 툴체인 — 최소 설치 가이드 (tracked)

신규 체크아웃에서 로컬 검증(`make ci`/`make verify`/`make chart-test`)을 돌리는 데 필요한
호스트 도구를 정리한다. 상세 운영 런북(`docs/runbooks/toolchain.md`)은
gitignored(owner 로컬 전용)이므로, **도구 설치 단계에 한해** 이 문서가 자급 대체본이다.

> **정확한 CI 핀은 여기 없다 — `.github/actions/setup-toolchain/action.yml`을 직접 읽어라**
> (각 `inputs.*.description`이 버전을 적고, 다운로드 줄이 sha256을 검증한다).
> 이 문서가 그 값을 다시 적으면 **아무도 대조하지 않는 사본**이 되어 반드시 드리프트한다 —
> 실제로 그랬다(bats를 `apt(>=1.11)`로, kubeseal을 "명시 핀 없음"으로 적고 있었고, 이 문서를
> 대조하는 게이트는 레포 전역에 0건이다). 그래서 CI 핀 열을 **지웠다**: 신규 체크아웃에도
> `action.yml`은 이미 있으므로 자급성 손실이 0이다.
>
> 아래 표가 소유하는 것은 **로컬 최소 버전**(`Makefile`의 `m6-tools` 타겟 — 설치 후
> `make m6-tools`로 검증) + 설치 힌트뿐이다. 로컬 최소는 **하한**이고 CI 핀은 **정확 핀**이라
> 둘은 같은 값이 아니며, 둘을 대조하는 게이트도 없다(그 차이는 의도된 것이다 — 예: helm은
> CI가 고정 핀이고 로컬은 major 4.x도 통과한다).
>
> k3s/local-path 등 **클러스터·런타임** 버전은 `infra/k3s-bootstrap/versions.env`에 있다
> (호스트 dev 도구가 아니므로 아래 목록과 별개 — 부트스트랩 시에만 필요).

## 필수 도구와 핀

| 도구 | 로컬 최소(`m6-tools`) | 용도 | 설치 힌트 |
|---|---|---|---|
| **bun** | `1.3.14` (핀) | tools/`*.ts`·`*.mts` 실행 + 패키지/스크립트 런타임 | `curl -fsSL https://bun.sh/install \| bash`(시스템 PATH) 또는 `mise use -g bun@1.3.14` |
| **Node.js** | `>=22.18`(app-shared 계약 하한) | app-shared `*.mts`(seal-secret 벤더·env-example homelab-로컬) node strip-types 실행 — 앱 레포 `bun run secret:seal` 경로 | `mise use -g node@22` 또는 `brew install node` |
| **helm** | `>=3.16` | 공유 차트 렌더(chart-test) | `brew install helm` (CI는 고정 핀 — major 변동 시 chart-test 파손 위험) |
| **kustomize** | (게이트 없음) | KSOPS 풀 렌더(`make render`) | `brew install kustomize` |
| **kubeconform** | `>=0.6.7` | 매니페스트 스키마 검증(chart-test) | `brew install kubeconform` |
| **conftest** | (게이트 없음, 필수) | 메모리 원장 OPA 정책(`verify:ledger`) | `brew install conftest` (Open Policy Agent) |
| **bats** | `>=1.11` | bats 테스트 게이트(`run-bats.sh`) | `brew install bats-core` (CI는 apt가 아니라 커밋 SHA로 clone한다 — macOS 기본 bash 3.2 함정 주의) |
| **shellcheck** | (게이트 없음) | `*.sh` 린트(`make ci`) | `brew install shellcheck` (버전이 다르면 info 체크가 CI와 드리프트) |
| **yq** | `v4` | YAML 파싱(여러 스크립트/게이트) | `brew install yq` (mikefarah v4 — go-yq) |
| **jq** | 임의 버전 | JSON 처리 | `brew install jq` |
| **sops** | (게이트 없음) | 플랫폼 `*.enc.yaml` 복호/봉인 | `brew install sops` |
| **age** | (게이트 없음) | sops age 키(복호화) | `brew install age` |

추가로 필요(게이트엔 없지만 실사용):

- **terraform** — `make tf-validate`/IaC 루트용. **코어 핀은 루트마다 독립이다**(state writer가
  다르므로 한 값으로 통일하는 것이 오히려 고장이다 — `docs/traps-detail.md` 「owner 로컬 apply
  루트는 …」). 값을 여기 적지 않는다: 각 루트 `infra/<root>/versions.tf`의 `required_version`과
  워크플로의 `terraform_version`(`iac.yaml`·`tf-reconcile.yaml`)을 보라.
- **kubeseal** — 앱/리소스 시크릿 봉인(`seal-secret.mts`·provision-*). CI 핀은 `action.yml`의
  `kubeseal` input이고, 그 값은 **컨트롤러 appVersion과 lockstep**이다
  (`platform/sealed-secrets/prod/helmrelease.yaml`이 SSOT, `tests/gates/test_setup-toolchain-kubeseal.bats`가 강제).
  로컬도 같은 버전을 쓰는 것을 권장한다.
- **actionlint** — 워크플로 정적 검사. **CI 전용**이라 `m6-tools` 필수가 아니다. 로컬에 없으면
  `make ci`가 그 스텝을 미평가 원장에 남기고 마지막에 `SKIP:` 마커 + exit 4를 낸다(초록으로 끝나지 않는다).
- **docker**(OrbStack) — telegram-render-e2e 게이트·로컬 dev Postgres(`bun run db:up`). 없으면 위와 같은 SKIP 경로.
- **kubectl** — 라이브 클러스터 운영 타겟(`make argo-*`/`render`/posture). 클러스터 minor와 ±1 권장.
- **pre-commit** — 평문 시크릿 가드 + gitleaks(`pre-commit run -a`). `brew install pre-commit` 후 `pre-commit install`.

## 설치 후 검증

```bash
make m6-tools        # helm/kubeconform/bats/bun(1.3.14)/yq/jq 최소 버전 게이트
bun install      # 워크스페이스 의존성
pre-commit install   # 시크릿 가드 훅
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # 로컬 복호화(age 키는 owner 보관)
make ci              # required check(gate)를 로컬 재현 — 차이는 policy/ci-parity.json이 계상
```

`make`/git hook/Claude Bash는 셸 rc를 source하지 않는다 — **레포는 PATH를 손대지 않으므로**
mise 사용자는 셸 rc 밖에서도 도구가 보이도록 직접 활성화해야 한다(안 하면 exit 127이 난다).

> 이 레포에는 `.tool-versions`/`mise.toml`이 커밋돼 있지 않다 — 로컬 최소는 위 표, 정확한 CI 핀은
> `.github/actions/setup-toolchain/action.yml`이 1차 출처다.
