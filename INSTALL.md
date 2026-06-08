# Installing Magenta AU Template

## 1. Build and deploy

Follow [README.md](README.md). The `deploy_magenta_au` target copies the host app to:

```
~/Applications/Magenta AU Template (AU).app
```

## 2. Register the extension

Open the host app **once**. It shows a confirmation dialog and exits. This registers the embedded `MagentaAU_AU.appex` with macOS.

Alternatively:

```bash
pluginkit -a ~/Applications/Magenta\ AU\ Template\ \(AU\).app/Contents/PlugIns/MagentaAU_AU.appex
killall -9 AudioComponentRegistrar 2>/dev/null || true
```

## 3. Use in your DAW

| DAW | Steps |
|-----|-------|
| **Logic Pro** | Software Instrument track → Plug-in slot → **AU Instruments → AudioHacking: Magenta AU Template** |
| **Ableton Live** | MIDI track → Plug-ins → **AudioHacking: Magenta AU Template** |
| **GarageBand** | Software Instrument → Smart Controls → Plug-ins |

## 4. Models and resources

On first launch the UI guides you through downloading shared Magenta assets. Models are stored in:

```
~/Documents/Magenta/magenta-rt-v2/
```

You can reuse models downloaded for MRT2, Jam, or other Magenta RealTime apps.

## 5. Requirements

- **macOS 14+**
- **Apple Silicon** recommended (MLX/Metal inference)
- Host project sample rate **48 kHz** (non-48 kHz hosts are resampled on output)
- MIDI from the DAW routes to the instrument; the plugin UI also supports computer-keyboard MIDI when focused

## Troubleshooting

- Plugin not visible: re-run the host app or `pluginkit -m -v -i com.audiohacking.magenta.template.au`.
- Sandbox file access: grant folder access when prompted for custom model directories.
- Rebuild after submodule updates: `git submodule update --remote magenta-realtime && cmake --build build --target deploy_magenta_au`.
- Validate component: `auvaltool -v aumu MGTP AHck`
