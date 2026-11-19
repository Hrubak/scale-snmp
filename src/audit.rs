//! SuperAudit report. Read-only. These functions never see the password or the
//! Authorization header.
//!
//! Data collected and the report columns follow Scale Computing's SuperAudit example:
//! https://github.com/ScaleComputing/RestAPIExamples/tree/master/specific_task/superaudit
//! (Scale Computing Support Team). That repository does not publish a license file.
//! This module reimplements the one-time GET audit in Rust. It does not copy the
//! Python source.

use crate::util::{as_list, group_thousands, html_text, js, num, round_even, truthy};
use regex::Regex;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

pub type Row = Vec<String>;

/// Every path SuperAudit requests. Keep this list complete.
pub struct RequestPaths;
impl RequestPaths {
    pub const CLUSTER: &'static str = "/rest/v1/Cluster";
    pub const NODES: &'static str = "/rest/v1/Node";
    pub const VMS: &'static str = "/rest/v1/VirDomain";
    pub const DRIVES: &'static str = "/rest/v1/Drive";
    pub const REPLICATION: &'static str = "/rest/v1/RemoteClusterConnection";
    pub const SCHEDULES: &'static str = "/rest/v1/VirDomainSnapshotSchedule";
    pub const ISOS: &'static str = "/rest/v1/ISO";
    pub const CONDITION_FILTER: &'static str = "/rest/v1/Condition/filter?includeSet=true";
    pub const CONDITIONS: &'static str = "/rest/v1/Condition";
    #[allow(dead_code)]
    pub const ALL: [&'static str; 9] = [
        Self::CLUSTER,
        Self::NODES,
        Self::VMS,
        Self::DRIVES,
        Self::REPLICATION,
        Self::SCHEDULES,
        Self::ISOS,
        Self::CONDITION_FILTER,
        Self::CONDITIONS,
    ];
}

#[derive(Default)]
pub struct Input {
    pub cluster: Option<Value>,
    pub nodes: Vec<Value>,
    pub vms: Vec<Value>,
    pub replication: Vec<Value>,
    pub schedules: Vec<Value>,
    pub isos: Vec<Value>,
    pub conditions: Vec<Value>,
    pub extra_drives: Vec<Value>,
    pub notes: Vec<String>,
    pub skipped: Vec<String>,
    pub collected_at: String,
    pub elapsed_seconds: f64,
    pub tool_version: String,
}

pub struct Table {
    pub caption: &'static str,
    pub file_suffix: &'static str,
    pub headers: Vec<String>,
    pub rows: Vec<Row>,
}

#[allow(dead_code)]
pub struct Report {
    pub cluster_name: String,
    pub file_stem: String,
    pub vms: Table,
    pub nodes: Table,
    pub drives: Table,
    pub isos: Table,
    pub warnings: Table,
    pub compliance: Table,
    pub capacity: Table,
    pub conditions: Table,
    pub flat_warnings: Vec<String>,
    pub compliance_score: String,
    pub elapsed_text: String,
    pub summary_text: String,
    pub html: String,
}

// ---------- formatting helpers ----------

fn prop<'a>(obj: &'a Value, name: &str) -> Option<&'a Value> {
    obj.as_object().and_then(|o| o.get(name))
}

fn has(obj: &Value, name: &str) -> bool {
    obj.as_object()
        .map(|o| o.contains_key(name))
        .unwrap_or(false)
}

fn s(obj: &Value, name: &str) -> String {
    js(prop(obj, name))
}

/// bytes / divisor, rounded half-even, at least one decimal kept ("100.0", "0.5").
fn round_string(bytes: Option<&Value>, divisor: f64, digits: u32) -> String {
    let n = num(bytes) / divisor;
    let r = round_even(n, digits);
    let mut text = format!("{:.*}", digits as usize, r);
    while text.contains('.') && text.ends_with('0') && !text.ends_with(".0") {
        text.pop();
    }
    text
}

fn memory_gb(bytes: Option<&Value>) -> String {
    let b = num(bytes);
    if b == 0.0 {
        return "0".into();
    }
    let r = round_even(b / 1e9, 3);
    if r.fract() == 0.0 {
        return format!("{}", r as i64);
    }
    let t = format!("{r:.3}");
    t.trim_end_matches('0').trim_end_matches('.').to_string()
}

fn fixed2(n: f64) -> String {
    format!("{n:.2}")
}

fn num1(n: f64) -> String {
    group_thousands(&format!("{n:.1}"))
}

fn pct1(n: f64) -> String {
    format!("{:.1}", round_even(n, 1))
}

fn pct0(n: f64) -> String {
    format!("{}", round_even(n, 0) as i64)
}

pub fn format_elapsed(seconds: f64) -> String {
    let secs = seconds.max(0.0);
    if secs < 60.0 {
        return format!("{}s", secs.floor() as i64);
    }
    if secs < 3600.0 {
        return format!(
            "{}m {}s",
            (secs / 60.0).floor() as i64,
            (secs % 60.0).floor() as i64
        );
    }
    format!(
        "{}h {}m",
        (secs / 3600.0).floor() as i64,
        ((secs % 3600.0) / 60.0).floor() as i64
    )
}

fn ssd_tier(v: Option<&Value>) -> String {
    let key = num(v).trunc() as i64;
    let label = match key {
        0 => "0 - OFF (0)",
        1 => "1 - MINIMAL (1)",
        2 => "2 - VERY LOW (2)",
        4 => "3 - LOW (4)",
        8 => "4 - NORMAL (8)",
        16 => "5 - HIGH (16)",
        32 => "6 - VERY HIGH (32)",
        64 => "7 - EXTREME (64)",
        128 => "8 - ABSURD (128)",
        256 => "9 - HYPERSPEED (256)",
        1024 => "10 - LUDICROUS SPEED (1024)",
        10240 => "11 - THESE GO TO 11 (10240)",
        _ => return key.to_string(),
    };
    label.to_string()
}

fn clear_ipv6(ip: &str) -> &str {
    match ip.find('%') {
        Some(i) => &ip[..i],
        None => ip,
    }
}

pub fn file_stem(name: &str) -> String {
    let re = Regex::new(r"[^\w\-.]").unwrap();
    let multi = Regex::new(r"_+").unwrap();
    let a = re.replace_all(name, "_");
    let b = multi.replace_all(&a, "_");
    let stem = b.trim_matches('_').to_lowercase();
    if stem.is_empty() {
        "cluster".into()
    } else {
        stem
    }
}

fn is_true_text(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        other => {
            let t = js(Some(other));
            t == "True" || t == "true"
        }
    }
}

fn tag_text(vm: &Value) -> String {
    match prop(vm, "tags") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(t)) => t.clone(),
        Some(other) => as_list(Some(other))
            .iter()
            .map(|t| js(Some(t)))
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join("/"),
    }
}

fn vm_type(vm: &Value) -> &'static str {
    let name = s(vm, "name").to_lowercase();
    let tags = tag_text(vm).to_lowercase();
    if truthy(prop(vm, "replicationSourceVirDomainUUID")) {
        return "VM REPLICA";
    }
    if name.contains("template") || name.contains("tmpl") {
        return "TEMPLATE";
    }
    if !tags.is_empty() {
        if tags.contains("template") {
            return "TEMPLATE";
        }
        if tags.contains("test") {
            return "TEST VM";
        }
        if tags.contains("production") || tags.contains("prod") {
            return "PRODUCTION VM";
        }
        if tags.contains("dev") {
            return "DEV VM";
        }
    }
    "VM"
}

