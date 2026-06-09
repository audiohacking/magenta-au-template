# Magenta AU Template

Starting point for building **Magenta RealTime** AUv3 (and future VST) plugins on macOS. This repo recycles the proven patterns from [jam-au3](https://github.com/audiohacking/jam-au3) and [mrt2-au3](https://github.com/audiohacking/mrt2-au3):

- Two-bundle AUv3 layout (host app + embedded `.appex`)
- `magentart::core` inference via the `magenta-realtime` submodule
- React UI in a `WKWebView` with native IPC bridge
- Model loading with security-scoped bookmarks
- Production core overlays (MLX GPU mutex, bounce-safe ring-buffer drain)
- GitHub Actions CI + release packaging (`.pkg` + `.dmg`)

The template ships as a working **Instrument** (`aumu`) plugin named **AudioHacking: Magenta AU Template**. Fork or clone it, rename identifiers, customize the UI, and ship your own plugin.

## Prerequisites

- macOS 14+
- Full Xcode (Metal compiler required)
- Node.js 20+
- Python 3.12 + [uv](https://github.com/astral-sh/uv)

## Quick start

```bash
git clone --recurse-submodules https://github.com/audiohacking/magenta-au-template.git
cd magenta-au-template
uv venv --python 3.12 && source .venv/bin/activate
uv pip install "cmake<3.28"
cmake . -B build
cmake --build build --target deploy_magenta_au -j10
```

Open `~/Applications/Magenta AU Template (AU).app` once to register the extension, then insert **AudioHacking: Magenta AU Template** as an Instrument in your DAW.

Models and shared resources live under `~/Documents/Magenta/magenta-rt-v2/` (same as Jam/MRT2 standalone).

See [INSTALL.md](INSTALL.md) for DAW setup, [AGENTS.md](AGENTS.md) for agent/developer bootstrap guide, and [MODEL_LOADING.md](MODEL_LOADING.md) for sandbox model/resource path behavior.

## Dev UI (HMR)

```bash
npm install
npm run dev --workspace=jam-ui   # Vite on port 62422
```

Rebuild the AU extension; when the dev server is running, the plugin UI loads from localhost with hot reload.

## Creating a new plugin from this template

1. Use **GitHub → Use this template** or clone and rename the repo.
2. Run `./scripts/bootstrap-plugin.sh` (see [AGENTS.md](AGENTS.md) §3) to replace bundle IDs, AU subtype, display names, and state prefixes.
3. Customize `MagentaAU_AudioUnit.mm` / `MagentaAU_ViewController.mm` and UI overlays in `ui-patches/`.
4. Update `Info.plist.in` AU component name/description.

## Reference plugins

| Repo | Mode | Notes |
|------|------|-------|
| [jam-au3](https://github.com/audiohacking/jam-au3) | Instrument | Simpler Jam UI; primary reference for this template |
| [mrt2-au3](https://github.com/audiohacking/mrt2-au3) | Instrument + FX | Sidechain capture, extended params — see AGENTS.md for FX porting |

## License

Apache 2.0 (Magenta components). See upstream [magenta-realtime](https://github.com/magenta/magenta-realtime).
