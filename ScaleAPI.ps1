# Scale HyperCore API Toolkit - Windows UI for SC//HyperCore REST (v1 + SNMP v2).
# Talks to the cluster with curl.exe (TLS 1.2 + no revoke) and falls back to .NET if
# Windows schannel fails the HyperCore handshake. Credentials stay in memory only.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Prefer TLS 1.2 for HyperCore; ignore self-signed certs on the .NET fallback path.
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}
if (-not ("HcTrustAll" -as [type])) {
  Add-Type @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class HcTrustAll {
  public static bool Allow(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) { return true; }
  public static void Enable() {
    ServicePointManager.ServerCertificateValidationCallback = Allow;
  }
}
"@
}
[HcTrustAll]::Enable()

$script:AppTitle = "Scale HyperCore API"
$logFile = Join-Path $PSScriptRoot "ScaleAPI-log.txt"
$script:VmCache = @()
$script:NodeCache = @()
$script:Transport = $null   # 'curl' or 'dotnet' once a working path is found

# --- helpers: UI factories ---
function New-Label([string]$text, [int]$x, [int]$y, [int]$w = 110, [int]$h = 22) {
  $l = New-Object Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, $h)
  $l.TextAlign = "MiddleLeft"; $l
}
function New-TextBox([int]$x, [int]$y, [int]$w = 220, [bool]$password = $false) {
  $t = New-Object Windows.Forms.TextBox
  $t.Location = New-Object Drawing.Point($x, $y); $t.Size = New-Object Drawing.Size($w, 22)
  if ($password) { $t.UseSystemPasswordChar = $true }
  $t
}
function New-Button([string]$text, [int]$x, [int]$y, [int]$w = 120, [int]$h = 28) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, $h)
  $b
}
function New-Grid([int]$x, [int]$y, [int]$w, [int]$h) {
  $g = New-Object Windows.Forms.DataGridView
  $g.Location = New-Object Drawing.Point($x, $y); $g.Size = New-Object Drawing.Size($w, $h)
  $g.ReadOnly = $true; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false
  $g.SelectionMode = "FullRowSelect"; $g.MultiSelect = $false; $g.AutoSizeColumnsMode = "Fill"
  $g.RowHeadersVisible = $false; $g.BackgroundColor = [Drawing.SystemColors]::Window
  $g
}

# --- main form ---
$form = New-Object Windows.Forms.Form
$form.Text = $script:AppTitle
$form.Size = New-Object Drawing.Size(920, 680)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object Drawing.Size(800, 560)

# Connection bar
$connPanel = New-Object Windows.Forms.Panel
$connPanel.Dock = "Top"; $connPanel.Height = 78; $connPanel.Padding = New-Object Windows.Forms.Padding(8)
$ipBox = New-TextBox 120 12 200
$userBox = New-TextBox 120 42 140
$passBox = New-TextBox 380 42 160 $true
$connStatus = New-Label "Not connected" 560 42 320 22
$connStatus.ForeColor = [Drawing.Color]::DimGray
$connectBtn = New-Button "Connect" 560 10 100 28
$connPanel.Controls.AddRange(@(
  (New-Label "Cluster IP / host" 12 12 108), $ipBox,
  (New-Label "Login" 12 42 108), $userBox,
  (New-Label "Password" 280 42 90), $passBox,
  $connectBtn, $connStatus
))

# Tabs + shared log
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = "Fill"
$tabs.Padding = New-Object Drawing.Point(12, 4)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = "Vertical"
$logBox.Dock = "Bottom"; $logBox.Height = 160
$logBox.Font = New-Object Drawing.Font("Consolas", 9)
$logBox.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
$logBox.ForeColor = [Drawing.Color]::Gainsboro

$form.Controls.Add($tabs)
$form.Controls.Add($logBox)
$form.Controls.Add($connPanel)

function Say([string]$text) {
  $line = "$(Get-Date -Format 'HH:mm:ss')  $text"
  $logBox.AppendText("$line`r`n")
  try { Add-Content -Path $logFile -Value "$(Get-Date -Format s)  $text" -ErrorAction SilentlyContinue } catch {}
  [Windows.Forms.Application]::DoEvents()
}

function Show-Msg([string]$text, [string]$icon = "Information") {
  [Windows.Forms.MessageBox]::Show($text, $script:AppTitle, "OK", $icon) | Out-Null
}

function Test-Credentials {
  if (-not $ipBox.Text.Trim() -or -not $userBox.Text.Trim() -or -not $passBox.Text) {
    Show-Msg "Enter the cluster IP, login, and password." "Warning"
    return $false
  }
  return $true
}

function Get-HcUrl([string]$Path) {
  $ip = $ipBox.Text.Trim()
  if ($Path -match '^https?://') { return $Path }
  if ($Path.StartsWith("/update/")) { return "https://$ip$Path" }
  return "https://$ip/rest$Path"
}

