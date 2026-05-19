# AI Gateway Docker Image

AI Gateway is an AI API Gateway Platform for distributing and managing AI product subscription API quotas.

## Quick Start

```bash
docker run -d \
  --name gateway \
  -p 18080:18080 \
  -e DATABASE_URL="postgres://user:pass@host:5432/gateway" \
  -e REDIS_URL="redis://host:6379" \
  ghcr.io/yangbb7/gateway:latest
```

## Docker Compose

```yaml
version: '3.8'

services:
  gateway:
    image: ghcr.io/yangbb7/gateway:latest
    ports:
      - "18080:18080"
    environment:
      - DATABASE_URL=postgres://postgres:postgres@db:5432/gateway?sslmode=disable
      - REDIS_URL=redis://redis:6379
    depends_on:
      - db
      - redis

  db:
    image: postgres:15-alpine
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=gateway
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data

volumes:
  postgres_data:
  redis_data:
```

## Environment Variables

| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| `DATABASE_URL` | PostgreSQL connection string | Yes | - |
| `REDIS_URL` | Redis connection string | Yes | - |
| `PORT` | Server port | No | `18080` |
| `GIN_MODE` | Gin framework mode (`debug`/`release`) | No | `release` |

## Supported Architectures

- `linux/amd64`
- `linux/arm64`

## Tags

- `latest` - Latest stable release
- `x.y.z` - Specific version
- `x.y` - Latest patch of minor version
- `x` - Latest minor of major version

## Links

- [GitHub Repository](https://github.com/yangbb7/sub2api)
- [Documentation](https://github.com/yangbb7/sub2api#readme)
