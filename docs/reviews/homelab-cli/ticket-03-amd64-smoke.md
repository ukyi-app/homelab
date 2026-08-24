# ticket 03 — 템플릿 arm64 수리: amd64 스캐폴드→빌드→기동 스모크 증거

릴리스 수용 증거(스펙 "크로스레포 티켓" 절 요구). 수리 PR: <https://github.com/ukyi-app/homelab-app-template/pull/31>
(브랜치 `fix/targetarch-multiarch`, 검증 시점 2026-08-20).

## 병 (수리 전 실측 재현 — amd64 호스트)

- 현행 템플릿으로 api 스캐폴드 후 `docker build --platform linux/amd64` → 빌드 **성공**(조용히).
- 기동: `exec container process '/app/app': Exec format error` — 컨테이너 즉사(ExitCode 1).
- 이미지에서 추출한 바이너리 `file` 검증: `ELF 64-bit LSB executable, ARM aarch64` — "OCI config만
  amd64인 이미지"(reusable-app-build.yaml 주석이 경고한 그 함정).

## 수리 요약

- api/fullstack/worker: build 스크립트 `--target=$BUN_COMPILE_TARGET` 파라미터화 + Dockerfile
  `ARG TARGETARCH`(기본값 금지) case 매핑(arm64→bun-linux-arm64, amd64→bun-linux-x64, 그 외 exit 1)
  + 빌드 스테이지 `--platform=$BUILDPLATFORM` 네이티브 고정(게이트 QEMU 회피, --target 크로스컴파일).
- **site는 파라미터화 대상이 아니다**: build가 `vite build`뿐(하드코딩 자체가 없었음), 산출물은
  arch 중립 정적 파일, SWS 베이스는 멀티아치. 소비처 없는 ARG를 넣지 않았다.
  → doctor의 템플릿 호환성 검사(TARGETARCH 파라미터화 존재)는 **컴파일 아키타입 3종 한정**으로
  정의할 것 — 4종 전수로 짜면 정상 템플릿에서 fail(ticket 04 주의).
- template-ci: 러너 매트릭스(ubuntu-24.04-arm + ubuntu-24.04)로 4개 아키타입 × 양 아치를 각각
  **네이티브** 빌드·기동 스모크 — amd64 무검증 구멍을 CI가 소유.

## green 스모크 (로컬 amd64 호스트, FAILED=0)

| 검증 | 결과 |
|---|---|
| api amd64: 빌드(tsc·bun test 29건 게이트 포함)→기동 | `/healthz`→200 'ok', `/readyz`→200 'ready' |
| fullstack amd64: 빌드(테스트 4건)→기동 | `/healthz`→200 'ok', `/readyz`→200 'ready' |
| site amd64: 빌드→기동(SWS 최소 인자) | `/health` 200, 없는 경로 404, 루트 문서 `<title>` 일치 |
| worker amd64: 빌드(테스트 9건)→기동 | started/tick 로그, SIGTERM 상한 내 종료 |
| 이미지 내 바이너리 `file`(amd64 3종) | 전부 `ELF … x86-64` |
| arm64 크로스 빌드(api·fullstack·worker) | 전부 `ELF … ARM aarch64` |

로그 원문: 세션 스크래치 `green-smoke.log` (스모크 스크립트는 template-ci의 단언을 미러링 —
probe 본문 단언·404 대조군·title 마커·SIGTERM 상한).

## template-ci (PR #31, run 32341341182)

9/9 초록 — scaffold-build 8셀(fullstack/api/site/worker × ubuntu-24.04/ubuntu-24.04-arm) + scaffold-args.
amd64 leg 각 셀이 스캐폴드→빌드(이미지 내 게이트)→기동 스모크를 네이티브로 통과.

## 스캐폴더 비대화형 계약

`--archetype/--name/--yes/--public/--metrics/--no-autodeploy` 파서부 무변경(diff 확인) — 변경은
DOC 산문(멀티아치 정정·BUN_COMPILE_TARGET 안내)뿐.