function Invoke-HcCurl {
  param(
    [string]$Method,
    [string]$Url,
    [string]$Body,
    [int]$TimeoutSec
  )
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userBox.Text.Trim() + ":" + $passBox.Text))
  $cfg = [IO.Path]::GetTempFileName()
  $bf = $null
  $exit = 0
  try {
    Set-Content -Path $cfg -Value "header = `"Authorization: Basic $b64`"" -Encoding ASCII
    # Force TLS 1.2 and skip schannel revocation checks - common HyperCore + Windows curl fixes.
    $ca = @(
      "-sS", "-k", "--ssl-no-revoke",
      "--tlsv1.2", "--tls-max", "1.2",
      "--max-time", "$TimeoutSec",
      "-K", $cfg, "-X", $Method,
      "-w", "`n%{http_code}",
      $Url
    )
    if ($Body) {
      $bf = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($bf, $Body)
      $ca += @("-H", "Content-Type: application/json", "--data-binary", "@$bf")
    }
    $raw = (& curl.exe @ca 2>&1) -join "`n"
    $exit = $LASTEXITCODE
  } finally {
    Remove-Item $cfg -Force -ErrorAction SilentlyContinue
    if ($bf) { Remove-Item $bf -Force -ErrorAction SilentlyContinue }
  }
  $lines = @($raw -split "`n")
  $code = if ($lines.Count) { $lines[-1].Trim() } else { "000" }
  $bodyText = if ($lines.Count -gt 1) { ($lines[0..($lines.Count - 2)] -join "`n").Trim() } else { "" }
  # curl SSL/connect failures often still print http_code 000
  if ($exit -ne 0 -and ($code -notmatch '^\d{3}$' -or $code -eq "000")) {
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = $bodyText; Exit = $exit }
  }
  if ($code -notmatch '^\d{3}$') {
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = $raw; Exit = $exit }
  }
  [pscustomobject]@{ Ok = $true; Code = $code; Body = $bodyText; Exit = $exit }
}

function Invoke-HcDotNet {
  param(
    [string]$Method,
    [string]$Url,
    [string]$Body,
    [int]$TimeoutSec
  )
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.Accept = "application/json"
    $req.UserAgent = "ScaleHyperCoreAPIToolkit/0.2"
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userBox.Text.Trim() + ":" + $passBox.Text))
    $req.Headers.Add("Authorization", "Basic $token")
    if ($Body -and $Method -in @("POST", "PATCH", "PUT")) {
      $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
      $req.ContentType = "application/json"
      $req.ContentLength = $bytes.Length
      $stream = $req.GetRequestStream()
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Close()
    }
    $resp = $req.GetResponse()
    try {
      $sr = New-Object IO.StreamReader($resp.GetResponseStream())
      $text = $sr.ReadToEnd()
      $sr.Close()
      $code = [int]$resp.StatusCode
      return [pscustomobject]@{ Ok = $true; Code = "$code"; Body = $text; Exit = 0 }
    } finally {
      $resp.Close()
    }
  } catch [Net.WebException] {
    $ex = $_.Exception
    $resp = $ex.Response
    if ($resp) {
      try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $text = $sr.ReadToEnd()
        $sr.Close()
      } catch { $text = $ex.Message }
      $code = [int]$resp.StatusCode
      return [pscustomobject]@{ Ok = $true; Code = "$code"; Body = $text; Exit = 0 }
    }
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = $ex.Message; Exit = 1 }
  } catch {
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = $_.Exception.Message; Exit = 1 }
  }
}

