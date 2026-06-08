# AGENTS.md — Magenta RealTime AUv3 Plugin Template

Guide for AI agents and developers bootstrapping new **Magenta RealTime** AUv3 plugins from [audiohacking/magenta-au-template](https://github.com/audiohacking/magenta-au-template).

---

## 1. What this repository is

**magenta-au-template** is a reusable scaffold — not a shipping product. It encodes everything repeated across AudioHacking Magenta plugins:

| Concern | Where it lives |
|---------|----------------|
| AU processor + MIDI/render loop | `MagentaAU_AudioUnit.mm` |
| WKWebView UI bridge + model IPC | `MagentaAU_ViewController.mm` |
| Shared MIDI/audio levels | `MagentaAU_SharedState.h` |
| Host app for `pluginkit` registration | `MagentaAU_HostApp.mm` |
| React UI (Jam example + overlay) | `magenta-realtime/examples/jam/ui` + `ui-patches/` |
| MLX inference | `magenta-realtime/core` + `core-patches/` |
| Build / deploy / CI / release | `CMakeLists.txt`, `.github/`, `scripts/` |

**Reference plugins (read-only — do not modify when working on a fork):**

| Repo | Use when |
|------|----------|
| [jam-au3](https://github.com/audiohacking/jam-au3) | Instrument-only, simpler UI — **primary reference** |
| [mrt2-au3](https://github.com/audiohacking/mrt2-au3) | FX mode, sidechain, extended params |
| [magenta-realtime](https://github.com/magenta/magenta-realtime) | Upstream engine + example apps |

---

## 2. Repository layout

```
magenta-au-template/
├── CMakeLists.txt                 # Build targets (see §5)
├── package.json                   # npm workspaces: jam-ui + @magenta-rt/common
├── .gitmodules                    # magenta-realtime submodule
│
├── MagentaAU_AudioUnit.h/.mm      # AUAudioUnit processor
├── MagentaAU_ViewController.mm    # AUViewController + WKWebView bridge
├── MagentaAU_SharedState.h        # MIDI note + audio level shared state
├── MagentaAU_HostApp.mm           # Minimal host app
│
├── Info.plist.in                  # AU extension — subtype MGTP, mfg AHck
├── HostInfo.plist.in              # Host app plist
├── Entitlements.plist             # Sandbox entitlements for .appex
│
├── core-patches/                  # Overlay onto magenta-realtime/core at configure time
│   └── core/src/realtime_runner.cpp   # Bounce-safe ring-buffer drain
│   └── core/include/magentart/mlx_gpu_guard.h  # Process-wide MLX GPU mutex
├── ui-patches/App.tsx             # Optional React UI overlay (copied at configure time)
│
├── assets/AppIcon.icns
├── scripts/
│   ├── bootstrap-plugin.sh        # Rename template → your plugin
│   ├── build-installer-pkg.sh     # .pkg + .dmg release artefacts
│   ├── ci-reclaim-disk.sh         # CI disk cleanup after package_magenta_au
│   └── pkg-postinstall            # pluginkit registration
├── .github/workflows/             # build.yml + release.yml
└── AGENTS.md                      # This file
```

**Submodule (required):**

```
magenta-realtime/
├── core/                          # magentart::core — RealtimeRunner, MLX
├── examples/common/               # magenta_paths, MagentaModelManager, MagentaSettings
└── examples/jam/ui/               # React UI → bundled as Resources/jam_ui/
```

---

## 3. Bootstrapping a new plugin

### Option A — GitHub template

1. **Use this template** on GitHub → create `your-org/your-plugin-au3`.
2. Clone with submodules:
   ```bash
   git clone --recurse-submodules https://github.com/your-org/your-plugin-au3.git
   cd your-plugin-au3
   ```
3. Run the bootstrap script:
   ```bash
   chmod +x scripts/bootstrap-plugin.sh
   ./scripts/bootstrap-plugin.sh \
     --name "My Plugin" \
     --slug my-plugin-au3 \
     --prefix MYPL \
     --state-prefix MYPL_ \
     --bundle-id com.example.myplugin \
     --dev-port 62423
   ```
4. Manually review `Info.plist.in` (component name, description, tags).
5. Optionally rename `MagentaAU_*` files and update `CMakeLists.txt` target names.

### Option B — Manual rename checklist

| Item | Template default | Change to |
|------|------------------|-----------|
| AU subtype (4 chars) | `MGTP` | Unique per plugin — register with Apple if shipping |
| Manufacturer | `AHck` | Usually keep for AudioHacking |
| Host app name | `Magenta AU Template (AU).app` | `Your Plugin (AU).app` |
| Appex bundle ID | `com.audiohacking.magenta.template.au` | `com.yourco.yourplugin.au` |
| Host bundle ID | `...template.au.host` | `...yourplugin.au.host` |
| State keys | `MGTAU_*` | `YOURPREFIX_*` |
| NSUserDefaults prefix | `MGTAU` in MagentaSettings | Your prefix |
| Dev HMR port | `62422` | Unique per plugin (avoid 62420=mrt2, 62421=jam) |
| CMake targets | `magenta_au`, `finalize_magenta_au`, … | Rename consistently |
| Release artefacts | `Magenta-AU-Template-*` | `Your-Plugin-*` |

**Validate after rename:**

```bash
auvaltool -v aumu YOUR_SUBTYPE AHck
pluginkit -m -v -i com.yourco.yourplugin.au
```

---

## 4. Two-bundle AUv3 pattern

```
Magenta AU Template (AU).app/           # Host — open once to register
└── Contents/PlugIns/
    └── MagentaAU_AU.appex/             # Actual AUv3 extension
        └── Contents/
            ├── MacOS/MagentaAU_AU      # Entry: -e _NSExtensionMain
            ├── MacOS/mlx.metallib       # MLX Metal kernels (codesigned separately)
            └── Resources/jam_ui/        # Vite production bundle
```

This pattern is required for sandboxed AUv3 on macOS. The host app exists solely to embed and register the `.appex`.

---

## 5. CMake target chain

| Target | Purpose |
|--------|---------|
| `npm_install_root` | `npm install` at repo root |
| `build_template_ui` | `npm run build --workspace=jam-ui` |
| `magenta_au` | Extension executable → `MagentaAU_AU.appex` |
| `magenta_au_app` | Host app |
| `finalize_magenta_au` | Embed appex + UI + metallib; codesign |
| `deploy_magenta_au` | Copy to `~/Applications`, `pluginkit -a` |
| `package_magenta_au` | Stage `build/dist/` for release |
| `notarize_magenta_au` | Notarize (requires Developer ID) |

---

## 6. Audio component registration

From `Info.plist.in` (must match fallback in `MagentaAU_AudioUnit.mm`):

| Field | Template value |
|-------|----------------|
| type | `aumu` (Instrument) |
| subtype | `MGTP` |
| manufacturer | `AHck` |
| name | `AudioHacking: Magenta AU Template` |
| factoryFunction | `MagentaAUViewController` |
| bundle ID | `com.audiohacking.magenta.template.au` |

For **FX plugins**, change `type` to `aufx` and study [mrt2-au3](https://github.com/audiohacking/mrt2-au3) (`SidechainReferenceCapture.h`, audio input buses, params 49–50). The template defaults to instrument-only (Jam pattern).

---

## 7. Class responsibilities

### `MagentaAUAudioUnit` (`MagentaAU_AudioUnit.mm`)

- Subclasses `AUAudioUnit`, owns `RealtimeRunner _engine`
- **Instrument mode**: stereo output @ 48 kHz, no audio input buses
- AU parameter tree addresses 0–48 (shared engine params with Jam/MRT2)
- Solo-mode gate + cfg-notes ramp in `internalRenderBlock`
- MIDI from host via `AURenderEventMIDI` → `_sharedState.midiNotes`
- DAW transport via cached `transportStateBlock`
- State keys prefixed `MGTAU_*`: `MGTAU_Prompt`, `MGTAU_ModelName`, `MGTAU_ModelBookmark`, etc.
- Default auto-load model: `mrt2_small`
- Model path resolution: `~/Documents/Magenta/magenta-rt-v2/models` + security-scoped bookmarks

### `MagentaAUViewController` (`MagentaAU_ViewController.mm`)

- Subclasses `AUViewController`, implements `AUAudioUnitFactory`
- Hosts React UI in `WKWebView`
- Dev server: port **62422**; production: `Resources/jam_ui/index.html`
- Injected at document start: `window.__HOST_MODE__ = 'auv3'`

### UI ↔ Native bridge

**Native → JS:** `window.updateState({...})` at ~25 Hz

**JS → Native:** `window.webkit.messageHandlers.auHost.postMessage({type, ...})`

Key message types: `param`, `textPrompts`, `setSoloMode`, `loadModel`, `selectModel`, `downloadModel`, `initResources`, `loadAudioPromptData`, `kbdNote`, `togglePlay`, `uiReady`

Customize UI via `ui-patches/App.tsx` (copied over upstream `App.tsx` at CMake configure time).

---

## 8. Core patches (required for production)

The template applies `core-patches/` onto `magenta-realtime/core` at **configure time** (not a submodule fork):

1. **`mlx_gpu_guard.h`** — Process-wide mutex around MLX GPU ops. Required for multiple AU instances on separate tracks. Inside `magentart::core`, reference as `::magentart::detail::MlxGpuGuard`.

2. **`realtime_runner.cpp`** — Deferred ring-buffer drain during offline/bounce render. Prevents Logic bounce crashes.

If upstream merges these fixes, the overlay can be removed. Until then, keep `core-patches/` in every AudioHacking AU plugin.

---

## 9. Build commands

### First-time / clean build

```bash
git submodule update --init --recursive
uv venv --python 3.12 && source .venv/bin/activate
uv pip install "cmake<3.28"
npm install
cmake . -B build
cmake --build build --target deploy_magenta_au -j$(sysctl -n hw.ncpu)
```

First build fetches MLX + TensorFlow Lite via CMake FetchContent — expect 30–90+ minutes on a clean machine.

### UI development with HMR

Terminal 1:
```bash
npm run dev --workspace=jam-ui   # localhost:62422
```

Terminal 2:
```bash
cmake --build build --target finalize_magenta_au -j10
# Re-insert plugin in DAW or restart host
```

### Release staging

```bash
cmake --build build --target package_magenta_au
# Output: build/dist/Magenta AU Template (AU).app
./scripts/build-installer-pkg.sh --sign-app
# Output: release-artifacts/Magenta-AU-Template-*.{pkg,dmg}
```

### Codesigning / notarization

- Set `MAGENTART_DEVELOPER_ID` to your Developer ID Application identity
- Configure `notarytool-creds` keychain profile
- Run `cmake --build build --target notarize_magenta_au`

---

## 10. External runtime dependencies (not bundled)

| Resource | Default path |
|----------|--------------|
| Models | `~/Documents/Magenta/magenta-rt-v2/models/` |
| Shared resources | `~/Documents/Magenta/magenta-rt-v2/resources/` |

Models are **not** shipped in the app bundle. UI onboarding (`initResources`) downloads via `MagentaModelDownloader`.

---

## 11. FetchContent pins (CMake)

Identical across AudioHacking Magenta plugins:

- **MLX** `v0.31.1`
- **sentencepiece** `v0.2.0`
- **tensorflow-lite** `v2.21.0`

Includes MLX `make_compiled_preamble.sh` patch for CMake 3.27 compatibility.

---

## 12. CI and release

**`.github/workflows/build.yml`** (on push/PR to `main`):
1. Checkout + submodules
2. `setup-build` action (Node, ccache, uv, cmake, npm, UI build)
3. `cmake --build build --target finalize_magenta_au`

**`.github/workflows/release.yml`** (on GitHub Release publish or manual dispatch):
1. `package_magenta_au`
2. `ci-reclaim-disk.sh` (free disk on runner)
3. `build-installer-pkg.sh --sign-app`
4. Upload `.pkg` + `.dmg` to release assets

When forking, update ccache hash paths in `.github/actions/setup-build/action.yml` if you rename source files.

---

## 13. Extending to FX mode

The template ships as an **Instrument**. To add FX (audio effect) support:

1. Read `mrt2-au3` — `MagentaRT_AudioUnit.mm` for dual bus layout (sidechain input)
2. Add `SidechainReferenceCapture.h` (or equivalent) for reference audio upload
3. Change `Info.plist.in`: `type` → `aufx`, update tags
4. Extend parameter addresses (49–50 in mrt2) for sidechain mix
5. Update UI overlay for FX-specific controls

Keep instrument and FX as separate products or use compile-time flags — do not mix subtypes in one component.

---

## 14. Naming conventions

| Item | Template | jam-au3 | mrt2-au3 |
|------|----------|---------|----------|
| State prefix | `MGTAU_*` | `JAM_*` | `MGRT_*` |
| AU subtype | `MGTP` | `JAM3` | `MRT2` |
| Dev port | 62422 | 62421 | 62420 |
| UI resource dir | `jam_ui/` | `jam_ui/` | `ui/` |
| CMake prefix | `magenta_au` | `jam_au` | `mrt2_au` |

Do not mix prefixes within one plugin — state keys must stay consistent across processor, view controller, and UI.

---

## 15. Submodule updates

```bash
cd magenta-realtime
git fetch origin && git checkout main && git pull
cd ..
git add magenta-realtime
# commit submodule pointer when ready
rm -rf build && cmake . -B build
cmake --build build --target deploy_magenta_au -j10
```

If upstream changes Jam IPC protocol, merge into `MagentaAU_ViewController.mm` manually.

---

## 16. Testing checklist

- [ ] Host app opens and registers extension
- [ ] Plugin appears as Instrument in Logic Pro
- [ ] Onboarding downloads resources
- [ ] Model load + generation at 48 kHz
- [ ] Auto-load `mrt2_small` when present in models folder
- [ ] MIDI from DAW piano roll triggers notes
- [ ] Logic bounce/export does not crash
- [ ] Multiple instances on separate tracks work (GPU mutex)
- [ ] Preset/state persists across DAW project save/reload
- [ ] `auvaltool -v aumu MGTP AHck` passes

---

## 17. Important files quick reference

| Purpose | Path |
|---------|------|
| Processor | `MagentaAU_AudioUnit.mm` |
| UI bridge | `MagentaAU_ViewController.mm` |
| UI overlay | `ui-patches/App.tsx` |
| Core overlay | `core-patches/core/` |
| Upstream Jam UI | `magenta-realtime/examples/jam/ui/src/App.tsx` |
| Upstream AU baseline | `magenta-realtime/examples/mrt2/auv3/MagentaRT_AudioUnit.mm` |
| jam-au3 reference | `github.com/audiohacking/jam-au3` |
| mrt2-au3 reference | `github.com/audiohacking/mrt2-au3` |
| Build root | `CMakeLists.txt` |
| Extension plist | `Info.plist.in` |
| Bootstrap script | `scripts/bootstrap-plugin.sh` |

---

## 18. Agent session quick start

```bash
cd magenta-au-template
git submodule update --init --recursive
source .venv/bin/activate 2>/dev/null || (uv venv --python 3.12 && source .venv/bin/activate && uv pip install "cmake<3.28")
npm install
cmake . -B build 2>/dev/null || cmake . -B build
cmake --build build --target deploy_magenta_au -j10 2>&1 | tee build.log
```

Review `build.log` for compile errors in `MagentaAU_*.mm` first. Do **not** modify jam-au3 or mrt2-au3 when working on this template or its forks.
