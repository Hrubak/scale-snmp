//! egui front end. Every network call runs on a worker thread so the window
//! never freezes; results come back as `jobs::Msg`.

use crate::http::Client;
use crate::jobs::{self, Ctx, DoneGuard, Msg};
use crate::util::js;
use eframe::egui::{self, Color32, RichText};
use egui_extras::{Column, TableBuilder};
use serde_json::Value;
use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};

pub const APP_TITLE: &str = "Scale HyperCore API";

#[derive(PartialEq, Clone, Copy)]
enum Tab {
    Cluster,
    Vms,
    Snapshots,
    Snmp,
    Alerts,
    Settings,
    SuperAudit,
    Api,
}

enum Pending {
    VmAction {
        uuid: String,
        name: String,
        action: &'static str,
    },
    DeleteSnap {
        uuid: String,
    },
    SnmpForce,
    Api {
        method: String,
        path: String,
        body: String,
    },
}

struct Confirm {
    text: String,
    action: Pending,
}

pub struct App {
    host: String,
    user: String,
    pass: String,
    status: String,
    status_ok: Option<bool>,
    tab: Tab,
    busy: bool,
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
    log: Vec<String>,
    log_path: PathBuf,
    app_dir: PathBuf,

    cluster_text: String,
    vms: Vec<Value>,
    vm_sel: Option<usize>,
    snaps: Vec<[String; 5]>,
    snap_sel: Option<usize>,
    community: String,
    snmp_out: String,
    conds: Vec<[String; 5]>,
    cond_summary: String,
    settings_out: String,
    api_method: &'static str,
    api_path: String,
    api_body: String,
    api_out: String,
    audit_folder: String,
    audit_out: String,
    audit_html: Option<PathBuf>,

    confirm: Option<Confirm>,
    alert: Option<String>,
}

impl App {
    pub fn new(egui_ctx: &egui::Context) -> Self {
        egui_ctx.set_visuals(egui::Visuals::light());
        let app_dir = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .unwrap_or_else(|| PathBuf::from("."));
        let (tx, rx) = channel();
        let mut app = Self {
            host: String::new(),
            user: String::new(),
            pass: String::new(),
            status: "Not connected".into(),
            status_ok: None,
            tab: Tab::Cluster,
            busy: false,
            tx,
            rx,
            log: Vec::new(),
            log_path: app_dir.join("ScaleAPI-log.txt"),
            audit_folder: app_dir.display().to_string(),
            app_dir,
            cluster_text: String::new(),
            vms: Vec::new(),
            vm_sel: None,
            snaps: Vec::new(),
            snap_sel: None,
            community: String::new(),
            snmp_out: String::new(),
            conds: Vec::new(),
            cond_summary: String::new(),
            settings_out: String::new(),
            api_method: "GET",
            api_path: "/v1/Cluster".into(),
            api_body: String::new(),
            api_out: String::new(),
            audit_out: String::new(),
            audit_html: None,
            confirm: None,
            alert: None,
        };
        app.say(format!(
            "Scale HyperCore API Toolkit {} ready. Enter cluster credentials and click Connect.",
            env!("CARGO_PKG_VERSION")
        ));
        app.say(format!(
            "TLS 1.2/1.3 is built in (rustls). No curl, .NET, or OpenSSL needed. Log file: {}",
            app.log_path.display()
        ));
        app
    }

