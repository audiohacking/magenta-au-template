# Model loading (Magenta AU plugins)

Portable guide for fixing **repeated folder-picker prompts**, **false “resources missing” onboarding**, and **failure to auto-load `mrt2_small`** in sandboxed Magenta RealTime AUv3 plugins.

Applies to forks that use:

- `magenta-realtime/examples/common/objc/MagentaModelManager.{h,mm}`
- `magenta-realtime/examples/common/objc/MagentaModelDownloader.{h,mm}`
- `magenta-realtime/examples/common/cpp/magenta_paths.{h,cpp}`
- React UI with `ResourceOnboardingModal` + `ModelSelector` (`@magenta-rt/common`)

Reference implementation: **magenta-au-template** (`MagentaAU_ViewController.mm`, `MagentaAU_AudioUnit.mm`, `common-patches/`). See also **mrt2-au3** on `feature/bpm-sync`.

---

## Expected on-disk layout

Default install path (recommended for new users):

```
~/Documents/Magenta/magenta-rt-v2/
├── models/
│   ├── mrt2_small/
│   │   ├── mrt2_small.mlxfn
│   │   └── mrt2_small_state.safetensors
│   └── mrt2_base/          (optional)
├── resources/
│   ├── musiccoca/          (*.tflite)
│   └── spectrostream/      (*.mlxfn)
└── banks/                  (runtime state snapshots)
```

Users may also pick **`~/Documents/Magenta`** (parent folder) in the folder browser. The plugin must resolve that to `magenta-rt-v2/models` and `magenta-rt-v2/resources` automatically.

Override with env var `MAGENTA_HOME` (parent of `models/` and `resources/`; see `magenta_paths.cpp`).

---

## Sandbox & entitlements

AU extensions run sandboxed. Two access mechanisms work together:

| Mechanism | Purpose |
|-----------|---------|
| `com.apple.security.temporary-exception.files.home-relative-path.read-write` → `/Documents/Magenta/` | Read/write default Magenta tree **without** a bookmark |
| `com.apple.security.files.user-selected.read-write` + security-scoped bookmark | Access **user-picked** folders outside the default tree |

**Important:** Always resolve paths with `NSHomeDirectoryForUser(NSUserName())`, not `NSHomeDirectory()`, when building `~/Documents/Magenta/...`. The sandbox container path must not be used for entitlement-relative paths.

See `Entitlements.plist` in this repo.

---

## Symptoms (before fix)

1. **Onboarding modal every launch** — “Download Model” blocks the UI even when models exist.
2. **Folder picker required twice** — once to “load the UI”, again in Model selector.
3. **`localModels` empty** in UI while files exist on disk.
4. **Works on second open** — first `connectToAU` races ahead of async model scan/load.

---

## Root causes

### 1. Brittle resource validation (`glob`)

Old `areSharedResourcesValid` used glob patterns like `musiccoca*/*.tflite`. These fail silently in the sandbox or with slightly different directory layouts.

**Fix:** `resourcesValidAtPath:` — explicit `NSFileManager` checks for `musiccoca/*.tflite` and `spectrostream/*.mlxfn`.

### 2. Single-path model resolution

Old code only listed models in the exact bookmarked folder. If the user picked `~/Documents/Magenta`, listing returned empty (models live in `magenta-rt-v2/models/`).

**Fix:** `MGRTModelsSearchCandidates` / `defaultModelsSearchPaths` — try, in order:

- Bookmarked / saved path
- `{path}/models`
- `{path}/magenta-rt-v2/models`
- `~/Documents/Magenta/magenta-rt-v2/models`
- `~/Documents/Magenta/models`
- `magentart::paths::get_models_dir()`

Return the **first** directory where `listLocalModelsInDirectory` finds `.mlxfn` bundles.

### 3. Aggressive bookmark clearing

Old code **deleted** saved folder bookmarks when a single listing returned zero models (e.g. wrong subfolder). Next launch forced folder selection again.

