# AniSpawn 0.5.15 portable Windows build.
# Reproducible application source is the ZIP uploaded to this repository.
# Executed only on a Windows x64 GitHub Actions runner with internet access.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:PYTHONUTF8 = '1'  # HTML and UI text are UTF-8; Windows runner defaults to cp1252.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repo
$archive = Join-Path $repo 'AniSpawn-0.5.15-Linux-Source.zip'
if (!(Test-Path $archive)) { throw 'Source archive missing from repository root.' }
$sha256 = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sha256 -ne '068fc22f8dd41f9b0cb12cc7810ef589a94a298fb4a488c9e54bae767cc4ba49') {
  throw "Unexpected AniSpawn 0.5.15 source archive SHA256: $sha256"
}
$stage = Join-Path $env:RUNNER_TEMP 'AniSpawn-0.5.15-windows'
New-Item -ItemType Directory -Force $stage | Out-Null
$extract = Join-Path $stage 'source'
Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
$src = Join-Path $extract 'AniSpawn'
if (!(Test-Path (Join-Path $src 'desktop/server.py'))) { throw 'ZIP did not unpack into AniSpawn/desktop/server.py.' }
python (Join-Path $repo 'scripts/windows_prepare.py') $src
if ($LASTEXITCODE -ne 0) { throw 'Windows source adaptation failed.' }
python -m pip install --disable-pip-version-check 'pyinstaller==6.16.0' 'pytest==8.4.2' 'pillow==12.0.0'
if ($LASTEXITCODE -ne 0) { throw 'Python build dependencies unavailable.' }
Push-Location $src
try {
  python -m pytest -q tests/test_desktop.py tests/test_brand.py tests/test_source_hub.py tests/test_network_settings.py
  if ($LASTEXITCODE -ne 0) { throw 'Windows backend regression tests failed.' }
} finally { Pop-Location }

$downloads = Join-Path $stage 'downloads'
New-Item -ItemType Directory -Force $downloads | Out-Null

# Browser: official Chrome for Testing Windows x64. Keep its full DLL/resource tree.
$manifest = Invoke-RestMethod -Uri 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json' -TimeoutSec 90
$browserUrl = @($manifest.channels.Stable.downloads.chrome | Where-Object { $_.platform -eq 'win64' })[0].url
if (!$browserUrl -or !$browserUrl.StartsWith('https://storage.googleapis.com/chrome-for-testing-public/')) {
  throw 'Unexpected Chrome for Testing download endpoint.'
}
$chromeZip = Join-Path $downloads 'chrome-win64.zip'
Invoke-WebRequest -Uri $browserUrl -OutFile $chromeZip -TimeoutSec 900
$chromeUnpack = Join-Path $downloads 'chrome'
Expand-Archive -LiteralPath $chromeZip -DestinationPath $chromeUnpack -Force
$chromeDir = Join-Path $chromeUnpack 'chrome-win64'
if (!(Test-Path (Join-Path $chromeDir 'chrome.exe'))) { throw 'Downloaded browser has no chrome.exe.' }

# LGPL static FFmpeg build: independent ffmpeg.exe and ffprobe.exe, no PATH dependency.
$ffmpegUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip'
$ffmpegZip = Join-Path $downloads 'ffmpeg-win64-lgpl.zip'
Invoke-WebRequest -Uri $ffmpegUrl -OutFile $ffmpegZip -TimeoutSec 900
$ffmpegUnpack = Join-Path $downloads 'ffmpeg'
Expand-Archive -LiteralPath $ffmpegZip -DestinationPath $ffmpegUnpack -Force
$ffmpegFile = Get-ChildItem -LiteralPath $ffmpegUnpack -Recurse -File -Filter 'ffmpeg.exe' | Select-Object -First 1
if (!$ffmpegFile) { throw 'Downloaded FFmpeg archive has no ffmpeg.exe.' }
$ffprobe = Join-Path $ffmpegFile.DirectoryName 'ffprobe.exe'
if (!(Test-Path $ffprobe)) { throw 'Downloaded FFmpeg archive has no ffprobe.exe.' }

