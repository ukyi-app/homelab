# skopeo ops 이미지

`victoria-stack`의 두 exporter가 GHCR 이미지 digest를 조회하는 데 쓰는 skopeo 런타임이다.

| 항목 | 값 |
|---|---|
| 게시처 | `ghcr.io/<owner>/skopeo:alpine` |
| base | `alpine:3.22`(Docker Hub, digest 핀) |
| 담긴 것 | `skopeo`(1.20.x) · `curl` · `ca-certificates` |
| 소비자 | `platform/victoria-stack/prod/digest-exporter.yaml` · `gha-liveness-exporter.yaml` |

## 왜 자체 이미지인가

`quay.io/skopeo/stable`의 **릴리스 태그가 불변이 아니다.** 상류가 같은 태그를 재푸시하고 옛
매니페스트를 GC한다 — 2026-08-18(#518) · 08-21(#528) · 08-24(#531)로 6일에 세 번 났다.
`tests/gates/image-pin-liveness.sh`가 라이브 레지스트리를 조회하므로, GC가 날 때마다
**브랜치와 무관하게 모든 PR의 `gate`가 red**가 된다. 재핀 PR은 증상 대응일 뿐이고 3일마다 돌아온다.

Docker Hub는 옛 매니페스트를 GC하지 않는다 — 같은 레포의 `ops/pg-tools`가 쓰는
`debian:bookworm-slim` 핀이 오래 살아 있는 것이 그 증거다.

## 버전을 올릴 때

`FROM`의 alpine digest는 Renovate가 갱신한다. skopeo 자체는 alpine 저장소의 버전을 따르므로
`apk` 버전을 고정하지 않는다(`ops/pg-tools`가 `postgresql-client-18`을 다루는 방식과 같다).
소비자가 쓰는 것은 `skopeo inspect`뿐이라 마이너 차이에 민감하지 않다.

⚠️ **소비자는 non-root(65532)로 돈다.** apk 설치물은 world-readable이라 그대로 실행되지만,
이미지에 `USER`를 박지는 않는다 — uid는 소비자 매니페스트의 `runAsUser`가 소유한다.
