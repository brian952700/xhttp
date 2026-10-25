"""Debian 13/systemd integration. Only public CA operations are replaced.

Runs only in the disposable CI container. Downloads/installs the real Xray core;
the local TLS certificate is self-signed and NEVER claims ACME validation.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

import pexpect

ROOT = Path('/workspace')
CONFIG = Path('/usr/local/etc/xray/config.json')
CERT = Path('/etc/xray-cert/server.crt')
KEY = Path('/etc/xray-cert/server.key')
FIXTURE = Path('/etc/xray-cert/acme/ci.example.test_ecc')
RAW = 'https://raw.githubusercontent.com/brian952700/xhttp/main/'
MENU = '请选择 [1-6]：'
PAUSE = '按 Enter 返回菜单…'


def run(*args, check=True, **kwargs):
    return subprocess.run(args, check=check, text=True, **kwargs)


def check(name, predicate):
    if not predicate:
        raise AssertionError(name)
    print(f'PASS: {name}', flush=True)


def content():
    return json.loads(CONFIG.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def active():
    return run('systemctl', 'is-active', '--quiet', 'xray', check=False).returncode == 0


def spawn(command, args=()):
    child = pexpect.spawn(command, list(args), encoding='utf-8', timeout=360)
    child.logfile_read = sys.stdout
    return child


def close(child):
    child.expect(pexpect.EOF)
    child.close()
    check('interactive command exit status', child.exitstatus == 0)


def resume(child):
    child.expect_exact(PAUSE)
    child.sendline('')
    child.expect_exact(MENU)


def certificate():
    run('openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
        '-nodes', '-days', '7', '-subj', '/CN=ci.example.test',
        '-addext', 'subjectAltName=DNS:ci.example.test',
        '-addext', 'basicConstraints=critical,CA:FALSE',
        '-keyout', str(FIXTURE / 'key.pem'), '-out', str(FIXTURE / 'fullchain.cer'))


def manager(code, check_result=True):
    return run('bash', '-c', 'source /usr/local/bin/xy\n' + code, check=check_result)


def proxy_test(uuid):
    cert_der = subprocess.check_output(['openssl', 'x509', '-in', str(CERT), '-outform', 'DER'])
    cert_pin = hashlib.sha256(cert_der).hexdigest()
    client_config = {
        'log': {'loglevel': 'warning'},
        'inbounds': [{'listen': '127.0.0.1', 'port': 10808, 'protocol': 'socks',
                      'settings': {'auth': 'noauth', 'udp': False}}],
        'outbounds': [{'protocol': 'vless', 'settings': {'vnext': [{
            'address': '127.0.0.1', 'port': 8443,
            'users': [{'id': uuid, 'encryption': 'none'}]}]},
            'streamSettings': {'network': 'xhttp', 'security': 'tls',
                'xhttpSettings': {'path': '/ci'},
                # Self-signed certificate is only used in this local CI test.
                'tlsSettings': {'serverName': 'ci.example.test', 'pinnedPeerCertSha256': cert_pin}}}]
    }
    client_file = Path('/tmp/ci-client.json')
    client_file.write_text(json.dumps(client_config))
    with open('/tmp/ci-client.log', 'w') as log:
        client = subprocess.Popen(['xray', 'run', '-config', str(client_file)], stdout=log, stderr=log)
        try:
            for _ in range(15):
                response = run('curl', '-fsS', '--max-time', '3', '--noproxy', '',
                    '--socks5-hostname', '127.0.0.1:10808', 'http://127.0.0.1:19080/',
                    check=False, capture_output=True)
                if response.returncode == 0:
                    check('VLESS+xHTTP+TLS transfers HTTP via SOCKS', response.stdout == 'xy-ci-ok\n')
                    return
                time.sleep(1)
            raise AssertionError('Local proxy failed: ' + response.stderr + Path('/tmp/ci-client.log').read_text())
        finally:
            client.terminate()
            client.wait(timeout=10)


def main():
    check('Debian 13', 'VERSION_ID="13"' in Path('/etc/os-release').read_text())
    check('real systemd PID 1', Path('/proc/1/comm').read_text().strip() == 'systemd')
    for script in ('xy.sh', 'install.sh', 'tests/acme-fixture.sh'):
        run('bash', '-n', str(ROOT / script))
    run('shellcheck', '--severity=error', str(ROOT / 'xy.sh'), str(ROOT / 'install.sh'))
    check('Bash syntax and ShellCheck error-level checks', True)

    FIXTURE.mkdir(parents=True)
    (FIXTURE / 'ci.example.test.conf').touch()
    certificate()
    shutil.copy(ROOT / 'tests/acme-fixture.sh', FIXTURE.parent / 'acme.sh')
    (FIXTURE.parent / 'acme.sh').chmod(0o755)

    # Verify anonymous public URLs and ensure this run tests this checkout.
    for name in ('install.sh', 'xy.sh'):
        downloaded = Path('/tmp') / ('public-' + name)
        run('curl', '-fsSL', '--retry', '3', RAW + name, '-o', str(downloaded))
        check('public URL exact checkout: ' + name, downloaded.read_bytes() == (ROOT / name).read_bytes())

    # Execute exactly the README one-command pipeline inside a controlling PTY.
    child = spawn('bash', ['-o', 'pipefail', '-c', f'curl -fsSL {RAW}install.sh | bash'])
    child.expect_exact('请输入域名（已解析到本服务器）：')
    child.sendline('ci.example.test')
    child.expect_exact('监听端口 [443]：')
    child.sendline('8443')
    child.expect_exact('xHTTP 路径 [/]：')
    child.sendline('/ci')
    child.expect_exact('安装/更新完成；证书续期回调已注册。')
    resume(child)
    check('downloaded manager matches checkout', Path('/usr/local/bin/xy').read_bytes() == (ROOT / 'xy.sh').read_bytes())
    check('real Xray service active after first install', active())
    run('systemctl', 'is-enabled', 'xray')
    run('systemctl', 'is-active', 'cron')
    check('independent renewal cron installed', Path('/etc/cron.d/xy-acme').is_file())
    admin = content()['inbounds'][0]['settings']['clients'][0]['id']

    username = 'ci "quoted" \\ user #&中文'
    child.sendline('2')
    child.expect_exact('请输入新用户名/邮箱：')
    child.sendline(username)
    child.expect_exact('已添加用户：' + username)
    resume(child)
    check('special-character user safely added', any(c['email'] == username for c in content()['inbounds'][0]['settings']['clients']))
    before = content()
    child.sendline('1')
    child.expect_exact('安装/更新完成；证书续期回调已注册。')
    resume(child)
    check('update preserves every existing user and setting', content() == before)

    child.sendline('3')
    child.expect_exact('请输入要删除的用户名/邮箱：')
    child.sendline(username)
    child.expect_exact('[y/N]：')
    child.sendline('y')
    child.expect_exact('已删除用户：' + username)
    resume(child)
    check('delete user preserves original UUID', content()['inbounds'][0]['settings']['clients'] == [{'id': admin, 'email': 'admin'}])
    child.sendline('3')
    child.expect_exact('请输入要删除的用户名/邮箱：')
    child.sendline('admin')
    child.expect_exact('[y/N]：')
    child.sendline('y')
    child.expect_exact('至少需要保留一个用户。')
    resume(child)
    child.sendline('6')
    close(child)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'xy-ci-ok\n')
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 19080), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    proxy_test(admin)

    before = CONFIG.read_bytes()
    Path('/tmp/invalid.json').write_text('{invalid')
    result = manager('lock\napply_config /tmp/invalid.json', check_result=False)
    check('invalid JSON rejected without changing live config', result.returncode != 0 and CONFIG.read_bytes() == before and active())

    busy = content()
    busy['inbounds'][0]['port'] = 19080  # occupied by the real HTTP server
    Path('/tmp/busy.json').write_text(json.dumps(busy))
    result = manager('lock\napply_config /tmp/busy.json', check_result=False)
    check('failed real service restart rolls back config and service', result.returncode != 0 and CONFIG.read_bytes() == before and active())

    old_cert = digest(CERT)
    certificate()
    shutil.copy(FIXTURE / 'fullchain.cer', '/etc/xray-cert/staging/server.crt')
    shutil.copy(FIXTURE / 'key.pem', '/etc/xray-cert/staging/server.key')
    run('/usr/local/bin/xy', '--renew-reload')
    check('renewal callback deploys matching new certificate', digest(CERT) != old_cert and active())
    good_cert, good_key = digest(CERT), digest(KEY)
    certificate()  # use only the new key, yielding a mismatched pair
    shutil.copy(FIXTURE / 'key.pem', '/etc/xray-cert/staging/server.key')
    result = run('/usr/local/bin/xy', '--renew-reload', check=False)
    check('mismatched certificate rejected without replacing active pair', result.returncode != 0 and digest(CERT) == good_cert and digest(KEY) == good_key and active())
    proxy_test(admin)

    # Bootstrap under sudo must still read the menu from /dev/tty.
    run('useradd', '-m', 'ciuser')
    sudoers = Path('/etc/sudoers.d/xy-ci')
    sudoers.write_text('ciuser ALL=(ALL) NOPASSWD: ALL\n')
    sudoers.chmod(0o440)
    before = CONFIG.read_bytes()
    child = spawn('runuser', ['-u', 'ciuser', '--', 'bash', '-o', 'pipefail', '-c', f'curl -fsSL {RAW}install.sh | bash'])
    child.expect_exact(MENU)
    child.sendline('6')
    close(child)
    check('non-root bootstrap preserves existing configuration', CONFIG.read_bytes() == before)

    shared = Path('/root/.acme.sh/unrelated-site.keep')
    shared.parent.mkdir(exist_ok=True)
    shared.write_text('must survive')
    child = spawn('/usr/local/bin/xy')
    child.expect_exact(MENU)
    child.sendline('5')
    child.expect_exact('确定彻底卸载？[y/N]：')
    child.sendline('y')
    child.expect_exact('卸载完成。')
    close(child)
    check('uninstall removes manager/config/cert/cron', all(not p.exists() for p in (CONFIG, CERT, KEY, Path('/usr/local/bin/xy'), Path('/etc/cron.d/xy-acme'))))
    check('uninstall preserves shared ACME directory', shared.read_text() == 'must survive')
    print('ALL INTEGRATION CHECKS PASSED. Public ACME issuance was NOT tested.', flush=True)


if __name__ == '__main__':
    main()
