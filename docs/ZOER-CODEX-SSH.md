# Codex SSH access to OTE Zoer computers

This operator pilot connects the desktop Codex app to an explicitly selected
Kubernetes computer on https://zoer.k8s.overtheedgepaper.ca. It is **partial**:
there is no Zoer SSH settings UI or automatic enablement for new computers.
DDEV, Colab, Coder and other connector runtimes are outside this helper's scope.

## Network

The node is 10.70.20.50. UniFi's OTE-Users LAN is 10.70.30.0/24; its existing
WireGuard Server uses 192.168.3.0/24 (observed 2026-10-08). Test directly on the
LAN first, then from an off-site laptop with its own existing WireGuard client.
WireGuard is a laptop-to-UniFi connection; it does not run inside the computers.
The HTTPS dashboard/Traefik address is separate from the node's SSH ports.

Each enabled computer has one dedicated NodePort Service, with
externalTrafficPolicy: Local to preserve the connecting address. Source
restrictions are also enforced by sshd's AllowUsers user@CIDR. UniFi routing
and firewall must allow the approved VPN client to reach that node/port. This
helper does not modify UniFi, WAN forwarding, Kubernetes credentials, or other
computer Services. NodePorts are node listeners; source restrictions here are
SSH authentication restrictions, not a claim of network-level port isolation.

## Enable one computer

Generate a device key on the connecting laptop; retain its private half there.
Use a different WireGuard client configuration for each remote device.

    ssh-keygen -t ed25519 -f ~/.ssh/zoer-ote-codex
    python3 scripts/zoer-computer-ssh.py plan \
      --computer <existing-computer-deployment> \
      --public-key ~/.ssh/zoer-ote-codex.pub \
      --allowed-source 10.70.30.0/24 --allowed-source 192.168.3.0/24

Review the selected computer, sources and allocated port, then use enable.
For sandboxed Codex command execution, first complete the opt-in AppArmor setup
below and include `--sandbox-profile zoer-codex-computer` in plan and enable.
After enable, register the connection on this laptop with:

    python3 scripts/zoer-computer-ssh.py client \
      --computer <existing-computer-deployment> --alias zoer-ote-<name> \
      --identity-file ~/.ssh/zoer-ote-codex

Client pins the public host key read through Kubernetes, writes a dedicated
SSH include, and preserves unrelated local SSH aliases. It rejects unexpected
host-key changes instead of silently trusting them.

Enable checks the existing private runtime PVC and active workflow ownership,
then installs a per-computer ConfigMap startup hook and rolls only that computer.
Other deployments and storage are preserved. Existing postStart hooks are
rejected rather than overwritten. The supplied public-key list is the complete
managed access list; supplying a replacement list revokes omitted keys and
terminates the existing managed SSH sessions after configuration read-back.
Do not enable or restart a computer with an active native Codex task: native
desktop tasks are not fully represented by Zoer's workflow reservation field.
Managed computers use Recreate rollouts to avoid two pods writing one private
HOME concurrently; disable restores the original deployment strategy.

The current Ubuntu/Kasm image installs two Ubuntu OpenSSH packages on first
startup. Their debs are retained in the existing private runtime volume and
reinstalled after pod replacement without requiring a new download. The image
must block package service autostart (policy-rc.d=101). Incompatible image or
package updates require explicit requalification; this is an operator pilot,
not an image-independent package manager. No application/container rebuild is
needed for this scoped startup addition.

The SSH identity persists under /var/lib/zoer-runtime/ssh. Managed client keys
use /home/kasm-user/.ssh/zoer-managed-authorized_keys, separate from the user's
ordinary authorized_keys. Root/password/keyboard-interactive login is disabled.
SSH runs as kasm-user after authentication. Local forwards to computer loopback
and Unix sockets support the app; agent, remote and X11 forwarding are disabled.
The existing Codex HOME, PATH and local SQLite environment are retained.
The existing Kasm account has passwordless sudo: authorized SSH users can
administer the entire selected computer. Root-login rejection does not remove
that existing account permission.