function Invoke-Hc {
  param(
    [Parameter(Mandatory)][ValidateSet("GET","POST","PATCH","PUT","DELETE")][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [string]$Body = "",
    [int]$TimeoutSec = 60
  )
  $url = Get-HcUrl $Path

  # Stick with the transport that already worked this session.
  if ($script:Transport -eq "dotnet") {
    $r = Invoke-HcDotNet $Method $url $Body $TimeoutSec
    return [pscustomobject]@{ Code = $r.Code; Body = $r.Body }
  }
  if ($script:Transport -eq "curl") {
    $r = Invoke-HcCurl $Method $url $Body $TimeoutSec
    if ($r.Ok) { return [pscustomobject]@{ Code = $r.Code; Body = $r.Body } }
    # curl broke mid-session - try .NET once
    Say "curl failed; trying .NET TLS fallback..."
    $r2 = Invoke-HcDotNet $Method $url $Body $TimeoutSec
    if ($r2.Ok) {
      $script:Transport = "dotnet"
      return [pscustomobject]@{ Code = $r2.Code; Body = $r2.Body }
    }
    return [pscustomobject]@{ Code = "000"; Body = "curl: $($r.Body)`r`n.NET: $($r2.Body)" }
  }

  # First request: try hardened curl, then .NET fallback.
  $r = Invoke-HcCurl $Method $url $Body $TimeoutSec
  if ($r.Ok) {
    $script:Transport = "curl"
    return [pscustomobject]@{ Code = $r.Code; Body = $r.Body }
  }
  Say "curl TLS/connect failed ($($r.Exit)): $($r.Body)"
  Say "Retrying with .NET HttpWebRequest (TLS 1.2, cert check skipped)..."
  $r2 = Invoke-HcDotNet $Method $url $Body $TimeoutSec
  if ($r2.Ok) {
    $script:Transport = "dotnet"
    Say "Connected via .NET fallback."
    return [pscustomobject]@{ Code = $r2.Code; Body = $r2.Body }
  }
  [pscustomobject]@{
    Code = "000"
    Body = @"
TLS connection failed over both curl and .NET.

curl: $($r.Body)
.NET: $($r2.Body)

Check that $($ipBox.Text.Trim()) is a node lanIP reachable on TCP 443, and that nothing is intercepting HTTPS.
"@
  }
}

function ConvertFrom-HcJson([string]$json) {
  if ([string]::IsNullOrWhiteSpace($json)) { return $null }
  try { return ($json | ConvertFrom-Json) } catch { return $null }
}

function Get-FirstRecord($parsed) {
  if ($null -eq $parsed) { return $null }
  if ($parsed -is [System.Array]) {
    if ($parsed.Count -gt 0) { return $parsed[0] }
    return $null
  }
  return $parsed
}

function Wait-HcTask([string]$tag, [int]$maxSeconds = 120) {
  if (-not $tag) { return $true }
  Say "Waiting for task $tag ..."
  $deadline = (Get-Date).AddSeconds($maxSeconds)
  while ((Get-Date) -lt $deadline) {
    $t = Invoke-Hc GET "/v1/TaskTag/$tag"
    $parsed = ConvertFrom-HcJson $t.Body
    $task = Get-FirstRecord $parsed
    $state = if ($task -and $task.state) { [string]$task.state } else { "" }
    if ($state -and $state -notin @("RUNNING", "QUEUED")) {
      if ($state -in @("ERROR", "UNINITIALIZED")) {
        $msg = if ($task.formattedMessage) { $task.formattedMessage } else { $t.Body }
        Say "Task failed ($state): $msg"
        return $false
      }
      Say "Task finished: $state"
      return $true
    }
    Start-Sleep -Seconds 2
    [Windows.Forms.Application]::DoEvents()
  }
  Say "Task wait timed out after ${maxSeconds}s."
  return $false
}

function Set-Busy([bool]$busy) {
  $form.UseWaitCursor = $busy
  $connectBtn.Enabled = -not $busy
  [Windows.Forms.Application]::DoEvents()
}

function Set-Connected([bool]$ok, [string]$detail = "") {
  if ($ok) {
    $connStatus.Text = if ($detail) { $detail } else { "Connected" }
    $connStatus.ForeColor = [Drawing.Color]::ForestGreen
  } else {
    $connStatus.Text = if ($detail) { $detail } else { "Not connected" }
    $connStatus.ForeColor = [Drawing.Color]::Firebrick
  }
}

# ========== Tab: Cluster ==========
$tabCluster = New-Object Windows.Forms.TabPage
$tabCluster.Text = "Cluster"
$clusterOut = New-Object Windows.Forms.TextBox
$clusterOut.Multiline = $true; $clusterOut.ReadOnly = $true; $clusterOut.ScrollBars = "Both"
$clusterOut.Font = New-Object Drawing.Font("Consolas", 9)
$clusterOut.WordWrap = $false
$clusterOut.Location = New-Object Drawing.Point(12, 48)
$clusterOut.Anchor = "Top,Bottom,Left,Right"
$clusterOut.Size = New-Object Drawing.Size(860, 360)
$refreshClusterBtn = New-Button "Refresh cluster" 12 12 130
$refreshNodesBtn = New-Button "Refresh nodes" 150 12 120
$refreshUpdateBtn = New-Button "Update status" 280 12 120
$tabCluster.Controls.AddRange(@($refreshClusterBtn, $refreshNodesBtn, $refreshUpdateBtn, $clusterOut))

function Show-ClusterInfo {
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    $script:Transport = $null  # re-probe curl vs .NET for this connect
    Say "--- Cluster $($ipBox.Text.Trim())"
    $c = Invoke-Hc GET "/v1/Cluster"
    if ($c.Code -eq "401") { Set-Connected $false "Login failed"; Say "Login failed (401)."; return }
    if ($c.Code -ne "200") { Set-Connected $false "Error $($c.Code)"; Say "Cluster failed ($($c.Code)): $($c.Body)"; return }
    $rec = Get-FirstRecord (ConvertFrom-HcJson $c.Body)
    $name = if ($rec.clusterName) { $rec.clusterName } else { "?" }
    $ver = if ($rec.icosVersion) { $rec.icosVersion } else { "?" }
    $uuid = if ($rec.uuid) { $rec.uuid } else { "?" }
    Set-Connected $true "$name  -  HyperCore $ver"
    $clusterOut.Text = @"
Cluster name : $name
Version      : $ver
UUID         : $uuid

Raw:
$($c.Body)
"@
    Say "Cluster $name  HyperCore $ver"
  } finally { Set-Busy $false }
}

