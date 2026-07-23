# Triage 결정 — bats-pin-checksum

### structure r1

R-1 accept (as proposed·high) — Generated tag archive can invalidate the pinned checksum and block every required gate. bats-core는 업로드 릴리스 에셋이 없어 auto-generated archive(/archive/refs/tags/, 체크섬 불안정)를 쓸 수밖에 없었다 → **git clone + 커밋 SHA 핀**(eb7f42f8d608ac693d7a4b67474f6714ea68cfc5 = v1.14.0)으로 전환. git 객체는 content-addressed·fetch 시 git이 SHA 검증 → tarball 체크섬보다 강한 불변성, blob 무추가, 동일 host(github.com). 테스트를 커밋-SHA 핀 검증 + auto-generated archive 경로 부재로 갱신, sha256sum count는 10으로 환원(bats는 git-SHA로 검증).
