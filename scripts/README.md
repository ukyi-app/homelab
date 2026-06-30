# scripts/ — 운영 셸 스크립트 인덱스

부트스트랩·CI 게이트·시크릿 봉인·DR 운영 스크립트 모음. 각 스크립트의 **호출 경로**와
**파괴성**을 명시한다. 크게 세 부류:

- **CI 게이트** — `make verify`/`make ci` 또는 `ci.yaml`/`verify.yaml`이 호출하는 순수 검사(읽기 전용).
- **시크릿/부트스트랩** — `make` 타겟이 호출, 라이브 클러스터에 쓰거나 봉인본을 산출.
- **DR/owner 전용(파괴적)** — Makefile/워크플로에 배선 없이 **사람이 직접 실행**. 잘못 쓰면 데이터 유실.

> CNPG 복구·DR 절차 상세는 (gitignored) `docs/runbooks/restore.md`·`docs/runbooks/host-substrate.md` 참고.

## CI 게이트 (읽기 전용 검사)

- **`check-skeleton.sh`** — 필수 디렉토리 스켈레톤 존재 검사. `make verify`·**`bun run verify:skeleton`**·
  `ci.yaml`(gate)이 호출. 라이브 무관.
- **`check-bats-accounting.sh`** — 모든 추적 `test_*.bats`가 정확히 한 도메인(gate / chart-test /
  `.ci-exclude`)에 배정됐는지 검사(고아·이중소유 차단). `make verify`가 호출. `run-bats.sh --list`를 읽는다.
- **`check-app-deploy.sh`** — `apps/<name>/deploy/prod/` 배포 계약 가드. 필수 산출물 목록을
  `tools/app-deploy-schema.json`(SSOT)에서 읽어 강제(`source-repo` 누락/공백 = fail-closed). `make verify`가 호출.
  인레포 앱 0개면 vacuous pass.
- **`run-bats.sh`** — **단일 테스트 수집·실행기(required GATE)**. `make ci`·`ci.yaml`(gate)이 공통 호출(이중 SSOT 제거).
  스코프 = git-tracked `test_*.bats` − `platform/charts/*`(chart-test 별도) − `tests/.ci-exclude`. `--list`는 수집 목록만.
- **`verify-secrets.sh`** — 추적 `*.enc.yaml` 무결성(암호화됨 + age recipient 정확히 2개 + 복호 가능)
  검사. **`make verify-secrets`**가 호출. 값 비출력; age 키 없으면(=CI) 복호 단계만 스킵하고 구조 검사는 수행.
- **`verify-traps.sh`** — `docs/traps.md` enforcement 원장이 가리키는 guard 파일이 실재하는지 검사
  (가드 소실 드리프트 = 거짓 안심 차단). **`make verify-traps`**가 호출. 순수 파일 존재 검사.
- **`ledger-to-json.sh`** — `docs/memory-ledger.md` 표를 JSON으로 변환(conftest 입력 생성). **`bun run verify:ledger`**·
  `make verify`·`ci.yaml`(gate)이 호출(출력을 `conftest test … policy/ledger.rego`로 파이프). 라이브 무관.
- **`sops-guard.sh`** — 인자로 받은 `*.enc.yaml`이 실제 sops 암호화됐는지(평문 누출 차단) 검사.
  pre-commit 가드 훅이 호출(staged 파일). `make`/워크플로 배선 아님.

## 시크릿 / 부트스트랩 (라이브 쓰기·봉인본 산출)

- **`bootstrap.sh`** — 멱등 DR 진입점: argocd NS + sops-age Secret + ArgoCD + root app 설치.
  **`make bootstrap`**이 호출(+ `bootstrap-deadmanswitch` 선행). 라이브 클러스터에 적용.
- **`seed-secrets.sh`** — terraform output + `.env.secrets`에서 SOPS 암호화 시드 시크릿 생성.
  **`make seed-secrets`**가 호출(`.env.secrets`를 source한 뒤). R2/telegram 등 키를 env로 요구.
- **`seal-adguard-auth.sh`** — `.env.secrets`의 `ADGUARD_PASSWORD`를 bcrypt로 봉인 → `adguard-auth`
  SealedSecret(edge NS). **`make seal-adguard-auth`**가 호출. 평문·해시 모두 stdout 비출력(봉인본만 산출물).
- **`secret-cert-check.sh`** — 봉인 전 preflight: 커밋된 `tools/sealed-secrets-cert.pem`이 라이브
  컨트롤러 cert와 fingerprint 일치하는지(stale 차단) 검사. **`make secret-cert-check`**가 호출.
  read-only(fetch만); 오프라인이면 검증 스킵(에러 아님). `sealing-key-dr-gate.sh` 로직 재사용.

## DR / owner 전용 — 파괴적 (직접 실행, Makefile/워크플로 배선 주의)

- **`reset-pg-r2-archive.sh`** — **파괴적**. fresh initdb `pg`가 R2의 옛 barman 아카이브와 충돌할 때
  serverName `pg` 아카이브(base/+wals/)만 정리해 아카이빙 재개. **`make reset-pg-archive`**가 호출하되
  **기본 dry-run** — 실제 삭제는 `ARGS=--purge`. 라이브 ObjectStore에서 bucket/endpoint를 읽음.
- **`dr-drill.sh`** — **극도로 파괴적(owner 전용)**. OrbStack VM(cattle)을 DESTROY→RECREATE하고
  git+R2+age 키만으로 전 플랫폼 재구축 + R2 DB 복구(canary 일치)를 증명하는 풀 DR 드릴(R5). Makefile/워크플로
  **배선 없음** — 직접 실행. 파괴 전 canary 캡처 + 복구 증명 후에만 노드 파괴. `sealing-key-dr-gate.sh`를 source.
- **`sealing-key-dr-gate.sh`** — sealing-key DR 게이트 **라이브러리(source 전용 — top-level 실행 없음)**.
  `dr-drill.sh`가 source한다. SealedSecret 소비자/커밋 cert가 있으면 파괴 전 백업·실복원 증명 + 재구축 후
  전수 unseal + cert 일치를 강제(권위 소스 조회 실패 = fail-closed). `make`/워크플로 직접 호출 아님.
- **`backup-sealed-secrets-key.sh`** — **owner 전용(DR 불변식)**. SealedSecrets 컨트롤러 sealing key를
  out-of-band 백업. `scripts/backup-sealed-secrets-key.sh <outdir>`(백업 생성, outdir는 git 밖) /
  `--verify <outdir>`(최신 백업이 라이브 키 셋을 담는지 — 회전 게이트). `sealing-key-dr-gate.sh`가 `--verify`로 호출.
  평문 private key를 디스크에 비기록(kubectl→sops 직행), git 작업트리 안 보관 거부.
