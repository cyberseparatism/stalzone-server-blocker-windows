#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("gui","sync","import","list","ping","apply","clear","status")]
    [string]$Command = "gui",
    [string]$ImportPath,
    [string[]]$BlockPool,
    [string[]]$BlockServer,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$AppName = "STALZONE — блокировщик серверов"
$AppVersion = "0.1.6"
$RuleGroup = "STALZONE Server Blocker"
$RulePrefix = "SZSB:"
$ApiBase = "https://backend.stalcraftx.ru/address_list"
$FallbackTunnelList = "https://raw.githubusercontent.com/clovexx/sz-server-blocker/master/tunnels.txt"

$ConfigDir = Join-Path $env:LOCALAPPDATA "StalzoneServerBlocker"
$CacheFile = Join-Path $ConfigDir "servers.json"
$ConfigFile = Join-Path $ConfigDir "config.json"

$script:servers = @()
$script:cfg = $null
$script:PingByIp = @{}
$script:txtLog = $null
$script:lblSource = $null
$script:lblRules = $null
$script:lblAdmin = $null
$script:lblAction = $null
$script:gridPools = $null
$script:gridServers = $null

function Ensure-ConfigDir {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
}

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw "Для изменения Windows Firewall требуются права администратора."
    }
}

function Get-DefaultConfig {
    [pscustomobject]@{
        blockedPools = @()
        blockedServers = @()
    }
}

function Load-Config {
    Ensure-ConfigDir
    if (-not (Test-Path $ConfigFile)) {
        $cfg = Get-DefaultConfig
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
        return $cfg
    }

    try {
        $old = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

        $pools = @()
        $servers = @()
        if ($null -ne $old.blockedPools) { $pools = @($old.blockedPools) }
        if ($null -ne $old.blockedServers) { $servers = @($old.blockedServers) }

        return [pscustomobject]@{
            blockedPools = $pools
            blockedServers = $servers
        }
    } catch {
        throw "Не удалось прочитать config.json: $($_.Exception.Message)"
    }
}

function Save-Config($cfg) {
    Ensure-ConfigDir
    [pscustomobject]@{
        blockedPools = @($cfg.blockedPools)
        blockedServers = @($cfg.blockedServers)
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigFile -Encoding UTF8
}

function Convert-EndpointToIp([string]$Address) {
    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }

    if ($Address.StartsWith("[")) {
        $end = $Address.IndexOf("]")
        if ($end -gt 1) {
            return $Address.Substring(1, $end - 1)
        }
    }

    $lastColon = $Address.LastIndexOf(":")
    if ($lastColon -gt 0) {
        $hostPart = $Address.Substring(0, $lastColon)
        $colonCount = ($hostPart.ToCharArray() | Where-Object { $_ -eq ':' }).Count
        if ($colonCount -eq 0) {
            return $hostPart
        }
    }

    return $Address
}

function Normalize-ServerList($raw) {
    $result = @()

    foreach ($pool in @($raw.pools)) {
        foreach ($tunnel in @($pool.tunnels)) {
            $ip = Convert-EndpointToIp ([string]$tunnel.address)
            if ([string]::IsNullOrWhiteSpace($ip)) { continue }

            $result += [pscustomobject]@{
                Pool = [string]$pool.name
                Name = [string]$tunnel.name
                Address = [string]$tunnel.address
                Ip = $ip
            }
        }
    }

    return $result
}

function Convert-FallbackTunnelList([string[]]$Lines) {
    $result = @()

    foreach ($lineRaw in $Lines) {
        $line = [string]$lineRaw
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^\s*(.+?)\s+-\s+([0-9a-fA-F\.:]+)\s+@(.+?)\s*$') {
            $result += [pscustomobject]@{
                Pool = $matches[3].Trim()
                Name = $matches[1].Trim()
                Address = $matches[2].Trim()
                Ip = $matches[2].Trim()
            }
        }
    }

    return $result
}

function Save-Cache([string]$Source, [object[]]$Servers, $Raw = $null) {
    Ensure-ConfigDir

    if ($Source -eq "official" -or $Source -eq "manual-json") {
        $cache = [pscustomobject]@{
            source = $Source
            fetchedAt = (Get-Date).ToString("o")
            raw = $Raw
        }
    } else {
        $cache = [pscustomobject]@{
            source = $Source
            fetchedAt = (Get-Date).ToString("o")
            fallbackUrl = $FallbackTunnelList
            servers = @($Servers)
        }
    }

    $cache | ConvertTo-Json -Depth 20 | Set-Content -Path $CacheFile -Encoding UTF8
}

function Sync-ServersFromFallback {
    Write-Host "Использую резервный список серверов с GitHub..." -ForegroundColor Yellow

    try {
        $resp = Invoke-WebRequest -Uri $FallbackTunnelList -UseBasicParsing -TimeoutSec 20 -Headers @{
            "User-Agent" = "stalzone-server-blocker-windows/$AppVersion"
            "Accept" = "text/plain"
        }

        $servers = @(Convert-FallbackTunnelList ($resp.Content -split "`r?`n"))
    } catch {
        throw "Не удалось загрузить резервный список с GitHub: $($_.Exception.Message)"
    }

    if ($servers.Count -eq 0) {
        throw "Резервный список загрузился, но в нём не найдено серверов."
    }

    Save-Cache -Source "github-fallback" -Servers $servers
    Write-Host ("Загружено серверов: {0}" -f $servers.Count) -ForegroundColor Green
    return $servers
}

function Sync-Servers {
    Write-Host "Получаю список серверов из официального endpoint..." -ForegroundColor Cyan

    try {
        $raw = Invoke-RestMethod -Uri $ApiBase -Method Get -TimeoutSec 20 -Headers @{
            "User-Agent" = "stalzone-server-blocker-windows/$AppVersion"
            "Accept" = "application/json"
        }

        if ($null -eq $raw.pools) {
            throw "Официальный API вернул неожиданный формат."
        }

        $servers = @(Normalize-ServerList $raw)
        Save-Cache -Source "official" -Servers $servers -Raw $raw

        Write-Host ("Синхронизировано: {0} серверов." -f $servers.Count) -ForegroundColor Green
        return $servers
    } catch {
        $msg = $_.Exception.Message
        Write-Warning "Официальный endpoint недоступен: $msg"
        Write-Warning "Проверка TLS не отключается. Переключаюсь на резервный список GitHub."
        return Sync-ServersFromFallback
    }
}