## Codex container sandbox support

The runtime's standard containerd AppArmor profile denies mounts. Codex's
Bubblewrap sandbox needs nested mount namespaces, and can fail with
`bwrap: Failed to make / slave: Permission denied`. CLI app-server versions
that isolate their control sockets also require Bubblewrap even if the
deprecated Landlock compatibility flag is available.

Install the dedicated enforcing profile on the selected node once:

    python3 scripts/zoer-install-codex-sandbox.py

The installer validates the SSH address against the selected node's InternalIP,
compiles the profile before loading it, writes it under `/etc/apparmor.d` for
normal AppArmor boot loading, and labels the node only after confirming that the
profile is enforcing. It preserves unrelated profiles and node settings.
Profile updates affect computers already using that profile; qualify a new
profile name before future incompatible changes. This pilot targets the OTE
single-node cluster; scheduling and NodePort locality need separate review on
a multi-node cluster.

Enable SSH and the profile for one explicitly selected, idle computer:

    python3 scripts/zoer-computer-ssh.py enable \
      --computer <existing-computer-deployment> \
      --public-key ~/.ssh/zoer-ote-codex.pub \
      --allowed-source 10.70.30.0/24 --allowed-source 192.168.3.0/24 \
      --sandbox-profile zoer-codex-computer

The computer restarts when its profile changes. The helper records the previous
AppArmor setting and scheduling selector, retains other securityContext fields,
and restores those settings on disable. It selects a labeled node with the
loaded profile and rejects privileged mode, CAP_SYS_ADMIN/ALL capabilities,
host namespaces, hostPath volumes and unrelated custom AppArmor profiles.

The profile allows Bubblewrap's user-namespace, pivot and mount operations while
retaining the standard containerd proc/sys denial rules. These mount permissions
apply to all processes in that selected computer; kernel capability boundaries
still apply, and the outer container has no CAP_SYS_ADMIN. Codex continues to
enforce read-only/workspace-write and its separate network policy. This does
not grant native Zoer tools to an SSH chat. Ordinary SSH account access retains
its existing sudo permissions. The read-only qualification chat's sudo metadata
probe was blocked by the sandbox's setuid restrictions.

Qualify each computer after selecting the profile or upgrading the image/CLI:

    python3 tests/qualify_codex_ssh.py zoer-ote-ahmad

This checks the outer capability bound, enforcing profile, shell execution,
read-only write denial, workspace file creation/read-back/cleanup and HOME write
denial from a workspace-write session. It creates only its own temporary probe
file and does not request model inference. Start standalone app-server probes
from `/workspace`; otherwise command/exec's default writable project root can
be the SSH login directory. Also run a real chat through the native Codex app.

The node's full reboot path remains untested. If a node loses the profile,
Localhost-profile pods fail to start; restore the same profile before starting
them. Keep the node file/label while any running or stopped computer references
it. No container image or backend/frontend rollout is required for this setup.

## Connect and verify

Obtain the host public key through the trusted Kubernetes connection, then pin
it in a dedicated client known_hosts file. Never use a network key scan as the
only source of initial trust. Keep the SSH alias stable across pod replacement.

    Host zoer-ote-ahmad
      HostName 10.70.20.50
      Port 30022
      User kasm-user
      IdentityFile ~/.ssh/zoer-ote-codex
      IdentitiesOnly yes
      HostKeyAlias zoer-ote-ahmad
      UserKnownHostsFile ~/.ssh/known_hosts_zoer_ote
      StrictHostKeyChecking yes

Verify SSH id, command -v codex and codex login status, then add the alias in
Codex Settings → Connections → SSH and choose /workspace. A newly created
computer needs its own Codex installation and ChatGPT sign-in; no credentials
are copied from the pilot. SSH access shares that computer's Unix account,
files and CLI account. Different people needing isolated accounts require
separate computers. Zoer browser tools and chat mirroring are separate work.

