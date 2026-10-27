# 多阶段构建：Go 构建层 → scratch 运行层，最终镜像 ≈ 15MB（docs/06 §4.1）
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o /out/server ./cmd/server && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o /out/serverctl ./cmd/serverctl

FROM scratch
# ca-certificates：HTTPS 外呼与 TLS 校验所需
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/server /app/server
COPY --from=build /out/serverctl /app/serverctl
VOLUME /data
EXPOSE 8080
ENV PORT=8080 DATA_DIR=/data
ENTRYPOINT ["/app/server"]
