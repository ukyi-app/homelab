# O02 검증: 파드 안 hc core와 holder 경계

- 단계: 0 끄기와 검증
- 상태: 대기
- 명세: `spec.md` §5.2 B-02, §6 불변 조건 3·7·8
- Blocked by: 없음
- 연결 AC: AC-03
- 수행: 에이전트 + 사람(시험 파드 배포 PR)
- 저장소·PR: homelab PR 하나(시험용 네임스페이스·파드, 끝나면 되돌림), 결과는 이 계획 문서 PR
- 파일 소유: 시험 매니페스트(위치는 이 티켓이 정한다), 이 티켓의 "결과" 절, `spec.md` §5.2 B-02 줄
- 설계 계약: 보안 조사 3.1·3.2·10절(아래 요약)

## 목표

NUC의 별도 파드에서 hc core가 뜨고, core가 띄우는 holder와 그 자식이 모두 같은 파드 경계(cgroup·PID·네트워크) 안에 있는지 확인한다. 안 되면 B-02의 대안(호스트 전용 계정 + systemd 강화)으로 내리는 근거를 남긴다.

## 알려진 사실

- [확인] 설치된 hc는 0.1.17이고, 클라이언트별 권한·인증이 없다. 소켓에 닿는 쪽은 그 계정의 명령·파일·터미널을 제어한다.
- [확인] hc 0.1.17은 user manager가 있으면 core·holder를 별도 systemd user service로 띄우고 `KillMode=process`를 쓴다. "core를 강화된 서비스에서 띄웠으니 자식도 같은 경계"라고 가정하면 안 된다.
- [확인] 호스트는 `kernel.apparmor_restrict_unprivileged_userns=1`이다. 지금 작업자 파드는 bwrap용 프로필을 쓴다.
- [미확인] 파드 안(systemd user manager 없음)에서 hc가 holder를 어떻게 띄우는지.

## 할 일

1. 전용 시험 네임스페이스에 비root UID, `automountServiceAccountToken: false`, `enableServiceLinks: false`, 읽기 전용 root, capability drop ALL, privilege escalation 금지인 파드를 띄운다. hostPath·hostPID·hostNetwork 없음.
2. 고정 버전 hc의 core를 PID 1 아래 장수 프로세스로 띄운다(`HC_SESSION=olive`, 짧은 XDG 경로). core 상태는 PVC, 소켓은 emptyDir 0700.
3. 모델 호출 없는 셸 프로그램(예: `sleep`)을 hc로 여러 개 띄우고 확인한다:
   - holder와 자식의 cgroup이 파드 cgroup 안인지(`/proc/<pid>/cgroup`).
   - 파드 limits(CPU·메모리·PID)가 holder에도 걸리는지.
   - core를 멈추거나 파드를 지웠을 때 holder·자식이 0개가 되는지.
   - `--outlive-parent`로 띄운 자식이 오케스트레이터 역할 프로세스 종료 뒤에도 남고 회수되는지.
4. 소켓이 다른 컨테이너·파드에서 보이지 않는지 확인한다.
5. 결과를 "결과" 절에 적고, B-02를 유지할지 내릴지 안을 낸다. 시험 파드는 되돌린다.

## 완료 조건

- [ ] 위 네 확인 각각의 결과(됨/안 됨)와 근거(명령·출력 요약)가 있다.
- [ ] B-02 유지 또는 대안 전환 안이 있고, O09 머리말이 그에 맞게 고쳐졌다.

## 검증

- 경계: 운영 실험(모델 호출 없음, 시험·빌드 없음). NUC 부하를 지켜보며 한 번에 하나.
- 잡는 실패: holder가 경계 밖으로 빠짐, 정지 뒤 고아 프로세스. 못 잡는 범위: 실제 모델 세션의 자원 사용(O09·O21).

## 결과

(검증 뒤 채운다)