    fn say(&mut self, text: impl Into<String>) {
        let text = text.into();
        let now = chrono::Local::now();
        self.log.push(format!("{}  {text}", now.format("%H:%M:%S")));
        if self.log.len() > 5000 {
            self.log.drain(..1000);
        }
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)
        {
            let _ = writeln!(f, "{}  {text}", now.format("%Y-%m-%dT%H:%M:%S"));
        }
    }

    fn have_creds(&mut self) -> bool {
        if self.host.trim().is_empty() || self.user.trim().is_empty() || self.pass.is_empty() {
            self.alert = Some("Enter the cluster IP, login, and password.".into());
            return false;
        }
        true
    }

    fn spawn(
        &mut self,
        ui_ctx: &egui::Context,
        client: Client,
        job: impl FnOnce(&Ctx) + Send + 'static,
    ) {
        if self.busy {
            return;
        }
        self.busy = true;
        let ctx = Ctx {
            tx: self.tx.clone(),
            repaint: ui_ctx.clone(),
            client,
        };
        std::thread::spawn(move || {
            let _done = DoneGuard(&ctx);
            job(&ctx);
        });
    }

    /// Run a job that needs credentials.
    fn run(&mut self, ui_ctx: &egui::Context, job: impl FnOnce(&Ctx) + Send + 'static) {
        if !self.have_creds() {
            return;
        }
        let client = Client::new(&self.host, self.user.trim(), &self.pass);
        self.spawn(ui_ctx, client, job);
    }

    fn vm_names(&self) -> HashMap<String, String> {
        self.vms
            .iter()
            .map(|v| (js(v.get("uuid")), js(v.get("name"))))
            .filter(|(u, _)| !u.is_empty())
            .collect()
    }

    fn drain(&mut self) {
        while let Ok(m) = self.rx.try_recv() {
            match m {
                Msg::Log(t) => self.say(t),
                Msg::Status { ok, text } => {
                    self.status_ok = Some(ok);
                    self.status = text;
                }
                Msg::ClusterText(t) => self.cluster_text = t,
                Msg::Vms(v) => {
                    self.vms = v;
                    self.vm_sel = None;
                }
                Msg::Snapshots(s) => {
                    self.snaps = s;
                    self.snap_sel = None;
                }
                Msg::SnmpLine(t) => {
                    self.snmp_out.push_str(&t);
                    self.snmp_out.push('\n');
                }
                Msg::SnmpAskAlreadyOn => {
                    self.confirm = Some(Confirm {
                        text:
                            "SNMP is already on for this cluster. Add this community string anyway?"
                                .into(),
                        action: Pending::SnmpForce,
                    })
                }
                Msg::Conditions(rows, summary) => {
                    self.conds = rows;
                    self.cond_summary = summary;
                }
                Msg::Settings(t) => self.settings_out = t,
                Msg::ApiOut(t) => self.api_out = t,
                Msg::Audit { text, html } => {
                    self.audit_out = text;
                    if html.is_some() {
                        self.audit_html = html;
                    }
                }
                Msg::Done => self.busy = false,
            }
        }
    }

    fn do_pending(&mut self, ctx: &egui::Context, p: Pending) {
        match p {
            Pending::VmAction { uuid, name, action } => {
                self.run(ctx, move |c| jobs::vm_action(c, &uuid, &name, action))
            }
            Pending::DeleteSnap { uuid } => {
                let names = self.vm_names();
                self.run(ctx, move |c| jobs::delete_snapshot(c, &uuid, &names))
            }
            Pending::SnmpForce => {
                let comm = self.community.trim().to_string();
                self.run(ctx, move |c| jobs::snmp_enable(c, &comm, true))
            }
            Pending::Api { method, path, body } => {
                self.run(ctx, move |c| jobs::api_send(c, &method, &path, &body))
            }
        }
    }

    fn selected_vm(&mut self) -> Option<(String, String)> {
        match self.vm_sel.and_then(|i| self.vms.get(i)) {
            Some(vm) => Some((js(vm.get("uuid")), js(vm.get("name")))),
            None => {
                self.alert = Some("Select a VM in the list.".into());
                None
            }
        }
    }

    // ---------- panels ----------

    fn connection_bar(&mut self, ui: &mut egui::Ui) {
        let label = |ui: &mut egui::Ui, t: &str, w: f32| {
            ui.allocate_ui_with_layout(
                [w, 22.0].into(),
                egui::Layout::left_to_right(egui::Align::Center),
                |ui| {
                    ui.set_min_width(w);
                    ui.label(t);
                },
            );
        };
        let (connect, test) = ui
            .horizontal(|ui| {
                label(ui, "Cluster IP / host", 110.0);
                ui.add_sized(
                    [220.0, 22.0],
                    egui::TextEdit::singleline(&mut self.host).hint_text("node lanIP"),
                );
                ui.add_space(12.0);
                let c = ui.add_enabled(
                    !self.busy,
                    egui::Button::new("Connect").min_size([90.0, 24.0].into()),
                );
                let t = ui.add_enabled(
                    !self.busy,
                    egui::Button::new("Test TLS").min_size([90.0, 24.0].into()),
                );
                if self.busy {
                    ui.spinner();
                }
                (c, t)
            })
            .inner;
        let pw = ui
            .horizontal(|ui| {
                label(ui, "Login", 110.0);
                ui.add_sized([220.0, 22.0], egui::TextEdit::singleline(&mut self.user));
                ui.add_space(12.0);
                label(ui, "Password", 60.0);
                let pw = ui.add_sized(
                    [180.0, 22.0],
                    egui::TextEdit::singleline(&mut self.pass).password(true),
                );
                ui.add_space(12.0);
                let color = match self.status_ok {
                    Some(true) => Color32::from_rgb(34, 139, 34),
                    Some(false) => Color32::from_rgb(178, 34, 34),
                    None => Color32::DARK_GRAY,
                };
                ui.label(RichText::new(&self.status).color(color).strong());
                pw
            })
            .inner;

        let enter = pw.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        if connect.clicked() || enter {
            self.tab = Tab::Cluster;
            self.run(ui.ctx(), jobs::cluster_info);
        }
        if test.clicked() {
            if self.host.trim().is_empty() {
                self.alert = Some("Enter the cluster IP or host.".into());
            } else {
                let client = Client::anonymous(&self.host);
                self.spawn(ui.ctx(), client, jobs::tls_test);
            }
        }
    }

    fn readonly_text(ui: &mut egui::Ui, text: &str) {
        egui::ScrollArea::both()
            .auto_shrink([false, false])
            .id_salt(ui.next_auto_id())
            .show(ui, |ui| {
                let mut t = text;
                ui.add(
                    egui::TextEdit::multiline(&mut t)
                        .font(egui::TextStyle::Monospace)
                        .desired_width(f32::INFINITY)
                        .desired_rows(20),
                );
            });
    }

    fn tab_cluster(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.busy, egui::Button::new("Refresh cluster"))
                .clicked()
            {
                self.run(ui.ctx(), jobs::cluster_info);
            }
            if ui
                .add_enabled(!self.busy, egui::Button::new("Refresh nodes"))
                .clicked()
            {
                self.run(ui.ctx(), jobs::nodes);
            }
            if ui
                .add_enabled(!self.busy, egui::Button::new("Update status"))
                .clicked()
            {
                self.run(ui.ctx(), jobs::update_status);
            }
        });
        ui.separator();
        Self::readonly_text(ui, &self.cluster_text);
    }

    fn tab_vms(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let en = !self.busy;
            if ui
                .add_enabled(en, egui::Button::new("Refresh VMs"))
                .clicked()
            {
                self.run(ui.ctx(), jobs::vms);
            }
            ui.separator();
            for (label, action) in [
                ("Start", "START"),
                ("Shutdown", "SHUTDOWN"),
                ("Power off", "STOP"),
                ("Reboot", "REBOOT"),
            ] {
                if ui.add_enabled(en, egui::Button::new(label)).clicked() {
                    if let Some((uuid, name)) = self.selected_vm() {
                        let p = Pending::VmAction {
                            uuid,
                            name: name.clone(),
                            action,
                        };
                        if action == "START" {
                            self.do_pending(ui.ctx(), p);
                        } else {
                            self.confirm = Some(Confirm {
                                text: format!("Send {action} to '{name}'?"),
                                action: p,
                            });
                        }
                    }
                }
            }
            if ui.add_enabled(en, egui::Button::new("Snapshot")).clicked() {
                if let Some((uuid, name)) = self.selected_vm() {
                    self.run(ui.ctx(), move |c| jobs::vm_snapshot(c, &uuid, &name));
                }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(format!("{} VM(s)", self.vms.len()));
            });
        });
        ui.separator();
        let rows: Vec<[String; 6]> = self
            .vms
            .iter()
            .map(|vm| {
                let mem = crate::util::num(vm.get("mem"));
                let mem_text = if mem > 0.0 {
                    format!(
                        "{} GiB",
                        crate::util::group_thousands(&format!("{:.1}", mem / 1073741824.0))
                    )
                } else {
                    "?".into()
                };
                [
                    js(vm.get("name")),
                    js(vm.get("state")),
                    js(vm.get("numVCPU")),
                    mem_text,
                    js(vm.get("tags")),
                    js(vm.get("uuid")),
                ]
            })
            .collect();
        if let Some(i) = grid(
            ui,
            "vmgrid",
            &["Name", "State", "vCPU", "Memory", "Tags", "UUID"],
            &rows,
            self.vm_sel,
        ) {
            self.vm_sel = Some(i);
        }
    }

    fn tab_snapshots(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.busy, egui::Button::new("Refresh snapshots"))
                .clicked()
            {
                let names = self.vm_names();
                self.run(ui.ctx(), move |c| jobs::snapshots(c, &names));
            }
            if ui
                .add_enabled(!self.busy, egui::Button::new("Delete selected"))
                .clicked()
            {
                match self.snap_sel.and_then(|i| self.snaps.get(i)) {
                    Some(row) => {
                        self.confirm = Some(Confirm {
                            text: format!("Delete snapshot '{}' of {}?", row[1], row[0]),
                            action: Pending::DeleteSnap {
                                uuid: row[3].clone(),
                            },
                        })
                    }
                    None => self.alert = Some("Select a snapshot.".into()),
                }
            }
            ui.label(format!("{} snapshot(s)", self.snaps.len()));
            if self.vms.is_empty() && !self.snaps.is_empty() {
                ui.label(RichText::new("Load the VMs tab to show VM names.").weak());
            }
        });
        ui.separator();
        if let Some(i) = grid(
            ui,
            "snapgrid",
            &["VM", "Label", "Timestamp", "UUID", "DomainUUID"],
            &self.snaps,
            self.snap_sel,
        ) {
            self.snap_sel = Some(i);
        }
    }

    fn tab_snmp(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("Community string");
            ui.add(
                egui::TextEdit::singleline(&mut self.community)
                    .password(true)
                    .desired_width(260.0),
            );
        });
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.busy, egui::Button::new("Check SNMP"))
                .clicked()
            {
                self.snmp_out.clear();
                self.run(ui.ctx(), jobs::snmp_check);
            }
            if ui
                .add_enabled(!self.busy, egui::Button::new("Enable SNMP"))
                .clicked()
            {
                if self.community.trim().is_empty() {
                    self.alert = Some("Enter the community string.".into());
                } else {
                    self.snmp_out.clear();
                    let comm = self.community.trim().to_string();
                    self.run(ui.ctx(), move |c| jobs::snmp_enable(c, &comm, false));
                }
            }
            ui.label(RichText::new("Needs HyperCore 9.7.1 or newer (REST v2).").weak());
        });
        ui.separator();
        Self::readonly_text(ui, &self.snmp_out);
    }

    fn tab_alerts(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.busy, egui::Button::new("Refresh conditions"))
                .clicked()
            {
                self.run(ui.ctx(), jobs::conditions);
            }
            ui.label(&self.cond_summary);
        });
        ui.separator();
        grid(
            ui,
            "condgrid",
            &["Severity", "Set", "Type", "Message", "UUID"],
            &self.conds,
            None,
        );
    }

    fn tab_settings(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let en = !self.busy;
            for (label, title, path) in [
                ("DNS", "DNS", "/v1/DNSConfig"),
                (
                    "Email alerts",
                    "Email alert targets",
                    "/v1/AlertEmailTarget",
                ),
                ("Syslog", "Syslog targets", "/v1/AlertSyslogTarget"),
                ("Users", "Users", "/v1/User"),
                ("ISOs", "ISOs", "/v1/ISO"),
            ] {
                if ui.add_enabled(en, egui::Button::new(label)).clicked() {
                    self.run(ui.ctx(), move |c| jobs::settings(c, title, path));
                }
                if label == "DNS"
                    && ui
                        .add_enabled(en, egui::Button::new("Time / NTP"))
                        .clicked()
                {
                    self.run(ui.ctx(), jobs::time_settings);
                }
            }
        });
        ui.separator();
        Self::readonly_text(ui, &self.settings_out);
    }

    fn tab_api(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            egui::ComboBox::from_id_salt("method")
                .selected_text(self.api_method)
                .width(80.0)
                .show_ui(ui, |ui| {
                    for m in ["GET", "POST", "PATCH", "DELETE"] {
                        ui.selectable_value(&mut self.api_method, m, m);
                    }
                });
            ui.add(egui::TextEdit::singleline(&mut self.api_path).desired_width(480.0));
            ui.label(
                RichText::new("Path under /rest (e.g. /v1/VirDomain or /v2/SNMPConfig)").weak(),
            );
        });
        ui.label("JSON body (POST/PATCH)");
        ui.add(
            egui::TextEdit::multiline(&mut self.api_body)
                .font(egui::TextStyle::Monospace)
                .desired_width(f32::INFINITY)
                .desired_rows(4),
        );
        if ui
            .add_enabled(!self.busy, egui::Button::new("Send"))
            .clicked()
        {
            let mut path = self.api_path.trim().to_string();
            if path.is_empty() {
                self.alert = Some("Enter an API path.".into());
            } else {
                if !path.starts_with('/') {
                    path.insert(0, '/');
                }
                let p = Pending::Api {
                    method: self.api_method.to_string(),
                    path: path.clone(),
                    body: self.api_body.clone(),
                };
                if self.api_method == "GET" {
                    self.do_pending(ui.ctx(), p);
                } else {
                    self.confirm = Some(Confirm {
                        text: format!("Send {} {path} to the cluster? Mutating calls wait for taskTag when present.", self.api_method),
                        action: p,
                    });
                }
            }
        }
        ui.separator();
        Self::readonly_text(ui, &self.api_out);
    }

    fn tab_audit(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if ui
                .add_enabled(!self.busy, egui::Button::new("Run SuperAudit"))
                .clicked()
            {
                let folder = if self.audit_folder.trim().is_empty() {
                    self.app_dir.clone()
                } else {
                    PathBuf::from(self.audit_folder.trim())
                };
                self.run(ui.ctx(), move |c| jobs::superaudit(c, folder));
            }
            if ui.button("Choose folder").clicked() {
                if let Some(dir) = pick_folder(&self.audit_folder) {
                    self.audit_folder = dir.display().to_string();
                }
            }
            let can_open = self
                .audit_html
                .as_ref()
                .map(|p| p.exists())
                .unwrap_or(false);
            if ui
                .add_enabled(can_open, egui::Button::new("Open report"))
                .clicked()
            {
                if let Some(p) = &self.audit_html {
                    open_path(p);
                }
            }
        });
        ui.horizontal(|ui| {
            ui.label("Save to");
            ui.add(egui::TextEdit::singleline(&mut self.audit_folder).desired_width(f32::INFINITY));
        });
        ui.separator();
        Self::readonly_text(ui, &self.audit_out);
    }
}

