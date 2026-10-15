# Scale HyperCore API Toolkit

A Windows UI for common SC//HyperCore REST API tasks. Point it at a client cluster, sign in, and use the tabs for cluster info, VMs, snapshots, SNMP, alerts, settings, a SuperAudit report, and a raw API explorer.

## Use

1. Copy the folder to a Windows PC that can reach the cluster.
2. Double-click **Scale API.cmd**.
3. Enter the cluster IP (or hostname), login, and password, then **Connect**.

| Tab | What it does |
|---|---|
| **Cluster** | Cluster name / HyperCore version, node list (`lanIP`), software update status. **Test TLS** (connection bar) logs which protocol succeeded |
| **VMs** | List VMs; Start, Shutdown, Power off, Reboot; create a snapshot |
| **Snapshots** | List all snapshots; delete selected |
| **SNMP** | Check SNMP status; enable with a community string (HyperCore **9.7.1+**) |
| **Alerts** | Cluster conditions / health alerts |
| **Settings** | Read DNS, NTP/timezone, email & syslog alert targets, users, ISOs |
| **SuperAudit** | Read-only inventory of the connected cluster and an HTML report plus CSV files. **Open report** opens the HTML |
| **API** | Send a custom GET/POST/PATCH/DELETE under `/rest` (mutating calls confirm first and wait on `taskTag`) |

Each run appends to `ScaleAPI-log.txt` next to the app. The password is never saved or logged; the SNMP community string is not logged. SuperAudit does not write the password or the Authorization header into the log or the report.

## SuperAudit

**Run SuperAudit** collects a point-in-time audit of the cluster you are connected to and writes a timestamped folder under **Save to** (the app folder, unless you choose another one). The folder holds `superaudit_<cluster>.html` and CSV files with every field quoted, so Excel can open them. **Open report** opens the HTML.

The audit follows the one-time report in [Scale Computing's SuperAudit example](https://github.com/ScaleComputing/RestAPIExamples/tree/master/specific_task/superaudit) (Scale Computing Support Team). That repository does not publish a license file. This app reimplements the audit in PowerShell and does not include the Python source.

It reads cluster name and version, nodes, VM inventory (CPU, memory, boot, HA, disks, network, snapshot counts, snapshot schedules, replication partners), drive health, the ISO library, and active conditions. It scores the same warning rules as the example and writes a compliance score and a capacity section from the targets in that example's README. Requests go through the same helper as the other tabs, at `/rest/v1/...`. A failed call, including Cluster, is logged, that section is marked skipped, and the rest of the audit still runs.

Not included from that example: daemon mode, SQLite or PostgreSQL history, the Flask dashboard, VM filters, JSON export, and growth forecasts (those need the historical database). The upstream `generate_excel_workbook` function also does not write the Compliance or Capacity sheets; this report includes them from the published targets.

## Requirements

- Windows 10/11 with built-in `curl.exe` and Windows PowerShell 5.1. HyperCore 9.7.11 is TLS 1.3 only. Windows 10 Schannel cannot do TLS 1.3. Install Git for Windows (its `usr\bin\openssl.exe`, not its curl) or run the app on Windows 11.
- Network reachability to a cluster node IP (there is no cluster VIP — use a node `lanIP`)
- SNMP tab needs SC//HyperCore **9.7.1 or newer** (REST v2). Other tabs work on 9.6+

## API used

| Call | Purpose |
|---|---|
| `GET /rest/v1/Cluster` | Cluster name and `icosVersion` |
| `GET /rest/v1/Node` | Node IPs and status |
| `GET /update/update_status.json` | Rolling-update busy check (no auth) |
| `GET /rest/v1/VirDomain` | VM inventory |
| `POST /rest/v1/VirDomain/action` | Start / Shutdown / Stop / Reboot |
| `GET` / `POST` / `DELETE /rest/v1/VirDomainSnapshot` | Snapshots |
| `GET` / `POST /rest/v2/SNMPConfig` | SNMP status and enable (`{"communityName":"..."}`) |
| `GET /rest/v1/Condition` | Health conditions |
| `GET /rest/v1/DNSConfig`, `TimeZone`, `TimeSource` | Cluster time/DNS settings |
| `GET /rest/v1/AlertEmailTarget`, `AlertSyslogTarget` | Alert destinations |
| `GET /rest/v1/User`, `ISO` | Users and ISO library |
| `GET /rest/v1/TaskTag/{tag}` | Wait for mutating calls to finish |
| `GET /rest/v1/RemoteClusterConnection` | SuperAudit replication partners (skipped if missing) |
| `GET /rest/v1/VirDomainSnapshotSchedule` | SuperAudit snapshot schedule names (skipped if missing) |
| `GET /rest/v1/Drive` | SuperAudit drive rows when a node has no embedded drives |
| `GET /rest/v1/Condition/filter?includeSet=true` | SuperAudit active conditions; falls back to `GET /rest/v1/Condition` |

Auth is HTTP Basic. Clusters use self-signed certificates, so requests skip certificate checks. Schannel `curl.exe` (TLS 1.3, then default, then TLS 1.0-1.1, always `--ssl-no-revoke`) and .NET are tried first. HyperCore 9.7.11 negotiates TLS 1.3 only (`TLS_AES_256_GCM_SHA384`). Windows 10 Schannel fails that with `SEC_E_ALGORITHM_MISMATCH` before the handshake, and Git's `curl.exe` is Schannel-only. The app then sends the HTTP request through `openssl s_client` (Git's `C:\Program Files\Git\usr\bin\openssl.exe`, or `SCALE_OPENSSL`, or a path in `ScaleAPI-openssl.path`). **Test TLS** does this without sending the password. App version 0.5.0 (see `CHANGELOG.md`).

References: [ScaleComputing/RestAPIExamples](https://github.com/ScaleComputing/RestAPIExamples), cluster OpenAPI at `https://<node-ip>/rest/v1/docs/` and `https://<node-ip>/rest/v2/openAPI.json`.
