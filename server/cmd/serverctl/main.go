// serverctl —— 服务端管理 CLI（docs/06 §3.2/§4.5）：
//
//	user add|list          多用户模式建号（v1 注册默认关闭）
//	devices list|revoke    设备管理与吊销
//	backup <dir>           一致性备份（SQLite VACUUM INTO + 文件打包）
//	reindex                扫描 users/* 重建 meta_index
//	health --port N        Docker healthcheck 探针
//
// M0 仅注册命令骨架；具体子命令在 M3 随对应功能实现。
package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"
)

const usage = `serverctl —— SyncReader 服务端管理工具

用法:
  serverctl <command> [args]

命令:
  user add <name>       创建用户
  devices list          列出设备
  devices revoke <id>   吊销设备
  backup <dir>          备份数据
  reindex               重建 meta_index
  health --port N       健康检查探针
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	switch os.Args[1] {
	case "health":
		port := flag.Int("port", 8080, "服务端口")
		_ = flag.CommandLine.Parse(os.Args[2:])
		os.Exit(healthProbe(*port))
	case "user", "devices", "backup", "reindex":
		// TODO(M3)：随鉴权与存储层一起实现。
		fmt.Fprintf(os.Stderr, "serverctl: 子命令 %q 尚未实现（M3 里程碑）\n", os.Args[1])
		os.Exit(1)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
}

func healthProbe(port int) int {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/health", port))
	if err != nil {
		fmt.Fprintln(os.Stderr, "health check failed:", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		fmt.Fprintf(os.Stderr, "health check: unexpected status %d\n", resp.StatusCode)
		return 1
	}
	return 0
}
