#!/usr/bin/env python3
"""Run with Python 3 on Windows/Linux with adb on PATH and one device attached."""
from pathlib import Path
import datetime
import shutil
import subprocess
import zipfile


def adb(*args):
    try:
        p = subprocess.run(['adb', *args], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=45)
        return f'command: adb {" ".join(args)}\nexit: {p.returncode}\n'.encode() + p.stdout
    except subprocess.TimeoutExpired:
        return b'Command timed out after 45 seconds\n'


def main():
    if not shutil.which('adb'):
        raise SystemExit('adb not found. Install Android platform-tools and add to PATH.')
    state = subprocess.run(['adb', 'get-state'], capture_output=True, text=True)
    if state.returncode or state.stdout.strip() != 'device':
        raise SystemExit('Connect exactly one phone, enable USB debugging and authorize this computer.')
    name = Path('b2q-fold-logs-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '.zip')
    print('The archive includes system logs; review it before sharing. No logs are cleared.')
    with zipfile.ZipFile(name, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('build.txt', adb('shell', 'getprop'))
        for label, prompt in [('open', 'Fully OPEN the phone'),
                              ('half', 'HALF FOLD the phone'),
                              ('closed', 'CLOSE the phone'),
                              ('reopened', 'OPEN the phone again')]:
            input(prompt + ', wait a few seconds, then press Enter: ')
            for service in ['device_state', 'display', 'sensorservice', 'window', 'power']:
                z.writestr(f'{label}/{service}.txt', adb('shell', 'dumpsys', service))
        z.writestr('controlpanel.txt', adb('shell', 'dumpsys', 'package', 'com.samsung.controlpanel'))
        z.writestr('overlays.txt', adb('shell', 'cmd', 'overlay', 'list'))
        z.writestr('floating_feature.xml', adb('shell', 'cat', '/system/etc/floating_feature.xml'))
        z.writestr('logcat.txt', adb('logcat', '-d', '-v', 'threadtime', '-t', '15000'))
        z.writestr('tester-description.txt', input('Describe what happens on the inner and cover screens: ') + '\n')
    print('Saved:', name.resolve())


if __name__ == '__main__':
    main()
