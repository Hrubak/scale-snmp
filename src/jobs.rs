//! Work that talks to the cluster. Each job runs on a background thread and
//! reports back to the UI through `Msg`. Jobs never log the password, the
//! Authorization header, or the SNMP community string.

use crate::audit::{self, RequestPaths};
use crate::http::{self, Client};
use crate::util::{as_list, first_record, js, parse_json, public_error};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

pub enum Msg {
    Log(String),
    Status { ok: bool, text: String },
    ClusterText(String),
    Vms(Vec<Value>),
    Snapshots(Vec<[String; 5]>),
    SnmpLine(String),
    SnmpAskAlreadyOn,
    Conditions(Vec<[String; 5]>, String),
    Settings(String),
    ApiOut(String),
    Audit { text: String, html: Option<PathBuf> },
    Done,
}

pub struct Ctx {
    pub tx: Sender<Msg>,
    pub repaint: eframe::egui::Context,
    pub client: Client,
}

impl Ctx {
    pub fn send(&self, m: Msg) {
        let _ = self.tx.send(m);
        self.repaint.request_repaint();
    }
    pub fn say(&self, t: impl Into<String>) {
        self.send(Msg::Log(t.into()));
    }
}

/// Sends `Done` even if a job returns early.
pub struct DoneGuard<'a>(pub &'a Ctx);
impl Drop for DoneGuard<'_> {
    fn drop(&mut self) {
        self.0.send(Msg::Done);
    }
}

fn body_or_code(r: &http::Response) -> String {
    format!("({}): {}", r.code_text(), public_error(&r.body))
}

