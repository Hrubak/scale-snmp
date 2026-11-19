// Scale HyperCore API Toolkit - Windows UI for SC//HyperCore REST (v1 + SNMP v2).
// No console window on Windows release builds.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod audit;
mod http;
mod jobs;
mod util;

fn options(renderer: eframe::Renderer) -> eframe::NativeOptions {
    eframe::NativeOptions {
        renderer,
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title(format!("{} {}", app::APP_TITLE, env!("CARGO_PKG_VERSION")))
            .with_inner_size([1000.0, 720.0])
            .with_min_inner_size([800.0, 560.0]),
        ..Default::default()
    }
}

fn launch(renderer: eframe::Renderer) -> eframe::Result<()> {
    eframe::run_native(
        app::APP_TITLE,
        options(renderer),
        Box::new(|cc| Ok(Box::new(app::App::new(cc)))),
    )
}

fn main() -> eframe::Result<()> {
    // Direct3D 12 / Vulkan first: over RDP or on a VM without a GPU, Windows still
    // offers the Microsoft Basic Render Driver for D3D12 but only OpenGL 1.1.
    // OpenGL is the fallback. SCALE_RENDERER=glow forces OpenGL.
    let force_glow = std::env::var("SCALE_RENDERER")
        .map(|v| v.eq_ignore_ascii_case("glow"))
        .unwrap_or(false);
    if force_glow {
        return launch(eframe::Renderer::Glow);
    }
    match launch(eframe::Renderer::Wgpu) {
        Ok(()) => Ok(()),
        Err(first) => launch(eframe::Renderer::Glow).map_err(|_| first),
    }
}
