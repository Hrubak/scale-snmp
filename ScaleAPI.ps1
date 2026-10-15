# Scale HyperCore API Toolkit 0.4 - Windows UI for SC//HyperCore REST (v1 + SNMP v2).
# Schannel curl (TLS 1.3, then default, then TLS 1.0-1.1) and .NET run first.
# HyperCore 9.7.11 is TLS 1.3 only (TLS_AES_256_GCM_SHA384). Windows 10 Schannel
# fails with SEC_E_ALGORITHM_MISMATCH before the handshake. Git curl is Schannel too.
# Fallback is openssl s_client (Git usr\bin\openssl.exe, SCALE_OPENSSL, or ScaleAPI-openssl.path).
# Credentials stay in memory and are never logged. The Authorization header is never logged.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppVersion = "0.4"
$script:AppTitle = "Scale HyperCore API"
$logFile = Join-Path $PSScriptRoot "ScaleAPI-log.txt"
$script:VmCache = @()
$script:NodeCache = @()
$script:Transport = $null
$script:CurlProfileLabel = $null
$script:CurlProfileArgs = @()
$script:HcDotNetProtoLabel = "TLS 1.0, TLS 1.1, TLS 1.2"
$script:HcDotNetTls13 = $false

# Self-signed HyperCore certs. The callback is for the .NET fallback only.
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

function Set-HcDotNetProtocols {
  # Prefer TLS 1.3 (enum value 12288) plus Tls12 | Tls11 | Tls. Fall back if 12288 is rejected.
  $base = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
  $script:HcDotNetTls13 = $false
  $chosen = $base
  try {
    $with13 = $base -bor ([Net.SecurityProtocolType]12288)
    [Net.ServicePointManager]::SecurityProtocol = $with13
    $current = [int][Net.ServicePointManager]::SecurityProtocol
    if (($current -band 12288) -eq 12288) {
      $script:HcDotNetTls13 = $true
      $chosen = $with13
    }
  } catch {
    $script:HcDotNetTls13 = $false
  }
  if (-not $script:HcDotNetTls13) {
    try { [Net.ServicePointManager]::SecurityProtocol = $base } catch {}
    $chosen = $base
    $script:HcDotNetProtoLabel = "TLS 1.2, TLS 1.1, TLS 1.0 (TLS 1.3 value 12288 was rejected by this runtime)"
  } else {
    $script:HcDotNetProtoLabel = "TLS 1.3 (12288), TLS 1.2, TLS 1.1, TLS 1.0"
  }
  return $chosen
}