function Show-Nodes {
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    Say "--- Nodes"
    $r = Invoke-Hc GET "/v1/Node"
    if ($r.Code -ne "200") { Say "Nodes failed ($($r.Code)): $($r.Body)"; return }
    $nodes = @(ConvertFrom-HcJson $r.Body)
    $script:NodeCache = $nodes
    $lines = @("Nodes ($($nodes.Count)):", "")
    foreach ($n in $nodes) {
      $lines += ("  lanIP={0,-16}  peerIP={1,-16}  status={2,-10}  disposition={3}" -f `
        $n.lanIP, $n.peerIP, $n.networkStatus, $n.currentDisposition)
      if ($n.uuid) { $lines += "    uuid=$($n.uuid)" }
    }
    $clusterOut.Text = ($lines -join "`r`n")
    Say "Loaded $($nodes.Count) node(s)."
  } finally { Set-Busy $false }
}

function Show-UpdateStatus {
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    Say "--- Update status (no auth)"
    $r = Invoke-Hc GET "/update/update_status.json"
    if ($r.Code -eq "404") {
      $clusterOut.Text = "Update status: never updated / endpoint returned 404.`r`nTreat as unknown - fail closed for writes during upgrades."
      Say "Update status 404 (never updated or unavailable)."
      return
    }
    if ($r.Code -ne "200") { Say "Update status failed ($($r.Code)): $($r.Body)"; return }
    $u = ConvertFrom-HcJson $r.Body
    $prep = if ($u.prepareStatus -and $u.prepareStatus.state) { $u.prepareStatus.state } else { "(absent)" }
    $master = if ($u.updateStatus -and $u.updateStatus.masterState) { $u.updateStatus.masterState } else { "(absent)" }
    $idle = ($prep -eq "COMPLETE" -and $master -eq "COMPLETE")
    $clusterOut.Text = @"
prepareStatus.state      : $prep
updateStatus.masterState : $master
Idle for writes          : $idle

Raw:
$($r.Body)
"@
    Say "Update prepare=$prep master=$master idle=$idle"
  } finally { Set-Busy $false }
}

$refreshClusterBtn.Add_Click({ Show-ClusterInfo })
$refreshNodesBtn.Add_Click({ Show-Nodes })
$refreshUpdateBtn.Add_Click({ Show-UpdateStatus })

# ========== Tab: VMs ==========
$tabVms = New-Object Windows.Forms.TabPage
$tabVms.Text = "VMs"
$vmGrid = New-Grid 12 48 860 320
$vmGrid.Anchor = "Top,Bottom,Left,Right"
$refreshVmsBtn = New-Button "Refresh VMs" 12 12 110
$startVmBtn = New-Button "Start" 130 12 80
$shutdownVmBtn = New-Button "Shutdown" 218 12 90
$stopVmBtn = New-Button "Power off" 316 12 90
$rebootVmBtn = New-Button "Reboot" 414 12 80
$snapVmBtn = New-Button "Snapshot" 502 12 90
$vmDetail = New-Label "" 600 14 270 22
$vmDetail.Anchor = "Top,Right"
$tabVms.Controls.AddRange(@($refreshVmsBtn, $startVmBtn, $shutdownVmBtn, $stopVmBtn, $rebootVmBtn, $snapVmBtn, $vmDetail, $vmGrid))

function Get-SelectedVm {
  if ($vmGrid.SelectedRows.Count -lt 1) { Show-Msg "Select a VM in the list." "Warning"; return $null }
  $name = [string]$vmGrid.SelectedRows[0].Cells["Name"].Value
  $vm = $script:VmCache | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if (-not $vm) { Show-Msg "Could not resolve the selected VM."; return $null }
  return $vm
}

function Format-Mem([long]$bytes) {
  if ($bytes -le 0) { return "?" }
  "{0:N1} GiB" -f ($bytes / 1GB)
}

function Show-Vms {
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    Say "--- VMs"
    $r = Invoke-Hc GET "/v1/VirDomain"
    if ($r.Code -eq "401") { Set-Connected $false "Login failed"; Say "Login failed (401)."; return }
    if ($r.Code -ne "200") { Say "VMs failed ($($r.Code)): $($r.Body)"; return }
    $vms = @(ConvertFrom-HcJson $r.Body)
    $script:VmCache = $vms
    $table = New-Object System.Data.DataTable
    foreach ($col in @("Name", "State", "vCPU", "Memory", "Tags", "UUID")) { [void]$table.Columns.Add($col) }
    foreach ($vm in ($vms | Sort-Object name)) {
      $row = $table.NewRow()
      $row.Name = $vm.name
      $row.State = $vm.state
      $row.vCPU = $vm.numVCPU
      $row.Memory = Format-Mem ([long]$vm.mem)
      $row.Tags = $vm.tags
      $row.UUID = $vm.uuid
      [void]$table.Rows.Add($row)
    }
    $vmGrid.DataSource = $table
    $vmDetail.Text = "$($vms.Count) VM(s)"
    Say "Loaded $($vms.Count) VM(s)."
  } finally { Set-Busy $false }
}

function Invoke-VmAction([string]$actionType) {
  $vm = Get-SelectedVm
  if (-not $vm) { return }
  if ($actionType -in @("STOP", "SHUTDOWN", "REBOOT")) {
    $a = [Windows.Forms.MessageBox]::Show(
      "Send $actionType to '$($vm.name)'?",
      $script:AppTitle, "YesNo", "Question")
    if ($a -ne "Yes") { return }
  }
  Set-Busy $true
  try {
    Say "--- VM $actionType  $($vm.name)"
    $body = (@(@{ virDomainUUID = $vm.uuid; actionType = $actionType }) | ConvertTo-Json -Compress -Depth 5)
    # ConvertTo-Json of single-element array becomes object in PS 5.1 - force array wrapper
    if ($body -notmatch '^\s*\[') { $body = "[$body]" }
    $r = Invoke-Hc POST "/v1/VirDomain/action" $body
    if ($r.Code -notin @("200", "201")) { Say "Action failed ($($r.Code)): $($r.Body)"; return }
    $parsed = ConvertFrom-HcJson $r.Body
    $tag = if ($parsed.taskTag) { [string]$parsed.taskTag } else { $null }
    [void](Wait-HcTask $tag)
    Show-Vms
  } finally { Set-Busy $false }
}

function New-VmSnapshot {
  $vm = Get-SelectedVm
  if (-not $vm) { return }
  $label = "API toolkit $(Get-Date -Format s)"
  Set-Busy $true
  try {
    Say "--- Snapshot $($vm.name)"
    $body = @{ domainUUID = $vm.uuid; label = $label } | ConvertTo-Json -Compress
    $r = Invoke-Hc POST "/v1/VirDomainSnapshot" $body
    if ($r.Code -notin @("200", "201")) { Say "Snapshot failed ($($r.Code)): $($r.Body)"; return }
    $parsed = ConvertFrom-HcJson $r.Body
    [void](Wait-HcTask ([string]$parsed.taskTag))
    Say "Snapshot created: $($parsed.createdUUID)"
  } finally { Set-Busy $false }
}

$refreshVmsBtn.Add_Click({ Show-Vms })
$startVmBtn.Add_Click({ Invoke-VmAction "START" })
$shutdownVmBtn.Add_Click({ Invoke-VmAction "SHUTDOWN" })
$stopVmBtn.Add_Click({ Invoke-VmAction "STOP" })
$rebootVmBtn.Add_Click({ Invoke-VmAction "REBOOT" })
$snapVmBtn.Add_Click({ New-VmSnapshot })

# ========== Tab: Snapshots ==========
$tabSnaps = New-Object Windows.Forms.TabPage
$tabSnaps.Text = "Snapshots"
$snapGrid = New-Grid 12 48 860 320
$snapGrid.Anchor = "Top,Bottom,Left,Right"
$refreshSnapsBtn = New-Button "Refresh snapshots" 12 12 140
$deleteSnapBtn = New-Button "Delete selected" 160 12 120
$snapCount = New-Label "" 300 14 400 22
$tabSnaps.Controls.AddRange(@($refreshSnapsBtn, $deleteSnapBtn, $snapCount, $snapGrid))
$script:SnapCache = @()

function Show-Snapshots {
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    Say "--- Snapshots"
    $r = Invoke-Hc GET "/v1/VirDomainSnapshot"
    if ($r.Code -ne "200") { Say "Snapshots failed ($($r.Code)): $($r.Body)"; return }
    $snaps = @(ConvertFrom-HcJson $r.Body)
    $script:SnapCache = $snaps
    $vmByUuid = @{}
    foreach ($vm in $script:VmCache) { if ($vm.uuid) { $vmByUuid[[string]$vm.uuid] = [string]$vm.name } }
    $table = New-Object System.Data.DataTable
    foreach ($col in @("VM", "Label", "Timestamp", "UUID", "DomainUUID")) { [void]$table.Columns.Add($col) }
    foreach ($s in ($snaps | Sort-Object timestamp -Descending)) {
      $dom = [string]$s.domainUUID
      $row = $table.NewRow()
      $row.VM = if ($vmByUuid.ContainsKey($dom)) { $vmByUuid[$dom] } else { $dom }
      $row.Label = $s.label
      $row.Timestamp = $s.timestamp
      $row.UUID = $s.uuid
      $row.DomainUUID = $dom
      [void]$table.Rows.Add($row)
    }
    $snapGrid.DataSource = $table
    $snapCount.Text = "$($snaps.Count) snapshot(s)"
    Say "Loaded $($snaps.Count) snapshot(s)."
  } finally { Set-Busy $false }
}

function Remove-SelectedSnapshot {
  if ($snapGrid.SelectedRows.Count -lt 1) { Show-Msg "Select a snapshot." "Warning"; return }
  $uuid = [string]$snapGrid.SelectedRows[0].Cells["UUID"].Value
  $label = [string]$snapGrid.SelectedRows[0].Cells["Label"].Value
  $a = [Windows.Forms.MessageBox]::Show("Delete snapshot '$label'?", $script:AppTitle, "YesNo", "Warning")
  if ($a -ne "Yes") { return }
  Set-Busy $true
  try {
    Say "--- Delete snapshot $uuid"
    $r = Invoke-Hc DELETE "/v1/VirDomainSnapshot/$uuid"
    if ($r.Code -notin @("200", "201", "204")) { Say "Delete failed ($($r.Code)): $($r.Body)"; return }
    $parsed = ConvertFrom-HcJson $r.Body
    $tag = if ($parsed -and $parsed.taskTag) { [string]$parsed.taskTag } else { $null }
    [void](Wait-HcTask $tag)
    Show-Snapshots
  } finally { Set-Busy $false }
}

$refreshSnapsBtn.Add_Click({ Show-Snapshots })
$deleteSnapBtn.Add_Click({ Remove-SelectedSnapshot })

# ========== Tab: SNMP ==========
$tabSnmp = New-Object Windows.Forms.TabPage
$tabSnmp.Text = "SNMP"
$commBox = New-TextBox 140 20 280
$snmpOut = New-Object Windows.Forms.TextBox
$snmpOut.Multiline = $true; $snmpOut.ReadOnly = $true; $snmpOut.ScrollBars = "Vertical"
$snmpOut.Font = New-Object Drawing.Font("Consolas", 9)
$snmpOut.Location = New-Object Drawing.Point(12, 100)
$snmpOut.Size = New-Object Drawing.Size(860, 280)
$snmpOut.Anchor = "Top,Bottom,Left,Right"
$checkSnmpBtn = New-Button "Check SNMP" 12 58 120
$enableSnmpBtn = New-Button "Enable SNMP" 140 58 120
$tabSnmp.Controls.AddRange(@(
  (New-Label "Community string" 12 20 120), $commBox,
  $checkSnmpBtn, $enableSnmpBtn, $snmpOut
))

function Write-Snmp([string]$text) {
  $snmpOut.AppendText("$text`r`n")
  Say $text
}

function Get-SnmpStatus {
  $c = Invoke-Hc GET "/v1/Cluster"
  if ($c.Code -eq "401") { Write-Snmp "Login failed (401). Check the login and password."; return $null }
  if ($c.Code -ne "200") { Write-Snmp "Could not reach the cluster ($($c.Code)): $($c.Body)"; return $null }
  $rec = Get-FirstRecord (ConvertFrom-HcJson $c.Body)
  $ver = if ($rec.icosVersion) { $rec.icosVersion } else { "unknown" }
  $name = if ($rec.clusterName) { $rec.clusterName } else { "" }
  Write-Snmp "Cluster $name  HyperCore $ver"
  Set-Connected $true "$name  -  HyperCore $ver"
  $s = Invoke-Hc GET "/v2/SNMPConfig"
  if ($s.Code -eq "404") { Write-Snmp "This cluster has no SNMP API. It needs HyperCore 9.7.1 or newer."; return $null }
  if ($s.Code -ne "200") { Write-Snmp "SNMP status failed ($($s.Code)): $($s.Body)"; return $null }
  Write-Snmp "SNMP status: $($s.Body)"
  return ($s.Body -notmatch '^\s*\[\s*\]\s*$' -and $s.Body -notmatch '(?i)not enabled|disabled')
}

$checkSnmpBtn.Add_Click({
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  $snmpOut.Clear()
  try { Write-Snmp "--- Check $($ipBox.Text.Trim())"; $null = Get-SnmpStatus }
  finally { Set-Busy $false }
})

$enableSnmpBtn.Add_Click({
  if (-not (Test-Credentials)) { return }
  if (-not $commBox.Text.Trim()) { Show-Msg "Enter the community string." "Warning"; return }
  Set-Busy $true
  $snmpOut.Clear()
  try {
    Write-Snmp "--- Enable on $($ipBox.Text.Trim())"
    $on = Get-SnmpStatus
    if ($null -eq $on) { return }
    if ($on) {
      $a = [Windows.Forms.MessageBox]::Show(
        "SNMP is already on for this cluster. Add this community string anyway?",
        $script:AppTitle, "YesNo", "Question")
      if ($a -ne "Yes") { Write-Snmp "No change made."; return }
    }
    $body = @{ communityName = $commBox.Text.Trim() } | ConvertTo-Json -Compress
    $r = Invoke-Hc POST "/v2/SNMPConfig" $body
    if ($r.Code -ne "200") { Write-Snmp "Enable failed ($($r.Code)): $($r.Body)"; return }
    Write-Snmp "Enable sent."
    $parsed = ConvertFrom-HcJson $r.Body
    if ($parsed -and $parsed.taskTag) { [void](Wait-HcTask ([string]$parsed.taskTag)) }
    elseif ($r.Body -match '"taskTag"\s*:\s*"?([^",}\s]+)') { [void](Wait-HcTask $Matches[1]) }
    $null = Get-SnmpStatus
  } finally { Set-Busy $false }
})

# ========== Tab: Alerts ==========
$tabAlerts = New-Object Windows.Forms.TabPage
$tabAlerts.Text = "Alerts"
$alertGrid = New-Grid 12 48 860 320
$alertGrid.Anchor = "Top,Bottom,Left,Right"
$refreshAlertsBtn = New-Button "Refresh conditions" 12 12 150
$alertCount = New-Label "" 180 14 500 22
$tabAlerts.Controls.AddRange(@($refreshAlertsBtn, $alertCount, $alertGrid))

function Show-Conditions {
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    Say "--- Conditions"
    $r = Invoke-Hc GET "/v1/Condition"
    if ($r.Code -ne "200") { Say "Conditions failed ($($r.Code)): $($r.Body)"; return }
    $items = @(ConvertFrom-HcJson $r.Body)
    $table = New-Object System.Data.DataTable
    foreach ($col in @("Severity", "Set", "Type", "Message", "UUID")) { [void]$table.Columns.Add($col) }
    $setCount = 0
    foreach ($c in $items) {
      $isSet = $false
      if ($null -ne $c.value) {
        if ($c.value -is [bool]) { $isSet = [bool]$c.value }
        else { $isSet = ([string]$c.value) -match '^(?i)true|1$' }
      }
      if ($isSet) { $setCount++ }
      $row = $table.NewRow()
      $row.Severity = $c.severity
      $row.Set = $isSet
      $row.Type = $c.alertType
      $row.Message = if ($c.formattedMessage) { $c.formattedMessage } elseif ($c.message) { $c.message } else { "" }
      $row.UUID = $c.uuid
      [void]$table.Rows.Add($row)
    }
    $alertGrid.DataSource = $table
    $alertCount.Text = "$($items.Count) condition(s), $setCount set"
    Say "Loaded $($items.Count) condition(s), $setCount set."
  } finally { Set-Busy $false }
}

$refreshAlertsBtn.Add_Click({ Show-Conditions })

# ========== Tab: Settings ==========
$tabSettings = New-Object Windows.Forms.TabPage
$tabSettings.Text = "Settings"
$settingsOut = New-Object Windows.Forms.TextBox
$settingsOut.Multiline = $true; $settingsOut.ReadOnly = $true; $settingsOut.ScrollBars = "Both"
$settingsOut.Font = New-Object Drawing.Font("Consolas", 9)
$settingsOut.WordWrap = $false
$settingsOut.Location = New-Object Drawing.Point(12, 48)
$settingsOut.Size = New-Object Drawing.Size(860, 360)
$settingsOut.Anchor = "Top,Bottom,Left,Right"
$dnsBtn = New-Button "DNS" 12 12 80
$timeBtn = New-Button "Time / NTP" 100 12 100
$emailBtn = New-Button "Email alerts" 210 12 110
$syslogBtn = New-Button "Syslog" 330 12 90
$usersBtn = New-Button "Users" 430 12 80
$isoBtn = New-Button "ISOs" 520 12 80
$tabSettings.Controls.AddRange(@($dnsBtn, $timeBtn, $emailBtn, $syslogBtn, $usersBtn, $isoBtn, $settingsOut))

function Show-SettingsPath([string]$title, [string]$path) {
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    Say "--- $title"
    $r = Invoke-Hc GET $path
    if ($r.Code -ne "200") { Say "$title failed ($($r.Code)): $($r.Body)"; $settingsOut.Text = $r.Body; return }
    try {
      $obj = ConvertFrom-HcJson $r.Body
      $pretty = $obj | ConvertTo-Json -Depth 8
      $settingsOut.Text = $pretty
    } catch {
      $settingsOut.Text = $r.Body
    }
    Say "$title loaded."
  } finally { Set-Busy $false }
}

$dnsBtn.Add_Click({ Show-SettingsPath "DNS" "/v1/DNSConfig" })
$timeBtn.Add_Click({
  if (-not (Test-Credentials)) { return }
  Set-Busy $true
  try {
    Say "--- Time / NTP"
    $tz = Invoke-Hc GET "/v1/TimeZone"
    $ts = Invoke-Hc GET "/v1/TimeSource"
    $settingsOut.Text = @"
=== TimeZone ($($tz.Code)) ===
$($tz.Body)

=== TimeSource / NTP ($($ts.Code)) ===
$($ts.Body)
"@
    Say "Time settings loaded."
  } finally { Set-Busy $false }
})
$emailBtn.Add_Click({ Show-SettingsPath "Email alert targets" "/v1/AlertEmailTarget" })
$syslogBtn.Add_Click({ Show-SettingsPath "Syslog targets" "/v1/AlertSyslogTarget" })
$usersBtn.Add_Click({ Show-SettingsPath "Users" "/v1/User" })
$isoBtn.Add_Click({ Show-SettingsPath "ISOs" "/v1/ISO" })

# ========== Tab: API explorer ==========
$tabApi = New-Object Windows.Forms.TabPage
$tabApi.Text = "API"
$methodBox = New-Object Windows.Forms.ComboBox
$methodBox.DropDownStyle = "DropDownList"
$methodBox.Items.AddRange(@("GET", "POST", "PATCH", "DELETE"))
$methodBox.SelectedIndex = 0
$methodBox.Location = New-Object Drawing.Point(12, 16)
$methodBox.Size = New-Object Drawing.Size(90, 24)
$pathBox = New-TextBox 110 16 520
$pathBox.Text = "/v1/Cluster"
$pathHint = New-Label "Path under /rest  (e.g. /v1/VirDomain or /v2/SNMPConfig)" 640 16 240 36
$bodyLabel = New-Label "JSON body (POST/PATCH)" 12 52 160
$apiBody = New-Object Windows.Forms.TextBox
$apiBody.Multiline = $true; $apiBody.ScrollBars = "Vertical"
$apiBody.Location = New-Object Drawing.Point(12, 76)
$apiBody.Size = New-Object Drawing.Size(860, 80)
$apiBody.Font = New-Object Drawing.Font("Consolas", 9)
$apiBody.Anchor = "Top,Left,Right"
$sendApiBtn = New-Button "Send" 12 168 100
$apiOut = New-Object Windows.Forms.TextBox
$apiOut.Multiline = $true; $apiOut.ReadOnly = $true; $apiOut.ScrollBars = "Both"
$apiOut.Font = New-Object Drawing.Font("Consolas", 9)
$apiOut.WordWrap = $false
$apiOut.Location = New-Object Drawing.Point(12, 208)
$apiOut.Size = New-Object Drawing.Size(860, 200)
$apiOut.Anchor = "Top,Bottom,Left,Right"
$tabApi.Controls.AddRange(@($methodBox, $pathBox, $pathHint, $bodyLabel, $apiBody, $sendApiBtn, $apiOut))

$sendApiBtn.Add_Click({
  if (-not (Test-Credentials)) { return }
  $method = [string]$methodBox.SelectedItem
  $path = $pathBox.Text.Trim()
  if (-not $path) { Show-Msg "Enter an API path." "Warning"; return }
  if (-not $path.StartsWith("/")) { $path = "/$path" }
  if ($method -ne "GET") {
    $a = [Windows.Forms.MessageBox]::Show(
      "Send $method $path to the cluster? Mutating calls wait for taskTag when present.",
      $script:AppTitle, "YesNo", "Warning")
    if ($a -ne "Yes") { return }
  }
  Set-Busy $true
  try {
    Say "--- $method $path"
    $body = if ($method -in @("POST", "PATCH", "PUT")) { $apiBody.Text } else { "" }
    $r = Invoke-Hc $method $path $body
    $apiOut.Text = "HTTP $($r.Code)`r`n`r`n$($r.Body)"
    if ($method -ne "GET" -and $r.Code -match '^2') {
      $parsed = ConvertFrom-HcJson $r.Body
      if ($parsed -and $parsed.taskTag) { [void](Wait-HcTask ([string]$parsed.taskTag)) }
    }
    Say "$method $path -> $($r.Code)"
  } finally { Set-Busy $false }
})

# Assemble tabs
$tabs.TabPages.AddRange(@($tabCluster, $tabVms, $tabSnaps, $tabSnmp, $tabAlerts, $tabSettings, $tabApi))

# Connect button = cluster refresh
$connectBtn.Add_Click({ Show-ClusterInfo })
$form.AcceptButton = $connectBtn

$form.Add_Shown({
  Say "Scale HyperCore API Toolkit ready. Enter cluster credentials and click Connect."
  Say "Log file: $logFile"
})

$form.Add_FormClosed({ $passBox.Text = "" })

[void]$form.ShowDialog()
