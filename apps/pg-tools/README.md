# pg-tools

Operations image: `kubectl` + `psql` (postgresql-client-16) + `rclone` + `curl`.

Published by CI (Task 6.15 matrix) as `ghcr.io/ukyi-app/pg-tools:16-rclone` and
`:sha-<gitsha>`. Milestone 4's restore-drill CronJob and the `pg_dump → rclone → R2`
hedge reference this image; M4's LIVE-drill acceptance is gated on this image existing.
