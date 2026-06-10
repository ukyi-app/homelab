# Memory Ledger (SSOT, CI-gated)

VM cap = 11 GiB. We reserve headroom for kernel page cache + burst, so the
enforced **allocatable** budget for pod LIMITS is 8704 MiB (8.5 GiB).
Onboarding a new app CI-fails if the limit total exceeds this (design §10, R2).
This is the ONE ledger format/validator; M6's onboarding gate reuses
`pnpm verify:ledger` against this file — it does not define a second ledger.

<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->

| component                          | namespace      | req_mi | limit_mi |
|------------------------------------|----------------|-------:|---------:|
| <!-- ledger:row --> k3s+os+coredns | kube-system    |   1075 |     1740 |
| <!-- ledger:row --> argocd         | argocd         |    594 |     1474 |
| <!-- ledger:row --> cnpg           | database       |    952 |     1485 |
| <!-- ledger:row --> cert-manager   | cert-manager   |     60 |      180 |
| <!-- ledger:row --> observability  | observability  |    850 |     1966 |
| <!-- ledger:row --> edge           | edge           |    236 |      594 |
| <!-- ledger:row --> apps           | prod           |    369 |      737 |
| <!-- ledger:row --> media          | prod           |    133 |      389 |

**Totals:** req ≈ 4269 Mi · limit ≈ 8565 Mi (must stay ≤ 8704 Mi).

## How to update
Adding/resizing a component: edit its row's `req_mi`/`limit_mi` (or append a new
marked table row carrying the row-marker comment), then run `pnpm verify:ledger`.
CI runs the same check on every PR; it fails loudly at the budget boundary, not
at OOM.
