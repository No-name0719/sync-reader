// Package store 承载 SQLite 账本（users / devices / meta_index / refresh_tokens）
// 与单写者串行化。驱动用 modernc.org/sqlite（纯 Go、CGO-free）。
//
// 设计约束见 docs/06 §1/§5：meta_index 是加速表，JSON 文件才是正本，
// 两者不一致时以 JSON 为准并在自检（serverctl reindex）时修复。M3 里程碑实现。
package store
