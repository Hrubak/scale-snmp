// Embed Windows version information (file description, product name, version)
// in ScaleAPI.exe. Unsigned binaries with no version resource are more likely
// to be flagged by antivirus heuristics.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let mut res = winresource::WindowsResource::new();
        if std::env::var("HOST")
            .map(|h| !h.contains("windows"))
            .unwrap_or(false)
        {
            // Cross-compiling from Linux with MinGW.
            res.set_toolkit_path("/usr/bin");
            res.set_windres_path("x86_64-w64-mingw32-windres");
            res.set_ar_path("x86_64-w64-mingw32-ar");
        }
        res.set("FileDescription", "Scale HyperCore API Toolkit")
            .set("ProductName", "Scale HyperCore API Toolkit")
            .set("OriginalFilename", "ScaleAPI.exe")
            .set("InternalName", "ScaleAPI")
            .set(
                "Comments",
                "SC//HyperCore REST API client: cluster, VMs, snapshots, SNMP, SuperAudit",
            );
        if let Err(e) = res.compile() {
            println!("cargo:warning=version resource not embedded: {e}");
        }
    }
}
