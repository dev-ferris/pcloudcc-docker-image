# syntax=docker/dockerfile:1.7
# =============================================================================
# pcloudcc-webui — Lightweight management sidecar
# Multi-stage build: Go compile → Alpine runtime (~15 MB)
# =============================================================================

FROM golang:1.22-alpine AS builder

WORKDIR /build
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOFLAGS="-trimpath" \
    go build -ldflags="-s -w" -o /webui .

# --- Runtime ---
FROM alpine:3.19

LABEL org.opencontainers.image.title="pcloudcc-webui" \
      org.opencontainers.image.description="Web UI sidecar for pcloudcc Docker containers" \
      org.opencontainers.image.source="https://github.com/dev-ferris/pcloudcc-docker-image"

RUN apk --no-cache add ca-certificates

COPY --from=builder /webui /usr/local/bin/webui

EXPOSE 8080

ENTRYPOINT ["webui"]
