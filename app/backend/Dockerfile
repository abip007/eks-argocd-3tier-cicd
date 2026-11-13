# Base images come from the ECR Public mirror of Docker Hub official images:
# same images, no Docker Hub pull-rate limit in CodeBuild.
# ---- Stage 1: Install production dependencies ----
FROM public.ecr.aws/docker/library/node:20-alpine AS builder

WORKDIR /app

# Copy dependency files first (layer caching). The lock file makes the build
# install exactly the versions the pipeline tested.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src/ ./src/

# ---- Stage 2: Runtime ----
FROM public.ecr.aws/docker/library/node:20-alpine

WORKDIR /app

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder --chown=appuser:appgroup /app /app

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]
