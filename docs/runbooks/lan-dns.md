# Runbook — LAN DNS (split-horizon via AdGuard) — R7

AdGuard Home is LAN DNS only (ad-block + split-horizon). The router keeps DHCP.
AdGuard is the most resettable component, so it must NEVER be load-bearing for
internet access. Two non-negotiable router settings make ad-block best-effort:

## 1. DHCP option 6 (DNS server) → AdGuard
On the router's LAN/DHCP settings, set the advertised DNS server (DHCP
option 6) to the AdGuard `adguard-dns` LoadBalancer address:
- Primary DNS: <ADGUARD_LAN_IP> =
  `kubectl -n edge get svc adguard-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
  (servicelb publishes udp/tcp 53 on the VM node IP, which OrbStack maps to the Mac
  mini host — give the Mac mini a DHCP RESERVATION so this address is stable).
- VERIFY from a REAL non-cluster LAN device before relying on it:
  `dig +short @<ADGUARD_LAN_IP> cloudflare.com` must return an answer.
- This is what makes every household device resolve through AdGuard.

## 2. Secondary upstream DNS on the router → 1.1.1.1  (the SPOF guard)
Set the router's SECONDARY DNS to 1.1.1.1 (Cloudflare).
- When the VM / AdGuard is down, the household degrades to "no ad-block",
  NOT "no internet". This is the entire point of R7.
- Do NOT set both primaries to AdGuard with no fallback.

## 3. Split-horizon verification
From a LAN device, `*.int.<DOMAIN>` must resolve to the STABLE Tailscale IP of
the operator-exposed Traefik (Task 3.7), so internal apps work on-LAN and
off-LAN identically:
```
dig +short whoami.int.<DOMAIN>
# <STABLE_TAILSCALE_IP>
```
If it returns the VM IP instead, the AdGuard rewrite is stale — re-read
`tailscale ip -4 homelab` and update platform/adguard/prod/adguardhome.yaml.

## 4. Failure drill (do this once)
- Stop AdGuard (`kubectl -n edge scale deploy/adguard --replicas=0`).
- Confirm a LAN device still resolves `cloudflare.com` (via 1.1.1.1 fallback).
- Restore (`--replicas=1`).