**Fix:** **Never** clear bookmarks on empty listing. Log and fall through to default search paths instead.

### 4. `resourcesMissing` tied only to glob check

UI onboarding showed when `!areSharedResourcesValid`, even if `init_assets()` had already succeeded at AU init.

**Fix:** `MGRTSharedResourcesAvailable(au)` — true if resources validate on disk **or** `au.hasInitializedAssets` (engine already loaded tokenizer/MusicCoCa paths).

### 5. Async bootstrap race (first vs second open)

`connectToAU` flow:

```
uiReady → connectToAU
  → sendStateUpdate (resourcesMissing, params, …)   ← may show onboarding
  → handleListLocalModels                           ← sync
  → autoLoadSavedModelIfNeeded                      ← background queue
       → tryAutoLoadFromModelsDirectory
       → loadModelAtPath → sendStateUpdate (modelName)  ← second update fixes UI
```

First paint can show onboarding or “Select model…” until the background load completes. Second plugin open often has `LoadedModelBookmark` / `LoadedModelName` in `NSUserDefaults`, so load is faster.

**Mitigations applied:**

- UI: don’t show onboarding if `localModels.length > 0` or model already loaded (`App.tsx`).
- Native: `handleListLocalModels` sends `resourcesMissing: false` when models are found.
- Native: `loadModelAtPath` sends `resourcesMissing: false` on success.

**Future improvement:** await auto-load before first `sendStateUpdate`, or send a single consolidated state after bootstrap completes.

---

## Files to change (checklist)

### Shared (`magenta-realtime/examples/common/objc/`)

#### `MagentaModelDownloader.h` / `.mm`

- [ ] `+defaultResourceSearchPaths` — ordered candidate resource dirs
- [ ] `+resourcesValidAtPath:` — FileManager-based validation
- [ ] `+areSharedResourcesValid` — scan all candidates (replace glob)

#### `MagentaModelManager.h` / `.mm`

- [ ] `+defaultModelsSearchPaths` — ordered candidate model dirs
- [ ] Keep `+defaultModelsDirectory` using `NSHomeDirectoryForUser`

### Plugin view controller (e.g. `MagentaAU_ViewController.mm + MagentaAU_AudioUnit.mm`)

- [ ] `MGRTModelsSearchCandidates` / `MGRTEffectiveModelsDirectoryURL`
- [ ] `MGRTResolveModelsDirectory` — bookmark + fallback, **no bookmark clearing**
- [ ] `MGRTResolveResourcesPath` / `MGRTEnsureCustomResourcesPath`
- [ ] `MGRTSandboxAwareResourcesPath` — map user-picked folder to `resources` or `magenta-rt-v2/resources`
- [ ] `MGRTSharedResourcesAvailable`
- [ ] `MGRTPreferredModelName` — prefer `LoadedModelName`, else `mrt2_small`, else first found
- [ ] `connectToAU` — call `MGRTEnsureCustomResourcesPath()` before `resourcesMissing`
- [ ] `tryAutoLoadFromModelsDirectory` — call `MGRTEnsureCustomResourcesPath()`; load preferred model on background queue
- [ ] `handleListLocalModels` — push `resourcesMissing: false` when models exist
- [ ] `loadModelAtPath` — push `resourcesMissing: false` on success
- [ ] `hasInitializedAssets` on `AUAudioUnit` subclass (wraps `_modelLoaded`)

### React UI (`react_ui/src/App.tsx`)

- [ ] Gate onboarding: `resourcesMissing && !hasLocalModels && !modelReady`

### Entitlements

- [ ] `Entitlements.plist` includes `/Documents/Magenta/` home-relative exception (if using default path)

---

## NSUserDefaults keys

