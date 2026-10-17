#!/usr/bin/env python3
"""Exercise network setup without changing host networking or installing packages."""
from pathlib import Path
import os
import pty
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'comfy.sh').read_text()
FUNCTION = SCRIPT.split('configure_ipv6() {', 1)[1].split('\nensure_localhost()', 1)[0]
FUNCTION = 'configure_ipv6() {' + FUNCTION


def prompt_case(answer, *, interactive=True, connection='', available=True):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        log = root / 'calls'
        config = root / 'config'
        (root / 'sysctl').write_text('#!/bin/sh\nexit ' + ('0' if available else '1') + '\n')
        (root / 'sudo').write_text('''#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
case "$1" in
  test) exit 1 ;;
  tee) cat > "$TEST_CONFIG" ;;
  sysctl) exit 0 ;;
  *) exit 99 ;;
esac
''')
        for name in ('sudo', 'sysctl'):
            (root / name).chmod(0o755)
        harness = root / 'prompt.sh'
        harness.write_text('set -Eeuo pipefail\ndie() { echo "$*" >&2; exit 1; }\n' + FUNCTION + '\nconfigure_ipv6\n')
        env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
               'TEST_LOG': str(log), 'TEST_CONFIG': str(config)}
        env.pop('SSH_CONNECTION', None)
        if connection:
            env['SSH_CONNECTION'] = connection
        if interactive:
            master, slave = pty.openpty()
            proc = subprocess.Popen(['bash', str(harness)], stdin=slave, stdout=slave,
                                    stderr=slave, env=env)
            os.close(slave)
            output = b''
            sent = False
            deadline = time.monotonic() + 8
            try:
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], 0.1)
                    if ready:
                        try:
                            chunk = os.read(master, 8192)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output += chunk
                        if b'[y/N]' in output and not sent:
                            os.write(master, answer.encode())
                            sent = True
                    if proc.poll() is not None:
                        break
                status = proc.wait(timeout=2)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                os.close(master)
        else:
            result = subprocess.run(['bash', str(harness)], input=answer, text=True,
                                    capture_output=True, env=env, timeout=5)
            status = result.returncode
        return status, log.read_text() if log.exists() else '', config.read_text() if config.exists() else ''


for name, answer, kwargs in (
    ('default no', '\n', {}), ('explicit no', 'n\n', {}),
    ('invalid answer', 'maybe\n', {}), ('EOF', '\x04', {}),
    ('unattended yes', 'yes\n', {'interactive': False}),
    ('IPv6 unavailable', 'yes\n', {'available': False}),
):
    status, calls, config = prompt_case(answer, **kwargs)
    assert status == 0 and not calls and not config, (name, status, calls)
    print('PASS:', name)

status, calls, config = prompt_case('yes\n')
assert status == 0 and 'sysctl -p /etc/sysctl.d/99-comfyui-disable-ipv6.conf' in calls
assert 'net.ipv6.conf.all.disable_ipv6 = 1' in config
assert 'net.ipv6.conf.default.disable_ipv6 = 1' in config
print('PASS: interactive yes writes and applies only the named configuration')

status, calls, config = prompt_case('yes\n', connection='2001:db8::1 12345 2001:db8::2 22')
assert status != 0 and not calls and not config
print('PASS: IPv6 SSH connection is refused before changes')

hosts_code = SCRIPT.split("<<'PY_HOSTS'\n", 1)[1].split('\nPY_HOSTS', 1)[0]
for original in (
    '127.0.0.1 localhost\n::1 ip6-localhost ip6-loopback # keep aliases\n',
    '127.0.0.1 localhost',
    '127.0.0.1 localhost\n::1 localhost ip6-localhost\n',
):
    with tempfile.TemporaryDirectory() as temporary:
        hosts = Path(temporary) / 'hosts'
        hosts.write_text(original)
        code = hosts_code.replace("Path('/etc/hosts')", f'Path({str(hosts)!r})')
        subprocess.run(['python3', '-c', code], check=True, capture_output=True)
        first = hosts.read_text()
        assert any(line.split()[:2] == ['127.0.0.1', 'localhost'] for line in first.splitlines())
        assert any(line.startswith('::1') and 'localhost' in line.split('#')[0].split()[1:] for line in first.splitlines())
        if 'ip6-loopback' in original:
            assert 'ip6-loopback' in first and '# keep aliases' in first
        backups = list(Path(temporary).glob('hosts.before-comfyui-*'))
        assert bool(backups) == (first != original)
        if backups:
            assert backups[0].read_text() == original
        subprocess.run(['python3', '-c', code], check=True, capture_output=True)
        assert hosts.read_text() == first
print('PASS: hosts repair preserves aliases, comments and backups, and is idempotent')
