# TODO

Open and completed work items for Multi-AI. Checked items are done; unchecked items are open.

## Priority Roadmap

| Priority | Feature / Improvement | Impact |
|---|---|---|
| **High** | **Streaming (SSE) in Python Backend** | Eliminates long blank waits for 7B+ server models; brings server UX to parity with on-device streaming. |
| **High** | **On-Device Download Progress Bar** | Threading `llamadart`'s `ModelDownloadProgress.fraction` into the UI prevents multi-GB downloads from looking like frozen UI spinners. |
| **Medium** | **OpenAI-Compatible Route on Server** | Lets the Code tab, LibreChat, or external tools use the server-side 4-bit quantized models directly. |
| **Medium** | **Environment Doctor Script (`doctor.ps1`)** | Validates MSVC, Rust/Cargo, Python 3.14 embed, `coli`, and `opencode` to simplify developer setup. |
| **Low / Polish** | **Documentation Site (GitHub Pages)** | Publishing your architecture guides and model fit benchmarks to a clean documentation site (VitePress/Starlight) would attract strong community interest. |

- [ ] **Streaming (`SSE`) in Python Backend** — Implement Server-Sent Events (`text/event-stream`) in `server.pyx`'s `/api/chat` and update `api_client.dart` to yield stream chunks so server generation mirrors on-device streaming.
- [ ] **On-Device Download Progress Bar** — Thread `llamadart`'s `ModelDownloadProgress.fraction` callback from `OnDeviceEngine` into the chat screen and models tab download UI.
- [x] **OpenAI-Compatible Route on Server** — `multi_ai/server.pyx` now serves `GET /v1/models` and `POST /v1/chat/completions` for server-side models (system text is folded into the last user turn; `stream: true` gets the whole reply as one SSE chunk, pending real streaming). Tested (`tests/test_openai_route.pyx`, plus live HTTP checks of both the plain and SSE paths) but only with generation stubbed — never against a real model, since that needs torch/transformers. The Code tab still isn't pointed at it; that wiring remains.
- [x] **Environment Doctor Script (`scripts/doctor.ps1`)** — Automated health-check script verifying Flutter, MSVC compiler and Rust/Cargo (required, exit 1 on failure), plus Python 3.14 and the optional tools (`coli`, `opencode`, `llama-server`) as warnings, each with a remediation hint.
- [ ] **Documentation Site (GitHub Pages)** — Setup a static docs site (VitePress or Starlight) to host guides, model fit benchmarks, architecture diagrams, and installation workflows.

## Extend on-device (GGUF/llama.cpp) model support

Mobile can't run the `transformers`/`torch`/`bitsandbytes` server backend (no CUDA, no mobile builds of those libs) — the on-device path is GGUF weights run through `llamadart`/llama.cpp, already proven with the built-in Qwen2.5 0.5B (`app/lib/on_device_engine.dart`). The `_GGUF_SOURCE` → `"gguf"` JSON field → `ModelInfo.gguf` routing in `chat_screen.dart` is already generic (any model with a `gguf` field auto-routes through `OnDeviceEngine`, no Dart changes needed) — only one model (`gpt_oss_20b.pyx`) currently uses it.

