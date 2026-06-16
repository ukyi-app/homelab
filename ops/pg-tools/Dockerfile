# syntax=docker/dockerfile:1
# kubectl/psql/rclone 기반 운영(ops) 이미지 (Postgres 백업/복구 + 캐시 백업).
# Milestone 4의 restore-drill CronJob·pg_dump→rclone→R2 헤지와 캐시(Valkey) 백업 CronJob이 사용한다.
# ghcr.io/<owner>/pg-tools:16-rclone으로 게시된다 (Task 6.15 matrix 참조).
FROM debian:bookworm-slim

ARG TARGETARCH=arm64
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release unzip && \
    # PostgreSQL 클라이언트 16 (PGDG)
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends postgresql-client-16 && \
    # kubectl (stable 채널, 아키텍처 인지)
    curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && \
    # rclone (R2 호환 S3)
    curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${TARGETARCH}.zip" -o /tmp/rclone.zip && \
    unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin && chmod +x /usr/local/bin/rclone && \
    rm -rf /tmp/rclone.zip /var/lib/apt/lists/*

USER 65532:65532
ENTRYPOINT ["/bin/bash", "-c"]
