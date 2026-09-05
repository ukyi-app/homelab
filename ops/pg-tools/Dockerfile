# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# kubectl/psql/rclone 기반 운영(ops) 이미지 (Postgres 백업/복구 + 캐시 백업).
# Milestone 4의 restore-drill CronJob·pg_dump→rclone→R2 헤지와 캐시(Valkey) 백업 CronJob이 사용한다.
# ghcr.io/<owner>/pg-tools:18-rclone으로 게시된다 (Task 6.15 matrix 참조).
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

# ⚠️ 기본값을 주지 않는다. stage-level ARG 기본값은 BuildKit predefined platform arg를 **이긴다**
#   (실측: `ARG TARGETARCH=arm64` + `--platform linux/amd64` → TARGETARCH=[arm64]).
#   기본값이 있으면 amd64 빌드가 OCI config만 amd64이고 아래 kubectl·rclone은 arm64 바이너리인
#   이미지를 만든다 — pull·기동은 성공하고 CronJob이 처음 실행될 때 exec format error로 죽는다.
#   비워두면 TARGETARCH가 비어 URL이 404 → curl -f가 즉시 실패한다(요란한 실패가 옳다).
ARG TARGETARCH

# kubectl 버전 핀. **freshness 소유자는 infra/k3s-bootstrap/versions.env의 K3S_VERSION**이다 —
# 이 값은 거기서 `+k3s1`을 뗀 것과 문자 그대로 같아야 하고, tools/tests/test_pg-tools.bats가 그
# 등식을 강제한다(k3s bump PR이 이 줄을 안 따라오면 그 PR이 red). 독립 소유자를 주면 서버와의
# ±1 minor skew가 다시 열린다.
# ⚠️ 부동 채널(`release/stable`)을 따라가던 옛 형태는 같은 커밋의 두 빌드가 다른 kubectl을 담았고,
#    그 재빌드가 restore-drill을 두 번(8/22·8/25) 결정적으로 죽였다. versions.env:5 "고정 —
#    'stable'/'latest' 금지, cattle 재구축이 결정적이도록"이 이 자리에도 적용된다.
ARG KUBECTL_VERSION=v1.36.3

# rclone 버전 핀. freshness 소유자는 renovate.json customManagers(github-releases: rclone/rclone).
ARG RCLONE_VERSION=v1.75.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release unzip && \
    # PostgreSQL 클라이언트 18 (PGDG) — CNPG 서버 메이저(18)와 정합. pg_dump는 서버보다 낮은 버전을 거부한다.
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends postgresql-client-18 && \
    # kubectl (버전 핀, 아키텍처 인지)
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && \
    # rclone (R2 호환 S3, 버전 핀)
    curl -fsSL "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-${TARGETARCH}.zip" -o /tmp/rclone.zip && \
    unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin && chmod +x /usr/local/bin/rclone && \
    rm -rf /tmp/rclone.zip /var/lib/apt/lists/*

USER 65532:65532
ENTRYPOINT ["/bin/bash", "-c"]
