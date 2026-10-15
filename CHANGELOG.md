# Changelog

## 0.5.0

- SuperAudit tab. Read-only GET audit of the connected cluster: cluster, nodes, VMs (disks, network, snapshots, schedules, replication), drive health, ISOs, and active conditions.
- Writes an HTML report and quoted CSV files into a timestamped folder next to the app, or into a folder you choose. Open report opens the HTML.
- Endpoints that are missing on older HyperCore versions are skipped and listed in the report. The password and Authorization header are not logged or written into the report.
- SuperAudit calls the same request helper as the other tabs. Paths are `/rest/v1/...` (a path that already starts with `/rest` is not prefixed again). A failed call, including Cluster, is logged, that section is marked skipped, and the audit continues. The request timeout is not sent as a JSON body.
- The layout follows [Scale Computing's SuperAudit example](https://github.com/ScaleComputing/RestAPIExamples/tree/master/specific_task/superaudit). That repository has no license file. This is a PowerShell reimplementation, not a copy of the Python source. Daemon mode, the historical database, and the web dashboard are not included.

## 0.4.1

- Removed the legacy SNMP launcher (`Scale SNMP.cmd` and `ScaleSNMP.ps1`). Use `Scale API.cmd`.

## 0.4

- HyperCore 9.7.11.227728 negotiates TLS 1.3 only (`TLS_AES_256_GCM_SHA384`, X25519). Windows 10 Schannel fails `curl --tlsv1.3` with `SEC_E_ALGORITHM_MISMATCH` before the handshake, and a TLS 1.2 attempt fails in the handshake with `SEC_E_UNSUPPORTED_FUNCTION`.
- Git for Windows `curl.exe` is Schannel-only. `CURL_SSL_BACKEND=openssl` does not change that. The working binary is `openssl.exe` (`C:\Program Files\Git\usr\bin\openssl.exe`).
- After Schannel curl and .NET both fail, the app sends HTTP/1.1 through `openssl s_client -connect host:443 -quiet` (Host, Authorization, Content-Type, Content-Length, Connection: close), including chunked responses. The Authorization header is never logged.
- OpenSSL is found in Git's `usr\bin`, or from `SCALE_OPENSSL`, or from `ScaleAPI-openssl.path` next to the app.
- If none of those work, the log says: this node only accepts TLS 1.3, which Windows 10 can't do. Install Git for Windows or run from Windows 11.

## 0.3

- Curl no longer pins TLS 1.2. That pin (`--tlsv1.2 --tls-max 1.2`) made schannel return `SEC_E_UNSUPPORTED_FUNCTION (0x80090302)` against HyperCore 9.7.11.227728. The same app connected to a 9.7.10 cluster, so this is not an older TLS-only node.
- Curl tries `--tlsv1.3` first, then default negotiation, then `--tlsv1.0 --tls-max 1.1`. Every attempt uses `--ssl-no-revoke` and skips certificate checks.
- The .NET fallback sets `ServicePointManager.SecurityProtocol` to TLS 1.3 (enum value 12288) when the runtime accepts it, plus TLS 1.2, 1.1, and 1.0.
- If every attempt fails, the log lists what was tried and says Windows 10 Schannel does not offer TLS 1.3 by default (Windows 11 and Server 2022 do). It also notes a possible cipher or curve mismatch (ChaCha20-Poly1305 or an ECDSA-only suite).
- **Test TLS** (connection bar) probes TLS 1.3 first, without sending credentials, and logs which profile or SslStream protocol succeeded.

## 0.2

- First Windows TLS workaround: curl forced TLS 1.2 and fell back to .NET `HttpWebRequest` with TLS 1.2 only. Replaced in 0.3.

## 0.1

- Scale HyperCore API Toolkit Windows UI (cluster, VMs, snapshots, SNMP, alerts, settings, raw API).
- PowerShell 5.1: ASCII source and a UTF-8 BOM so the script parses.
