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
MENU = '请选择 [1-8]：'
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


def certificate(domain='ci.example.test'):
    fixture = FIXTURE.parent / (domain + '_ecc')
    fixture.mkdir(parents=True, exist_ok=True)
    (fixture / (domain + '.conf')).touch()
    run('openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
        '-nodes', '-days', '7', '-subj', '/CN=' + domain,
        '-addext', 'subjectAltName=DNS:' + domain,
        '-addext', 'basicConstraints=critical,CA:FALSE',
        '-keyout', str(fixture / 'key.pem'), '-out', str(fixture / 'fullchain.cer'))


def manager(code, check_result=True, **kwargs):
    return run('bash', '-c', 'source /usr/local/bin/xy\n' + code, check=check_result, **kwargs)


def proxy_test(uuid, domain='ci.example.test'):
    cert_der = subprocess.check_output(['openssl', 'x509', '-in', str(CERT), '-outform', 'DER'])
    cert_pin = hashlib.sha256(cert_der).hexdigest()
    client_config = {
        'log': {'loglevel': 'info'},
        'inbounds': [{'listen': '127.0.0.1', 'port': 10808, 'protocol': 'socks',
                      'settings': {'auth': 'noauth', 'udp': False}}],
        'outbounds': [{'protocol': 'vless', 'settings': {'vnext': [{
            'address': '127.0.0.1', 'port': 8443,
            'users': [{'id': uuid, 'encryption': 'none'}]}]},
            'streamSettings': {'network': 'xhttp', 'security': 'tls',
                'xhttpSettings': {'path': '/ci'},
                # Self-signed certificate is only used in this local CI test.
                'tlsSettings': {'serverName': domain, 'pinnedPeerCertSha256': cert_pin}}}]
    }
    client_file = Path('/tmp/ci-client.json')
    client_file.write_text(json.dumps(client_config))
    with open('/tmp/ci-client.log', 'w') as log:
        client = subprocess.Popen(['xray', 'run', '-config', str(client_file)], stdout=log, stderr=log)
        try:
            for _ in range(3):
                response = run('curl', '-fsS', '--max-time', '5', '--noproxy', '',
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
    child.sendline('7')
    child.expect_exact('Xray 服务已重启并正常运行。')
    resume(child)
    check('restart menu preserves settings and users', active() and content()['inbounds'][0]['settings']['clients'][0]['id'] == admin)
    before = (CONFIG.read_bytes(), digest(CERT), digest(KEY))
    child.sendline('8')
    child.expect_exact('请输入新域名（留空保留当前域名，仅更新证书）：')
    child.sendline('')
    child.expect_exact('强制重新签发证书？重复操作可能触发 CA 限额 [y/N]：')
    child.sendline('n')
    child.expect_exact('确定更新域名及证书？[y/N]：')
    child.sendline('n')
    resume(child)
    check('cancel certificate update leaves files unchanged', before == (CONFIG.read_bytes(), digest(CERT), digest(KEY)))
    child.sendline('8')
    child.expect_exact('请输入新域名（留空保留当前域名，仅更新证书）：')
    child.sendline('https://invalid/')
    child.expect_exact('域名格式错误')
    resume(child)
    child.sendline('6')
    close(child)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Length', str(len(b'xy-ci-ok\n')))
            self.end_headers()
            self.wfile.write(b'xy-ci-ok\n')
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 19080), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    direct = run('curl', '-fsS', '--max-time', '5', '--noproxy', '*', 'http://127.0.0.1:19080/', capture_output=True)
    check('local HTTP fixture responds directly', direct.stdout == 'xy-ci-ok\n')
    debug_config = content()
    debug_config['log']['loglevel'] = 'info'
    Path('/tmp/debug-server.json').write_text(json.dumps(debug_config))
    manager('lock\napply_config /tmp/debug-server.json')
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
    shutil.copy(FIXTURE / 'fullchain.cer', '/etc/xray-cert/staging/ci.example.test/server.crt')
    shutil.copy(FIXTURE / 'key.pem', '/etc/xray-cert/staging/ci.example.test/server.key')
    run('/usr/local/bin/xy', '--renew-reload', 'ci.example.test')
    check('renewal callback deploys matching new certificate', digest(CERT) != old_cert and active())
    good_cert, good_key = digest(CERT), digest(KEY)
    certificate()  # use only the new key, yielding a mismatched pair
    shutil.copy(FIXTURE / 'key.pem', '/etc/xray-cert/staging/ci.example.test/server.key')
    result = run('/usr/local/bin/xy', '--renew-reload', 'ci.example.test', check=False)
    check('mismatched certificate rejected without replacing active pair', result.returncode != 0 and digest(CERT) == good_cert and digest(KEY) == good_key and active())
    proxy_test(admin)


    # Exercise domain/certificate operations against real Xray, with CA calls replaced.
    certificate()  # repair deliberately mismatched fixture above
    domain_file = Path('/etc/xray-cert/domain.txt')
    baseline = (CONFIG.read_bytes(), domain_file.read_bytes(), digest(CERT), digest(KEY))
    result = manager('update_domain_cert', check_result=False, input='missing.example.test\ny\n')
    check('failed certificate issuance preserves live state', result.returncode != 0 and
          baseline == (CONFIG.read_bytes(), domain_file.read_bytes(), digest(CERT), digest(KEY)) and active())

    certificate('wrong.example.test')
    shutil.copy(FIXTURE / 'fullchain.cer', FIXTURE.parent / 'wrong.example.test_ecc/fullchain.cer')
    shutil.copy(FIXTURE / 'key.pem', FIXTURE.parent / 'wrong.example.test_ecc/key.pem')
    result = manager('update_domain_cert', check_result=False, input='wrong.example.test\ny\n')
    check('wrong-domain certificate rejected without changing live state', result.returncode != 0 and
          baseline == (CONFIG.read_bytes(), domain_file.read_bytes(), digest(CERT), digest(KEY)) and active())

    certificate('next.example.test')
    # Inject failure only in the first restart; rollback must really restart Xray.
    rollback_code = """eval "$(declare -f healthy_restart | sed '1s/healthy_restart/real_restart/')"
healthy_restart() {
    if [[ ! -e /tmp/xy-fail-once ]]; then touch /tmp/xy-fail-once; return 1; fi
    real_restart
}
update_domain_cert"""
    result = manager(rollback_code, check_result=False, input='next.example.test\ny\n')
    check('failed domain deployment restores domain/config/certificates/service', result.returncode != 0 and
          baseline == (CONFIG.read_bytes(), domain_file.read_bytes(), digest(CERT), digest(KEY)) and active())

    child = spawn('/usr/local/bin/xy')
    child.expect_exact(MENU)
    child.sendline('8')
    child.expect_exact('请输入新域名（留空保留当前域名，仅更新证书）：')
    child.sendline('next.example.test')
    child.expect_exact('确定更新域名及证书？[y/N]：')
    child.sendline('y')
    child.expect_exact('域名及证书更新完成。')
    child.expect_exact('@next.example.test:8443')
    resume(child)
    check('domain change preserves full Xray config', CONFIG.read_bytes() == baseline[0])
    check('domain change deploys matching certificate and domain', domain_file.read_text().strip() == 'next.example.test' and active())
    child.sendline('6')
    close(child)
    proxy_test(admin, 'next.example.test')
    current_cert = digest(CERT)
    run('/usr/local/bin/xy', '--renew-reload', 'ci.example.test')
    check('old domain callback cannot replace new certificate', digest(CERT) == current_cert and active())

    # Force a same-domain renewal through the menu and verify actual certificate replacement.
    certificate('next.example.test')
    child = spawn('/usr/local/bin/xy')
    child.expect_exact(MENU)
    child.sendline('8')
    child.expect_exact('请输入新域名（留空保留当前域名，仅更新证书）：')
    child.sendline('')
    child.expect_exact('强制重新签发证书？重复操作可能触发 CA 限额 [y/N]：')
    child.sendline('y')
    child.expect_exact('确定更新域名及证书？[y/N]：')
    child.sendline('y')
    child.expect_exact('域名及证书更新完成。')
    resume(child)
    child.sendline('6')
    close(child)
    check('same-domain certificate refresh preserves configuration', CONFIG.read_bytes() == baseline[0] and digest(CERT) != current_cert and active())
    proxy_test(admin, 'next.example.test')

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
