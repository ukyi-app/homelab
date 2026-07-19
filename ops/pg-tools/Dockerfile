# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# kubectl/psql/rclone 기반 운영(ops) 이미지 (Postgres 백업/복구 + 캐시 백업).
# Milestone 4의 restore-drill CronJob·pg_dump→rclone→R2 헤지와 캐시(Valkey) 백업 CronJob이 사용한다.
# ghcr.io/<owner>/pg-tools:18-rclone으로 게시된다 (Task 6.15 matrix 참조).
FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

ARG TARGETARCH=arm64
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
    # kubectl (stable 채널, 아키텍처 인지)
    curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && \
    # rclone (R2 호환 S3)
    curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${TARGETARCH}.zip" -o /tmp/rclone.zip && \
    unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin && chmod +x /usr/local/bin/rclone && \
    rm -rf /tmp/rclone.zip /var/lib/apt/lists/*

USER 65532:65532
ENTRYPOINT ["/bin/bash", "-c"]
