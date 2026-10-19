#!/usr/bin/env bash
# Operator-managed SSH for an explicitly selected Zoer computer. No app rollout.
set -Eeuo pipefail
umask 077
state=/var/lib/zoer-runtime/ssh
control=/run/zoer-ssh
config=/opt/zoer-ssh/sshd_config

if [[ ${1:-} == supervise ]]; then
  echo "$BASHPID" > "$control/supervisor.pid"
  child=
  trap '[[ -z "$child" ]] || kill "$child" 2>/dev/null || true; exit 0' TERM INT
  while true; do
    /usr/sbin/sshd -D -e -f "$config" &
    child=$!
    wait "$child" || true
    sleep 3
  done
fi

[[ $(id -u) == 0 ]] || { echo 'SSH setup requires the computer root account.' >&2; exit 1; }
mountpoint -q /var/lib/zoer-runtime || { echo 'Private computer storage is required.' >&2; exit 1; }
mkdir -p "$state/packages" "$control" /run/sshd
chmod 700 "$state" "$control"
# Duplicate startup hooks must not install packages or launch competing daemons.
exec 9>"$control/setup.lock"
flock 9
if [[ -s "$control/supervisor.pid" ]] && kill -0 "$(cat "$control/supervisor.pid")" 2>/dev/null; then
  exit 0
fi

if [[ ! -x /usr/sbin/sshd ]]; then
  # The Kasm image blocks automatic package service startup. Refuse an image
  # without that protection: installing the package must not expose port 22.
  policy_status=0
  /usr/sbin/policy-rc.d ssh start >/dev/null 2>&1 || policy_status=$?
  [[ $policy_status == 101 ]] || { echo 'Image must block automatic package service startup (policy-rc.d=101).' >&2; exit 1; }
  shopt -s nullglob
  packages=("$state/packages/"*.deb)
  if [[ ${#packages[@]} -gt 0 ]]; then
    dpkg -i "${packages[@]}"
  else
    # Use the image's Ubuntu repositories, excluding unrelated third-party
    # apt sources. Cache the downloaded packages for offline pod replacement.
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Dir::Etc::sourcelist=/etc/apt/sources.list -o Dir::Etc::sourceparts=- update
    apt-get -o Dir::Cache::archives="$state/packages" -o APT::Keep-Downloaded-Packages=true \
      install -y --no-install-recommends openssh-server
    packages=("$state/packages/"*.deb)
    [[ ${#packages[@]} -gt 0 ]] || { echo 'SSH package cache was not retained.' >&2; exit 1; }
  fi
fi

# The computer entrypoint may remap the account to its existing workspace UID.
# Resolve ownership by account name, never by an assumed fixed UID.
chown kasm-user:kasm-user "$state"
ssh-keygen -lf /opt/zoer-ssh/authorized_keys >/dev/null
install -d -o kasm-user -g kasm-user -m 700 /home/kasm-user/.ssh
# Use the mode-700 HOME mount so StrictModes can check every parent.
# Leave the user's ordinary authorized_keys file untouched.
install -o kasm-user -g kasm-user -m 600 /opt/zoer-ssh/authorized_keys /home/kasm-user/.ssh/zoer-managed-authorized_keys
if [[ ! -s "$state/ssh_host_ed25519_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -f "$state/ssh_host_ed25519_key"
fi
chmod 600 "$state/ssh_host_ed25519_key"
/usr/sbin/sshd -t -f "$config"
# Close the setup lock in the detached supervisor; it must not hold it forever.
nohup setsid /bin/bash "$0" supervise 9>&- </dev/null >"$control/log" 2>&1 &
for attempt in {1..50}; do
  [[ ! -s "$control/supervisor.pid" ]] || { echo 'Managed computer SSH started on port 2222.'; exit 0; }
  sleep .1
done
echo 'SSH supervisor did not start.' >&2
exit 1
