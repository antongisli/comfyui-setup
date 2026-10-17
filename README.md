# ComfyUI setup

Install ComfyUI on an Ubuntu or Debian VM with an NVIDIA GPU. The installer creates a Python virtual environment and a persistent systemd user service listening on `127.0.0.1:8188`.

## Run

Clone this repository onto the GPU VM, review `comfy.sh`, then run:

```bash
bash comfy.sh
```

The VM needs working NVIDIA drivers, sudo access, internet access, and enough free disk space for the models you plan to use. The script installs or updates ComfyUI and its Python dependencies. Rerunning it also restarts the service, so finish active jobs first.

The installer includes ComfyUI Manager, Model Resolver, Model Manager, and aria2. It checks CUDA support and waits for an actual HTTP response before reporting readiness. Models and access tokens are not included.

Use SSH forwarding from your computer:

```bash
ssh -N -L 127.0.0.1:8188:127.0.0.1:8188 user@gpu-host
```

Then open <http://127.0.0.1:8188>. The application port stays private to the VM; the SSH connection carries the traffic.

## Localhost and IPv6

The installer ensures `/etc/hosts` maps `localhost` to both `127.0.0.1` and `::1`, preserving existing aliases and saving a backup before changes. ComfyUI checks both address families when validating browser origins. A missing mapping can trigger a slow DNS lookup that blocks the server and leaves the browser loading indefinitely. The installer checks that both lookups complete within five seconds.

It also asks:

```text
Disable IPv6 on this VM? [y/N]
```

Only an explicit yes in an interactive terminal enables this option. Enter, no, or a noninteractive run leaves IPv6 unchanged. The option affects the whole VM, takes effect immediately, and persists through `/etc/sysctl.d/99-comfyui-disable-ipv6.conf`. It can interrupt IPv6 connections, so the installer refuses to apply it over an IPv6 SSH connection. Existing configuration at that path is backed up.

Disabling IPv6 is optional; the localhost repair addresses the loading issue independently. The `::1 localhost` hosts entry remains useful for ComfyUI's hostname checks even with IPv6 networking disabled.

To undo this installer's IPv6 setting on a VM that previously had IPv6 enabled:

```bash
sudo rm /etc/sysctl.d/99-comfyui-disable-ipv6.conf
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0
```

If that file existed before installation, restore its saved backup instead and apply it with `sudo sysctl -p /path/to/restored-file`. Other system or network configuration may also govern IPv6. See the [Linux kernel's IPv6 sysctl documentation](https://docs.kernel.org/networking/ip-sysctl.html#proc-sys-net-ipv6-variables).

## Settings and service

Optional environment variables: `COMFY_DIR` (default `~/ComfyUI`), `COMFY_PORT` (default `8188`), and `PYTHON_BIN` (default `python3`).

```bash
systemctl --user status comfyui.service
journalctl --user -u comfyui.service -f
systemctl --user restart comfyui.service
systemctl --user stop comfyui.service
```

## Checks

```bash
bash -n comfy.sh
shellcheck comfy.sh
python3 tests/check_network_setup.py
```

The checks exercise the confirmation paths and hosts-file repair using temporary fixtures and mocked system commands. They do not install packages or change the test machine's networking.
