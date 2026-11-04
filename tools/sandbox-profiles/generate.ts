// 봇 작업 레인 worker 전용 Localhost 프로필을 containerd 기본값(base/) + 아래 변경으로 만든다.
//
// 사용: bun tools/sandbox-profiles/generate.ts [--check] [--host-dir <host 경로>]
//   인자 없음  host/sandbox-profiles/에 쓴다.
//   --check   쓰지 않고 커밋한 프로필과 대조한다. ci가 부른다. base/를 containerd에서 다시 뽑는 일은 regen.sh가 한다.
//
// 이 파일은 지금 버전(VERSION) 하나만 만든다. 내용을 바꾸면 VERSION을 올려 새 이름의 파일을 만들고 옛 파일은 그대로 둔다.
// 도는 파드는 시작할 때 고른 이름을 참조하므로, 같은 이름을 덮으면 그 파드가 검증 안 된 규칙을 받는다.
//
// 변경은 바꿀 줄을 정확히 한 번씩 찾아 적용한다. containerd를 올려 기본값이 달라지면 조용히 어긋나지 않고 여기서 멈춘다.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const VERSION = "v1";
const SECCOMP_FILE = `sandbox-worker-${VERSION}.json`;
const APPARMOR_NAME = `homelab-sandbox-worker-${VERSION}`;
const NAME_PLACEHOLDER = "@PROFILE_NAME@";

const HERE = dirname(new URL(import.meta.url).pathname);

// containerd 기본 seccomp가 CAP_SYS_ADMIN 없이 막는 것 가운데 bwrap이 새 userns 안에서 쓰는 것만 조건 없이 연다.
//   clone·unshare: namespace 생성(기본은 clone의 namespace 플래그와 unshare를 막는다).
//   mount·umount2: 샌드박스 루트 구성.
//   pivot_root: 기본 목록에 아예 없어 SYS_ADMIN을 줘도 bwrap이 루트 교체에서 멈춘다(실측).
//   sethostname: bwrap --hostname.
// clone3는 기본(ENOSYS) 그대로 둔다. libc가 clone으로 되돌아가므로 열 까닭이 없다.
// 이 허용은 worker 컨테이너 전체에 걸린다. 바깥 프로세스를 막는 것은 capability 0·no_new_privs와 AppArmor mount 규칙이다.
const SECCOMP_ALLOW = ["clone", "unshare", "mount", "umount2", "pivot_root", "sethostname"];

// 설치되는 파일의 일부다. 줄 앞에 include를 쓰면 파서가 지시어로 읽으니 주석을 그 낱말로 시작하지 않는다.
const APPARMOR_HEADER = `#
# 생성물이다. 손으로 고치지 않는다: tools/sandbox-profiles/generate.ts(containerd 기본값 + 변경).
# 내용을 바꾸려면 이름의 버전을 올린다. 같은 이름에 apparmor_parser -r을 하면 도는 파드의 규칙이 그 자리에서 바뀐다.
#
# containerd 기본 프로필의 복사본이라 upstream 수정이 저절로 들어오지 않는다. 출발점은 host/versions.env의
# SANDBOX_PROFILE_CONTAINERD 판이다. k3s·containerd·Ubuntu·bubblewrap·Claude CLI를 올리면 다시 생성하고 다시 잰다.
#
# bwrap이 namespace를 만들 수 있는 것은 이 프로필이 아니라 호스트 Ubuntu의 프로필 bwrap 덕분이다
# (/etc/apparmor.d/bwrap-userns-restrict). 그 프로필은 /usr/bin/bwrap에 경로로 붙고 컨테이너 안의 같은 경로에도 붙는다.
# 그래서 worker 이미지의 bwrap은 배포판 패키지 경로여야 한다. 경로가 다르거나 호스트에서 프로필이 빠지면
# kernel.apparmor_restrict_unprivileged_userns=1이 userns를 막을 것으로 본다(미측정). 그때는 다시 잰다.
# bwrap의 자식은 unpriv_bwrap(capability 거부) 아래서 돌아 샌드박스 안에서는 쓸 수 있는 userns를 다시 만들지 못한다.
#
`;

const STACKED_SIGNAL = `  # 이 호스트의 userns 파드는 runc의 프로필 전환이 unconfined와의 stack으로 바뀌어 라벨이 겹쳐 붙는다
  # (${NAME_PLACEHOLDER}//&unconfined, 샌드박스 안은 bwrap//&${NAME_PLACEHOLDER}//&unpriv_bwrap).
  # peer는 겹친 라벨 문자열 전체와 맞춰 보므로 이름만 쓰면 같은 컨테이너 안 kill·ptrace도 거부된다.
  # *는 /를 넘지 못해 *이름*으로도 안 된다. **는 //& 구분자까지 넘는다.
  signal (send,receive) peer=**${NAME_PLACEHOLDER}**,
`;

