# ghcr-pull

**역할** — private GHCR 컨테이너 패키지 pull용 `imagePullSecret`(`prod` 네임스페이스). 인레포 앱
이미지(`ghcr.io/ukyi-app/<app>`)는 첫 push 시 private이라, 공유차트의
`imagePullSecrets: [{name: ghcr-pull}]`가 이 dockerconfigjson SealedSecret을 소비해 pull한다.
덕분에 패키지 가시성을 public으로 바꿀 필요가 없다(가시성 변경은 UI 전용·비가역).

자격은 `read:packages` 전용 토큰(`.env.secrets`의 `GHCR_PULL_TOKEN`)으로 봉인. 재봉인은
`make seal-ghcr-pull`. `platform-components` ApplicationSet이 `platform/*/prod`로 자동 발견 →
`ghcr-pull-prod` Application.
