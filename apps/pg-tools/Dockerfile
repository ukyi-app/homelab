# syntax=docker/dockerfile:1
# Operations image for CNPG backup/restore tooling.
# Consumed by Milestone 4's restore-drill CronJob and the pg_dump→rclone→R2 hedge.
# Published as ghcr.io/<owner>/pg-tools:16-rclone (see Task 6.15 matrix).
FROM debian:bookworm-slim

ARG TARGETARCH=arm64
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release unzip && \
    # PostgreSQL client 16 (PGDG)
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends postgresql-client-16 && \
    # kubectl (stable, arch-aware)
    curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && \
    # rclone (R2-compatible S3)
    curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${TARGETARCH}.zip" -o /tmp/rclone.zip && \
    unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin && chmod +x /usr/local/bin/rclone && \
    rm -rf /tmp/rclone.zip /var/lib/apt/lists/*

USER 65532:65532
ENTRYPOINT ["/bin/bash", "-c"]
