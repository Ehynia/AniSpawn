"""PyInstaller entrypoint for AniSpawn 0.5.15 Windows portable (no installed Python)."""
from pathlib import Path
import json
import os
import runpy
import subprocess
import sys
import tempfile
import threading
import traceback
import urllib.request

ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'desktop'))


def packaged_selftest():
    import server
    checks = {}
    assert server.VERSION == '0.5.15'
    assert server.RENDERER.joinpath('index.html').is_file()
    checks['renderer'] = True
    browser = server.chromium_path()
    ffmpeg = server.RUNTIME / 'ffmpeg' / ('ffmpeg.exe' if os.name == 'nt' else 'ffmpeg')
    assert browser and Path(browser).is_file(), 'Bundled Chrome is absent'
    assert ffmpeg.is_file(), 'Bundled FFmpeg is absent'
    # Chrome for Testing is a GUI-subsystem executable on Windows. Calling
    # chrome.exe --version can launch a long-running GUI process instead of
    # returning a version string. Verify a real local headless page instead.
    with tempfile.TemporaryDirectory(prefix='anispawn-browser-test-') as profile:
        chrome_cmd = [browser, '--headless=new', '--disable-gpu',
                      '--disable-background-networking', '--no-first-run',
                      '--no-default-browser-check', '--user-data-dir=' + profile,
                      '--dump-dom', 'data:text/html,<title>AniSpawnSmoke</title>']
        browser_result = subprocess.run(chrome_cmd, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, timeout=50)
        assert browser_result.returncode == 0, 'Chrome headless test failed'
        assert b'AniSpawnSmoke' in browser_result.stdout, 'Chrome did not render test page'
    checks['chromium'] = True
    result = subprocess.run([str(ffmpeg), '-version'], capture_output=True,
                            text=True, timeout=30)
    assert result.returncode == 0, 'FFmpeg self-test failed: ' + (result.stderr or '')[:350]
    checks['ffmpeg'] = True
    with tempfile.TemporaryDirectory(prefix='anispawn-win-smoke-') as tmp:
        backend = server.Backend(user_dir=tmp)
        assert str(backend.ffmpeg) == str(ffmpeg)
        assert backend.state['source'] == 'all'
        httpd = server.Server(('127.0.0.1', 0), backend)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            base = f'http://127.0.0.1:{httpd.server_port}{httpd.prefix}'
            with urllib.request.urlopen(base, timeout=6) as resp:
                assert resp.status == 200 and b'AniSpawn' in resp.read()
            data = json.dumps({'method':'sources', 'args':[]}).encode()
            req = urllib.request.Request(base + 'rpc', data=data,
                headers={'Origin':f'http://127.0.0.1:{httpd.server_port}',
                         'Content-Type':'application/json'})
            with urllib.request.urlopen(req, timeout=6) as resp:
                items=json.load(resp)['result']
            assert any(x['id']=='all' for x in items)
            checks['loopback_rpc'] = True
        finally:
            httpd.shutdown()
            httpd.server_close()
    target = Path(os.environ.get('ANISPAWN_SELFTEST_REPORT', str(Path(tempfile.gettempdir())/'anispawn-windows-selftest.json')))
    target.write_text(json.dumps({'ok':True, 'checks': checks}, indent=2), encoding='utf-8')


if __name__ == '__main__':
    if '--packaged-selftest' in sys.argv:
        try:
            packaged_selftest()
        except BaseException as exc:
            target = Path(os.environ.get('ANISPAWN_SELFTEST_REPORT', str(Path(tempfile.gettempdir())/'anispawn-windows-selftest.json')))
            target.write_text(json.dumps({'ok': False, 'error': str(exc), 'traceback': traceback.format_exc()}, indent=2), encoding='utf-8')
            sys.exit(1)
    else:
        runpy.run_path(str(ROOT / 'desktop' / 'server.py'), run_name='__main__')