Set-HcDotNetProtocols | Out-Null

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
$form.Text = "$($script:AppTitle) $($script:AppVersion)"
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
$testTlsBtn = New-Button "Test TLS" 670 10 100 28
$connPanel.Controls.AddRange(@(
  (New-Label "Cluster IP / host" 12 12 108), $ipBox,
  (New-Label "Login" 12 42 108), $userBox,
  (New-Label "Password" 280 42 90), $passBox,
  $connectBtn, $testTlsBtn, $connStatus
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

function Format-HcPublicError([string]$text) {
  if (-not $text) { return "" }
  $clean = $text -replace '(?i)Authorization:\s*Basic\s+\S+', 'Authorization: Basic [redacted]'
  $clean = $clean -replace '(?i)(password|communityName)"?\s*[:=]\s*"?[^",\s]+', '$1=[redacted]'
  $clean = ($clean -replace '[\r\n]+', ' ').Trim()
  if ($clean.Length -gt 400) { $clean = $clean.Substring(0, 400) + "..." }
  return $clean
}

function Get-HcExceptionText($err) {
  $ex = $null
  if ($err -and $err.Exception) { $ex = $err.Exception } elseif ($err) { $ex = $err }
  $parts = @()
  $guard = 0
  while ($ex -and $guard -lt 6) {
    if ($ex.Message) { $parts += [string]$ex.Message }
    $ex = $ex.InnerException
    $guard++
  }
  return ($parts -join " | ")
}

function Test-HcTlsFailure([int]$exitCode, [string]$text) {
  if ($exitCode -in 35, 51, 53, 54, 58, 59, 60, 66, 77, 80, 82, 83, 90, 91) { return $true }
  if ($text -match '(?i)schannel|SEC_E_|SSL|TLS|secure channel|InitializeSecurityContext|certificate') { return $true }
  if ($exitCode -eq 2 -and $text -match '(?i)option|unknown|tls|ssl') { return $true }
  return $false
}

function Split-HcCurlRaw([string]$raw) {
  $code = "000"
  $match = [regex]::Match($raw, '__HC_HTTP_(\d{3})__')
  if ($match.Success) { $code = $match.Groups[1].Value }
  $body = [regex]::Replace($raw, '__HC_HTTP_\d{3}__', '')
  [pscustomobject]@{ Code = $code; Body = $body.Trim() }
}

function Get-HcNegotiatedTls([string]$text) {
  if (-not $text) { return "" }
  if ($text -match '(?i)TLSv1\.3|TLS[\s/]*1\.3') { return "TLS 1.3" }
  if ($text -match '(?i)TLSv1\.2|TLS[\s/]*1\.2') { return "TLS 1.2" }
  if ($text -match '(?i)TLSv1\.1|TLS[\s/]*1\.1') { return "TLS 1.1" }
  if ($text -match '(?i)TLSv1\.0|TLS[\s/]*1\.0|(?<![\d\.])TLSv1(?![\d\.])') { return "TLS 1.0" }
  return ""
}

function ConvertTo-HcProtoLabel([string]$name) {
  switch ($name) {
    "Tls13" { return "TLS 1.3" }
    "Tls12" { return "TLS 1.2" }
    "Tls11" { return "TLS 1.1" }
    "Tls" { return "TLS 1.0" }
    "None" { return "none" }
    default { return $name }
  }
}

function Get-HcCurlProfiles {
  # TLS 1.3 first. HyperCore 9.7.11 can fail a TLS 1.2 pin with SEC_E_UNSUPPORTED_FUNCTION.
  # Default is next (works for 9.7.10). TLS 1.0-1.1 is last and unlikely on 9.7.11.
  @(
    @{ Label = "TLS 1.3"; Args = @("--tlsv1.3") },
    @{ Label = "default"; Args = @() },
    @{ Label = "TLS 1.0-1.1"; Args = @("--tlsv1.0", "--tls-max", "1.1") }
  )
}

function Get-HcUrl([string]$Path) {
  $ip = $ipBox.Text.Trim()
  if ($Path -match '^https?://') { return $Path }
  if ($Path.StartsWith("/update/")) { return "https://$ip$Path" }
  return "https://$ip/rest$Path"
}

function Invoke-HcCurlOnce {
  param(
    [string]$Method,
    [string]$Url,
    [string]$Body,
    [int]$TimeoutSec,
    [string[]]$TlsArgs,
    [switch]$Anonymous,
    [switch]$CaptureTrace
  )
  $cfg = $null
  $bf = $null
  $exitCode = 1
  $raw = ""
  try {
    $ca = @("-sS", "-k", "--ssl-no-revoke")
    if ($TlsArgs) { $ca += @($TlsArgs) }
    $ca += @(
      "--max-time", "$TimeoutSec",
      "-X", $Method,
      "-w", "`n__HC_HTTP_%{http_code}__"
    )
    if ($CaptureTrace) { $ca += "--verbose" }
    if (-not $Anonymous) {
      $cfg = [IO.Path]::GetTempFileName()
      $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userBox.Text.Trim() + ":" + $passBox.Text))
      Set-Content -Path $cfg -Value "header = `"Authorization: Basic $b64`"" -Encoding ASCII
      $ca += @("-K", $cfg)
    }
    if ($Body) {
      $bf = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($bf, $Body)
      $ca += @("-H", "Content-Type: application/json", "--data-binary", "@$bf")
    }
    $ca += $Url
    $raw = (& curl.exe @ca 2>&1) -join "`n"
    if ($null -ne $LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE }
  } catch {
    $raw = Get-HcExceptionText $_
    $exitCode = 1
  } finally {
    if ($cfg) { Remove-Item $cfg -Force -ErrorAction SilentlyContinue }
    if ($bf) { Remove-Item $bf -Force -ErrorAction SilentlyContinue }
  }
  $split = Split-HcCurlRaw $raw
  $ok = ($exitCode -eq 0 -and $split.Code -match '^\d{3}$' -and $split.Code -ne "000")
  [pscustomobject]@{ Ok = $ok; Code = $split.Code; Body = $split.Body; Exit = $exitCode }
}

function Invoke-HcDotNet {
  param(
    [string]$Method,
    [string]$Url,
    [string]$Body,
    [int]$TimeoutSec,
    [switch]$Anonymous
  )
  Set-HcDotNetProtocols | Out-Null
  $resp = $null
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.Accept = "application/json"
    $req.UserAgent = "ScaleHyperCoreAPIToolkit/$($script:AppVersion)"
    if (-not $Anonymous) {
      $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userBox.Text.Trim() + ":" + $passBox.Text))
      $req.Headers.Add("Authorization", "Basic $token")
    }
    if ($Body -and $Method -in @("POST", "PATCH", "PUT")) {
      $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
      $req.ContentType = "application/json"
      $req.ContentLength = $bytes.Length
      $stream = $req.GetRequestStream()
      try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
    }
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    try { $text = $sr.ReadToEnd() } finally { $sr.Close() }
    $code = [int]$resp.StatusCode
    return [pscustomobject]@{ Ok = $true; Code = "$code"; Body = $text; Exit = 0 }
  } catch [Net.WebException] {
    $ex = $_.Exception
    $respErr = $ex.Response
    if ($respErr) {
      try {
        $sr = New-Object IO.StreamReader($respErr.GetResponseStream())
        try { $text = $sr.ReadToEnd() } finally { $sr.Close() }
        $code = [int]$respErr.StatusCode
        return [pscustomobject]@{ Ok = $true; Code = "$code"; Body = $text; Exit = 0 }
      } catch {
        return [pscustomobject]@{ Ok = $false; Code = "000"; Body = (Get-HcExceptionText $_); Exit = 1 }
      } finally {
        $respErr.Close()
      }
    }
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = (Get-HcExceptionText $_); Exit = 1 }
  } catch {
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = (Get-HcExceptionText $_); Exit = 1 }
  } finally {
    if ($resp) { $resp.Close() }
  }
}

