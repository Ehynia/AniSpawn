$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..'))
if (!(Test-Path 'desktop/server.py') -or !(Test-Path 'renderer/index.html')) { throw 'Extract the 0.5.15 source archive into repository root first.' }
python -m pip install --disable-pip-version-check pyinstaller
New-Item -ItemType Directory -Force 'build/windows' | Out-Null
$src = Get-Content 'desktop/server.py' -Raw
Set-Content 'build/windows/server.py' -Value $src -Encoding utf8
$sep = [IO.Path]::PathSeparator
python -m PyInstaller --noconfirm --clean --onedir --name AniSpawn --paths desktop --add-data "renderer${sep}renderer" --add-data "desktop${sep}desktop" build/windows/server.py
New-Item -ItemType Directory -Force 'dist/AniSpawn-Windows' | Out-Null
Copy-Item 'dist/AniSpawn/*' 'dist/AniSpawn-Windows' -Recurse -Force

# FFmpeg is provided by a trusted Windows package manager, not an unverified mirror.
# Pinning the package version and verifying the executable is essential for reproducibility.
winget install --id Gyan.FFmpeg --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
$ffmpeg = Get-ChildItem "$env:LOCALAPPDATA/Microsoft/WinGet/Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (!$ffmpeg) { $ffmpeg = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source }
if (!$ffmpeg -or !(Test-Path $ffmpeg)) { throw 'FFmpeg installation failed; refusing to publish incomplete portable package.' }
$bin = Join-Path (Split-Path $ffmpeg -Parent) 'ffprobe.exe'
Copy-Item $ffmpeg 'dist/AniSpawn-Windows/ffmpeg.exe'
if (Test-Path $bin) { Copy-Item $bin 'dist/AniSpawn-Windows/ffprobe.exe' }
& 'dist/AniSpawn-Windows/ffmpeg.exe' -version
if ($LASTEXITCODE -ne 0) { throw 'Bundled FFmpeg failed self-test.' }
@'
AniSpawn Windows portable
FFmpeg is bundled in this folder. FFmpeg license: https://ffmpeg.org/legal.html
For full portability, the app must explicitly resolve ffmpeg.exe relative to its executable.
'@ | Set-Content 'dist/AniSpawn-Windows/THIRD_PARTY_NOTICES.txt'
Write-Host 'Portable distribution includes ffmpeg.exe; verify Windows app integration before release.'
