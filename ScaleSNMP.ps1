# Scale SNMP: enable SNMP on a Scale Computing HyperCore 9.7.1+ cluster through REST v2.
# Credentials are used only for this session and never written to disk except a temp header file deleted after each request.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$logFile = Join-Path $PSScriptRoot "ScaleSNMP-log.txt"

function New-Label($text, $y) { $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.Location = "12,$y"; $l.Size = "120,22"; $l.TextAlign = "MiddleLeft"; $l }
function New-Box($y, $pw = $false) { $t = New-Object Windows.Forms.TextBox; $t.Location = "135,$y"; $t.Size = "280,22"; if ($pw) { $t.UseSystemPasswordChar = $true }; $t }

$form = New-Object Windows.Forms.Form
$form.Text = "Scale SNMP"; $form.Size = "445,470"; $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$ipBox = New-Box 15; $userBox = New-Box 45; $passBox = New-Box 75 $true; $commBox = New-Box 105
$form.Controls.AddRange(@((New-Label "Cluster IP" 15), $ipBox, (New-Label "Login" 45), $userBox, (New-Label "Password" 75), $passBox, (New-Label "Community string" 105), $commBox))

$checkBtn = New-Object Windows.Forms.Button; $checkBtn.Text = "Check"; $checkBtn.Location = "135,140"; $checkBtn.Size = "130,30"
$enableBtn = New-Object Windows.Forms.Button; $enableBtn.Text = "Enable SNMP"; $enableBtn.Location = "285,140"; $enableBtn.Size = "130,30"
$out = New-Object Windows.Forms.TextBox; $out.Multiline = $true; $out.ReadOnly = $true; $out.ScrollBars = "Vertical"; $out.Location = "12,185"; $out.Size = "403,230"; $out.Font = New-Object Drawing.Font("Consolas", 9)
$form.Controls.AddRange(@($checkBtn, $enableBtn, $out))
$form.AcceptButton = $checkBtn

function Say($text) {
  $out.AppendText("$text`r`n")
  Add-Content -Path $logFile -Value "$(Get-Date -Format s)  $text"
  [Windows.Forms.Application]::DoEvents()
}

function Invoke-Hc([string]$Method, [string]$Path, [string]$Body = "") {
  $ip = $ipBox.Text.Trim()
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userBox.Text.Trim() + ":" + $passBox.Text))
  $cfg = [IO.Path]::GetTempFileName()
  $bf = $null
  try {
    Set-Content -Path $cfg -Value "header = `"Authorization: Basic $b64`"" -Encoding ASCII
    $ca = @("-sSk", "--max-time", "60", "-K", $cfg, "-X", $Method, "-w", "`n%{http_code}", "https://$ip/rest$Path")
    if ($Body) {
      $bf = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($bf, $Body)
      $ca += @("-H", "Content-Type: application/json", "--data-binary", "@$bf")
    }
    $raw = (& curl.exe @ca 2>&1) -join "`n"
  } finally {
    Remove-Item $cfg -Force -ErrorAction SilentlyContinue
    if ($bf) { Remove-Item $bf -Force -ErrorAction SilentlyContinue }
  }
  $lines = $raw -split "`n"
  $code = $lines[-1].Trim()
  [pscustomobject]@{ Code = $code; Body = ($lines[0..([Math]::Max(0, $lines.Count - 2))] -join "`n").Trim() }
}

function Test-Inputs([bool]$needCommunity) {
  if (-not $ipBox.Text.Trim() -or -not $userBox.Text.Trim() -or -not $passBox.Text) { [Windows.Forms.MessageBox]::Show("Enter the cluster IP, login, and password.", "Scale SNMP") | Out-Null; return $false }
  if ($needCommunity -and -not $commBox.Text.Trim()) { [Windows.Forms.MessageBox]::Show("Enter the community string.", "Scale SNMP") | Out-Null; return $false }
  return $true
}

function Get-Status {
  $c = Invoke-Hc GET "/v1/Cluster"
  if ($c.Code -eq "401") { Say "Login failed (401). Check the login and password."; return $null }
  if ($c.Code -ne "200") { Say "Could not reach the cluster ($($c.Code)): $($c.Body)"; return $null }
  $ver = if ($c.Body -match '"icosVersion"\s*:\s*"([^"]+)"') { $Matches[1] } else { "unknown" }
  $name = if ($c.Body -match '"clusterName"\s*:\s*"([^"]+)"') { $Matches[1] } else { "" }
  Say "Cluster $name  HyperCore $ver"
  $s = Invoke-Hc GET "/v2/SNMPConfig"
  if ($s.Code -eq "404") { Say "This cluster has no SNMP API. It needs HyperCore 9.7.1 or newer."; return $null }
  if ($s.Code -ne "200") { Say "SNMP status failed ($($s.Code)): $($s.Body)"; return $null }
  Say "SNMP status: $($s.Body)"
  return ($s.Body -notmatch '^\s*\[\s*\]\s*$' -and $s.Body -notmatch '(?i)not enabled|disabled')
}

$checkBtn.Add_Click({
  if (-not (Test-Inputs $false)) { return }
  $form.UseWaitCursor = $true; Say "--- Check $($ipBox.Text.Trim())"
  try { $null = Get-Status } finally { $form.UseWaitCursor = $false }
})

$enableBtn.Add_Click({
  if (-not (Test-Inputs $true)) { return }
  $form.UseWaitCursor = $true; Say "--- Enable on $($ipBox.Text.Trim())"
  try {
    $on = Get-Status
    if ($null -eq $on) { return }
    if ($on) {
      $a = [Windows.Forms.MessageBox]::Show("SNMP is already on for this cluster. Add this community string anyway?", "Scale SNMP", "YesNo", "Question")
      if ($a -ne "Yes") { Say "No change made."; return }
    }
    $body = @{ communityName = $commBox.Text.Trim() } | ConvertTo-Json -Compress
    $r = Invoke-Hc POST "/v2/SNMPConfig" $body
    if ($r.Code -ne "200") { Say "Enable failed ($($r.Code)): $($r.Body)"; return }
    Say "Enable sent."
    if ($r.Body -match '"taskTag"\s*:\s*"?([^",}\s]+)') {
      $tag = $Matches[1]
      for ($i = 0; $i -lt 60; $i++) {
        $t = Invoke-Hc GET "/v1/TaskTag/$tag"
        if ($t.Body -notmatch '"state"\s*:\s*"(RUNNING|QUEUED)"') {
          $st = if ($t.Body -match '"state"\s*:\s*"([^"]+)"') { $Matches[1] } else { $t.Body }
          Say "Task finished: $st"; break
        }
        Start-Sleep -Seconds 2
      }
    }
    $null = Get-Status
  } finally { $form.UseWaitCursor = $false }
})

$form.Add_FormClosed({ $passBox.Text = "" })
[void]$form.ShowDialog()