function Invoke-HcCurlLadder {
  param(
    [string]$Method,
    [string]$Url,
    [string]$Body,
    [int]$TimeoutSec,
    [switch]$OnlyRemembered,
    [string]$SkipLabel
  )
  $profiles = @(Get-HcCurlProfiles)
  if ($OnlyRemembered -and $script:CurlProfileLabel) {
    $profiles = @($profiles | Where-Object { $_.Label -eq $script:CurlProfileLabel })
  }
  if (-not $script:LoggedCurlExe) {
    $script:LoggedCurlExe = $true
    Say ("Using schannel curl: {0}" -f (Get-HcCurlExe))
  }
  $notes = @()
  $last = $null
  foreach ($tlsProfile in $profiles) {
    if ($SkipLabel -and $tlsProfile.Label -eq $SkipLabel) { continue }
    $tlsArgs = @()
    if ($tlsProfile.Args) { $tlsArgs = @($tlsProfile.Args) }
    $r = Invoke-HcCurlOnce -Method $Method -Url $Url -Body $Body -TimeoutSec $TimeoutSec -TlsArgs $tlsArgs
    $last = $r
    if ($r.Ok) {
      $changed = ($script:Transport -ne "curl" -or $script:CurlProfileLabel -ne $tlsProfile.Label)
      $script:Transport = "curl"
      $script:CurlProfileLabel = [string]$tlsProfile.Label
      $script:CurlProfileArgs = $tlsArgs
      if ($changed) { Say ("Using curl TLS profile: {0}" -f $tlsProfile.Label) }
      return [pscustomobject]@{ Ok = $true; Code = $r.Code; Body = $r.Body; TlsFailure = $false; Attempts = $notes }
    }
    $tls = Test-HcTlsFailure ([int]$r.Exit) ([string]$r.Body)
    $note = "curl $($tlsProfile.Label) exit $($r.Exit)"
    $notes += $note
    $public = Format-HcPublicError $r.Body
    if ($tls) {
      Say ("curl TLS/connect failed ({0}, exit {1}): {2}" -f $tlsProfile.Label, $r.Exit, $public)
    } else {
      Say ("curl failed ({0}, exit {1}): {2}" -f $tlsProfile.Label, $r.Exit, $public)
      return [pscustomobject]@{ Ok = $false; Code = "000"; Body = $public; TlsFailure = $false; Attempts = $notes }
    }
  }
  $tail = ""
  if ($last) { $tail = Format-HcPublicError $last.Body }
  [pscustomobject]@{ Ok = $false; Code = "000"; Body = $tail; TlsFailure = $true; Attempts = $notes }
}

function Get-HcCurlExe {
  $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
  return "curl.exe"
}

function Find-HcOpenSsl {
  # Git for Windows ships a real OpenSSL at usr\bin\openssl.exe. Its curl.exe is Schannel-only.
  $candidates = @()
  if ($env:SCALE_OPENSSL) { $candidates += $env:SCALE_OPENSSL.Trim().Trim('"') }
  if ($PSScriptRoot) {
    $pathFile = Join-Path $PSScriptRoot "ScaleAPI-openssl.path"
    if (Test-Path -LiteralPath $pathFile) {
      $line = @(Get-Content -LiteralPath $pathFile -TotalCount 1 -ErrorAction SilentlyContinue)
      if ($line.Count -gt 0 -and $line[0]) { $candidates += ([string]$line[0]).Trim().Trim('"') }
    }
  }
  $roots = @()
  if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
  if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
  foreach ($root in $roots) {
    $candidates += (Join-Path $root "Git\usr\bin\openssl.exe")
    $candidates += (Join-Path $root "Git\mingw64\bin\openssl.exe")
    $candidates += (Join-Path $root "OpenSSL-Win64\bin\openssl.exe")
  }
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Git\usr\bin\openssl.exe")
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) {
      $resolved = Resolve-Path -LiteralPath $c
      return [string]$resolved.Path
    }
  }
  $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return [string]$cmd.Source }
  return $null
}

function Find-HcByteSeq([byte[]]$data, [byte[]]$pattern, [int]$start) {
  if (-not $data -or -not $pattern -or $pattern.Length -eq 0) { return -1 }
  $last = $data.Length - $pattern.Length
  for ($i = $start; $i -le $last; $i++) {
    $ok = $true
    for ($j = 0; $j -lt $pattern.Length; $j++) {
      if ($data[$i + $j] -ne $pattern[$j]) { $ok = $false; break }
    }
    if ($ok) { return $i }
  }
  return -1
}

