#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

echo "[BOOTSTRAP] Updating system and installing packages..."
apt-get update -y > /dev/null
apt-get install -y curl ca-certificates gnupg apt-transport-https jq > /dev/null
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Installing k3s..."
if ! systemctl list-unit-files | grep -q '^k3s\.service'; then
  ufw disable > /dev/null
  curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --disable traefik >/dev/null
fi
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Setting kubeconfig for vagrant user..."
mkdir -p /home/vagrant/.kube
cp -f /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Creating namespace in k3s..."
sudo -u vagrant -H bash -lc "kubectl create namespace f1 --dry-run=client -o yaml | kubectl apply -f -" > /dev/null
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Installing Helm..."
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash > /dev/null
fi
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Installing TimescaleDB..."
sudo -u vagrant -H bash -lc '
helm upgrade --install timescaledb oci://registry-1.docker.io/cloudpirates/timescaledb -n f1 --create-namespace --set persistence.size=20Gi > /dev/null'
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Waiting TimescaleDB to start up. This may take a few minutes..."
sudo -u vagrant -H bash -lc '
kubectl -n f1 rollout status statefulset/timescaledb --timeout=300s > /dev/null'
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Initializing TimescaleDB..."
sudo -u vagrant -H bash -lc '
SQL_SRC="/vagrant/bootstrap-files/timescaledb-init.sql"
test -f "$SQL_SRC" || { echo "[BOOTSTRAP] ERROR: Missing SQL file."; exit 1; }
PGPASS=$(kubectl -n f1 get secret timescaledb -o go-template="{{index .data \"postgres-password\"}}" | base64 -d)
kubectl -n f1 exec -i timescaledb-0 -- sh -lc "PGPASSWORD=\"$PGPASS\" psql -h timescaledb -U postgres -d postgres -f -" < "$SQL_SRC" > /dev/null'
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Installing Grafana..."
sudo -u vagrant -H bash -lc '
test -f /vagrant/bootstrap-files/grafana-ds-values.yaml || { echo "[BOOTSTRAP] ERROR: Missing Grafana datasource file."; exit 1; }
helm repo list 2>/dev/null | grep -q "^grafana" || helm repo add grafana https://grafana.github.io/helm-charts > /dev/null
helm repo update >/dev/null
helm upgrade --install grafana grafana/grafana -n f1 --create-namespace --set service.type=NodePort \
  --set service.nodePort=32000 --set adminUser=admin --set-string adminPassword=telemetryscan \
  --set persistence.enabled=true --set persistence.type=pvc --set persistence.storageClassName=local-path --set persistence.size=5Gi \
  -f /vagrant/bootstrap-files/grafana-ds-values.yaml > /dev/null'
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Importing default dashboard..."
sudo -u vagrant -H bash -lc '
GRAFANA_URL="http://127.0.0.1:32000"
GRAFANA_USER="admin"
GRAFANA_PASS="telemetryscan"
DASH_SRC="/vagrant/bootstrap-files/core-dashboard.json"
DASH_UID="telemetryscan-default"

for i in $(seq 1 60); do
  if curl -sf -u "${GRAFANA_USER}:${GRAFANA_PASS}" "${GRAFANA_URL}/api/health" >/dev/null; then
    break
  fi
  sleep 1
done

test -f "$DASH_SRC" || { echo "[BOOTSTRAP] ERROR: Missing Grafana dashboard file."; exit 1; }

jq --arg uid "${DASH_UID}" \
  ".uid = (.uid // \$uid) | .id = null" \
  "${DASH_SRC}" > /tmp/dashboard.json

jq -n --slurpfile d /tmp/dashboard.json \
  "{dashboard: \$d[0], folderId: 0, overwrite: true}" \
  > /tmp/dashboard-import.json

curl -sf -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
  -H "Content-Type: application/json" \
  -X POST "${GRAFANA_URL}/api/dashboards/db" \
  --data-binary @/tmp/dashboard-import.json >/dev/null'
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Deploying Telemetry Gateway..."
sudo -u vagrant -H bash -lc '
test -f /vagrant/bootstrap-files/telemetry-gateway.yaml || { echo "[BOOTSTRAP] ERROR: Missing Telemetry Gateway deployment file."; exit 1; }
kubectl apply -f /vagrant/bootstrap-files/telemetry-gateway.yaml > /dev/null'
echo "[BOOTSTRAP] Done!"

echo "[BOOTSTRAP] Waiting Telemetry Gateway rollout..."
sudo -u vagrant -H bash -lc 'kubectl -n f1 rollout status deploy/telemetry-gateway --timeout=180s > /dev/null'
echo "[BOOTSTRAP] Done!"