#!/usr/bin/env bash
set -Eeuo pipefail

COMFY_DIR="${COMFY_DIR:-$HOME/ComfyUI}"
COMFY_PORT="${COMFY_PORT:-8188}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="comfyui.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$SERVICE_NAME"
CURRENT_USER="$(id -un)"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

clone_or_update() {
  local repo_url="$1"
  local target_dir="$2"

  if [[ -d "$target_dir/.git" ]]; then
    git -C "$target_dir" pull --ff-only
  elif [[ -e "$target_dir" ]]; then
    die "$target_dir exists but is not a Git checkout"
  else
    git clone --depth=1 "$repo_url" "$target_dir"
  fi
}

configure_ipv6() {
  local answer="" config="/etc/sysctl.d/99-comfyui-disable-ipv6.conf"
  local connection="${SSH_CONNECTION:-}" client_ip
  client_ip="${connection%% *}"

  if ! sysctl -n net.ipv6.conf.all.disable_ipv6 >/dev/null 2>&1; then
    printf 'IPv6 is unavailable; skipping IPv6 configuration.\n'
    return
  fi
  printf '\nOptional: disable IPv6 on this entire VM, now and after reboot.\n'
  printf 'This affects every application and can interrupt IPv6 connections.\n'
  printf 'The localhost repair below fixes the ComfyUI loading issue without this change.\n'
  if [[ ! -t 0 ]]; then
    printf 'No interactive terminal; leaving IPv6 unchanged.\n'
    return
  fi
  read -r -p 'Disable IPv6 on this VM? [y/N] ' answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes) ;;
    *) printf 'Leaving IPv6 unchanged.\n'; return ;;
  esac
  if [[ "$client_ip" == *:* ]]; then
    die "This SSH connection uses IPv6. Reconnect using IPv4 before disabling IPv6."
  fi
  if sudo test -e "$config"; then
    sudo cp -a -- "$config" "$config.before-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  printf '%s\n' \
    '# Created by comfyui-setup after interactive confirmation.' \
    'net.ipv6.conf.all.disable_ipv6 = 1' \
    'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee "$config" >/dev/null
  sudo sysctl -p "$config"
  printf 'IPv6 disabled. Persistent configuration: %s\n' "$config"
}

ensure_localhost() {
  printf '==> Ensuring IPv4 and IPv6 localhost entries\n'
  sudo "$PYTHON_BIN" - <<'PY_HOSTS'
from pathlib import Path
import shutil
import time

path = Path('/etc/hosts')
original = path.read_text()
lines = original.splitlines(keepends=True)
for address in ('127.0.0.1', '::1'):
    for index, line in enumerate(lines):
        content, marker, comment = line.partition('#')
        fields = content.split()
        if fields and fields[0] == address:
            if 'localhost' not in fields[1:]:
                suffix = ' #' + comment.rstrip('\n') if marker else ''
                lines[index] = '\t'.join([*fields, 'localhost']) + suffix + '\n'
            break
    else:
        if lines and not lines[-1].endswith('\n'):
            lines[-1] += '\n'
        lines.append(address + '\tlocalhost\n')
updated = ''.join(lines)
if updated != original:
    backup = path.with_name('hosts.before-comfyui-' + time.strftime('%Y%m%dT%H%M%S'))
    shutil.copy2(path, backup)
    path.write_text(updated)
    print('Updated localhost entries; backup:', backup)
else:
    print('Localhost entries already present.')
PY_HOSTS

  # ComfyUI resolves both families even when IPv6 networking is disabled.
  "$PYTHON_BIN" - <<'PY_LOCALHOST'
import ipaddress
import signal
import socket
import sys

def fail(*_):
    sys.exit('localhost resolution failed or timed out; check /etc/hosts and the system resolver.')

signal.signal(signal.SIGALRM, fail)
signal.alarm(5)
try:
    for family in (socket.AF_INET, socket.AF_INET6):
        addresses = socket.getaddrinfo('localhost', None, family, socket.SOCK_STREAM)
        if not addresses or not all(ipaddress.ip_address(item[4][0]).is_loopback for item in addresses):
            fail()
except OSError:
    fail()
signal.alarm(0)
PY_LOCALHOST
}

printf '==> Preflight checks\n'
command -v sudo >/dev/null || die "sudo is required"
command -v nvidia-smi >/dev/null || die "NVIDIA drivers are not installed"
nvidia-smi >/dev/null || die "The NVIDIA GPU is not available"

if [[ ! -r /etc/os-release ]]; then
  die "This installer supports Ubuntu/Debian systems"
fi

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "This installer supports Ubuntu/Debian, not ${ID:-unknown}" ;;
esac

configure_ipv6

available_kb="$(df -Pk "$HOME" | awk 'NR == 2 {print $4}')"
if [[ "$available_kb" =~ ^[0-9]+$ ]] && (( available_kb < 30 * 1024 * 1024 )); then
  printf 'WARNING: less than 30 GiB is free. Models need substantial extra space.\n' >&2
fi