function ConvertFrom-HcChunkedBytes([byte[]]$data) {
  $ms = New-Object IO.MemoryStream
  $complete = $false
  if (-not $data) { return [pscustomobject]@{ Bytes = (New-Object byte[] 0); Complete = $false } }
  $i = 0
  $crlf = [byte[]](13, 10)
  while ($i -lt $data.Length) {
    $lineEnd = Find-HcByteSeq $data $crlf $i
    if ($lineEnd -lt 0) { break }
    $line = [Text.Encoding]::ASCII.GetString($data, $i, ($lineEnd - $i)).Trim()
    $semi = $line.IndexOf(";")
    if ($semi -ge 0) { $line = $line.Substring(0, $semi).Trim() }
    $size = 0
    $parsed = [int]::TryParse($line, [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture, [ref]$size)
    if (-not $parsed) { break }
    $i = $lineEnd + 2
    if ($size -le 0) { $complete = $true; break }
    if (($i + $size) -gt $data.Length) { break }
    $ms.Write($data, $i, $size)
    $i += $size
    if (($i + 1) -lt $data.Length -and $data[$i] -eq 13 -and $data[$i + 1] -eq 10) { $i += 2 }
  }
  return [pscustomobject]@{ Bytes = $ms.ToArray(); Complete = $complete }
}

function ConvertFrom-HcHttpBytes([byte[]]$data) {
  $empty = [pscustomobject]@{ Ok = $false; Code = "000"; Body = ""; Complete = $false }
  if (-not $data -or $data.Length -eq 0) { return $empty }
  $marker = [Text.Encoding]::ASCII.GetBytes("HTTP/1.")
  $start = Find-HcByteSeq $data $marker 0
  if ($start -lt 0) { return $empty }
  $sep = [byte[]](13, 10, 13, 10)
  $hdrEnd = Find-HcByteSeq $data $sep $start
  $sepLen = 4
  if ($hdrEnd -lt 0) {
    $sep = [byte[]](10, 10)
    $hdrEnd = Find-HcByteSeq $data $sep $start
    $sepLen = 2
  }
  if ($hdrEnd -lt 0) { return $empty }
  $headerText = [Text.Encoding]::ASCII.GetString($data, $start, ($hdrEnd - $start))
  $bodyStart = $hdrEnd + $sepLen
  $bodyLen = $data.Length - $bodyStart
  $bodyBytes = New-Object byte[] 0
  if ($bodyLen -gt 0) {
    $bodyBytes = New-Object byte[] $bodyLen
    [Array]::Copy($data, $bodyStart, $bodyBytes, 0, $bodyLen)
  }
  $lines = @($headerText -split "`r?`n")
  $code = "000"
  if ($lines.Count -gt 0 -and $lines[0] -match 'HTTP/1\.[01]\s+(\d{3})') { $code = $Matches[1] } else { return $empty }
  $chunked = $false
  $contentLength = -1
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    $colon = $line.IndexOf(":")
    if ($colon -lt 1) { continue }
    $name = $line.Substring(0, $colon).Trim().ToLower()
    $value = $line.Substring($colon + 1).Trim()
    if ($name -eq "transfer-encoding" -and $value -match '(?i)chunked') { $chunked = $true }
    if ($name -eq "content-length") {
      $n = 0
      if ([int]::TryParse($value, [ref]$n)) { $contentLength = $n }
    }
  }
  $complete = $false
  if ($chunked) {
    $decoded = ConvertFrom-HcChunkedBytes $bodyBytes
    $bodyBytes = $decoded.Bytes
    $complete = [bool]$decoded.Complete
  } elseif ($contentLength -ge 0) {
    if ($bodyBytes.Length -ge $contentLength) {
      if ($contentLength -eq 0) {
        $bodyBytes = New-Object byte[] 0
      } else {
        $exact = New-Object byte[] $contentLength
        [Array]::Copy($bodyBytes, 0, $exact, 0, $contentLength)
        $bodyBytes = $exact
      }
      $complete = $true
    }
  }
  $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes)
  return [pscustomobject]@{ Ok = $true; Code = $code; Body = $bodyText; Complete = $complete }
}

function Split-HcRequestUrl([string]$Url) {
  $uri = [Uri]$Url
  $port = [int]$uri.Port
  if ($port -le 0) { $port = 443 }
  $path = [string]$uri.PathAndQuery
  if (-not $path) { $path = "/" }
  $hostHeader = [string]$uri.Host
  if ($port -ne 443) { $hostHeader = "$($uri.Host):$port" }
  return [pscustomobject]@{ Host = [string]$uri.Host; Port = $port; Path = $path; HostHeader = $hostHeader }
}

function New-HcRawHttpBytes([string]$Method, [string]$HostHeader, [string]$PathQuery, [string]$Body, [string]$BasicToken) {
  # BasicToken is written only into the request bytes. Callers must not log this string.
  $header = New-Object Text.StringBuilder
  [void]$header.Append("$Method $PathQuery HTTP/1.1`r`n")
  [void]$header.Append("Host: $HostHeader`r`n")
  [void]$header.Append("User-Agent: ScaleHyperCoreAPIToolkit/$($script:AppVersion)`r`n")
  [void]$header.Append("Accept: application/json`r`n")
  [void]$header.Append("Connection: close`r`n")
  if ($BasicToken) { [void]$header.Append("Authorization: Basic $BasicToken`r`n") }
  $payload = $null
  if ($Body -and $Method -in @("POST", "PATCH", "PUT", "DELETE")) {
    $payload = [Text.Encoding]::UTF8.GetBytes($Body)
    [void]$header.Append("Content-Type: application/json`r`n")
    [void]$header.Append("Content-Length: $($payload.Length)`r`n")
  }
  [void]$header.Append("`r`n")
  $head = [Text.Encoding]::ASCII.GetBytes($header.ToString())
  if (-not $payload) { return $head }
  $all = New-Object byte[] ($head.Length + $payload.Length)
  [Buffer]::BlockCopy($head, 0, $all, 0, $head.Length)
  [Buffer]::BlockCopy($payload, 0, $all, $head.Length, $payload.Length)
  return $all
}

