// Package auth 实现设备级鉴权（docs/06 §3）：Argon2id 密码哈希、
// 短期 accessToken（JWT HS256）+ 长期 refreshToken（服务端只存哈希、刷新轮换）、
// SINGLE_USER 配对码模式。M3 里程碑实现。
package auth