/// Simple read-only table with single-row selection. Returns a newly clicked row.
fn grid<const N: usize>(
    ui: &mut egui::Ui,
    id: &str,
    headers: &[&str; N],
    rows: &[[String; N]],
    selected: Option<usize>,
) -> Option<usize> {
    let mut clicked = None;
    ui.push_id(id, |ui| {
        let mut tb = TableBuilder::new(ui)
            .striped(true)
            .resizable(true)
            .sense(egui::Sense::click())
            .cell_layout(egui::Layout::left_to_right(egui::Align::Center));
        for i in 0..N {
            tb = if i + 1 == N {
                tb.column(Column::remainder().at_least(80.0))
            } else {
                tb.column(Column::initial(140.0).at_least(40.0).clip(true))
            };
        }
        tb.header(22.0, |mut h| {
            for name in headers {
                h.col(|ui| {
                    ui.strong(*name);
                });
            }
        })
        .body(|body| {
            body.rows(20.0, rows.len(), |mut row| {
                let i = row.index();
                row.set_selected(selected == Some(i));
                let mut hit = false;
                for cell in &rows[i] {
                    let (_, r) = row.col(|ui| {
                        let l = ui.add(
                            egui::Label::new(cell.as_str())
                                .truncate()
                                .selectable(false)
                                .sense(egui::Sense::click()),
                        );
                        hit |= l.clicked();
                    });
                    hit |= r.clicked();
                }
                if hit || row.response().clicked() {
                    clicked = Some(i);
                }
            });
        });
    });
    clicked
}

