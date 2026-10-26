$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..'))
if (!(Test-Path 'desktop/server.py') -or !(Test-Path 'renderer/index.html')) { throw 'Missing AniSpawn 0.5.15 desktop source.' }
python -m pip install --disable-pip-version-check pyinstaller
New-Item -ItemType Directory -Force 'build/windows' | Out-Null
$src = Get-Content 'desktop/server.py' -Raw
$src = $src.Replace("return shutil.which('chromium') or shutil.which('chromium-browser')", @"
 if os.name == 'nt':
  for root in (os.getenv('PROGRAMFILES'),os.getenv('PROGRAMFILES(X86)'),os.getenv('LOCALAPPDATA')):
   if root:
    for suffix in ('Microsoft/Edge/Application/msedge.exe','Google/Chrome/Application/chrome.exe'):
     candidate=Path(root)/suffix
     if candidate.is_file():return str(candidate)
 return shutil.which('chromium') or shutil.which('chromium-browser')
"@)
$src = $src.Replace("os.getenv('XDG_CONFIG_HOME') or Path.home()/'.config'", "os.getenv('APPDATA') or os.getenv('XDG_CONFIG_HOME') or Path.home()/'.config'")
$src = $src.Replace("os.getenv('XDG_CACHE_HOME') or Path.home()/'.cache'", "os.getenv('LOCALAPPDATA') or os.getenv('XDG_CACHE_HOME') or Path.home()/'.cache'")
Set-Content 'build/windows/server.py' -Value $src -Encoding utf8
$sep = [IO.Path]::PathSeparator
python -m PyInstaller --noconfirm --clean --onedir --name AniSpawn --paths desktop --add-data "renderer${sep}renderer" --add-data "desktop${sep}desktop" build/windows/server.py
New-Item -ItemType Directory -Force 'dist/AniSpawn-Windows' | Out-Null
Copy-Item 'dist/AniSpawn/*' 'dist/AniSpawn-Windows' -Recurse -Force
Write-Host 'Portable build created. Playback requiring FFmpeg needs ffmpeg.exe on PATH; Edge or Chrome must be installed.'