| Key | Type | Purpose |
|-----|------|---------|
| `DownloadFolderBookmark` | `NSData` | Security-scoped bookmark (legacy name) |
| `MagentaRT_ModelFolderBookmark` | `NSData` | Same bookmark (canonical) |
| `DownloadFolderPath` | `NSString` | Display path for UI |
| `MagentaRT_ModelFolderPath` | `NSString` | Display path (canonical) |
| `MagentaRT_CustomResourcesPath` | `NSString` | Resolved `resources/` dir used by `init_assets` |
| `LoadedModelBookmark` | `NSData` | Security-scoped bookmark to selected `.mlxfn` parent |
| `LoadedModelName` | `NSString` | Last loaded model folder name (e.g. `mrt2_small`) |

Save bookmarks with `NSURLBookmarkCreationWithSecurityScope`. Resolve with `NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI`.

---

## Bootstrap sequence (target behavior)

```
AU init
  └─ init_assets(resourcesPath)     // default or MagentaRT_CustomResourcesPath

WebView loads → React posts uiReady
  └─ connectToAU
       ├─ MGRTEnsureCustomResourcesPath()
       ├─ resourcesMissing = !MGRTSharedResourcesAvailable(au)
       ├─ handleListLocalModels() → localModels[]
       └─ autoLoadSavedModelIfNeeded() [async]
            ├─ resolve LoadedModelBookmark OR scan MGRTResolveModelsDirectory
            ├─ prefer mrt2_small
            └─ loadModelAtPath → modelName, resourcesMissing: false
```

User should **not** need to pick a folder if assets already live under `~/Documents/Magenta/`.

Manual folder pick (`selectDownloadFolder`) is still required for custom locations outside the entitlement path.

---

## Porting to another plugin

1. Copy or merge changes from **magenta-au-template** into the plugin’s view-controller `.mm` (search for `MGRT` helpers).
2. Update **shared** `MagentaModelDownloader` / `MagentaModelManager` in the submodule (or vendor copies).
3. Apply the **App.tsx** onboarding gate if the plugin uses the same React shell.
4. Verify **Entitlements.plist** is signed into the `.appex` (`cmake --build …` + `codesign -d --entitlements -`).
5. Test matrix:

| Scenario | Expected |
|----------|----------|
| Fresh install, models in `~/Documents/Magenta/magenta-rt-v2/` | No onboarding; `mrt2_small` auto-loads |
| User picked `~/Documents/Magenta` once | Bookmark saved; subpaths resolved; no re-prompt |
| Models only on external drive | Folder picker once; bookmark persists |
| No models, no resources | Onboarding shown; download flow works |
| Second plugin window open | Same as first (no regression) |

---

## Debugging

### Logs

Enable debug build:

```bash
cmake . -B build -DMAGENTART_DEBUG_LOG=ON
cmake --build build --target deploy_magenta_au -j10
```

Disk log (when models bookmark exists): `~/Documents/Magenta/magenta-rt-v2/models/mrt_debug.log`

Console filter: `MagentaAU`, `MagentaModelManager`

### Useful commands

```bash
# Verify appex entitlements
codesign -d --entitlements - "/path/to/Plugin.appex"

# List on-disk models (host)
ls ~/Documents/Magenta/magenta-rt-v2/models/*/ 

# Validate resources
ls ~/Documents/Magenta/magenta-rt-v2/resources/musiccoca/*.tflite
ls ~/Documents/Magenta/magenta-rt-v2/resources/spectrostream/*.mlxfn
```

### Crash / load reports

`~/Library/Logs/DiagnosticReports/MagentaAU_AU-*.ips` — extension crashes  
Filter Console for `MagentaAU: using models directory` / `using resources at`

---

## Known limitation: first-open race

Auto-load runs on a **background queue** after the first state push. The UI may briefly show onboarding or “Select model…” until `loadModelAtPath` completes. Re-open or wait ~1–2 s for the second `updateState`.

To eliminate entirely: block `connectToAU` on bootstrap completion or merge list + load into one state update (not yet implemented in magenta-au-template).

---

## Related docs

- [INSTALL.md](INSTALL.md) — DAW setup, 48 kHz requirement
- [README.md](README.md) — build & deploy
- Upstream: [magenta-realtime installation](https://github.com/magenta/magenta-realtime/blob/main/docs/installation.md)
