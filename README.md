# Ghostpen Oriel

A desktop app built with [Oriel](https://github.com/highercomve/Oriel): Zig
and the system webview (WebKitGTK on Linux, WebView2 on Windows, WKWebView on macOS), with a React + Vite
frontend.

## Develop

```sh
oriel dev        # Vite dev server with hot reload; Zig changes restart the app
oriel build      # production build: zig-out/bin/ghostpen-oriel (frontend embedded)
oriel run        # build and run it
oriel types      # regenerate frontend/src/oriel.ts from the Zig structs
oriel check      # type-check the Zig code (fast)
oriel package    # deb/rpm/AppImage, setup.exe or .app/.dmg in zig-out/package/
```

Each command is a thin wrapper around `zig build <step>` (run from anywhere
inside the project; extra arguments are passed on), so plain `zig build ...`
works as well. `oriel doctor` checks that the system has everything needed.

## Layout

| Path | What |
|---|---|
| `src/main.zig` | The Zig side: `Commands` the page can call and `Events` pushed to it |
| `frontend/` | The page: React + Vite |
| `build.zig` | Which Oriel modules are compiled in, packaging metadata |
| `build.zig.zon` | Package manifest; Oriel is a dependency |

## Calling Zig from the page

```ts
// frontend/src/oriel.ts is generated from the Zig structs, so both are typed.
import { invoke, listen } from "./oriel";
const text = await invoke("greet", { name: "Ada" }); // string
const off = listen("greeted", (e) => console.log(e.count)); // e: { count: number }
```

A command is any `pub fn` in `Commands`; its arguments struct and return type
become the JSON on the JavaScript side. Events declared in `Events` are sent
with `events.emit(.name, payload)` from any thread.
