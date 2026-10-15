# Scale HyperCore API Toolkit

A Windows UI for common SC//HyperCore REST API tasks. Point it at a client cluster, sign in, and use the tabs for cluster info, VMs, snapshots, SNMP, alerts, settings, and a raw API explorer.

## Use

1. Copy the folder to a Windows PC that can reach the cluster.
2. Double-click **Scale API.cmd** (or **Scale SNMP.cmd** — same app).
3. Enter the cluster IP (or hostname), login, and password, then **Connect**.

| Tab | What it does |
|---|---|
| **Cluster** | Cluster name / HyperCore version, node list (`lanIP`), software update status |
| **VMs** | List VMs; Start, Shutdown, Power off, Reboot; create a snapshot |
| **Snapshots** | List all snapshots; delete selected |
| **SNMP** | Check SNMP status; enable with a community string (HyperCore **9.7.1+**) |
| **Alerts** | Cluster conditions / health alerts |
| **Settings** | Read DNS, NTP/timezone, email & syslog alert targets, users, ISOs |
| **API** | Send a custom GET/POST/PATCH/DELETE under `/rest` (mutating calls confirm first and wait on `taskTag`) |

Each run appends to `ScaleAPI-log.txt` next to the app. The password is never saved or logged; the SNMP community string is not logged.

## Requirements

- Windows 10/11 with built-in `curl.exe` and Windows PowerShell 5.1
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

Auth is HTTP Basic. Clusters use self-signed certificates, so requests skip certificate checks. Windows PowerShell’s own web client fails TLS against HyperCore, which is why the app uses `curl.exe`.

References: [ScaleComputing/RestAPIExamples](https://github.com/ScaleComputing/RestAPIExamples), cluster OpenAPI at `https://<node-ip>/rest/v1/docs/` and `https://<node-ip>/rest/v2/openAPI.json`.
