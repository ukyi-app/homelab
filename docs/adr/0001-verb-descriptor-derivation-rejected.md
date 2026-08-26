# Verb descriptor는 CLI·MCP·스키마 표면을 파생하지 않는다

동사 하나를 추가하면 편집 지점이 ~10곳(verbs.ts 6곳 + homelab.ts 4곳 + mcp.ts +
스키마 allOf 분기 + 골든 픽스처)이라는 마찰이 실재하고, 2026-08 아키텍처 리뷰가
descriptor에 `inputSchema`·`render`를 넣어 세 표면을 파생시키는 deepening을 후보로
올렸다. 기각한다 — homelab-cli 패스의 structure 게이트(r1·r2)가 "op는 Envelope만
반환하고 json/human 등 표현 관심사는 셸의 어댑터·렌더러가 소유한다"를 확정한 직후이고,
그 결정을 마찰 실증 없이 재론하면 다음 리뷰에서 또 뒤집힐 근거도 똑같이 약하다.
totality 검사(homelab.ts·mcp.ts)가 누락은 이미 잡고 있으므로 현재 비용은 중복 편집뿐이다.

재개 조건: 동사 추가가 실제로 잦아져 10곳 편집이 반복 비용으로 실증될 때.
그 전까지 아키텍처 리뷰는 이 후보를 재제안하지 않는다.
