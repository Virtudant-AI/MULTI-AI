# MULTI-AI — File Map

A hybrid **Python (Cython-compiled) backend** + **Flutter frontend** for running many
AI models locally, prioritising on-device inference. This document lists every
source file in the repo and what it does. For the *why* behind the architecture,
see [README.md](README.md).

- **Backend** lives in `Multi-AI/` — a stdlib HTTP server plus one declarative
  stub per model, all written in `.pyx` and compiled to native extension modules
  before they run (`.pyx` → committed `.c` → git-ignored `.pyd`/`.so`).
- **Frontend** lives in `app/` — a Flutter app (Windows/Android primary) with a
  tab-per-feature "add-on" architecture.
- Generated `.c` files sit beside every `.pyx` (committed, never hand-edited).
  Compiled `.pyd`/`.so`, `__pycache__/`, `*.egg-info/`, and `venv/` are build
  output / not documented here.

---

## Repo root — build & run tooling

| File | Purpose |
|---|---|
| [README.md](README.md) | The canonical project doc: goals, run instructions, backend/build model, release process, feature design notes, benchmarks, TODOs. |
| [map.md](map.md) | This file. |
| [pyproject.toml](pyproject.toml) | Build-system config for the compiled backend — `setuptools` + `wheel` only, **no Cython in the build path**. |
| [setup.py](setup.py) | Compiles every committed `.c` under `Multi-AI/` into a native extension module and registers the `multi_ai` package + `multi-ai-server` console script. Needs a C compiler, not Cython. |
| [backend_build.py](backend_build.py) | Shared discovery of the backend's source modules, imported by both `setup.py` and `scripts/regen_cython.py` so build and codegen can't drift. |
| [.gitignore](.gitignore) | Ignore rules (compiled binaries, `venv/`, build dirs, keystore, …). |
| [.idx/dev.nix](.idx/dev.nix) | Firebase Studio / Project IDX workspace definition (Python 3.11, pip, cython). |

### `scripts/`

| File | Purpose |
|---|---|
| [scripts/regen_cython.py](scripts/regen_cython.py) | **The one place Cython runs.** Regenerates the committed `.c` from each `.pyx` at a pinned Cython version. Run after editing any `.pyx`, then commit the `.c`. |
| [scripts/run-windows.ps1](scripts/run-windows.ps1) | Runs the Flutter app as a Windows desktop build, prepending `~/.cargo/bin` to PATH so `velopack_flutter`'s Rust build hook works regardless of when the terminal was opened. |
| [scripts/run-app.ps1](scripts/run-app.ps1) | Boots the `Pixel_9` Android emulator, waits for it to come online, then `flutter run`s onto it. |
| [scripts/restart-backend.ps1](scripts/restart-backend.ps1) | Kills whatever holds port 8000 and restarts `multi-ai-server` (process only — does not rebuild). |

### `installer/`

| File | Purpose |
|---|---|
| [installer/runtime/bootstrap.py](installer/runtime/bootstrap.py) | Backend entry point inside a packaged Windows build. Assembles `sys.path` in plain Python after startup (the embeddable interpreter ignores `PYTHONPATH`), reading `MULTI_AI_PATH`. |
| [installer/runtime/requirements.txt](installer/runtime/requirements.txt) | The chat-time dependency list (torch, transformers, …) pip-installed under `%LOCALAPPDATA%` on first launch of a packaged build. |

### `.github/workflows/`

| File | Purpose |
|---|---|
| [.github/workflows/backend-check.yml](.github/workflows/backend-check.yml) | CI gate: regenerates every `.c` and fails if the committed copy doesn't match its `.pyx` (the stale-`.c` bug that broke v1.0.1). |
| [.github/workflows/release.yml](.github/workflows/release.yml) | On tag push, builds the Windows (Velopack) and Android (signed APK) packages in parallel and attaches both to one draft GitHub release. |

---

## Backend — `Multi-AI/`