Test correct-key access, wrong-key and root rejection, app-server protocol,
loopback forwarding, a fresh computer, and identity/package persistence after
pod replacement. LAN success does not establish off-site WireGuard success.

## Another laptop or a new computer

For each laptop, generate its own SSH key locally and give the operator only
the `.pub` file. On the LAN, connect directly; off site, connect that laptop's
WireGuard profile first. Never share another laptop's private SSH key or VPN
private key. The connecting laptop does not need Kubernetes administrator
credentials.

The operator reruns `enable` for the selected computer with **all** public-key
files that should retain access, repeating `--public-key` for each, and the
approved `--allowed-source` CIDRs. This replaces the managed key list and ends
existing managed SSH sessions, so coordinate with anyone using it. For another
Zoer computer, create it through the dashboard with Installed CLI → Codex,
wait for its runtime and CLI installation, then enable SSH with that computer's
deployment ID and an unused NodePort. Each computer gets a distinct persistent
host key and port; this is currently an operator step.

The operator supplies the laptop's Host block (use `~/.ssh/zoer-ote-codex` and
`~/.ssh/known_hosts_zoer_ote` for its local paths) and a host-key record obtained
with the trusted cluster connection:

    kubectl --kubeconfig ~/.kube/ote-k3s.yaml -n zoer \
      exec deploy/<computer-id> -c computer -- \
      cat /var/lib/zoer-runtime/ssh/ssh_host_ed25519_key.pub

Add `<ssh-alias> ssh-ed25519 <public-key-base64>` to the laptop's dedicated
known_hosts file, using that public key and the same HostKeyAlias as its config.
Verify its fingerprint against the operator's `status` output before connecting.
Keep both SSH files private to the local user (mode 600). Then verify SSH and
add the alias in Codex Settings → Connections → SSH.

The fresh test computer can be signed in from this Mac with:

    ssh -t zoer-ote-fresh-test 'codex login --device-auth'

Follow the displayed browser/code instructions, then verify `codex login status`.
Device authentication may need enabling in the intended ChatGPT account.
Keep the CLI's sign-in inside that computer; do not copy Ahmad's auth files.

The dated pilot results, computer IDs, endpoints and remaining manual checks are
in [the qualification record](../output/ui-audit/2026-10-08-codex-ssh.md).

## Status and recovery

Native desktop SSH chats do not inherit Zoer's Installed CLI MCP connection.
The Zoer repository now contains a partial browser-only operator connection in
`docs/codex-ssh-browser-tools.md` and `scripts/zoer-ssh-browser-tools.py`. After
deploying its backend, bind a dedicated existing Zoer chat to each running SSH
computer. Observation is the default; explicit browser interaction is separate
from Codex shell permissions. Grants expire after fifteen minutes and are shared
by native chats on that computer account. Do not copy another computer's lease
or hand the SSH client backend credentials. Actual rollout and native/provider
qualification are recorded in
[the MCP audit](../output/ui-audit/2026-10-08-ssh-browser-tools.md).

Status reports the port and fingerprint. Disable removes its dedicated Service,
restores the original startup lifecycle, rolls the selected computer to end
SSH sessions, and preserves its host identity and package cache. Stop/start
through Zoer also preserves the Service and identity. Trashing a computer does
not currently remove these operator-managed resources; disable SSH before
archiving/purging. The helper never deletes a computer, workspace PVC or
project database.

References: [Codex SSH setup](https://learn.chatgpt.com/docs/remote-connections#connect-to-an-ssh-host),
[UniFi WireGuard](https://help.ui.com/hc/en-us/articles/115005445768-UniFi-Gateway-WireGuard-VPN-Server),
[OpenSSH AllowUsers](https://man.openbsd.org/sshd_config#AllowUsers),
[Kubernetes NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport).