function Import-ServerJson([string]$Path) {
    Ensure-ConfigDir

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Укажи путь к address_list.json через -ImportPath."
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop

    try {
        $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Не удалось прочитать JSON: $($_.Exception.Message)"
    }

    if ($null -eq $raw.pools) {
        throw "Файл не похож на address_list.json: отсутствует поле 'pools'."
    }

    $servers = @(Normalize-ServerList $raw)
    Save-Cache -Source "manual-json" -Servers $servers -Raw $raw

    Write-Host ("Импортировано серверов: {0}" -f $servers.Count) -ForegroundColor Green
    return $servers
}

function Get-CacheSource {
    if (-not (Test-Path $CacheFile)) { return "нет кэша" }

    try {
        $cache = Get-Content $CacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $cache.source) {
            switch ([string]$cache.source) {
                "official" { return "официальный API" }
                "github-fallback" { return "резервный GitHub" }
                "manual-json" { return "ручной JSON" }
                default { return [string]$cache.source }
            }
        }
        return "старый кэш"
    } catch {
        return "ошибка кэша"
    }
}

function Load-Servers {
    if (-not (Test-Path $CacheFile)) {
        return @(Sync-Servers)
    }

    try {
        $cache = Get-Content $CacheFile -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($cache.source -eq "github-fallback" -and $null -ne $cache.servers) {
            return @($cache.servers)
        }

        if (($cache.source -eq "official" -or $cache.source -eq "manual-json") -and $null -ne $cache.raw) {
            return @(Normalize-ServerList $cache.raw)
        }

        if ($null -ne $cache.pools) {
            return @(Normalize-ServerList $cache)
        }

        throw "Неизвестный формат кэша."
    } catch {
        Write-Warning "Кэш повреждён или несовместим. Загружаю список заново."
        return @(Sync-Servers)
    }
}

function Get-PingMs([string]$Ip, [int]$TimeoutMs = 450) {
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Ip, $TimeoutMs)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            return [int]$reply.RoundtripTime
        }
    } catch {}

    return $null
}

function Show-Servers([object[]]$Servers, [switch]$WithPing) {
    $rows = foreach ($s in $Servers) {
        $ms = $null
        if ($WithPing) {
            $ms = Get-PingMs $s.Ip
        }

        [pscustomobject]@{
            Pool = $s.Pool
            Server = $s.Name
            IP = $s.Ip
            Ping = if ($WithPing) {
                if ($null -eq $ms) { "N/A" } else { "$ms ms" }
            } else {
                ""
            }
        }
    }

    if ($Json) {
        $rows | ConvertTo-Json -Depth 4
    } else {
        $rows | Sort-Object Pool,Server | Format-Table -AutoSize
    }
}

function Get-DesiredBlockedServers([object[]]$Servers, $cfg) {
    $blockedPools = @($cfg.blockedPools)
    $blockedNames = @($cfg.blockedServers)

    return @($Servers | Where-Object {
        ($blockedPools -contains $_.Pool) -or ($blockedNames -contains $_.Name)
    })
}

function Get-OurFirewallRules {
    return @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Group -eq $RuleGroup -or $_.DisplayName -like "$RulePrefix*"
        })
}

function Clear-FirewallRules {
    Require-Administrator

    $rules = @(Get-OurFirewallRules)
    if ($rules.Count -eq 0) {
        Write-Host "Правил блокировки нет." -ForegroundColor Yellow
        return 0
    }

    $rules | Remove-NetFirewallRule
    Write-Host ("Удалено правил: {0}" -f $rules.Count) -ForegroundColor Green
    return $rules.Count
}

function Apply-FirewallRules([object[]]$Servers, $cfg) {
    Require-Administrator

    Get-OurFirewallRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    $targets = @(Get-DesiredBlockedServers $Servers $cfg)
    if ($targets.Count -eq 0) {
        Write-Host "Ничего не выбрано для блокировки." -ForegroundColor Yellow
        return 0
    }

    $targets = @($targets | Sort-Object Name,Ip -Unique)
    $created = 0

    foreach ($s in $targets) {
        $safeName = ($s.Name -replace '[^\p{L}\p{N}\-_\.]','_')
        $display = "$RulePrefix$($s.Pool):$safeName"

        try {
            New-NetFirewallRule `
                -DisplayName $display `
                -Group $RuleGroup `
                -Description "STALZONE Server Blocker. Pool=$($s.Pool); Server=$($s.Name); Address=$($s.Address)" `
                -Direction Outbound `
                -Action Block `
                -RemoteAddress $s.Ip `
                -Profile Any `
                -Enabled True | Out-Null
            $created++
        } catch {
            Write-Warning "Не удалось заблокировать $($s.Name) / $($s.Ip): $($_.Exception.Message)"
        }
    }

    Write-Host ("Создано правил: {0}" -f $created) -ForegroundColor Green
    return $created
}

function Show-Status {
    $cfg = Load-Config
    $rules = @(Get-OurFirewallRules)

    [pscustomobject]@{
        Version = $AppVersion
        Admin = Test-IsAdministrator
        CacheSource = Get-CacheSource
        BlockedPools = (@($cfg.blockedPools) -join ", ")
        BlockedServers = (@($cfg.blockedServers) -join ", ")
        FirewallRules = $rules.Count
        Config = $ConfigFile
    } | Format-List
}