pub fn wait_task(ctx: &Ctx, tag: &str) -> bool {
    if tag.is_empty() {
        return true;
    }
    ctx.say(format!("Waiting for task {tag} ..."));
    let deadline = Instant::now() + Duration::from_secs(120);
    while Instant::now() < deadline {
        let r = ctx.client.get(&format!("/v1/TaskTag/{tag}"));
        let parsed = parse_json(&r.body).unwrap_or(Value::Null);
        let task = first_record(&parsed).cloned().unwrap_or(Value::Null);
        let state = js(task.get("state"));
        if !state.is_empty() && state != "RUNNING" && state != "QUEUED" {
            if state == "ERROR" || state == "UNINITIALIZED" {
                let msg = task
                    .get("formattedMessage")
                    .map(|m| js(Some(m)))
                    .filter(|m| !m.is_empty())
                    .unwrap_or_else(|| public_error(&r.body));
                ctx.say(format!("Task failed ({state}): {msg}"));
                return false;
            }
            ctx.say(format!("Task finished: {state}"));
            return true;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    ctx.say("Task wait timed out after 120s.");
    false
}

fn task_tag(body: &str) -> String {
    parse_json(body)
        .and_then(|v| {
            first_record(&v)
                .and_then(|r| r.get("taskTag"))
                .map(|t| js(Some(t)))
        })
        .unwrap_or_default()
}

// ---------- Cluster tab ----------

pub fn cluster_info(ctx: &Ctx) {
    ctx.say(format!("--- Cluster {}", ctx.client.host()));
    let c = ctx.client.get("/v1/Cluster");
    if c.code == 401 {
        ctx.send(Msg::Status {
            ok: false,
            text: "Login failed".into(),
        });
        ctx.say("Login failed (401).");
        return;
    }
    if c.code != 200 {
        ctx.send(Msg::Status {
            ok: false,
            text: format!("Error {}", c.code_text()),
        });
        ctx.say(format!("Cluster failed {}", body_or_code(&c)));
        if c.code == 0 {
            ctx.say("No HTTP response. Click Test TLS to check the handshake without sending the password.");
        }
        return;
    }
    let parsed = parse_json(&c.body).unwrap_or(Value::Null);
    let rec = first_record(&parsed).cloned().unwrap_or(Value::Null);
    let or_q = |k: &str| {
        Some(js(rec.get(k)))
            .filter(|x| !x.is_empty())
            .unwrap_or("?".into())
    };
    let (name, ver, uuid) = (or_q("clusterName"), or_q("icosVersion"), or_q("uuid"));
    ctx.send(Msg::Status {
        ok: true,
        text: format!("{name}  -  HyperCore {ver}"),
    });
    let pretty = serde_json::to_string_pretty(&parsed).unwrap_or(c.body.clone());
    ctx.send(Msg::ClusterText(format!(
        "Cluster name : {name}\nVersion      : {ver}\nUUID         : {uuid}\n\nRaw:\n{pretty}"
    )));
    ctx.say(format!("Cluster {name}  HyperCore {ver}"));
}

pub fn nodes(ctx: &Ctx) {
    ctx.say("--- Nodes");
    let r = ctx.client.get("/v1/Node");
    if r.code != 200 {
        ctx.say(format!("Nodes failed {}", body_or_code(&r)));
        return;
    }
    let nodes = as_list(parse_json(&r.body).as_ref());
    let mut lines = vec![format!("Nodes ({}):", nodes.len()), String::new()];
    for n in &nodes {
        lines.push(format!(
            "  lanIP={:<16}  peerIP={:<16}  status={:<10}  disposition={}",
            js(n.get("lanIP")),
            js(n.get("peerIP")),
            js(n.get("networkStatus")),
            js(n.get("currentDisposition"))
        ));
        let uuid = js(n.get("uuid"));
        if !uuid.is_empty() {
            lines.push(format!("    uuid={uuid}"));
        }
    }
    ctx.send(Msg::ClusterText(lines.join("\n")));
    ctx.say(format!("Loaded {} node(s).", nodes.len()));
}

pub fn update_status(ctx: &Ctx) {
    ctx.say("--- Update status");
    let r = ctx.client.get("/update/update_status.json");
    if r.code == 404 {
        ctx.send(Msg::ClusterText(
            "Update status: never updated / endpoint returned 404.\nTreat as unknown - fail closed for writes during upgrades.".into(),
        ));
        ctx.say("Update status 404 (never updated or unavailable).");
        return;
    }
    if r.code != 200 {
        ctx.say(format!("Update status failed {}", body_or_code(&r)));
        return;
    }
    let u = parse_json(&r.body).unwrap_or(Value::Null);
    let pick = |a: &str, b: &str| {
        Some(js(u.get(a).and_then(|x| x.get(b))))
            .filter(|x| !x.is_empty())
            .unwrap_or("(absent)".into())
    };
    let prep = pick("prepareStatus", "state");
    let master = pick("updateStatus", "masterState");
    let idle = prep == "COMPLETE" && master == "COMPLETE";
    ctx.send(Msg::ClusterText(format!(
        "prepareStatus.state      : {prep}\nupdateStatus.masterState : {master}\nIdle for writes          : {idle}\n\nRaw:\n{}",
        r.body
    )));
    ctx.say(format!("Update prepare={prep} master={master} idle={idle}"));
}

// ---------- TLS test ----------

pub fn tls_test(ctx: &Ctx) {
    let host = ctx.client.host().to_string();
    ctx.say(format!("--- Test TLS {host}"));
    ctx.say(
        "No credentials are sent. TLS is rustls (built in), so TLS 1.3 works on Windows 10 too.",
    );
    match http::probe_tls13(&host) {
        Ok(t) => ctx.say(format!("TLS 1.3 only: connected ({t})")),
        Err(e) => ctx.say(format!("TLS 1.3 only: failed: {}", public_error(&e))),
    }
    match http::probe_tls12(&host) {
        Ok(t) => ctx.say(format!("TLS 1.2 only: connected ({t})")),
        Err(e) => ctx.say(format!("TLS 1.2 only: failed: {}", public_error(&e))),
    }
    let anon = Client::anonymous(&host);
    let r = anon.request(
        "GET",
        &format!("https://{host}/"),
        "",
        Duration::from_secs(20),
    );
    if r.code == 0 {
        ctx.say(format!("HTTPS GET /: no response: {}", r.body));
        ctx.say("TLS 1.0 and 1.1 are not offered. HyperCore 9.6+ speaks TLS 1.2 or 1.3.");
    } else {
        ctx.say(format!(
            "HTTPS GET /: HTTP {} (TLS works; Connect will use it)",
            r.code
        ));
    }
}

// ---------- VMs ----------

pub fn vms(ctx: &Ctx) {
    ctx.say("--- VMs");
    let r = ctx.client.get("/v1/VirDomain");
    if r.code == 401 {
        ctx.send(Msg::Status {
            ok: false,
            text: "Login failed".into(),
        });
        ctx.say("Login failed (401).");
        return;
    }
    if r.code != 200 {
        ctx.say(format!("VMs failed {}", body_or_code(&r)));
        return;
    }
    let mut list = as_list(parse_json(&r.body).as_ref());
    list.sort_by_key(|v| js(v.get("name")).to_lowercase());
    ctx.say(format!("Loaded {} VM(s).", list.len()));
    ctx.send(Msg::Vms(list));
}

pub fn vm_action(ctx: &Ctx, uuid: &str, name: &str, action: &str) {
    ctx.say(format!("--- VM {action}  {name}"));
    let body = json!([{ "virDomainUUID": uuid, "actionType": action }]).to_string();
    let r = ctx.client.request(
        "POST",
        "/v1/VirDomain/action",
        &body,
        Duration::from_secs(60),
    );
    if r.code != 200 && r.code != 201 {
        ctx.say(format!("Action failed {}", body_or_code(&r)));
        return;
    }
    wait_task(ctx, &task_tag(&r.body));
    vms(ctx);
}

pub fn vm_snapshot(ctx: &Ctx, uuid: &str, name: &str) {
    let label = format!(
        "API toolkit {}",
        chrono::Local::now().format("%Y-%m-%dT%H:%M:%S")
    );
    ctx.say(format!("--- Snapshot {name}"));
    let body = json!({ "domainUUID": uuid, "label": label }).to_string();
    let r = ctx.client.request(
        "POST",
        "/v1/VirDomainSnapshot",
        &body,
        Duration::from_secs(60),
    );
    if r.code != 200 && r.code != 201 {
        ctx.say(format!("Snapshot failed {}", body_or_code(&r)));
        return;
    }
    wait_task(ctx, &task_tag(&r.body));
    let created = parse_json(&r.body)
        .map(|v| js(v.get("createdUUID")))
        .unwrap_or_default();
    ctx.say(format!("Snapshot created: {created}"));
}

// ---------- Snapshots ----------

pub fn snapshots(ctx: &Ctx, vm_names: &HashMap<String, String>) {
    ctx.say("--- Snapshots");
    let r = ctx.client.get("/v1/VirDomainSnapshot");
    if r.code != 200 {
        ctx.say(format!("Snapshots failed {}", body_or_code(&r)));
        return;
    }
    let mut list = as_list(parse_json(&r.body).as_ref());
    list.sort_by(|a, b| {
        crate::util::num(b.get("timestamp"))
            .partial_cmp(&crate::util::num(a.get("timestamp")))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let rows: Vec<[String; 5]> = list
        .iter()
        .map(|s| {
            let dom = js(s.get("domainUUID"));
            let ts = crate::util::num(s.get("timestamp")) as i64;
            let when = chrono::DateTime::from_timestamp(ts, 0)
                .map(|d| {
                    d.with_timezone(&chrono::Local)
                        .format("%Y-%m-%d %H:%M:%S")
                        .to_string()
                })
                .unwrap_or_else(|| js(s.get("timestamp")));
            [
                vm_names.get(&dom).cloned().unwrap_or(dom.clone()),
                js(s.get("label")),
                when,
                js(s.get("uuid")),
                dom,
            ]
        })
        .collect();
    ctx.say(format!("Loaded {} snapshot(s).", rows.len()));
    ctx.send(Msg::Snapshots(rows));
}

pub fn delete_snapshot(ctx: &Ctx, uuid: &str, vm_names: &HashMap<String, String>) {
    ctx.say(format!("--- Delete snapshot {uuid}"));
    let r = ctx.client.request(
        "DELETE",
        &format!("/v1/VirDomainSnapshot/{uuid}"),
        "",
        Duration::from_secs(60),
    );
    if !matches!(r.code, 200 | 201 | 204) {
        ctx.say(format!("Delete failed {}", body_or_code(&r)));
        return;
    }
    wait_task(ctx, &task_tag(&r.body));
    snapshots(ctx, vm_names);
}

// ---------- SNMP ----------

fn snmp_line(ctx: &Ctx, t: String) {
    ctx.send(Msg::SnmpLine(t.clone()));
    ctx.say(t);
}

/// Some(true) = SNMP looks enabled, Some(false) = not enabled, None = could not tell.
fn snmp_status(ctx: &Ctx) -> Option<bool> {
    let c = ctx.client.get("/v1/Cluster");
    if c.code == 401 {
        snmp_line(
            ctx,
            "Login failed (401). Check the login and password.".into(),
        );
        return None;
    }
    if c.code != 200 {
        snmp_line(
            ctx,
            format!("Could not reach the cluster {}", body_or_code(&c)),
        );
        return None;
    }
    let parsed = parse_json(&c.body).unwrap_or(Value::Null);
    let rec = first_record(&parsed).cloned().unwrap_or(Value::Null);
    let ver = Some(js(rec.get("icosVersion")))
        .filter(|x| !x.is_empty())
        .unwrap_or("unknown".into());
    let name = js(rec.get("clusterName"));
    snmp_line(ctx, format!("Cluster {name}  HyperCore {ver}"));
    ctx.send(Msg::Status {
        ok: true,
        text: format!("{name}  -  HyperCore {ver}"),
    });
    let s = ctx.client.get("/v2/SNMPConfig");
    if s.code == 404 {
        snmp_line(
            ctx,
            "This cluster has no SNMP API. It needs HyperCore 9.7.1 or newer.".into(),
        );
        return None;
    }
    if s.code != 200 {
        snmp_line(ctx, format!("SNMP status failed {}", body_or_code(&s)));
        return None;
    }
    // The status response can include configured community names. Show it in the
    // SNMP tab only; the shared log and log file get a redacted copy.
    let _ = ctx
        .tx
        .send(Msg::SnmpLine(format!("SNMP status: {}", s.body)));
    ctx.say(format!("SNMP status: {}", public_error(&s.body)));
    let body = s.body.trim();
    let empty = regex::Regex::new(r"^\[\s*\]$").unwrap().is_match(body);
    let off = regex::Regex::new(r"(?i)not enabled|disabled")
        .unwrap()
        .is_match(body);
    Some(!empty && !off)
}

pub fn snmp_check(ctx: &Ctx) {
    snmp_line(ctx, format!("--- Check {}", ctx.client.host()));
    let _ = snmp_status(ctx);
}

pub fn snmp_enable(ctx: &Ctx, community: &str, force: bool) {
    snmp_line(ctx, format!("--- Enable on {}", ctx.client.host()));
    if !force {
        match snmp_status(ctx) {
            None => return,
            Some(true) => {
                ctx.send(Msg::SnmpAskAlreadyOn);
                return;
            }
            Some(false) => {}
        }
    }
    let body = json!({ "communityName": community }).to_string();
    let r = ctx
        .client
        .request("POST", "/v2/SNMPConfig", &body, Duration::from_secs(60));
    if r.code != 200 {
        snmp_line(ctx, format!("Enable failed {}", body_or_code(&r)));
        return;
    }
    snmp_line(ctx, "Enable sent.".into());
    wait_task(ctx, &task_tag(&r.body));
    let _ = snmp_status(ctx);
}

// ---------- Alerts ----------

pub fn conditions(ctx: &Ctx) {
    ctx.say("--- Conditions");
    let r = ctx.client.get("/v1/Condition");
    if r.code != 200 {
        ctx.say(format!("Conditions failed {}", body_or_code(&r)));
        return;
    }
    let items = as_list(parse_json(&r.body).as_ref());
    let mut set_count = 0;
    let rows: Vec<[String; 5]> = items
        .iter()
        .map(|c| {
            let is_set = match c.get("value") {
                None | Some(Value::Null) => false,
                Some(Value::Bool(b)) => *b,
                Some(v) => {
                    let t = js(Some(v));
                    t.to_lowercase().starts_with("true") || t.ends_with('1')
                }
            };
            if is_set {
                set_count += 1;
            }
            let mut msg = js(c.get("formattedMessage"));
            if msg.is_empty() {
                msg = js(c.get("message"));
            }
            [
                js(c.get("severity")),
                if is_set { "True" } else { "False" }.into(),
                js(c.get("alertType")),
                msg,
                js(c.get("uuid")),
            ]
        })
        .collect();
    let summary = format!("{} condition(s), {set_count} set", items.len());
    ctx.say(format!("Loaded {summary}."));
    ctx.send(Msg::Conditions(rows, summary));
}

// ---------- Settings ----------

pub fn settings(ctx: &Ctx, title: &str, path: &str) {
    ctx.say(format!("--- {title}"));
    let r = ctx.client.get(path);
    if r.code != 200 {
        ctx.say(format!("{title} failed {}", body_or_code(&r)));
        ctx.send(Msg::Settings(r.body));
        return;
    }
    let text = parse_json(&r.body)
        .and_then(|v| serde_json::to_string_pretty(&v).ok())
        .unwrap_or(r.body);
    ctx.send(Msg::Settings(text));
    ctx.say(format!("{title} loaded."));
}

pub fn time_settings(ctx: &Ctx) {
    ctx.say("--- Time / NTP");
    let pretty = |r: &http::Response| {
        parse_json(&r.body)
            .and_then(|v| serde_json::to_string_pretty(&v).ok())
            .unwrap_or(r.body.clone())
    };
    let tz = ctx.client.get("/v1/TimeZone");
    let ts = ctx.client.get("/v1/TimeSource");
    ctx.send(Msg::Settings(format!(
        "=== TimeZone ({}) ===\n{}\n\n=== TimeSource / NTP ({}) ===\n{}",
        tz.code_text(),
        pretty(&tz),
        ts.code_text(),
        pretty(&ts)
    )));
    ctx.say("Time settings loaded.");
}

// ---------- API explorer ----------

pub fn api_send(ctx: &Ctx, method: &str, path: &str, body: &str) {
    ctx.say(format!("--- {method} {path}"));
    let body = if matches!(method, "POST" | "PATCH" | "PUT") {
        body
    } else {
        ""
    };
    let r = ctx
        .client
        .request(method, path, body, Duration::from_secs(60));
    let shown = parse_json(&r.body)
        .and_then(|v| serde_json::to_string_pretty(&v).ok())
        .unwrap_or(r.body.clone());
    ctx.send(Msg::ApiOut(format!("HTTP {}\n\n{shown}", r.code_text())));
    if method != "GET" && r.ok() {
        wait_task(ctx, &task_tag(&r.body));
    }
    ctx.say(format!("{method} {path} -> {}", r.code_text()));
}

// ---------- SuperAudit ----------

struct Call {
    ok: bool,
    items: Vec<Value>,
    note: String,
}

fn sa_get(ctx: &Ctx, label: &str, path: &str) -> Call {
    ctx.say(format!("GET {path}"));
    let r = ctx
        .client
        .request("GET", path, "", Duration::from_secs(120));
    if r.ok() {
        let trimmed = r.body.trim();
        return match parse_json(&r.body) {
            Some(v) => Call {
                ok: true,
                items: as_list(Some(&v))
                    .into_iter()
                    .filter(|x| !x.is_null())
                    .collect(),
                note: String::new(),
            },
            None if trimmed.is_empty() || trimmed == "[]" || trimmed == "null" => Call {
                ok: true,
                items: Vec::new(),
                note: String::new(),
            },
            None => {
                let note = format!("{label} skipped. HTTP {} body was not JSON. {path}", r.code);
                ctx.say(&note);
                Call {
                    ok: false,
                    items: Vec::new(),
                    note,
                }
            }
        };
    }
    let note = match r.code {
        0 => format!("{label} skipped. {} {path}", public_error(&r.body)),
        401 | 403 => format!(
            "{label} skipped (HTTP {}). Check the login and password. {path}",
            r.code
        ),
        c => format!("{label} skipped (HTTP {c}). {path}"),
    };
    ctx.say(&note);
    Call {
        ok: false,
        items: Vec::new(),
        note,
    }
}

pub fn superaudit(ctx: &Ctx, folder: PathBuf) {
    let started = Instant::now();
    ctx.say(
        "SuperAudit started. Read-only GET. The password is not written to the log or the report.",
    );
    let mut input = audit::Input {
        tool_version: env!("CARGO_PKG_VERSION").into(),
        ..Default::default()
    };

    let cluster = sa_get(ctx, "Cluster", RequestPaths::CLUSTER);
    if cluster.ok {
        input.cluster = cluster.items.into_iter().next();
    } else {
        input.notes.push(cluster.note);
        input.skipped.push("Cluster".into());
    }
    let nodes = sa_get(ctx, "Nodes", RequestPaths::NODES);
    if nodes.ok {
        input.nodes = nodes.items;
    } else {
        input.notes.push(nodes.note);
        input.skipped.push("Nodes".into());
    }
    let vms = sa_get(ctx, "VMs", RequestPaths::VMS);
    if vms.ok {
        input.vms = vms.items;
    } else {
        input.notes.push(vms.note);
        input.skipped.push("VMs".into());
    }

    let node_has_drives = |n: &Value| !as_list(n.get("drives")).is_empty();
    let need_drives = !nodes.ok || input.nodes.iter().any(|n| !node_has_drives(n));
    if need_drives {
        let d = sa_get(ctx, "Drives", RequestPaths::DRIVES);
        if d.ok {
            input.extra_drives = d.items;
            if nodes.ok {
                input.notes.push(format!(
                    "Node records did not include drives. Drive rows use {}.",
                    RequestPaths::DRIVES
                ));
            }
        } else {
            input.notes.push(d.note);
            if !input.nodes.iter().any(node_has_drives) {
                input.skipped.push("Drives".into());
            }
        }
    }

    let repl = sa_get(ctx, "Replication", RequestPaths::REPLICATION);
    if repl.ok {
        input.replication = repl.items;
    } else {
        input.notes.push(repl.note);
    }
    let sched = sa_get(ctx, "Snapshot schedules", RequestPaths::SCHEDULES);
    if sched.ok {
        input.schedules = sched.items;
    } else {
        input.notes.push(sched.note);
    }
    let isos = sa_get(ctx, "ISOs", RequestPaths::ISOS);
    if isos.ok {
        input.isos = isos.items;
    } else {
        input.notes.push(isos.note);
        input.skipped.push("ISOs".into());
    }
    let cf = sa_get(ctx, "Condition filter", RequestPaths::CONDITION_FILTER);
    if cf.ok {
        input.conditions = cf.items;
    } else {
        input.notes.push(cf.note);
        let all = sa_get(ctx, "Conditions", RequestPaths::CONDITIONS);
        if all.ok {
            input.conditions = all.items;
            input.notes.push(format!(
                "Condition filter skipped. Used {}.",
                RequestPaths::CONDITIONS
            ));
        } else {
            input.notes.push(all.note);
            input.skipped.push("Conditions".into());
        }
    }

    ctx.say("Building SuperAudit report. A skipped endpoint does not stop the rest of the audit.");
    input.collected_at = chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
    input.elapsed_seconds = started.elapsed().as_secs_f64();
    let report = audit::build(&input);
    match std::fs::create_dir_all(&folder).and_then(|_| audit::export(&report, &folder, "")) {
        Ok(saved) => {
            ctx.say(format!("SuperAudit wrote {}", saved.html_path.display()));
            ctx.say(format!(
                "Warnings: {}. Compliance score: {}.",
                report.flat_warnings.len(),
                report.compliance_score
            ));
            ctx.send(Msg::Audit {
                text: format!(
                    "{}\n\nReport: {}",
                    report.summary_text.replace("\r\n", "\n"),
                    saved.html_path.display()
                ),
                html: Some(saved.html_path),
            });
        }
        Err(e) => {
            let msg = format!("SuperAudit failed to write the report: {e}");
            ctx.say(&msg);
            ctx.send(Msg::Audit {
                text: msg,
                html: None,
            });
        }
    }
}

/// End-to-end against a live (or mock) cluster. Read-only: GET requests and TLS
/// handshakes only. Skipped unless SCALE_TEST_HOST, SCALE_TEST_USER and
/// SCALE_TEST_PASS are set.
#[cfg(test)]
mod live {
    use super::*;
    use std::sync::mpsc::channel;

    fn ctx() -> Option<(Ctx, std::sync::mpsc::Receiver<Msg>)> {
        let host = std::env::var("SCALE_TEST_HOST").ok()?;
        let user = std::env::var("SCALE_TEST_USER").ok()?;
        let pass = std::env::var("SCALE_TEST_PASS").ok()?;
        let (tx, rx) = channel();
        Some((
            Ctx {
                tx,
                repaint: eframe::egui::Context::default(),
                client: Client::new(&host, &user, &pass),
            },
            rx,
        ))
    }

    fn logs(rx: &std::sync::mpsc::Receiver<Msg>) -> Vec<String> {
        rx.try_iter()
            .filter_map(|m| match m {
                Msg::Log(t)
                | Msg::ClusterText(t)
                | Msg::SnmpLine(t)
                | Msg::Audit { text: t, .. } => Some(t),
                Msg::Status { text, .. } => Some(format!("STATUS {text}")),
                Msg::Vms(v) => Some(format!("VMS {}", v.len())),
                Msg::Snapshots(s) => Some(format!("SNAPS {}", s.len())),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn live_cluster_round_trip() {
        let Some((c, rx)) = ctx() else { return };
        tls_test(&c);
        cluster_info(&c);
        vms(&c);
        snapshots(&c, &HashMap::new());
        snmp_check(&c);
        let dir = std::env::temp_dir().join("sa-live");
        superaudit(&c, dir.clone());
        let out = logs(&rx);
        for l in &out {
            println!("{l}");
        }
        let all = out.join("\n");
        assert!(all.contains("TLS 1.3 only: connected"));
        assert!(all.contains("STATUS Lab Cluster"));
        assert!(all.contains("VMS 2"));
        assert!(all.contains("SuperAudit wrote"));
        assert!(!all.contains("YWRtaW46cHc"), "auth token leaked into logs");
        let _ = std::fs::remove_dir_all(dir);
    }
}
