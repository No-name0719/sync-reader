// Package books 实现正文文件托管：整体上传（落盘 tmp → rename 原子提交，
// 流式计算 SHA-256 与 query hash 比对，不符返回 422）、Range 下载
// （http.ServeContent）、孤儿文件清理。文件布局见 docs/06 §1。M3 里程碑实现。
package books