const PROC_SYS_DENY = `  # bwrap --disable-userns가 새 userns 안에서 /proc/sys/user/max_user_namespaces에 쓴다. deny는 allow보다 앞서므로
  # allow로 예외를 만들 수 없어 deny를 글자별로 나눠 그 경로를 뺀다. 나눔이 max_u에서 끝나 max_uts_namespaces도 함께 빠진다.
  # 이 sysctl은 쓰는 쪽 userns의 한도라 바깥 userns에는 닿지 않는다(커널 ucount 구조, 미측정).
  deny @{PROC}/sys/[^ku]** w,
  deny @{PROC}/sys/u[^s]** w,
  deny @{PROC}/sys/us[^e]** w,
  deny @{PROC}/sys/use[^r]** w,
  deny @{PROC}/sys/user[^/]** w,
  deny @{PROC}/sys/user/[^m]** w,
  deny @{PROC}/sys/user/m[^a]** w,
  deny @{PROC}/sys/user/ma[^x]** w,
  deny @{PROC}/sys/user/max[^_]** w,
  deny @{PROC}/sys/user/max_[^u]** w,
`;

const MOUNT_RULES = `  # bwrap 0.12.0이 새 userns 안에서 하는 mount만 연다: 전파 변경, bind와 그 remount, tmpfs·proc·devpts, 루트 교체.
  # overlay·mqueue·sysfs·cgroup·move는 열지 않는다. 바깥 컨테이너는 capability가 없어 어차피 mount를 못 한다.
  # options in (...)은 부분집합 일치라 fstype 없는 규칙에 쓰면 아무 파일시스템의 rw mount도 받는다(mqueue가 통과했다).
  # 그래서 bind·전파는 options=(...)로 정확한 집합을 쓰고, options in은 fstype을 고정한 규칙과 remount에만 쓴다.
  mount options=(rw, silent, rslave) -> **,
  mount options=(rw, silent, rprivate) -> **,
  mount options=(rw, bind) ** -> **,
  mount options=(rw, rbind) ** -> **,
  remount options in (ro, rw, nosuid, nodev, noexec, bind, silent, relatime, noatime, nodiratime, strictatime) **,
  mount fstype=tmpfs options in (rw, nosuid, nodev, silent) tmpfs -> **,
  mount fstype=proc options in (rw, nosuid, nodev, noexec, silent) proc -> **,
  mount fstype=devpts options in (rw, nosuid, noexec, silent) devpts -> **,
  pivot_root,
`;

const APPARMOR_CHANGES: [string, string][] = [
  ["\nabi <abi/3.0>,", `\n${APPARMOR_HEADER}abi <abi/3.0>,`],
  [
    `  signal (send,receive) peer=${NAME_PLACEHOLDER},\n`,
    `  signal (send,receive) peer=${NAME_PLACEHOLDER},\n${STACKED_SIGNAL}`,
  ],
  ["  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)\n", PROC_SYS_DENY],
  ["  deny mount,\n", MOUNT_RULES],
  [
    `  ptrace (trace,tracedby,read,readby) peer=${NAME_PLACEHOLDER},\n`,
    `  ptrace (trace,tracedby,read,readby) peer=${NAME_PLACEHOLDER},\n  ptrace (trace,tracedby,read,readby) peer=**${NAME_PLACEHOLDER}**,\n`,
  ],
];

function replaceOnce(text: string, from: string, to: string): string {
  const n = text.split(from).length - 1;
  if (n !== 1) throw new Error(`기본값에서 이 줄을 ${n}번 찾았다(기대 1). containerd 기본값이 바뀌었는지 본다:\n${from}`);
  return text.replace(from, () => to);
}

export function renderSeccomp(base: string): string {
  const profile = JSON.parse(base) as { syscalls: { names: string[]; action: string }[] };
  profile.syscalls.push({ names: SECCOMP_ALLOW, action: "SCMP_ACT_ALLOW" });
  return JSON.stringify(profile, null, 2);
}

export function renderAppArmor(base: string, name: string): string {
  if (!base.includes(`profile ${NAME_PLACEHOLDER} `)) throw new Error(`기본값에 ${NAME_PLACEHOLDER} 프로필 선언이 없다`);
  let text = base;
  for (const [from, to] of APPARMOR_CHANGES) text = replaceOnce(text, from, to);
  return text.replace(/\n{3,}/g, "\n\n").replaceAll(NAME_PLACEHOLDER, name);
}

function main(argv: string[]): number {
  const check = argv.includes("--check");
  const hostFlag = argv.indexOf("--host-dir");
  const hostDir = hostFlag >= 0 ? resolve(argv[hostFlag + 1] ?? "") : resolve(HERE, "../../host");
  const outputs: [string, string][] = [
    [join(hostDir, "sandbox-profiles/seccomp", SECCOMP_FILE), renderSeccomp(readFileSync(join(HERE, "base/seccomp.json"), "utf8"))],
    [join(hostDir, "sandbox-profiles/apparmor", APPARMOR_NAME), renderAppArmor(readFileSync(join(HERE, "base/apparmor.txt"), "utf8"), APPARMOR_NAME)],
  ];
  let bad = 0;
  for (const [path, want] of outputs) {
    if (check) {
      if (!existsSync(path) || readFileSync(path, "utf8") !== want) {
        console.error(`FAIL ${path}가 생성 결과와 다르다. bun tools/sandbox-profiles/generate.ts로 다시 만든다`);
        bad += 1;
      } else {
        console.log(`ok   ${path}`);
      }
    } else {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, want);
      console.log(`씀   ${path}`);
    }
  }
  return bad === 0 ? 0 : 1;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
