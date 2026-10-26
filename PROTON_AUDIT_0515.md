# AniSpawn 0.5.15 — Proton / Wine risk audit

**Scope:** Python backend in `AniSpawn-0.5.15-Linux-Source.zip` (`AniSpawn/desktop/`), editable UI (`AniSpawn/renderer/`), Windows PyInstaller entrypoint and Windows build workflow in `scripts/`. Excludes testing against an installed Proton runtime: no Wine/Proton executable was available in the review environment. A green Windows Actions run tests Windows, **not** Proton.

Risk classes: **CODE** = supported directly by source; **COMPAT** = Wine/Proton environment can differ; **PROVIDER** = external stream/API behavior. A risk is not proof of a reproduced crash.

## P0 — app launch/freeze

| Component | Risk and symptom | Basis | Practical mitigation |
|---|---|---|---|
| Bundled Windows Chrome | **COMPAT.** Wine/Proton may fail to start Chrome's Windows sandbox, GPU or subprocesses. Blank app window, Chrome exits, UI never loads. | `desktop/server.py:841-877` calls bundled `chrome.exe --app=127.0.0.1`. Historic Wine bug 21232 covers Chromium sandbox issues; modern Chrome/Proton must be tested separately. | `--proton-diagnostics` to test bundled Chrome headless; compare with native Linux DEB. Do **not** silently append `--no-sandbox`: the app embeds third-party websites. |
| Unbounded browser wait | **CODE.** Backend waits `p.wait()` while browser lives. Hung Chrome leaves Steam showing game running indefinitely; when Chrome exits early, server is destroyed. | `desktop/server.py:850-879`. | Inspect `launch.log` and `chromium-stderr.log`; exit Steam or stop process. Long term: browser health/IPC watchdog, not a guessed fixed timeout. |
| Duplicate launch/shared Chrome profile | **CODE.** Two instances use the same `browser-profile`; Chrome may forward second launch and exit, destroying the second backend's loopback URL. | `desktop/server.py:864-877`. | **Mitigated in Windows entrypoint:** Win32 named mutex prevents second running desktop instance. |
| Invisible launch exceptions | **CODE.** PyInstaller `--windowed` has no console; initialization and subprocess failures are hard to report. | `scripts/build-windows.ps1`, `desktop/server.py:166-197,850-879`. | **Mitigated:** `%APPDATA%\\AniSpawn\\launch.log` receives launcher exceptions and `chromium-stderr.log` captures child Chrome stderr. |

## P1 — playback and GPU

| Component | Risk and symptom | Basis | Practical mitigation |
|---|---|---|---|
| Windows H.264/AAC decoding under Wine | **COMPAT.** FFmpeg forwards a stream, but Windows Chrome in Wine may not decode all video/audio formats due to media/GPU backend differences. Black video/audio or player error, not necessarily process crash. | `desktop/server.py:783-840` copies streams into fragmented MP4 (`-c copy`), `renderer/index.html:101` uses HTML5 `<video>`. | Test with a known H.264/AAC MP4 and each provider separately. Do not infer decoding success from FFmpeg `-version`. |
| GPU compositor / WebGL2 | **COMPAT+CODE.** WebGL2 context creation, shader link, and `texImage2D(video)` can fail or lose context under Proton's GPU stack. Heavy 2× scaling can exhaust VRAM on handhelds. | `renderer/upscale.js:77-135`. | Keep upscale disabled until ordinary video works. UI code catches common WebGL failures, but GPU subprocess crashes can still freeze the browser. |
| FFmpeg process stalls/incorrect codec | **CODE+PROVIDER.** Streaming `Popen` reads pipes synchronously; no short per-request watchdog. Incompatible codecs or stalled remote HLS may lead to spinner, abrupt stream end, or suspended request. | `desktop/server.py:323-343,781-840`; `-rw_timeout 12000000`, cache timeout 14400 seconds. | Test short stream and seek; capture provider-specific failures. Stream-transcoding fallback and cancellation need separate design. |
| HTTP proxy versus SOCKS5 for FFmpeg | **CODE.** Proxy mode works for browser/Python; FFmpeg supports only app's HTTP proxy flags. SOCKS5 can make API load while streams fail. | `desktop/network_settings.py:280-295`. | Use HTTP CONNECT proxy for HLS or direct access; UI should explicitly explain this difference. |
| Third-party embedded iframes | **COMPAT+PROVIDER.** A site can reject cross-site embedding, block the user agent or require proprietary codecs/Cookies; sandbox capabilities differ from a normal browser. | `renderer/index.html:102`, `desktop/video_providers.py`, `desktop/site_bridges.py`. | Diagnose the provider separately, preserve iframe sandbox; unsupported providers should remain marked unavailable. RUTUBE and VK remain excluded. |

## P1 — storage, networking and launcher environment

