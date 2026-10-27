// SyncReader 自建服务端入口。
//
// 服务端只做四件事（见 docs/06-自建服务端设计与部署.md §1）：
// 带 CAS 乐观锁的元数据存储、增量变更查询（游标）、书籍文件托管（Range）、设备级 token 鉴权。
// 冲突裁决永远在客户端（sync_core），服务端不做任何业务合并。
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dycc/sync-reader/server/internal/api"
)

func main() {
	addr := ":" + envOr("PORT", "8080")
	dataDir := envOr("DATA_DIR", "./data")
	singleUser := os.Getenv("SINGLE_USER") == "true"

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	r := api.NewRouter(api.Config{
		DataDir:    dataDir,
		SingleUser: singleUser,
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		slog.Info("服务端启动", "addr", addr, "dataDir", dataDir, "singleUser", singleUser)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("HTTP 服务异常退出", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("优雅关停失败", "err", err)
	}
	slog.Info("服务端已停止")
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
