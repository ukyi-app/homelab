# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# skopeo 운영(ops) 이미지 — victoria-stack의 digest-exporter·gha-liveness-exporter가 쓴다.
# ghcr.io/<owner>/skopeo:alpine으로 게시된다.
#
# ⚠️ **왜 quay.io/skopeo/stable을 안 쓰는가**: 그 릴리스 태그가 **불변이 아니다.**
#    상류가 `v1.22.2` 같은 태그를 주기적으로 재푸시하고 옛 매니페스트를 GC한다 —
#    2026-08-18(#518) · 08-21(#528) · 08-24(#531)로 6일에 세 번 났고, 세 번째는 재핀 PR을
#    머지한 **같은 세션 안에서** 죽었다. `image-pin-liveness`가 라이브 레지스트리를 보므로
#    그때마다 **브랜치와 무관하게 모든 PR의 gate가 red**가 된다. 재핀은 증상 대응이었다.
#    ⇒ 상류 GC와 무관한 자기 소유 이미지로 옮긴다. 이 파일의 base는 Docker Hub의 alpine이고,
#      Docker Hub는 옛 매니페스트를 GC하지 않는다(같은 레포의 `debian:bookworm-slim` 핀이
#      오래 살아 있는 것이 그 증거다).
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

# skopeo — `inspect --authfile`을 쓴다(소비자 두 곳 모두). curl은 vmsingle push용이고,
# ca-certificates는 GHCR·vmsingle TLS 검증에 필요하다.
# ⚠️ **coreutils가 반드시 필요하다** — gha-liveness-exporter의 run.sh가 GitHub 타임스탬프를
#    `date -u -d "$ISO" +%s`로 파싱하는데, 이는 **GNU date 문법**이다. alpine 기본 date는 busybox라
#    ISO8601을 `date: invalid date`로 거부한다(실측: EPOCH가 빈 값이 되고 `2>/dev/null || true`가
#    실패를 삼켜 워크플로 나이 계산이 **조용히 깨진다** — heartbeat 신선도 판정이 무력화된다).
#    예전 quay.io/skopeo/stable(Fedora base)엔 GNU coreutils date가 있었으므로 미러 전환에서 드러난
#    회귀다(적대 검증 2026-08-24). digest-exporter는 `date +%s`만 써서 무관하지만, 같은 이미지를
#    공유하므로 여기서 GNU date를 보장한다.
# ⚠️ 소비자는 non-root(65532)로 돈다 — apk 설치물은 world-readable이라 그대로 실행된다(실측).
RUN apk add --no-cache skopeo curl ca-certificates coreutils

# ⚠️ USER를 여기서 고정하지 않는다 — 소비자 매니페스트가 `runAsUser: 65532`를 이미 강제하고,
#    이미지가 uid를 박으면 그 값이 두 곳에 흩어져 드리프트 원이 된다(PSA restricted는 매니페스트가 소유).
