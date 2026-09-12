# Polyrelay 후속 연결 결정

사용자는 “AIOps 파일럿 먼저, Polyrelay는 후속 연결”을 선택했다. 따라서 첫 실행기는
기존 ChatGPT/Codex 구독을 사용하는 `codex exec`다. 사건 큐·증거·게시와 실행 인터페이스를
분리하고 Polyrelay protocol, client 또는 fallback은 첫 파일럿에 구현하지 않는다.

2026-09-12 별도 로컬 연구에서는 Polyrelay의 production Codex 실행/인증, 재시작 후
무인 활성화, 외부 Change Set export가 현재 AIOps 계약을 충족하지 못하는 것으로 확인됐다.
Polyrelay 자체의 개선은 이번 리뷰 범위 밖이며 그 레포를 조회할 필요가 없다.

이 사본은 생략한 연구의 요약임을 명시한다. 그 연구 전체를 이번 gate가 검토했다고 주장하지
않는다. 이 리뷰에서는 현재 직접 실행 설계가 운영 요구와 권한 경계를 충족하는지 판단한다.
