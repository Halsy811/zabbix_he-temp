<#
service-check.ps1 - Zabbix agent UserParameter script (Windows services states)
Template: "Windows Services State by Agent Script" (Zabbix 7.0)

Flow: server (active agent item) sends key service.check[{$SERVICELIST},{$HOST}]
with host macros resolved -> agent runs this script ($1 = service list "A;B;C",
$2 = target host) -> script returns JSON -> LLD creates per-service items/triggers.

Agent config (zabbix_agentd.conf / zabbix_agent2.conf):
  Server=172.20.0.195
  ServerActive=172.20.0.195
  Hostname=<exact technical name of the host in Zabbix>
  Timeout=30
  UserParameter=service.check[*],powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent\scripts\service-check.ps1" "$1" "$2"

Manual test:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service-check.ps1 "BITS;WinDefend" 127.0.0.1
#>
param(
    [Parameter(Position = 0)][string]$ServiceList = "",
    [Parameter(Position = 1)][string]$TargetHost = "127.0.0.1"
)

# --- optional zabbix_sender mode (send the same JSON as a trap). Default: off ---
$SendTrap     = $false
$ZabbixSender = "C:\Program Files\Zabbix Agent\zabbix_sender.exe"
$ZabbixServer = "172.20.0.195"
$TrapperKey   = "service.states"
$TrapHostName = ""   # host name in Zabbix for zabbix_sender -s; empty = $TargetHost

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
Write-Output $json

if ($SendTrap -and (Test-Path -LiteralPath $ZabbixSender)) {
    $hn = if ($TrapHostName -ne "") { $TrapHostName } else { $TargetHost }
    & $ZabbixSender -z $ZabbixServer -s $hn -k $TrapperKey -o $json | Out-Null
}
