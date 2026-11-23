
#
# 생성물이다. 손으로 고치지 않는다: tools/sandbox-profiles/generate.ts(containerd 기본값 + 변경).
#
# containerd가 프로필을 지정하지 않은 모든 컨테이너에 붙이는 기본 프로필을 같은 이름으로 먼저 올려 덮는다.
# containerd는 이 이름이 커널에 이미 있으면 자기 기본값을 올리지 않는다(contrib/apparmor의 LoadDefaultProfile).
# 부팅 때는 apparmor.service가 k3s보다 먼저 이 파일을 올린다. 이 파일이 없으면 containerd가 규칙이 빠진 기본값을 올린다.
#
# containerd가 정한 이름이라 버전을 붙일 수 없다. 내용을 바꿔 install.sh --sandbox-profiles를 돌리면
# apparmor_parser -r이 도는 모든 파드의 규칙을 그 자리에서 바꾼다.
#
# containerd 기본 프로필의 복사본이라 upstream 수정이 저절로 들어오지 않는다. 출발점은 host/versions.env의
# SANDBOX_PROFILE_CONTAINERD 판이다. k3s·containerd를 올리면 다시 생성한다.
#
# 기본값에 더하는 것은 겹친 라벨의 signal·ptrace 규칙뿐이다.
#
abi <abi/3.0>,

#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {

  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined
,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,
  # 커널 7.0.0-42·7.0.0-44에서 컨테이너 프로세스의 라벨이 cri-containerd.apparmor.d//&unconfined로 겹쳐 붙는다(실측).
  # peer는 겹친 라벨 문자열 전체와 맞춰 보므로 이름만 쓴 위 규칙으로는 같은 컨테이너 안 시그널이 거부된다.
  # *는 /를 넘지 못해 *이름*으로도 안 된다. **는 //& 구분자까지 넘는다.
  # 거부되면 Postgres의 래치 깨우기(SIGURG)가 사라져 연결이 authentication에서 멈춘다(docs/runbooks-public/nuc-kernel-pin.md).
  signal (send,receive) peer=**cri-containerd.apparmor.d**,

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
  ptrace (trace,tracedby,read,readby) peer=**cri-containerd.apparmor.d**,
}
