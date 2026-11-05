// containerd 기본 seccomp·AppArmor를 손대지 않고 그대로 낸다. 결과는 tools/sandbox-profiles/base/에 커밋한다.
//
// seccomp는 빈 capability 집합으로 뽑는다. 기본값은 capability마다 syscall을 더하는 구조라, 집합을 비워야
// 무엇을 여는지 tools/sandbox-profiles/generate.ts의 차이만 보고 알 수 있다.
//
// AppArmor 결과는 실행하는 곳에 따라 달라진다. /etc/apparmor.d의 abi·tunables·abstractions 유무로 줄이 바뀌고,
// 이 프로세스의 /proc/self/attr/current가 "Manager" peer 규칙에 들어간다. 그래서 NUC에서, 제한 없는(unconfined)
// 셸에서 뽑는다. CI에서 다시 뽑지 않는 이유이기도 하다.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/containerd/containerd/v2/contrib/apparmor"
	"github.com/containerd/containerd/v2/contrib/seccomp"
	specs "github.com/opencontainers/runtime-spec/specs-go"
)

// generate.ts가 정식 프로필 이름으로 바꾼다.
const profileNamePlaceholder = "@PROFILE_NAME@"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("사용: containerd-defaults seccomp|apparmor")
	}
	switch args[0] {
	case "seccomp":
		spec := &specs.Spec{Process: &specs.Process{Capabilities: &specs.LinuxCapabilities{}}}
		out, err := json.MarshalIndent(seccomp.DefaultProfile(spec), "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(out))
	case "apparmor":
		out, err := apparmor.DumpDefaultProfile(profileNamePlaceholder)
		if err != nil {
			return err
		}
		fmt.Print(out)
	default:
		return fmt.Errorf("모르는 종류: %s", args[0])
	}
	return nil
}
