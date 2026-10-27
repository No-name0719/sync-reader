// Package api 装配 REST 路由与中间件。
//
// v1 端点规格见 docs/06-自建服务端设计与部署.md §2。M0 仅落地 /health 存活检查，
// 其余端点（auth / library / sync / meta / books）在 M3 里程碑按规格补齐。
package api

import (
	"encoding/json"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// Config 服务端运行配置（来自环境变量，语义与 docs/06 §4.1 的 compose 示例一致）。
type Config struct {
	DataDir    string // 数据根目录（SQLite + users/ 文件树）
	SingleUser bool   // 单用户家用模式：启动时打印一次性配对码
}

// NewRouter 构建全部路由。
func NewRouter(cfg Config) http.Handler {
	r := chi.NewRouter()

	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)

	r.Group(func(v1 chi.Router) {
		v1.Get("/health", handleHealth)
		// TODO(M3): auth/library/sync/meta/books 端点，见 docs/06 §2.1 端点一览。
		_ = cfg
	})

	return r
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