function Get-Theme {
    return @{
        Bg        = [System.Drawing.Color]::FromArgb(9, 12, 17)
        Header    = [System.Drawing.Color]::FromArgb(12, 16, 23)
        Card      = [System.Drawing.Color]::FromArgb(16, 22, 31)
        Card2     = [System.Drawing.Color]::FromArgb(20, 27, 38)
        Border    = [System.Drawing.Color]::FromArgb(37, 48, 65)
        GridLine  = [System.Drawing.Color]::FromArgb(30, 40, 54)
        Text      = [System.Drawing.Color]::FromArgb(239, 243, 249)
        Muted     = [System.Drawing.Color]::FromArgb(139, 151, 170)
        Accent    = [System.Drawing.Color]::FromArgb(99, 112, 255)
        Accent2   = [System.Drawing.Color]::FromArgb(82, 190, 255)
        Green     = [System.Drawing.Color]::FromArgb(82, 210, 143)
        Yellow    = [System.Drawing.Color]::FromArgb(245, 194, 73)
        Red       = [System.Drawing.Color]::FromArgb(247, 103, 112)
        Hover     = [System.Drawing.Color]::FromArgb(31, 40, 55)
        Select    = [System.Drawing.Color]::FromArgb(45, 55, 91)
    }
}

function Initialize-NativeDarkMode {
    if ("SzsbNativeTheme" -as [type]) { return }

    $code = @"
using System;
using System.Runtime.InteropServices;

public static class SzsbNativeTheme
{
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(
        IntPtr hwnd,
        int dwAttribute,
        ref int pvAttribute,
        int cbAttribute
    );

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(
        IntPtr hWnd,
        string pszSubAppName,
        string pszSubIdList
    );

    public static void ApplyDark(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return;

        try
        {
            int enabled = 1;

            DwmSetWindowAttribute(handle, 20, ref enabled, sizeof(int));
            DwmSetWindowAttribute(handle, 19, ref enabled, sizeof(int));

            SetWindowTheme(handle, "DarkMode_Explorer", null);
        }
        catch
        {
        }
    }
}
"@

    Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
}

function Set-NativeDarkTheme([System.Windows.Forms.Control]$Control) {
    if ($null -eq $Control) { return }

    try {
        [SzsbNativeTheme]::ApplyDark($Control.Handle)
    } catch {}

    foreach ($child in $Control.Controls) {
        Set-NativeDarkTheme $child
    }
}


function Write-UiLog([string]$Text) {
    if ($null -eq $script:txtLog) { return }

    $stamp = Get-Date -Format "HH:mm:ss"
    $script:txtLog.AppendText("$stamp  $Text`r`n")
    $script:txtLog.SelectionStart = $script:txtLog.TextLength
    $script:txtLog.ScrollToCaret()
}

function Save-GuiSelection {
    if ($null -eq $script:cfg) {
        $script:cfg = Load-Config
    }

    if ($null -ne $script:gridPools) { [void]$script:gridPools.EndEdit() }
    if ($null -ne $script:gridServers) { [void]$script:gridServers.EndEdit() }

    $pools = @()
    foreach ($row in $script:gridPools.Rows) {
        if ($row.IsNewRow) { continue }
        $checked = $false
        if ($null -ne $row.Cells["Blocked"].Value) {
            $checked = [bool]$row.Cells["Blocked"].Value
        }
        if ($checked) {
            $pools += [string]$row.Cells["Pool"].Value
        }
    }

    $servers = @()
    foreach ($row in $script:gridServers.Rows) {
        if ($row.IsNewRow) { continue }
        $checked = $false
        if ($null -ne $row.Cells["Blocked"].Value) {
            $checked = [bool]$row.Cells["Blocked"].Value
        }
        if ($checked) {
            $servers += [string]$row.Cells["Server"].Value
        }
    }

    $script:cfg = [pscustomobject]@{
        blockedPools = @($pools | Sort-Object -Unique)
        blockedServers = @($servers | Sort-Object -Unique)
    }

    Save-Config $script:cfg
}

function Get-PingVisual([object]$Value) {
    $t = Get-Theme

    if ($null -eq $Value) {
        return [pscustomobject]@{
            Text = "—"
            Color = $t.Muted
            Quality = "НЕ ПРОВЕРЕН"
        }
    }

    if ($Value -is [string] -and $Value -eq "N/A") {
        return [pscustomobject]@{
            Text = "Н/Д"
            Color = $t.Muted
            Quality = "НЕТ ОТВЕТА"
        }
    }

    $ms = [int]$Value
    if ($ms -le 30) {
        return [pscustomobject]@{
            Text = "$ms мс"
            Color = $t.Green
            Quality = "ОТЛИЧНО"
        }
    }

    if ($ms -le 60) {
        return [pscustomobject]@{
            Text = "$ms мс"
            Color = $t.Yellow
            Quality = "НОРМАЛЬНО"
        }
    }

    return [pscustomobject]@{
        Text = "$ms мс"
        Color = $t.Red
        Quality = "ВЫСОКИЙ"
    }
}

function Get-PoolStats {
    $stats = @()

    foreach ($g in @($script:servers | Group-Object Pool | Sort-Object Name)) {
        $pings = @()

        foreach ($s in @($g.Group)) {
            if ($script:PingByIp.ContainsKey($s.Ip) -and $null -ne $script:PingByIp[$s.Ip]) {
                $pings += [int]$script:PingByIp[$s.Ip]
            }
        }

        $avg = $null
        if ($pings.Count -gt 0) {
            $avg = [int][math]::Round((($pings | Measure-Object -Average).Average))
        }

        $stats += [pscustomobject]@{
            Pool = [string]$g.Name
            Count = @($g.Group).Count
            Avg = $avg
        }
    }

    return @($stats)
}

