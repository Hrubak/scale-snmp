# Behavior tests for the SuperAudit report. No cluster and no WinForms.
$ErrorActionPreference = "Stop"
$script:failed = 0

function Assert-True([string]$name, [bool]$condition) {
  if (-not $condition) {
    Write-Host "FAIL $name"
    $script:failed++
  }
}

function Assert-Equal([string]$name, $actual, $expected) {
  if ([string]$actual -ne [string]$expected) {
    Write-Host "FAIL $name"
    Write-Host "  actual:   [$actual]"
    Write-Host "  expected: [$expected]"
    $script:failed++
  }
}

$lib = Join-Path (Split-Path $PSScriptRoot -Parent) "ScaleSuperAudit.ps1"
. $lib

$cluster = [pscustomobject]@{
  clusterName = "Prod Cluster"
  companyName = "Acme"
  icosVersion = "9.4.33"
}
$driveIn = [pscustomobject]@{
  slot = 1
  serialNumber = "SN1"
  type = "SSD"
  capacityBytes = 2000000000000
  usedBytes = 500000000000
  temperature = 40
  maxTemperature = 55
  temperatureThreshold = 70
  isHealthy = $true
  reallocatedSectors = 0
  errorCount = 0
  currentDisposition = "IN"
}
$driveOut = [pscustomobject]@{
  slot = 2
  serialNumber = "SN2"
  type = "HDD"
  capacityBytes = 1000000000000
  usedBytes = 100000000000
  temperature = 30
  maxTemperature = 40
  temperatureThreshold = 60
  isHealthy = $false
  reallocatedSectors = 0
  errorCount = 0
  currentDisposition = "OUT"
}
$node1 = [pscustomobject]@{
  uuid = "n1"
  lanIP = "10.0.0.1"
  backplaneIP = "10.0.1.1"
  numCores = 8
  numThreads = 16
  memSize = 32000000000
  capacity = 2000000000000
  cpuUsage = 85.5
  memUsagePercentage = 40
  networkStatus = "ONLINE"
  currentDisposition = "IN"
  drives = @($driveIn)
}
$node2 = [pscustomobject]@{
  uuid = "n2"
  lanIP = "10.0.0.2"
  backplaneIP = "10.0.1.2"
  numCores = 4
  numThreads = 8
  memSize = 16000000000
  capacity = 1000000000000
  cpuUsage = 10
  memUsagePercentage = 20
  networkStatus = "OFFLINE"
  currentDisposition = "IN"
  drives = @($driveOut)
}
$disk1 = [pscustomobject]@{
  type = "VIRTIO_DISK"
  slot = 0
  capacity = 100000000000
  allocation = 96000000000
  tieringPriorityFactor = 8
  cacheMode = "writeback"
  disableSnapshotting = $false
}
$cdrom = [pscustomobject]@{
  type = "IDE_CDROM"
  path = "/var/iso/ubuntu.iso"
  slot = "cdrom0"
}
$net1 = [pscustomobject]@{
  ipv4Addresses = @("192.168.1.10")
  ipv6Addresses = @("fe80::1%10")
  vlan = 10
  macAddress = "AA:BB"
  type = "VIRTIO"
  connected = $true
}
$web1 = [pscustomobject]@{
  uuid = "uuid-web1"
  name = "web1"
  description = 'Say "hi", friend'
  tags = @("production")
  mem = 4000000000
  numVCPU = 2
  state = "RUNNING"
  bootDevices = @([pscustomobject]@{ type = "HD" }, [pscustomobject]@{ type = "CDROM" })
  machineType = "UEFI"
  operatingSystem = "Linux"
  affinityStrategy = [pscustomobject]@{ strictAffinity = $false; preferredNodeUUID = "" }
  nodeUUID = "n1"
  snapUUIDs = @()
  blockDevs = @($null, $disk1, $cdrom)
  netDevs = @($null, $net1)
  snapshotScheduleUUID = ""
  remoteClusterConnectionUUID = ""
}
$disk2 = [pscustomobject]@{
  type = "VIRTIO_DISK"
  slot = 1
  capacity = 10000000000
  allocation = 1000000000
  tieringPriorityFactor = 0
  cacheMode = "none"
  disableSnapshotting = $false
}
$web2 = [pscustomobject]@{
  uuid = "uuid-web2"
  name = "app"
  description = ""
  tags = @()
  mem = 2500000000
  numVCPU = 1
  state = "RUNNING"
  machineType = "BIOS"
  operatingSystem = "Windows"
  affinityStrategy = [pscustomobject]@{ strictAffinity = $true; preferredNodeUUID = "" }
  nodeUUID = "n2"
  snapUUIDs = @("snap1")
  blockDevs = @($disk2)
  netDevs = @()
  snapshotScheduleUUID = "s1"
}
$replica = [pscustomobject]@{
  uuid = "uuid-replica"
  name = "replica1"
  description = ""
  mem = 1000000000
  numVCPU = 1
  state = "STOPPED"
  nodeUUID = "n1"
  replicationSourceVirDomainUUID = "uuid-web1"
  remoteClusterConnectionUUID = "rc1"
  snapUUIDs = @()
  blockDevs = @()
  netDevs = @()
}
$replication = [pscustomobject]@{
  uuid = "rc1"
  remoteClusterName = "DR-Site"
  password = "super-secret-token"
  remotePassword = "another-secret"
}
$schedule = [pscustomobject]@{ uuid = "s1"; name = "Nightly" }
$isoAlpine = [pscustomobject]@{
  name = "alpine.iso"
  size = 1000000000
  path = "/isos/alpine.iso"
  mounts = 1
  readyForInsert = $false
}
$isoUbuntu = [pscustomobject]@{
  name = "ubuntu.iso"
  size = 5000000000
  path = "/isos/ubuntu.iso"
  mounts = @("a", "b")
  readyForInsert = $true
}
$conditionOn = [pscustomobject]@{
  severity = "CRITICAL"
  alertType = "Disk"
  formattedMessage = "Disk degraded"
  uuid = "c1"
  value = $true
}
$conditionOff = [pscustomobject]@{
  severity = "INFO"
  alertType = "Other"
  formattedMessage = "Cleared"
  uuid = "c2"
  value = $false
}

