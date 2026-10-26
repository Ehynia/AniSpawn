"""PyInstaller entrypoint for AniSpawn 0.5.15 Windows portable (no installed Python)."""
from pathlib import Path
import contextlib
import datetime
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


def _data_dir():
    # Proton provides Windows %APPDATA% inside the Steam compatdata prefix.
    base = os.environ.get('APPDATA') or os.environ.get('LOCALAPPDATA') or tempfile.gettempdir()
    directory = Path(base) / 'AniSpawn'
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def _report_path():
    override = os.environ.get('ANISPAWN_SELFTEST_REPORT')
    if override:
        return Path(override)
    if '--proton-diagnostics' in sys.argv:
        return _data_dir() / 'proton-diagnostics.json'
    return Path(tempfile.gettempdir()) / 'anispawn-windows-selftest.json'


def _write_report(value):
    target = _report_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding='utf-8')


def _desktop_mutex():
    # A second Chrome --app invocation with the same profile forwards its URL to
    # an existing browser and exits immediately. This would kill the second
    # process's local server and leave that newly opened window unusable.
    if os.name != 'nt':
        return None
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
    kernel.CreateMutexW.restype = wintypes.HANDLE
    handle = kernel.CreateMutexW(None, False, 'Local\\AniSpawn_0_5_15_Desktop')
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    already_running = ctypes.get_last_error() == 183  # ERROR_ALREADY_EXISTS
    if already_running:
        kernel.CloseHandle(handle)
        return False
    return kernel, handle


def _run_desktop():
    logpath = _data_dir() / 'launch.log'
    if logpath.exists() and logpath.stat().st_size > 1_048_576:
        logpath.replace(logpath.with_suffix('.previous.log'))
    with logpath.open('a', encoding='utf-8') as log:
        log.write('\n[' + datetime.datetime.now().isoformat(timespec='seconds') +
                  '] AniSpawn 0.5.15 starting; Proton env=' +
                  str(bool(os.environ.get('STEAM_COMPAT_DATA_PATH'))) + '\n')
        log.flush()
        lock = None
        try:
            lock = _desktop_mutex()
            if lock is False:
                log.write('Another AniSpawn instance already owns the browser profile.\n')
                log.flush()
                return
            with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                runpy.run_path(str(ROOT / 'desktop' / 'server.py'), run_name='__main__')
        except SystemExit as exc:
            if exc.code not in (0, None):
                log.write('AniSpawn exited with error code ' + repr(exc.code) + '\n')
                log.flush()
            raise
        except BaseException:
            traceback.print_exc(file=log)
            log.flush()
            raise
        finally:
            if isinstance(lock, tuple):
                lock[0].CloseHandle(lock[1])


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
    _write_report({'ok': True, 'checks': checks,
                   'proton_environment': bool(os.environ.get('STEAM_COMPAT_DATA_PATH')),
                   'limitations': ['headless browser only', 'no actual video playback test',
                                   'no browser GPU compositor test']})


if __name__ == '__main__':
    if '--packaged-selftest' in sys.argv or '--proton-diagnostics' in sys.argv:
        try:
            packaged_selftest()
        except BaseException as exc:
            _write_report({'ok': False, 'error': str(exc), 'traceback': traceback.format_exc(),
                           'proton_environment': bool(os.environ.get('STEAM_COMPAT_DATA_PATH'))})
            sys.exit(1)
    else:
        _run_desktop()