function Receive-HcProcessBytes([System.Diagnostics.Process]$Proc, [int]$TimeoutMs) {
  $outMs = New-Object IO.MemoryStream
  $errMs = New-Object IO.MemoryStream
  $outBuf = New-Object byte[] 8192
  $errBuf = New-Object byte[] 4096
  $outStream = $Proc.StandardOutput.BaseStream
  $errStream = $Proc.StandardError.BaseStream
  $outPending = $null
  $errPending = $null
  try { $outPending = $outStream.BeginRead($outBuf, 0, $outBuf.Length, $null, $null) } catch { $outPending = $null }
  try { $errPending = $errStream.BeginRead($errBuf, 0, $errBuf.Length, $null, $null) } catch { $errPending = $null }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false
  while ($true) {
    if ($outPending -and $outPending.IsCompleted) {
      try {
        $n = $outStream.EndRead($outPending)
        if ($n -gt 0) {
          $outMs.Write($outBuf, 0, $n)
          $parsedNow = ConvertFrom-HcHttpBytes $outMs.ToArray()
          if ($parsedNow.Complete -and -not $Proc.HasExited) {
            try { $Proc.Kill() } catch {}
          }
          $outPending = $outStream.BeginRead($outBuf, 0, $outBuf.Length, $null, $null)
        } else { $outPending = $null }
      } catch { $outPending = $null }
    }
    if ($errPending -and $errPending.IsCompleted) {
      try {
        $n = $errStream.EndRead($errPending)
        if ($n -gt 0) {
          $errMs.Write($errBuf, 0, $n)
          $errPending = $errStream.BeginRead($errBuf, 0, $errBuf.Length, $null, $null)
        } else { $errPending = $null }
      } catch { $errPending = $null }
    }
    if ($sw.ElapsedMilliseconds -ge $TimeoutMs -and -not $Proc.HasExited) {
      $timedOut = $true
      try { $Proc.Kill() } catch {}
    }
    if ($Proc.HasExited -and -not $outPending -and -not $errPending) { break }
    if ($sw.ElapsedMilliseconds -ge ($TimeoutMs + 3000)) { break }
    Start-Sleep -Milliseconds 20
  }
  return [pscustomobject]@{ Out = $outMs.ToArray(); Err = $errMs.ToArray(); TimedOut = [bool]$timedOut }
}

function Invoke-HcOpenSslProc([string]$Exe, [string]$Arguments, [byte[]]$StdinBytes, [int]$TimeoutSec) {
  $proc = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    if ($StdinBytes -and $StdinBytes.Length -gt 0) {
      $proc.StandardInput.BaseStream.Write($StdinBytes, 0, $StdinBytes.Length)
      $proc.StandardInput.BaseStream.Flush()
    }
    $proc.StandardInput.Close()
    return (Receive-HcProcessBytes -Proc $proc -TimeoutMs ($TimeoutSec * 1000))
  } finally {
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
    if ($proc) { try { $proc.Dispose() } catch {} }
  }
}

function Invoke-HcOpenSsl {
  param(
    [string]$Method,
    [string]$Url,
    [string]$Body,
    [int]$TimeoutSec,
    [string]$OpenSslPath,
    [switch]$Anonymous
  )
  try {
    if (-not $OpenSslPath) { $OpenSslPath = Find-HcOpenSsl }
    if (-not $OpenSslPath) {
      return [pscustomobject]@{ Ok = $false; Code = "000"; Body = "openssl.exe not found. Install Git for Windows or set SCALE_OPENSSL, or put the path in ScaleAPI-openssl.path."; Exit = 1 }
    }
    $parts = Split-HcRequestUrl $Url
    $token = ""
    if (-not $Anonymous) {
      $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userBox.Text.Trim() + ":" + $passBox.Text))
    }
    $raw = New-HcRawHttpBytes -Method $Method -HostHeader $parts.HostHeader -PathQuery $parts.Path -Body $Body -BasicToken $token
    $token = $null
    $opensslArgs = "s_client -connect $($parts.Host):$($parts.Port) -servername $($parts.Host) -quiet -ign_eof"
    $got = Invoke-HcOpenSslProc -Exe $OpenSslPath -Arguments $opensslArgs -StdinBytes $raw -TimeoutSec $TimeoutSec
    $raw = $null
    $parsed = ConvertFrom-HcHttpBytes $got.Out
    if ($parsed.Ok -and $parsed.Code -ne "000") {
      return [pscustomobject]@{ Ok = $true; Code = $parsed.Code; Body = $parsed.Body.Trim(); Exit = 0 }
    }
    $errText = ""
    if ($got.Err -and $got.Err.Length -gt 0) { $errText = [Text.Encoding]::UTF8.GetString($got.Err) }
    if (-not $errText) { $errText = "openssl s_client returned no HTTP response" }
    if ($got.TimedOut) { $errText = "openssl s_client timed out. $errText" }
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = (Format-HcPublicError $errText); Exit = 1 }
  } catch {
    return [pscustomobject]@{ Ok = $false; Code = "000"; Body = (Format-HcPublicError (Get-HcExceptionText $_)); Exit = 1 }
  }
}

