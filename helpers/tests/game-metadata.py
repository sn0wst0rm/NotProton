"""Validate identity, signing and hardlink isolation on a synthetic Wine loader."""
import hashlib, os, pathlib, plistlib, subprocess, sys, tempfile

tool = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='np-game-metadata-') as folder:
    root = pathlib.Path(folder)
    old = {'CFBundleIdentifier': 'com.codeweavers.CrossOver.wineloader',
           'CFBundleName': 'Wine', 'CFBundleVersion': '1'}
    embedded = root / 'embedded.plist'
    embedded.write_bytes(plistlib.dumps(old).ljust(4096, b' '))
    c = root / 'fixture.c'; c.write_text('int main(void) { return 0; }\n')
    runner = root / 'runner'
    subprocess.run(['clang', str(c), '-Wl,-sectcreate,__TEXT,__info_plist,' + str(embedded),
                    '-o', str(runner)], check=True)
    subprocess.run(['codesign', '-s', '-', str(runner)], check=True)
    wine = root / 'wine'; os.link(runner, wine)
    before = runner.read_bytes()
    info = root / 'Info.plist'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.notproton.launcher.999',
                                     'CFBundleName': 'Example Game'}))
    subprocess.run([str(tool), str(wine), str(info)], check=True)
    assert runner.read_bytes() == before, 'shared runner inode was modified'
    assert runner.stat().st_ino != wine.stat().st_ino
    subprocess.run(['codesign', '--verify', '--strict', str(wine)], check=True)
    blob = wine.read_bytes()
    assert b'com.notproton.launcher.999' in blob and b'LSSupportsGameMode' in blob
    subprocess.run([str(tool), str(wine), str(info)], check=True)
    assert wine.read_bytes() == blob, 'second preparation is not idempotent'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unrelated.app', 'CFBundleName': 'Bad'}))
    assert subprocess.run([str(tool), str(wine), str(info)], capture_output=True).returncode != 0
    assert wine.read_bytes() == blob
    wine.write_bytes(b'not a Mach-O')
    assert subprocess.run([str(tool), str(wine), str(info)], capture_output=True).returncode != 0
    print('PASS metadata: scoped identity, valid signature, unchanged runner, idempotency, invalid input rejection')