#[cfg(windows)]
fn pick_folder(start: &str) -> Option<PathBuf> {
    let mut d = rfd::FileDialog::new().set_title("Choose a folder for the SuperAudit report");
    if !start.is_empty() && std::path::Path::new(start).is_dir() {
        d = d.set_directory(start);
    }
    d.pick_folder()
}

#[cfg(not(windows))]
fn pick_folder(_start: &str) -> Option<PathBuf> {
    None
}

fn open_path(p: &std::path::Path) {
    #[cfg(windows)]
    let _ = std::process::Command::new("explorer").arg(p).spawn();
    #[cfg(not(windows))]
    let _ = std::process::Command::new("xdg-open").arg(p).spawn();
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.ui(ctx);
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.shutdown();
    }
}

impl App {
    /// Clear secrets from memory when the window closes.
    pub fn shutdown(&mut self) {
        self.pass.clear();
        self.community.clear();
    }

    /// One frame of UI. Shared by eframe (GPU) and the software renderer.
    pub fn ui(&mut self, ctx: &egui::Context) {
        self.drain();
        let modal = self.alert.is_some() || self.confirm.is_some();
        if self.busy {
            ctx.request_repaint_after(std::time::Duration::from_millis(200));
        }

        egui::TopBottomPanel::top("conn").show(ctx, |ui| {
            ui.add_space(6.0);
            if modal {
                ui.disable();
            }
            self.connection_bar(ui);
            ui.add_space(4.0);
        });

        egui::TopBottomPanel::bottom("log")
            .resizable(true)
            .default_height(170.0)
            .min_height(80.0)
            .frame(
                egui::Frame::default()
                    .fill(Color32::from_rgb(30, 30, 30))
                    .inner_margin(6.0),
            )
            .show(ctx, |ui| {
                egui::ScrollArea::vertical()
                    .stick_to_bottom(true)
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        for line in &self.log {
                            ui.label(
                                RichText::new(line)
                                    .monospace()
                                    .color(Color32::from_rgb(220, 220, 220)),
                            );
                        }
                    });
            });

        egui::CentralPanel::default().show(ctx, |ui| {
            if modal {
                ui.disable();
            }
            ui.horizontal(|ui| {
                for (t, name) in [
                    (Tab::Cluster, "Cluster"),
                    (Tab::Vms, "VMs"),
                    (Tab::Snapshots, "Snapshots"),
                    (Tab::Snmp, "SNMP"),
                    (Tab::Alerts, "Alerts"),
                    (Tab::Settings, "Settings"),
                    (Tab::SuperAudit, "SuperAudit"),
                    (Tab::Api, "API"),
                ] {
                    ui.selectable_value(&mut self.tab, t, RichText::new(name).size(15.0));
                }
            });
            ui.separator();
            match self.tab {
                Tab::Cluster => self.tab_cluster(ui),
                Tab::Vms => self.tab_vms(ui),
                Tab::Snapshots => self.tab_snapshots(ui),
                Tab::Snmp => self.tab_snmp(ui),
                Tab::Alerts => self.tab_alerts(ui),
                Tab::Settings => self.tab_settings(ui),
                Tab::SuperAudit => self.tab_audit(ui),
                Tab::Api => self.tab_api(ui),
            }
        });

        if let Some(msg) = self.alert.clone() {
            let mut close = false;
            egui::Window::new(APP_TITLE)
                .collapsible(false)
                .resizable(false)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    ui.label(&msg);
                    ui.add_space(8.0);
                    if ui.button("OK").clicked() {
                        close = true;
                    }
                });
            if close {
                self.alert = None;
            }
        }

        if self.confirm.is_some() {
            let text = self
                .confirm
                .as_ref()
                .map(|c| c.text.clone())
                .unwrap_or_default();
            let mut answer = None;
            egui::Window::new("Confirm")
                .collapsible(false)
                .resizable(false)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    ui.label(&text);
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        if ui.button("Yes").clicked() {
                            answer = Some(true);
                        }
                        if ui.button("No").clicked() {
                            answer = Some(false);
                        }
                    });
                });
            match answer {
                Some(true) => {
                    if let Some(c) = self.confirm.take() {
                        self.do_pending(ctx, c.action);
                    }
                }
                Some(false) => {
                    if matches!(
                        self.confirm.as_ref().map(|c| &c.action),
                        Some(Pending::SnmpForce)
                    ) {
                        self.snmp_out.push_str("No change made.\n");
                        self.say("No change made.");
                    }
                    self.confirm = None;
                }
                None => {}
            }
        }
    }
}