function Get-HcOpenSslHandshake([string]$OpenSslPath, [string]$HostName, [int]$Port, [int]$TimeoutSec) {
  # No HTTP and no credentials. Reads the handshake banner only.
  try {
    $opensslArgs = "s_client -connect ${HostName}:${Port} -servername $HostName"
    $got = Invoke-HcOpenSslProc -Exe $OpenSslPath -Arguments $opensslArgs -StdinBytes (New-Object byte[] 0) -TimeoutSec $TimeoutSec
    $text = ""
    if ($got.Out) { $text += [Text.Encoding]::UTF8.GetString($got.Out) }
    if ($got.Err) { $text += [Text.Encoding]::UTF8.GetString($got.Err) }
    $proto = ""
    $cipher = ""
    if ($text -match 'TLSv1\.3') { $proto = "TLS 1.3" }
    elseif ($text -match 'TLSv1\.2') { $proto = "TLS 1.2" }
    elseif ($text -match 'TLSv1\.1') { $proto = "TLS 1.1" }
    elseif ($text -match 'TLSv1\.0') { $proto = "TLS 1.0" }
    if ($text -match 'Cipher is ([A-Za-z0-9_]+)') { $cipher = $Matches[1] }
    if ($proto -and $cipher) { return "$proto $cipher" }
    if ($proto) { return $proto }
    return (Format-HcPublicError $text)
  } catch {
    return (Format-HcPublicError (Get-HcExceptionText $_))
  }
}

function Get-HcTlsDiagnosis([string[]]$attempts, [string]$dotnetError, [string]$opensslError) {
  $tried = "none"
  if ($attempts -and $attempts.Count -gt 0) { $tried = ($attempts -join "; ") }
  $text = @"
This node only accepts TLS 1.3, which Windows 10 can't do. Install Git for Windows or run from Windows 11.
Attempted schannel curl profiles: $tried.
Schannel curl: $(Get-HcCurlExe)
Attempted .NET protocols: $($script:HcDotNetProtoLabel).
.NET: $(Format-HcPublicError $dotnetError)
OpenSSL: $(Format-HcPublicError $opensslError)
Git for Windows curl.exe is Schannel-only (CURL_SSL_BACKEND=openssl does not switch it). The OpenSSL binary that works is openssl.exe, usually C:\Program Files\Git\usr\bin\openssl.exe. Set SCALE_OPENSSL or ScaleAPI-openssl.path to point at a different openssl.exe.
"@
  return $text.Trim()
}

function Invoke-HcSslProbe {
  param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][int]$ProtocolMask,
    [int]$TimeoutMs = 12000
  )
  $tcp = $null
  $ssl = $null
  try {
    $tcp = New-Object Net.Sockets.TcpClient
    $wait = $tcp.BeginConnect($HostName, 443, $null, $null)
    if (-not $wait.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      throw "TCP connect to ${HostName}:443 timed out"
    }
    $tcp.EndConnect($wait)
    $callback = [Net.Security.RemoteCertificateValidationCallback]{ param($sender, $cert, $chain, $errors) return $true }
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $callback)
    try {
      $protocols = [System.Security.Authentication.SslProtocols]$ProtocolMask
    } catch {
      return [pscustomobject]@{ Ok = $false; Protocol = ""; Error = "Protocol value $ProtocolMask is not in SslProtocols on this runtime. Windows 10 Schannel does not offer TLS 1.3 by default; Windows 11 and Server 2022 do." }
    }
    $ssl.AuthenticateAsClient($HostName, $null, $protocols, $false)
    $negotiated = "unknown"
    try { $negotiated = [string]$ssl.SslProtocol } catch {}
    return [pscustomobject]@{ Ok = $true; Protocol = $negotiated; Error = "" }
  } catch {
    return [pscustomobject]@{ Ok = $false; Protocol = ""; Error = (Get-HcExceptionText $_) }
  } finally {
    if ($ssl) { try { $ssl.Dispose() } catch {} }
    if ($tcp) { try { $tcp.Close() } catch {} }
  }
}

function Get-HcSslDiagnostic([string]$HostName) {
  # Diagnostics only. 12288 = TLS 1.3, tried before TLS 1.2/1.1/1.0 (3072/768/192).
  $tls13 = Invoke-HcSslProbe -HostName $HostName -ProtocolMask 12288
  if ($tls13.Ok) {
    return ("TLS 1.3 negotiated ({0}; diagnostics only, not used for API calls)" -f (ConvertTo-HcProtoLabel $tls13.Protocol))
  }
  $older = Invoke-HcSslProbe -HostName $HostName -ProtocolMask (192 -bor 768 -bor 3072)
  $why13 = Format-HcPublicError $tls13.Error
  if ($older.Ok) {
    return ("TLS 1.3 failed ({0}). Negotiated {1} without TLS 1.3. Windows 10 Schannel does not offer TLS 1.3 by default; Windows 11 and Server 2022 do. Diagnostics only, not used for API calls." -f $why13, (ConvertTo-HcProtoLabel $older.Protocol))
  }
  return ("TLS 1.3 failed ({0}). TLS 1.0-1.2 also failed ({1}). Windows 10 Schannel does not offer TLS 1.3 by default; Windows 11 and Server 2022 do. The node may also require a cipher or curve Schannel lacks, such as ChaCha20-Poly1305 or an ECDSA-only suite." -f $why13, (Format-HcPublicError $older.Error))
}

