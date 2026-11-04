#!/usr/bin/env bash
# Instala Terraform y k6 en AWS CloudShell (Amazon Linux 2023).
# CloudShell borra lo instalado fuera de $HOME al cerrar la sesión: ejecutar en cada sesión.
set -euo pipefail

if ! command -v terraform >/dev/null; then
  sudo dnf install -y -q dnf-plugins-core
  sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
  sudo dnf install -y -q terraform
fi

if ! command -v k6 >/dev/null; then
  K6_VERSION="v1.0.0"
  curl -sSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp
  sudo mv "/tmp/k6-${K6_VERSION}-linux-amd64/k6" /usr/local/bin/k6
fi

terraform version | head -1
k6 version
