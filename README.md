# Scale SNMP

A small Windows app that turns on SNMP for a Scale Computing SC//HyperCore cluster through its REST API. Use it on client clusters: enter the cluster IP, login, password, and community string.

## Use

1. Copy the folder to a Windows PC that can reach the cluster.
2. Double-click `Scale SNMP.cmd`.
3. Fill in the cluster IP, login, password, and community string.
4. **Check** shows the cluster name, HyperCore version, and whether SNMP is on. **Enable SNMP** turns it on with the community string (it asks first if SNMP is already on).

Each run is logged to `ScaleSNMP-log.txt` next to the app. The password is never saved; the community string is not logged.

## Requirements

- SC//HyperCore **9.7.1 or newer** (the SNMP API is REST v2 only). Older clusters show a clear message.
- Windows 10/11 with built-in `curl.exe` and Windows PowerShell 5.1.

## API used

| Call | Purpose |
|---|---|
| `GET /rest/v1/Cluster` | Cluster name and `icosVersion` |
| `GET /rest/v2/SNMPConfig` | SNMP status (array of strings, e.g. `["The SNMP Service is enabled."]`) |
| `POST /rest/v2/SNMPConfig` `{"communityName":"..."}` | Adds a read-only community and enables and starts SNMP |
| `DELETE /rest/v2/SNMPConfig/{uuid}` | Disables and stops SNMP (not used by the app) |
| `GET /rest/v1/TaskTag/{tag}` | Wait for a change to finish |

Auth is HTTP Basic. Clusters use self-signed certificates, so requests skip certificate checks. Windows PowerShell's own web client fails TLS against HyperCore, which is why the app uses `curl.exe`. The only SNMP setting the API exposes is a read-only community name (no SNMPv3, traps, or allowed hosts).

References: [ScaleComputing/RestAPIExamples](https://github.com/ScaleComputing/RestAPIExamples), and the cluster's own spec at `https://<node-ip>/rest/v2/openAPI.json`.
