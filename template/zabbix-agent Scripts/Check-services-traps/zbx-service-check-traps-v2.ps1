<#
.SYNOPSIS
    Zabbix Active Check: Мониторинг состояния Windows-служб (данные идут ЧЕРЕЗ агента).
.DESCRIPTION
    Скрипт проверяет список служб и возвращает JSON-строку для LLD (Low-Level Discovery) в Zabbix.
    Zabbix Agent (тип элемента "Zabbix agent (active)", ключ service.check.trap) сам перехватывает
    этот вывод и отправляет на сервер. Никаких zabbix_sender/трапперов — сервер видит данные,
    пришедшие от агента узла.
.USAGE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\zbx-service-check-traps.ps1
    Ожидаемый вывод: {"data":[{"{#SERVICE}":"<служба>","state":"<состояние>"},...]}
#>

# ==================== НАСТРОЙКИ (править под каждый хост) ====================
$ServiceList = "RarusTAPIServer;WinRM;ModuleAsteriskSP"   # Службы для мониторинга, разделитель ';'
$TargetHost  = "127.0.0.1"         # Хост, где работают службы (127.0.0.1 = локально)
# ============================================================================

# Корректная кодировка UTF-8 без BOM для вывода в Zabbix
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

# Полное JSON-экранирование строки: кавычки, слэши и ВСЕ управляющие символы (\uXXXX).
# ConvertTo-Json для строки возвращает уже закавыченное значение — подставляем как есть.
function ConvertTo-JsonString {
    param([AllowEmptyString()][string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Get-ServiceState {
    param([string]$Name, [string]$Computer)
    $isLocal = ($Computer -eq "" -or $Computer -eq "127.0.0.1" -or $Computer -eq "localhost" -or $Computer -eq $env:COMPUTERNAME)
    $svc = $null

    # 1. Пробуем найти по системному имени службы (ServiceName)
    try {
        if ($isLocal) { $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue }
        else          { $svc = Get-Service -Name $Name -ComputerName $Computer -ErrorAction SilentlyContinue }
    } catch {}
    if ($svc) { return [string]@($svc)[0].Status }

    # 2. Если не нашли, пробуем найти по отображаемому имени (DisplayName)
    try {
        if ($isLocal) { $svc = Get-Service -DisplayName $Name -ErrorAction SilentlyContinue }
        else          { $svc = Get-Service -DisplayName $Name -ComputerName $Computer -ErrorAction SilentlyContinue }
    } catch {}
    if ($svc) { return [string]@($svc)[0].Status }

    # 3. Определяем причину отсутствия: служба не найдена или хост недоступен
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
    $state = Get-ServiceState -Name $n -Computer $TargetHost
    $rows.Add(('{"{#SERVICE}":' + (ConvertTo-JsonString $n) + ',"state":' + (ConvertTo-JsonString $state) + '}'))
}

# Формируем итоговый JSON и выводим его. Zabbix Agent заберет этот вывод.
$json = '{"data":[' + ($rows -join ',') + ']}'
Write-Output $json
exit 0