printf '==> Installing system packages, including aria2\n'
sudo apt-get update
sudo apt-get install -y \
  aria2 \
  build-essential \
  git \
  libgl1 \
  libglib2.0-0 \
  python3 \
  python3-dev \
  python3-venv

"$PYTHON_BIN" -c 'import sys; sys.exit("Python 3.10+ is required") if sys.version_info < (3, 10) else None'

ensure_localhost

printf '==> Installing or updating ComfyUI\n'
clone_or_update "https://github.com/Comfy-Org/ComfyUI.git" "$COMFY_DIR"

printf '==> Creating the private Python environment\n'
if [[ ! -x "$COMFY_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$COMFY_DIR/.venv"
fi
PYTHON="$COMFY_DIR/.venv/bin/python"

"$PYTHON" -m pip install --upgrade pip setuptools wheel

printf '==> Installing NVIDIA PyTorch and ComfyUI dependencies\n'
"$PYTHON" -m pip install --upgrade \
  torch torchvision torchaudio \
  --extra-index-url https://download.pytorch.org/whl/cu130
"$PYTHON" -m pip install -r "$COMFY_DIR/requirements.txt"
"$PYTHON" -m pip install -r "$COMFY_DIR/manager_requirements.txt"

printf '==> Installing model tools\n'
mkdir -p "$COMFY_DIR/custom_nodes"
clone_or_update \
  "https://github.com/Azornes/Comfyui-Model-Resolver.git" \
  "$COMFY_DIR/custom_nodes/Comfyui-Model-Resolver"
clone_or_update \
  "https://github.com/hayden-cn/ComfyUI-Model-Manager.git" \
  "$COMFY_DIR/custom_nodes/ComfyUI-Model-Manager"

for requirements in \
  "$COMFY_DIR/custom_nodes/Comfyui-Model-Resolver/requirements.txt" \
  "$COMFY_DIR/custom_nodes/ComfyUI-Model-Manager/requirements.txt"
do
  if [[ -f "$requirements" ]]; then
    "$PYTHON" -m pip install -r "$requirements"
  fi
done

printf '==> Creating model directories\n'
mkdir -p "$COMFY_DIR/models"/{checkpoints,clip,clip_vision,controlnet,diffusion_models,embeddings,loras,text_encoders,unet,upscale_models,vae,vae_approx}

printf '==> Verifying PyTorch GPU support\n'
"$PYTHON" -c 'import sys, torch; sys.exit("PyTorch installed, but CUDA is not available") if not torch.cuda.is_available() else None; print(f"PyTorch: {torch.__version__}"); print(f"CUDA:   {torch.version.cuda}"); print(f"GPU:    {torch.cuda.get_device_name(0)}")'

printf '==> Creating user service\n'
mkdir -p "$UNIT_DIR"
{
  printf '%s\n' \
    '[Unit]' \
    'Description=ComfyUI' \
    'After=network-online.target' \
    'Wants=network-online.target' \
    '' \
    '[Service]' \
    'Type=simple'
  printf 'WorkingDirectory=%s\n' "$COMFY_DIR"
  printf 'ExecStart="%s" "%s/main.py" --listen 127.0.0.1 --port %s --enable-manager --preview-method auto\n' \
    "$PYTHON" "$COMFY_DIR" "$COMFY_PORT"
  printf '%s\n' \
    'Environment=PYTHONUNBUFFERED=1' \
    'Restart=on-failure' \
    'RestartSec=5' \
    '' \
    '[Install]' \
    'WantedBy=default.target'
} > "$UNIT_PATH"

# Keep the user's service manager available after SSH logout and across reboots.
if command -v loginctl >/dev/null; then
  sudo loginctl enable-linger "$CURRENT_USER"
fi

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

printf '==> Waiting for ComfyUI to answer browser requests\n'
if ! "$PYTHON" - "$COMFY_PORT" <<'PY_READY'
import sys
import time
import urllib.error
import urllib.request

port = int(sys.argv[1])
origin = f'http://localhost:{port}'
request = urllib.request.Request(
    f'http://127.0.0.1:{port}/system_stats',
    headers={'Host': f'localhost:{port}', 'Origin': origin},
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
deadline = time.monotonic() + 120
last_error = None
while time.monotonic() < deadline:
    try:
        with opener.open(request, timeout=5) as response:
            response.read()
            if response.status == 200:
                break
    except (OSError, urllib.error.URLError) as error:
        last_error = error
    time.sleep(1)
else:
    sys.exit(f'ComfyUI did not answer within 120 seconds: {last_error}')
PY_READY
then
  journalctl --user -u "$SERVICE_NAME" -n 80 --no-pager >&2
  die "ComfyUI did not become ready"
fi

printf '\nComfyUI is ready on the VM at 127.0.0.1:%s\n' "$COMFY_PORT"
printf 'Forward remote port %s to the same local port, then open:\n' "$COMFY_PORT"
printf 'http://127.0.0.1:%s\n' "$COMFY_PORT"
printf '\nLogs: journalctl --user -u %s -f\n' "$SERVICE_NAME"