function Invoke-Hc {
  param(
    [Parameter(Mandatory)][ValidateSet("GET","POST","PATCH","PUT","DELETE")][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [string]$Body = "",
    [int]$TimeoutSec = 60
  )
  $url = Get-HcUrl $Path

  if ($script:Transport -eq "openssl") {
    $r = Invoke-HcOpenSsl -Method $Method -Url $url -Body $Body -TimeoutSec $TimeoutSec -OpenSslPath $script:OpenSslPath
    if ($r.Ok) { return [pscustomobject]@{ Code = $r.Code; Body = $r.Body } }
    Say "OpenSSL transport failed; retrying schannel curl..."
    $script:Transport = $null
  }

  if ($script:Transport -eq "dotnet") {
    $r = Invoke-HcDotNet -Method $Method -Url $url -Body $Body -TimeoutSec $TimeoutSec
    if ($r.Ok) { return [pscustomobject]@{ Code = $r.Code; Body = $r.Body } }
    Say ".NET transport failed; retrying curl TLS ladder..."
    $script:Transport = $null
  }

  $onlyRemembered = [bool]($script:Transport -eq "curl" -and $script:CurlProfileLabel)
  $curl = Invoke-HcCurlLadder -Method $Method -Url $url -Body $Body -TimeoutSec $TimeoutSec -OnlyRemembered:$onlyRemembered
  if ($curl.Ok) { return [pscustomobject]@{ Code = $curl.Code; Body = $curl.Body } }
  if ($onlyRemembered -and $curl.TlsFailure) {
    $failedLabel = [string]$script:CurlProfileLabel
    $previousAttempts = @($curl.Attempts)
    $script:Transport = $null
    $script:CurlProfileLabel = $null
    $script:CurlProfileArgs = @()
    $curl = Invoke-HcCurlLadder -Method $Method -Url $url -Body $Body -TimeoutSec $TimeoutSec -SkipLabel $failedLabel
    $merged = @(@($previousAttempts) + @($curl.Attempts) | Where-Object { $_ })
    $curl = [pscustomobject]@{ Ok = $curl.Ok; Code = $curl.Code; Body = $curl.Body; TlsFailure = $curl.TlsFailure; Attempts = $merged }
    if ($curl.Ok) { return [pscustomobject]@{ Code = $curl.Code; Body = $curl.Body } }
  }
  if (-not $curl.TlsFailure) {
    return [pscustomobject]@{ Code = "000"; Body = $curl.Body }
  }

  Say ("Retrying with .NET HttpWebRequest ({0}, cert check skipped)..." -f $script:HcDotNetProtoLabel)
  $r2 = Invoke-HcDotNet -Method $Method -Url $url -Body $Body -TimeoutSec $TimeoutSec
  if ($r2.Ok) {
    $script:Transport = "dotnet"
    $script:CurlProfileLabel = $null
    Say "Connected via .NET fallback."
    return [pscustomobject]@{ Code = $r2.Code; Body = $r2.Body }
  }

  $opensslPath = Find-HcOpenSsl
  $opensslError = "openssl.exe not found. Install Git for Windows or set SCALE_OPENSSL, or put the path in ScaleAPI-openssl.path."
  if ($opensslPath) {
    Say ("Schannel and .NET failed. Retrying with OpenSSL s_client: {0}" -f $opensslPath)
    $r3 = Invoke-HcOpenSsl -Method $Method -Url $url -Body $Body -TimeoutSec $TimeoutSec -OpenSslPath $opensslPath
    if ($r3.Ok) {
      $script:Transport = "openssl"
      $script:OpenSslPath = $opensslPath
      $script:CurlProfileLabel = $null
      Say "Connected via OpenSSL s_client. This node speaks TLS 1.3, which Windows 10 Schannel cannot do."
      return [pscustomobject]@{ Code = $r3.Code; Body = $r3.Body }
    }
    $opensslError = $r3.Body
  } else {
    Say $opensslError
  }
  $diag = Get-HcTlsDiagnosis -attempts @($curl.Attempts) -dotnetError $r2.Body -opensslError $opensslError
  [pscustomobject]@{ Code = "000"; Body = $diag }
}

function Invoke-HcTlsTest {
  $ip = $ipBox.Text.Trim()
  if (-not $ip) { Show-Msg "Enter the cluster IP or host." "Warning"; return }
  Set-Busy $true
  try {
    Say "--- Test TLS $ip"
    Say ("No credentials are sent. Schannel curl: {0}" -f (Get-HcCurlExe))
    Say "Order: curl --tlsv1.3, then default, then TLS 1.0-1.1, then .NET, then OpenSSL s_client."
    Say "Windows 10 Schannel does not offer TLS 1.3 by default. Windows 11 and Server 2022 do."
    $winner = $null
    $gotTransport = $false
    $winnerNeg = ""
    foreach ($tlsProfile in @(Get-HcCurlProfiles)) {
      $tlsArgs = @()
      if ($tlsProfile.Args) { $tlsArgs = @($tlsProfile.Args) }
      $r = Invoke-HcCurlOnce -Method GET -Url "https://$ip/" -Body "" -TimeoutSec 20 -TlsArgs $tlsArgs -Anonymous -CaptureTrace
      if ($r.Ok) {
        $winnerNeg = Get-HcNegotiatedTls $r.Body
        $shown = if ($winnerNeg) { $winnerNeg } else { "protocol not reported by curl" }
        Say ("curl {0}: connected ({1}, HTTP {2})" -f $tlsProfile.Label, $shown, $r.Code)
        $winner = $tlsProfile
        $gotTransport = $true
        $script:Transport = "curl"
        $script:CurlProfileLabel = [string]$tlsProfile.Label
        $script:CurlProfileArgs = $tlsArgs
        break
      }
      Say ("curl {0}: failed (exit {1}) {2}" -f $tlsProfile.Label, $r.Exit, (Format-HcPublicError $r.Body))
      if ($tlsProfile.Label -eq "TLS 1.3") {
        Say "curl TLS 1.3 did not connect. On Windows 10 that is expected: Schannel has no TLS 1.3 unless the PC is Windows 11 or Server 2022."
      }
    }
    if ($winner) {
      $extra = if ($winnerNeg) { " Negotiated $winnerNeg." } else { "" }
      Say ("Test TLS: curl profile '{0}' succeeded.{1} Later API calls use it until Connect." -f $winner.Label, $extra)
    } else {
      Say ("Retrying with .NET HttpWebRequest ({0}, cert check skipped)..." -f $script:HcDotNetProtoLabel)
      $n = Invoke-HcDotNet -Method GET -Url "https://$ip/" -Body "" -TimeoutSec 20 -Anonymous
      if ($n.Ok) {
        $gotTransport = $true
        $script:Transport = "dotnet"
        $script:CurlProfileLabel = $null
        Say ("Test TLS: .NET HttpWebRequest succeeded (HTTP {0}) using {1}." -f $n.Code, $script:HcDotNetProtoLabel)
      } else {
        Say ("Test TLS: .NET HttpWebRequest failed: {0}" -f (Format-HcPublicError $n.Body))
      }
    }

    $opensslPath = Find-HcOpenSsl
    if ($opensslPath) {
      Say ("OpenSSL: {0}" -f $opensslPath)
      $banner = Get-HcOpenSslHandshake -OpenSslPath $opensslPath -HostName $ip -Port 443 -TimeoutSec 15
      Say ("OpenSSL handshake: {0}" -f $banner)
      if (-not $gotTransport) {
        $o = Invoke-HcOpenSsl -Method GET -Url "https://$ip/rest/v1/ping" -Body "" -TimeoutSec 20 -OpenSslPath $opensslPath -Anonymous
        if ($o.Ok) {
          $gotTransport = $true
          $script:Transport = "openssl"
          $script:OpenSslPath = $opensslPath
          $script:CurlProfileLabel = $null
          Say ("Test TLS: OpenSSL s_client succeeded (HTTP {0}). Later API calls use it until Connect." -f $o.Code)
        } else {
          Say ("OpenSSL s_client failed: {0}" -f (Format-HcPublicError $o.Body))
        }
      }
    } else {
      Say "OpenSSL: not found. Install Git for Windows or set SCALE_OPENSSL, or put the path in ScaleAPI-openssl.path."
    }
    if (-not $gotTransport) {
      Say "This node only accepts TLS 1.3, which Windows 10 can't do. Install Git for Windows or run from Windows 11."
    }

    Say "SslStream diagnostic (no credentials), TLS 1.3 first:"
    $only13 = Invoke-HcSslProbe -HostName $ip -ProtocolMask 12288
    if ($only13.Ok) {
      Say ("SslStream TLS 1.3: succeeded ({0})." -f (ConvertTo-HcProtoLabel $only13.Protocol))
    } else {
      Say ("SslStream TLS 1.3: failed: {0}" -f (Format-HcPublicError $only13.Error))
      if (-not $gotTransport) {
        Say "Windows 10 Schannel does not offer TLS 1.3 by default. Windows 11 and Server 2022 do."
        foreach ($one in @(
          @{ Name = "TLS 1.2"; Mask = 3072 },
          @{ Name = "TLS 1.1"; Mask = 768 },
          @{ Name = "TLS 1.0"; Mask = 192 }
        )) {
          $p = Invoke-HcSslProbe -HostName $ip -ProtocolMask $one.Mask
          if ($p.Ok) {
            Say ("SslStream {0}: succeeded ({1})" -f $one.Name, (ConvertTo-HcProtoLabel $p.Protocol))
          } else {
            Say ("SslStream {0}: failed: {1}" -f $one.Name, (Format-HcPublicError $p.Error))
          }
        }
        Say "This node only accepts TLS 1.3, which Windows 10 can't do. Install Git for Windows or run from Windows 11."
      }
    }
  } finally { Set-Busy $false }
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
  $testTlsBtn.Enabled = -not $busy
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
    $script:Transport = $null
    $script:CurlProfileLabel = $null
    $script:CurlProfileArgs = @()
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
$testTlsBtn.Add_Click({ Invoke-HcTlsTest })
$ipBox.Add_TextChanged({
  $script:Transport = $null
  $script:CurlProfileLabel = $null
  $script:CurlProfileArgs = @()
})
$form.AcceptButton = $connectBtn

$form.Add_Shown({
  Say "Scale HyperCore API Toolkit $($script:AppVersion) ready. Enter cluster credentials and click Connect."
  Say "If Connect fails with a TLS error, click Test TLS. Log file: $logFile"
})

$form.Add_FormClosed({ $passBox.Text = "" })

[void]$form.ShowDialog()
