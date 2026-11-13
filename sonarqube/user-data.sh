#!/bin/bash
# EC2 user data for the SonarQube server (Amazon Linux 2023, >= 4 GiB RAM).
# Runs once at first boot: Docker + PostgreSQL + SonarQube Community Build.
# Used as-is by the console guide, the CLI guide (--user-data file://) and Terraform.
# Log: /var/log/cloud-init-output.log   UI: http://<elastic-ip>:9000 (admin/admin)
set -euxo pipefail

SONAR_IMAGE="public.ecr.aws/docker/library/sonarqube:26.9.0.129388-community"
DB_IMAGE="public.ecr.aws/docker/library/postgres:16-alpine"

dnf install -y docker
systemctl enable --now docker

# SonarQube's embedded Elasticsearch refuses to start without these limits.
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system

# DB password is generated here and only ever lives on this instance.
install -d -m 700 /etc/sonarqube
[ -f /etc/sonarqube/db-password ] || openssl rand -hex 24 > /etc/sonarqube/db-password
DB_PASSWORD=$(cat /etc/sonarqube/db-password)

docker network inspect sonar >/dev/null 2>&1 || docker network create sonar

docker rm -f sonar-db sonarqube 2>/dev/null || true

docker run -d --name sonar-db --network sonar --restart unless-stopped \
  -e POSTGRES_USER=sonar -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=sonarqube \
  -v sonar_db:/var/lib/postgresql/data \
  "$DB_IMAGE"

docker run -d --name sonarqube --network sonar --restart unless-stopped \
  -p 9000:9000 \
  -e SONAR_JDBC_URL=jdbc:postgresql://sonar-db:5432/sonarqube \
  -e SONAR_JDBC_USERNAME=sonar \
  -e SONAR_JDBC_PASSWORD="$DB_PASSWORD" \
  --ulimit nofile=131072:131072 --ulimit nproc=8192:8192 \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  -v sonarqube_logs:/opt/sonarqube/logs \
  "$SONAR_IMAGE"

echo "SonarQube starting on port 9000 (takes 2-3 minutes)"
