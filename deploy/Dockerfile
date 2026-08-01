# =============================================================================
# AI Gateway Multi-Stage Dockerfile
# =============================================================================
# Stage 1: Build frontend
# Stage 2: Build Go backend with embedded frontend
# Stage 3: Final minimal image
# =============================================================================

ARG NODE_IMAGE=node:24-alpine
ARG GOLANG_IMAGE=golang:1.26.5-alpine
ARG ALPINE_IMAGE=alpine:3.20
ARG PNPM_VERSION=9.15.9
ARG GOPROXY=https://goproxy.cn,direct
ARG GOSUMDB=sum.golang.google.cn
ARG NODE_OPTIONS=--max-old-space-size=1280
ARG BUILD_GOMAXPROCS=1
ARG BUILD_GOMEMLIMIT=640MiB
ARG BUILD_GCFLAGS=all=-l
ARG PNPM_REGISTRY=https://registry.npmjs.org/

# -----------------------------------------------------------------------------
# Stage 1: Frontend Builder
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS frontend-builder
ARG PNPM_VERSION
ARG NODE_OPTIONS
ARG PNPM_REGISTRY

WORKDIR /app/frontend

# Install pnpm
RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate

# Install dependencies first (better caching)
COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm config set registry "${PNPM_REGISTRY}" && \
    pnpm config set fetch-retries 5 && \
    pnpm config set fetch-retry-mintimeout 10000 && \
    pnpm config set fetch-retry-maxtimeout 120000 && \
    pnpm config set network-timeout 600000 && \
    pnpm install --frozen-lockfile

# Copy frontend source and build.
# LegalDocumentView.vue (admin-compliance gate) build-time imports
# ../../../../docs/legal/*.md?raw, so docs/legal/ must sit beside frontend/
# in the image (WORKDIR /app/frontend -> resolves to /app/docs/legal/*.md).
# Copy only that subtree to keep the build dependency minimal.
# Type checking is kept out of the 1G remote image build because vue-tsc can
# spend minutes swapping on 1C1G VPSes.
COPY frontend/ ./
COPY docs/legal/ /app/docs/legal/
RUN VITE_DISABLE_CHECKER=true NODE_OPTIONS="${NODE_OPTIONS}" pnpm exec vite build

# -----------------------------------------------------------------------------
# Stage 2: Backend Builder
# -----------------------------------------------------------------------------
FROM ${GOLANG_IMAGE} AS backend-builder

# Build arguments for version info (set by CI)
ARG VERSION=docker
ARG COMMIT=docker
ARG DATE
ARG GOPROXY
ARG GOSUMDB

ENV GOPROXY=${GOPROXY}
ENV GOSUMDB=${GOSUMDB}

# Install build dependencies
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app/backend

# Copy go mod files first (better caching)
COPY backend/go.mod backend/go.sum ./
RUN go mod download

ARG BUILD_GOMAXPROCS
ARG BUILD_GOMEMLIMIT
ARG BUILD_GCFLAGS

ENV GOMAXPROCS=${BUILD_GOMAXPROCS}
ENV GOMEMLIMIT=${BUILD_GOMEMLIMIT}

# Copy backend source first
COPY backend/ ./

# Copy frontend dist from previous stage (must be after backend copy to avoid being overwritten)
COPY --from=frontend-builder /app/backend/internal/web/dist ./internal/web/dist

# Build the binary (BuildType=release for CI builds, embed frontend). The
# generated ent package has a high compile-time memory peak, so the 1G image
# build keeps Go package parallelism at one and disables inlining.
RUN CGO_ENABLED=0 GOOS=linux GOGC=50 go build \
    -p 1 \
    -gcflags="${BUILD_GCFLAGS}" \
    -tags embed \
    -ldflags="-s -w -X main.Commit=${COMMIT} -X main.Date=${DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} -X main.BuildType=release" \
    -o /app/gateway \
    ./cmd/server

# -----------------------------------------------------------------------------
# Stage 3: Final Runtime Image
# -----------------------------------------------------------------------------
FROM ${ALPINE_IMAGE}

# Labels
LABEL description="AI Gateway Platform"

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    curl \
    su-exec \
    && rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -g 1000 gateway && \
    adduser -u 1000 -G gateway -s /bin/sh -D gateway

# Set working directory
WORKDIR /app

# Copy binary and runtime fallback resources from builder
COPY --from=backend-builder /app/gateway /app/gateway
COPY --from=backend-builder --chown=gateway:gateway /app/backend/resources /app/resources

# Create data directory
RUN mkdir -p /app/data && chown -R gateway:gateway /app

# Copy entrypoint script (fixes volume permissions then drops to gateway)
COPY deploy/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

# Expose port (can be overridden by SERVER_PORT env var)
EXPOSE 18080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD wget -q -T 5 -O /dev/null http://localhost:${SERVER_PORT:-18080}/health || exit 1

# Run the application (entrypoint fixes /app/data ownership then execs as gateway)
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["/app/gateway"]
