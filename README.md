# zui-sokol

A [sokol](https://github.com/floooh/sokol) backend for
[zui](https://github.com/AaronJClausen/zui), through
[sokol-zig](https://github.com/floooh/sokol-zig): it collects sokol_app
events into `zui.Input` and draws zui's render commands with sokol_gl and
sokol_debugtext, on D3D11 (Windows), Metal (macOS) or OpenGL (Linux).

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
| `text` | sokol_debugtext, one call per wrapped line; `FontId` 0–5 picks one of its fonts |
| `image` | a textured sokol_gl quad (`zui_sokol.Image`: a view and a sampler) |
| `clip_begin` / `clip_end` | `sg.applyScissorRect` per layer |
| wheel | `MOUSE_SCROLL` events, flipped and scaled by `InputCollector.wheel_step` |

sokol_gl and sokol_debugtext each batch their own draws. To keep zui's
paint order, the renderer starts a new layer whenever a shape follows text
or the clip changes, then replays the layers in order, each under its own
scissor rectangle.

Current limits:
- **Bitmap text.** sokol_debugtext's fonts are 8×8 and printable ASCII
  only; other code points draw as `?`. Glyphs are `Platform.glyph_scale`
  of the text size, and every glyph has the same advance.
- **No idle sleep.** sokol_app redraws every display refresh, so
  `ui.needsFrame()` is not used and `Platform` has no `wake`.

## Use it in your application

```zig
const zui_sokol = @import("zui_sokol");
const zui = zui_sokol.zui;
const Ui = zui.Context(zui_sokol.config(.{}), zui_sokol.Platform);

// in sokol_app's init callback, after sg.setup:
renderer = .init();

// in the event callback:
input.handleEvent(event, sapp.dpiScale());

// in the frame callback:
platform.dpi_scale = sapp.dpiScale();
ui.beginFrame(input.take(viewport, @floatCast(sapp.frameDuration())));
// ... declare your UI ...
const frame = ui.endFrame() catch ui.lastFrame();
sg.beginPass(.{ .action = clear, .swapchain = sokol.glue.swapchain() });
renderer.draw(Ui.RenderCommand, &platform, frame.commands(), viewport, .{});
sg.endPass();
sg.commit();
ui.release(frame);
```

## License

MIT; see [LICENSE](LICENSE).