$report = New-SaReport -Cluster $cluster -Nodes @($node1, $node2) -Vms @($web1, $web2, $replica) `
  -Replication @($replication) -Schedules @($schedule) -Isos @($isoAlpine, $isoUbuntu) `
  -Conditions @($conditionOn, $conditionOff) -Notes @("RemoteClusterConnection unavailable (HTTP 404).") `
  -CollectedAt "2026-10-15 12:00:00" -ElapsedSeconds 2.2 -ToolVersion "0.5.0"

Assert-Equal "vm rows" $report.VmRows.Count 3
Assert-Equal "file stem" $report.FileStem "prod_cluster"
Assert-Equal "score" $report.ComplianceScore "30.0"
Assert-Equal "elapsed" $report.ElapsedText "2s"

$expectedWeb1 = @(
  "uuid-web1", "4", "PRODUCTION VM", "2", "RUNNING", "10.0.0.1", "85.50",
  "web1", 'Say "hi", friend', "production", "HD/CDROM", "UEFI", "Linux", "",
  "VIRTIO_DISK", "0", "100.0", "96.0", "4 - NORMAL (8)", "writeback", "Enabled",
  "0", "ubuntu.iso", "192.168.1.10/fe80::1", "10", "AA:BB", "VIRTIO", "Connected",
  "", ""
)
Assert-Equal "web1 width" $expectedWeb1.Count 30
$row0 = $report.VmRows[0]
Assert-Equal "web1 width actual" @($row0).Count 30
for ($i = 0; $i -lt 30; $i++) {
  Assert-Equal ("web1[{0}] {1}" -f $i, $report.VmHeaders[$i]) $row0[$i] $expectedWeb1[$i]
}
$row1 = $report.VmRows[1]
Assert-Equal "web2 type" $row1[2] "VM"
Assert-Equal "web2 ha" $row1[13] "STRICT"
Assert-Equal "web2 mem" $row1[1] "2.5"
Assert-Equal "web2 cpu" $row1[6] "10.00"
Assert-Equal "web2 tier" $row1[18] "0 - OFF (0)"
Assert-Equal "web2 schedule" $row1[28] "Nightly"
Assert-Equal "web2 snaps" $row1[21] "1"
$row2 = $report.VmRows[2]
Assert-Equal "replica type" $row2[2] "VM REPLICA"
Assert-Equal "replica cpu" $row2[6] "N/A"
Assert-Equal "replica size" $row2[16] "0"
Assert-Equal "replica partner" $row2[29] "DR-Site"

Assert-Equal "node capacity" $report.NodeRows[0][4] "2.0"
Assert-Equal "node used" $report.NodeRows[0][5] "0.5"
Assert-Equal "node cpu" $report.NodeRows[0][6] "85.50"
Assert-Equal "node mem" $report.NodeRows[0][3] "32.0"
Assert-Equal "node cores" $report.NodeRows[0][2] "8/16"
Assert-Equal "node2 offline cell" $report.NodeRows[1][8] "OFFLINE"
Assert-Equal "drive health" $report.DriveRows[0][10] "Healthy"
Assert-Equal "drive usage" $report.DriveRows[0][6] "25.00"
Assert-Equal "drive failed" $report.DriveRows[1][10] "Failed"
$degree = [string]([char]0x00B0)
Assert-Equal "drive header temp" $report.DriveHeaders[7] "Temperature ($degree`C)"