| Component | Risk and symptom | Basis | Practical mitigation |
|---|---|---|---|
| Steam Proton prefix lifecycle | **COMPAT.** `%APPDATA%` and `%LOCALAPPDATA%` resolve **inside** the selected Steam compatibility prefix. Switching Proton/prefix or deleting `compatdata` makes prior history appear lost. Read-only/corrupt prefix can stop `Backend()` at startup. | `desktop/server.py:166-200`; Windows patch in `scripts/windows_prepare.py`. | Keep same Steam shortcut and prefix, back up `%APPDATA%\\AniSpawn`, inspect `launch.log` on failure. |
| Windows file operations / antivirus / NTFS | **COMPAT+CODE.** Atomic `.tmp.replace()`, `chmod`, cache writes and large MP4s may throw on readonly, locked or unmapped volumes; exceptions in startup can terminate process. | `desktop/server.py:168-269,297-345`, `desktop/accounts.py:273-280`, `desktop/network_settings.py:187`. | Check prefix disk space and permissions. Log errors; avoid running executable from an archive. |
| TLS, certificate store and DoH | **COMPAT+PROVIDER.** Python OpenSSL and Chrome use different networking/cert paths under Wine; a working source-status probe does not prove Chrome iframe/HLS reachability. | `desktop/network_settings.py:81-110,216-295`. | Compare system DNS vs DoH, with and without proxy; inspect individual source states and Anixart diagnostics. Do not turn off TLS verification. |
| Loopback RPC port and Origin check | **CODE+COMPAT.** Python binds ephemeral `127.0.0.1` port, sends it to Chrome, and requires matching `Origin`. Unexpected browser proxy behavior, firewalls or process isolation can cause a blank UI/RPC failures. | `desktop/server.py:731-771,850-877`. | `--proton-diagnostics` checks HTTP UI and RPC; run inside the same Proton prefix and check logs. |
| Dynamic Chrome Stable at build time | **CODE.** CI fetches last-known-good Chrome each build, so identical app sources can produce different browser versions, introducing Proton regressions. | `scripts/build-windows.ps1`. | Pin a tested Chrome version and archive SHA256 for reproducible releases. Not yet fixed in this release. |
| Dynamic BtbN FFmpeg nightly at build time | **CODE.** URL `ffmpeg-master-latest-win64-lgpl.zip` also changes; providers/codec behavior can regress without source changes. | `scripts/build-windows.ps1`. | Pin a version and SHA256 once verified on real Proton. Not yet fixed. |
| Browser profile corruption and concurrent access | **CODE+COMPAT.** Startup relies on persisted `browser-profile` in the prefix, which may get corrupted by interrupted Wine process termination. | `desktop/server.py:865-876`. | If only browser fails, back up/rename `browser-profile` and relaunch. Win32 mutex now prevents accidental parallel profile use. |
| Shell/browser open outside app | **COMPAT.** `webbrowser.open` may target Wine's Windows association, rather than a Linux desktop browser, or return false. | `desktop/server.py:626,703`. | Open the external link manually in the Linux browser; do not treat failure as broken API. |
| Steam overlay/input/focus/fullscreen | **COMPAT.** Chrome `--app` is a browser window, not a native DirectX game. Steam overlay, controllers, on-screen keyboard and window focus may differ from games. | `desktop/server.py:867`, HTML controls. | Prefer keyboard/mouse for testing; compare desktop mode versus Big Picture/Steam Deck Game Mode. |
| Incomplete/unextracted ZIP | **CODE.** The executable depends on adjacent `_internal/renderer`, `desktop`, Chrome DLL/resources and FFmpeg. Moving only `AniSpawn.exe` fails. | `scripts/build-windows.ps1`, `scripts/windows_entry.py`. | Extract all nested ZIPs and keep the complete `AniSpawn` directory. |

## Diagnostics in Proton

1. Add `AniSpawn.exe` as a non-Steam game; enable a recent Proton/Proton Experimental in **Properties → Compatibility**.
2. For a non-interactive compatibility check, set Steam launch options to `PROTON_LOG=1 %command% --proton-diagnostics`. This **does not open the normal UI**. It tests the bundled browser headless, FFmpeg executable, loopback server and source-list RPC.
3. Read `proton-diagnostics.json` in `compatdata/<shortcut-appid>/pfx/drive_c/users/<user>/AppData/Roaming/AniSpawn/`. The exact Steam library/prefix location varies. Find it with `find ~/.local/share/Steam ~/.steam -name proton-diagnostics.json 2>/dev/null`.
4. For normal start, use `PROTON_LOG=1 %command%`. If it fails, inspect adjacent `launch.log` and `chromium-stderr.log` under the same `AniSpawn` folder; Proton writes `~/steam-<appid>.log` (see Valve Proton FAQ).
5. Check stream playback **and** WebGL/upscaling manually: these are intentionally not validated by the headless check. For reproducibility, record Proton version, Wine/Proton prefix, GPU/driver, distribution, browser console errors, provider/source, and symptom.

**Do not disable browser sandbox or TLS verification as a default.** The app displays untrusted embedded player pages.

## Verification limits

The latest Windows workflow built, ran Chrome and FFmpeg, and exercised renderer and RPC successfully **on GitHub's Windows runner**. This audit identifies source-visible failure points and Wine/Proton compatibility risks. A real Proton game-mode session on a Linux GPU remains necessary before calling the Windows build Proton-compatible.

References: [Valve Proton FAQ](https://github.com/ValveSoftware/Proton/wiki/Proton-FAQ), [Wine bug 21232](https://bugs.winehq.org/show_bug.cgi?id=21232).
