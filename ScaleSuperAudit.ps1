# SuperAudit report for the Scale HyperCore API Toolkit.
# Read-only. These functions never see the password or the Authorization header.
#
# Data collected and the report columns follow Scale Computing's SuperAudit example:
# https://github.com/ScaleComputing/RestAPIExamples/tree/master/specific_task/superaudit
# Author of that example: Scale Computing Support Team.
# That repository does not publish a license file. This file reimplements the
# one-time GET audit in PowerShell. It does not copy the Python source.
#
# The upstream workbook writes Summary, VM Inventory, Node Hardware, Drive Health,
# ISO Library, and Warnings. Compliance Report and Capacity Planning follow the
# categories and targets in that example's README (the Python writer does not
# emit those two sheets). Active conditions are included because the example's
# daemon stores GET /rest/v1/Condition; the one-time workbook does not.

function Get-SaProp($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IDictionary]) {
    if ($obj.Contains($name)) { return $obj[$name] }
    return $null
  }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Test-SaHasProp($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  if ($obj -is [System.Collections.IDictionary]) { return [bool]$obj.Contains($name) }
  return ($null -ne $obj.PSObject.Properties[$name])
}

function ConvertTo-SaArray($value) {
  # ArrayList is not unwrapped by assignment the way a one-element Object[] is.
  $list = New-Object System.Collections.ArrayList
  if ($null -ne $value) {
    $enumerable = $value -is [System.Collections.IEnumerable] -and -not ($value -is [string]) -and -not ($value -is [System.Collections.IDictionary])
    if ($enumerable) {
      foreach ($item in $value) { [void]$list.Add($item) }
    } else {
      [void]$list.Add($value)
    }
  }
  Write-Output -NoEnumerate $list
}

function Add-SaRow($list, [object[]]$cells) {
  $row = New-Object System.Collections.ArrayList
  foreach ($c in $cells) {
    if ($null -eq $c) { [void]$row.Add("") } else { [void]$row.Add([string]$c) }
  }
  [void]$list.Add($row)
}