Assert-Equal "iso first" $report.IsoRows[0][0] "alpine.iso"
Assert-Equal "iso mounts int" $report.IsoRows[0][3] "1"
Assert-Equal "iso second" $report.IsoRows[1][0] "ubuntu.iso"
Assert-Equal "iso mounts list" $report.IsoRows[1][3] "2"
Assert-Equal "iso ready" $report.IsoRows[1][4] "Yes"
Assert-Equal "iso size" $report.IsoRows[1][1] "5.0"

Assert-Equal "conditions" $report.ConditionRows.Count 1
Assert-Equal "condition msg" $report.ConditionRows[0][2] "Disk degraded"

Assert-Equal "flat warnings" $report.FlatWarnings.Count 5
Assert-Equal "warn0" $report.FlatWarnings[0] "web1: No snapshots configured (Running VM)"
Assert-Equal "warn1" $report.FlatWarnings[1] "web1: No HA policy configured (Production VM)"
Assert-Equal "warn2" $report.FlatWarnings[2] "web1: No replication configured (Production VM)"
Assert-Equal "warn3" $report.FlatWarnings[3] "Node 10.0.0.1: High CPU usage (85.5%)"
Assert-Equal "warn4" $report.FlatWarnings[4] "web1: Disk 0 is 96% full"
Assert-Equal "grouped0" $report.WarningRows[0][0] "CRITICAL"
Assert-Equal "grouped0 issue" $report.WarningRows[0][1] "web1: No snapshots configured (Running VM)"
Assert-Equal "grouped1 issue" $report.WarningRows[1][1] "web1: Disk 0 is 96% full"
Assert-Equal "snap advice" $report.WarningRows[0][2] "Configure snapshot schedule immediately. Snapshots are critical for data protection and recovery."
Assert-Equal "disk advice" $report.WarningRows[1][2] "URGENT: Free up disk space or expand storage immediately to prevent VM failures."

Assert-Equal "comp snap" $report.ComplianceRows[0][3] "FAIL"
Assert-Equal "comp snap actual" $report.ComplianceRows[0][1] "50.0"
Assert-Equal "comp ha" $report.ComplianceRows[1][1] "0.0"
Assert-Equal "comp disk" $report.ComplianceRows[3][1] "50.0"
Assert-Equal "comp cpu" $report.ComplianceRows[4][1] "50.0"
Assert-True "summary score" ($report.SummaryText.Contains("Compliance score: 30.0"))
Assert-True "summary storage" ($report.SummaryText.Contains("Storage allocated: 1.9 TB"))
Assert-True "summary used" ($report.SummaryText.Contains("Storage used: 0.5 TB (25.0%)"))
Assert-True "summary memory" ($report.SummaryText.Contains("Memory allocated: 7.5 GB"))
Assert-True "summary note" ($report.SummaryText.Contains("RemoteClusterConnection unavailable (HTTP 404)."))
Assert-True "html title" ($report.Html.Contains("SUPERAUDIT SUMMARY REPORT"))
Assert-True "html vm" ($report.Html.Contains("VM Inventory"))
Assert-True "html compliance" ($report.Html.Contains("Compliance Report"))
Assert-True "html capacity" ($report.Html.Contains("Capacity Planning"))
Assert-True "no secret" (-not $report.Html.Contains("super-secret-token"))
Assert-True "no secret 2" (-not $report.SummaryText.Contains("another-secret"))
Assert-True "no auth header" (-not $report.Html.Contains("Authorization"))

$csv = Format-SaCsv $report.VmHeaders $report.VmRows
Assert-True "csv quoted comma" ($csv.Contains('"Say ""hi"", friend"'))
Assert-True "csv header quoted" ($csv.StartsWith('"VM UUID","Mem Alloc (GB)"'))

$out = Export-SaReport -Report $report -Folder ([IO.Path]::GetTempPath()) -Stamp "teststamp"
Assert-True "html exists" (Test-Path -LiteralPath $out.HtmlPath)
Assert-Equal "html name" ([IO.Path]::GetFileName($out.HtmlPath)) "superaudit_prod_cluster.html"
$csvFile = Get-Content -LiteralPath (Join-Path $out.Directory "superaudit_prod_cluster.csv") -Raw
Assert-True "csv file quote" ($csvFile.Contains('"Say ""hi"", friend"'))
$bytes = [IO.File]::ReadAllBytes($out.HtmlPath)
Assert-Equal "html bom 0" $bytes[0] 239
Assert-Equal "html bom 1" $bytes[1] 187
Assert-Equal "html bom 2" $bytes[2] 191
Remove-Item -LiteralPath $out.Directory -Recurse -Force