fn ha_policy(vm: &Value) -> &'static str {
    let ha = match prop(vm, "affinityStrategy") {
        Some(v @ Value::Object(_)) => v,
        _ => return "",
    };
    // HyperCore returns strictAffinity as a boolean. The example compares it to the
    // string STRICT, which never matches, so a boolean true is treated as STRICT.
    if let Some(strict) = prop(ha, "strictAffinity") {
        if is_true_text(strict) || js(Some(strict)) == "STRICT" {
            return "STRICT";
        }
    }
    if truthy(prop(ha, "preferredNodeUUID")) {
        return "PREFERRED";
    }
    ""
}

fn boot_order(vm: &Value) -> String {
    as_list(prop(vm, "bootDevices"))
        .iter()
        .filter_map(|d| match d {
            Value::Null => None,
            Value::String(t) if t.is_empty() => None,
            Value::String(t) => Some(t.clone()),
            other => {
                let k = match prop(other, "type") {
                    Some(t) => js(Some(t)),
                    None => js(Some(other)),
                };
                (!k.is_empty()).then_some(k)
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn base_name(path: &str) -> String {
    let n = path.replace('\\', "/");
    match n.rfind('/') {
        Some(i) if i < n.len() - 1 => n[i + 1..].to_string(),
        _ => n,
    }
}

/// PowerShell `-match "^(?i)true|1$"`: starts with "true" (any case) or ends with "1".
fn matches_true(t: &str) -> bool {
    t.to_lowercase().starts_with("true") || t.ends_with('1')
}

fn condition_set(c: &Value) -> bool {
    match prop(c, "value") {
        None | Some(Value::Null) => true,
        Some(Value::Bool(b)) => *b,
        Some(other) => matches_true(&js(Some(other))),
    }
}

fn bool_default_true(obj: &Value, name: &str) -> bool {
    match prop(obj, name) {
        None | Some(Value::Null) => true,
        Some(Value::Bool(b)) => *b,
        Some(other) => {
            let t = js(Some(other));
            !(t.to_lowercase().starts_with("false") || t.ends_with('0'))
        }
    }
}

fn recommendation(warning: &str, severity: &str) -> &'static str {
    let l = warning.to_lowercase();
    if l.contains("no snapshots") {
        return "Configure snapshot schedule immediately. Snapshots are critical for data protection and recovery.";
    }
    if l.contains("ha policy") {
        return "Configure High Availability policy to ensure VM redundancy across nodes.";
    }
    if l.contains("no replication") {
        return "Consider configuring replication for disaster recovery and business continuity.";
    }
    if l.contains("disk") && l.contains("full") {
        if severity == "CRITICAL" {
            return "URGENT: Free up disk space or expand storage immediately to prevent VM failures.";
        }
        return "Monitor disk usage closely and plan for storage expansion.";
    }
    if l.contains("cpu") {
        if severity == "CRITICAL" {
            return "URGENT: High CPU usage may impact VM performance. Migrate VMs to other nodes or add capacity.";
        }
        return "Monitor CPU usage and consider load balancing VMs across nodes.";
    }
    if l.contains("memory") {
        return "Monitor memory usage and consider adding memory to nodes or rebalancing VM placement.";
    }
    "Review and address this issue to maintain optimal cluster health."
}

#[derive(Default)]
struct Warnings {
    flat: Vec<String>,
    critical: Vec<String>,
    warning: Vec<String>,
    info: Vec<String>,
}

impl Warnings {
    fn add(&mut self, severity: &str, msg: String) {
        if !self.flat.contains(&msg) {
            self.flat.push(msg.clone());
        }
        let bucket = match severity {
            "CRITICAL" => &mut self.critical,
            "WARNING" => &mut self.warning,
            "INFO" => &mut self.info,
            _ => return,
        };
        if !bucket.contains(&msg) {
            bucket.push(msg);
        }
    }
}

fn merge_node_drives(nodes: &[Value], extras: &[Value]) -> Vec<Value> {
    nodes
        .iter()
        .map(|node| {
            let drives = as_list(prop(node, "drives"));
            if drives.is_empty() && !extras.is_empty() {
                let uuid = s(node, "uuid");
                let mine: Vec<Value> = extras
                    .iter()
                    .filter(|d| s(d, "nodeUUID") == uuid)
                    .cloned()
                    .collect();
                if !mine.is_empty() {
                    let mut copy = node.clone();
                    if let Some(o) = copy.as_object_mut() {
                        o.insert("drives".into(), Value::Array(mine));
                    }
                    return copy;
                }
            }
            node.clone()
        })
        .collect()
}

fn strs(items: &[&str]) -> Vec<String> {
    items.iter().map(|x| x.to_string()).collect()
}

pub fn csv(headers: &[String], rows: &[Row]) -> String {
    let q = |v: &str| format!("\"{}\"", v.replace('"', "\"\""));
    let mut out = headers.iter().map(|h| q(h)).collect::<Vec<_>>().join(",");
    out.push_str("\r\n");
    for row in rows {
        out.push_str(&row.iter().map(|c| q(c)).collect::<Vec<_>>().join(","));
        out.push_str("\r\n");
    }
    out
}

fn html_table(caption: &str, headers: &[String], rows: &[Row]) -> String {
    let mut sb = String::new();
    let _ = write!(
        sb,
        "<h2>{}</h2>\r\n<div class=\"sheet\"><table>\r\n<thead><tr>",
        html_text(caption)
    );
    for h in headers {
        let _ = write!(sb, "<th>{}</th>", html_text(h));
    }
    sb.push_str("</tr></thead>\r\n<tbody>\r\n");
    let colored = caption == "Warnings and Recommendations" || caption == "Compliance Report";
    for row in rows {
        sb.push_str("<tr>");
        for (i, cell) in row.iter().enumerate() {
            let class = if i == 0 && colored {
                match cell.as_str() {
                    "CRITICAL" | "FAIL" => " class=\"bad\"",
                    "WARNING" => " class=\"warn\"",
                    "INFO" | "N/A" => " class=\"info\"",
                    "PASS" => " class=\"good\"",
                    _ => "",
                }
            } else {
                ""
            };
            let _ = write!(sb, "<td{class}>{}</td>", html_text(cell));
        }
        sb.push_str("</tr>\r\n");
    }
    if rows.is_empty() {
        let _ = write!(
            sb,
            "<tr><td colspan=\"{}\">None</td></tr>\r\n",
            headers.len().max(1)
        );
    }
    sb.push_str("</tbody></table></div>\r\n");
    sb
}

// ---------- report ----------

pub fn build(input: &Input) -> Report {
    let nodes = merge_node_drives(&input.nodes, &input.extra_drives);
    let skip: HashSet<&str> = input.skipped.iter().map(|x| x.as_str()).collect();
    let empty = Value::Null;
    let cluster = input.cluster.as_ref().unwrap_or(&empty);

    let mut cluster_name = s(cluster, "clusterName");
    if cluster_name.is_empty() {
        cluster_name = "Unknown".into();
    }
    let mut company = s(cluster, "companyName");
    if company.is_empty() {
        company = "Unknown".into();
    }
    let mut icos = s(cluster, "icosVersion");
    if icos.is_empty() {
        if let Some(n) = nodes.first() {
            icos = s(n, "icosVersion");
        }
    }
    if icos.is_empty() {
        icos = "Unknown".into();
    }
    let collected_at = if input.collected_at.is_empty() {
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string()
    } else {
        input.collected_at.clone()
    };
    let tool_version = if input.tool_version.is_empty() {
        env!("CARGO_PKG_VERSION").to_string()
    } else {
        input.tool_version.clone()
    };

    let node_by_uuid: HashMap<String, &Value> = nodes
        .iter()
        .filter_map(|n| {
            let id = s(n, "uuid");
            (!id.is_empty()).then_some((id, n))
        })
        .collect();
    let repl_by_uuid: HashMap<String, String> = input
        .replication
        .iter()
        .filter_map(|c| {
            let id = s(c, "uuid");
            (!id.is_empty()).then(|| (id, s(c, "remoteClusterName")))
        })
        .collect();
    let schedule_by_uuid: HashMap<String, String> = input
        .schedules
        .iter()
        .filter_map(|c| {
            let id = s(c, "uuid");
            (!id.is_empty()).then(|| (id, s(c, "name")))
        })
        .collect();

    let vm_headers = strs(&[
        "VM UUID",
        "Mem Alloc (GB)",
        "Type",
        "CPUs",
        "State",
        "Node",
        "Node CPU Load (%)",
        "Name",
        "Description",
        "Tags",
        "Boot Order",
        "Machine Type",
        "Operating System",
        "HA Policy",
        "Drive Type",
        "Mounted As",
        "Drive Size (GB)",
        "Used Size (GB)",
        "SSD Tier",
        "Cache Mode",
        "Disk Snapshots",
        "Snaps",
        "ISO Mounted",
        "VM IP Address",
        "VLANS",
        "MAC Addresses",
        "Adapter Types",
        "Connection Status",
        "Snapshot Schedule Plan",
        "Replication Partner",
    ]);
    let node_headers = strs(&[
        "Node IP",
        "Backplane IP",
        "CPU (cores/threads)",
        "Memory (GB)",
        "Storage Capacity (TB)",
        "Storage Used (TB)",
        "CPU Usage (%)",
        "Memory Usage (%)",
        "Network Status",
        "Disposition",
        "ICOS Version",
    ]);
    let drive_headers = strs(&[
        "Node IP",
        "Slot",
        "Serial Number",
        "Type",
        "Capacity (GB)",
        "Used (GB)",
        "Usage (%)",
        "Temperature (\u{b0}C)",
        "Max Temperature (\u{b0}C)",
        "Temperature Threshold (\u{b0}C)",
        "Health Status",
        "Reallocated Sectors",
        "Error Count",
        "Disposition",
    ]);

    let mut node_rows = Vec::new();
    let mut drive_rows = Vec::new();
    let (mut storage_cap_gb, mut storage_used_gb) = (0f64, 0f64);
    let (mut ssd, mut hdd, mut total_drives, mut healthy_drives, mut unhealthy_drives) =
        (0, 0, 0, 0, 0);
    let (mut online, mut offline) = (0, 0);
    let mut cpu_samples = Vec::new();

    for node in &nodes {
        let lan = s(node, "lanIP");
        let cores = prop(node, "numCores")
            .map(|v| js(Some(v)))
            .filter(|x| !x.is_empty())
            .unwrap_or("0".into());
        let threads = prop(node, "numThreads")
            .map(|v| js(Some(v)))
            .filter(|x| !x.is_empty())
            .unwrap_or("0".into());
        let drives = as_list(prop(node, "drives"));
        let used_bytes: f64 = drives
            .iter()
            .filter(|d| s(d, "currentDisposition") == "IN")
            .map(|d| num(prop(d, "usedBytes")))
            .sum();
        let cpu = num(prop(node, "cpuUsage"));
        let mem = num(prop(node, "memUsagePercentage"));
        let network_cell = if has(node, "networkStatus") {
            s(node, "networkStatus")
        } else {
            "Unknown".into()
        };
        let network_stat = if truthy(prop(node, "networkStatus")) {
            s(node, "networkStatus")
        } else {
            "ONLINE".into()
        };
        if network_stat == "ONLINE" {
            online += 1;
        } else {
            offline += 1;
        }
        let mut disposition = s(node, "currentDisposition");
        if disposition.is_empty() {
            disposition = "Unknown".into();
        }
        node_rows.push(vec![
            lan.clone(),
            s(node, "backplaneIP"),
            format!("{cores}/{threads}"),
            round_string(prop(node, "memSize"), 1e9, 2),
            round_string(prop(node, "capacity"), 1e12, 2),
            round_string(Some(&Value::from(used_bytes)), 1e12, 2),
            fixed2(cpu),
            fixed2(mem),
            network_cell,
            disposition,
            icos.clone(),
        ]);
        cpu_samples.push(cpu);

        for drive in drives.iter().filter(|d| !d.is_null()) {
            total_drives += 1;
            let dtype = s(drive, "type");
            if dtype == "SSD" {
                ssd += 1;
            } else {
                hdd += 1;
            }
            let healthy = bool_default_true(drive, "isHealthy");
            if healthy {
                healthy_drives += 1;
            } else {
                unhealthy_drives += 1;
            }
            let cap = num(prop(drive, "capacityBytes"));
            let used = num(prop(drive, "usedBytes"));
            if s(drive, "currentDisposition") == "IN" {
                storage_cap_gb += cap / 1073741824.0;
                storage_used_gb += used / 1073741824.0;
            }
            let usage = if cap > 0.0 { used / cap * 100.0 } else { 0.0 };
            let num_or0 = |k: &str| {
                prop(drive, k)
                    .filter(|v| !v.is_null())
                    .map(|v| js(Some(v)))
                    .unwrap_or("0".into())
            };
            let temp = num(prop(drive, "temperature"));
            let thresh = num(prop(drive, "temperatureThreshold"));
            let errors = num(prop(drive, "errorCount"));
            let realloc = num(prop(drive, "reallocatedSectors"));
            let health = if !healthy || errors > 100.0 {
                "Failed"
            } else if (temp > 0.0 && thresh > 0.0 && temp > thresh * 0.9) || realloc > 0.0 {
                "Warning"
            } else {
                "Healthy"
            };
            let mut ddisp = s(drive, "currentDisposition");
            if ddisp.is_empty() {
                ddisp = "Unknown".into();
            }
            drive_rows.push(vec![
                lan.clone(),
                s(drive, "slot"),
                s(drive, "serialNumber"),
                dtype,
                round_string(Some(&Value::from(cap)), 1e9, 2),
                round_string(Some(&Value::from(used)), 1e9, 2),
                fixed2(usage),
                num_or0("temperature"),
                num_or0("maxTemperature"),
                num_or0("temperatureThreshold"),
                health.into(),
                num_or0("reallocatedSectors"),
                num_or0("errorCount"),
                ddisp,
            ]);
        }
    }

    let mut warn = Warnings::default();
    let mut vm_rows = Vec::new();
    let (mut total_vms, mut running_vms, mut stopped_vms) = (0, 0, 0);
    let mut memory_sum = 0f64;
    let (mut with_snaps, mut without_snaps, mut running_with_snaps) = (0, 0, 0);
    let (mut prod, mut prod_ha, mut prod_repl) = (0, 0, 0);
    let (mut disk_count, mut disks_ok) = (0, 0);

    for vm in input.vms.iter().filter(|v| !v.is_null()) {
        let mut name = s(vm, "name");
        if name.is_empty() {
            name = "Unknown".into();
        }
        let cpu = prop(vm, "numVCPU")
            .map(|v| js(Some(v)))
            .filter(|x| !x.is_empty())
            .unwrap_or("0".into());
        let mut state = s(vm, "state");
        if state.is_empty() {
            state = "UNKNOWN".into();
        }
        let running = state == "RUNNING";
        let ha = ha_policy(vm);
        let vtype = vm_type(vm);
        let node_uuid = s(vm, "nodeUUID");
        let owner = node_by_uuid.get(&node_uuid);
        let node_lan = owner
            .map(|n| s(n, "lanIP"))
            .filter(|x| !x.is_empty())
            .unwrap_or("--".into());
        let node_cpu = match owner {
            Some(n) if running && has(n, "cpuUsage") => fixed2(num(prop(n, "cpuUsage"))),
            _ => "N/A".into(),
        };
        let num_snaps = as_list(prop(vm, "snapUUIDs")).len();
        let block_devs = as_list(prop(vm, "blockDevs"));
        let net_devs = as_list(prop(vm, "netDevs"));

        let (mut ips, mut vlans, mut macs, mut adapters, mut conns) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for net in net_devs.iter().filter(|n| !n.is_null()) {
            for ip in as_list(prop(net, "ipv4Addresses")) {
                let t = js(Some(&ip));
                if !t.is_empty() {
                    ips.push(t);
                }
            }
            for ip in as_list(prop(net, "ipv6Addresses")) {
                let t = js(Some(&ip));
                let c = clear_ipv6(&t);
                if !c.is_empty() {
                    ips.push(c.to_string());
                }
            }
            let vlan = s(net, "vlan");
            if !vlan.is_empty() && vlan != "0" {
                vlans.push(vlan);
            }
            let mut mac = s(net, "macAddress");
            if mac.is_empty() {
                mac = s(net, "mac");
            }
            if !mac.is_empty() {
                macs.push(mac);
            }
            let ad = s(net, "type");
            if !ad.is_empty() {
                adapters.push(ad);
            }
            if let Some(c) = prop(net, "connected") {
                conns.push(
                    if is_true_text(c) {
                        "Connected"
                    } else {
                        "Disconnected"
                    }
                    .to_string(),
                );
            }
        }
        let iso_names: Vec<String> = block_devs
            .iter()
            .filter(|b| matches!(s(b, "type").as_str(), "IDE_CDROM" | "VIRTIO_CDROM"))
            .map(|b| s(b, "path"))
            .filter(|p| p.to_lowercase().ends_with(".iso"))
            .map(|p| base_name(&p))
            .collect();
        let snap_plan = schedule_by_uuid
            .get(&s(vm, "snapshotScheduleUUID"))
            .cloned()
            .unwrap_or_default();
        let mut partner = repl_by_uuid
            .get(&s(vm, "remoteClusterConnectionUUID"))
            .cloned()
            .unwrap_or_default();
        if partner.is_empty() && truthy(prop(vm, "replicationSourceVirDomainUUID")) {
            partner = "Replicated (source unknown)".into();
        }

        let mem_text = memory_gb(prop(vm, "mem"));
        total_vms += 1;
        memory_sum += mem_text.parse::<f64>().unwrap_or(0.0);
        if running {
            running_vms += 1;
        } else {
            stopped_vms += 1;
        }
        if num_snaps > 0 {
            with_snaps += 1;
        } else {
            without_snaps += 1;
        }
        if running && num_snaps > 0 {
            running_with_snaps += 1;
        }
        let production = vtype == "PRODUCTION VM";
        if production {
            prod += 1;
            if !ha.is_empty() {
                prod_ha += 1;
            }
            if !partner.is_empty() {
                prod_repl += 1;
            }
        }

        if num_snaps == 0 && running {
            let sev = if production { "CRITICAL" } else { "WARNING" };
            warn.add(sev, format!("{name}: No snapshots configured (Running VM)"));
        }
        if ha.is_empty() && running && production {
            warn.add(
                "WARNING",
                format!("{name}: No HA policy configured (Production VM)"),
            );
        }
        if partner.is_empty() && production && running {
            warn.add(
                "INFO",
                format!("{name}: No replication configured (Production VM)"),
            );
        }
        if running && node_cpu != "N/A" {
            let v: f64 = node_cpu.parse().unwrap_or(0.0);
            if v > 90.0 {
                warn.add(
                    "CRITICAL",
                    format!("Node {node_lan}: Critical CPU usage ({}%)", pct1(v)),
                );
            } else if v > 80.0 {
                warn.add(
                    "WARNING",
                    format!("Node {node_lan}: High CPU usage ({}%)", pct1(v)),
                );
            }
        }

        let shared = vec![
            s(vm, "uuid"),
            mem_text,
            vtype.to_string(),
            cpu,
            state.clone(),
            node_lan,
            node_cpu,
            name.clone(),
            s(vm, "description"),
            tag_text(vm),
            boot_order(vm),
            s(vm, "machineType"),
            s(vm, "operatingSystem"),
            ha.to_string(),
        ];
        let tail = vec![
            num_snaps.to_string(),
            iso_names.join("/"),
            ips.join("/"),
            vlans.join("/"),
            macs.join("/"),
            adapters.join("/"),
            conns.join("/"),
            snap_plan,
            partner,
        ];
        let disks: Vec<&Value> = block_devs
            .iter()
            .filter(|b| {
                let t = s(b, "type");
                t.contains("DISK") && !t.contains("CDROM")
            })
            .collect();
        if disks.is_empty() {
            let mut row = shared.clone();
            row.extend(strs(&["", "", "0", "0", "", "", ""]));
            row.extend(tail.clone());
            vm_rows.push(row);
        }
        for bd in disks {
            let slot = s(bd, "slot");
            let mount = if slot.is_empty() || slot.to_lowercase().contains("cdrom") {
                "no".to_string()
            } else {
                slot.clone()
            };
            let size = round_string(prop(bd, "capacity"), 1e9, 2);
            let used = round_string(prop(bd, "allocation"), 1e9, 2);
            let snaps = match prop(bd, "disableSnapshotting") {
                Some(v) if is_true_text(v) => "Disabled",
                _ => "Enabled",
            };
            let mut row = shared.clone();
            row.extend(vec![
                s(bd, "type"),
                mount,
                size.clone(),
                used.clone(),
                ssd_tier(prop(bd, "tieringPriorityFactor")),
                s(bd, "cacheMode"),
                snaps.to_string(),
            ]);
            row.extend(tail.clone());
            vm_rows.push(row);
            let size_gb: f64 = size.parse().unwrap_or(0.0);
            let used_gb: f64 = used.parse().unwrap_or(0.0);
            if size_gb > 0.0 {
                disk_count += 1;
                let pct = used_gb / size_gb * 100.0;
                if pct <= 85.0 {
                    disks_ok += 1;
                }
                if pct > 95.0 {
                    warn.add(
                        "CRITICAL",
                        format!("{name}: Disk {slot} is {}% full", pct0(pct)),
                    );
                } else if pct > 85.0 {
                    warn.add(
                        "WARNING",
                        format!("{name}: Disk {slot} is {}% full", pct0(pct)),
                    );
                }
            }
        }
    }

    let mut iso_rows: Vec<Row> = input
        .isos
        .iter()
        .filter(|i| !i.is_null())
        .map(|iso| {
            let mounts = match prop(iso, "mounts") {
                None | Some(Value::Null) => "0".to_string(),
                Some(v @ (Value::String(_) | Value::Number(_))) => js(Some(v)),
                Some(other) => as_list(Some(other)).len().to_string(),
            };
            vec![
                s(iso, "name"),
                round_string(prop(iso, "size"), 1e9, 2),
                s(iso, "path"),
                mounts,
                if truthy(prop(iso, "readyForInsert")) {
                    "Yes"
                } else {
                    "No"
                }
                .into(),
            ]
        })
        .collect();
    iso_rows.sort_by_key(|r| r[0].to_lowercase());

    let condition_rows: Vec<Row> = input
        .conditions
        .iter()
        .filter(|c| !c.is_null() && condition_set(c))
        .map(|c| {
            let mut msg = s(c, "formattedMessage");
            if msg.is_empty() {
                msg = s(c, "message");
            }
            if msg.is_empty() {
                msg = s(c, "name");
            }
            vec![s(c, "severity"), s(c, "alertType"), msg, s(c, "uuid")]
        })
        .collect();

    let mut warning_rows = Vec::new();
    for (sev, list) in [
        ("CRITICAL", &warn.critical),
        ("WARNING", &warn.warning),
        ("INFO", &warn.info),
    ] {
        for m in list {
            warning_rows.push(vec![
                sev.to_string(),
                m.clone(),
                recommendation(m, sev).to_string(),
            ]);
        }
    }

    let nodes_normal = cpu_samples.iter().filter(|c| **c <= 80.0).count();
    let mut compliance_rows = Vec::new();
    let mut scores = Vec::new();
    let mut comp = |cat: &str, have: usize, total: usize, target: f64, detail: String| {
        if total == 0 {
            compliance_rows.push(vec![
                cat.into(),
                "n/a".into(),
                pct1(target),
                "N/A".into(),
                detail,
            ]);
            return;
        }
        let actual = have as f64 / total as f64 * 100.0;
        let status = if actual >= target { "PASS" } else { "FAIL" };
        compliance_rows.push(vec![
            cat.into(),
            pct1(actual),
            pct1(target),
            status.into(),
            detail,
        ]);
        scores.push(actual);
    };
    let running_count = running_vms;
    comp(
        "VMs with Snapshots (Running)",
        running_with_snaps,
        running_count,
        80.0,
        format!("{running_with_snaps} of {running_count} running VMs have snapshots"),
    );
    comp(
        "Production VMs with HA Policy",
        prod_ha,
        prod,
        70.0,
        format!("{prod_ha} of {prod} production VMs have an HA policy"),
    );
    comp(
        "Production VMs with Replication",
        prod_repl,
        prod,
        50.0,
        format!("{prod_repl} of {prod} production VMs have replication"),
    );
    comp(
        "Disks with Adequate Space",
        disks_ok,
        disk_count,
        90.0,
        format!("{disks_ok} of {disk_count} disks are at or below 85% used"),
    );
    comp(
        "Nodes with Normal CPU",
        nodes_normal,
        nodes.len(),
        80.0,
        format!(
            "{nodes_normal} of {} nodes are at or below 80% CPU",
            nodes.len()
        ),
    );
    let score = if scores.is_empty() {
        100.0
    } else {
        scores.iter().sum::<f64>() / scores.len() as f64
    };
    let score_text = pct1(score);

    let storage_pct = if storage_cap_gb > 0.0 {
        storage_used_gb / storage_cap_gb * 100.0
    } else {
        0.0
    };
    let cap_tb = num1(storage_cap_gb / 1000.0);
    let used_tb = num1(storage_used_gb / 1000.0);
    let free_tb = num1((storage_cap_gb - storage_used_gb) / 1000.0);
    let cap_rec = if storage_pct > 95.0 {
        "URGENT: Free up cluster disk space or expand storage immediately to prevent VM failures."
    } else if storage_pct > 85.0 {
        "Monitor cluster disk usage closely and plan for storage expansion."
    } else {
        "Storage capacity is within the normal range."
    };
    let drives_text = format!("{total_drives} ({ssd} SSD, {hdd} HDD)");
    let capacity_rows: Vec<Row> = vec![
        vec!["Storage allocated (TB)".into(), cap_tb.clone()],
        vec!["Storage used (TB)".into(), used_tb.clone()],
        vec!["Storage free (TB)".into(), free_tb],
        vec!["Storage used (%)".into(), pct1(storage_pct)],
        vec!["Storage free (%)".into(), pct1(100.0 - storage_pct)],
        vec!["Memory allocated (GB)".into(), num1(memory_sum)],
        vec!["Nodes".into(), nodes.len().to_string()],
        vec!["Drives".into(), drives_text.clone()],
        vec!["Healthy drives".into(), healthy_drives.to_string()],
        vec!["Unhealthy drives".into(), unhealthy_drives.to_string()],
        vec!["Recommendation".into(), cap_rec.into()],
        vec!["Forecast".into(), "Growth projections are not included. SuperAudit daemon mode stores history for forecasting; this audit is one read-only pass.".into()],
    ];

    let pct_of = |n: usize| {
        if total_vms > 0 {
            n as f64 / total_vms as f64 * 100.0
        } else {
            0.0
        }
    };
    let elapsed_text = format_elapsed(input.elapsed_seconds);
    if skip.contains("Cluster") {
        cluster_name = "skipped".into();
        company = "skipped".into();
        icos = "skipped".into();
    }

    let mut sm = String::new();
    let mut line = |t: String| {
        sm.push_str(&t);
        sm.push_str("\r\n");
    };
    line("SUPERAUDIT SUMMARY".into());
    line(format!("Generated: {collected_at}"));
    line(format!("Tool: Scale HyperCore API Toolkit {tool_version}"));
    line("Source: Scale Computing SuperAudit one-time audit (read-only GET)".into());
    line(String::new());
    line(format!("Cluster: {cluster_name}"));
    line(format!("Company: {company}"));
    line(format!("ICOS version: {icos}"));
    line(format!("Collection time: {elapsed_text}"));
    line(String::new());
    if skip.contains("VMs") {
        line("VMs processed: skipped".into());
    } else {
        line(format!("VMs processed: {total_vms}"));
        line(format!(
            "  Running: {running_vms} ({}%)",
            pct1(pct_of(running_vms))
        ));
        line(format!(
            "  Stopped: {stopped_vms} ({}%)",
            pct1(pct_of(stopped_vms))
        ));
        line(format!("Memory allocated: {} GB", num1(memory_sum)));
    }
    line(String::new());
    line(format!("Storage allocated: {cap_tb} TB"));
    line(format!(
        "Storage used: {used_tb} TB ({}%)",
        pct1(storage_pct)
    ));
    line(String::new());
    line(format!(
        "VMs with snapshots: {with_snaps} ({}%)",
        pct1(pct_of(with_snaps))
    ));
    line(format!("VMs without snapshots: {without_snaps}"));
    line(String::new());
    if skip.contains("Nodes") {
        line("Nodes: skipped".into());
    } else {
        line(format!(
            "Nodes: {} ({online} online, {offline} offline)",
            nodes.len()
        ));
    }
    if skip.contains("Drives") {
        line("Drives: skipped".into());
    } else {
        line(format!("Drives: {drives_text}"));
        line(format!("Healthy drives: {healthy_drives}"));
        line(format!("Unhealthy drives: {unhealthy_drives}"));
    }
    line(String::new());
    line(format!("Compliance score: {score_text}"));
    for c in &compliance_rows {
        line(format!(
            "  {}  {}: {}% (target {}%)",
            c[3], c[0], c[1], c[2]
        ));
    }
    line(String::new());
    line(format!("Capacity: {cap_rec}"));
    line(String::new());
    if warn.flat.is_empty() {
        line("Warnings: none".into());
    } else {
        line(format!("Warnings ({}):", warn.flat.len()));
        for m in &warn.flat {
            line(format!("  - {m}"));
        }
    }
    if !input.notes.is_empty() {
        line(String::new());
        line("Skipped or unavailable API calls:".into());
        for n in &input.notes {
            line(format!("  - {n}"));
        }
    }
    let summary_text = sm.trim_end().to_string();

    let tables = [
        (
            "vms",
            "VMs",
            Table {
                caption: "VM Inventory",
                file_suffix: "",
                headers: vm_headers,
                rows: vm_rows,
            },
        ),
        (
            "nodes",
            "Nodes",
            Table {
                caption: "Node Hardware",
                file_suffix: "_nodes",
                headers: node_headers,
                rows: node_rows,
            },
        ),
        (
            "drives",
            "Drives",
            Table {
                caption: "Drive Health",
                file_suffix: "_drives",
                headers: drive_headers,
                rows: drive_rows,
            },
        ),
        (
            "isos",
            "ISOs",
            Table {
                caption: "ISO Library",
                file_suffix: "_isos",
                headers: strs(&[
                    "ISO Name",
                    "Size (GB)",
                    "Path",
                    "Number of Mounts",
                    "Ready for Insert",
                ]),
                rows: iso_rows,
            },
        ),
        (
            "warnings",
            "",
            Table {
                caption: "Warnings and Recommendations",
                file_suffix: "_warnings",
                headers: strs(&["Severity", "Issue", "Recommendation"]),
                rows: warning_rows,
            },
        ),
        (
            "compliance",
            "",
            Table {
                caption: "Compliance Report",
                file_suffix: "_compliance",
                headers: strs(&["Category", "Actual (%)", "Target (%)", "Status", "Detail"]),
                rows: compliance_rows,
            },
        ),
        (
            "capacity",
            "",
            Table {
                caption: "Capacity Planning",
                file_suffix: "_capacity",
                headers: strs(&["Metric", "Value"]),
                rows: capacity_rows,
            },
        ),
        (
            "conditions",
            "Conditions",
            Table {
                caption: "Active Conditions",
                file_suffix: "_conditions",
                headers: strs(&["Severity", "Type", "Message", "UUID"]),
                rows: condition_rows,
            },
        ),
    ];

    let mut h = String::new();
    let mut hl = |t: &str| {
        h.push_str(t);
        h.push_str("\r\n");
    };
    hl("<!DOCTYPE html>");
    hl("<html lang=\"en\"><head><meta charset=\"utf-8\">");
    hl("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    hl(&format!(
        "<title>SuperAudit {}</title>",
        html_text(&cluster_name)
    ));
    hl("<style>");
    hl("body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#f7f7f5;}");
    hl("h1{color:#366092;margin-bottom:0;} h2{color:#366092;margin-top:28px;}");
    hl(".meta{color:#444;margin-top:4px;} .sheet{overflow-x:auto;background:#fff;border:1px solid #ddd;}");
    hl("table{border-collapse:collapse;width:100%;font-size:13px;}");
    hl("th{background:#366092;color:#fff;text-align:left;padding:6px 8px;position:sticky;top:0;}");
    hl("td{border-top:1px solid #e4e4e4;padding:5px 8px;vertical-align:top;}");
    hl("tr:nth-child(even) td{background:#f4f7fb;} .bad{background:#ffcccc;} .warn{background:#ffffcc;} .info{background:#cce5ff;} .good{background:#c6efce;}");
    hl(".note{font-size:13px;color:#333;max-width:900px;} nav a{margin-right:12px;}");
    hl("</style></head><body>");
    hl("<h1>SUPERAUDIT SUMMARY REPORT</h1>");
    hl(&format!(
        "<p class=\"meta\">Generated: {}<br>Tool: Scale HyperCore API Toolkit {}<br>Cluster: {}<br>Company: {}<br>ICOS version: {}<br>Collection time: {}<br>Compliance score: {}</p>",
        html_text(&collected_at), html_text(&tool_version), html_text(&cluster_name),
        html_text(&company), html_text(&icos), html_text(&elapsed_text), html_text(&score_text)
    ));
    hl("<nav>");
    hl("<a href=\"#summary\">Summary</a><a href=\"#vms\">VM Inventory</a><a href=\"#nodes\">Node Hardware</a>");
    hl("<a href=\"#drives\">Drive Health</a><a href=\"#isos\">ISO Library</a><a href=\"#warnings\">Warnings</a>");
    hl("<a href=\"#compliance\">Compliance</a><a href=\"#capacity\">Capacity</a><a href=\"#conditions\">Conditions</a>");
    hl("</nav>");
    hl("<h2 id=\"summary\">Summary Dashboard</h2>");
    hl("<pre class=\"sheet\">");
    hl(&html_text(&summary_text));
    hl("</pre>");
    for (id, skip_key, t) in &tables {
        hl(&format!("<div id=\"{id}\">"));
        if !skip_key.is_empty() && skip.contains(skip_key) {
            hl("<p class=\"note\">This section was skipped.</p>");
        }
        hl(html_table(t.caption, &t.headers, &t.rows).trim_end_matches("\r\n"));
        let note = match *id {
            "compliance" => "Targets are the ones published in the SuperAudit README: snapshots 80% of running VMs, HA 70% of production VMs, replication 50% of production VMs, adequate disks 90%, normal CPU 80%. Adequate means VM disk usage at or below 85% (the example's warning threshold). Normal CPU means node cpuUsage at or below 80%. Categories with nothing to score are N/A and are left out of the average. The upstream workbook writer does not emit this sheet.",
            "capacity" => "Storage totals follow the example: bytes on drives whose disposition is IN, divided by 1024^3, then shown as TB by dividing that figure by 1000. Node Hardware capacity uses each node's capacity field and decimal TB (1000^4). The upstream workbook writer does not emit this sheet.",
            "conditions" => "Active conditions come from GET /rest/v1/Condition (value true). The example daemon stores them. The one-time workbook does not.",
            _ => "",
        };
        if !note.is_empty() {
            hl(&format!("<p class=\"note\">{note}</p>"));
        }
        hl("</div>");
    }
    hl("<p class=\"note\">Read-only GET audit adapted from <a href=\"https://github.com/ScaleComputing/RestAPIExamples/tree/master/specific_task/superaudit\">Scale Computing SuperAudit</a> (Scale Computing Support Team). That repository has no license file. This report is a Rust reimplementation and does not include the Python source. Daemon mode, the SQLite or PostgreSQL history, and the Flask dashboard are not part of this app.</p>");
    hl("</body></html>");

    let [vms, nodes_t, drives, isos, warnings, compliance, capacity, conditions] =
        tables.map(|(_, _, t)| t);
    Report {
        file_stem: file_stem(&cluster_name),
        cluster_name,
        vms,
        nodes: nodes_t,
        drives,
        isos,
        warnings,
        compliance,
        capacity,
        conditions,
        flat_warnings: warn.flat,
        compliance_score: score_text,
        elapsed_text,
        summary_text,
        html: h,
    }
}

#[allow(dead_code)]
pub struct Saved {
    pub directory: PathBuf,
    pub html_path: PathBuf,
}

fn write_bom(path: &Path, text: &str) -> std::io::Result<()> {
    let mut bytes = vec![0xEF, 0xBB, 0xBF];
    bytes.extend_from_slice(text.as_bytes());
    std::fs::write(path, bytes)
}

/// Writes `superaudit_<stem>_<stamp>/` with the HTML report and quoted CSV files (UTF-8 BOM).
pub fn export(report: &Report, folder: &Path, stamp: &str) -> std::io::Result<Saved> {
    let stem = if report.file_stem.is_empty() {
        "cluster"
    } else {
        &report.file_stem
    };
    let stamp = if stamp.is_empty() {
        chrono::Local::now().format("%Y%m%d-%H%M%S").to_string()
    } else {
        stamp.to_string()
    };
    let dir = folder.join(format!("superaudit_{stem}_{stamp}"));
    std::fs::create_dir_all(&dir)?;
    let html_path = dir.join(format!("superaudit_{stem}.html"));
    write_bom(&html_path, &report.html)?;
    for t in [
        &report.vms,
        &report.nodes,
        &report.drives,
        &report.isos,
        &report.warnings,
        &report.compliance,
        &report.capacity,
        &report.conditions,
    ] {
        let p = dir.join(format!("superaudit_{stem}{}.csv", t.file_suffix));
        write_bom(&p, &csv(&t.headers, &t.rows))?;
    }
    Ok(Saved {
        directory: dir,
        html_path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::api_path;
    use serde_json::json;

    fn fixture() -> Input {
        let drive_in = json!({"slot":1,"serialNumber":"SN1","type":"SSD","capacityBytes":2000000000000u64,"usedBytes":500000000000u64,"temperature":40,"maxTemperature":55,"temperatureThreshold":70,"isHealthy":true,"reallocatedSectors":0,"errorCount":0,"currentDisposition":"IN"});
        let drive_out = json!({"slot":2,"serialNumber":"SN2","type":"HDD","capacityBytes":1000000000000u64,"usedBytes":100000000000u64,"temperature":30,"maxTemperature":40,"temperatureThreshold":60,"isHealthy":false,"reallocatedSectors":0,"errorCount":0,"currentDisposition":"OUT"});
        let node1 = json!({"uuid":"n1","lanIP":"10.0.0.1","backplaneIP":"10.0.1.1","numCores":8,"numThreads":16,"memSize":32000000000u64,"capacity":2000000000000u64,"cpuUsage":85.5,"memUsagePercentage":40,"networkStatus":"ONLINE","currentDisposition":"IN","drives":[drive_in]});
        let node2 = json!({"uuid":"n2","lanIP":"10.0.0.2","backplaneIP":"10.0.1.2","numCores":4,"numThreads":8,"memSize":16000000000u64,"capacity":1000000000000u64,"cpuUsage":10,"memUsagePercentage":20,"networkStatus":"OFFLINE","currentDisposition":"IN","drives":[drive_out]});
        let disk1 = json!({"type":"VIRTIO_DISK","slot":0,"capacity":100000000000u64,"allocation":96000000000u64,"tieringPriorityFactor":8,"cacheMode":"writeback","disableSnapshotting":false});
        let cdrom = json!({"type":"IDE_CDROM","path":"/var/iso/ubuntu.iso","slot":"cdrom0"});
        let net1 = json!({"ipv4Addresses":["192.168.1.10"],"ipv6Addresses":["fe80::1%10"],"vlan":10,"macAddress":"AA:BB","type":"VIRTIO","connected":true});
        let web1 = json!({"uuid":"uuid-web1","name":"web1","description":"Say \"hi\", friend","tags":["production"],"mem":4000000000u64,"numVCPU":2,"state":"RUNNING","bootDevices":[{"type":"HD"},{"type":"CDROM"}],"machineType":"UEFI","operatingSystem":"Linux","affinityStrategy":{"strictAffinity":false,"preferredNodeUUID":""},"nodeUUID":"n1","snapUUIDs":[],"blockDevs":[null,disk1,cdrom],"netDevs":[null,net1],"snapshotScheduleUUID":"","remoteClusterConnectionUUID":""});
        let disk2 = json!({"type":"VIRTIO_DISK","slot":1,"capacity":10000000000u64,"allocation":1000000000u64,"tieringPriorityFactor":0,"cacheMode":"none","disableSnapshotting":false});
        let web2 = json!({"uuid":"uuid-web2","name":"app","description":"","tags":[],"mem":2500000000u64,"numVCPU":1,"state":"RUNNING","machineType":"BIOS","operatingSystem":"Windows","affinityStrategy":{"strictAffinity":true,"preferredNodeUUID":""},"nodeUUID":"n2","snapUUIDs":["snap1"],"blockDevs":[disk2],"netDevs":[],"snapshotScheduleUUID":"s1"});
        let replica = json!({"uuid":"uuid-replica","name":"replica1","description":"","mem":1000000000u64,"numVCPU":1,"state":"STOPPED","nodeUUID":"n1","replicationSourceVirDomainUUID":"uuid-web1","remoteClusterConnectionUUID":"rc1","snapUUIDs":[],"blockDevs":[],"netDevs":[]});
        Input {
            cluster: Some(
                json!({"clusterName":"Prod Cluster","companyName":"Acme","icosVersion":"9.4.33"}),
            ),
            nodes: vec![node1, node2],
            vms: vec![web1, web2, replica],
            replication: vec![
                json!({"uuid":"rc1","remoteClusterName":"DR-Site","password":"super-secret-token","remotePassword":"another-secret"}),
            ],
            schedules: vec![json!({"uuid":"s1","name":"Nightly"})],
            isos: vec![
                json!({"name":"ubuntu.iso","size":5000000000u64,"path":"/isos/ubuntu.iso","mounts":["a","b"],"readyForInsert":true}),
                json!({"name":"alpine.iso","size":1000000000u64,"path":"/isos/alpine.iso","mounts":1,"readyForInsert":false}),
            ],
            conditions: vec![
                json!({"severity":"CRITICAL","alertType":"Disk","formattedMessage":"Disk degraded","uuid":"c1","value":true}),
                json!({"severity":"INFO","alertType":"Other","formattedMessage":"Cleared","uuid":"c2","value":false}),
            ],
            notes: vec!["RemoteClusterConnection unavailable (HTTP 404).".into()],
            collected_at: "2026-10-15 12:00:00".into(),
            elapsed_seconds: 2.2,
            tool_version: "0.6.0".into(),
            ..Default::default()
        }
    }

    #[test]
    fn full_report_matches_powershell_version() {
        let r = build(&fixture());
        assert_eq!(r.vms.rows.len(), 3);
        assert_eq!(r.file_stem, "prod_cluster");
        assert_eq!(r.compliance_score, "30.0");
        assert_eq!(r.elapsed_text, "2s");

        let expected_web1 = [
            "uuid-web1",
            "4",
            "PRODUCTION VM",
            "2",
            "RUNNING",
            "10.0.0.1",
            "85.50",
            "web1",
            "Say \"hi\", friend",
            "production",
            "HD/CDROM",
            "UEFI",
            "Linux",
            "",
            "VIRTIO_DISK",
            "0",
            "100.0",
            "96.0",
            "4 - NORMAL (8)",
            "writeback",
            "Enabled",
            "0",
            "ubuntu.iso",
            "192.168.1.10/fe80::1",
            "10",
            "AA:BB",
            "VIRTIO",
            "Connected",
            "",
            "",
        ];
        assert_eq!(r.vms.headers.len(), 30);
        assert_eq!(r.vms.rows[0], expected_web1.map(String::from).to_vec());

        let row1 = &r.vms.rows[1];
        assert_eq!(row1[2], "VM");
        assert_eq!(row1[13], "STRICT");
        assert_eq!(row1[1], "2.5");
        assert_eq!(row1[6], "10.00");
        assert_eq!(row1[18], "0 - OFF (0)");
        assert_eq!(row1[28], "Nightly");
        assert_eq!(row1[21], "1");
        let row2 = &r.vms.rows[2];
        assert_eq!(row2[2], "VM REPLICA");
        assert_eq!(row2[6], "N/A");
        assert_eq!(row2[16], "0");
        assert_eq!(row2[29], "DR-Site");

        assert_eq!(r.nodes.rows[0][4], "2.0");
        assert_eq!(r.nodes.rows[0][5], "0.5");
        assert_eq!(r.nodes.rows[0][6], "85.50");
        assert_eq!(r.nodes.rows[0][3], "32.0");
        assert_eq!(r.nodes.rows[0][2], "8/16");
        assert_eq!(r.nodes.rows[1][8], "OFFLINE");
        assert_eq!(r.drives.rows[0][10], "Healthy");
        assert_eq!(r.drives.rows[0][6], "25.00");
        assert_eq!(r.drives.rows[1][10], "Failed");
        assert_eq!(r.drives.headers[7], "Temperature (\u{b0}C)");

        assert_eq!(r.isos.rows[0][0], "alpine.iso");
        assert_eq!(r.isos.rows[0][3], "1");
        assert_eq!(r.isos.rows[1][0], "ubuntu.iso");
        assert_eq!(r.isos.rows[1][3], "2");
        assert_eq!(r.isos.rows[1][4], "Yes");
        assert_eq!(r.isos.rows[1][1], "5.0");

        assert_eq!(r.conditions.rows.len(), 1);
        assert_eq!(r.conditions.rows[0][2], "Disk degraded");

        assert_eq!(
            r.flat_warnings,
            vec![
                "web1: No snapshots configured (Running VM)",
                "web1: No HA policy configured (Production VM)",
                "web1: No replication configured (Production VM)",
                "Node 10.0.0.1: High CPU usage (85.5%)",
                "web1: Disk 0 is 96% full",
            ]
        );
        assert_eq!(r.warnings.rows[0][0], "CRITICAL");
        assert_eq!(
            r.warnings.rows[0][1],
            "web1: No snapshots configured (Running VM)"
        );
        assert_eq!(r.warnings.rows[1][1], "web1: Disk 0 is 96% full");
        assert!(r.warnings.rows[0][2].starts_with("Configure snapshot schedule immediately."));
        assert!(r.warnings.rows[1][2].starts_with("URGENT: Free up disk space"));

        assert_eq!(r.compliance.rows[0][3], "FAIL");
        assert_eq!(r.compliance.rows[0][1], "50.0");
        assert_eq!(r.compliance.rows[1][1], "0.0");
        assert_eq!(r.compliance.rows[3][1], "50.0");
        assert_eq!(r.compliance.rows[4][1], "50.0");

        for needle in [
            "Compliance score: 30.0",
            "Storage allocated: 1.9 TB",
            "Storage used: 0.5 TB (25.0%)",
            "Memory allocated: 7.5 GB",
            "RemoteClusterConnection unavailable (HTTP 404).",
        ] {
            assert!(r.summary_text.contains(needle), "summary missing {needle}");
        }
        for needle in [
            "SUPERAUDIT SUMMARY REPORT",
            "VM Inventory",
            "Compliance Report",
            "Capacity Planning",
        ] {
            assert!(r.html.contains(needle));
        }
        assert!(!r.html.contains("super-secret-token"));
        assert!(!r.summary_text.contains("another-secret"));
        assert!(!r.html.contains("Authorization"));

        let c = csv(&r.vms.headers, &r.vms.rows);
        assert!(c.contains("\"Say \"\"hi\"\", friend\""));
        assert!(c.starts_with("\"VM UUID\",\"Mem Alloc (GB)\""));
    }

    #[test]
    fn export_writes_bom_files() {
        let r = build(&fixture());
        let tmp = std::env::temp_dir().join(format!("sa-test-{}", std::process::id()));
        let out = export(&r, &tmp, "teststamp").unwrap();
        assert_eq!(
            out.html_path.file_name().unwrap(),
            "superaudit_prod_cluster.html"
        );
        let bytes = std::fs::read(&out.html_path).unwrap();
        assert_eq!(&bytes[..3], &[0xEF, 0xBB, 0xBF]);
        let csv_text =
            std::fs::read_to_string(out.directory.join("superaudit_prod_cluster.csv")).unwrap();
        assert!(csv_text.contains("\"Say \"\"hi\"\", friend\""));
        assert!(out
            .directory
            .join("superaudit_prod_cluster_conditions.csv")
            .exists());
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn extra_drives_merge() {
        let input = Input {
            cluster: fixture().cluster,
            nodes: vec![json!({"uuid":"n9","lanIP":"10.9.9.9","numCores":2,"numThreads":2})],
            extra_drives: vec![
                json!({"nodeUUID":"n9","slot":0,"type":"SSD","capacityBytes":1000000000u64,"usedBytes":0,"currentDisposition":"IN","isHealthy":true}),
            ],
            collected_at: "2026-10-15 12:00:00".into(),
            ..Default::default()
        };
        let r = build(&input);
        assert_eq!(r.drives.rows.len(), 1);
        assert_eq!(r.drives.rows[0][1], "0");
        assert_eq!(r.compliance_score, "100.0");
        assert_eq!(r.compliance.rows[0][3], "N/A");
    }

    #[test]
    fn skipped_sections() {
        let input = Input {
            skipped: vec!["Cluster".into(), "Nodes".into(), "VMs".into()],
            notes: vec!["Cluster skipped (HTTP 400). /rest/v1/Cluster".into()],
            collected_at: "2026-10-15 12:00:00".into(),
            ..Default::default()
        };
        let r = build(&input);
        assert!(r.summary_text.contains("Cluster: skipped"));
        assert!(r.summary_text.contains("VMs processed: skipped"));
        assert!(r.summary_text.contains("Nodes: skipped"));
        assert!(r
            .summary_text
            .contains("Cluster skipped (HTTP 400). /rest/v1/Cluster"));
        assert!(r.html.contains("This section was skipped."));
    }

    #[test]
    fn request_paths_are_normalized() {
        for p in RequestPaths::ALL {
            assert!(p.starts_with("/rest/v1/") || p.starts_with("/rest/v2/"));
            assert!(!p.contains("/rest/rest/"));
            assert_eq!(api_path(p), p);
        }
    }

    #[test]
    fn elapsed_and_rounding() {
        assert_eq!(format_elapsed(75.0), "1m 15s");
        assert_eq!(format_elapsed(7300.0), "2h 1m");
        assert_eq!(memory_gb(Some(&json!(4000000000u64))), "4");
        assert_eq!(memory_gb(Some(&json!(1234567890u64))), "1.235");
        assert_eq!(num1(1234.56), "1,234.6");
    }
}
