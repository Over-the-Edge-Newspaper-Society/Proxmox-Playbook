#!/usr/bin/env bash
# Called by zoer-setup-ddev.sh over the existing operator SSH connection.
set -Eeuo pipefail
set +x
umask 077
[[ $EUID == 0 ]] || { echo 'Run the host installer as root.' >&2; exit 1; }
mode="${1:?enable or disable}"; bind_ip="${2:?private IP}"; pod_cidr="${3:?pod CIDR}"; source_dir="${4:?bridge source}"; bun_version="${5:-1.3.14}"
[[ "$mode" == enable || "$mode" == disable ]] || exit 2
if [[ "$mode" == disable ]]; then
  if systemctl cat zoer-ddev-bridge.service >/dev/null 2>&1; then systemctl disable --now zoer-ddev-bridge.service; fi
  echo 'DDEV bridge disabled. Existing project files and containers are preserved.'
  exit 0
fi
python3 - "$bind_ip" "$pod_cidr" <<'PY'
import ipaddress,sys
address=ipaddress.ip_address(sys.argv[1]); network=ipaddress.ip_network(sys.argv[2])
assert address.version==4 and address.is_private and not address.is_loopback
assert network.version==4 and network.is_private
PY
[[ "$bun_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
# A pre-existing Kubernetes token may seed first-time host setup. Never rotate it
# silently, or print it in logs / command arguments.
seed="$(cat)"
existing=''
if [[ -f /etc/zoer/ddev-bridge.env ]]; then existing="$(sed -n 's/^DDEV_BRIDGE_TOKEN=//p' /etc/zoer/ddev-bridge.env)"; fi
if [[ -n "$seed" && -n "$existing" && "$seed" != "$existing" ]]; then
  echo 'Host and Kubernetes bridge tokens differ. Reconcile the existing credentials before setup.' >&2; exit 1
fi
token="${existing:-$seed}"
if [[ -z "$token" ]]; then token="$(openssl rand -hex 32)"; fi
[[ "$token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || { echo 'Existing bridge token has an unsupported format; preserve and reconcile it manually.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
for utility in curl git iptables; do
  if ! command -v "$utility" >/dev/null; then apt-get update; apt-get install -y curl ca-certificates git iptables; break; fi
done
if ! command -v docker >/dev/null; then apt-get update; apt-get install -y docker.io; fi
systemctl enable --now docker
if ! command -v ddev >/dev/null; then
  apt-get update; apt-get install -y curl ca-certificates unzip git iptables
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://packages.ddev.com/public/gpg.key -o /etc/apt/keyrings/ddev.asc
  chmod 0644 /etc/apt/keyrings/ddev.asc
  printf 'Types: deb\nURIs: https://packages.ddev.com/public/deb/ubuntu\nSuites: stable\nComponents: main\nSigned-By: /etc/apt/keyrings/ddev.asc\n' > /etc/apt/sources.list.d/ddev.sources
  chmod 0644 /etc/apt/sources.list.d/ddev.sources
  apt-get update; apt-get install -y ddev
fi
if ! docker buildx version >/dev/null 2>&1; then
  apt-get update
  if apt-cache show docker-buildx-plugin >/dev/null 2>&1; then apt-get install -y docker-buildx-plugin; else apt-get install -y docker-buildx; fi
fi
if [[ ! -x /opt/zoer-bun/bin/bun ]] || [[ "$(/opt/zoer-bun/bin/bun --version)" != "$bun_version" ]]; then
  apt-get update; apt-get install -y curl unzip
  installer="$(mktemp)"
  curl -fsSL https://bun.sh/install -o "$installer"
  BUN_INSTALL=/opt/zoer-bun bash "$installer" "bun-v$bun_version"
  rm -f "$installer"
fi
chmod 0755 /opt/zoer-bun /opt/zoer-bun/bin /opt/zoer-bun/bin/bun
if ! id zoer >/dev/null 2>&1; then useradd --system --create-home --home-dir /srv/zoer-wordpress/.home --shell /usr/sbin/nologin zoer; fi
[[ "$(getent passwd zoer | cut -d: -f6)" == /srv/zoer-wordpress/.home ]] || { echo "Existing zoer account uses a different home. Reconcile the service account before setup." >&2; exit 1; }
usermod -aG docker zoer
install -d -m 0750 -o zoer -g zoer /srv/zoer-wordpress
install -d -m 0750 -o root -g zoer /etc/zoer
old_hash="$(find /opt/zoer-ddev-bridge -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum || true)"
install -d -m 0755 /opt/zoer-ddev-bridge
cp -a "$source_dir/src" "$source_dir/package.json" /opt/zoer-ddev-bridge/
chown -R root:root /opt/zoer-ddev-bridge
chmod -R a+rX /opt/zoer-ddev-bridge
new_hash="$(find /opt/zoer-ddev-bridge -type f -exec sha256sum {} + | sort | sha256sum)"
env_file="$(mktemp)"
printf 'PORT=4085\nHOST=%s\nDDEV_WORKSPACE_ROOT=/srv/zoer-wordpress\nDDEV_BRIDGE_TOKEN=%s\n' "$bind_ip" "$token" > "$env_file"
env_changed=0
cmp -s "$env_file" /etc/zoer/ddev-bridge.env || env_changed=1
install -m 0640 -o root -g zoer "$env_file" /etc/zoer/ddev-bridge.env
rm -f "$env_file"
sudo -Hu zoer sh -c 'cd /srv/zoer-wordpress && docker info >/dev/null && ddev config global --router-http-port=8080 --router-https-port=8443 --router-bind-all-interfaces=false --docker-buildx-version=system --instrumentation-opt-in=false'
# Protect only inbound bridge traffic, leaving Docker/K3s and outbound Git alone.
cat > /usr/local/sbin/zoer-ddev-firewall <<FIREWALL
#!/usr/bin/env bash
set -euo pipefail
iptables -w -N ZOER-DDEV-BRIDGE 2>/dev/null || true
iptables -w -F ZOER-DDEV-BRIDGE
iptables -w -A ZOER-DDEV-BRIDGE -s 127.0.0.0/8 -j ACCEPT
iptables -w -A ZOER-DDEV-BRIDGE -s $bind_ip/32 -j ACCEPT
iptables -w -A ZOER-DDEV-BRIDGE -s $pod_cidr -j ACCEPT
iptables -w -A ZOER-DDEV-BRIDGE -j REJECT
iptables -w -C INPUT -p tcp -d $bind_ip --dport 4085 -j ZOER-DDEV-BRIDGE 2>/dev/null || iptables -w -I INPUT 1 -p tcp -d $bind_ip --dport 4085 -j ZOER-DDEV-BRIDGE
FIREWALL
chmod 0755 /usr/local/sbin/zoer-ddev-firewall
cat > /etc/systemd/system/zoer-ddev-firewall.service <<'UNIT'
[Unit]
Description=Private inbound access to Zoer DDEV bridge
After=network-online.target
Before=zoer-ddev-bridge.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zoer-ddev-firewall
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
unit_file="$(mktemp)"
cat > "$unit_file" <<'UNIT'
[Unit]
Description=Zoer DDEV WordPress runtime bridge
After=network-online.target docker.service zoer-ddev-firewall.service
Requires=docker.service zoer-ddev-firewall.service
Wants=network-online.target
[Service]
Type=simple
User=zoer
Group=zoer
SupplementaryGroups=docker
WorkingDirectory=/opt/zoer-ddev-bridge
EnvironmentFile=/etc/zoer/ddev-bridge.env
ExecStart=/opt/zoer-bun/bin/bun src/index.ts
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/srv/zoer-wordpress
[Install]
WantedBy=multi-user.target
UNIT
unit_changed=0
cmp -s "$unit_file" /etc/systemd/system/zoer-ddev-bridge.service || unit_changed=1
install -m 0644 "$unit_file" /etc/systemd/system/zoer-ddev-bridge.service
rm -f "$unit_file"
systemctl daemon-reload
systemctl enable zoer-ddev-firewall.service zoer-ddev-bridge.service
# Restarting a Requires= dependency also stops the bridge. Reapply the rules
# directly so an unchanged setup does not interrupt active WordPress work.
/usr/local/sbin/zoer-ddev-firewall
systemctl start zoer-ddev-firewall.service
if [[ "$old_hash" != "$new_hash" || "$env_changed" == 1 || "$unit_changed" == 1 ]]; then systemctl restart zoer-ddev-bridge.service; else systemctl start zoer-ddev-bridge.service; fi
for attempt in {1..20}; do
  if printf 'header = "Authorization: Bearer %s"\n' "$token" | curl --config - -fsS --max-time 10 "http://$bind_ip:4085/health" 2>/dev/null | python3 -c 'import json,sys; assert json.load(sys.stdin)["ok"]' 2>/dev/null; then
    echo 'DDEV bridge ready; authenticated health check passed.'; exit 0
  fi
  sleep 1
done
echo 'DDEV bridge failed its health check; connector was not enabled.' >&2
exit 1