| File | Purpose |
|---|---|
| [Multi-AI/pyproject.toml](Multi-AI/pyproject.toml) | Package metadata + the heavy chat-time dependency set (torch, transformers, accelerate, bitsandbytes, …). |
| [Multi-AI/requirements.txt](Multi-AI/requirements.txt) | Flat pip requirements for a dev environment. |
| [Multi-AI/multi_ai/__init__.pyx](Multi-AI/multi_ai/__init__.pyx) | Package init (compiled like everything else). |
| [Multi-AI/multi_ai/server.pyx](Multi-AI/multi_ai/server.pyx) | **The backend.** Stdlib-only HTTP server: `/api/hello`, `/api/models`, `/api/chat`, `/api/device`, an OpenAI-compatible `/v1/models` + `/v1/chat/completions` (with tool calling via the model's chat template; SSE is faked from a whole reply), and per-model `cache`/`download`/`delete` routes. Lazily imports torch/transformers; resolves each model stub; runs the 4-bit-quantized generation pipeline; downloads Colibri weights and spawns/stops `coli serve`. |
| [Multi-AI/multi_ai/hardware.pyx](Multi-AI/multi_ai/hardware.pyx) | Machine sizing (RAM via stdlib, VRAM via lazily-imported torch) and per-model green/yellow/red/unknown fit ratings — separate formulas for `_REPO_ID` (VRAM, 4-bit), `_GGUF_SOURCE` (on-device, 3 regimes), and Colibri external models (RAM + disk). |

### `Multi-AI/multi_ai/models/` — one declarative stub per model

Each `*.pyx` is a tiny stub: a `get_info()` dict plus **one** module-level constant
saying how it runs:

- **`_REPO_ID`** — a Hugging Face checkpoint the **server** loads via `transformers` (4-bit quantized).
- **`_GGUF_SOURCE`** — an `hf://…/*.gguf` URI the **Flutter app** runs **on-device** via `llamadart`/llama.cpp; the server never touches it. Optional `_GGUF_MMPROJ_SOURCE` adds a vision projector.
- **`_EXTERNAL_ENDPOINT = "colibri"`** + `_COLIBRI_REPO_ID` — a large MoE model run as a separate `coli serve` process on port 8010.
- `_INPUT_MODALITIES` — declares image/audio support (surfaced as `input_modalities`).

Many models exist as a **pair**: a server file (`_REPO_ID`) and an `_on_device.pyx`
sibling (`_GGUF_SOURCE`) for the same weights.

| Family | Files |
|---|---|
| **Llama** | `llama_3_8b`, `llama_3_1_8b`(+`_on_device`), `llama_3_2_3b`, `llama_3_8b_on_device`, `llama_3_2_1b`(+`_on_device`), `llama_3_2_3b`(+`_on_device`) |
| **Gemma** | `gemma_1_2b`, `gemma_1_7b`, `gemma_2_2b`, `gemma_2_9b`, `gemma_2_27b`, `gemma_3_270m`, `gemma_3_1b`, `gemma_3_4b`, `gemma_3_12b`, `gemma_3_27b` (4B+ vision), `gemma_3n_e2b`, `gemma_3n_e4b`, `gemma_4_e2b`, `gemma_4_e4b`, `gemma_4_12b`, `gemma_4_26b_a4b`, `gemma_4_31b` — each with an `_on_device` sibling |
| **Gemma variants** | `codegemma_7b`, `medgemma_4b`, `medgemma_1_5_4b`, `medgemma_27b`, `medgemma_27b_text`, `txgemma_9b`, `txgemma_27b` (each +`_on_device`); `recurrentgemma_2b`, `recurrentgemma_9b` — server-only, llama.cpp has no Griffin support |
| **Falcon** | `falcon_7b`(+`_on_device`), `falcon2_11b`(+`_on_device`), `falcon_3_3b`(+`_on_device`), `falcon_h1_1_5b`(+`_on_device`), `falcon_mamba_7b`(+`_on_device`) |
| **Mistral / Ministral** | `mistral_7b`(+`_on_device`), `mistral_nemo_12b`(+`_on_device`), `ministral_3_3b`(+`_on_device`, vision), `ministral_3_8b`(+`_on_device`, vision), `ministral_3_14b`(+`_on_device`, vision) |
| **Qwen** | `qwen3_8b`(+`_on_device`), `qwen2_5_coder_7b`(+`_on_device`), `qwen2_5_coder_3b_on_device`, `qwen2_5_coder_1_5b_on_device` |
| **DeepSeek** | `deepseek_r1_distill_1_5b`(+`_on_device`), `deepseek_v4_flash_colibri` |
| **GPT-OSS** | `gpt_oss_20b` — GGUF-only (transformers path won't fit in RAM) |
| **Colibri MoE** (external `coli serve`) | `glm_5_2_colibri`, `inkling_colibri`, `kimi_k3_colibri`, `deepseek_v4_flash_colibri`, `olmoe_colibri` |
| **Framework stubs** (not chat models) | `pytorch.pyx`, `TensorFlow.pyx` — legacy dev stubs that just report a version |
| | `models/__init__.pyx` — package init |

### `Multi-AI/tests/`

| File | Purpose |
|---|---|
| [Multi-AI/tests/conftest.py](Multi-AI/tests/conftest.py) | Lets pytest collect the `.pyx` test files (loads them by path via `SourceFileLoader`, since pytest hard-codes a `.py` suffix check). |
| [Multi-AI/tests/test_imports.pyx](Multi-AI/tests/test_imports.pyx) | Every `models/*.pyx` compiles, imports, and declares `get_info()` + a run constant. |
| [Multi-AI/tests/test_model_roster.pyx](Multi-AI/tests/test_model_roster.pyx) | The model list matches `models/*.pyx` both internally and via the live `GET /api/models`. |
| [Multi-AI/tests/test_hardware_fit.pyx](Multi-AI/tests/test_hardware_fit.pyx) | Fit ratings behave against synthetic specs (12GB / 4GB / no-GPU), plus a monotonicity property. |
| [Multi-AI/tests/test_model_downloads.pyx](Multi-AI/tests/test_model_downloads.pyx) | Every declared `_REPO_ID`/`_GGUF_SOURCE`/`_COLIBRI_REPO_ID` resolves on the HF Hub (metadata only). |
| [Multi-AI/tests/test_generation_pipeline.pyx](Multi-AI/tests/test_generation_pipeline.pyx) | Drives `server.pyx`'s full generation pipeline against fake torch/transformers modules — every branch, no weights, no GPU. |

---

## Frontend — `app/`

| File | Purpose |
|---|---|
| [app/pubspec.yaml](app/pubspec.yaml) / [app/pubspec.lock](app/pubspec.lock) | Flutter package manifest + lockfile. |
| [app/analysis_options.yaml](app/analysis_options.yaml) | Dart lint config. |
| [app/.metadata](app/.metadata) / [app/README.md](app/README.md) | Flutter-generated project metadata / default readme. |

### `app/lib/` — entry point & app shell

| File | Purpose |
|---|---|
| [app/lib/main.dart](app/lib/main.dart) | `main()`. Handles Velopack install/update/uninstall lifecycle hooks, then runs `StartupGate`. |
| [app/lib/startup_gate.dart](app/lib/startup_gate.dart) | Between launch and the chat screen: no-op in dev; in a packaged build shows the first-launch ~2.5GB pip-install screen with live output. |
| [app/lib/chat_screen.dart](app/lib/chat_screen.dart) | Thin assembly: builds the shared `ModelPool`, registers add-ons, starts the `AddOnHost`, hands off to `AppShell`. |
| [app/lib/app_shell.dart](app/lib/app_shell.dart) | The frame every add-on draws inside — sidebar/tab bar, top bar, banners, active add-on's pane. |
| [app/lib/theme.dart](app/lib/theme.dart) | Shared dark palette and fit-badge colours. |

### `app/lib/` — backend & model plumbing

| File | Purpose |
|---|---|
| [app/lib/api_client.dart](app/lib/api_client.dart) | HTTP client for the Python backend (`/api/*`). Re-exports `chat_types.dart`. Web-safe (no `dart:io`). |
| [app/lib/chat_types.dart](app/lib/chat_types.dart) | Flutter-free value types (`Attachment`, `ChatTurn`, `ModelInfo`, …) shared by the HTTP client and the on-device engine so the latter stays `dart run`-able. |
| [app/lib/backend_process.dart](app/lib/backend_process.dart) | Locate / provision / start / stop the bundled Python backend in a packaged Windows build. Adopts an already-running server on port 8000. |
| [app/lib/model_pool.dart](app/lib/model_pool.dart) | The `model_pool` host capability: the roster, download/cache/delete, and `generate()` routing (server vs on-device). Falls back to the bundled roster asset on Android / unreachable backend. |
| [app/lib/on_device_engine.dart](app/lib/on_device_engine.dart) | Runs one resident GGUF model in-process via `llamadart`/llama.cpp, incl. the GPU-offload ladder and multimodal projector. Flutter-free. |
| [app/lib/update_service.dart](app/lib/update_service.dart) | Checks for / downloads / applies Velopack app updates (silent, non-nagging). |
| [app/lib/download_foreground_service.dart](app/lib/download_foreground_service.dart) | Android-only platform channel keeping a model download alive while the app is backgrounded. No-op elsewhere. |

### `app/lib/` — device capability probes (conditional imports for web-safety)

| File | Purpose |
|---|---|
| [app/lib/platform_check.dart](app/lib/platform_check.dart) / [_io](app/lib/platform_check_io.dart) / [_stub](app/lib/platform_check_stub.dart) | Real OS-level "is this genuinely Android" — not `defaultTargetPlatform`, which `flutter_test` overrides. |
| [app/lib/device_ram.dart](app/lib/device_ram.dart) / [_io](app/lib/device_ram_io.dart) / [_stub](app/lib/device_ram_stub.dart) | Total physical RAM, or null — used by `device_fit.dart` when there's no backend to ask. |
| [app/lib/device_fit.dart](app/lib/device_fit.dart) | Client-side RAM-only port of `hardware.pyx`'s on-device rating, for Android / unreachable-backend. |

### `app/lib/` — chat UI pieces

| File | Purpose |
|---|---|
| [app/lib/attachment_input.dart](app/lib/attachment_input.dart) | Image picker + audio recorder for the chat input, behind an interface so widget tests can fake it. |
| [app/lib/chat_store.dart](app/lib/chat_store.dart) | Persists chat history (via `path_provider`'s app-support dir). Exposes the shared `appDataFile` helper used across the app. `ChatMessage` type. |
| [app/lib/markdown_text.dart](app/lib/markdown_text.dart) | Renders model replies as markdown; `openExternalUrl` helper. |
| [app/lib/copy_button.dart](app/lib/copy_button.dart) | Self-contained "Copy" affordance for any AI response block. |
| [app/lib/thinking_words.dart](app/lib/thinking_words.dart) | The phrase sets shown in the "thinking" row, grouped by the AI product that inspired them. |
| [app/lib/thinking_settings.dart](app/lib/thinking_settings.dart) | Persisted enable/disable state for thinking-phrase groups. |
| [app/lib/thinking_settings_dialog.dart](app/lib/thinking_settings_dialog.dart) | The settings dialog for the above. |
| [app/lib/thinking_indicator.dart](app/lib/thinking_indicator.dart) | The rotating status text widget itself (timed fade; `{query}`/`{model}` templating). |
| [app/lib/storage_settings_dialog.dart](app/lib/storage_settings_dialog.dart) | Pre-set choice for whether the downloaded runtime is removed on uninstall (Velopack uninstall hooks allow no UI). |

### `app/lib/` — models tab pieces

| File | Purpose |
|---|---|
| [app/lib/model_detail_screen.dart](app/lib/model_detail_screen.dart) | Full-page breakdown of one model + its download/delete flow. |
| [app/lib/model_fit_badge.dart](app/lib/model_fit_badge.dart) | The coloured fit badge + its explanatory text. |
| [app/lib/code_tool_support.dart](app/lib/code_tool_support.dart) | Per-model table of whether the Code tab's tools work with it (tested / inferred), shown on the detail page. Evidence in CODE-TAB-MODELS.md. |

### `app/lib/addons/` — the tab-per-feature architecture

| File | Purpose |
|---|---|
| [app/lib/addons/addon.dart](app/lib/addons/addon.dart) | The `AddOn` base class, `AddOnManifest`, `AddOnContext`, and `HostCapability` enum. |
| [app/lib/addons/addon_host.dart](app/lib/addons/addon_host.dart) | Owns the add-on lifecycle: which can run (capabilities satisfied), builds their UI, persists per-add-on state (`AddOnStateStore`). |
| [app/lib/addons/registry.dart](app/lib/addons/registry.dart) | `buildRegistry()` — the one list of every add-on this build ships, with injected dependencies. |

#### `addons/chat/` — the Chat tab

| File | Purpose |
|---|---|
| [chat_addon.dart](app/lib/addons/chat/chat_addon.dart) | The Chat tab UI: transcript, input, attachments, model picker, web-search toggle. |
| [chat_controller.dart](app/lib/addons/chat/chat_controller.dart) | Chat turn logic — history trimming, routing to server/on-device, web grounding, thinking state. |
| [web_grounding.dart](app/lib/addons/chat/web_grounding.dart) | One deterministic retrieval pass per turn (search or YouTube transcript) → sources + a context block prepended to the prompt. |
| [web_search_client.dart](app/lib/addons/chat/web_search_client.dart) | Queries the bundled local SearXNG instance's JSON API. Honest User-Agent constant. |
| [web_page_fetcher.dart](app/lib/addons/chat/web_page_fetcher.dart) | Fetches a result page and reduces it to ≤4000 chars of plain text (2MB cap, no robots.txt in v1). |
| [youtube_transcript_fetcher.dart](app/lib/addons/chat/youtube_transcript_fetcher.dart) | Pulls a video transcript + metadata via the yt-dlp component (one-shot subprocess). |
| [web_source.dart](app/lib/addons/chat/web_source.dart) | `WebSource` — one citation attached to a `ChatMessage`. |
| [web_access_settings.dart](app/lib/addons/chat/web_access_settings.dart) | Persists only whether the one-time explainer has been seen; the toggle itself resets to off each launch. |
| [web_access_explainer_dialog.dart](app/lib/addons/chat/web_access_explainer_dialog.dart) | The one-time "what leaves your device" consent dialog. |

#### `addons/models/` — the Models tab

| File | Purpose |
|---|---|
| [models_addon.dart](app/lib/addons/models/models_addon.dart) | Browses the roster — size, fit rating, download/delete via each model's detail page. |

#### `addons/orchestration/` — the Model Council tab

| File | Purpose |
|---|---|
| [orchestration_addon.dart](app/lib/addons/orchestration/orchestration_addon.dart) | UI: pick members, name a lead, ask a question, see each answer + the synthesis. |
| [orchestration_controller.dart](app/lib/addons/orchestration/orchestration_controller.dart) | Runs the council — parallel or sequential member answers, then lead synthesis (`DeliberationMode`). |
| [orchestration_store.dart](app/lib/addons/orchestration/orchestration_store.dart) | Persists past council runs (`File…` real impl, `InMemory…` for tests). |

#### `addons/antigravity/` — the Antigravity tab (local OpenAI-compatible endpoint, Windows only)

| File | Purpose |
|---|---|
| [antigravity_addon.dart](app/lib/addons/antigravity/antigravity_addon.dart) | The tab (Windows only; other platforms get an "unavailable" pane). |
| [antigravity_controller.dart](app/lib/addons/antigravity/antigravity_controller.dart) | Server state, settings, request log; starts/stops the server. |
| [local_model_server.dart](app/lib/addons/antigravity/local_model_server.dart) | The loopback `HttpServer`: `/v1/models`, `/v1/chat/completions` (SSE faked from a whole reply), bearer-token auth, Origin/Host checks, body cap. |
| [antigravity_settings.dart](app/lib/addons/antigravity/antigravity_settings.dart) | Port, default model, auto-start and key, in `antigravity_settings.json`. |
| [antigravity_main_pane.dart](app/lib/addons/antigravity/antigravity_main_pane.dart) | The tab UI. |

#### `addons/code/` — the Code tab (local coding agent via opencode + llama-server)

| File | Purpose |
|---|---|
| [code_addon.dart](app/lib/addons/code/code_addon.dart) | The tab (desktop only; Android gets a hard "not available" pane). |
| [code_agent_controller.dart](app/lib/addons/code/code_agent_controller.dart) | Drives one turn: `ensureRunning()`, create/continue an opencode session, stream events, transcript entries, tool-approval routing. |
| [code_agent_pane.dart](app/lib/addons/code/code_agent_pane.dart) | The tab UI — transcript, collapsible tool-call rows (icon per opencode tool), approval dialog. |
| [code_engine.dart](app/lib/addons/code/code_engine.dart) | `CodeEngine` interface + `LocalCodeEngine` — composes the two supervisors behind one `ensureRunning({model})`, and exposes `isInstalled()` / `install()` for the Install card. Abstract for testability. |
| [code_engine_installer.dart](app/lib/addons/code/code_engine_installer.dart) | One-click install of `llama-server` + `opencode` (Windows x64): pinned releases, SHA-256 verified, unpacked into the app data folder. `CodeEngineTool`, the pins, and where they live. |
| [code_engine_locator.dart](app/lib/addons/code/code_engine_locator.dart) | Finds those two programs: the app's own install, then `PATH`, then WinGet / npm / `~/.opencode` locations that never reach `PATH`. |
| [llama_server_supervisor.dart](app/lib/addons/code/llama_server_supervisor.dart) | Owns the `llama-server` child process (port **8100**) serving the selected GGUF model over an OpenAI-compatible API with `--jinja`. Restarts only when the model changes. |
| [opencode_process_supervisor.dart](app/lib/addons/code/opencode_process_supervisor.dart) | Owns the single `opencode serve` process (port **8101**), started once lazily and kept for the app's life; hosts all project dirs via a `directory` query param. Writes opencode's config pointing at llama-server, plus a second provider for the Python backend's server models (restarts if asked for one it didn't register). |
| [opencode_client.dart](app/lib/addons/code/opencode_client.dart) | HTTP/SSE client for opencode — `POST /session`, `/session/:id/prompt_async`, the shared `/event` stream, `/permission/:id/reply`. `OpencodeEvent.tryParse` narrows the 80+ event types to the few acted on. |
| [code_session_store.dart](app/lib/addons/code/code_session_store.dart) | Persists one conversation: display transcript + the opencode session id (so reopening actually continues it) + last project/model. |
| [project_root_source.dart](app/lib/addons/code/project_root_source.dart) | Directory picker for the project folder, behind an interface (real picker blocks under `flutter test`). |
| [tool_approval.dart](app/lib/addons/code/tool_approval.dart) | `ToolApprovalRequest` / `ToolApprovalDecision` (allow once / allow for session / deny) — the gate for `edit`/`bash`. |
| [tool_approval_dialog.dart](app/lib/addons/code/tool_approval_dialog.dart) | The approval dialog widget. |

> Note: `agent_llm_client.dart` / `agent_tools.dart` and their tests are the
> **removed** hand-rolled agent loop (replaced by opencode); they may still
> appear as deletions in `git status`.

#### `addons/components/` — the Add-ons tab (local services a feature depends on)

| File | Purpose |
|---|---|
| [component.dart](app/lib/addons/components/component.dart) | `LocalComponent` + `ComponentKind` (`server` = supervised long-running process e.g. SearXNG; `tool` = one-shot subprocess e.g. yt-dlp). The catalog. |
| [component_manager.dart](app/lib/addons/components/component_manager.dart) | The Models-tab equivalent for components: what's installed/running, install/delete/run. Shared between the Add-ons tab and Chat. |
| [component_runtime.dart](app/lib/addons/components/component_runtime.dart) | Where one component's files live on disk and how they get there — an isolated per-component site-packages, borrowing the bundled interpreter. |
| [components_addon.dart](app/lib/addons/components/components_addon.dart) | The Add-ons tab UI (install/delete cards). |
| [component_detail_screen.dart](app/lib/addons/components/component_detail_screen.dart) | Full-page install/delete flow for one component. |
| [searxng_supervisor.dart](app/lib/addons/components/searxng_supervisor.dart) | Owns the SearXNG child process (port **8891**). Header comment is the canonical port registry (8000 backend, 8010 Colibri, 8891 SearXNG, 8100/8101 Code tab). |

### `app/assets/`

| File | Purpose |
|---|---|
| [app/assets/on_device_roster.json](app/assets/on_device_roster.json) | Bundled model roster (all `_GGUF_SOURCE` entries) so Android has a roster with no backend. Regenerated by `tool/generate_on_device_roster.dart`. |
| [app/assets/components/searxng_install.py](app/assets/components/searxng_install.py) | Installs SearXNG under the embeddable interpreter (works around its sdist-only, no-wheel packaging + `._pth` PYTHONPATH trap). |
| [app/assets/components/searxng_bootstrap.py](app/assets/components/searxng_bootstrap.py) | Entry point that starts SearXNG under the packaged build (path-extension trick + `SEARXNG_SETTINGS_PATH`). |
| [app/assets/components/searxng_settings.yml.tmpl](app/assets/components/searxng_settings.yml.tmpl) | Template for the SearXNG `settings.yml` the app generates. |
| [app/assets/components/searxng_requirements.txt](app/assets/components/searxng_requirements.txt) | SearXNG's pinned dependency set. |
| [app/assets/components/run_tool_bootstrap.py](app/assets/components/run_tool_bootstrap.py) | Generic `python -m <module> args…` entry point for `ComponentKind.tool` components (yt-dlp today). |
| [app/assets/components/yt_dlp_requirements.txt](app/assets/components/yt_dlp_requirements.txt) | yt-dlp's dependency set. |

### `app/tool/` — build-time `dart run` scripts (not part of the app)

| File | Purpose |
|---|---|
| [app/tool/generate_on_device_roster.dart](app/tool/generate_on_device_roster.dart) | Parses every `_GGUF_SOURCE` from `Multi-AI/multi_ai/models/*.pyx` → `app/assets/on_device_roster.json`. Run before any Android build. |
| [app/tool/verify_on_device.dart](app/tool/verify_on_device.dart) | Headless smoke test: loads each GGUF roster entry through the real `OnDeviceEngine` and asks it one question. |

### `app/test/`

| File | Covers |
|---|---|
| [addon_host_test.dart](app/test/addon_host_test.dart) | Add-on lifecycle / capability gating / state persistence. |
| [chat_controller_test.dart](app/test/chat_controller_test.dart) | Chat turn logic, history trimming, routing. |
| [chat_screen_test.dart](app/test/chat_screen_test.dart) | Chat screen widget assembly. |
| [chat_store_test.dart](app/test/chat_store_test.dart) | History persistence. |
| [local_model_server_test.dart](app/test/local_model_server_test.dart) | Antigravity endpoint: auth, hardening, completions, SSE, disconnect. |
| [antigravity_controller_test.dart](app/test/antigravity_controller_test.dart) | Antigravity tab controller against a fake pool. |
| [antigravity_settings_test.dart](app/test/antigravity_settings_test.dart) | Antigravity settings + token. |
| [code_addon_test.dart](app/test/code_addon_test.dart) | Code tab add-on. |
| [code_agent_controller_test.dart](app/test/code_agent_controller_test.dart) | Code agent turn logic against a fake `CodeEngine`. |
| [code_session_store_test.dart](app/test/code_session_store_test.dart) | Code conversation persistence. |
| [opencode_client_test.dart](app/test/opencode_client_test.dart) | opencode HTTP/SSE client + event parsing. |
| [code_model_warning_test.dart](app/test/code_model_warning_test.dart) | The Code tab picker's warning dialog: silent for working/uncertain/unknown models, confirm-or-cancel for an incompatible one, not repeated after "Use anyway". |
| [code_tool_support_test.dart](app/test/code_tool_support_test.dart) | The Code-tab verdict table: every model file has an entry, ids resolve across `_on_device` siblings, and the detail page renders the verdict. |
| [code_engine_installer_test.dart](app/test/code_engine_installer_test.dart) | The installer against a fake HTTP client: checksum mismatch, HTTP errors, missing exe, antivirus-deleted exe, already-installed. |
| [code_engine_locator_test.dart](app/test/code_engine_locator_test.dart) | Lookup order and the WinGet / npm / `~/.opencode` locations. |
| [code_engine_card_test.dart](app/test/code_engine_card_test.dart) | The controller's engine-ready / install flow and the pane's Install card. |
| [real_code_run_test.dart](app/test/real_code_run_test.dart) | Skipped by default. A real `llama-server` + `opencode` run of the Code tab; `MULTI_AI_REAL_INSTALL=1` also does a real install from GitHub. |
| [code_engine_test.dart](app/test/code_engine_test.dart) | `LocalCodeEngine`'s on-device vs. server-model routing (provider/model ids, llama-server skipped, backend errors). |
| [model_pool_download_test.dart](app/test/model_pool_download_test.dart) | Roster / download / cache logic. |
| [orchestration_controller_test.dart](app/test/orchestration_controller_test.dart) | Council deliberation modes. |
| [orchestration_store_test.dart](app/test/orchestration_store_test.dart) | Council run persistence. |
| [widget_test.dart](app/test/widget_test.dart) | Default smoke test. |

> `agent_llm_client_test.dart` / `agent_tools_test.dart` are deletions from the
> removed agent loop.

### Platform folders (Flutter-generated, edited only where noted)

- `app/android/` — Gradle project. Hand-edited: `app/build.gradle.kts` (keystore signing), `AndroidManifest.xml` (INTERNET / RECORD_AUDIO), `network_security_config.xml`, `MainActivity.kt` (RAM read + download-service channel), `DownloadForegroundService.kt`.
- `app/ios/` — Xcode project (iOS is **not** a target; present but unmaintained).
- `app/windows/`, `app/linux/`, `app/macos/` — desktop runners (Windows is the maintained desktop target).
- `app/web/` — web bootstrap (`index.html`, `manifest.json`, icons); the app is largely web-safe but web is not a shipping target.