function Populate-GuiTables {
    $t = Get-Theme

    $script:gridPools.Rows.Clear()
    $script:gridServers.Rows.Clear()

    $blockedPools = @($script:cfg.blockedPools)
    $blockedServers = @($script:cfg.blockedServers)

    foreach ($stat in @(Get-PoolStats)) {
        $visual = Get-PingVisual $stat.Avg

        $rowIndex = $script:gridPools.Rows.Add(
            ($blockedPools -contains $stat.Pool),
            $stat.Pool,
            $stat.Count,
            $visual.Text,
            $visual.Quality
        )

        $row = $script:gridPools.Rows[$rowIndex]
        $row.Cells["Ping"].Style.ForeColor = $visual.Color
        $row.Cells["Quality"].Style.ForeColor = $visual.Color
    }

    foreach ($s in @($script:servers | Sort-Object Pool,Name)) {
        $rawPing = $null

        if ($script:PingByIp.ContainsKey($s.Ip)) {
            if ($null -eq $script:PingByIp[$s.Ip]) {
                $rawPing = "N/A"
            } else {
                $rawPing = [int]$script:PingByIp[$s.Ip]
            }
        }

        $visual = Get-PingVisual $rawPing

        $rowIndex = $script:gridServers.Rows.Add(
            ($blockedServers -contains $s.Name),
            $s.Pool,
            $s.Name,
            $s.Ip,
            $visual.Text
        )

        $row = $script:gridServers.Rows[$rowIndex]
        $row.Cells["Ping"].Style.ForeColor = $visual.Color
        $row.Cells["Pool"].Style.ForeColor = $t.Accent2
    }

    $script:gridPools.ClearSelection()
    $script:gridServers.ClearSelection()
    $script:gridPools.CurrentCell = $null
    $script:gridServers.CurrentCell = $null

    Apply-SearchFilter
    Refresh-Dashboard
}

function Apply-SearchFilter {
    if ($null -eq $script:txtSearch) { return }

    $query = $script:txtSearch.Text.Trim().ToLowerInvariant()

    foreach ($row in $script:gridPools.Rows) {
        if ($row.IsNewRow) { continue }

        if ([string]::IsNullOrWhiteSpace($query)) {
            $row.Visible = $true
        } else {
            $hay = ("{0} {1} {2}" -f `
                $row.Cells["Pool"].Value, `
                $row.Cells["Ping"].Value, `
                $row.Cells["Quality"].Value).ToLowerInvariant()

            $row.Visible = $hay.Contains($query)
        }
    }

    foreach ($row in $script:gridServers.Rows) {
        if ($row.IsNewRow) { continue }

        if ([string]::IsNullOrWhiteSpace($query)) {
            $row.Visible = $true
        } else {
            $hay = ("{0} {1} {2} {3}" -f `
                $row.Cells["Pool"].Value, `
                $row.Cells["Server"].Value, `
                $row.Cells["IP"].Value, `
                $row.Cells["Ping"].Value).ToLowerInvariant()

            $row.Visible = $hay.Contains($query)
        }
    }
}

function Get-BestPoolText {
    $good = @(Get-PoolStats | Where-Object { $null -ne $_.Avg } | Sort-Object Avg)

    if ($good.Count -eq 0) {
        return "—"
    }

    return ("{0}  ·  {1} мс" -f $good[0].Pool, $good[0].Avg)
}

function Get-RecommendationText {
    $good = @(Get-PoolStats |
        Where-Object { $null -ne $_.Avg } |
        Sort-Object Avg |
        Select-Object -First 5)

    if ($good.Count -eq 0) {
        return "Проверь пинг — здесь появятся лучшие пулы."
    }

    $lines = @()
    $rank = 1

    foreach ($x in $good) {
        $lines += ("{0}.  {1,-12} {2,3} мс" -f $rank, $x.Pool, $x.Avg)
        $rank++
    }

    return ($lines -join "`r`n")
}

function Refresh-Dashboard {
    $t = Get-Theme

    $ruleCount = 0
    try {
        $ruleCount = @(Get-OurFirewallRules).Count
    } catch {}

    if ($null -ne $script:cardStatusValue) {
        if ($ruleCount -gt 0) {
            $script:cardStatusValue.Text = "АКТИВНА"
            $script:cardStatusValue.ForeColor = $t.Green
        } else {
            $script:cardStatusValue.Text = "НЕ АКТИВНА"
            $script:cardStatusValue.ForeColor = $t.Muted
        }
    }

    if ($null -ne $script:cardRulesValue) {
        $script:cardRulesValue.Text = [string]$ruleCount
        $script:cardRulesValue.ForeColor = if ($ruleCount -gt 0) { $t.Green } else { $t.Text }
    }

    if ($null -ne $script:cardBestValue) {
        $script:cardBestValue.Text = Get-BestPoolText
    }

    if ($null -ne $script:cardServersValue) {
        $script:cardServersValue.Text = [string]$script:servers.Count
    }

    if ($null -ne $script:lblFooter) {
        $rights = if (Test-IsAdministrator) { "АДМИНИСТРАТОР" } else { "ОБЫЧНЫЙ ЗАПУСК" }
        $script:lblFooter.Text = "v$AppVersion   •   $rights   •   Папка настроек: $ConfigDir"
    }

    if ($null -ne $script:txtRecommended) {
        $script:txtRecommended.Text = Get-RecommendationText
    }

    Update-SelectionSummary
}

function Update-SelectionSummary {
    if ($null -eq $script:lblSelection) { return }

    $p = 0
    foreach ($row in $script:gridPools.Rows) {
        if (-not $row.IsNewRow -and
            $null -ne $row.Cells["Blocked"].Value -and
            [bool]$row.Cells["Blocked"].Value) {
            $p++
        }
    }

    $s = 0
    foreach ($row in $script:gridServers.Rows) {
        if (-not $row.IsNewRow -and
            $null -ne $row.Cells["Blocked"].Value -and
            [bool]$row.Cells["Blocked"].Value) {
            $s++
        }
    }

    $script:lblSelection.Text = "ВЫБРАНО: $p ПУЛ. / $s СЕРВ."
}

function Start-ElevatedCommand([string]$ElevatedCommand) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Не удалось определить путь к скрипту."
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Command $ElevatedCommand"

    $p = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList $arguments `
        -Verb RunAs `
        -Wait `
        -PassThru

    return $p.ExitCode
}

function New-DarkButton {
    param(
        [string]$Text,
        [int]$Width = 150,
        [string]$Kind = "secondary"
    )

    $t = Get-Theme

    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Width = $Width
    $b.Height = 38
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $b.UseVisualStyleBackColor = $false

    switch ($Kind) {
        "primary" {
            $b.BackColor = $t.Accent
            $b.ForeColor = [System.Drawing.Color]::White
            $b.FlatAppearance.BorderColor = $t.Accent
            $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(116, 128, 255)
        }

        "danger" {
            $b.BackColor = [System.Drawing.Color]::FromArgb(44, 25, 31)
            $b.ForeColor = $t.Red
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(92, 45, 56)
            $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(60, 31, 39)
        }

        default {
            $b.BackColor = $t.Card2
            $b.ForeColor = $t.Text
            $b.FlatAppearance.BorderColor = $t.Border
            $b.FlatAppearance.MouseOverBackColor = $t.Hover
        }
    }

    return $b
}

function New-StatCard {
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X,
        [int]$Y,
        [int]$W,
        [string]$Title,
        [string]$Value
    )

    $t = Get-Theme

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($W, 82)
    $panel.BackColor = $t.Card
    $Parent.Controls.Add($panel)

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0, 0)
    $accent.Size = New-Object System.Drawing.Size(4, 82)
    $accent.BackColor = $t.Accent
    $panel.Controls.Add($accent)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title.ToUpperInvariant()
    $titleLabel.ForeColor = $t.Muted
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(16, 14)
    $panel.Controls.Add($titleLabel)

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.Text = $Value
    $valueLabel.ForeColor = $t.Text
    $valueLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
    $valueLabel.AutoEllipsis = $true
    $valueLabel.AutoSize = $false
    $valueLabel.Location = New-Object System.Drawing.Point(16, 38)
    $valueLabel.Size = New-Object System.Drawing.Size(($W - 28), 30)
    $panel.Controls.Add($valueLabel)

    return $valueLabel
}

function New-DashboardGrid {
    $t = Get-Theme

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
    $grid.RowTemplate.Height = 35
    $grid.BackgroundColor = $t.Card
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $grid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::None
    $grid.GridColor = $t.GridLine
    $grid.MultiSelect = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersHeight = 38
    $grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing

    $grid.ColumnHeadersDefaultCellStyle.BackColor = $t.Card2
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $t.Muted
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $t.Card2
    $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $t.Muted
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)

    $grid.DefaultCellStyle.BackColor = $t.Card
    $grid.DefaultCellStyle.ForeColor = $t.Text
    $grid.DefaultCellStyle.SelectionBackColor = $t.Select
    $grid.DefaultCellStyle.SelectionForeColor = $t.Text
    $grid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)

    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(18, 25, 35)
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill

    return $grid
}

