//! CPU renderer for PCs with no usable GPU driver.
//!
//! Server 2019 over ScreenConnect (and similar GPU-less VMs) offers no Direct3D 12
//! adapter and only OpenGL 1.1, so neither eframe renderer can start. This draws
//! egui's triangles into a plain RGB bitmap and hands it to the window with GDI
//! (via softbuffer). It needs nothing beyond what every Windows desktop has.

use crate::app::{App, APP_TITLE};
use eframe::egui::{self, epaint, Color32, TextureId};
use std::collections::HashMap;
use std::num::NonZeroU32;
use std::rc::Rc;
use std::time::Instant;
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

struct Texture {
    w: usize,
    h: usize,
    px: Vec<Color32>,
}

/// Rasterizes egui meshes into a 0x00RRGGBB buffer.
#[derive(Default)]
pub struct Raster {
    textures: HashMap<TextureId, Texture>,
    pub w: usize,
    pub h: usize,
    pub buf: Vec<u32>,
}

impl Raster {
    pub fn update_textures(&mut self, delta: &egui::TexturesDelta) {
        for (id, d) in &delta.set {
            let (w, h) = (d.image.width(), d.image.height());
            let px: Vec<Color32> = match &d.image {
                egui::ImageData::Color(c) => c.pixels.clone(),
                egui::ImageData::Font(f) => f.srgba_pixels(None).collect(),
            };
            match d.pos {
                None => {
                    self.textures.insert(*id, Texture { w, h, px });
                }
                Some([x0, y0]) => {
                    if let Some(t) = self.textures.get_mut(id) {
                        for y in 0..h {
                            for x in 0..w {
                                let (tx, ty) = (x0 + x, y0 + y);
                                if tx < t.w && ty < t.h {
                                    t.px[ty * t.w + tx] = px[y * w + x];
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn free_textures(&mut self, delta: &egui::TexturesDelta) {
        for id in &delta.free {
            self.textures.remove(id);
        }
    }

    pub fn resize(&mut self, w: usize, h: usize) {
        self.w = w;
        self.h = h;
        self.buf.resize(w * h, 0);
    }

    pub fn paint(&mut self, prims: &[egui::ClippedPrimitive], ppp: f32, clear: Color32) {
        let c = (clear.r() as u32) << 16 | (clear.g() as u32) << 8 | clear.b() as u32;
        self.buf.fill(c);
        for p in prims {
            if let epaint::Primitive::Mesh(mesh) = &p.primitive {
                let clip = [
                    (p.clip_rect.min.x * ppp).round().max(0.0) as i32,
                    (p.clip_rect.min.y * ppp).round().max(0.0) as i32,
                    ((p.clip_rect.max.x * ppp).round() as i32).min(self.w as i32),
                    ((p.clip_rect.max.y * ppp).round() as i32).min(self.h as i32),
                ];
                if clip[0] >= clip[2] || clip[1] >= clip[3] {
                    continue;
                }
                self.mesh(mesh, ppp, clip);
            }
        }
    }

    fn mesh(&mut self, mesh: &epaint::Mesh, ppp: f32, clip: [i32; 4]) {
        let Some(tex) = self.textures.get(&mesh.texture_id) else {
            return;
        };
        let (tw, th) = (tex.w as f32, tex.h as f32);
        for tri in mesh.indices.chunks_exact(3) {
            let v = [
                &mesh.vertices[tri[0] as usize],
                &mesh.vertices[tri[1] as usize],
                &mesh.vertices[tri[2] as usize],
            ];
            let p: [(f32, f32); 3] = v.map(|v| (v.pos.x * ppp, v.pos.y * ppp));
            let area =
                (p[1].0 - p[0].0) * (p[2].1 - p[0].1) - (p[1].1 - p[0].1) * (p[2].0 - p[0].0);
            if area.abs() < 1e-6 {
                continue;
            }
            let inv = 1.0 / area;
            let minx = (p.iter().map(|q| q.0).fold(f32::MAX, f32::min).floor() as i32).max(clip[0]);
            let maxx = (p.iter().map(|q| q.0).fold(f32::MIN, f32::max).ceil() as i32).min(clip[2]);
            let miny = (p.iter().map(|q| q.1).fold(f32::MAX, f32::min).floor() as i32).max(clip[1]);
            let maxy = (p.iter().map(|q| q.1).fold(f32::MIN, f32::max).ceil() as i32).min(clip[3]);
            if minx >= maxx || miny >= maxy {
                continue;
            }
            let col = v.map(|v| {
                let c = v.color;
                [c.r() as f32, c.g() as f32, c.b() as f32, c.a() as f32]
            });
            let uv = v.map(|v| (v.uv.x * tw - 0.5, v.uv.y * th - 0.5));
            // Solid fills (most of the UI) sample one texel; skip per-pixel sampling.
            let flat_uv = uv[0] == uv[1] && uv[1] == uv[2];
            let flat_col = col[0] == col[1] && col[1] == col[2];
            let flat_tex = if flat_uv {
                sample(tex, uv[0].0, uv[0].1)
            } else {
                [0.0; 4]
            };

            for y in miny..maxy {
                let py = y as f32 + 0.5;
                let row = y as usize * self.w;
                for x in minx..maxx {
                    let px = x as f32 + 0.5;
                    let w0 = ((p[1].0 - px) * (p[2].1 - py) - (p[1].1 - py) * (p[2].0 - px)) * inv;
                    let w1 = ((p[2].0 - px) * (p[0].1 - py) - (p[2].1 - py) * (p[0].0 - px)) * inv;
                    let w2 = 1.0 - w0 - w1;
                    if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 {
                        continue;
                    }
                    let c = if flat_col {
                        col[0]
                    } else {
                        let mut c = [0.0; 4];
                        for i in 0..4 {
                            c[i] = col[0][i] * w0 + col[1][i] * w1 + col[2][i] * w2;
                        }
                        c
                    };
                    let t = if flat_uv {
                        flat_tex
                    } else {
                        let u = uv[0].0 * w0 + uv[1].0 * w1 + uv[2].0 * w2;
                        let vv = uv[0].1 * w0 + uv[1].1 * w1 + uv[2].1 * w2;
                        sample(tex, u, vv)
                    };
                    // Both are premultiplied (gamma space); egui blends with premultiplied alpha.
                    let sr = c[0] * t[0] / 255.0;
                    let sg = c[1] * t[1] / 255.0;
                    let sb = c[2] * t[2] / 255.0;
                    let sa = c[3] * t[3] / 255.0;
                    if sa <= 0.0 && sr <= 0.0 && sg <= 0.0 && sb <= 0.0 {
                        continue;
                    }
                    let k = 1.0 - sa / 255.0;
                    let d = &mut self.buf[row + x as usize];
                    let dr = ((*d >> 16) & 0xFF) as f32;
                    let dg = ((*d >> 8) & 0xFF) as f32;
                    let db = (*d & 0xFF) as f32;
                    let r = (sr + dr * k).clamp(0.0, 255.0) as u32;
                    let g = (sg + dg * k).clamp(0.0, 255.0) as u32;
                    let b = (sb + db * k).clamp(0.0, 255.0) as u32;
                    *d = (r << 16) | (g << 8) | b;
                }
            }
        }
    }
}

/// Bilinear sample in texel space (premultiplied RGBA as f32 0..255).
fn sample(t: &Texture, u: f32, v: f32) -> [f32; 4] {
    let x0 = u.floor();
    let y0 = v.floor();
    let fx = u - x0;
    let fy = v - y0;
    let get = |x: f32, y: f32| {
        let xi = (x as i64).clamp(0, t.w as i64 - 1) as usize;
        let yi = (y as i64).clamp(0, t.h as i64 - 1) as usize;
        let c = t.px[yi * t.w + xi];
        [c.r() as f32, c.g() as f32, c.b() as f32, c.a() as f32]
    };
    let a = get(x0, y0);
    let b = get(x0 + 1.0, y0);
    let c = get(x0, y0 + 1.0);
    let d = get(x0 + 1.0, y0 + 1.0);
    let mut out = [0.0; 4];
    for i in 0..4 {
        let top = a[i] + (b[i] - a[i]) * fx;
        let bot = c[i] + (d[i] - c[i]) * fx;
        out[i] = top + (bot - top) * fy;
    }
    out
}

// ---------- window + event loop ----------

#[derive(Debug, Clone, Copy)]
struct Wake;

struct Gfx {
    window: Rc<Window>,
    surface: softbuffer::Surface<Rc<Window>, Rc<Window>>,
    state: egui_winit::State,
}

struct Runner {
    ctx: egui::Context,
    app: App,
    proxy: EventLoopProxy<Wake>,
    gfx: Option<Gfx>,
    raster: Raster,
    next_repaint: Option<Instant>,
    error: Option<String>,
}

impl Runner {
    fn redraw(&mut self) {
        let Some(g) = self.gfx.as_mut() else { return };
        let size = g.window.inner_size();
        let (Some(w), Some(h)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else {
            return;
        };
        let input = g.state.take_egui_input(&g.window);
        let app = &mut self.app;
        let out = self.ctx.run(input, |ctx| app.ui(ctx));
        g.state
            .handle_platform_output(&g.window, out.platform_output);

        self.raster.update_textures(&out.textures_delta);
        let prims = self.ctx.tessellate(out.shapes, out.pixels_per_point);
        self.raster.resize(w.get() as usize, h.get() as usize);
        let clear = self.ctx.style().visuals.panel_fill;
        self.raster.paint(&prims, out.pixels_per_point, clear);
        self.raster.free_textures(&out.textures_delta);

        if g.surface.resize(w, h).is_ok() {
            if let Ok(mut buf) = g.surface.buffer_mut() {
                buf.copy_from_slice(&self.raster.buf);
                let _ = buf.present();
            }
        }

        let delay = out
            .viewport_output
            .get(&egui::ViewportId::ROOT)
            .map(|v| v.repaint_delay)
            .unwrap_or(std::time::Duration::MAX);
        self.next_repaint = if delay.is_zero() {
            g.window.request_redraw();
            None
        } else {
            Instant::now().checked_add(delay)
        };
    }
}

impl ApplicationHandler<Wake> for Runner {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.gfx.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title(format!(
                "{APP_TITLE} {} (software rendering)",
                env!("CARGO_PKG_VERSION")
            ))
            .with_inner_size(winit::dpi::LogicalSize::new(1000.0, 720.0))
            .with_min_inner_size(winit::dpi::LogicalSize::new(800.0, 560.0));
        let window = match el.create_window(attrs) {
            Ok(w) => Rc::new(w),
            Err(e) => {
                self.error = Some(format!("create window: {e}"));
                el.exit();
                return;
            }
        };
        let surface = match softbuffer::Context::new(window.clone())
            .and_then(|c| softbuffer::Surface::new(&c, window.clone()))
        {
            Ok(s) => s,
            Err(e) => {
                self.error = Some(format!("software surface: {e}"));
                el.exit();
                return;
            }
        };
        let state = egui_winit::State::new(
            self.ctx.clone(),
            egui::ViewportId::ROOT,
            &window,
            Some(window.scale_factor() as f32),
            None,
            Some(8192),
        );
        window.request_redraw();
        self.gfx = Some(Gfx {
            window,
            surface,
            state,
        });
    }

    fn user_event(&mut self, _el: &ActiveEventLoop, _e: Wake) {
        if let Some(g) = &self.gfx {
            g.window.request_redraw();
        }
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let Some(g) = self.gfx.as_mut() else { return };
        match &event {
            WindowEvent::CloseRequested => {
                self.app.shutdown();
                el.exit();
                return;
            }
            WindowEvent::RedrawRequested => {
                self.redraw();
                return;
            }
            _ => {}
        }
        let resp = g.state.on_window_event(&g.window, &event);
        if resp.repaint {
            g.window.request_redraw();
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        match self.next_repaint {
            Some(t) if t <= Instant::now() => {
                self.next_repaint = None;
                if let Some(g) = &self.gfx {
                    g.window.request_redraw();
                }
                el.set_control_flow(ControlFlow::Wait);
            }
            Some(t) => el.set_control_flow(ControlFlow::WaitUntil(t)),
            None => el.set_control_flow(ControlFlow::Wait),
        }
    }
}

pub fn run() -> Result<(), String> {
    let el = EventLoop::<Wake>::with_user_event()
        .build()
        .map_err(|e| format!("event loop: {e}"))?;
    let ctx = egui::Context::default();
    let proxy = el.create_proxy();
    let wake = proxy.clone();
    // Worker threads call request_repaint(); wake the event loop when they do.
    ctx.set_request_repaint_callback(move |_| {
        let _ = wake.send_event(Wake);
    });
    let app = App::new(&ctx);
    let mut runner = Runner {
        ctx,
        app,
        proxy,
        gfx: None,
        raster: Raster::default(),
        next_repaint: None,
        error: None,
    };
    el.run_app(&mut runner)
        .map_err(|e| format!("event loop: {e}"))?;
    let _ = &runner.proxy;
    match runner.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paints_a_frame_without_gpu() {
        let ctx = egui::Context::default();
        let mut raster = Raster::default();
        let input = egui::RawInput {
            screen_rect: Some(egui::Rect::from_min_size(
                egui::Pos2::ZERO,
                egui::vec2(400.0, 300.0),
            )),
            ..Default::default()
        };
        let out = ctx.run(input, |ctx| {
            egui::CentralPanel::default()
                .frame(egui::Frame::default().fill(Color32::from_rgb(0, 0, 200)))
                .show(ctx, |ui| {
                    ui.label("Hello");
                });
        });
        raster.update_textures(&out.textures_delta);
        let prims = ctx.tessellate(out.shapes, out.pixels_per_point);
        raster.resize(400, 300);
        raster.paint(&prims, out.pixels_per_point, Color32::BLACK);
        // Background filled blue, and some text pixels differ from it.
        assert_eq!(raster.buf[399 + 299 * 400] & 0xFF, 200);
        let distinct = raster
            .buf
            .iter()
            .filter(|p| **p != raster.buf[299 * 400 + 399])
            .count();
        assert!(distinct > 20, "no text drawn ({distinct} pixels)");
    }
}
