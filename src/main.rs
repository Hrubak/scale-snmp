// Scale HyperCore API Toolkit - Windows UI for SC//HyperCore REST (v1 + SNMP v2).
// No console window on Windows release builds.
// The `console` feature keeps the console so startup problems print to the terminal.
#![cfg_attr(
    all(windows, not(debug_assertions), not(feature = "console")),
    windows_subsystem = "windows"
)]

mod app;
mod audit;
mod http;
mod jobs;
mod util;

use std::io::Write;
use std::path::PathBuf;

fn app_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Startup problems go to ScaleAPI-log.txt next to the exe, or to %TEMP% when that
/// folder is not writable. They also go to stderr (visible in the console build).
fn log_startup(text: &str) {
    let line = format!(
        "{}  [startup] {text}",
        chrono::Local::now().format("%Y-%m-%dT%H:%M:%S")
    );
    eprintln!("{line}");
    for dir in [app_dir(), std::env::temp_dir()] {
        let path = dir.join("ScaleAPI-log.txt");
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            if writeln!(f, "{line}").is_ok() {
                return;
            }
        }
    }
}

fn show_error(text: &str) {
    #[cfg(windows)]
    {
        let _ = rfd::MessageDialog::new()
            .set_title(app::APP_TITLE)
            .set_description(text)
            .set_level(rfd::MessageLevel::Error)
            .set_buttons(rfd::MessageButtons::Ok)
            .show();
    }
    #[cfg(not(windows))]
    eprintln!("{text}");
}

fn os_info() -> String {
    #[cfg(windows)]
    {
        let out = std::process::Command::new("cmd")
            .args(["/C", "ver"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        if !out.is_empty() {
            return out;
        }
    }
    format!("{} {}", std::env::consts::OS, std::env::consts::ARCH)
}

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
    log_startup(&format!("starting renderer {renderer:?}"));
    let r = eframe::run_native(
        app::APP_TITLE,
        options(renderer),
        Box::new(|cc| Ok(Box::new(app::App::new(cc)))),
    );
    if let Err(e) = &r {
        log_startup(&format!("renderer {renderer:?} failed: {e}"));
    }
    r
}

fn main() {
    // A panic would otherwise kill the window with no message (release builds abort).
    std::panic::set_hook(Box::new(|info| {
        let msg = format!("Crash: {info}");
        log_startup(&msg);
        show_error(&format!(
            "{msg}\n\nDetails were written to ScaleAPI-log.txt next to ScaleAPI.exe."
        ));
    }));
    log_startup(&format!(
        "ScaleAPI {} on {}",
        env!("CARGO_PKG_VERSION"),
        os_info()
    ));

    // Direct3D 12 / Vulkan first: over RDP or on a VM without a GPU, Windows still
    // offers the Microsoft Basic Render Driver for D3D12 but only OpenGL 1.1.
    // OpenGL is the fallback. SCALE_RENDERER=glow forces OpenGL.
    let force_glow = std::env::var("SCALE_RENDERER")
        .map(|v| v.eq_ignore_ascii_case("glow"))
        .unwrap_or(false);
    let result: Result<(), String> = if force_glow {
        launch(eframe::Renderer::Glow).map_err(|e| format!("OpenGL: {e}"))
    } else {
        match launch(eframe::Renderer::Wgpu) {
            Ok(()) => Ok(()),
            Err(first) => launch(eframe::Renderer::Glow)
                .map_err(|second| format!("Direct3D/Vulkan: {first}\nOpenGL: {second}")),
        }
    };
    if let Err(e) = result {
        let text = format!(
            "The window could not be created.\n\n{e}\n\nThis PC has no usable graphics driver for Direct3D 12 or OpenGL 2+. \
             See ScaleAPI-log.txt next to ScaleAPI.exe."
        );
        log_startup(&text.replace('\n', " | "));
        show_error(&text);
        std::process::exit(1);
    }
}