- [x] Add on-device sibling model files (declare `_GGUF_SOURCE` only, mirror `Multi-AI/multi_ai/models/gpt_oss_20b.pyx`'s shape) for verified-available GGUF quantizations, alongside their existing `_REPO_ID` file rather than replacing it (one server file plus one `_on_device` sibling per model):
  - [x] `llama_3_2_1b_on_device.pyx` — `unsloth/Llama-3.2-1B-Instruct-GGUF`
  - [x] `llama_3_2_3b_on_device.pyx` — `unsloth/Llama-3.2-3B-Instruct-GGUF`
  - [x] `gemma_3_4b_on_device.pyx` — `unsloth/gemma-3-4b-it-GGUF`
  - [x] `deepseek_r1_distill_1_5b_on_device.pyx` — `unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF`
  - [x] `falcon_3_3b_on_device.pyx` — `tiiuae/Falcon3-3B-Instruct-GGUF`
  - [x] `ministral_3_3b_on_device.pyx` — `mistralai/Ministral-3-3B-Instruct-2512-GGUF`
  - (all use the `Q4_K_M` quant, confirmed against each repo's file listing; note Falcon3's file is lowercase `q4_k_m`)
- [ ] Android: add `<uses-permission android:name="android.permission.INTERNET"/>` to `app/android/app/src/main/AndroidManifest.xml` (currently missing — needed for on-device GGUF downloads to work on a real device)
- [ ] iOS: verify `Info.plist`/ATS on first real device build (huggingface.co is standard HTTPS, likely needs no changes)
- [ ] Download progress UI: `llamadart` already exposes an `onProgress`/`ModelDownloadProgress.fraction` callback on `loadModelSource` (confirmed in the installed `llamadart-0.8.11` source) and already resumes partial downloads itself — just thread the callback from `OnDeviceEngine._ensureLoaded`/`generate` (`app/lib/on_device_engine.dart`) up into `chat_screen.dart`'s thinking-row UI (`_buildThinkingRow`, currently a static "Thinking…" string)
- [ ] Verify: `pytest -q` (roster/import tests) → `flutter run -d windows` (desktop llamadart run, no phone needed) → real Android build (the one thing desktop testing can't catch is the missing `INTERNET` permission)


## A real speedup for GPT-OSS 20B and the dense 10–14B models

Colibri (above) can't be the answer for these — it only implements the five
MoE families it ships hand-written engines for, GPT-OSS is a different MoE
architecture Colibri doesn't support (not even on its roadmap), and the
dense models (`falcon2_11b`, `mistral_nemo_12b`, `ministral_3_14b`) have no
experts to stream in the first place. Their slowness is a separate,
still-open problem:

- `gpt_oss_20b` on-device: **0.1 tok/s**, 198s for one short reply once it spills
  onto the CPU (see the Wave 0 benchmarks above) — technically works, not
  practically usable.
- `falcon2_11b`, `mistral_nemo_12b`, `ministral_3_14b`: server-side (`_REPO_ID`)
  they're rated against VRAM after 4-bit quantization same as everything
  else, and on-device they're the partial-offload candidates Wave 4 hasn't
  run yet.

Possible directions, none investigated yet:

- [ ] A dedicated llama.cpp **server** process instead of running GGUF
      in-app via llamadart — decouples generation from the Flutter process
      and might expose batching/scheduling llamadart's embedded use doesn't.
- [ ] Better quantization for the CPU-spill cases (a smaller quant, or one
      more suited to CPU inference than Q4_K_M).
- [ ] Tuning `_gpuLayerLadder` (`app/lib/on_device_engine.dart`) — it was
      calibrated on Vulkan against this machine's 11.7GB VRAM; revisit once
      Wave 3/4 (the 7–14B on-device entries) actually run.
- [ ] Whether `_CPU_FALLBACK_LIMIT_GB` in `hardware.pyx` (currently 10.0GB,
      calibrated on the single `gpt_oss_20b` data point) should apply more
      granularly once more large-model benchmarks exist.


## Other items

### AI Orchestration Portion
  - [x] Create the Orchestration Page — the Model Council, see "Orchestration" above
  - LangGraph was the original idea here; it's Python-only and lives on the wrong
    side of the app/backend split. The Dart-side alternatives (Genkit, Agenix,
    dart_agent_core) were evaluated and declined — the council needs fan-out, not
    an agent framework. Revisit a framework only if routing grows real agent loops.
  - [ ] Multi-round deliberation (parallel and sequential ship; multi-round doesn't)
  - [ ] Preset manifests — make the member set, lead, mode and lead prompt a
    downloadable JSON recipe (the add-on contract's preset follow-on)

### AI Coding Tool Portion
  - [x] Create coding page — the Code tab, backed by `opencode` + `llama-server`
    rather than a hand-rolled agent loop, see "Code tab" above
  - [x] Bridge server-side (`_REPO_ID`) models into the Code tab — wired
    through the backend's `/v1/chat/completions`, see "Server-side models" in
    that section. Not run end to end (needs opencode + a real model).
  - [x] Real run of the Code tab on an on-device model (2026-10-24) — works
    end to end with Gemma 4 E2B; Qwen2.5-Coder 1.5B/7B don't emit parseable
    tool calls (see the README's "Which models actually call tools"). Fixed a
    Windows bug found on the way: `stop()` left `opencode.exe` running. Still
    unrun: the server-model path (needs torch + a CUDA build for the GPU).
  - [x] Ship the Code tab working out of the box (Windows x64) — an Install card
    downloads pinned, checksum-verified `llama-server` (b11193 Vulkan) and `opencode`
    (v1.18.29) into the app's data folder; the app also finds WinGet/npm installs
    that aren't on `PATH`. Verified with a real install + a real end-to-end run
    (Gemma 4 E2B read a file through opencode using only the app-installed
    binaries). Open: a CUDA build option, Linux/macOS (still manual), and
    antivirus — Norton deleted a brand-new llama.cpp build's exe, see the README.
  - [x] Show each model's Code-tab verdict on its detail page — a model like
    Qwen2.5-Coder prints its call as text with no hint why, and Gemma 3 invents
    file contents. `app/lib/code_tool_support.dart` holds the per-model table
    (evidence in [CODE-TAB-MODELS.md](CODE-TAB-MODELS.md)); tests fail if a new
    model file lacks an entry.
  - [x] Warn where the model is *picked* — choosing a model the table rates
    "unlikely" in the Code tab's picker now opens a confirm dialog ("Choose
    another" / "Use anyway", shown once per model per run). An "uncertain" model
    selects without a warning. The picker's empty-state text no longer
    recommends Qwen2.5-Coder, which doesn't call tools.
  - [x] Tool calling on the server's OpenAI route — `tools` go through the
    model's chat template and `tool_calls` are parsed back out (Hermes/Qwen,
    Llama, Mistral shapes). Tested with a fake tokenizer/model only; **still
    needs a real run** against an actual checkpoint (see below).

### Docs & info site (GitHub Pages)
  - [ ] A public docs/marketing site along the lines of flutter.dev — project
    overview, install instructions per platform, model roster, architecture
    docs — built from this repo and deployed to GitHub Pages via a GitHub
    Actions workflow (e.g. `actions/deploy-pages`) on push to `main` or on
    tag, separate from the release workflow that builds the installer/APK.
  - [ ] Pick a static-site generator (Jekyll comes free with Pages, but
    Docusaurus/VitePress/Hugo are closer to flutter.dev's actual docs-site
    shape — versioned docs, search, nav sidebar) and decide whether content
    is authored directly as site pages or generated from this README/other
    markdown so the two don't drift apart.
  - [ ] Custom domain + HTTPS (GitHub Pages supports both) once content exists.
  - [ ] Landing page for the site, built from the existing `app/web/` folder (currently an untouched Flutter web scaffold; the Windows and Android builds never use it). Replaces the old "delete Web folder" item. Decide whether it stays a Flutter web target or moves to a top-level site folder, since Pages deploys from a static build.

### Android

**Scope: Android only (iOS is not a target), and on-device GGUF only — the
phone never talks to the Python backend.** That second decision removes a lot
of work (no runtime server-URL setting, no LAN entry in
`network_security_config.xml`, no cleartext HTTP, and the Models tab's
server download/delete calls and `/api/device` header can be compiled out) but
it creates one new problem, below.

Already done, contrary to what the on-device TODO above still says: the
`INTERNET` and `RECORD_AUDIO` permissions are declared in
`app/android/app/src/main/AndroidManifest.xml`, `network_security_config.xml`
exists, and `chat_screen.dart` already has a `LayoutBuilder`/`Drawer` phone
layout.

- [x] **Bundle the model roster as an asset** — the app had no local roster:
      `_GGUF_SOURCE` lives in `Multi-AI/multi_ai/models/*.pyx`, Cython-compiled
      and server-side, so with no reachable backend `ModelPool.refresh()` fell
      back to a single hardcoded Qwen2.5 0.5B plus a red "Backend unreachable"
      banner. Fixed: `app/tool/generate_on_device_roster.dart` (a new,
      standalone `dart run` script, duplicating rather than importing
      `verify_on_device.dart`'s private `_parseRoster` — that one only reads 4
      of the 9 fields `ModelInfo` needs) parses every `.pyx` declaring a
      module-level `_GGUF_SOURCE` (27 today) and writes
      `app/assets/on_device_roster.json` in the same shape `/api/models`
      already emits, so `ModelInfo.fromJson` reads it with zero new parsing
      code. `ModelPool.refresh()` branches on a real, OS-level Android check
      (see the `platform_check.dart` note below) to load the asset instead of
      calling `fetchModels()`. Re-run the generator after any `.pyx` change and
      before any Android build — nothing does it automatically yet.
- [x] **Fix persistence — it was silently broken on mobile.**
      `chat_store.dart` and `thinking_settings.dart` (a byte-for-byte
      duplicate) resolved their data directory from `Platform.environment`,
      empty on Android, falling through to an unwritable relative path with a
      `catch (_)` swallowing the failure into "no history". Fixed with
      `path_provider`'s `getApplicationSupportDirectory()` — the stale
      Developer-Mode-avoidance reasoning no longer applies (`file_picker`/`record`
      already pay that cost). `thinking_settings.dart`'s duplicate is gone;
      it now calls `chat_store.dart`'s shared `appDataFile`, which also means
      `addon_host.dart`'s `AddOnStateStore` inherited the fix for free.
      `ChatStore`/`ThinkingSettingsStore` are now interfaces
      (`FileChatStore`/`FileThinkingSettingsStore` are the real
      implementations) so `InMemoryChatStore`/`InMemoryThinkingSettingsStore`
      exist for tests, mirroring `InMemoryAddOnStateStore`.
      A second, previously-unflagged gap: the on-device model *cache* has
      three independent construction sites (`ModelPool`, `ModelDetailScreen`,
      and `OnDeviceEngine`'s own `LlamaEngine`), each defaulting to
      `DefaultModelDownloadManager()`'s OS-purgeable temp-directory fallback on
      Android. All three now share one durable directory
      (`androidModelCacheDirectory()` in `model_pool.dart`) via
      `DefaultModelDownloadManager.appPrivate(...)`, threaded into
      `OnDeviceEngine` through a new settable `downloadManager` field (it stays
      Flutter-plugin-free itself, so `verify_on_device.dart` still runs under
      plain `dart run` — only the already-Flutter-bound `ModelPool` does the
      `path_provider` resolution and hands down the finished manager).
      **Trap worth knowing:** `defaultTargetPlatform` — the obvious way to
      check "is this Android" — is overridden to `TargetPlatform.android` by
      the `flutter_test` binding on every host OS, which silently broke every
      existing widget test the first time this landed (confirmed by probing it
      directly under `flutter test`). `app/lib/platform_check.dart` provides
      `isAndroidHost` instead: a conditional-import shim (`dart:io`'s real
      `Platform.isAndroid` where available, `false` on web) that's accurate
      under test. Everything above keys off `isAndroidPlatform` in
      `model_pool.dart` (`!kIsWeb && isAndroidHost`), not `defaultTargetPlatform`.
- [ ] **Device-side fit ratings** — currently `fit` comes from the backend and
      is null with no server, so every badge vanishes on the platform that needs
      it most: the roster carries `gpt_oss_20b` at 12.11GB and several 7–14B entries,
      and a phone will happily start a download that can never load. Simpler than
      the server version — only the GGUF formula applies (`size × 1.1 + 0.8GB`),
      against total RAM rather than VRAM. Realistically only the ≤2–3GB Q4
      entries should be listed at all. Supersedes the scope caveat under
      "Hardware fit ratings".
- [ ] **Verify llamadart's `android-arm64` backend before tuning anything.**
      `_gpuLayerLadder` in `app/lib/on_device_engine.dart` was calibrated on
      *Vulkan* against 11.7GB of dedicated VRAM; its own comment concedes the
      free-VRAM question "would be wrong on the phone targets anyway". If the
      Android bundle is CPU-only, `gpuLayers` is moot and the ladder just burns
      three reload attempts before landing on `0`. llamadart's `hook/build.dart`
      does ship real `android-arm64`/`android-x64` bundles, so no companion
      package is needed (unlike the iOS SwiftPM path) — but which compute backend
      is in them is unchecked.
- [ ] **Foreground service for downloads** — Android kills a multi-GB fetch as
      soon as the app backgrounds. Pairs with the download-progress indicator
      already open above.
- [x] **Release signing** — see "Shipping an Android release" above. A real
      keystore now signs release builds (falling back to debug only when
      `key.properties` is absent, e.g. a fresh clone); CI reconstructs it from
      repo secrets and verifies the result isn't debug-signed before shipping.
      Distribution is a signed APK on GitHub releases, not the Play Store —
      see that section for why.
- [ ] **On-device image input is unverified on Android** — the `mtmd` symbol
      resolution problem root-caused under `dart run` (see the on-device
      verification notes) has never been checked against an Android bundle.

Suggested order: roster asset and `path_provider` first (both independent of
any device being present, and together they make the build testable at all),
then `flutter run` on the Pixel_9 emulator for the first honest signal, then
device-side fit, then the foreground-download service.

### Linux

Unlike Android, Linux is a **full-fat desktop target**: both run paths (the
Python/`transformers` server *and* on-device GGUF) are in scope, because a Linux
box has the same CUDA and RAM story as the Windows dev machine. Most of the
work is therefore packaging and scripting, not architecture — none of it has
been attempted or verified, but very little of it looks hard.

What already works by construction, and is worth not re-solving:

- `setup.py` is platform-agnostic — it walks for the committed `.c` (via
  `backend_build.py`) and compiles each as an `Extension`, so `pip install -e .
  --no-deps` should produce `.cpython-314-x86_64-linux-gnu.so` files under
  `gcc`/`clang` with no changes. The `.c` are OS-independent (the regen
  normalises paths), so `scripts/regen_cython.py` and the backend-check CI job
  run anywhere. (The `.pyd` naming throughout this README is Windows-specific
  prose, not a code assumption.)
- `hardware.pyx` already branches: `GlobalMemoryStatusEx` on `win32`, and
  `os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")` everywhere else.
  The VRAM path is `torch.cuda`, which is if anything better supported on Linux.
- `chat_store.dart` and `thinking_settings.dart` resolve `XDG_DATA_HOME` (then
  `$HOME/.local/share`). Linux is the one platform where their environment-
  variable approach genuinely works — contrast the Android entry above, where
  the same code silently writes nowhere.
- `app/linux/` scaffolding exists (`CMakeLists.txt`, `runner/`,
  `my_application.cc`) and `record_linux` is registered in
  `generated_plugin_registrant.cc`.
- **No Developer Mode / symlink problem.** That constraint is Windows-only, so
  the plugin-avoidance reasoning documented elsewhere in this README does not
  apply here.
- llamadart's `hook/build.dart` ships `linux-x64` and `linux-arm64` bundles, so
  the native-assets path resolves with no companion package.

- [ ] **Decide the packaging story — this is the real fork in the road.**
      `installer/multi-ai.iss` is Inno Setup, Windows-only, and the trick it
      wraps does not port: there is no Linux equivalent of embeddable CPython,
      and the `python._pth` / `pip.pyz --target` dance exists purely to work
      around Program Files being read-only. On Linux the honest options are a
      `venv` built at first launch, or an AppImage/Flatpak carrying its own
      interpreter. Cheapest credible v1 — and the one that matches the Android
      scoping decision — is **"Linux is a source install"**: document
      `pip install -e . --no-deps` plus `flutter build linux`, ship no installer,
      and revisit once someone actually wants a one-click Linux download.
- [ ] **Port or explicitly disable the bundled-backend supervisor.**
      `app/lib/backend_process.dart` is hardcoded Windows throughout: backslash
      path joins, `python\python.exe`, `%LOCALAPPDATA%`, and an `isBundled`
      gated on `Platform.isWindows`. The *safe* current behaviour is that
      `isBundled` is false on Linux, so `startup_gate.dart` falls straight
      through to the chat screen and you start `multi-ai-server` yourself —
      exactly the development experience. That is fine and needs no code today;
      it only becomes work if the packaging decision above says otherwise.
      Whichever way it goes, the file should say so rather than leaving the
      Windows-only gate looking accidental.
- [ ] **Build-time system dependencies** — Flutter Linux desktop needs `clang`,
      `cmake`, `ninja-build`, `pkg-config` and `libgtk-3-dev`; `record_linux`
      additionally wants ALSA/PulseAudio headers. Document them, since a missing
      one surfaces as a CMake error rather than anything mentioning Flutter.
- [ ] **Runtime system dependency: `xdg-desktop-portal`.** `file_picker` 11
      talks to `org.freedesktop.portal.FileChooser` over D-Bus (`dartPluginClass`,
      so nothing appears in `generated_plugins.cmake` — its absence there is
      correct, not a bug). A headless or minimal desktop with no portal backend
      installed gets no file dialog, which will read as "the + button is
      broken". Note this is a **change from `file_picker` 8.x**, which shelled
      out to `zenity`/`qarma`/`kdialog` — don't follow older guidance found
      online.
- [ ] **Verify llamadart's `linux-x64` compute backend.** Same unknown as the
      Android entry: the Windows bundle turned out to be Vulkan (see the Wave 0
      notes), and the hook's CUDA-detection helpers (`_windowsCudartPattern`,
      `_hasWindowsBackendModule`) are explicitly Windows-only, so which backend
      Linux gets is unread. This decides whether `_gpuLayerLadder` is doing
      anything useful there or just burning reload attempts.
- [ ] **Shell-script equivalents** — `scripts/` is three PowerShell files
      (`run-windows.ps1`, `run-app.ps1`, `restart-backend.ps1`). The
      port-8000-holder lookup in `restart-backend.ps1` needs `lsof`/`ss` instead
      of `Get-NetTCPConnection`.
- [ ] **CI** — `.github/workflows/release.yml` is a single Windows job. Add a
      Linux build (at minimum `pip install -e . --no-deps` + `pytest -q` +
      `flutter build linux`, which would also catch Windows-only regressions in
      the backend early), or state that Linux is deliberately source-only.

Suggested order: build it once by hand end-to-end (`pip install -e . --no-deps`
→ `pytest -q` → `flutter build linux` → chat with one server model and one
on-device model) and let that tell you which of the above are real. The
packaging decision can wait until that works; everything else is downstream
of it.

### Model status after the 2026-07-20 fix round

Root causes found for the manual-test failures: (1) the server fed raw text
instead of applying chat templates, so instruct models "continued" the prompt
— that was the "hallucinating"; (2) loaded models were never evicted, so
switching models stacked them in the 12GB GPU until it choked; (3) official
Gemma/Llama repos are gated; (4) Ministral 3 ships FP8 weights that need
Triton kernels which fail on Windows; (5) 20B+ models simply don't fit.

Verified working (each answered a test question correctly):

- [x] Qwen2.5 0.5B (on-device) — user-confirmed
- [x] `deepseek_r1_distill_1_5b` — fixed by chat template + `<think>` stripping (19s)
- [x] `falcon_h1_1_5b` — fixed by chat template (6s)
- [x] `falcon_3_3b` — fixed by load fixes (10s)
- [x] `falcon2_11b` — fixed: a server bug was masking its real load error (47s)
- [x] `falcon_mamba_7b` — fixed; base model, replies truncated at invented turns (43s)
- [x] `ministral_3_3b` — fixed by swapping to the bf16 `unsloth` mirror (official FP8 weights need Triton kernels that don't work on Windows)
- [x] `llama_3_2_1b` — fixed by swapping to ungated `unsloth` mirror (4s)
- [x] `qwen3_8b` — regression-checked (17s)
(`"hi"` → `"hi"`, `"What color is the sky"` → `"What color is the moon?"`) and otherwise rambled. Nothing to fix — it was mostly a source of output that looked like a bug. Both `gpt2.pyx` and `gpt2_on_device.pyx` deleted; `gpt_oss_20b` (GPT-OSS 20B) is unrelated and stays.
- [x] `gemma_1_2b` — ungated `unsloth` mirror works (8s)
- [x] `gemma_3n_e2b` / `gemma_3n_e2b` — all three modalities confirmed (2026-07-19): text (14s), image (5s, correctly read a red circle), audio (3s). Needed `pip install timm` — its vision tower is a `TimmWrapperModel`, and without it the load failed with an error the server then mislabeled as a gating problem.
- [x] `gemma_3_4b` — text (13s) and image (4s, correctly read the same test circle). Its first run returned "(model returned an empty response)": the weights were chatted with before the download finished, so `local_files_only=True` loaded a vocabulary-less tokenizer that encoded the whole prompt to one `<unk>`. See the partial-download guard below.
- [x] `gemma_2_2b` / `gemma_3_1b` — ungated `unsloth` mirrors, same mechanism as the `gemma_1_2b`/`gemma_3n_e2b`/`gemma_3_4b` set now verified above; these two just aren't downloaded yet
- [x] `gpt_oss_20b` (GPT-OSS 20B) — rerouted to run **on-device** via llama.cpp GGUF (native MXFP4, 12.11GB download on first chat); via transformers it
- [x] `falcon_7b` — swapped to `falcon-7b-instruct` (base variant couldn't chat)

2026-07-17: "only the on-device Qwen works" root-caused — gpt2 generated past
its 1024-token position-embedding table (`max_new_tokens=1024` regardless of
context size), firing a CUDA device-side assert that corrupts the process's
GPU state and makes **every** server model fail until restart. The server now
clamps generation to each model's `max_position_embeddings` and flags
CUDA-poisoned state in error replies. Verified: gpt2 → falcon_3_3b →
deepseek_r1_distill_1_5b all answer correctly in one server run.

Fix applied, not yet run (weights download on first use):


- [ ] `llama_3_8b` / `llama_3_1_8b` / `llama_3_2_3b` / `llama_3_2_3b` — ungated mirrors
- [ ] `ministral_3_8b` / `ministral_3_14b` — bf16 mirrors (3B variant verified)
 dequantizes to ~40GB, more than this machine's RAM. Duplicate `GPTOSSS20b.pyx` removed (2026-07-18: its orphaned `__pycache__/GPTOSSS20b.cpython-314.pyc` was still tracked in git; untracked and deleted). Server side verified 2026-07-18: roster lists it as available with `gguf` set and no `_REPO_ID`, `/api/chat` correctly defers to the app, and `ggml-org/gpt-oss-20b-GGUF/gpt-oss-20b-MXFP4.gguf` resolves and is **ungated** (no `HF_TOKEN` needed). **On-device generation verified 2026-07-19** — first attempt failed with `Failed to create context`: llamadart defaults to `gpuLayers: 999`, so all layers went to the GPU, the 11.28GB of weights fit inside 11.66GB of free VRAM, and nothing was left for the KV cache or compute buffers. llama.cpp reports that as a context-creation failure *after* a successful model load, which reads like a corrupt download. Fixed with a GPU-offload backoff ladder in `OnDeviceEngine._ensureLoaded` (`app/lib/on_device_engine.dart`) — it retries with progressively fewer offloaded layers, and small models still succeed on the first (full-offload) attempt unchanged.

### On-device GGUF verification (2026-07-19 – 2026-07-20, in progress)

Separate from the list above, which is scoped to the server/`transformers` path
— an entry there means "answered correctly via the Python backend", which is a
different claim from "loads and generates through llamadart on-device".

Run headless, no GUI and no server, from `app/`:

```
dart run tool/verify_on_device.dart --preflight   # cache status, downloads nothing
dart run tool/verify_on_device.dart --wave 0      # cached models only
```

`tool/verify_on_device.dart` drives the real `OnDeviceEngine` — the same code
path the app uses, including the GPU-offload ladder and the mmproj projector —
rather than a reimplementation that could drift. It parses the roster out of
`Multi-AI/multi_ai/models/*.pyx` so there is one source of truth, and flushes
results to `tool/.verify_results.json` after every model so a native crash
costs one result rather than the run. `--report` reprints the table without
re-running anything.

This was possible only because llamadart uses Dart **native assets/build
hooks** rather than a Flutter plugin, so `dart run` resolves the DLLs from
`app/.dart_tool/lib`. (Never run `dart pub get` in `app/` — the SDK-sourced
Flutter dep won't resolve and a partial `.dart_tool/` rewrite destroys that
state. Use `flutter pub get`.)

**A `pass` means the model loaded and generated coherent, non-echoing text —
not that it answered correctly.** Several roster models are base models that
ramble or emit `<think>` blocks; gating on answer content would measure model
quality instead of whether the stack works. The keyword check is recorded but
non-gating.

**Wave 0 — 4 of 4 passed** (already-cached models, zero downloads):

| Model | GB | GPU layers | First token | Gen | tok/s | Verdict | Reply |
|---|---|---|---|---|---|---|---|
| `gpt_oss_20b` | 12.11 | **12** | 40.9s | 198.5s | **0.1** | pass | `<\|channel\|>analysis<\|message\|>The user asks…` |
| `falcon2_11b_on_device` | 6.85 | 999 | 10.8s | 11.5s | 4.3 | pass | The capital city of France is Paris. |
| `gemma_4_e2b_on_device` | 3.11 | 999 | 7.2s | 7.9s | 25.1 | pass | The capital of France is Paris. |
| `gemma_3n_e2b_on_device` | 3.03 | 999 | 7.3s | 8.3s | 2.9 | pass | The capital of France is Paris. |
| Qwen2.5 0.5B (built-in) | 0.49 | 999 | 5.8s | 6.3s | 6.3 | pass | Paris is the capital city of France. |

(`gemma_4_e2b` and the pre-0.8.16 numbers aren't directly comparable — everything
above `gemma_4_e2b` was measured on llamadart 0.8.11 and would likely be faster
re-run today. Only Gemma 4 has been measured on `b9982`.)

The **GPU layers** column is the practical output of the exercise — it records
which rung of the `_gpuLayerLadder` each model needed. Three findings:

- **`falcon2_11b` full-offloads at 999.** 6.85GB fits comfortably beside its own
  runtime allocations in ~11.7GB, at a usable 4.3 tok/s. Since every remaining
  7–9B entry is 4.4–5.2GB at Q4_K_M, they should all full-offload too — this one
  zero-download data point de-risks that whole wave.
- **`gpt_oss_20b` passes but is not practically usable.** The ladder rescues it from
  the `Failed to create context` crash by dropping to 12 layers, but that means
  most of a 20B MoE runs on CPU: **0.1 tok/s**, 40.9s to first token, 198.5s for
  one short reply. "Working" and "usable" are different claims and this is the
  gap between them. Anything that makes it faster costs context or quality
  (smaller `contextSize` to buy back offload room, or a smaller quant).
- **The backend is Vulkan, not CUDA.** llamadart's prebuilt Windows bundle
  drives the RTX 5070 Ti through `ggml-vulkan.dll`. The VRAM arithmetic is
  unchanged, but the ladder is backing off *Vulkan* offload, and its allocator
  behaves differently under pressure than CUDA's.

**`gpt_oss_20b` leaks its harmony format into the reply.** The raw output begins
`<|channel|>analysis<|message|>…` — the app has no parser for GPT-OSS's channel
scaffolding, so a user would see that reasoning-channel markup verbatim in the
chat bubble. The harness strips `<|…|>` before judging, which is why it still
scores a pass; the *display* path has no such stripping. Unfiled — needs either
a harmony parser or a channel filter in `chat_screen.dart`, alongside the
existing `<think>`-stripping the server does.

**Falcon 7B Instruct on-device fixed and verified (2026-07-20).** It was
prefixing every reply with a wall of `<|im_start|>calculate` / `<|im_start|>while
loop` junk, then — mid-investigation — echoing the question back, leaking a
trailing `<|im_end|>`, and returning empty after the first turn. All of it was
one cause: `maddes8cht/tiiuae-falcon-7b-instruct-gguf` ships **no
`tokenizer.chat_template`**, so llama.cpp falls back to ChatML. Falcon-7B-Instruct
predates ChatML and was trained on a bare `User:`/`Assistant:` transcript; fed
`<|im_start|>` it has no `<|im_end|>` token to stop on and degenerates into
repeating `<|im_start|>assistant` forever.

The trap is that **`ModelParams.chatTemplate` does not fix this** — it is
silently ineffective on the path the app uses. `LlamaEngine.create()` renders its
prompt Dart-side in `ChatTemplateRenderer`, which reads `tokenizer.chat_template`
straight out of the GGUF metadata and never consults the model params.
(`llama_cpp_service`'s `applyChatTemplate` *does* honour them, but `create()`
doesn't go through it.) Setting it looks correct, analyzes clean, and changes
nothing.

The fix is a `_quirksBySource` table in `app/lib/on_device_engine.dart`: a
quirked model bypasses chat templating entirely and takes llamadart's low-level
`engine.generate(rawPrompt)` with the transcript built in Dart. Non-quirked
models take the original `create()` path untouched; both feed one shared
`Stream<String>`, so buffering, `onToken`, and cancellation are common.

Two things worth carrying forward to the next model that misbehaves like this:

- **Declaring a stop sequence does not keep its text out of the reply.**
  llama.cpp's decode loop `yield`s each token's bytes downstream *before* testing
  them against the stop list, and never retracts — so the text that triggered the
  stop is always already in the buffer. `OnDeviceEngine._trimStopMarker` strips a
  trailing match; this is independent of the templating question and applies to
  any model given stop sequences.
- **Dump the rendered prompt before theorising.** Four rounds of plausible
  fixes were aimed at the wrong layer because the prompt was assumed rather than
  inspected; one throwaway script printing the prompt and the raw bytes settled
  it immediately. `engine.chatTemplate(messages)` returns the exact string.

Verified end-to-end through `OnDeviceEngine` (not a reimplementation), three
turns with real history: `The capital of France is Paris.` →
`&lt;header&gt;&lt;/header&gt;` → a coherent follow-up. No markup, no echo, no
empties. Answer *quality* is the ceiling of a 4-bit 2023-era 7B — turn 3
confabulated — but the prompting stack is correct. Note this is the on-device
path only; the server/`transformers` `falcon_7b` entry above is unaffected.

**Gemma 3n on-device is text-only, and now says so (2026-07-19).**
`gemma_3n_e2b_on_device.pyx` advertised `"modality": "Text + Image + Audio"` while
having no `_GGUF_MMPROJ_SOURCE`, so the Models tab promised image and audio that
the attachment buttons correctly refused to offer — the file contradicted its own
`strengths` text. Corrected to `"Text"`. The model *is* multimodal and the
server-backed `gemma_3n_e2b` entry still delivers all three modalities; it's llama.cpp
that can't:

- No projector exists in any repo. `unsloth/gemma-3n-E2B-it-GGUF` ships 24 text
  quants and no mmproj; `ggml-org/gemma-3n-E2B-it-GGUF` — llama.cpp's own org —
  ships two text GGUFs. `lmstudio-community` names theirs `…-text-GGUF`.
- Gemma 3n uses MobileNet-V5 vision and a USM audio tower rather than Gemma 3's
  SigLIP, and is **absent** from llama.cpp's supported multimodal list.

**Gemma 4 E2B/E4B added as the on-device multimodal path.** Both are in
llama.cpp's vision *and* mixed-modality lists and ship "omni" GGUFs where one
projector covers image and audio. GGUF-only, no `_REPO_ID` sibling (same shape as
`gpt_oss_20b`). `gemma_4_e2b_on_device` text verified: full offload, **25.1 tok/s**.

**llamadart 0.8.11 → 0.8.16.** Lockfile-only bump (the existing `^0.8.11`
constraint already allowed it). Native runtime `b9829` → `b9982`. Text throughput
on Gemma 4 E2B went **2.5 → 25.1 tok/s, a 10x speedup**, from the release's
"improved llama.cpp batching defaults". 19/19 Dart tests and 66 pytest tests
still pass.

**On-device image/audio is blocked under `dart run` — root-caused, and probably
harness-only.** Both Gemma 4 probes fail with *"Multimodal support is unavailable
in this native runtime bundle (missing `mtmd_context_params_default`)"*. That
message is misleading; the chain is:

1. `mtmd.dll` is fine. A direct `DynamicLibrary.open` of it from `.dart_tool/lib`
   succeeds and resolves `mtmd_context_params_default`, `mtmd_init_from_file`,
   and `mtmd_support_audio`. It exports 97 `mtmd_*` symbols, including
   `mtmd_audio_preprocessor_gemma4a`.
2. `bindings.dart` is annotated `@ffi.DefaultAsset('package:llamadart/llamadart')`,
   so every binding resolves against **llamadart.dll** — which does not contain
   the `mtmd_*` symbols. The primary lookup therefore always fails and llamadart
   falls back to opening `mtmd.dll` itself.
3. That fallback searches only the bare filename plus `_backendModuleDirectory`.
   Under `dart run` the executable is `dart.exe` and the CWD is `app/`, so
   neither looks like a native bundle and the directory resolves to null —
   nothing finds `.dart_tool/lib`. Setting `LLAMADART_NATIVE_LIB_DIR` does not
   help.

**A `flutter run -d windows` build stages those DLLs next to the `.exe`, which
*should* satisfy the executable-directory branch — so multimodal may well work in
the real app. That is a hypothesis, not a result: it has not been tested, and
confirming it needs the GUI path this harness exists to avoid.** Until someone
checks, treat on-device image/audio as unverified for all four projector-bearing
entries (`gemma_4_e2b`, `gemma_4_e4b`, `gemma_3_4b`, and the Ministrals), not as
broken.

`OnDeviceEngine._buildMessage` previously dropped audio attachments silently —
it filtered to `AttachmentKind.image` only. Now fixed to emit
`LlamaAudioContent`, which was a prerequisite for any entry honestly declaring
`audio`.

Not yet run — waves 1-4, ~65GB of downloads (`--preflight` reports 5 of 25
cached):

- [ ] Wave 1 (~4GB, resumes existing `.part` files) — `gemma_3_4b` (also the
      first test of the mmproj/vision path), `deepseek_r1_distill_1_5b`, `gemma_1_2b`
- [ ] Wave 2 (~15GB, ≤4GB models) — includes `ministral_3_3b`, whose BF16
      projector comes from `mistralai`'s own repo rather than the `unsloth`
      mirror the other three use
- [ ] Wave 3 (~30GB, 7-9B) — expected to full-offload per the `falcon2_11b` result
- [ ] Wave 4 (~17GB, 12-14B) — `mistral_nemo_12b`, `ministral_3_14b`; the
      partial-offload candidates, expect `gpt_oss_20b`-like speeds

Removed (2026-07-17: all models previously marked "unavailable" were deleted from the project):

- [x] `deepseek_v3_2_speciale_7b` — deleted per request (the real model is a huge MoE, not 7B)
- [x] `falcon_40b` — deleted: ~22GB at 4-bit > 12GB VRAM. Its ~78GB weight cache at `~/.cache/huggingface/hub` was deleted too (2026-07-17)
- [x] `mixtral_8x7b` — deleted: ~47B MoE, same problem
- [x] `pixtral_12b` / `kimi_instant_edge` — deleted (multimodal-only / no public small checkpoint)

- [x] Fix `.gitignore` — excludes `venv/`, `__pycache__/`, `*.egg-info/`, `build/`, and the compiled `.pyd`/`.so` binaries (platform/version-specific, rebuilt per machine). The generated `.c` stays tracked as a build input.
- [x] Flesh out real model implementations end-to-end — all 25 remaining models call real Hugging Face checkpoints via `transformers` (see `_REPO_ID` in each model file) or run on-device via a `_GGUF_SOURCE`; unavailable stubs were deleted
- [x] Wire up the API layer so the Flutter frontend (`app/lib/chat_screen.dart`) talks to a real backend handler — see `multi_ai.server`
- [x] `models/__init__.pyx` cleaned up — it re-exports nothing; `multi_ai.server` imports each compiled model module by name (`importlib.import_module`), and `tests/test_imports.pyx` validates all of them the same way
- [ ] Add a download-progress / "downloading model…" indicator in the chat UI — right now a first-time chat request just blocks until the weights finish downloading
- [x] Compile the `.pyx` sources for real (Cython + MSVC/`gcc`) — the backend is now compiled-only: `pip install -e . --no-deps` builds every `.pyx` to a `.pyd`/`.so` and the runtime imports the compiled modules (no plain-Python-script path)
- [x] Persist chat history to disk (`%APPDATA%\multi_ai\chat_sessions.json` on Windows) — chats survive restarts until deleted via right-click → Delete on a sidebar chat (see `app/lib/chat_store.dart`)
- [x] First on-device inference proof of concept (Qwen2.5 0.5B via `llamadart`/llama.cpp, no server needed) — see `app/lib/on_device_engine.dart`
- [x] Configurable "thinking" status text (word/phrase groups inspired by other AI products' loaders — Classic, Dev Tools, Quirky, and a Transparency Log group), with a settings dialog to enable/disable each group or individual phrases — see `app/lib/thinking_words.dart`, `thinking_settings.dart`, `thinking_settings_dialog.dart`, `thinking_indicator.dart`, and the gear icon in the chat top bar
  - The Transparency Log phrases are templated (`{query}`/`{model}` placeholders filled via `fillThinkingTemplate()`) so they narrate the actual in-flight request — e.g. `Searching for "what's the capital of..."…` / `Assembling Qwen2.5 0.5B's response…` — instead of generic text; the settings dialog shows a generic filled-in preview since it has no live request to reference
  - Regression-tested: `late` fields whose initializer reads themselves (as the original phrase-picker did, to avoid repeating a phrase) don't throw — they silently corrupt the value — so `app/test/chat_screen_test.dart`'s "sending a message shows the thinking row without crashing" test drives an actual send to catch that class of bug
- [x] Expand on-device support to more/larger models with GGUF builds (mirroring the server's `_REPO_ID` roster) — 22 of the 24 server models now have an on-device `_GGUF_SOURCE` sibling (Q4_K_M). Skipped only where no clean llama.cpp GGUF exists: `gemma_3n_e2b`/`llama_3_2_3b` are duplicate stems already covered by `gemma_3n_e2b`/`llama_3_2_3b`; every other model has a sibling.
- [x] Surface **device fit** before download — every model card and detail page now carries a green/yellow/red badge saying whether this machine can run it, so an 8–14B entry can't quietly cost a multi-gigabyte download that ends in an OOM. See "Hardware fit ratings" above (`multi_ai/hardware.pyx`, `GET /api/device`, `app/lib/model_fit_badge.dart`)
- [ ] Add a model-download **progress** indicator to go with it — the size is now shown up front, but a first-time download still gives no feedback while it runs
- [ ] Decide if/how `multi_ai.server`'s model roster and the on-device roster should be unified (e.g. one config listing both a `_REPO_ID` for the server and a GGUF source for on-device, per model)

## Core + add-on architecture

The plugin contract (spec #3) and the `model_pool` capability under it now
exist — see "Add-on architecture" below. The rest of Core does not. Ordering
follows the spec's own sequential action items; #7 (tiering) is the remaining
unblocker.

### Add-on architecture (done)

Every tab is an `AddOn` registered at compile time in
[`app/lib/addons/registry.dart`](app/lib/addons/registry.dart) — Models, Chat,
Orchestration and Code all sit on the same contract, with no privileged
built-in. Adding a feature is one file plus one registry entry.

| Piece | Where |
|---|---|
| The contract — `AddOnManifest`, `AddOnSurface`, lifecycle, `HostCapability` | [`addons/addon.dart`](app/lib/addons/addon.dart) |
| The host — registry, lifecycle, enable/disable, capability gating | [`addons/addon_host.dart`](app/lib/addons/addon_host.dart) |
| The frame every add-on draws inside | [`app/lib/app_shell.dart`](app/lib/app_shell.dart) |
| The `model_pool` capability | [`app/lib/model_pool.dart`](app/lib/model_pool.dart) |

An add-on contributes three optional surfaces — a **sidebar panel**, a **main
pane**, and a **top-bar slot** — so selecting a tab now swaps the whole window,
not just the sidebar. It declares what it needs (`requires: [HostCapability.modelPool]`)
and the host hands over exactly that; reaching for an undeclared capability
throws and names the fix. An add-on whose capabilities this build can't supply
renders as a disabled tab with the reason, never a broken pane.

**`model_pool`** is the roster, its download state, and the single `generate()`
that decides between the two run paths (a `gguf` source goes to llama.cpp
in-process; everything else to the Python backend). That decision used to be
inline in the chat screen's send handler reading private state, which is why
nothing else could run a model. On-device calls are serialized behind a queue:
`OnDeviceEngine` keeps exactly one model resident and evicts on switch, so a
Model Council asking several GGUFs at once would otherwise thrash multi-gigabyte
loads against each other.

Two things worth knowing before extending this:

- **Add-ons cannot be installed after the app is.** Flutter ships as machine
  code with no interpreter, so there is no way to load a new `.dart` file at
  runtime. Add-ons are registered at compile time and have a *lifecycle* at
  runtime; new ones reach users through the Velopack updater. `onInstall`
  accordingly means first-run setup on this machine — it runs once, and again
  only when a release bumps that add-on's `schemaVersion`, like a migration.
  The genuinely downloadable half is data, not code: a JSON *preset* naming
  which models a Council uses and what the lead's prompt is. That's spec #1's
  manifest, still open below.
- **Nothing may await the filesystem on the startup path.** Real file IO never
  completes under `flutter_test`'s fake-async binding, so a host that awaited
  its state file before enabling add-ons hung every widget test forever (and
  would hold the first paint behind a disk round trip in production). The shell
  renders its chrome immediately and the pane catches up; tests inject
  `InMemoryAddOnStateStore` so they neither read nor write the developer's real
  `%APPDATA%`. Covered by [`app/test/addon_host_test.dart`](app/test/addon_host_test.dart).

Still open here: nothing calls `AddOnHost.setEnabled` yet — the persistence and
gating work, but there is no settings UI to turn a tab off.

### Antigravity: local OpenAI-compatible endpoint (done, experimental, Windows only)

`addons/antigravity/` serves `ModelPool` over loopback HTTP; see the README's
Antigravity section for scope. Antigravity has no supported custom-model hook, so
whether it can use this depends on a community proxy that is untested here.
Open: tool calling (needs a `llama-server --jinja` route like the Code tab's, since
`ModelPool.generate` has none), real token streaming, and cancelling on disconnect
for non-streamed requests.

### Orchestration: the Model Council (done)

The Orchestration tab is a real add-on now
([`app/lib/addons/orchestration/`](app/lib/addons/orchestration/)), not the
placeholder. Pick two or more **downloaded** models in the sidebar, crown one as
**lead**, ask a question: the non-lead members answer, and the lead reads every
answer and returns one consolidated reply.

Built directly on [`ModelPool.generate()`](app/lib/model_pool.dart), **no agent
framework**. The evaluated options (Genkit Dart, Agenix, dart_agent_core) all
assume an LLM provider client, so each would have needed a custom adapter for
this app's two local run paths before doing anything — and the council is
fan-out plus a synthesis prompt, not the tool-use / planning / delegation those
frameworks exist for.

(The Code tab *did* want a real agent loop, and did try `dart_agent_core`
first — but its `LLMClient` abstraction still only elicits tool calls by
prompting for a text tag, which turned out to be the actual problem, not
something an agent framework fixes. It now runs on `opencode` instead; see
"Code tab" above.)

Two **deliberation modes**, picked in the sidebar (the README previously left
these "to be decided"):

- **Parallel** — each member answers the raw question, seeing nobody else's.
- **Sequential** — each member answers in turn, seeing the answers already given.

Both **run members serially**, not concurrently — a deliberate call, not a
missing feature. On one GPU there's nothing to gain: the on-device engine keeps
one model resident and the Python backend evicts on model switch, so
"simultaneous" generations would just thrash the same hardware. "Parallel" is
the *semantic* distinction (independent answers), not a threading one.

Robustness the controller
([`orchestration_controller.dart`](app/lib/addons/orchestration/orchestration_controller.dart))
handles, all under test in
[`app/test/orchestration_controller_test.dart`](app/test/orchestration_controller_test.dart):
a member that fails to load doesn't sink the run (the lead synthesizes whoever
answered); if *everyone* fails, the run says so and never asks the lead to
synthesize nothing; Stop discards late-arriving answers via a run-generation
guard; deleting a selected model from the Models tab drops it from the council,
and deselecting the lead promotes another member.

Not done: the synthesizer prompt is a sensible built-in, not yet the preset's
`leadPrompt` field — that's the downloadable-manifest follow-on. Multi-round
deliberation (the spec's third mode) is also still open; parallel and sequential
ship.

### Partially complete

- [ ] **Model catalog audit** (spec #4/#8) — param counts and sizes are resolved for all 47 entries via `get_info()`, including the previously ambiguous ones (`gemma_1_2b`→2B, `gemma_2_2b`→2B, `falcon_3_3b`→3B, `gpt_oss_20b`→20B, `llama_3_8b`/`llama_3_1_8b`→8B). Still missing as *structured* fields: `quant_level` (only implicit in the GGUF filename/prose) and `architecture_type` (dense vs. MoE vs. Mamba-hybrid — matters because `falcon_mamba_7b`/`falcon_h1_1_5b` have different compute characteristics than a standard transformer).
- [x] **Naming convention fix** (spec action item #2) — done 2026-09-27: every stem now encodes family, version and size (`gemma_1_2b`, `gemma_2_2b`, `gemma_3_1b`, `gemma_3n_e2b`, `falcon_3_3b`, `falcon_h1_1_5b`, `llama_3_8b`, `llama_3_1_8b`, `gpt_oss_20b`).
- [ ] **Resource management** — `OnDeviceEngine._ensureLoaded` (`app/lib/on_device_engine.dart`) enforces one resident model and evicts on switch, which covers "which model is loaded". There is no RAM/VRAM *budget* — just single-tenancy.
- [ ] **Desktop vs. mobile catalog split** — models split by `_REPO_ID` (server, 4-bit GPU) vs. `_GGUF_SOURCE` (in-app), but that's a *where it runs* distinction, not the hardware-aware gating layer the spec describes. No `platform_support` field, no per-device labelling.
- [x] **Orchestration tab** — a working Model Council, see "Orchestration" above. Only the manifest-preset and multi-round pieces remain.
- [x] **Code tab** — a working local coding agent backed by `opencode` + `llama-server`, see "Code tab" above. Server-side (`_REPO_ID`) models are bridged through the backend's OpenAI route, including tool calling (not yet verified against a real model).
- [x] **Plugin/add-on interface contract** (spec #3) — landed; see "Add-on architecture" above. One capability so far (`model_pool`); `memory` is deliberately absent until the memory layer (spec #2) is built, and adding it is a new enum case plus a getter, not a redesign.

### Not started

- [ ] **`model_registry` SQLite table** (spec #5) — no SQLite anywhere in the project; model metadata lives in per-file `.pyx` dicts. Missing every gating column: `quant_level`, `architecture_type`, `min_ram_mb`, `recommended_ram_mb`, `platform_support`, `role_tags`. Since `get_info()` already holds most of the descriptive fields, populating it is largely a migration script.
- [ ] **Memory layer** (spec #2) — the four-table model (`raw_items`, `wiki_entries`, `outputs`, `memory_index`) doesn't exist. `app/lib/chat_store.dart` is a flat JSON file of chat sessions, not a queryable memory tier.
- [ ] **Device × model compatibility estimator** (spec #6) — no device-spec probing, no predicted tokens/sec, no thermal/battery estimate. Ship the heuristic v1 but keep the input/output contract swappable for a trained regression later.
- [ ] **Recommended / Possible but not ideal / Not Supported tiering** (spec #7) — every model appears in the dropdown regardless of device; a phone can currently select the 20B `gpt_oss_20b`. Overlaps with the existing "surface size/device-fit before download" TODO above — same problem, and the tiering layer is the real fix for it.
- [ ] **Skill manifest format** (spec #1) — no `skill.json`/JSON Schema, no paired `skill.md` front matter, no MD↔JSON sync, no drag-and-drop editor.
- [ ] **Agentic OS add-on** (all four levels) — no skill registry, no review/retry loop engine, no memory browser, no task view, no tab.
- [ ] **Orchestration routing logic** — model choice is a manual dropdown. Routing must consume the Core tiering so it never picks a model flagged Not Supported on the device.
- [ ] **Code add-on** — dedicated coding-assistant mode. Lightest lift of the three; introduces no new shared infrastructure.

### Catalog cleanup surfaced while auditing

- [x] Duplicate stems removed in the rename pass: `gemma_3n` (identical to `gemma3n`, now `gemma_3n_e2b`) and `llama3_2` (identical to `llama_3_2_3b`).
- [ ] `gemma_3n_e2b`'s `params` is `"E2B"` (effective-params notation) — won't parse into `model_registry.param_count INTEGER`, and it's the architecture case (MatFormer) the estimator most needs a real number for.

All model storage and distribution is Hugging Face repos (`_REPO_ID`/`_COLIBRI_REPO_ID` for server-side and Colibri weights, `_GGUF_SOURCE` for on-device GGUF) plus local device storage — there is no separate hosted backend for model files or metadata.
