# Observability bootstrap (one-time external dependencies)

The observability stack is fully GitOps-managed EXCEPT one off-node dependency that, by
definition (R8), cannot live on the monitored node: the healthchecks.io dead-man's-switch.

## 1. healthchecks.io account + check (the off-node detector)
1. Create a free account at https://healthchecks.io (or self-host on a DIFFERENT box — never this node).
2. Create a check named `homelab-watchdog`:
   - Period: 1 minute. Grace: 3 minutes.
   - (Matches Alertmanager Watchdog `repeat_interval: 1m`, Task 5.8.)
3. Copy the ping URL `https://hc-ping.com/<HC_UUID>`.
4. Add an escalation integration on the check (email/Telegram/phone) — this is the page that
   fires when the WHOLE node is down and in-cluster Alertmanager cannot reach you.

## 2. Put the URL + Telegram creds into the M2-owned SOPS secret
These values live in the M2-seeded `platform/victoria-stack/prod/alerting.enc.yaml`
(Secret `alerting-secrets`, keys `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `HEALTHCHECKS_URL`).
M2's `seed-secrets.sh` is the single producer; set/refresh:
- `HEALTHCHECKS_URL: https://hc-ping.com/<HC_UUID>`
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (from @BotFather + the target chat).
Re-run the M2 seed (or `sops --in-place` edit through M2's flow); M5 does NOT own this file.

## 3. Telegram bot (in-cluster alert path)
1. @BotFather → `/newbot` → token.
2. Add the bot to the target chat/channel; resolve the numeric chat_id
   (`curl https://api.telegram.org/bot<TOKEN>/getUpdates`).

## 4. Verify the switch is ARMED
After ArgoCD syncs the stack:
- healthchecks.io dashboard shows `homelab-watchdog` flipping to **up** within ~1 minute.
- To TEST the dead-man path: pause the relay (`kubectl -n observability scale deploy/deadmanswitch-relay --replicas=0`),
  wait >grace (3m), confirm healthchecks.io pages you, then `--replicas=1` to re-arm.

## Re-arm / DR note
On a full rebuild (`make bootstrap`), the SAME healthchecks.io URL is reused (it lives in the
committed SOPS secret), so the switch re-arms automatically once the relay pod is back.
