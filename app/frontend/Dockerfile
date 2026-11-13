# Base images come from the ECR Public mirror of Docker Hub official images:
# same images, no Docker Hub pull-rate limit in CodeBuild.
# ---- Stage 1: Build React app ----
FROM public.ecr.aws/docker/library/node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY index.html vite.config.js ./
COPY src/ ./src/

RUN npm run build

# ---- Stage 2: Serve with Nginx ----
FROM public.ecr.aws/docker/library/nginx:1.27-alpine

RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost/index.html || exit 1

CMD ["nginx", "-g", "daemon off;"]