function Add-TextColumn {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$Name,
        [string]$Header,
        [int]$Width,
        [bool]$Fill = $false
    )

    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $Name
    $c.HeaderText = $Header
    $c.ReadOnly = $true

    if ($Fill) {
        $c.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    } else {
        $c.Width = $Width
    }

    [void]$Grid.Columns.Add($c)
}

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $t = Get-Theme

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "STALZONE // SERVER BLOCKER — v$AppVersion"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(1210, 820)
    $form.MinimumSize = New-Object System.Drawing.Size(1120, 760)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.BackColor = $t.Bg
    $form.ForeColor = $t.Text

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 82
    $header.BackColor = $t.Header
    $form.Controls.Add($header)

    $mark = New-Object System.Windows.Forms.Panel
    $mark.Location = New-Object System.Drawing.Point(22, 20)
    $mark.Size = New-Object System.Drawing.Size(5, 41)
    $mark.BackColor = $t.Accent
    $header.Controls.Add($mark)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "STALZONE // SERVER BLOCKER"
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
    $title.ForeColor = $t.Text
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(39, 14)
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Мониторинг задержки и управление сетевой блокировкой через брандмауэр Windows"
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $subtitle.ForeColor = $t.Muted
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(41, 49)
    $header.Controls.Add($subtitle)

    $badge = New-Object System.Windows.Forms.Label
    $badge.Text = "ИНСТРУМЕНТ СООБЩЕСТВА"
    $badge.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $badge.ForeColor = $t.Accent2
    $badge.AutoSize = $true
    $badge.Anchor = "Top,Right"
    $badge.Location = New-Object System.Drawing.Point(1000, 12)
    $header.Controls.Add($badge)

    $contactDiscord = New-Object System.Windows.Forms.Label
    $contactDiscord.Text = "Discord: cyberseparatism"
    $contactDiscord.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $contactDiscord.ForeColor = $t.Muted
    $contactDiscord.AutoSize = $true
    $contactDiscord.Anchor = "Top,Right"
    $contactDiscord.Location = New-Object System.Drawing.Point(1000, 32)
    $header.Controls.Add($contactDiscord)

    $contactTelegram = New-Object System.Windows.Forms.Label
    $contactTelegram.Text = "Telegram: @cyberseparatism"
    $contactTelegram.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $contactTelegram.ForeColor = $t.Muted
    $contactTelegram.AutoSize = $true
    $contactTelegram.Anchor = "Top,Right"
    $contactTelegram.Location = New-Object System.Drawing.Point(1000, 51)
    $header.Controls.Add($contactTelegram)

    $script:cardStatusValue  = New-StatCard $form 22 98 260 "Состояние блокировки" "НЕ АКТИВНА"
    $script:cardRulesValue   = New-StatCard $form 292 98 245 "Правила брандмауэра" "0"
    $script:cardBestValue    = New-StatCard $form 547 98 305 "Лучший пул" "—"
    $script:cardServersValue = New-StatCard $form 862 98 250 "Серверов в списке" "0"

    $btnSync = New-DarkButton "ОБНОВИТЬ СПИСОК" 160 "secondary"
    $btnSync.Location = New-Object System.Drawing.Point(22, 195)
    $form.Controls.Add($btnSync)

    $btnPing = New-DarkButton "ПРОВЕРИТЬ ПИНГ" 165 "secondary"
    $btnPing.Location = New-Object System.Drawing.Point(192, 195)
    $form.Controls.Add($btnPing)

    $btnApply = New-DarkButton "ПРИМЕНИТЬ" 150 "primary"
    $btnApply.Location = New-Object System.Drawing.Point(367, 195)
    $form.Controls.Add($btnApply)

    $btnClear = New-DarkButton "СНЯТЬ БЛОКИРОВКУ" 190 "danger"
    $btnClear.Location = New-Object System.Drawing.Point(527, 195)
    $form.Controls.Add($btnClear)

    $script:lblSelection = New-Object System.Windows.Forms.Label
    $script:lblSelection.Text = "ВЫБРАНО: 0 ПУЛ. / 0 СЕРВ."
    $script:lblSelection.ForeColor = $t.Muted
    $script:lblSelection.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $script:lblSelection.AutoSize = $true
    $script:lblSelection.Location = New-Object System.Drawing.Point(736, 207)
    $form.Controls.Add($script:lblSelection)

    $mainCard = New-Object System.Windows.Forms.Panel
    $mainCard.Location = New-Object System.Drawing.Point(22, 250)
    $mainCard.Size = New-Object System.Drawing.Size(825, 465)
    $mainCard.Anchor = "Top,Bottom,Left,Right"
    $mainCard.BackColor = $t.Card
    $form.Controls.Add($mainCard)

    $mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $mainLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainLayout.Margin = New-Object System.Windows.Forms.Padding(0)
    $mainLayout.Padding = New-Object System.Windows.Forms.Padding(0)
    $mainLayout.ColumnCount = 1
    $mainLayout.RowCount = 2
    [void]$mainLayout.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle(
            [System.Windows.Forms.SizeType]::Percent,
            100
        ))
    )
    [void]$mainLayout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle(
            [System.Windows.Forms.SizeType]::Absolute,
            58
        ))
    )
    [void]$mainLayout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle(
            [System.Windows.Forms.SizeType]::Percent,
            100
        ))
    )
    $mainCard.Controls.Add($mainLayout)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $toolbar.BackColor = $t.Card
    $mainLayout.Controls.Add($toolbar, 0, 0)

    $btnPools = New-DarkButton "ПУЛЫ" 94 "primary"
    $btnPools.Location = New-Object System.Drawing.Point(12, 10)
    $toolbar.Controls.Add($btnPools)

    $btnServers = New-DarkButton "СЕРВЕРЫ" 110 "secondary"
    $btnServers.Location = New-Object System.Drawing.Point(116, 10)
    $toolbar.Controls.Add($btnServers)

    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.Text = "ПОИСК"
    $searchLabel.ForeColor = $t.Muted
    $searchLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $searchLabel.AutoSize = $true
    $searchLabel.Anchor = "Top,Right"
    $searchLabel.Location = New-Object System.Drawing.Point(548, 22)
    $toolbar.Controls.Add($searchLabel)

    $script:txtSearch = New-Object System.Windows.Forms.TextBox
    $script:txtSearch.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:txtSearch.BackColor = $t.Card2
    $script:txtSearch.ForeColor = $t.Text
    $script:txtSearch.Size = New-Object System.Drawing.Size(205, 25)
    $script:txtSearch.Anchor = "Top,Right"
    $script:txtSearch.Location = New-Object System.Drawing.Point(606, 16)
    $toolbar.Controls.Add($script:txtSearch)

    $gridHost = New-Object System.Windows.Forms.Panel
    $gridHost.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gridHost.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 10)
    $gridHost.BackColor = $t.Card
    $mainLayout.Controls.Add($gridHost, 0, 1)

    $script:gridPools = New-DashboardGrid
    $script:gridServers = New-DashboardGrid

    $poolCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $poolCheck.Name = "Blocked"
    $poolCheck.HeaderText = "БЛОК."
    $poolCheck.Width = 70
    $poolCheck.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    [void]$script:gridPools.Columns.Add($poolCheck)

    Add-TextColumn $script:gridPools "Pool" "ПУЛ" 190 $true
    Add-TextColumn $script:gridPools "Count" "СЕРВЕРОВ" 90
    Add-TextColumn $script:gridPools "Ping" "СР. ПИНГ" 110
    Add-TextColumn $script:gridPools "Quality" "ОЦЕНКА" 125

    $serverCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $serverCheck.Name = "Blocked"
    $serverCheck.HeaderText = "БЛОК."
    $serverCheck.Width = 70
    $serverCheck.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    [void]$script:gridServers.Columns.Add($serverCheck)

    Add-TextColumn $script:gridServers "Pool" "ПУЛ" 95
    Add-TextColumn $script:gridServers "Server" "СЕРВЕР" 270 $true
    Add-TextColumn $script:gridServers "IP" "IP-АДРЕС" 165
    Add-TextColumn $script:gridServers "Ping" "ПИНГ" 100

    $gridHost.Controls.Add($script:gridPools)
    $gridHost.Controls.Add($script:gridServers)
    $script:gridServers.Visible = $false

    $side = New-Object System.Windows.Forms.Panel
    $side.Location = New-Object System.Drawing.Point(865, 250)
    $side.Size = New-Object System.Drawing.Size(297, 465)
    $side.Anchor = "Top,Bottom,Right"
    $side.BackColor = $t.Card
    $form.Controls.Add($side)

    $sideTitle = New-Object System.Windows.Forms.Label
    $sideTitle.Text = "ЛУЧШИЕ МАРШРУТЫ"
    $sideTitle.ForeColor = $t.Text
    $sideTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
    $sideTitle.AutoSize = $true
    $sideTitle.Location = New-Object System.Drawing.Point(16, 15)
    $side.Controls.Add($sideTitle)

    $sideSub = New-Object System.Windows.Forms.Label
    $sideSub.Text = "Пулы с наименьшей задержкой"
    $sideSub.ForeColor = $t.Muted
    $sideSub.AutoSize = $true
    $sideSub.Location = New-Object System.Drawing.Point(16, 39)
    $side.Controls.Add($sideSub)

    $script:txtRecommended = New-Object System.Windows.Forms.TextBox
    $script:txtRecommended.Multiline = $true
    $script:txtRecommended.ReadOnly = $true
    $script:txtRecommended.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $script:txtRecommended.BackColor = $t.Card2
    $script:txtRecommended.ForeColor = $t.Text
    $script:txtRecommended.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:txtRecommended.Location = New-Object System.Drawing.Point(16, 66)
    $script:txtRecommended.Size = New-Object System.Drawing.Size(265, 118)
    $script:txtRecommended.Text = "Проверь пинг — здесь появятся лучшие пулы."
    $side.Controls.Add($script:txtRecommended)

    $quickTitle = New-Object System.Windows.Forms.Label
    $quickTitle.Text = "БЫСТРЫЙ ВЫБОР"
    $quickTitle.ForeColor = $t.Muted
    $quickTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $quickTitle.AutoSize = $true
    $quickTitle.Location = New-Object System.Drawing.Point(16, 201)
    $side.Controls.Add($quickTitle)

    $btnHighPing = New-DarkButton "Выбрать пулы с пингом выше 60 мс" 265 "secondary"
    $btnHighPing.Location = New-Object System.Drawing.Point(16, 225)
    $side.Controls.Add($btnHighPing)

    $btnReset = New-DarkButton "Очистить выбор" 265 "secondary"
    $btnReset.Location = New-Object System.Drawing.Point(16, 270)
    $side.Controls.Add($btnReset)

    $activityTitle = New-Object System.Windows.Forms.Label
    $activityTitle.Text = "ЖУРНАЛ"
    $activityTitle.ForeColor = $t.Muted
    $activityTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $activityTitle.AutoSize = $true
    $activityTitle.Location = New-Object System.Drawing.Point(16, 326)
    $side.Controls.Add($activityTitle)

    $script:txtLog = New-Object System.Windows.Forms.TextBox
    $script:txtLog.Multiline = $true
    $script:txtLog.ReadOnly = $true
    $script:txtLog.ScrollBars = "None"
    $script:txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $script:txtLog.BackColor = $t.Card2
    $script:txtLog.ForeColor = $t.Muted
    $script:txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
    $script:txtLog.Location = New-Object System.Drawing.Point(16, 349)
    $script:txtLog.Size = New-Object System.Drawing.Size(265, 98)
    $script:txtLog.Anchor = "Top,Bottom,Left,Right"
    $side.Controls.Add($script:txtLog)

    $script:lblFooter = New-Object System.Windows.Forms.Label
    $script:lblFooter.Text = "v$AppVersion"
    $script:lblFooter.ForeColor = $t.Muted
    $script:lblFooter.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:lblFooter.AutoSize = $true
    $script:lblFooter.Location = New-Object System.Drawing.Point(22, 738)
    $script:lblFooter.Anchor = "Bottom,Left"
    $form.Controls.Add($script:lblFooter)

    $disclaimer = New-Object System.Windows.Forms.Label
    $disclaimer.Text = "НЕОФИЦИАЛЬНЫЙ ПРОЕКТ СООБЩЕСТВА  •  НЕ СВЯЗАН С EXBO"
    $disclaimer.ForeColor = [System.Drawing.Color]::FromArgb(75, 86, 104)
    $disclaimer.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $disclaimer.AutoSize = $true
    $disclaimer.Location = New-Object System.Drawing.Point(800, 738)
    $disclaimer.Anchor = "Bottom,Right"
    $form.Controls.Add($disclaimer)

    $btnPools.Add_Click({
        $script:gridPools.Visible = $true
        $script:gridServers.Visible = $false

        $btnPools.BackColor = $t.Accent
        $btnPools.ForeColor = [System.Drawing.Color]::White
        $btnPools.FlatAppearance.BorderColor = $t.Accent

        $btnServers.BackColor = $t.Card2
        $btnServers.ForeColor = $t.Text
        $btnServers.FlatAppearance.BorderColor = $t.Border
    })

    $btnServers.Add_Click({
        $script:gridPools.Visible = $false
        $script:gridServers.Visible = $true

        $btnServers.BackColor = $t.Accent
        $btnServers.ForeColor = [System.Drawing.Color]::White
        $btnServers.FlatAppearance.BorderColor = $t.Accent

        $btnPools.BackColor = $t.Card2
        $btnPools.ForeColor = $t.Text
        $btnPools.FlatAppearance.BorderColor = $t.Border
    })

    $script:txtSearch.Add_TextChanged({
        Apply-SearchFilter
    })

    $script:gridPools.Add_CurrentCellDirtyStateChanged({
        if ($script:gridPools.IsCurrentCellDirty) {
            $script:gridPools.CommitEdit(
                [System.Windows.Forms.DataGridViewDataErrorContexts]::Commit
            )
            Update-SelectionSummary
        }
    })

    $script:gridServers.Add_CurrentCellDirtyStateChanged({
        if ($script:gridServers.IsCurrentCellDirty) {
            $script:gridServers.CommitEdit(
                [System.Windows.Forms.DataGridViewDataErrorContexts]::Commit
            )
            Update-SelectionSummary
        }
    })

    $btnSync.Add_Click({
        try {
            $btnSync.Enabled = $false
            Write-UiLog "Обновляю список серверов..."
            [System.Windows.Forms.Application]::DoEvents()

            $script:servers = @(Sync-Servers)
            Populate-GuiTables
            Refresh-Dashboard

            Write-UiLog "Список обновлён: $($script:servers.Count) серверов."
        } catch {
            Write-UiLog "Ошибка: $($_.Exception.Message)"

            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Ошибка обновления",
                "OK",
                "Error"
            ) | Out-Null
        } finally {
            $btnSync.Enabled = $true
        }
    })

    $btnPing.Add_Click({
        try {
            if ($script:servers.Count -eq 0) {
                throw "Список серверов пуст. Сначала обновите его."
            }

            $btnPing.Enabled = $false
            $btnPing.Text = "ПИНГ: 0 / $($script:servers.Count)"
            Write-UiLog "Проверяю задержку серверов..."

            $script:PingByIp = @{}
            $i = 0

            foreach ($s in $script:servers) {
                $i++
                $btnPing.Text = "ПИНГ: $i / $($script:servers.Count)"
                [System.Windows.Forms.Application]::DoEvents()

                $script:PingByIp[$s.Ip] = Get-PingMs $s.Ip
            }

            Populate-GuiTables
            Refresh-Dashboard
            Write-UiLog "Проверка пинга завершена."
        } catch {
            Write-UiLog "Ошибка пинга: $($_.Exception.Message)"

            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Ошибка пинга",
                "OK",
                "Error"
            ) | Out-Null
        } finally {
            $btnPing.Enabled = $true
            $btnPing.Text = "ПРОВЕРИТЬ ПИНГ"
        }
    })

    $btnHighPing.Add_Click({
        $changed = 0

        foreach ($row in $script:gridPools.Rows) {
            if ($row.IsNewRow) { continue }

            $pingText = [string]$row.Cells["Ping"].Value

            if ($pingText -match '^(\d+)\s+мс$') {
                $ms = [int]$matches[1]

                if ($ms -gt 60) {
                    $row.Cells["Blocked"].Value = $true
                    $changed++
                }
            }
        }

        Update-SelectionSummary
        Write-UiLog "Отмечены пулы с пингом выше 60 мс: $changed."
    })

    $btnReset.Add_Click({
        foreach ($row in $script:gridPools.Rows) {
            if (-not $row.IsNewRow) {
                $row.Cells["Blocked"].Value = $false
            }
        }

        foreach ($row in $script:gridServers.Rows) {
            if (-not $row.IsNewRow) {
                $row.Cells["Blocked"].Value = $false
            }
        }

        Save-GuiSelection
        Update-SelectionSummary
        Write-UiLog "Выбор очищен. Активные правила брандмауэра не изменялись."
    })

    $btnApply.Add_Click({
        try {
            Save-GuiSelection
            $targets = @(Get-DesiredBlockedServers $script:servers $script:cfg)

            if ($targets.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Ничего не выбрано.`r`n`r`nОтметьте нежелательные пулы или отдельные серверы.",
                    "Нечего блокировать",
                    "OK",
                    "Information"
                ) | Out-Null

                return
            }

            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Будет заблокировано адресов: $($targets.Count).`r`n`r`nWindows может показать запрос контроля учётных записей. Продолжить?",
                "Применить блокировку",
                "YesNo",
                "Question"
            )

            if ($answer -ne "Yes") { return }

            Write-UiLog "Применяю блокировку: $($targets.Count) адресов."

            if (Test-IsAdministrator) {
                [void](Apply-FirewallRules $script:servers $script:cfg)
            } else {
                $exit = Start-ElevatedCommand "apply"

                if ($exit -ne 0) {
                    throw "Команда с правами администратора завершилась с кодом $exit."
                }
            }

            Refresh-Dashboard
            Write-UiLog "Правила брандмауэра применены."

            [System.Windows.Forms.MessageBox]::Show(
                "Готово.`r`n`r`nЕсли STALZONE уже запущен, переподключитесь или перезапустите игру.",
                "Блокировка активна",
                "OK",
                "Information"
            ) | Out-Null
        } catch {
            Write-UiLog "Ошибка применения: $($_.Exception.Message)"

            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Ошибка",
                "OK",
                "Error"
            ) | Out-Null
        }
    })

    $btnClear.Add_Click({
        try {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Удалить все правила брандмауэра, созданные этой программой?`r`n`r`nОтмеченные галочки сохранятся.",
                "Снять блокировку",
                "YesNo",
                "Question"
            )

            if ($answer -ne "Yes") { return }

            Write-UiLog "Снимаю блокировку..."

            if (Test-IsAdministrator) {
                [void](Clear-FirewallRules)
            } else {
                $exit = Start-ElevatedCommand "clear"

                if ($exit -ne 0) {
                    throw "Команда с правами администратора завершилась с кодом $exit."
                }
            }

            Refresh-Dashboard
            Write-UiLog "Правила брандмауэра удалены."
        } catch {
            Write-UiLog "Ошибка удаления: $($_.Exception.Message)"

            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Ошибка",
                "OK",
                "Error"
            ) | Out-Null
        }
    })

    $form.Add_Shown({
        try {
            Write-UiLog "Запуск версии $AppVersion."

            $script:cfg = Load-Config
            $script:servers = @(Load-Servers)

            Populate-GuiTables
            Refresh-Dashboard

            Initialize-NativeDarkMode
            Set-NativeDarkTheme $form
            Set-NativeDarkTheme $script:gridPools
            Set-NativeDarkTheme $script:gridServers
            Set-NativeDarkTheme $script:txtLog

            Write-UiLog "Загружено серверов: $($script:servers.Count)."
        } catch {
            Write-UiLog "Ошибка запуска: $($_.Exception.Message)"

            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Ошибка запуска",
                "OK",
                "Error"
            ) | Out-Null
        }
    })

    $form.Add_HandleCreated({
        Initialize-NativeDarkMode
        Set-NativeDarkTheme $form
    })

    [void]$form.ShowDialog()
}

Ensure-ConfigDir

$cfg = Load-Config

if ($PSBoundParameters.ContainsKey("BlockPool")) {
    $cfg.blockedPools = @($BlockPool)
    Save-Config $cfg
}

if ($PSBoundParameters.ContainsKey("BlockServer")) {
    $cfg.blockedServers = @($BlockServer)
    Save-Config $cfg
}

switch ($Command) {
    "gui"    { Start-Gui }
    "sync"   { [void](Sync-Servers) }
    "import" { [void](Import-ServerJson $ImportPath) }
    "list"   { Show-Servers (Load-Servers) }
    "ping"   { Show-Servers (Load-Servers) -WithPing }
    "apply"  { [void](Apply-FirewallRules (Load-Servers) (Load-Config)) }
    "clear"  { [void](Clear-FirewallRules) }
    "status" { Show-Status }
}