function Format-SaInvariant([decimal]$value, [string]$format) {
  return $value.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-SaRoundString($bytes, [decimal]$divisor, [int]$digits) {
  if ($null -eq $bytes -or "$bytes" -eq "") { $bytes = 0 }
  $number = [decimal]$bytes / $divisor
  $rounded = [Math]::Round($number, $digits, [MidpointRounding]::ToEven)
  $fmt = "0"
  if ($digits -gt 0) { $fmt = "0." + ("0" * $digits) }
  $text = Format-SaInvariant $rounded $fmt
  while ($text.Contains(".") -and $text.EndsWith("0") -and -not $text.EndsWith(".0")) {
    $text = $text.Substring(0, $text.Length - 1)
  }
  return $text
}

function ConvertTo-SaMemoryGb($bytes) {
  if ($null -eq $bytes -or "$bytes" -eq "" -or [decimal]$bytes -eq 0) { return "0" }
  $gb = [decimal]$bytes / [decimal]1000000000
  $rounded = [Math]::Round($gb, 3, [MidpointRounding]::ToEven)
  if ($rounded -eq [decimal]::Truncate($rounded)) {
    return ([int64]$rounded).ToString([Globalization.CultureInfo]::InvariantCulture)
  }
  $text = Format-SaInvariant $rounded "0.000"
  return $text.TrimEnd("0").TrimEnd(".")
}

function Format-SaFixed2($number) {
  if ($null -eq $number -or "$number" -eq "") { $number = 0 }
  return ([decimal]$number).ToString("0.00", [Globalization.CultureInfo]::InvariantCulture)
}

function Format-SaNum1($number) {
  return ([double]$number).ToString("N1", [Globalization.CultureInfo]::InvariantCulture)
}

function Format-SaPct1($number) {
  $rounded = [Math]::Round([double]$number, 1, [MidpointRounding]::ToEven)
  return $rounded.ToString("0.0", [Globalization.CultureInfo]::InvariantCulture)
}

function Format-SaPercent0($number) {
  $rounded = [Math]::Round([double]$number, 0, [MidpointRounding]::ToEven)
  return ([int64]$rounded).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Format-SaElapsed([double]$seconds) {
  if ($seconds -lt 0) { $seconds = 0 }
  if ($seconds -lt 60) { return ("{0}s" -f [int][Math]::Floor($seconds)) }
  if ($seconds -lt 3600) {
    $mins = [int][Math]::Floor($seconds / 60)
    $secs = [int][Math]::Floor($seconds % 60)
    return ("{0}m {1}s" -f $mins, $secs)
  }
  $hours = [int][Math]::Floor($seconds / 3600)
  $mins = [int][Math]::Floor(($seconds % 3600) / 60)
  return ("{0}h {1}m" -f $hours, $mins)
}

function ConvertTo-SaSsdTier($tier) {
  if ($null -eq $tier -or "$tier" -eq "") { $tier = 0 }
  $key = ([int64][Math]::Truncate([double]$tier)).ToString([Globalization.CultureInfo]::InvariantCulture)
  $map = @{
    "0" = "0 - OFF (0)"
    "1" = "1 - MINIMAL (1)"
    "2" = "2 - VERY LOW (2)"
    "4" = "3 - LOW (4)"
    "8" = "4 - NORMAL (8)"
    "16" = "5 - HIGH (16)"
    "32" = "6 - VERY HIGH (32)"
    "64" = "7 - EXTREME (64)"
    "128" = "8 - ABSURD (128)"
    "256" = "9 - HYPERSPEED (256)"
    "1024" = "10 - LUDICROUS SPEED (1024)"
    "10240" = "11 - THESE GO TO 11 (10240)"
  }
  if ($map.ContainsKey($key)) { return [string]$map[$key] }
  return $key
}

function Clear-SaIpv6([string]$ip) {
  if ($null -eq $ip) { return "" }
  $cut = $ip.IndexOf("%")
  if ($cut -ge 0) { return $ip.Substring(0, $cut) }
  return $ip
}

function Get-SaFileStem([string]$name) {
  if ($null -eq $name) { $name = "" }
  $stem = [regex]::Replace($name, "[^\w\-.]", "_")
  $stem = [regex]::Replace($stem, "_+", "_")
  $stem = $stem.Trim("_").ToLowerInvariant()
  if (-not $stem) { return "cluster" }
  return $stem
}

function ConvertTo-SaHtmlText([string]$text) {
  if ($null -eq $text) { return "" }
  $safe = $text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
  return $safe.Replace("`r`n", "<br>").Replace("`n", "<br>").Replace("`r", "<br>")
}

function Get-SaVmType($vm) {
  $name = [string](Get-SaProp $vm "name")
  $tags = Get-SaProp $vm "tags"
  $tagText = ""
  if ($tags -is [string]) {
    $tagText = $tags
  } else {
    $parts = @()
    foreach ($tag in (ConvertTo-SaArray $tags)) {
      if ($null -ne $tag -and "$tag" -ne "") { $parts += [string]$tag }
    }
    $tagText = ($parts -join "/")
  }
  $tagsLower = $tagText.ToLowerInvariant()
  $nameLower = $name.ToLowerInvariant()
  if (Get-SaProp $vm "replicationSourceVirDomainUUID") { return "VM REPLICA" }
  if ($nameLower.Contains("template") -or $nameLower.Contains("tmpl")) { return "TEMPLATE" }
  if ($tagsLower) {
    if ($tagsLower.Contains("template")) { return "TEMPLATE" }
    if ($tagsLower.Contains("test") -or $tagsLower.Contains("testing")) { return "TEST VM" }
    if ($tagsLower.Contains("production") -or $tagsLower.Contains("prod")) { return "PRODUCTION VM" }
    if ($tagsLower.Contains("dev") -or $tagsLower.Contains("development")) { return "DEV VM" }
  }
  return "VM"
}

function Get-SaHaPolicy($vm) {
  $ha = Get-SaProp $vm "affinityStrategy"
  if ($null -eq $ha -or $ha -is [string]) { return "" }
  $strict = Get-SaProp $ha "strictAffinity"
  $preferred = Get-SaProp $ha "preferredNodeUUID"
  $strictText = ""
  if ($null -ne $strict) { $strictText = [string]$strict }
  # HyperCore returns strictAffinity as a boolean. The example compares it to
  # the string STRICT, which never matches that boolean, so real clusters would
  # show no HA policy. A boolean true is treated as STRICT.
  if ($strict -eq $true -or $strictText -eq "STRICT" -or $strictText -eq "True" -or $strictText -eq "true") {
    return "STRICT"
  }
  if ($preferred) { return "PREFERRED" }
  return ""
}

function Get-SaRecommendation([string]$warning, [string]$severity) {
  $lower = $warning.ToLowerInvariant()
  if ($lower.Contains("no snapshots")) {
    return "Configure snapshot schedule immediately. Snapshots are critical for data protection and recovery."
  }
  if ($lower.Contains("no ha policy") -or $lower.Contains("ha policy")) {
    return "Configure High Availability policy to ensure VM redundancy across nodes."
  }
  if ($lower.Contains("no replication")) {
    return "Consider configuring replication for disaster recovery and business continuity."
  }
  if ($lower.Contains("disk") -and $lower.Contains("full")) {
    if ($severity -eq "CRITICAL") {
      return "URGENT: Free up disk space or expand storage immediately to prevent VM failures."
    }
    return "Monitor disk usage closely and plan for storage expansion."
  }
  if ($lower.Contains("cpu")) {
    if ($severity -eq "CRITICAL") {
      return "URGENT: High CPU usage may impact VM performance. Migrate VMs to other nodes or add capacity."
    }
    return "Monitor CPU usage and consider load balancing VMs across nodes."
  }
  if ($lower.Contains("memory")) {
    return "Monitor memory usage and consider adding memory to nodes or rebalancing VM placement."
  }
  return "Review and address this issue to maintain optimal cluster health."
}

function Add-SaWarning($flat, $bySeverity, [string]$severity, [string]$message) {
  $seen = $false
  foreach ($existing in @($flat)) {
    if ([string]$existing -eq $message) { $seen = $true; break }
  }
  if (-not $seen) { [void]$flat.Add($message) }
  if (-not $bySeverity.ContainsKey($severity)) { return }
  $bucket = $bySeverity[$severity]
  foreach ($existing in @($bucket)) {
    if ([string]$existing -eq $message) { return }
  }
  [void]$bucket.Add($message)
}

function Get-SaTagText($vm) {
  $tags = Get-SaProp $vm "tags"
  if ($null -eq $tags) { return "" }
  if ($tags -is [string]) { return $tags }
  $parts = New-Object System.Collections.ArrayList
  foreach ($tag in (ConvertTo-SaArray $tags)) {
    if ($null -ne $tag -and "$tag" -ne "") { [void]$parts.Add([string]$tag) }
  }
  return ($parts -join "/")
}

function Get-SaBootOrder($vm) {
  $devices = (ConvertTo-SaArray (Get-SaProp $vm "bootDevices"))
  if ($devices.Count -eq 0) { return "" }
  $parts = New-Object System.Collections.ArrayList
  foreach ($device in $devices) {
    if ($null -eq $device -or "$device" -eq "") { continue }
    if ($device -is [string]) { [void]$parts.Add($device); continue }
    $kind = Get-SaProp $device "type"
    if ($null -eq $kind) { $kind = [string]$device }
    if ("$kind" -ne "") { [void]$parts.Add([string]$kind) }
  }
  return ($parts -join "/")
}

function Get-SaBaseName([string]$path) {
  if ($null -eq $path -or $path -eq "") { return "" }
  $normalized = $path.Replace("\", "/")
  $cut = $normalized.LastIndexOf("/")
  if ($cut -ge 0 -and $cut -lt ($normalized.Length - 1)) { return $normalized.Substring($cut + 1) }
  return $normalized
}

function Test-SaConditionSet($condition) {
  if (-not (Test-SaHasProp $condition "value")) { return $true }
  $value = Get-SaProp $condition "value"
  if ($null -eq $value) { return $true }
  if ($value -is [bool]) { return [bool]$value }
  return ([string]$value) -match "^(?i)true|1$"
}

function Get-SaBoolDefaultTrue($obj, [string]$name) {
  if (-not (Test-SaHasProp $obj $name)) { return $true }
  $value = Get-SaProp $obj $name
  if ($null -eq $value) { return $true }
  if ($value -is [bool]) { return [bool]$value }
  return -not (([string]$value) -match "^(?i)false|0$")
}

function Merge-SaNodeDrives($nodes, $extraDrives) {
  $nodeList = (ConvertTo-SaArray $nodes)
  $extras = (ConvertTo-SaArray $extraDrives)
  $merged = New-Object System.Collections.ArrayList
  foreach ($node in $nodeList) {
    $drives = (ConvertTo-SaArray (Get-SaProp $node "drives"))
    if ($drives.Count -eq 0 -and $extras.Count -gt 0) {
      $uuid = [string](Get-SaProp $node "uuid")
      $mine = New-Object System.Collections.ArrayList
      foreach ($drive in $extras) {
        if ([string](Get-SaProp $drive "nodeUUID") -eq $uuid) { [void]$mine.Add($drive) }
      }
      if ($mine.Count -gt 0) {
        $copy = New-Object PSObject
        foreach ($prop in $node.PSObject.Properties) {
          $copy | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
        $copy | Add-Member -NotePropertyName "drives" -NotePropertyValue $mine.ToArray() -Force
        $node = $copy
      }
    }
    [void]$merged.Add($node)
  }
  Write-Output -NoEnumerate $merged
}

function Format-SaCsv([System.Collections.IEnumerable]$headers, [System.Collections.IEnumerable]$rows) {
  $sb = New-Object System.Text.StringBuilder
  function Quote-Sa([string]$value) {
    if ($null -eq $value) { $value = "" }
    return '"' + $value.Replace('"', '""') + '"'
  }
  $headCells = New-Object System.Collections.ArrayList
  foreach ($header in $headers) { [void]$headCells.Add((Quote-Sa ([string]$header))) }
  [void]$sb.Append(($headCells -join ","))
  [void]$sb.Append("`r`n")
  foreach ($row in $rows) {
    $cells = New-Object System.Collections.ArrayList
    foreach ($cell in $row) { [void]$cells.Add((Quote-Sa ([string]$cell))) }
    [void]$sb.Append(($cells -join ","))
    [void]$sb.Append("`r`n")
  }
  return $sb.ToString()
}

function Format-SaHtmlTable([string]$caption, [System.Collections.IEnumerable]$headers, [System.Collections.IEnumerable]$rows) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("<h2>")
  [void]$sb.Append((ConvertTo-SaHtmlText $caption))
  [void]$sb.Append("</h2>`r`n<div class=`"sheet`"><table>`r`n<thead><tr>")
  foreach ($header in $headers) {
    [void]$sb.Append("<th>")
    [void]$sb.Append((ConvertTo-SaHtmlText ([string]$header)))
    [void]$sb.Append("</th>")
  }
  [void]$sb.Append("</tr></thead>`r`n<tbody>`r`n")
  $any = $false
  foreach ($row in $rows) {
    $any = $true
    [void]$sb.Append("<tr>")
    $index = 0
    foreach ($cell in $row) {
      $class = ""
      if ($index -eq 0 -and ($caption -eq "Warnings and Recommendations" -or $caption -eq "Compliance Report")) {
        $token = [string]$cell
        if ($token -eq "CRITICAL" -or $token -eq "FAIL") { $class = " class=`"bad`"" }
        elseif ($token -eq "WARNING") { $class = " class=`"warn`"" }
        elseif ($token -eq "INFO" -or $token -eq "N/A") { $class = " class=`"info`"" }
        elseif ($token -eq "PASS") { $class = " class=`"good`"" }
      }
      [void]$sb.Append("<td$class>")
      [void]$sb.Append((ConvertTo-SaHtmlText ([string]$cell)))
      [void]$sb.Append("</td>")
      $index++
    }
    [void]$sb.Append("</tr>`r`n")
  }
  if (-not $any) {
    $span = 0
    foreach ($header in $headers) { $span++ }
    if ($span -lt 1) { $span = 1 }
    [void]$sb.Append("<tr><td colspan=`"$span`">None</td></tr>`r`n")
  }
  [void]$sb.Append("</tbody></table></div>`r`n")
  return $sb.ToString()
}

function New-SaReport {
  param(
    $Cluster,
    $Nodes,
    $Vms,
    $Replication,
    $Schedules,
    $Isos,
    $Conditions,
    $ExtraDrives,
    [string[]]$Notes,
    [string[]]$SkippedSections,
    [string]$CollectedAt = "",
    [double]$ElapsedSeconds = 0,
    [string]$ToolVersion = "0.5.0"
  )

  $nodeItems = Merge-SaNodeDrives $Nodes $ExtraDrives
  $vmItems = ConvertTo-SaArray $Vms
  $scheduleItems = ConvertTo-SaArray $Schedules
  $replItems = ConvertTo-SaArray $Replication
  $isoItems = ConvertTo-SaArray $Isos
  $conditionItems = ConvertTo-SaArray $Conditions
  $noteItems = ConvertTo-SaArray $Notes

  $clusterObj = $Cluster
  $clusterList = ConvertTo-SaArray $Cluster
  if ($clusterList.Count -gt 0 -and (Test-SaHasProp $clusterList[0] "clusterName" -or Test-SaHasProp $clusterList[0] "icosVersion")) {
    $clusterObj = $clusterList[0]
  }
  $clusterName = [string](Get-SaProp $clusterObj "clusterName")
  if (-not $clusterName) { $clusterName = "Unknown" }
  $company = [string](Get-SaProp $clusterObj "companyName")
  if (-not $company) { $company = "Unknown" }
  $icos = [string](Get-SaProp $clusterObj "icosVersion")
  if (-not $icos -and $nodeItems.Count -gt 0) { $icos = [string](Get-SaProp $nodeItems[0] "icosVersion") }
  if (-not $icos) { $icos = "Unknown" }
  if (-not $CollectedAt) { $CollectedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

  $nodeByUuid = @{}
  foreach ($node in $nodeItems) {
    $id = [string](Get-SaProp $node "uuid")
    if ($id) { $nodeByUuid[$id] = $node }
  }
  $replByUuid = @{}
  foreach ($conn in $replItems) {
    $id = [string](Get-SaProp $conn "uuid")
    if (-not $id) { continue }
    $replByUuid[$id] = [string](Get-SaProp $conn "remoteClusterName")
  }
  $scheduleByUuid = @{}
  foreach ($schedule in $scheduleItems) {
    $id = [string](Get-SaProp $schedule "uuid")
    if (-not $id) { continue }
    $scheduleByUuid[$id] = [string](Get-SaProp $schedule "name")
  }

  $vmHeaders = @(
    "VM UUID", "Mem Alloc (GB)", "Type", "CPUs", "State", "Node",
    "Node CPU Load (%)", "Name", "Description", "Tags",
    "Boot Order", "Machine Type", "Operating System", "HA Policy",
    "Drive Type", "Mounted As", "Drive Size (GB)", "Used Size (GB)", "SSD Tier",
    "Cache Mode", "Disk Snapshots",
    "Snaps", "ISO Mounted", "VM IP Address", "VLANS",
    "MAC Addresses", "Adapter Types", "Connection Status",
    "Snapshot Schedule Plan", "Replication Partner"
  )
  $nodeHeaders = @(
    "Node IP", "Backplane IP", "CPU (cores/threads)", "Memory (GB)",
    "Storage Capacity (TB)", "Storage Used (TB)", "CPU Usage (%)",
    "Memory Usage (%)", "Network Status", "Disposition", "ICOS Version"
  )
  $degree = [string]([char]0x00B0)
  $driveHeaders = @(
    "Node IP", "Slot", "Serial Number", "Type", "Capacity (GB)",
    "Used (GB)", "Usage (%)", "Temperature ($degree`C)", "Max Temperature ($degree`C)",
    "Temperature Threshold ($degree`C)", "Health Status", "Reallocated Sectors",
    "Error Count", "Disposition"
  )
  $isoHeaders = @("ISO Name", "Size (GB)", "Path", "Number of Mounts", "Ready for Insert")
  $warningHeaders = @("Severity", "Issue", "Recommendation")
  $complianceHeaders = @("Category", "Actual (%)", "Target (%)", "Status", "Detail")
  $capacityHeaders = @("Metric", "Value")
  $conditionHeaders = @("Severity", "Type", "Message", "UUID")

  $nodeRows = New-Object System.Collections.ArrayList
  $driveRows = New-Object System.Collections.ArrayList
  $storageCapacityGb = [double]0
  $storageUsedGb = [double]0
  $ssdDrives = 0
  $hddDrives = 0
  $totalDrives = 0
  $healthyDrives = 0
  $unhealthyDrives = 0
  $nodesOnline = 0
  $nodesOffline = 0
  $cpuSamples = New-Object System.Collections.ArrayList
  $memSamples = New-Object System.Collections.ArrayList

  foreach ($node in $nodeItems) {
    $lan = [string](Get-SaProp $node "lanIP")
    $backplane = [string](Get-SaProp $node "backplaneIP")
    $cores = Get-SaProp $node "numCores"
    $threads = Get-SaProp $node "numThreads"
    if ($null -eq $cores) { $cores = 0 }
    if ($null -eq $threads) { $threads = 0 }
    $cpuInfo = ("{0}/{1}" -f [string]$cores, [string]$threads)
    $memoryGb = ConvertTo-SaRoundString (Get-SaProp $node "memSize") 1000000000 2
    $capacityTb = ConvertTo-SaRoundString (Get-SaProp $node "capacity") 1000000000000 2
    $usedBytes = [decimal]0
    $drives = (ConvertTo-SaArray (Get-SaProp $node "drives"))
    foreach ($drive in $drives) {
      if ($null -eq $drive) { continue }
      if ([string](Get-SaProp $drive "currentDisposition") -eq "IN") {
        $used = Get-SaProp $drive "usedBytes"
        if ($used) { $usedBytes += [decimal]$used }
      }
    }
    $usedTb = ConvertTo-SaRoundString $usedBytes 1000000000000 2
    $cpuUsage = Get-SaProp $node "cpuUsage"
    if ($null -eq $cpuUsage) { $cpuUsage = 0 }
    $memUsage = Get-SaProp $node "memUsagePercentage"
    if ($null -eq $memUsage) { $memUsage = 0 }
    $networkCell = "Unknown"
    if (Test-SaHasProp $node "networkStatus") {
      $networkCell = [string](Get-SaProp $node "networkStatus")
      if (-not $networkCell) { $networkCell = "" }
    }
    $networkStat = "ONLINE"
    if (Test-SaHasProp $node "networkStatus" -and (Get-SaProp $node "networkStatus")) {
      $networkStat = [string](Get-SaProp $node "networkStatus")
    }
    if ($networkStat -eq "ONLINE") { $nodesOnline++ } else { $nodesOffline++ }
    $disposition = [string](Get-SaProp $node "currentDisposition")
    if (-not $disposition) { $disposition = "Unknown" }
    Add-SaRow $nodeRows @(
      $lan, $backplane, $cpuInfo, $memoryGb, $capacityTb, $usedTb,
      (Format-SaFixed2 $cpuUsage), (Format-SaFixed2 $memUsage),
      $networkCell, $disposition, $icos
    )
    [void]$cpuSamples.Add([double]$cpuUsage)
    [void]$memSamples.Add([double]$memUsage)

    foreach ($drive in $drives) {
      if ($null -eq $drive) { continue }
      $totalDrives++
      $driveType = [string](Get-SaProp $drive "type")
      if ($driveType -eq "SSD") { $ssdDrives++ } else { $hddDrives++ }
      $healthy = Get-SaBoolDefaultTrue $drive "isHealthy"
      if ($healthy) { $healthyDrives++ } else { $unhealthyDrives++ }
      if ([string](Get-SaProp $drive "currentDisposition") -eq "IN") {
        $capBytes = Get-SaProp $drive "capacityBytes"
        $useBytes = Get-SaProp $drive "usedBytes"
        if ($capBytes) { $storageCapacityGb += ([double]$capBytes / [double]1073741824) }
        if ($useBytes) { $storageUsedGb += ([double]$useBytes / [double]1073741824) }
      }
      $capBytesSheet = Get-SaProp $drive "capacityBytes"
      $useBytesSheet = Get-SaProp $drive "usedBytes"
      if ($null -eq $capBytesSheet) { $capBytesSheet = 0 }
      if ($null -eq $useBytesSheet) { $useBytesSheet = 0 }
      $usagePct = [double]0
      if ([double]$capBytesSheet -gt 0) { $usagePct = ([double]$useBytesSheet / [double]$capBytesSheet) * 100 }
      $temperature = Get-SaProp $drive "temperature"
      $maxTemperature = Get-SaProp $drive "maxTemperature"
      $threshold = Get-SaProp $drive "temperatureThreshold"
      $realloc = Get-SaProp $drive "reallocatedSectors"
      $errors = Get-SaProp $drive "errorCount"
      if ($null -eq $temperature) { $temperature = 0 }
      if ($null -eq $maxTemperature) { $maxTemperature = 0 }
      if ($null -eq $threshold) { $threshold = 0 }
      if ($null -eq $realloc) { $realloc = 0 }
      if ($null -eq $errors) { $errors = 0 }
      $health = "Healthy"
      if ((-not $healthy) -or ([double]$errors -gt 100)) { $health = "Failed" }
      elseif (([double]$temperature -gt 0) -and ([double]$threshold -gt 0) -and ([double]$temperature -gt ([double]$threshold * 0.9))) { $health = "Warning" }
      elseif ([double]$realloc -gt 0) { $health = "Warning" }
      $driveDisposition = [string](Get-SaProp $drive "currentDisposition")
      if (-not $driveDisposition) { $driveDisposition = "Unknown" }
      Add-SaRow $driveRows @(
        $lan,
        [string](Get-SaProp $drive "slot"),
        [string](Get-SaProp $drive "serialNumber"),
        $driveType,
        (ConvertTo-SaRoundString $capBytesSheet 1000000000 2),
        (ConvertTo-SaRoundString $useBytesSheet 1000000000 2),
        (Format-SaFixed2 $usagePct),
        [string]$temperature,
        [string]$maxTemperature,
        [string]$threshold,
        $health,
        [string]$realloc,
        [string]$errors,
        $driveDisposition
      )
    }
  }

  $flatWarnings = New-Object System.Collections.ArrayList
  $bySeverity = @{
    "CRITICAL" = (New-Object System.Collections.ArrayList)
    "WARNING" = (New-Object System.Collections.ArrayList)
    "INFO" = (New-Object System.Collections.ArrayList)
  }
  $vmRows = New-Object System.Collections.ArrayList
  $totalVms = 0
  $runningVms = 0
  $stoppedVms = 0
  $memoryGbSum = [double]0
  $vmsWithSnaps = 0
  $vmsWithoutSnaps = 0
  $runningWithSnaps = 0
  $runningCount = 0
  $productionCount = 0
  $productionWithHa = 0
  $productionWithRepl = 0
  $diskCount = 0
  $disksAdequate = 0
  $vmTypeCounts = @{
    "VM" = 0
    "VM REPLICA" = 0
    "TEMPLATE" = 0
    "PRODUCTION VM" = 0
    "DEV VM" = 0
    "TEST VM" = 0
  }

  foreach ($vm in $vmItems) {
    if ($null -eq $vm) { continue }
    $vmUuid = [string](Get-SaProp $vm "uuid")
    $vmName = [string](Get-SaProp $vm "name")
    if (-not $vmName) { $vmName = "Unknown" }
    $vmDescription = [string](Get-SaProp $vm "description")
    $vmMem = Get-SaProp $vm "mem"
    $vmCpu = Get-SaProp $vm "numVCPU"
    if ($null -eq $vmCpu) { $vmCpu = 0 }
    $vmState = [string](Get-SaProp $vm "state")
    if (-not $vmState) { $vmState = "UNKNOWN" }
    $vmTags = Get-SaTagText $vm
    $bootOrder = Get-SaBootOrder $vm
    $machineType = [string](Get-SaProp $vm "machineType")
    $operatingSystem = [string](Get-SaProp $vm "operatingSystem")
    $haPolicy = Get-SaHaPolicy $vm
    $vmType = Get-SaVmType $vm
    $nodeUuid = [string](Get-SaProp $vm "nodeUUID")
    $nodeLan = "--"
    if ($nodeUuid -and $nodeByUuid.ContainsKey($nodeUuid)) {
      $mapped = [string](Get-SaProp $nodeByUuid[$nodeUuid] "lanIP")
      if ($mapped) { $nodeLan = $mapped } else { $nodeLan = "--" }
    }
    $nodeCpuLoad = "N/A"
    if ($vmState -eq "RUNNING" -and $nodeUuid -and $nodeByUuid.ContainsKey($nodeUuid)) {
      $owner = $nodeByUuid[$nodeUuid]
      if (Test-SaHasProp $owner "cpuUsage") {
        $nodeCpuLoad = Format-SaFixed2 (Get-SaProp $owner "cpuUsage")
      }
    }
    $snapIds = (ConvertTo-SaArray (Get-SaProp $vm "snapUUIDs"))
    $numSnaps = $snapIds.Count
    $blockDevs = (ConvertTo-SaArray (Get-SaProp $vm "blockDevs"))
    $netDevs = (ConvertTo-SaArray (Get-SaProp $vm "netDevs"))

    $ips = New-Object System.Collections.ArrayList
    $vlans = New-Object System.Collections.ArrayList
    $macs = New-Object System.Collections.ArrayList
    $adapters = New-Object System.Collections.ArrayList
    $connections = New-Object System.Collections.ArrayList
    foreach ($net in $netDevs) {
      if ($null -eq $net) { continue }
      foreach ($ipv4 in (ConvertTo-SaArray (Get-SaProp $net "ipv4Addresses"))) {
        if ($ipv4) { [void]$ips.Add([string]$ipv4) }
      }
      foreach ($ipv6 in (ConvertTo-SaArray (Get-SaProp $net "ipv6Addresses"))) {
        if ($ipv6) {
          $clean = Clear-SaIpv6 ([string]$ipv6)
          if ($clean) { [void]$ips.Add($clean) }
        }
      }
      $vlan = Get-SaProp $net "vlan"
      if ($null -ne $vlan -and "$vlan" -ne "" -and "$vlan" -ne "0") { [void]$vlans.Add([string]$vlan) }
      $mac = [string](Get-SaProp $net "macAddress")
      if (-not $mac) { $mac = [string](Get-SaProp $net "mac") }
      if ($mac) { [void]$macs.Add($mac) }
      $adapter = [string](Get-SaProp $net "type")
      if ($adapter) { [void]$adapters.Add($adapter) }
      if (Test-SaHasProp $net "connected") {
        $connected = Get-SaProp $net "connected"
        if ($connected -eq $true -or [string]$connected -eq "True" -or [string]$connected -eq "true") {
          [void]$connections.Add("Connected")
        } else {
          [void]$connections.Add("Disconnected")
        }
      }
    }
    $isoNames = New-Object System.Collections.ArrayList
    foreach ($bd in $blockDevs) {
      if ($null -eq $bd) { continue }
      $bdType = [string](Get-SaProp $bd "type")
      if ($bdType -eq "IDE_CDROM" -or $bdType -eq "VIRTIO_CDROM") {
        $isoPath = [string](Get-SaProp $bd "path")
        if ($isoPath -and $isoPath.ToLowerInvariant().EndsWith(".iso")) {
          [void]$isoNames.Add((Get-SaBaseName $isoPath))
        }
      }
    }
    $scheduleId = [string](Get-SaProp $vm "snapshotScheduleUUID")
    $snapPlan = ""
    if ($scheduleId -and $scheduleByUuid.ContainsKey($scheduleId)) { $snapPlan = [string]$scheduleByUuid[$scheduleId] }
    $replId = [string](Get-SaProp $vm "remoteClusterConnectionUUID")
    $partner = ""
    if ($replId -and $replByUuid.ContainsKey($replId)) { $partner = [string]$replByUuid[$replId] }
    if (-not $partner -and (Get-SaProp $vm "replicationSourceVirDomainUUID")) {
      $partner = "Replicated (source unknown)"
    }

    $memText = ConvertTo-SaMemoryGb $vmMem
    $totalVms++
    $memoryGbSum += [double]$memText
    if ($vmState -eq "RUNNING") { $runningVms++; $runningCount++ } else { $stoppedVms++ }
    if ($numSnaps -gt 0) { $vmsWithSnaps++ } else { $vmsWithoutSnaps++ }
    if ($vmState -eq "RUNNING" -and $numSnaps -gt 0) { $runningWithSnaps++ }
    if ($vmTypeCounts.ContainsKey($vmType)) { $vmTypeCounts[$vmType] = [int]$vmTypeCounts[$vmType] + 1 }
    if ($vmType -eq "PRODUCTION VM") {
      $productionCount++
      if ($haPolicy) { $productionWithHa++ }
      if ($partner) { $productionWithRepl++ }
    }

    if ($numSnaps -eq 0 -and $vmState -eq "RUNNING") {
      $severity = "WARNING"
      if ($vmType -eq "PRODUCTION VM") { $severity = "CRITICAL" }
      Add-SaWarning $flatWarnings $bySeverity $severity "$vmName`: No snapshots configured (Running VM)"
    }
    if (-not $haPolicy -and $vmState -eq "RUNNING" -and $vmType -eq "PRODUCTION VM") {
      Add-SaWarning $flatWarnings $bySeverity "WARNING" "$vmName`: No HA policy configured (Production VM)"
    }
    if (-not $partner -and $vmType -eq "PRODUCTION VM" -and $vmState -eq "RUNNING") {
      Add-SaWarning $flatWarnings $bySeverity "INFO" "$vmName`: No replication configured (Production VM)"
    }
    if ($vmState -eq "RUNNING" -and $nodeCpuLoad -ne "N/A") {
      $cpuVal = [double]$nodeCpuLoad
      if ($cpuVal -gt 90) {
        Add-SaWarning $flatWarnings $bySeverity "CRITICAL" ("Node {0}: Critical CPU usage ({1}%)" -f $nodeLan, (Format-SaPct1 $cpuVal))
      } elseif ($cpuVal -gt 80) {
        Add-SaWarning $flatWarnings $bySeverity "WARNING" ("Node {0}: High CPU usage ({1}%)" -f $nodeLan, (Format-SaPct1 $cpuVal))
      }
    }

    $disks = New-Object System.Collections.ArrayList
    foreach ($bd in $blockDevs) {
      if ($null -eq $bd) { continue }
      $bdType = [string](Get-SaProp $bd "type")
      if ($bdType.Contains("DISK") -and -not $bdType.Contains("CDROM")) { [void]$disks.Add($bd) }
    }
    $shared = @(
      $vmUuid, $memText, $vmType, [string]$vmCpu, $vmState, $nodeLan, $nodeCpuLoad,
      $vmName, $vmDescription, $vmTags, $bootOrder, $machineType, $operatingSystem, $haPolicy
    )
    $tail = @(
      [string]$numSnaps, ($isoNames -join "/"), ($ips -join "/"), ($vlans -join "/"),
      ($macs -join "/"), ($adapters -join "/"), ($connections -join "/"),
      $snapPlan, $partner
    )
    if ($disks.Count -eq 0) {
      Add-SaRow $vmRows ($shared + @("", "", "0", "0", "", "", "") + $tail)
    } else {
      foreach ($bd in $disks) {
        $driveType = [string](Get-SaProp $bd "type")
        $slot = Get-SaProp $bd "slot"
        $mount = "no"
        if ($null -ne $slot -and "$slot" -ne "") {
          if (([string]$slot).ToLowerInvariant().Contains("cdrom")) { $mount = "no" } else { $mount = [string]$slot }
        }
        $sizeText = ConvertTo-SaRoundString (Get-SaProp $bd "capacity") 1000000000 2
        $usedText = ConvertTo-SaRoundString (Get-SaProp $bd "allocation") 1000000000 2
        $tier = ConvertTo-SaSsdTier (Get-SaProp $bd "tieringPriorityFactor")
        $cache = [string](Get-SaProp $bd "cacheMode")
        $diskSnaps = "Enabled"
        $disable = Get-SaProp $bd "disableSnapshotting"
        if ($disable -eq $true -or [string]$disable -eq "True" -or [string]$disable -eq "true") { $diskSnaps = "Disabled" }
        Add-SaRow $vmRows ($shared + @($driveType, $mount, $sizeText, $usedText, $tier, $cache, $diskSnaps) + $tail)
        $sizeGb = [double]$sizeText
        $usedGb = [double]$usedText
        if ($sizeGb -gt 0) {
          $diskCount++
          $pct = ($usedGb / $sizeGb) * 100
          if ($pct -le 85) { $disksAdequate++ }
          if ($pct -gt 95) {
            Add-SaWarning $flatWarnings $bySeverity "CRITICAL" ("{0}: Disk {1} is {2}% full" -f $vmName, [string]$slot, (Format-SaPercent0 $pct))
          } elseif ($pct -gt 85) {
            Add-SaWarning $flatWarnings $bySeverity "WARNING" ("{0}: Disk {1} is {2}% full" -f $vmName, [string]$slot, (Format-SaPercent0 $pct))
          }
        }
      }
    }
  }

  $isoRows = New-Object System.Collections.ArrayList
  foreach ($iso in $isoItems) {
    if ($null -eq $iso) { continue }
    $mounts = Get-SaProp $iso "mounts"
    $mountText = "0"
    if ($null -ne $mounts) {
      if ($mounts -is [string] -or $mounts -is [int] -or $mounts -is [long] -or $mounts -is [double] -or $mounts -is [decimal]) {
        $mountText = [string]$mounts
      } else {
        $mountText = [string]((ConvertTo-SaArray $mounts).Count)
      }
    }
    $ready = "No"
    if (Get-SaProp $iso "readyForInsert") { $ready = "Yes" }
    Add-SaRow $isoRows @(
      [string](Get-SaProp $iso "name"),
      (ConvertTo-SaRoundString (Get-SaProp $iso "size") 1000000000 2),
      [string](Get-SaProp $iso "path"),
      $mountText,
      $ready
    )
  }
  $isoSorted = @($isoRows | Sort-Object { [string]$_[0] })
  $isoRows = New-Object System.Collections.ArrayList
  foreach ($isoRow in $isoSorted) { [void]$isoRows.Add($isoRow) }

  $conditionRows = New-Object System.Collections.ArrayList
  foreach ($condition in $conditionItems) {
    if ($null -eq $condition) { continue }
    if (-not (Test-SaConditionSet $condition)) { continue }
    $message = [string](Get-SaProp $condition "formattedMessage")
    if (-not $message) { $message = [string](Get-SaProp $condition "message") }
    if (-not $message) { $message = [string](Get-SaProp $condition "name") }
    Add-SaRow $conditionRows @(
      [string](Get-SaProp $condition "severity"),
      [string](Get-SaProp $condition "alertType"),
      $message,
      [string](Get-SaProp $condition "uuid")
    )
  }

  $warningRows = New-Object System.Collections.ArrayList
  foreach ($severity in @("CRITICAL", "WARNING", "INFO")) {
    foreach ($message in @($bySeverity[$severity])) {
      Add-SaRow $warningRows @($severity, [string]$message, (Get-SaRecommendation ([string]$message) $severity))
    }
  }

  $nodesNormal = 0
  foreach ($sample in @($cpuSamples)) {
    if ([double]$sample -le 80) { $nodesNormal++ }
  }
  $complianceRows = New-Object System.Collections.ArrayList
  $scoreParts = New-Object System.Collections.ArrayList
  function Add-SaCompliance($rows, $scores, [string]$category, [int]$have, [int]$total, [double]$target, [string]$detail) {
    if ($total -le 0) {
      Add-SaRow $rows @($category, "n/a", (Format-SaPct1 $target), "N/A", $detail)
      return
    }
    $actual = ([double]$have / [double]$total) * 100
    $status = "FAIL"
    if ($actual -ge $target) { $status = "PASS" }
    Add-SaRow $rows @($category, (Format-SaPct1 $actual), (Format-SaPct1 $target), $status, $detail)
    [void]$scores.Add($actual)
  }
  Add-SaCompliance $complianceRows $scoreParts "VMs with Snapshots (Running)" $runningWithSnaps $runningCount 80 ("{0} of {1} running VMs have snapshots" -f $runningWithSnaps, $runningCount)
  Add-SaCompliance $complianceRows $scoreParts "Production VMs with HA Policy" $productionWithHa $productionCount 70 ("{0} of {1} production VMs have an HA policy" -f $productionWithHa, $productionCount)
  Add-SaCompliance $complianceRows $scoreParts "Production VMs with Replication" $productionWithRepl $productionCount 50 ("{0} of {1} production VMs have replication" -f $productionWithRepl, $productionCount)
  Add-SaCompliance $complianceRows $scoreParts "Disks with Adequate Space" $disksAdequate $diskCount 90 ("{0} of {1} disks are at or below 85% used" -f $disksAdequate, $diskCount)
  Add-SaCompliance $complianceRows $scoreParts "Nodes with Normal CPU" $nodesNormal $nodeItems.Count 80 ("{0} of {1} nodes are at or below 80% CPU" -f $nodesNormal, $nodeItems.Count)
  $score = [double]100
  if ($scoreParts.Count -gt 0) {
    $sum = [double]0
    foreach ($part in @($scoreParts)) { $sum += [double]$part }
    $score = $sum / [double]$scoreParts.Count
  }
  $scoreText = Format-SaPct1 $score

  $storagePct = [double]0
  if ($storageCapacityGb -gt 0) { $storagePct = ($storageUsedGb / $storageCapacityGb) * 100 }
  $freePct = 100 - $storagePct
  $capTbText = Format-SaNum1 ($storageCapacityGb / 1000)
  $usedTbText = Format-SaNum1 ($storageUsedGb / 1000)
  $freeTbText = Format-SaNum1 (($storageCapacityGb - $storageUsedGb) / 1000)
  $capacityRecommendation = "Storage capacity is within the normal range."
  if ($storagePct -gt 95) {
    $capacityRecommendation = "URGENT: Free up cluster disk space or expand storage immediately to prevent VM failures."
  } elseif ($storagePct -gt 85) {
    $capacityRecommendation = "Monitor cluster disk usage closely and plan for storage expansion."
  }
  $forecastNote = "Growth projections are not included. SuperAudit daemon mode stores history for forecasting; this audit is one read-only pass."
  $capacityRows = New-Object System.Collections.ArrayList
  Add-SaRow $capacityRows @("Storage allocated (TB)", $capTbText)
  Add-SaRow $capacityRows @("Storage used (TB)", $usedTbText)
  Add-SaRow $capacityRows @("Storage free (TB)", $freeTbText)
  Add-SaRow $capacityRows @("Storage used (%)", (Format-SaPct1 $storagePct))
  Add-SaRow $capacityRows @("Storage free (%)", (Format-SaPct1 $freePct))
  Add-SaRow $capacityRows @("Memory allocated (GB)", (Format-SaNum1 $memoryGbSum))
  Add-SaRow $capacityRows @("Nodes", [string]$nodeItems.Count)
  Add-SaRow $capacityRows @("Drives", ("{0} ({1} SSD, {2} HDD)" -f $totalDrives, $ssdDrives, $hddDrives))
  Add-SaRow $capacityRows @("Healthy drives", [string]$healthyDrives)
  Add-SaRow $capacityRows @("Unhealthy drives", [string]$unhealthyDrives)
  Add-SaRow $capacityRows @("Recommendation", $capacityRecommendation)
  Add-SaRow $capacityRows @("Forecast", $forecastNote)

  $runningPct = [double]0
  $stoppedPct = [double]0
  $snapPct = [double]0
  if ($totalVms -gt 0) {
    $runningPct = ([double]$runningVms / [double]$totalVms) * 100
    $stoppedPct = ([double]$stoppedVms / [double]$totalVms) * 100
    $snapPct = ([double]$vmsWithSnaps / [double]$totalVms) * 100
  }
  $elapsedText = Format-SaElapsed $ElapsedSeconds
  $skipSet = @{}
  foreach ($section in (ConvertTo-SaArray $SkippedSections)) {
    if ($section) { $skipSet[[string]$section] = $true }
  }
  if ($skipSet.ContainsKey("Cluster")) {
    $clusterName = "skipped"
    $company = "skipped"
    $icos = "skipped"
  }
  $summary = New-Object System.Text.StringBuilder
  [void]$summary.AppendLine("SUPERAUDIT SUMMARY")
  [void]$summary.AppendLine(("Generated: {0}" -f $CollectedAt))
  [void]$summary.AppendLine(("Tool: Scale HyperCore API Toolkit {0}" -f $ToolVersion))
  [void]$summary.AppendLine("Source: Scale Computing SuperAudit one-time audit (read-only GET)")
  [void]$summary.AppendLine("")
  [void]$summary.AppendLine(("Cluster: {0}" -f $clusterName))
  [void]$summary.AppendLine(("Company: {0}" -f $company))
  [void]$summary.AppendLine(("ICOS version: {0}" -f $icos))
  [void]$summary.AppendLine(("Collection time: {0}" -f $elapsedText))
  [void]$summary.AppendLine("")
  if ($skipSet.ContainsKey("VMs")) {
    [void]$summary.AppendLine("VMs processed: skipped")
  } else {
    [void]$summary.AppendLine(("VMs processed: {0}" -f $totalVms))
    [void]$summary.AppendLine(("  Running: {0} ({1}%)" -f $runningVms, (Format-SaPct1 $runningPct)))
    [void]$summary.AppendLine(("  Stopped: {0} ({1}%)" -f $stoppedVms, (Format-SaPct1 $stoppedPct)))
    [void]$summary.AppendLine(("Memory allocated: {0} GB" -f (Format-SaNum1 $memoryGbSum)))
  }
  [void]$summary.AppendLine("")
  [void]$summary.AppendLine(("Storage allocated: {0} TB" -f $capTbText))
  [void]$summary.AppendLine(("Storage used: {0} TB ({1}%)" -f $usedTbText, (Format-SaPct1 $storagePct)))
  [void]$summary.AppendLine("")
  [void]$summary.AppendLine(("VMs with snapshots: {0} ({1}%)" -f $vmsWithSnaps, (Format-SaPct1 $snapPct)))
  [void]$summary.AppendLine(("VMs without snapshots: {0}" -f $vmsWithoutSnaps))
  [void]$summary.AppendLine("")
  if ($skipSet.ContainsKey("Nodes")) {
    [void]$summary.AppendLine("Nodes: skipped")
  } else {
    [void]$summary.AppendLine(("Nodes: {0} ({1} online, {2} offline)" -f $nodeItems.Count, $nodesOnline, $nodesOffline))
  }
  if ($skipSet.ContainsKey("Drives")) {
    [void]$summary.AppendLine("Drives: skipped")
  } else {
    [void]$summary.AppendLine(("Drives: {0} ({1} SSD, {2} HDD)" -f $totalDrives, $ssdDrives, $hddDrives))
    [void]$summary.AppendLine(("Healthy drives: {0}" -f $healthyDrives))
    [void]$summary.AppendLine(("Unhealthy drives: {0}" -f $unhealthyDrives))
  }
  [void]$summary.AppendLine("")
  [void]$summary.AppendLine(("Compliance score: {0}" -f $scoreText))
  foreach ($comp in @($complianceRows)) {
    [void]$summary.AppendLine(("  {0}  {1}: {2}% (target {3}%)" -f $comp[3], $comp[0], $comp[1], $comp[2]))
  }
  [void]$summary.AppendLine("")
  [void]$summary.AppendLine(("Capacity: {0}" -f $capacityRecommendation))
  [void]$summary.AppendLine("")
  if ($flatWarnings.Count -eq 0) {
    [void]$summary.AppendLine("Warnings: none")
  } else {
    [void]$summary.AppendLine(("Warnings ({0}):" -f $flatWarnings.Count))
    foreach ($message in @($flatWarnings)) { [void]$summary.AppendLine(("  - {0}" -f $message)) }
  }
  if ($noteItems.Count -gt 0) {
    [void]$summary.AppendLine("")
    [void]$summary.AppendLine("Skipped or unavailable API calls:")
    foreach ($note in $noteItems) { [void]$summary.AppendLine(("  - {0}" -f [string]$note)) }
  }
  $summaryText = $summary.ToString().TrimEnd()

  $html = New-Object System.Text.StringBuilder
  [void]$html.AppendLine("<!DOCTYPE html>")
  [void]$html.AppendLine("<html lang=`"en`"><head><meta charset=`"utf-8`">")
  [void]$html.AppendLine("<meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">")
  [void]$html.AppendLine(("<title>SuperAudit {0}</title>" -f (ConvertTo-SaHtmlText $clusterName)))
  [void]$html.AppendLine("<style>")
  [void]$html.AppendLine("body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#f7f7f5;}")
  [void]$html.AppendLine("h1{color:#366092;margin-bottom:0;} h2{color:#366092;margin-top:28px;}")
  [void]$html.AppendLine(".meta{color:#444;margin-top:4px;} .sheet{overflow-x:auto;background:#fff;border:1px solid #ddd;}")
  [void]$html.AppendLine("table{border-collapse:collapse;width:100%;font-size:13px;}")
  [void]$html.AppendLine("th{background:#366092;color:#fff;text-align:left;padding:6px 8px;position:sticky;top:0;}")
  [void]$html.AppendLine("td{border-top:1px solid #e4e4e4;padding:5px 8px;vertical-align:top;}")
  [void]$html.AppendLine("tr:nth-child(even) td{background:#f4f7fb;} .bad{background:#ffcccc;} .warn{background:#ffffcc;} .info{background:#cce5ff;} .good{background:#c6efce;}")
  [void]$html.AppendLine(".note{font-size:13px;color:#333;max-width:900px;} nav a{margin-right:12px;}")
  [void]$html.AppendLine("</style></head><body>")
  [void]$html.AppendLine("<h1>SUPERAUDIT SUMMARY REPORT</h1>")
  [void]$html.AppendLine(("<p class=`"meta`">Generated: {0}<br>Tool: Scale HyperCore API Toolkit {1}<br>Cluster: {2}<br>Company: {3}<br>ICOS version: {4}<br>Collection time: {5}<br>Compliance score: {6}</p>" -f @(
    (ConvertTo-SaHtmlText $CollectedAt),
    (ConvertTo-SaHtmlText $ToolVersion),
    (ConvertTo-SaHtmlText $clusterName),
    (ConvertTo-SaHtmlText $company),
    (ConvertTo-SaHtmlText $icos),
    (ConvertTo-SaHtmlText $elapsedText),
    (ConvertTo-SaHtmlText $scoreText)
  )))
  [void]$html.AppendLine("<nav>")
  [void]$html.AppendLine("<a href=`"#summary`">Summary</a><a href=`"#vms`">VM Inventory</a><a href=`"#nodes`">Node Hardware</a>")
  [void]$html.AppendLine("<a href=`"#drives`">Drive Health</a><a href=`"#isos`">ISO Library</a><a href=`"#warnings`">Warnings</a>")
  [void]$html.AppendLine("<a href=`"#compliance`">Compliance</a><a href=`"#capacity`">Capacity</a><a href=`"#conditions`">Conditions</a>")
  [void]$html.AppendLine("</nav>")
  [void]$html.AppendLine("<h2 id=`"summary`">Summary Dashboard</h2>")
  [void]$html.AppendLine("<pre class=`"sheet`">")
  [void]$html.AppendLine((ConvertTo-SaHtmlText $summaryText))
  [void]$html.AppendLine("</pre>")
  [void]$html.AppendLine("<div id=`"vms`">")
  if ($skipSet.ContainsKey("VMs")) { [void]$html.AppendLine("<p class=`"note`">This section was skipped.</p>") }
  [void]$html.Append((Format-SaHtmlTable "VM Inventory" $vmHeaders $vmRows))
  [void]$html.AppendLine("</div><div id=`"nodes`">")
  if ($skipSet.ContainsKey("Nodes")) { [void]$html.AppendLine("<p class=`"note`">This section was skipped.</p>") }
  [void]$html.Append((Format-SaHtmlTable "Node Hardware" $nodeHeaders $nodeRows))
  [void]$html.AppendLine("</div><div id=`"drives`">")
  if ($skipSet.ContainsKey("Drives")) { [void]$html.AppendLine("<p class=`"note`">This section was skipped.</p>") }
  [void]$html.Append((Format-SaHtmlTable "Drive Health" $driveHeaders $driveRows))
  [void]$html.AppendLine("</div><div id=`"isos`">")
  if ($skipSet.ContainsKey("ISOs")) { [void]$html.AppendLine("<p class=`"note`">This section was skipped.</p>") }
  [void]$html.Append((Format-SaHtmlTable "ISO Library" $isoHeaders $isoRows))
  [void]$html.AppendLine("</div><div id=`"warnings`">")
  [void]$html.Append((Format-SaHtmlTable "Warnings and Recommendations" $warningHeaders $warningRows))
  [void]$html.AppendLine("</div><div id=`"compliance`">")
  [void]$html.Append((Format-SaHtmlTable "Compliance Report" $complianceHeaders $complianceRows))
  [void]$html.AppendLine("<p class=`"note`">Targets are the ones published in the SuperAudit README: snapshots 80% of running VMs, HA 70% of production VMs, replication 50% of production VMs, adequate disks 90%, normal CPU 80%. Adequate means VM disk usage at or below 85% (the example's warning threshold). Normal CPU means node cpuUsage at or below 80%. Categories with nothing to score are N/A and are left out of the average. The upstream workbook writer does not emit this sheet.</p>")
  [void]$html.AppendLine("</div><div id=`"capacity`">")
  [void]$html.Append((Format-SaHtmlTable "Capacity Planning" $capacityHeaders $capacityRows))
  [void]$html.AppendLine("<p class=`"note`">Storage totals follow the example: bytes on drives whose disposition is IN, divided by 1024^3, then shown as TB by dividing that figure by 1000. Node Hardware capacity uses each node's capacity field and decimal TB (1000^4). The upstream workbook writer does not emit this sheet.</p>")
  [void]$html.AppendLine("</div><div id=`"conditions`">")
  if ($skipSet.ContainsKey("Conditions")) { [void]$html.AppendLine("<p class=`"note`">This section was skipped.</p>") }
  [void]$html.Append((Format-SaHtmlTable "Active Conditions" $conditionHeaders $conditionRows))
  [void]$html.AppendLine("<p class=`"note`">Active conditions come from GET /rest/v1/Condition (value true). The example daemon stores them. The one-time workbook does not.</p>")
  [void]$html.AppendLine("</div>")
  [void]$html.AppendLine("<p class=`"note`">Read-only GET audit adapted from <a href=`"https://github.com/ScaleComputing/RestAPIExamples/tree/master/specific_task/superaudit`">Scale Computing SuperAudit</a> (Scale Computing Support Team). That repository has no license file. This report is a PowerShell reimplementation and does not include the Python source. Daemon mode, the SQLite or PostgreSQL history, and the Flask dashboard are not part of this app.</p>")
  [void]$html.AppendLine("</body></html>")

  [pscustomobject]@{
    ClusterName = $clusterName
    Company = $company
    IcosVersion = $icos
    CollectedAt = $CollectedAt
    ElapsedText = $elapsedText
    ToolVersion = $ToolVersion
    FileStem = (Get-SaFileStem $clusterName)
    VmHeaders = $vmHeaders
    VmRows = $vmRows
    NodeHeaders = $nodeHeaders
    NodeRows = $nodeRows
    DriveHeaders = $driveHeaders
    DriveRows = $driveRows
    IsoHeaders = $isoHeaders
    IsoRows = $isoRows
    WarningHeaders = $warningHeaders
    WarningRows = $warningRows
    FlatWarnings = $flatWarnings
    ComplianceHeaders = $complianceHeaders
    ComplianceRows = $complianceRows
    ComplianceScore = $scoreText
    CapacityHeaders = $capacityHeaders
    CapacityRows = $capacityRows
    CapacityRecommendation = $capacityRecommendation
    ConditionHeaders = $conditionHeaders
    ConditionRows = $conditionRows
    Notes = $noteItems
    SummaryText = $summaryText
    Html = $html.ToString()
    TotalVms = $totalVms
    RunningVms = $runningVms
    StoppedVms = $stoppedVms
  }
}

function Export-SaReport {
  param(
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)][string]$Folder,
    [string]$Stamp = ""
  )
  if (-not $Stamp) { $Stamp = Get-Date -Format "yyyyMMdd-HHmmss" }
  $stem = [string]$Report.FileStem
  if (-not $stem) { $stem = "cluster" }
  $dirName = "superaudit_{0}_{1}" -f $stem, $Stamp
  $dir = Join-Path $Folder $dirName
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  $htmlName = "superaudit_{0}.html" -f $stem
  $htmlPath = Join-Path $dir $htmlName
  [IO.File]::WriteAllText($htmlPath, [string]$Report.Html, $utf8Bom)
  $csvMap = @(
    @{ Name = ("superaudit_{0}.csv" -f $stem); Headers = $Report.VmHeaders; Rows = $Report.VmRows },
    @{ Name = ("superaudit_{0}_nodes.csv" -f $stem); Headers = $Report.NodeHeaders; Rows = $Report.NodeRows },
    @{ Name = ("superaudit_{0}_drives.csv" -f $stem); Headers = $Report.DriveHeaders; Rows = $Report.DriveRows },
    @{ Name = ("superaudit_{0}_isos.csv" -f $stem); Headers = $Report.IsoHeaders; Rows = $Report.IsoRows },
    @{ Name = ("superaudit_{0}_warnings.csv" -f $stem); Headers = $Report.WarningHeaders; Rows = $Report.WarningRows },
    @{ Name = ("superaudit_{0}_compliance.csv" -f $stem); Headers = $Report.ComplianceHeaders; Rows = $Report.ComplianceRows },
    @{ Name = ("superaudit_{0}_capacity.csv" -f $stem); Headers = $Report.CapacityHeaders; Rows = $Report.CapacityRows },
    @{ Name = ("superaudit_{0}_conditions.csv" -f $stem); Headers = $Report.ConditionHeaders; Rows = $Report.ConditionRows }
  )
  $csvPaths = New-Object System.Collections.ArrayList
  foreach ($item in $csvMap) {
    $path = Join-Path $dir ([string]$item.Name)
    $csv = Format-SaCsv $item.Headers $item.Rows
    [IO.File]::WriteAllText($path, $csv, $utf8Bom)
    [void]$csvPaths.Add($path)
  }
  [pscustomobject]@{
    Directory = $dir
    HtmlPath = $htmlPath
    CsvPaths = $csvPaths
  }
}

function Get-HcApiPath([string]$Path) {
  # Final path on the host. VMs pass /v1/VirDomain. SuperAudit passes /rest/v1/Cluster.
  # Both must request /rest/v1/... exactly once. /update/ is outside /rest.
  if ($null -eq $Path) { return "" }
  if ($Path -match '^https?://') { return $Path }
  if ($Path.StartsWith("/update/")) { return $Path }
  if ($Path.StartsWith("/rest/") -or $Path -eq "/rest") { return $Path }
  if (-not $Path.StartsWith("/")) { $Path = "/" + $Path }
  return "/rest" + $Path
}

function Get-SaRequestPaths {
  # Every path SuperAudit passes to Invoke-Hc. Keep this list complete.
  return [pscustomobject]@{
    Cluster = "/rest/v1/Cluster"
    Nodes = "/rest/v1/Node"
    Vms = "/rest/v1/VirDomain"
    Drives = "/rest/v1/Drive"
    Replication = "/rest/v1/RemoteClusterConnection"
    Schedules = "/rest/v1/VirDomainSnapshotSchedule"
    Isos = "/rest/v1/ISO"
    ConditionFilter = "/rest/v1/Condition/filter?includeSet=true"
    Conditions = "/rest/v1/Condition"
  }
}
