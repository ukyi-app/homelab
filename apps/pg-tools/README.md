# pg-tools

운영(ops) 이미지: `kubectl` + `psql` (postgresql-client-16) + `rclone` + `curl`.

CI(Task 6.15 matrix)가 `ghcr.io/ukyi-app/pg-tools:16-rclone`과 `:sha-<gitsha>`로
게시한다. Milestone 4의 restore-drill CronJob과 `pg_dump → rclone → R2` 헤지가
이 이미지를 참조하며, M4의 LIVE drill 수용 기준은 이 이미지의 존재를 전제로 한다.
