#!/usr/bin/env python3
"""Adapt the published AniSpawn 0.5.15 Linux source for a bundled Windows runtime.

Refuse to patch unknown source revisions. No TLS bypass or network behavior changes.
"""
from pathlib import Path
import sys


def patch(root: Path):
    source = root / 'desktop' / 'server.py'
    ui = root / 'renderer' / 'index.html'
    if not source.is_file() or not ui.is_file():
        raise RuntimeError('Expected desktop/server.py and renderer/index.html in extracted source')
    code = source.read_text(encoding='utf-8')
    if "VERSION = '0.5.15'" not in code:
        raise RuntimeError('Archive is not AniSpawn 0.5.15; patch aborted')

    changes = [
        ("Path(user_dir or os.getenv('XDG_CONFIG_HOME') or Path.home()/'.config')",
         "Path(user_dir or (os.getenv('APPDATA') if os.name=='nt' else os.getenv('XDG_CONFIG_HOME')) or Path.home()/'.config')"),
        ("Path(os.getenv('XDG_CACHE_HOME') or Path.home()/'.cache')",
         "Path(os.getenv('XDG_CACHE_HOME') or (os.getenv('LOCALAPPDATA') if os.name=='nt' else None) or Path.home()/'.cache')"),
        ("RUNTIME/'ffmpeg'/'ffmpeg'",
         "RUNTIME/'ffmpeg'/('ffmpeg.exe' if os.name=='nt' else 'ffmpeg')"),
        ("""def chromium_path():
 bundled=RUNTIME/'chromium'/'chromium'
 if bundled.is_file():return str(bundled)
 return shutil.which('chromium') or shutil.which('chromium-browser')""",
         """def chromium_path():
 if os.name=='nt':
  bundled=RUNTIME/'chromium'/'chrome.exe'
  if bundled.is_file():return str(bundled)
  return None  # Windows portable requires bundled Chrome, not a system install.
 bundled=RUNTIME/'chromium'/'chromium'
 if bundled.is_file():return str(bundled)
 return shutil.which('chromium') or shutil.which('chromium-browser')"""),
    ]
    for before, after in changes:
        count = code.count(before)
        if count not in (1, 2, 4):
            raise RuntimeError(f'Windows patch mismatch ({count} occurrences): {before[:65]!r}')
        code = code.replace(before, after)
    source.write_text(code, encoding='utf-8')
    compile(code, str(source), 'exec')
    print('Windows 0.5.15 prepared: local FFmpeg/Chrome and AppData directories')


if __name__ == '__main__':
    patch(Path(sys.argv[1]).resolve())
