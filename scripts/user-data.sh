# Boot script for the dev box (Amazon Linux 2023). Terraform prepends a shebang and exports:
#   AWS_REGION CODE_SERVER_PASSWORD_PARAM TAILSCALE_AUTHKEY_PARAM TAILSCALE_HOSTNAME EXTENSIONS_B64
# Safe to re-run by hand over Session Manager:  sudo bash /var/lib/cloud/instance/scripts/part-001
# Log: /var/log/devbox-init.log   (no `set -x` anywhere, so secrets never reach the log)
set -euo pipefail

# cloud-init runs user data with no HOME; the code-server installer needs it under `set -u`.
export HOME="${HOME:-/root}"

LOG=/var/log/devbox-init.log
exec > >(tee -a "$LOG") 2>&1
echo "=== devbox init started $(date -u +%FT%TZ) ==="

DEV_USER=ec2-user
DEV_HOME=/home/$DEV_USER
CS_PORT=8080

retry() { # retry <attempts> <cmd...>
  local n=$1 i=1
  shift
  until "$@"; do
    if ((i >= n)); then
      echo "FAILED after $n attempts: $*"
      return 1
    fi
    i=$((i + 1))
    sleep 5
  done
}

get_secret() { # get_secret <ssm-parameter-name>; value goes to stdout only
  retry 12 aws ssm get-parameter --region "$AWS_REGION" --name "$1" \
    --with-decryption --query Parameter.Value --output text
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
echo "--- packages"
cat >/etc/yum.repos.d/gh-cli.repo <<'REPO'
[gh-cli]
name=packages for the GitHub CLI
baseurl=https://cli.github.com/packages/rpm
enabled=1
gpgcheck=1
gpgkey=https://cli.github.com/packages/githubcli-archive-keyring.asc
REPO
cat >/etc/yum.repos.d/tailscale.repo <<'REPO'
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/amazon-linux/2023/$basearch
enabled=1
type=rpm
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://pkgs.tailscale.com/stable/amazon-linux/2023/repo.gpg
REPO

# AL2023 keeps /usr/bin/python3 at 3.9 for system tools; we add a newer side-by-side python3.13.
# AWS CLI v2 ships preinstalled on AL2023 ("awscli-2" if it ever goes missing).
retry 3 dnf install -y git docker gh tailscale python3.13 python3.13-pip java-21-amazon-corretto-devel
command -v aws >/dev/null || retry 3 dnf install -y awscli-2

systemctl enable --now docker
usermod -aG docker "$DEV_USER"

# ---------------------------------------------------------------------------
# code-server (official install script, rpm method) under systemd
# ---------------------------------------------------------------------------
echo "--- code-server"
if ! command -v code-server >/dev/null; then
  retry 3 bash -c 'curl -fsSL https://code-server.dev/install.sh | sh'
fi

install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.config/code-server"
CS_CONFIG="$DEV_HOME/.config/code-server/config.yaml"
CS_PASSWORD="$(get_secret "$CODE_SERVER_PASSWORD_PARAM")"
# Tradeoff: code-server reads a plaintext password from this 0600 file owned by the dev user.
# Anyone with root or that user on the box can read it; it is never logged or kept in Terraform.
(
  umask 077
  cat >"$CS_CONFIG" <<CONF
bind-addr: 127.0.0.1:$CS_PORT
auth: password
password: "$CS_PASSWORD"
cert: false
CONF
)
chown "$DEV_USER:$DEV_USER" "$CS_CONFIG"
unset CS_PASSWORD

# Bound to localhost only: the sole way in is the Tailscale HTTPS proxy below.
systemctl enable --now "code-server@$DEV_USER"

# Extensions are installed after the service is up; one failure does not stop the boot.
echo "--- extensions"
echo "$EXTENSIONS_B64" | base64 -d | sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' |
  while read -r ext; do
    sudo -H -u "$DEV_USER" code-server --install-extension "$ext" ||
      echo "WARN: could not install extension $ext"
  done

# ---------------------------------------------------------------------------
# Tailscale: ephemeral, tagged node; HTTPS (valid cert) on the tailnet name
# ---------------------------------------------------------------------------
echo "--- tailscale"
systemctl enable --now tailscaled
if ! tailscale status >/dev/null 2>&1; then
  KEYFILE=/run/ts-authkey
  (
    umask 077
    get_secret "$TAILSCALE_AUTHKEY_PARAM" >"$KEYFILE"
  )
  # The key's own settings (ephemeral, tags, pre-approved) are chosen when you create it.
  retry 3 tailscale up --auth-key="file:$KEYFILE" --hostname="$TAILSCALE_HOSTNAME"
  shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"
fi

# Needs "HTTPS Certificates" enabled in the Tailscale admin console (see README).
# `timeout` because tailscale serve waits for interactive approval if HTTPS is not enabled.
timeout 90 tailscale serve --bg --https=443 "http://127.0.0.1:$CS_PORT" ||
  echo "WARN: tailscale serve failed; check that HTTPS certificates are enabled for the tailnet"

# Best effort: leave the tailnet on shutdown so the next apply can reuse the hostname
# instead of getting devbox-1. Ephemeral nodes are also cleaned up by Tailscale when offline.
cat >/etc/systemd/system/tailscale-logout.service <<'UNIT'
[Unit]
Description=Leave the tailnet on shutdown
After=tailscaled.service network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/bin/tailscale logout

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now tailscale-logout.service

echo "=== devbox init finished $(date -u +%FT%TZ) ==="
