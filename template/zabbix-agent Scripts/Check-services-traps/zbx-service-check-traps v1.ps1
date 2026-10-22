<#
zbx-service-check.ps1 - Zabbix TRAP mode: check Windows services and send the
result to the Zabbix server as a trapper item via zabbix_sender.

Flow (all traffic is outbound from the monitored host):
  1) Zabbix agent (ACTIVE item "service.check.trap") starts this script on its interval;
  2) the script checks the services listed in $ServiceList (the list is set HERE, on the host);
  3) the script sends a JSON trap via zabbix_sender to trapper item "service.states"
     on the Zabbix server (port 10051):
       {"data":[{"{#SERVICE}":"<name>","state":"<state>"},...]}
  4) server-side LLD creates per-service items and triggers.

EDIT THE CONFIG BLOCK BELOW for every host where you deploy this script.

Manual test (agent not required):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\zbx-service-check.ps1
Expected output: OK: info from server: processed: 1; failed: 0; ...
#>

# ==================== CONFIG (edit per host) ====================
$ServiceList    = "ssh-agent;WinRM"   # <-- services to monitor, separated by ';'
$TargetHost     = "127.0.0.1"         # machine where services run (127.0.0.1 = this host)
$ZabbixServer   = "172.20.0.195"      # Zabbix server (trapper listener, port 10051)
$ZabbixSender   = "C:\Program Files\Zabbix Agent 2\zabbix_sender.exe"
$ZabbixHostname = $env:COMPUTERNAME   # technical host name in Zabbix (zabbix_sender -s)
$TrapperKey     = "service.states"    # trapper item key on the server
# ================================================================

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

function Get-ServiceState {
    param([string]$Name, [string]$Computer)
    $isLocal = ($Computer -eq "" -or $Computer -eq "127.0.0.1" -or
                $Computer -eq "localhost" -or $Computer -eq $env:COMPUTERNAME)
    $svc = $null
    try {
        if ($isLocal) { $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue }
        else          { $svc = Get-Service -Name $Name -ComputerName $Computer -ErrorAction SilentlyContinue }
    } catch {}
    if ($svc) { return [string]@($svc)[0].Status }
    # not found by ServiceName -> try display name
    try {
        if ($isLocal) { $svc = Get-Service -DisplayName $Name -ErrorAction SilentlyContinue }
        else          { $svc = Get-Service -DisplayName $Name -ComputerName $Computer -ErrorAction SilentlyContinue }
    } catch {}
    if ($svc) { return [string]@($svc)[0].Status }
    # distinguish "no such service" from "cannot query remote host"
    if ($isLocal) { return "NotFound" }
    $probe = $null
    try { $probe = Get-Service -ComputerName $Computer -ErrorAction SilentlyContinue } catch {}
    if ($probe) { return "NotFound" }
    return "Unreachable"
}

$rows = New-Object System.Collections.Generic.List[string]
$names = @()
if ($ServiceList -ne "") {
    $names = @($ServiceList -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique)
}

foreach ($n in $names) {
    $state    = Get-ServiceState -Name $n -Computer $TargetHost
    $escName  = ($n     -replace '\\', '\\\\') -replace '"', '\"'
    $escState = ($state -replace '\\', '\\\\') -replace '"', '\"'
    $rows.Add(('{"{#SERVICE}":"' + $escName + '","state":"' + $escState + '"}'))
}

$json = '{"data":[' + ($rows -join ',') + ']}'

if (-not (Test-Path -LiteralPath $ZabbixSender)) {
    Write-Output ("FAIL: zabbix_sender not found: " + $ZabbixSender)
    exit 0
}

# zabbix_sender -i file line: <host> <key> "<value with \" escaped>"
$line = $ZabbixHostname + ' ' + $TrapperKey + ' "' + ($json -replace '"', '\"') + '"'
$tmp  = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmp, $line + "`r`n")

$out = & $ZabbixSender -z $ZabbixServer -i $tmp 2>&1
Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
$tx = [string]($out | Out-String)

if ($LASTEXITCODE -eq 0 -and $tx -match "processed:\s*\d+" -and $tx -match "failed:\s*0" -and $tx -notmatch "failed:\s*[1-9]") {
    $okLine = ($tx -split "`r?`n" | Where-Object { $_ -match "processed" } | Select-Object -First 1)
    Write-Output ("OK: " + $okLine.Trim())
} else {
    Write-Output ("FAIL: " + $tx.Trim())
}
exit 0
