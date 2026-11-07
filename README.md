# zui-sokol

A [sokol](https://github.com/floooh/sokol) backend for
[zui](https://github.com/AaronJClausen/zui), through
[sokol-zig](https://github.com/floooh/sokol-zig): it collects sokol_app
events into zui's frame records, measures text through zui's text
contract, and draws zui's frames as a renderer (zui's renderer contract)
with sokol_gl and sokol_debugtext, on D3D11 (Windows), Metal (macOS) or
OpenGL (Linux).

## Requirements

- Zig **0.16.0**
- zui, fetched automatically
- sokol-zig, fetched automatically
- On Linux: `libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev`

## Run the demo

```sh
zig build demo
zig build demo -- --frames 120   # quit after 120 frames, for smoke tests
zig build demo -Dgl=true         # force OpenGL instead of D3D11 or Metal
```

The demo runs `examples/showcase.zig`, the same UI as the zui-terminal
demo, so the two renderers can be compared.

## Developing against a local zui

`build.zig.zon` pins zui to a commit. To build against a zui working copy
instead, without editing it:

```sh
zig build test --fork=../zui
```

To move the pin, push the zui change and run
`zig fetch --save=zui git+https://github.com/AaronJClausen/zui#<commit>`.

## How zui maps onto sokol

| zui | sokol |
|---|---|
| `rectangle` | sokol_gl quads, or a triangle fan with each corner's own radius |
| `border` | a ring of triangles inside the bounds, with per-edge widths and per-corner radii |
| `text` | sokol_debugtext, one call per wrapped line; `FontId` 0–5 picks one of its fonts; with letter spacing, each glyph is placed on its own |
| `image` | a textured sokol_gl quad (`zui_sokol.Image`: a view and a sampler) |
| `clip_begin` / `clip_end` | `sg.applyScissorRect` per layer, at the record's `scale × zoom` |
| mouse and touch | `MOUSE_*` and `TOUCHES_*` events, in order; each touch is a pointer of its own |
| wheel | `MOUSE_SCROLL` events, flipped and scaled by `InputCollector.wheel_step` |
| keys | `KEY_DOWN` and `KEY_UP` with their modifiers, repeat flag and key code as the scancode; `CHAR` as text |
| focus | `FOCUSED` and `UNFOCUSED` as the environment's `window_focused` |
| cursor request | `sapp.setMouseCursor`, through `HostRequestApplier` |

sokol_gl and sokol_debugtext each batch their own draws. To keep zui's
paint order, the renderer starts a new layer whenever a shape follows text
or the clip changes, then replays the layers in order, each under its own
scissor rectangle.

Current limits:
- **Bitmap text.** sokol_debugtext's fonts are 8×8 and printable ASCII
  only; other code points draw as `?`. Glyphs are `Text.glyph_scale` of
  the text size, and every glyph has the same advance.
- **No idle sleep.** sokol_app presents at every display refresh, so the
  process never sleeps. The demo declares a zui frame only when
  `nextFrame` or new input calls for one, and otherwise redraws the frame
  it holds: 121 frames drawn with no input took 2 zui frames.
- **No IME window.** sokol_app cannot place one, so a text-input request
  is not applied.

## Use it in your application

```zig
const zui_sokol = @import("zui_sokol");
const zui = zui_sokol.zui;
const Ui = zui.Context(zui_sokol.config(.{}));

// in sokol_app's init callback, after sg.setup:
renderer = .init(&text);
renderer.clear_color = background;

// in the event callback:
input.handleEvent(event, sapp.dpiScale(), now());

// in the frame callback:
const params: zui.FrameParams = .{ .now = now(), .viewport = viewport, .scale = sapp.dpiScale() };
ui.beginFrame(&.{ .params = params, .events = input.take() });
// ... declare your UI ...
const frame = ui.endFrame();
host_requests.apply(frame.requests());
try renderer.zuiSubmit(.library, frame); // one swapchain pass, cleared to clear_color
ui.release(frame);
```

`zui_sokol.Renderer` implements zui's renderer contract. Its surface is
`.library`, sokol_app's swapchain. `zui_sokol.config(...)` builds the
`Config` from its declarations: `Text` is `zui_sokol.Text`, `ImageHandle`
is `zui_sokol.Image`, and there are no optional commands and no
`CustomData`, so the renderer's `switch` over the commands names exactly
the base commands and `image`.

## License

MIT; see [LICENSE](LICENSE).
