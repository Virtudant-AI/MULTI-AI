# Multi-AI

## The Goals & The Problems

MULTI-AI exists to make on-device inference a viable default, not just a
fallback — every model that runs locally is a query the shared cloud
infrastructure never has to serve. That's the one lever this project can
actually pull; here's the full picture of where AI's environmental cost
actually sits.

### Problem 1: Training — not addressed here

Training a frontier model is a genuinely massive one-time cost — GPT-4-scale
runs are estimated at nine figures and enough energy to power a city for
days, largely because of the GPU-parallel compute it demands
([MIT Technology Review, 2025](https://www.technologyreview.com/2025/05/20/1116327/ai-energy-usage-climate-footprint-big-tech/)).
This project doesn't touch that side yet — it's out of scope until it
expands beyond running existing models.

### Problem 2: Inference — the actual target

Training happens once; inference happens every time someone asks a question,
and it now accounts for roughly 80–90% of AI's total compute demand and
climbing, precisely because millions of users query the same few
data-center models
([MIT Technology Review, 2025](https://www.technologyreview.com/2025/05/20/1116327/ai-energy-usage-climate-footprint-big-tech/)).
Running the model on the device asking the question removes that query from
the shared-infrastructure tally entirely — the cost shifts to local battery
drain, a tradeoff the user controls directly instead of one absorbed by a
data center's grid draw.

### Problem 3: Hardware — reuse over extraction

Data-center-scale AI runs on lithium, cobalt, copper, and rare earths, and
the mining behind them carries a real human and environmental cost that
increasingly lands on communities with the least ability to push back
([Fortune, 2026](https://fortune.com/2026/04/29/where-do-critical-minerals-come-from-ai-boom-data-centers-africa-middle-east/);
[Roha, 2026](https://medium.com/@Jamesroha/the-new-strip-mines-how-ai-infrastructure-is-repeating-appalachias-extraction-history-e4ac29c1b88b)).
A phone or laptop that already exists needs none of that new extraction —
on-device inference reuses hardware the user already owns instead of adding to server-rack demand.

## Run using

```powershell
.\scripts\run-windows.ps1
```

equivalent to:

```powershell
# The app depends on velopack_flutter, whose native-assets build hook compiles a
# Rust crate — so the build needs rustup/cargo on PATH (see "Rust toolchain" below).
# run-windows.ps1 prepends this automatically; the bare commands need it explicitly.
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
cd app
flutter run -d windows
```

> **One-time: install the Rust toolchain.** The app depends on `velopack_flutter`
> (the in-app updater), a flutter_rust_bridge package whose native-assets build hook
> compiles a Rust crate as part of `flutter run/build windows`. Without rustup/cargo
> the build fails with `Building native assets failed` — the hook can't run
> `rustup show active-toolchain`. Install it once:
>
> ```powershell
> winget install --id Rustlang.Rustup -e --source winget
> ```
>
> rustup installs into `%USERPROFILE%\.cargo\bin` and adds it to your User PATH, but a
> terminal opened **before** the install keeps a stale PATH and still can't see it —
> `run-windows.ps1` prepends that directory so it works either way. To get it onto PATH
> for every new terminal, fully restart your shell (quit and reopen VS Code if you use
> its integrated terminal) or reboot once. `--source winget` skips the `msstore` source,
> which fails behind this machine's Norton TLS interception (`0x8a15005e`).

OR

(If using norton must first go to security -> network -> and disable smart firewall)

Or run the emulator + app in one go (boots Pixel_9, waits for it to come online, then `flutter run`s onto it):

```powershell
.\scripts\run-app.ps1
```

That's equivalent to, in order:

```powershell
# 1. start the emulator (takes ~60s to boot)
flutter emulators --launch Pixel_9

# 2. once it shows as a device, run
cd app
flutter run -d emulator-5554
```

## Restart backend

```powershell
.\scripts\restart-backend.ps1
```

That finds and kills whatever holds port 8000, then restarts the compiled backend's entry point. It only restarts the process — it does **not** build. If you changed a `.pyx` since the last build, regenerate its C and recompile first:

```powershell
python scripts/regen_cython.py      # needs Cython==3.3.0
pip install -e . --no-deps
```

`.\scripts\restart-backend.ps1` is equivalent to, in order:

1. Find the process ID using port 8000:
Get-NetTCPConnection -LocalPort 8000 | Select-Object OwningProcess
That prints a number (the PID).

2. Stop it (replace <PID> with that number):
Stop-Process -Id <PID> -Force

3. Restart it (the backend is compiled — run the entry point, not the .pyx):
cd "c:/Users/cajga/Documents/GitHub/MULTI-AI/Multi-AI"
python -c "from multi_ai.server import run; run()"

multi-ai-server
(equivalently: `python -c "from multi_ai.server import run; run()"`)

A hybrid Python/Dart edge computing platform for managing and running multiple AI models locally, with a Flutter mobile/desktop frontend.

## Shipping a Windows release

Push a tag and [`.github/workflows/release.yml`](.github/workflows/release.yml) builds the installer and opens a **draft** release with it attached:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

Review the draft on GitHub, then publish. A manual run from the Actions tab builds the same installer as a workflow artifact without creating a release — use that to test pipeline changes.

### Why an installer rather than a bare .exe

`flutter build windows` does **not** produce a standalone executable. It produces `multi_ai.exe` plus `flutter_windows.dll`, the plugin DLLs (`file_picker`, `record`, and llamadart's `ggml-vulkan.dll`/`mtmd.dll`) and a `data/` directory. Ship the `.exe` alone and it won't launch. [`installer/multi-ai.iss`](installer/multi-ai.iss) wraps the whole tree into one `MultiAI-Setup-<version>.exe` — that single file is the release asset.

### Why the dependencies aren't in it

The chat-time stack is ~4.5 GB installed (torch alone is 4.12 GB — the `cu128` wheel carries the CUDA runtime inside `torch/lib`), and **a GitHub release asset is capped at 2 GB**. No compression closes that gap. So the split is:

| Ships in the installer (~200 MB) | Installed on first launch (~2.5 GB) |
|---|---|
| Flutter app + DLLs + `data/` | torch, transformers, accelerate, bitsandbytes |
| Embeddable CPython 3.14 (~11 MB) | pillow, torchvision, librosa, soundfile, timm |
| The Cython-compiled `multi_ai` package | pip-system-certs |
| `bootstrap.py`, `pip.pyz`, `requirements.txt` | (from PyPI + PyTorch's index, not hosted here) |

First launch shows a setup screen with pip's live output — a 10-minute install behind a bare spinner is indistinguishable from a hang. It's skippable: the on-device GGUF models need none of it, so a failed or declined install costs the server models rather than the app.

### Runtime layout

```
C:\Program Files\Multi-AI\          (read-only, admin to install)
  multi_ai.exe, *.dll, data\        the Flutter app
  backend\python\                   embeddable CPython 3.14
  backend\multi_ai\*.pyd            the compiled backend
  backend\bootstrap.py, pip.pyz, requirements.txt

%LOCALAPPDATA%\MultiAI\
  site-packages\                    torch et al. land here
  .provisioned                      the requirements.txt they satisfy
```

Dependencies install under `%LOCALAPPDATA%` deliberately: Program Files isn't user-writable, and a first launch that's already a long download shouldn't also need an admin prompt. The `.provisioned` marker holds the `requirements.txt` those packages were installed from, so an update that edits the list re-provisions instead of running against stale packages.

### Three traps worth knowing before editing any of this

- **The embeddable interpreter ignores `PYTHONPATH`.** Its `python._pth` replaces path setup wholesale, so the obvious fix — point `PYTHONPATH` at the dependency directory — silently does nothing and `import torch` fails with paths that look correct. [`installer/runtime/bootstrap.py`](installer/runtime/bootstrap.py) takes a `MULTI_AI_PATH` env var instead and builds `sys.path` after startup, where nothing is overriding it. The workflow does still un-comment `import site` in the `._pth`, because `pip.pyz` needs the `site` module.
- **pip is a zipapp, not an install.** The interpreter lives in Program Files and isn't writable at runtime, so there's nowhere for a real `pip install` to go. `pip.pyz` runs without being installed and writes to `--target`.
- **The `.pyd` ABI tag must match the bundled interpreter.** `server.cp314-win_amd64.pyd` loads only under CPython 3.14 on win-amd64. `PYTHON_VERSION` and `PYTHON_EMBED_VERSION` in the workflow have to stay on the same minor version; patch releases are ABI-compatible.

The installer is **unsigned**, so Windows SmartScreen warns that the publisher is unknown and users must click *More info* → *Run anyway*. Fixing that means an Authenticode certificate (~$100–400/yr from a CA); an EV certificate clears SmartScreen immediately, a standard one only after enough downloads build reputation.

### Backend lifecycle

The app owns the backend process in a packaged build: [`app/lib/backend_process.dart`](app/lib/backend_process.dart) spawns it, polls `/api/hello` until healthy, and kills it on exit. It first checks whether something already answers on port 8000 and adopts it if so — otherwise a developer's hand-started server, or an orphan from a previous crash, would collide with a fresh spawn and produce an "address in use" crash loop.

In development none of this engages: with no `backend/` directory next to the executable, `BackendRuntime.isBundled` is false, [`startup_gate.dart`](app/lib/startup_gate.dart) falls straight through to the chat screen, and you keep starting the server yourself as before.

## Shipping an Android release

Android ships as a signed APK attached to the same GitHub release as the Windows installer — deliberately **not** the Play Store. The Play Console path adds a $25 developer-account fee, a mandatory 14-day/12-tester closed test before any production release, a privacy-policy URL, and a Data Safety questionnaire, none of which this project needs for a sideloaded download. The tradeoff: no store listing, and no automatic updates — see "No in-app updater" below.

Pushing a tag builds and attaches both platforms to one release:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs `build-windows` and `build-android` in parallel, then a `publish` job attaches both platforms' outputs to one draft release. Android needs none of the Windows job's backend-bundling steps — per the on-device-only scoping decision below, the APK is just the Flutter app.

### The release keystore

Android refuses to install an update over an existing app unless the new APK is signed with the *same* key, so unlike Windows (which ships unsigned and eats a SmartScreen warning) Android needs a real, stable signing identity from the first release onward.

The keystore was generated once, locally:

```powershell
keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias multiai -storepass:file <password-file> -keypass:file <password-file> -dname "CN=Multi-AI, OU=CAJ654, O=Multi-AI, L=Unknown, ST=Unknown, C=US"
```

`app/android/upload-keystore.jks` and `app/android/key.properties` (storePassword/keyPassword/keyAlias/storeFile) are both gitignored — never commit them. [`app/android/app/build.gradle.kts`](app/android/app/build.gradle.kts) reads `key.properties` if present and signs with it; if it's absent (a fresh clone with no keystore set up), it falls back to debug signing so `flutter run`/`flutter build apk` still work locally without extra setup.

CI reconstructs the keystore from three repo secrets — **Settings → Secrets and variables → Actions** on GitHub:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `[Convert]::ToBase64String([System.IO.File]::ReadAllBytes("upload-keystore.jks"))` |
| `ANDROID_KEYSTORE_PASSWORD` | The store/key password (PKCS12 keystores require these to match) |
| `ANDROID_KEY_ALIAS` | `multiai` |

The `build-android` job decodes the first secret back into `upload-keystore.jks`, writes `key.properties` from the other two, builds, then verifies with `apksigner verify --print-certs` that the result is *not* signed with the debug key — a missing or wrong secret fails that check loudly instead of silently shipping a debug-signed APK nobody can update over later.

**If the keystore is ever lost**, there is no recovery — a new one means a new signing identity, and every existing install has to be uninstalled before it can take an "update" signed by the new key. Back up `upload-keystore.jks` and its password somewhere durable (a password manager, not just this machine) the same way you'd back up any other credential with no reset flow.

### In-app update checker

`velopack_flutter` (the Windows updater — see "Shipping a Windows release" above) explicitly no-ops its native build on Android (`hook/build.dart` returns early for `OS.android`/`OS.iOS`), so Android can't use it. [`android_update_checker.dart`](app/lib/android_update_checker.dart) covers the gap instead: at startup it checks `/repos/CAJ654/MULTI-AI/releases/latest` on the GitHub API, and if the tag is newer than the running `PackageInfo` version, [`app_shell.dart`](app/lib/app_shell.dart) shows a dismissible banner. It doesn't download or install anything itself — no `FileProvider`, no `REQUEST_INSTALL_PACKAGES`, no native code — "Download" just opens the APK's direct asset URL in the system browser via `url_launcher`, and Android's normal unknown-sources install flow takes it from there, same as a user manually downloading it from the release page. That still lands as an upgrade (not a fresh install) because it's signed with the same key, so chat history and downloaded on-device models are preserved. A dismissed version is remembered (`android_update_dismissed.json` in the app's data directory) so the banner doesn't reappear until a newer release is published.

## Colibri: external-endpoint models on this edge server (5 MoE families)

[Colibri](https://github.com/JustVugg/colibri) runs a handful of large MoE
models on consumer hardware by streaming individual experts from disk instead
of residing the whole model in RAM. It is **not** a general model loader —
it's "one C file per model family," hand-written engines that hardcode each
family's tokenizer, attention mechanism, and MoE routing — so it only runs
the five families it explicitly implements, and can't be pointed at an
arbitrary checkpoint. (This is why it can't help with GPT-OSS or this
project's dense 10–14B models — see [TODO.md](TODO.md) — "A real speedup" section.)

None of the five fit either existing model path (`_REPO_ID` →
transformers/torch, `_GGUF_SOURCE` → on-device llamadart): each needs a
separately-downloaded weight set (167GB–1.6TB, resolved to a real Hugging
Face repo per family — see `_COLIBRI_REPO_ID` below) and runs as its own
long-running process on this edge server (`coli serve --model <path> --port
8010`). Unlike the original design, **MULTI-AI now downloads those weights
and starts/stops that process itself** — the Models tab's usual
download/cache/delete UI works for these five the same as any `_REPO_ID`
model, and sending a chat message spawns `coli serve` automatically if it
isn't already running for that model, blocking the reply until it answers
`/health` or a clear error can be shown. Only one Colibri process runs at a
time (shared port 8010), so switching to a different Colibri model stops
whatever was running first. The one thing still manual: **the `coli` binary
itself** — install it once from
[Colibri's releases](https://github.com/JustVugg/colibri/releases) and put
it on PATH, the same one-time shape as this project's Rust-toolchain step.
Without it on PATH, a chat attempt returns a clear "install `coli`" message
rather than hanging.

| Model | Params (active) | Disk | RAM (min / comfortable) | Context | License | `_COLIBRI_REPO_ID` |
|---|---|---|---|---|---|---|
| GLM-5.2 | 744B (~40–55B) | ~372GB | 16GB / 24GB | 1M | Apache-2.0 engine / MIT weights | `jlnsrk/GLM-5.2-colibri-int4` |
| Inkling | 975B (~41B) | ~469GB | 64GB / 120GB | 1M | Apache 2.0 | `sabrewing-engine/Inkling-colibri-int4` |
| Kimi K3 | 2.8T (~104B) | ~1.6TB | 32GB / 32GB | ~1.05M | Kimi K3 License (custom) | `moonshotai/Kimi-K3` |
| DeepSeek V4 Flash | 284B (~13B) | ~167GB | 16GB / 22GB | 1M | MIT | `deepseek-ai/DeepSeek-V4-Flash-0731` |
| OLMoE | 7B (~1B) | ~4GB | 8GB / 8GB | 4096 | Apache 2.0 (+ Gemma ToU note) | `allenai/OLMoE-1B-7B-0924-Instruct` |

GLM-5.2 and Inkling need a one-time int4 conversion Colibri doesn't do
automatically, so their `_COLIBRI_REPO_ID` points at a pre-converted
community mirror rather than the base checkpoint. Kimi K3, DeepSeek V4
Flash, and OLMoE stream directly from their official repos — no conversion
needed. Downloading needs `huggingface_hub` installed
(`pip install huggingface_hub`) — deliberately **not** the full
torch/transformers chat-time stack, since Colibri needs neither.

(Inkling's 64GB floor is Colibri's own doc'd threshold — below it the process
dies mid-generation; a 25GB int4-dense-container fallback mode exists but is
disk-bound and impractically slow, so it isn't what's rated here.)

- [x] Five model files under `Multi-AI/multi_ai/models/` — one per family
      (`glm_5_2_colibri.pyx`, `inkling_colibri.pyx`, `kimi_k3_colibri.pyx`,
      `deepseek_v4_flash_colibri.pyx`, `olmoe_colibri.pyx`), each declaring
      `_EXTERNAL_ENDPOINT = "colibri"`, `_EXTERNAL_ENDPOINT_PORT = 8010`,
      `_EXTERNAL_MIN_RAM_GB`/`_EXTERNAL_RECOMMENDED_RAM_GB`, `_COLIBRI_REPO_ID`
      (the Hub source above), and a `get_info()` with the figures in the
      table above.
- [x] `server.pyx`: `_resolve_server_model` now recognizes `_COLIBRI_REPO_ID`
      alongside `_REPO_ID` (returning which *kind* it is), so the existing
      `GET/POST/DELETE /api/models/{id}/cache|download` routes work for
      Colibri models too — `_download_colibri_weights()` fetches the repo via
      `huggingface_hub.snapshot_download()` without loading it (unlike
      `_download_hf_weights`, which would try to load a 284B-2.8T checkpoint
      through `transformers`).
- [x] `server.pyx`: `_ensure_colibri_running(model_id, port)` — spawns
      `coli serve --model <path> --port 8010` (subprocess.Popen, output
      drained on a daemon thread so the pipe never blocks the child) and
      polls `GET /health` until it answers or a timeout/early-exit produces a
      clear error with the captured log tail. Called from `_chat_reply`
      before `_colibri_generate()` proxies the actual request. Requires
      weights already downloaded (`local_files_only=True` — chatting never
      triggers a 167GB-1.6TB download itself) and the `coli` binary on PATH;
      each missing piece gets its own specific error message.
- [x] `hardware.pyx`: `rate_external_model(min_ram_gb, recommended_ram_gb,
      disk_gb, specs)` — rates off local RAM against each family's own stated
      minimums (`rate_model`'s `bool(gguf)` discriminator couldn't grow a third
      case in place, so this is a sibling function, not a branch inside it).
      Always notes the disk requirement in the `reason` text regardless of the
      RAM verdict — for one of these models that one-time download is the real
      commitment.
- [x] Shared fixed port `8010` for all five (avoids colliding with MULTI-AI's
      own backend on 8000). All five default to the same port since realistically
      only one Colibri process runs at a time — each family needs its own
      hundreds-of-GB-to-terabyte weight set, so running two simultaneously isn't
      a realistic scenario; `_ensure_colibri_running` stops whichever family was
      running before starting a different one. A per-model
      `_EXTERNAL_ENDPOINT_PORT` override exists if that assumption ever needs
      to change.
- [x] Dart side — `api_client.dart`/`model_pool.dart`/`chat_screen.dart` route
      these through the normal `_api.sendChat()` path unchanged (no `gguf`
      field), as originally expected. What wasn't anticipated: `ModelInfo` had
      no way to tell a `_REPO_ID` model (server-managed weights) apart from an
      `_EXTERNAL_ENDPOINT` one — both lack `gguf`, and now some
      `_EXTERNAL_ENDPOINT` models (the Colibri five) also have server-managed
      weights while others hypothetically might not. Fixed by adding
      `has_server_weights` to `/api/models` (true for `_REPO_ID` or
      `_COLIBRI_REPO_ID`) and threading it through `ModelInfo.hasServerWeights`,
      `model_detail_screen.dart`'s `_isServerModel` gate (now shows the normal
      download/cache/delete section for Colibri models instead of a static
      "run this command yourself" block), and `model_pool.dart`'s
      `isDownloaded()` (now genuinely checks cache status for these instead of
      hardcoding `true`).
- [x] Verify: `pytest -q` passes, including the Hub-resolution checks for all
      five `_COLIBRI_REPO_ID` values.
- [ ] Verify against a real `coli` install: start the backend, download OLMoE
      (the ~4GB family, the only one realistic to actually pull) from the
      Models tab, send it a chat message with no `coli serve` running yet, and
      confirm the backend spawns it automatically and the reply round-trips —
      including a second chat to a *different* Colibri model correctly
      stopping the first process first.

Explicitly out of scope: auto-fetching the `coli` binary itself (still a
one-time manual PATH install — see above), any installer/packaging changes,
SSE streaming in MULTI-AI's own `/api/chat`, running multiple Colibri
families at once.

## Code tab: opencode + llama-server

The Code tab (`app/lib/addons/code/`) is a local coding agent — read/edit
files and run shell commands in a real project folder, gated by an approval
dialog before anything risky. It used to run a hand-rolled agent loop over
[`dart_agent_core`](https://pub.dev/packages/dart_agent_core), eliciting tool
calls by prompting the model to reply with a literal
`<tool_call>{"name":...}</tool_call>` tag — Qwen2.5-Coder's own trained
Hermes-style format. Every other model just answered in prose and asked the
user to paste file contents instead of actually reading them, because
tool-calling that only works via one model family's trained text format isn't
tool-calling any model can reliably use — confirmed not just as a hunch but
by [`llamadart`](https://pub.dev/packages/llamadart)'s own bundled reference
coding-agent example (`example/tui_coding_agent`), which hits the identical
limitation with the identical protocol.

The fix was to stop eliciting tool calls by prompting and use a real agent
with native, model-agnostic tool-calling instead:
[opencode](https://opencode.ai) ([source](https://github.com/sst/opencode)),
run headless (`opencode serve`) and driven entirely over its HTTP/SSE API —
this app never shows opencode's own TUI. Two local processes back the tab:

- **`llama-server`** — llama.cpp's own server, serving the currently selected
  on-device (GGUF) model over an OpenAI-compatible API with `--jinja` enabled
  for real per-model-family tool-call grammar/parsing (llama.cpp implements
  this for Hermes/Qwen, Llama 3.x, Mistral, and others — solving generically
  what the old text-tag parser only solved for one). `llamadart`'s own
  embedded engine (`on_device_engine.dart`, used by on-device chat) has no
  server mode, so this is a second, independent inference process — chat is
  unaffected.
- **`opencode serve`** — runs the actual agent loop (tool selection, file
  edits, shell commands, permission checks) against that endpoint. A single
  instance is started lazily on the Code tab's first message and stays up for
  the app's life: opencode's server hosts any number of project
  directories/sessions at once via a `directory` query parameter on every
  request (confirmed against a running server, not documented), so switching
  project folders never needs a restart — only `llama-server` restarts, and
  only when the selected model actually changes.

**Getting the two programs.** On Windows x64 the Code tab installs them for you:
until both are found it shows an *Install* card (about 92 MB), which downloads
pinned releases of each from GitHub into the app's own data folder
(`<app data>\code_engine\`), verifies their SHA-256, and unpacks them. Nothing is
added to `PATH` and no admin rights are needed; deleting that folder is a full
uninstall (`code_engine_installer.dart`).

- **Pinned, not latest.** opencode v1.18.29 and llama.cpp b11193 (Vulkan build —
  32 MB and it runs on NVIDIA, AMD and Intel GPUs; a CUDA build is ~580 MB and is
  future work). The opencode client speaks an undocumented API confirmed against
  one release, so an unpinned download could break the tab with no change here.
  Bump a pin deliberately and re-run `test/real_code_run_test.dart` with
  `MULTI_AI_REAL_INSTALL=1`, which does a real install and a real end-to-end run.
- **Antivirus.** These are unsigned executables, and Norton 360 was seen deleting
  a freshly published llama.cpp build's `llama-server.exe` right after install,
  while leaving the older, widely used b11193 alone — hence that pin. "Installed"
  means the executable is still on disk, so a deleted install shows the Install
  card again; if your antivirus keeps removing it, add an exclusion for the
  `code_engine` folder or install the programs yourself.
- **Already installed?** The app looks, in order, at its own install, `PATH`, and
  the usual places the other install methods use (WinGet's package folder, npm's
  global folder, `~/.opencode`) — so a WinGet/npm install works even when it
  never made it onto `PATH` (`code_engine_locator.dart`).

Linux and macOS (and Windows on ARM) install them by hand, the same shape as the
`coli` binary above — the card says so instead of offering a download:

- `llama-server`: [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases)
- `opencode`: `curl -fsSL https://opencode.ai/install | bash`, or see
  [opencode.ai](https://opencode.ai) for other install methods (its own npm
  package, `opencode-ai`, works on Windows too)

`app/lib/addons/code/llama_server_supervisor.dart` and
`opencode_process_supervisor.dart` own these two processes (ping before
spawning so an already-running instance is adopted, health-poll after
starting, drain output into a log surfaced only on failure) — structurally
the same shape as `SearxngSupervisor`. `code_engine.dart`'s `CodeEngine`
composes both behind one `ensureRunning()` call `CodeAgentController` makes
at the top of every turn, mirroring `server.pyx`'s `_ensure_colibri_running`:
reuse if already correct, stop-and-restart if not, nothing spawns until the
first message is sent. `opencode_client.dart` is the HTTP/SSE client —
`POST /session`, `POST /session/:id/prompt_async`, a shared `GET
/event?directory=...` stream, and `POST /permission/:id/reply` for the
approval flow, which now maps directly onto opencode's own permission system
(`edit`/`bash`: ask; everything else: allow) instead of a hand-rolled gate.

**Which models actually call tools.** Checked against real `llama-server` +
opencode (Windows, llama.cpp b11193, 2026-10-24): **Gemma 4 E2B** returned a real
tool call 5 times out of 5 and completed a full read-a-file turn through the
Code tab. **Qwen2.5-Coder** (1.5B and 7B) did not — despite the name and a
tool-aware chat template, it writes the call as text in an invented format
(`<function .../>`, `<xml>{...}</xml>`, a bare JSON block) that llama.cpp can't
parse, so no tool ever runs. A model has to be *trained* for tool calling for
this tab to work; the code-specialised ones aren't necessarily. All 68 roster
models are sorted into works / should work / uncertain / should not in
[CODE-TAB-MODELS.md](CODE-TAB-MODELS.md), with the evidence for each.
`real_code_run_test.dart` repeats the end-to-end check — see its header for how
to run it against a model of your choice.

**Server-side models:** a model the Python backend manages weights for
(`hasServerWeights`, no BYO `externalEndpoint`) can drive the tab too. The
backend serves `GET /v1/models` and `POST /v1/chat/completions` from
`server.pyx`; for such a model `CodeEngine` skips `llama-server` and registers
the backend's models in opencode's config as a second provider
(`multiai-server`, `baseURL` = the backend). Opencode reads that config only at
startup, so the supervisor restarts the process it owns if asked for a server
model it didn't register.

That route does tool calling for transformers (`_REPO_ID`) models: a request
with `tools` skips the plain-text chat path and hands the tool definitions to
the model's own chat template (`apply_chat_template(..., tools=...)`) with the
full message history intact — system prompt, the assistant's earlier calls, and
tool results — then parses the output back into `tool_calls`. The parser
recognises Hermes/Qwen `<tool_call>` blocks and bare JSON in Llama's
(`parameters`) and Mistral's (`[TOOL_CALLS]` list) shapes, and only accepts a
call to a tool the request defined. The prompt may use up to 16384 tokens
(`_MAX_TOOL_PROMPT_TOKENS`, a VRAM ceiling like the chat's 4096) since an
agent's system prompt and tool definitions are large; older turns are trimmed
first, whole units at a time, never the system prompt or the current task.

**Caveats:** this is tested against a fake tokenizer and model, not a real
checkpoint — whether a given model's template renders tools and its output
parses depends on the model family, and a model whose template ignores `tools`
will just answer in prose. A model with no chat template, or a non-transformers
server model (Colibri), falls back to plain chat with no tool calls. Calls come
back whole, not token-streamed.

Ports in use: see `searxng_supervisor.dart`'s header comment (backend 8000,
Colibri 8010, SearXNG 8891) — this adds `llama-server` on 8100 and `opencode
serve` on 8101.

## Antigravity tab: your models behind a local OpenAI-compatible endpoint

**Experimental, Windows only.** The tab ([antigravity_addon.dart](app/lib/addons/antigravity/antigravity_addon.dart))
runs a small HTTP server on `127.0.0.1:8200` (port configurable) that serves the
downloaded models as `GET /v1/models` and `POST /v1/chat/completions`, so a
client that speaks the OpenAI API can use them. It is off until you press Start
(or turn on "Start automatically").

Google Antigravity itself has **no supported way to use outside models** (no BYOK
or custom-provider setting), so this only provides the endpoint. Whether
Antigravity can use it depends on third-party software. The community
[antigravity-proxy](https://github.com/12errh/antigravity-proxy) translates
Antigravity 2.0's Gemini calls to OpenAI-style providers, but its README
documents only per-provider API keys and auto-discovery of local servers, not a
custom base URL, so that combination is **untested**. It also needs administrator
rights and intercepts Antigravity's traffic on port 443 — read what it does
before installing it.

What the endpoint does and doesn't do:

- Every request needs `Authorization: Bearer <key>` (a random key generated on
  first use, shown in the tab, regenerable). Requests with an `Origin` header or a
  non-loopback `Host` are refused, and the server binds loopback only. Any local
  program holding the key can use your models while it runs.
- **No tool calling.** `tools` in a request are ignored and replies are plain text
  (`ModelPool.generate` has no tool-call path), so Antigravity's agent features
  won't work. Small local models are weak at agent work regardless.
- **No token-by-token streaming.** `stream: true` sends the whole reply as one
  chunk once the model finishes, with SSE keep-alive comments while waiting.
- A request naming a model this app doesn't have (every proxied request will) runs
  the tab's default model instead.
- A client hanging up mid-generation cancels it only for streamed requests, and
  only when it's the sole request in flight.

## File Architecture

```
MULTI-AI/
├── pyproject.toml                 # build-system: setuptools only — no Cython in the build path
├── setup.py                       # compiles every committed .c under Multi-AI/ to a .pyd/.so
├── backend_build.py               # shared .pyx/.c module discovery (setup.py + regen_cython.py)
├── scripts/regen_cython.py        # the one place Cython runs: regenerates the .c from the .pyx
├── Multi-AI/
│   ├── multi_ai/                  # the importable Python package
│   │   ├── server.pyx             # stdlib HTTP backend: /api/models, /api/chat, /api/hello, /api/device
│   │   ├── hardware.pyx           # GPU/RAM detection + per-model green/yellow/red fit ratings
│   │   ├── server.c               #   └─ Cython-generated C, committed — what setup.py compiles
│   │   ├── server.cp314-win_amd64.pyd  #   └─ compiled module — what actually runs (git-ignored)
│   │   ├── __init__.pyx           # package init (compiled like everything else)
│   │   └── models/                # 47 model entries — one file per model (server + on-device siblings)
│   │       ├── llama_3_2_3b.pyx           # server model: declares _REPO_ID (HF checkpoint)
│   │       ├── llama_3_2_3b_on_device.pyx # on-device sibling: declares _GGUF_SOURCE
│   │       └── …                          # falcon, gemma, mistral, qwen, deepseek, …
│   └── tests/                     # test_imports / test_model_roster / test_model_downloads (.pyx)
└── app/                           # Flutter frontend
    └── lib/
        ├── chat_screen.dart       # thin entry point: builds the pool + host, then AppShell
        ├── app_shell.dart         # sidebar, tab bar, top bar, banners — the frame add-ons draw in
        ├── model_pool.dart        # the `model_pool` capability: roster, downloads, generate()
        ├── on_device_engine.dart  # llama.cpp/llamadart, one resident model
        └── addons/                # one directory per tab — see "Add-on architecture"
            ├── addon.dart, addon_host.dart, registry.dart
            ├── chat/              # chat_controller.dart + chat_addon.dart
            ├── models/            # the roster browser
            ├── orchestration/     # the Model Council (controller + addon)
            └── code/               # the Code tab — see "Code tab" below
```

### What the `.pyx`, `.c`, and `.pyd`/`.so` files are

The Python backend is written in **Cython** and **must be compiled before it runs** — the runtime imports the compiled extension modules, never the `.pyx` source. You see three file types for what is conceptually one module because they're three stages of the same pipeline:

| File | Stage | Role |
|---|---|---|
| **`.pyx`** | source | What you edit. The source of truth — one file per model, plus `server.pyx`. Tracked in git. |
| **`.c`** | generated, **committed** | Cython's transpilation of the `.pyx`. Regenerated only by [`scripts/regen_cython.py`](scripts/regen_cython.py) (pinned Cython) — never edited by hand — and committed alongside the `.pyx`. This is what the build actually compiles, so Cython isn't needed to build. |
| **`.pyd`** (Windows) / **`.so`** (Linux/macOS) | compiled | A C compiler turns the `.c` into a native **CPython extension module** — the thing that's actually imported and run. The suffix (`.cp314-win_amd64.pyd`) is the ABI tag — CPython 3.14, win-amd64 — so the interpreter only loads a binary built for its exact version and platform. **Git-ignored**: platform/version-specific, so each machine rebuilds it. |

**You must compile before running.** `pip install -e . --no-deps` (from the repo root) invokes [setup.py](setup.py), which compiles every committed `.c` into a `.pyd`/`.so` next to its source and registers the package. This needs **a C compiler** (MSVC Build Tools on Windows, `gcc`/`clang` elsewhere) but **not Cython**. `--no-deps` builds the extensions without pulling the heavy chat-time deps (torch/transformers), which are lazy-imported only when you actually chat. Re-run it after adding or editing any `.pyx` — until you do, that model imports as `(broken)`.

**If you change a `.pyx`:** run `python scripts/regen_cython.py` (needs `Cython==3.3.0` — the pin is in that script) and commit the regenerated `.c` with it. CI ([backend-check.yml](.github/workflows/backend-check.yml)) regenerates the `.c` and fails if the committed copy doesn't match, and the release build repeats that check before packaging — a stale `.c` shipped broken once (v1.0.1) and this is what stops it recurring.

### How models are loaded (compiled imports, no source fallback)

Because the `.pyx` are compiled to real extension modules, the code that consumes them imports them normally:

- [server.pyx](Multi-AI/multi_ai/server.pyx)'s `_load_model_module()` does `importlib.import_module("multi_ai.models.<id>")`. It enumerates *which* models exist by scanning the directory for `*.pyx` (the source-of-truth list), then imports the compiled module for each. A `.pyx` with no matching `.pyd` raises `ImportError` and surfaces as an `(broken)`/unavailable entry — a "you forgot to recompile" signal, **not** a silent fallback to source.
- The test suite ([tests/](Multi-AI/tests/)) imports the same compiled modules. The test *files* themselves stay plain-Python `.pyx` loaded by pytest's [conftest.py](Multi-AI/tests/conftest.py) — the harness is source-loaded even though the runtime it drives is compiled-only.

### How a model file is structured

Each `models/*.pyx` is a tiny, declarative stub — a `get_info()` dict plus one module-level constant that says *how* it runs:

- **`_REPO_ID`** → a Hugging Face checkpoint the **server** loads via `transformers` (4-bit quantized to fit laptop VRAM).
- **`_GGUF_SOURCE`** → an `hf://…/*.gguf` URI the **Flutter app** runs **on-device** through `llamadart`/llama.cpp; the server never touches it. Surfaces as the `gguf` field on `/api/models`, which auto-routes through `OnDeviceEngine` in the app.

A model can have both — a `_REPO_ID` file for the server and a parallel `_on_device.pyx` sibling declaring `_GGUF_SOURCE` — which is exactly the on-device roster added above.

## Frontend (Flutter)

Install dependencies:

```bash
cd app
flutter pub get
```

Run:

```bash
flutter run -d windows
```

Run tests:

```bash
flutter test
```

The chat model dropdown always includes one **on-device** entry (currently Qwen2.5 0.5B, via [`llamadart`](https://pub.dev/packages/llamadart)/llama.cpp) that runs locally with no server or network calls after its first download — works even if the Python backend below isn't running. Every other entry in the dropdown comes from the backend and runs there. See `app/lib/on_device_engine.dart`.

## Python Backend

The backend is compiled — build it once (and after any `.pyx`/`.c` change) from the repo root:

```bash
pip install -e . --no-deps
```

This compiles every committed `.c` under `Multi-AI/` into a native `.pyd`/`.so` next to its source and registers the package. It needs **a C compiler** (MSVC Build Tools on Windows; `gcc`/`clang` elsewhere) but **not Cython** — the `.c` are checked in. `--no-deps` skips the heavy chat-time deps (torch/transformers), which are imported lazily only when you chat — install them separately when you need them.

If you edit a `.pyx`, regenerate its `.c` before rebuilding: `pip install "Cython==3.3.0" && python scripts/regen_cython.py`, then commit the `.c` alongside the `.pyx` (CI enforces they stay in sync).

Run a model directly (imports the compiled module and prints its metadata):

```bash
python -c "import multi_ai.models.qwen3_8b as m; print(m.get_info())"
```

Run the API server (serves `/api/hello`, `/api/models`, `/api/chat`, and `/api/device` on `http://localhost:8000`, which the Flutter app's chat screen calls):

```bash
multi-ai-server
```

> The `multi-ai-server` console script is created by the editable install. If its directory isn't on your PATH, use `python -c "from multi_ai.server import run; run()"` instead. A compiled extension module can't be launched as a script the way `python server.pyx` could, which is why there's a dedicated entry point.

Every model under `models/` points at a real Hugging Face checkpoint: 23 declare a `_REPO_ID` and the server loads/generates with `transformers`, while 22 declare a `_GGUF_SOURCE` and run on-device in the app via llama.cpp instead. Most GGUF entries are `_on_device` siblings of a server model; `gpt_oss_20b` is the exception, GGUF-only, because the transformers path won't fit in RAM. Selecting a model in the chat UI downloads its weights on first use (a minute or two for the 1–3B models, much longer for multi-billion-parameter ones) and keeps it cached in memory afterward.

Gated model families (Llama, Gemma) need a Hugging Face access token: run `huggingface-cli login`, or set `HF_TOKEN` in the environment, before chatting with one.

### Conversation history

Each `/api/chat` request carries the prior turns as `history: [{role, content}, …]`, and the on-device path passes the same turns to llamadart as a list of `LlamaChatMessage`s. Both then build a multi-turn prompt.

**This was broken until 2026-07-19** — every message was sent alone, so the model answered each one as if it were the first. The UI showed a thread, which made a stateless model look like it was hallucinating; the tell was a follow-up like "What is my name?" drawing a blank one turn after the name was given. It affected every model, not just weak ones.

Long chats are trimmed rather than allowed to overflow:

- The oldest turns are dropped first, so the newest exchange — the part the reply depends on — always survives.
- The budget reserves room for the new message *and* the reply, so history can't crowd out the answer it was meant to inform.
- Trimming never leaves an assistant turn first; a reply with no question above it reads as the model talking to itself.
- Capped at 4096 tokens (`_MAX_HISTORY_TOKENS`) regardless of the model's advertised window: the 256K-context models can't practically attend that far in this much VRAM. The on-device side approximates the same cap in characters (~4/token), since the tokenizer lives behind llama.cpp's FFI.

Error rows and "(response stopped)" placeholders are UI state and are excluded from what gets sent. Malformed history entries are dropped individually rather than failing the request.

### Image and audio input (multimodal models)

These models accept more than text, declared per-model via `_INPUT_MODALITIES` and surfaced as `input_modalities` on `/api/models`:

| Model | Accepts |
|---|---|
| `gemma_3n_e2b` / `gemma_3n_e4b` (Gemma 3n) | text, image, **audio** |
| `gemma_4_e2b` / `gemma_4_e4b` / `gemma_4_12b` (Gemma 4) | text, image, **audio** |
| `gemma_4_26b_a4b` / `gemma_4_31b` (Gemma 4) | text, image |
| `gemma_3_4b` / `gemma_3_12b` / `gemma_3_27b` (Gemma 3) | text, image |
| `medgemma_4b` / `medgemma_1_5_4b` / `medgemma_27b` (MedGemma) | text, image |
| `ministral_3_3b` / `_8b` / `_14b` | text, image |

The app gates its input buttons on that field: a **+** button left of the text box appears only for image-capable models, and a **microphone** button between the text box and Send appears only for audio-capable ones. A text-only model shows neither. Switching to a model that can't take what's staged drops those attachments and says so, rather than silently discarding them at send time.

Attachments ride along on `POST /api/chat` as base64 (`attachments: [{kind, mime_type, name, data}]`, 32MB each), get written to temp files, and go through the model's `AutoProcessor` chat template — the text-only tokenizer path is untouched. A model that doesn't declare a modality rejects it server-side, so the gate holds even if a client ignores it.

**On-device image input works too, via a second GGUF.** llama.cpp encodes images through a separate *multimodal projector* file (`libmtmd`), so a vision GGUF needs both the text weights and an `mmproj-*.gguf`. A model file declares that companion with `_GGUF_MMPROJ_SOURCE`, surfaced as `mmproj` on `/api/models`; `OnDeviceEngine` downloads it and calls `loadMultimodalProjector()` before generating. These on-device entries have one:

| On-device entry | Projector |
|---|---|
| `gemma_3_4b_on_device` / `gemma_3_12b_on_device` / `gemma_3_27b_on_device` | `mmproj-F16.gguf` |
| `gemma_4_e2b_on_device` / `gemma_4_e4b_on_device` | `mmproj-F16.gguf` (omni: image + audio) |
| `gemma_4_12b_on_device` / `gemma_4_26b_a4b_on_device` / `gemma_4_31b_on_device` | `mmproj-F16.gguf` (image only here — see note below) |
| `medgemma_4b_on_device` / `medgemma_1_5_4b_on_device` / `medgemma_27b_on_device` | `mmproj-F16.gguf` |
| `ministral_3_8b_on_device` / `_14b_on_device` | `mmproj-F16.gguf` |
| `ministral_3_3b_on_device` | `…-BF16-mmproj.gguf` (mistralai's repo ships only BF16) |

A GGUF entry earns a non-text modality **only** by declaring a projector — text weights alone load and chat but silently can't see. `gemma_3n_e2b_on_device` is the one multimodal checkpoint with no projector published anywhere (llama.cpp doesn't implement Gemma 3n's vision/audio towers), so it and `gemma_3n_e4b_on_device` stay text-only; use the server-backed `gemma_3n_e2b` / `gemma_3n_e4b` for image and audio input. `gemma_4_12b` has an audio tower, but whether its GGUF projector carries audio is unverified, so its on-device entry declares image only.

Downloading a vision model fetches both files, and neither the Models tab nor the chat picker counts it as downloaded until both are cached — otherwise the + button would appear against a model that can't actually see. Deleting removes both.

**On-device audio is not available at all.** The four projector-equipped models are vision-only; the one audio-capable checkpoint (Gemma 3n) has no llama.cpp projector. Audio input means the server.

Multimodal generation needs extra chat-time deps beyond `torch`/`transformers`:

```bash
pip install pillow torchvision          # image input
pip install librosa soundfile           # audio input (Gemma 3n)
pip install timm                        # Gemma 3n specifically — its vision tower is a timm model
```

When a model fails to load, the reply names the specific missing dependency. (It used to append "gated repos need HF_TOKEN" to *every* load failure, which sent you hunting for an auth problem when the real cause was a missing package.)

Verified against real weights (2026-07-19): `ministral_3_3b` and `gemma_3n_e2b` both read a generated test image correctly, and `gemma_3n_e2b` processed a WAV without error. The audio check used a synthesized 440Hz tone rather than speech — that exercises decode → feature extraction → audio encoder end-to-end, but says nothing about transcription quality on real speech, which is still untested. On-device (mmproj) image input is also untested against real weights: the plumbing and gating have unit coverage, but no projector has actually been downloaded and run.

`torchvision` must match your torch build — on CUDA 12.8, `pip install torchvision --index-url https://download.pytorch.org/whl/cu128`. Without it, image sends fail with "PixtralProcessor requires the Torchvision library".

> **The Flutter app now needs Windows Developer Mode.** The image picker (`file_picker`) and recorder (`record`) are plugins, and Flutter's Windows desktop build symlinks plugin sources — so `flutter run -d windows` fails with "Building with plugins requires symlink support" until you run `start ms-settings:developers` and turn Developer Mode on (one-time). This is a change from before: the app previously avoided all plugins for exactly this reason. That reasoning is now fully moot — `path_provider` was added too once `file_picker`/`record` had already paid this cost (see the Android persistence fix above). Android/iOS builds are unaffected.

> **Partial downloads used to fail silently.** Weights are loaded with `local_files_only=True` first (fast, and it dodges hub rate limits), but a half-finished cache satisfies that: the config JSON lands before the vocabulary, so a tokenizer loads *without error* and then encodes every token to `<unk>`. The prompt became one junk token, generation produced noise, and the reply was an unexplained "(model returned an empty response)" — which then repeated for the rest of the server's life, because the broken tokenizer was cached in memory. The server now sanity-checks a freshly loaded tokenizer, re-fetches from the hub if it's degenerate, and says so plainly if it still is.

> If every HTTPS request fails with `CERTIFICATE_VERIFY_FAILED`, something on your machine (antivirus or a network proxy) is intercepting TLS with a non-standard root certificate. `pip install pip-system-certs` makes Python trust the Windows certificate store instead of its bundled list, which usually fixes it.

### Hardware fit ratings

The roster spans 0.5B to 20B, and the difference between "this runs great" and "this downloads 12GB and then OOMs" isn't visible from a parameter count. So the backend sizes up the machine and rates every model against it, and the app colours each one:

| Badge | Meaning |
|---|---|
| 🟢 **Optimal** | Fits with headroom — full GPU offload, room left for a long conversation |
| 🟡 **Possible** | Runs, but tight on VRAM or partly CPU-bound. Usable, not fast |
| 🔴 **Not recommended** | Doesn't fit, or only "fits" by running mostly on the CPU at unusable speed |
| ⚪ **Unknown** | No CUDA GPU or unreadable memory total — a missing measurement, not a verdict |

`multi_ai/hardware.pyx` does the sizing: RAM via stdlib (`GlobalMemoryStatusEx` on Windows, `sysconf` elsewhere) and VRAM via a **lazily imported** `torch` — listing models still works on a machine that never installed the heavy deps, it just rates everything "unknown". Results are surfaced as a `fit` object per model on `/api/models`, plus a `GET /api/device` endpoint the app uses to caption the Models tab with the hardware being judged against.

The two run paths get **different formulas**, because `size_gb` means different things for each:

- **`_REPO_ID` (server)** — `size_gb` is the fp16 checkpoint, but transformers loads it 4-bit, so the estimate is `size/4 × 1.15 + 1.2GB` workspace and compares against **VRAM only**. Rating a 7B on its 14.5GB fp16 size would wrongly condemn most of the roster.
- **`_GGUF_SOURCE` (on-device)** — `size_gb` is already the quantized file, so `size × 1.1 + 0.8GB`. Three regimes: fits VRAM with headroom (full offload), fits but tight (llama.cpp drops layers), or spills to CPU.

The CPU-spill cutoff is calibrated on the Wave 0 benchmarks above rather than guessed: `gpt_oss_20b` (12.11GB) technically *passes* on this machine — the GPU-layer ladder rescues it — at **0.1 tok/s**, 198s for one short reply, while `falcon2_11b_on_device` (6.85GB) full-offloads at a usable 4.3 tok/s. So a GGUF that overflows VRAM and exceeds ~10GB rates red, not yellow: **"it runs" and "you'd wait three minutes for a sentence" are different claims**, and only one of them should be green.

Colour is never the only signal — every badge carries its text label and a one-line explanation in this machine's actual numbers ("Needs about 5.4 GB of your 11.9 GB VRAM — comfortable fit"), so the verdict is auditable rather than a mystery traffic light.

> **Scope caveat.** Ratings describe the **backend machine**, including for on-device GGUF entries. That's correct when the app and server run on the same desktop (the current setup) but wrong once the app runs on a phone against a remote backend — a phone can't be judged by its server's GPU. Rating on-device entries against the *app's* hardware needs a device-side probe that doesn't exist yet.

Run tests (from the `Multi-AI/` directory, where the pytest config and `conftest.py` live — and after building, since the tests import the compiled modules):

```bash
pip install pytest
cd Multi-AI
pytest -q
```

- `tests/test_imports.pyx` — every `models/*.pyx` file compiles, imports, and declares `get_info()` plus a `_REPO_ID`/`_GGUF_SOURCE`.
- `tests/test_model_roster.pyx` — the model list matches `models/*.pyx` both internally and through the live `GET /api/models` endpoint (what the Flutter dropdown actually calls).
- `tests/test_hardware_fit.pyx` — the fit ratings behave: rated against *synthetic* specs (a 12GB card, a 4GB card, no GPU) so the result doesn't change with whichever machine runs the suite, plus a monotonicity property (a bigger model must never rate better than a smaller one) and a check that every listed model carries a rating.
- `tests/test_model_downloads.pyx` — every declared `_REPO_ID`/`_GGUF_SOURCE` resolves on the Hugging Face Hub (metadata-only checks, no weights downloaded). Needs network; skips per-model on unreachable-Hub errors but fails on a genuinely broken/renamed source.

## TODO

All TODO items have moved to [TODO.md](TODO.md).