# Bundle editable renderer + Python backend under PyInstaller _internal.
$dist = Join-Path $repo 'dist'
$work = Join-Path $stage 'pyinstaller-build'
$spec = Join-Path $stage 'pyinstaller-spec'
New-Item -ItemType Directory -Force $dist | Out-Null
$sep = [IO.Path]::PathSeparator
python -m PyInstaller --noconfirm --clean --onedir --windowed --name AniSpawn --distpath $dist --workpath $work --specpath $spec --paths (Join-Path $src 'desktop') --icon (Join-Path $src 'renderer/assets/anispawn.ico') --add-data "$src/desktop${sep}desktop" --add-data "$src/renderer${sep}renderer" (Join-Path $repo 'scripts/windows_entry.py')
if ($LASTEXITCODE -ne 0) { throw 'PyInstaller failed.' }
$app = Join-Path $dist 'AniSpawn'
$internal = Join-Path $app '_internal'
if (!(Test-Path (Join-Path $internal 'renderer/index.html'))) { throw 'PyInstaller omitted the UI.' }
if (!(Test-Path (Join-Path $internal 'desktop/server.py'))) { throw 'PyInstaller omitted server.py.' }
$runtime = Join-Path $internal 'runtime'
New-Item -ItemType Directory -Force $runtime | Out-Null
Copy-Item -LiteralPath $chromeDir -Destination (Join-Path $runtime 'chromium') -Recurse -Force
$ffmpegDest = Join-Path $runtime 'ffmpeg'
New-Item -ItemType Directory -Force $ffmpegDest | Out-Null
Copy-Item -LiteralPath $ffmpegFile.FullName -Destination (Join-Path $ffmpegDest 'ffmpeg.exe')
Copy-Item -LiteralPath $ffprobe -Destination (Join-Path $ffmpegDest 'ffprobe.exe')
@"
AniSpawn Windows portable test build, version 0.5.15.

Browser: Chrome for Testing Stable, $($manifest.channels.Stable.version)
Chrome license/terms: https://www.google.com/chrome/terms/
Browser binaries are distributed separately from the AniSpawn GPL-2.0-only source.

FFmpeg: BtbN LGPL static Windows build.
FFmpeg license and source: https://ffmpeg.org/legal.html
Build provenance: $ffmpegUrl

The AniSpawn source in this build is the SHA256-verified repository ZIP.
"@ | Set-Content -Path (Join-Path $app 'THIRD_PARTY_NOTICES.txt') -Encoding utf8

# A real frozen executable smoke test (no GUI automation necessary).
$report = Join-Path $env:RUNNER_TEMP 'anispawn-windows-selftest.json'
$env:ANISPAWN_SELFTEST_REPORT = $report
$exe = Join-Path $app 'AniSpawn.exe'
$proc = Start-Process -FilePath $exe -ArgumentList '--packaged-selftest' -PassThru
if (!$proc.WaitForExit(120000)) {
  $proc.Kill()
  throw 'Frozen AniSpawn.exe self-test timed out.'
}
if (Test-Path $report) {
  Get-Content $report
}
if ($proc.ExitCode -ne 0 -or !(Test-Path $report)) {
  throw "Frozen AniSpawn self-test failed (exit code: $($proc.ExitCode))."
}
$result = Get-Content $report -Raw | ConvertFrom-Json
if (!$result.ok -or !$result.checks.loopback_rpc -or !$result.checks.chromium -or !$result.checks.ffmpeg) {
  throw 'Windows package did not pass renderer, RPC, Chromium and FFmpeg checks.'
}

# Windows mutex semantics: another desktop instance must not share Chrome's
# persistent browser profile and accidentally kill its loopback backend.
$mutexTest = @'
import sys
sys.path.insert(0, sys.argv[1])
import windows_entry as w
lock = w._desktop_mutex()
assert isinstance(lock, tuple), "First launch did not acquire a mutex"
try:
    assert w._desktop_mutex() is False, "Second launch was not rejected"
finally:
    assert lock[0].CloseHandle(lock[1]), "Win32 mutex could not be released"
print("Windows desktop mutex check passed")
'@
$mutexTest | python - (Join-Path $repo 'scripts')
if ($LASTEXITCODE -ne 0) { throw 'Windows desktop mutex check failed.' }

# Public Proton diagnostic flag must generate a report in APPDATA by default.
Remove-Item Env:ANISPAWN_SELFTEST_REPORT -ErrorAction SilentlyContinue
$protonReport = Join-Path $env:APPDATA 'AniSpawn/proton-diagnostics.json'
if (Test-Path $protonReport) { Remove-Item $protonReport -Force }
$diag = Start-Process -FilePath $exe -ArgumentList '--proton-diagnostics' -PassThru
if (!$diag.WaitForExit(120000)) {
  $diag.Kill()
  throw 'Proton diagnostic flag timed out on native Windows.'
}
if ($diag.ExitCode -ne 0 -or !(Test-Path $protonReport)) {
  throw "Proton diagnostic command did not produce report (exit code: $($diag.ExitCode))."
}
$protonCheck = Get-Content $protonReport -Raw | ConvertFrom-Json
if (!$protonCheck.ok -or !$protonCheck.checks.loopback_rpc) {
  throw 'Proton diagnostic report is not valid.'
}
Write-Host 'Proton diagnostic entrypoint passed on Windows (not a Proton runtime test).'

$zipPath = Join-Path $dist 'AniSpawn-0.5.15-Windows-x64-portable.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -LiteralPath $app -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Validated Windows portable ZIP: $zipPath"