$bareNode = [pscustomobject]@{ uuid = "n9"; lanIP = "10.9.9.9"; numCores = 2; numThreads = 2 }
$extra = [pscustomobject]@{
  nodeUUID = "n9"
  slot = 0
  type = "SSD"
  capacityBytes = 1000000000
  usedBytes = 0
  currentDisposition = "IN"
  isHealthy = $true
}
$merged = New-SaReport -Cluster $cluster -Nodes @($bareNode) -Vms @() -ExtraDrives @($extra) -CollectedAt "2026-10-15 12:00:00"
Assert-Equal "fallback drives" $merged.DriveRows.Count 1
Assert-Equal "fallback slot" $merged.DriveRows[0][1] "0"
Assert-Equal "empty vm score" $merged.ComplianceScore "100.0"
Assert-Equal "snap na" $merged.ComplianceRows[0][3] "N/A"

$paths = Get-SaRequestPaths
$pathCount = 0
foreach ($prop in $paths.PSObject.Properties) {
  $pathCount++
  $p = [string]$prop.Value
  $okPrefix = $p.StartsWith("/rest/v1/") -or $p.StartsWith("/rest/v2/")
  Assert-True ("request path " + $prop.Name) $okPrefix
  Assert-True ("no double rest " + $prop.Name) (-not $p.Contains("/rest/rest/"))
  Assert-Equal ("normalized " + $prop.Name) (Get-HcApiPath $p) $p
}
Assert-True "path count" ($pathCount -ge 9)
Assert-Equal "cluster path" $paths.Cluster "/rest/v1/Cluster"
Assert-Equal "vm path" $paths.Vms "/rest/v1/VirDomain"
Assert-Equal "node path" $paths.Nodes "/rest/v1/Node"
Assert-Equal "v1 prefix once" (Get-HcApiPath "/v1/Cluster") "/rest/v1/Cluster"
Assert-Equal "v2 prefix once" (Get-HcApiPath "/v2/SNMPConfig") "/rest/v2/SNMPConfig"
Assert-Equal "update untouched" (Get-HcApiPath "/update/update_status.json") "/update/update_status.json"
Assert-Equal "rest left alone" (Get-HcApiPath "/rest/v1/Node") "/rest/v1/Node"

$apiSrc = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) "ScaleAPI.ps1"))
Assert-True "named timeout" ($apiSrc.Contains('Invoke-Hc -Method GET -Path $path -Body "" -TimeoutSec 120'))
Assert-True "no positional body" (-not $apiSrc.Contains('Invoke-Hc GET $path 120'))

$skippedReport = New-SaReport -Cluster $null -Nodes @() -Vms @() -SkippedSections @("Cluster", "Nodes", "VMs") `
  -Notes @("Cluster skipped (HTTP 400). /rest/v1/Cluster") -CollectedAt "2026-10-15 12:00:00"
Assert-True "cluster skipped" ($skippedReport.SummaryText.Contains("Cluster: skipped"))
Assert-True "vms skipped" ($skippedReport.SummaryText.Contains("VMs processed: skipped"))
Assert-True "nodes skipped" ($skippedReport.SummaryText.Contains("Nodes: skipped"))
Assert-True "skip note kept" ($skippedReport.SummaryText.Contains("Cluster skipped (HTTP 400). /rest/v1/Cluster"))
Assert-True "html skipped" ($skippedReport.Html.Contains("This section was skipped."))

$srcFiles = @(
  (Join-Path (Split-Path $PSScriptRoot -Parent) "ScaleSuperAudit.ps1"),
  (Join-Path (Split-Path $PSScriptRoot -Parent) "ScaleAPI.ps1")
)
foreach ($src in $srcFiles) {
  $raw = [IO.File]::ReadAllBytes($src)
  Assert-Equal ("bom " + [IO.Path]::GetFileName($src)) $raw[0] 239
  $high = 0
  foreach ($b in $raw) { if ($b -gt 127) { $high++ } }
  Assert-Equal ("ascii " + [IO.Path]::GetFileName($src)) $high 3
}

if ($script:failed -gt 0) {
  Write-Host ("{0} assertion(s) failed" -f $script:failed)
  exit 1
}
Write-Host "SuperAudit tests passed"
exit 0
