# Auto-elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
# ── Params jeu (injectes par CS2-Launcher via dot-source ; valeurs par defaut = CS2) ──────────
if (-not (Get-Variable -Name GameExe   -EA SilentlyContinue)) { $GameExe   = "cs2" }
if (-not (Get-Variable -Name GameName  -EA SilentlyContinue)) { $GameName  = "CS2" }
if (-not (Get-Variable -Name GamePath  -EA SilentlyContinue)) { $GamePath  = "" }
if (-not (Get-Variable -Name LaunchUri -EA SilentlyContinue)) { $LaunchUri = "steam://rungameid/730" }
# ============================================================
#  CS2-HighPriority.ps1 v2
#  - Auto-detection interface reseau active (plus de "Wi-Fi" hardcode)
#  - Auto-detection chemin Steam via registre
#  - Detection dynamique des consommateurs reseau (TCP actif)
#  - Services geres en boucle
#  - Bilan detaille
# ============================================================

# ── Fonctions ──────────────────────────────────────────────────────────

function Get-ActiveNetAdapter {
    # Retourne l'adaptateur physique actif avec une passerelle (= connecte a internet)
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq "Up" -and
        $_.HardwareInterface -eq $true -and
        $_.Name -notmatch "Loopback|Bluetooth|Hyper-V|VMware|VirtualBox|Hamachi|TAP|Pseudo"
    }
    foreach ($a in $adapters) {
        $cfg = Get-NetIPConfiguration -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
        if ($cfg.IPv4DefaultGateway) { return $a }
    }
    return $adapters | Select-Object -First 1
}

function Get-SteamPath {
    $regPaths = @(
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam",
        "HKCU:\SOFTWARE\Valve\Steam"
    )
    foreach ($rp in $regPaths) {
        $val = (Get-ItemProperty $rp -ErrorAction SilentlyContinue).InstallPath
        if ($val -and (Test-Path $val)) { return $val }
    }
    # Fallback : process steam en cours
    $s = Get-Process -Name "steam" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($s -and $s.Path) { return Split-Path $s.Path }
    return $null
}

function Stop-ServiceSafe {
    param([string]$Name, [string]$Label, [switch]$Disable)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    $acted = $false
    if ($svc.Status -eq 'Running') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        $acted = $true
    }
    if ($Disable) {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
    }
    if ($acted -or $Disable) {
        $tag = if ($Disable) { "[STOP+DISABLE]" } else { "[STOP]" }
        Write-Host "  $tag $Label" -ForegroundColor DarkYellow
    }
    return $acted
}

function Get-TopNetworkProcesses {
    param([string[]]$Whitelist, [int]$MinConnections = 3)
    $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
             Group-Object OwningProcess
    $procs = Get-Process -ErrorAction SilentlyContinue
    $result = foreach ($grp in $conns) {
        $pid_ = [int]$grp.Name
        $proc = $procs | Where-Object { $_.Id -eq $pid_ } | Select-Object -First 1
        if ($proc -and $proc.Name -notin $Whitelist) {
            [PSCustomObject]@{ Name = $proc.Name; PID = $pid_; Connections = $grp.Count }
        }
    }
    return $result | Where-Object { $_.Connections -ge $MinConnections } |
           Sort-Object Connections -Descending | Select-Object -First 15
}

function Save-Blacklist {
    param([System.Collections.Generic.HashSet[string]]$List, [string]$Path)
    @{
        processes   = @($List | Sort-Object)
        count       = $List.Count
        lastUpdated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Encoding UTF8 $Path
}

# ── Init ───────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  $GameName - Optimiseur reseau   " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$killCount  = 0
$stopCount  = 0
$dynKilled  = @()
$backupData = @{}

# ── Detection interface reseau ─────────────────────────────────────────
$adapter = Get-ActiveNetAdapter
if ($adapter) {
    $ifName  = $adapter.Name
    $ifIndex = $adapter.InterfaceIndex
    Write-Host "  Interface  : $ifName ($($adapter.InterfaceDescription))" -ForegroundColor DarkGray
} else {
    Write-Host "  [WARN] Aucune interface reseau detectee - fallback Wi-Fi" -ForegroundColor DarkYellow
    $ifName  = "Wi-Fi"
    $ifIndex = (Get-NetAdapter -Name "Wi-Fi" -ErrorAction SilentlyContinue).InterfaceIndex
}

# ── Detection chemin Steam ─────────────────────────────────────────────
$steamPath = Get-SteamPath
if ($steamPath) {
    Write-Host "  Steam      : $steamPath" -ForegroundColor DarkGray
} else {
    Write-Host "  [WARN] Steam non detecte via registre" -ForegroundColor DarkYellow
}

# ── Backup settings ────────────────────────────────────────────────────
$backupData["Interface"]      = $ifName
$backupData["InterfaceIndex"] = $ifIndex
$backupData["InterfaceGuid"]  = (Get-NetAdapter -Name $ifName -ErrorAction SilentlyContinue).InterfaceGuid
$backupData["DNS"]            = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
$tcpGlobal                    = netsh int tcp show global
$backupData["AutoTuning"]     = ($tcpGlobal | Select-String "Receive Window Auto|Niveau d.auto") -replace ".*:\s*",""
$backupData["Timestamps"]     = ($tcpGlobal | Select-String "Horodatages|Timestamps") -replace ".*:\s*",""
$backupData["ECN"]            = ($tcpGlobal | Select-String "ECN") -replace ".*:\s*",""
$qosKey                       = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
$backupData["QoSKeyExisted"]  = (Test-Path $qosKey)
$backupData["QoSLimit"]       = if (Test-Path $qosKey) { (Get-ItemProperty $qosKey -ErrorAction SilentlyContinue).NonBestEffortLimit } else { $null }
$nagleKey = if ($backupData["InterfaceGuid"]) { "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($backupData['InterfaceGuid'])" } else { $null }
if ($nagleKey -and (Test-Path $nagleKey)) {
    $nagle = Get-ItemProperty $nagleKey -ErrorAction SilentlyContinue
    $backupData["NagleAckFreq"] = $nagle.TcpAckFrequency
    $backupData["NagleNoDelay"] = $nagle.TCPNoDelay
}
# MMCSS NetworkThrottlingIndex
$mmcssKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
$backupData["NetworkThrottlingIndex"] = (Get-ItemProperty $mmcssKey -ErrorAction SilentlyContinue).NetworkThrottlingIndex
# NIC power management (registre adaptateur)
$nicRegBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
$nicRegKey  = Get-ChildItem $nicRegBase -ErrorAction SilentlyContinue |
              Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).NetCfgInstanceId -ieq $backupData["InterfaceGuid"] } |
              Select-Object -First 1
if ($nicRegKey) {
    $backupData["NicRegPath"] = $nicRegKey.PSPath
    $backupData["NicPnPCaps"] = (Get-ItemProperty $nicRegKey.PSPath -ErrorAction SilentlyContinue).PnPCapabilities
}
$backupData | ConvertTo-Json | Set-Content -Encoding UTF8 "$PSScriptRoot\wifi-gaming-backup.json"

# ── [1/6] Kill liste statique ──────────────────────────────────────────
Write-Host ""
Write-Host "== [1/6] Processus connus ===================" -ForegroundColor Yellow

$whitelist = @(
    "cs2","steam","steamwebhelper","discord","powershell","pwsh",
    "explorer","dwm","csrss","winlogon","services","lsass","svchost",
    "taskmgr","conhost","audiodg","nvcontainer","NVDisplay.Container",
    "Code","cursor","devenv",
    "Spotify","SpotifyLauncher",
    # Windows Defender - jamais tuer
    "MpDefenderCoreService","MsMpEng","NisSrv","SecurityHealthService",
    # Windows Search / Start menu - UI systeme critique, se relance immediatement
    "SearchHost","SearchIndexer","SearchProtocolHost","SearchFilterHost",
    "ShellExperienceHost","StartMenuExperienceHost",
    # Processus inoffensifs captures par [NEW-DYN] par erreur (1 TCP suffit)
    "MicrosoftStartFeedProvider","APSDaemon","ctfmon",
    # Shells generiques - ne jamais auto-ajouter (tuer tous les cmd.exe serait catastrophique)
    "cmd","wscript","cscript","msiexec","rundll32","dllhost"
)

$knownKillList = @(
    # Cloud / sync
    "OneDrive","Dropbox","GoogleDriveFS","googledrivesync",
    # Communication (Discord exclu - outil team)
    "Teams","ms-teams","Slack",
    # Xbox / GameBar
    "GameBar","GameBarPresenceWriter","XbOnt faox","XboxGameOverlay","XboxSpeechToTextOverlay",
    # Mises a jour
    "MicrosoftEdgeUpdate","MusNotification",
    # Musique (Spotify exclu - voulu par l'utilisateur)
    # "Spotify","SpotifyLauncher",
    # iCloud / Apple (AppleMobileDeviceProcess exclu : requis pour tethering USB iPhone)
    "iCloudHome","iCloudDrive","iCloudPhotos","iCloudCKKS","iCloudOutlookConfig",
    "iCloudServices","ApplePhotoStreams","iCloud",
    # Peripheriques gaming
    "SteelSeriesSonar","SteelSeriesEngine","SteelSeriesPrism","SteelSeriesGG","SteelSeriesGGEZ",
    "lghub_agent","lghub_system_tray","ArmourySocketServer",
    # Adobe / divers
    "AdobeCollabSync",
    # WebView2 (utilise par Xbox/GamingServices ET Windows Widgets)
    "msedgewebview2",
    # Windows 11 Widgets (SearchHost retire - processus systeme Windows, ne jamais tuer)
    "WidgetBoard","WidgetService",
    # OneDrive updater
    "OneDriveStandaloneUpdater",
    # Valorant anti-cheat (inutile en CS2)
    "vgtray"
)

# ── Blacklist persistante (DB JSON) ───────────────────────────────────
$blacklistFile = "$PSScriptRoot\process-blacklist.json"
$killList = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Charger depuis fichier si existe
if (Test-Path $blacklistFile) {
    $saved = Get-Content $blacklistFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($saved.processes) {
        $beforeCount = 0; $skipped = 0
        $saved.processes | ForEach-Object {
            $beforeCount++
            if ($_ -in $whitelist) { $skipped++ }
            else { [void]$killList.Add($_) }
        }
        if ($skipped -gt 0) { Write-Host "  DB          : $skipped entrees whitelistees ignorees (ex: Defender, SearchHost)" -ForegroundColor DarkYellow }
    }
    Write-Host "  DB          : $($killList.Count) processus charges depuis process-blacklist.json" -ForegroundColor DarkGray
} else {
    Write-Host "  DB          : premier lancement, creation de process-blacklist.json" -ForegroundColor DarkGray
}

# Merger avec la seed (nouvelles entrees du code ajoutees automatiquement)
$knownKillList | ForEach-Object { [void]$killList.Add($_) }
Save-Blacklist -List $killList -Path $blacklistFile

foreach ($proc in $killList) {
    if (Get-Process -Name $proc -ErrorAction SilentlyContinue) {
        Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
        Write-Host "  [KILL] $proc" -ForegroundColor Red
        $killCount++
    }
}

# ── [2/6] Detection dynamique des consommateurs reseau ─────────────────
Write-Host ""
Write-Host "== [2/6] Detection dynamique (TCP actif) ====" -ForegroundColor Yellow

$topNet = Get-TopNetworkProcesses -Whitelist $whitelist -MinConnections 3
foreach ($p in $topNet) {
    if (-not $killList.Contains($p.Name)) {
        Stop-Process -Id $p.PID -Force -ErrorAction SilentlyContinue
        [void]$killList.Add($p.Name)
        Write-Host "  [KILL-DYN] $($p.Name) ($($p.Connections) TCP) -> ajoute a la DB" -ForegroundColor DarkRed
        $dynKilled += $p.Name
        $killCount++
    }
}
if ($dynKilled.Count -gt 0) {
    Save-Blacklist -List $killList -Path $blacklistFile
} else {
    Write-Host "  Aucun processus supplementaire detecte" -ForegroundColor DarkGray
}

# ── [3/6] Services ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "== [3/6] Services reseau de fond ============" -ForegroundColor Yellow

$services = @(
    @{ Name="BITS";                            Label="BITS (Windows Update DL)";   Disable=$false },
    @{ Name="wuauserv";                        Label="Windows Update";              Disable=$false },
    @{ Name="SysMain";                         Label="SysMain (Superfetch)";        Disable=$false },
    @{ Name="WSearch";                         Label="WSearch (indexation)";        Disable=$true  },
    @{ Name="DiagTrack";                       Label="DiagTrack (telemetrie)";      Disable=$false },
    @{ Name="SteelSeriesGGUpdateServiceProxy"; Label="SteelSeries GG Update";       Disable=$true  },
    # Xbox / GamingServices - toute la famille pour eviter respawn
    @{ Name="GamingServices";                  Label="Xbox GamingServices";         Disable=$true  },
    @{ Name="GamingServicesNet";               Label="Xbox GamingServicesNet";      Disable=$true  },
    @{ Name="XblAuthManager";                  Label="Xbox Auth Manager";           Disable=$true  },
    @{ Name="XblGameSave";                     Label="Xbox Game Save";              Disable=$true  },
    @{ Name="XboxNetApiSvc";                   Label="Xbox Live Networking";        Disable=$true  },
    @{ Name="XboxGipSvc";                      Label="Xbox Accessory Mgmt";         Disable=$true  },
    # iCloud - service racine qui relance tous les processus iCloud
    # AppleMobileDeviceService EXCLU : requis pour tethering USB iPhone
    @{ Name="Bonjour";                         Label="Bonjour (Apple)";             Disable=$true  },
    # Windows Widgets - root spawner de msedgewebview2
    @{ Name="Widgets";                         Label="Windows Widgets";             Disable=$true  },
    # Consommateurs upload en arriere-plan -- critiques sur 4G tethering
    @{ Name="DoSvc";   Label="Delivery Optimization (upload vers pairs)"; Disable=$true  },
    @{ Name="WerSvc";  Label="Windows Error Reporting (upload crashs)";   Disable=$false },
    @{ Name="UsoSvc";  Label="Update Orchestrator (declencheur MAJ)";     Disable=$false }
)
foreach ($svc in $services) {
    if (Stop-ServiceSafe -Name $svc.Name -Label $svc.Label -Disable:$svc.Disable) { $stopCount++ }
}

# nvcontainer -> BelowNormal (ne pas tuer, juste abaisser la priorite)
Get-Process -Name "nvcontainer","NVDisplay.Container" -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
}
Write-Host "  [PRIO] nvcontainer -> BelowNormal" -ForegroundColor DarkGray

# Force-disable via registre les services proteges Xbox (Set-Service est ignore par SCM sur ces services)
foreach ($svcName in @("GamingServices","GamingServicesNet","XblAuthManager","XblGameSave","XboxNetApiSvc","XboxGipSvc")) {
    $rp = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
    if (Test-Path $rp) {
        Set-ItemProperty $rp -Name Start -Value 4 -Type DWord -ErrorAction SilentlyContinue
    }
}
Write-Host "  [REG] Services Xbox force-desactives via registre" -ForegroundColor DarkGray

# Vider les recovery actions SCM (sinon le SCM relance le service apres kill comme si c'etait un crash)
foreach ($svcName in @("GamingServices","GamingServicesNet","XblAuthManager","XblGameSave","XboxNetApiSvc","XboxGipSvc")) {
    & sc.exe failure $svcName reset= 0 actions= "" 2>$null | Out-Null
}
Write-Host "  [SCM] Recovery actions Xbox videes (plus de restart sur crash)" -ForegroundColor DarkGray

# Supprimer les trigger-starts Xbox (cause principale du respawn de GamingServices malgre Start=4)
# Les services modernes Windows utilisent des triggers d'evenements pour se lancer, independamment du type de demarrage
foreach ($svcName in @("GamingServices","GamingServicesNet","XblAuthManager","XblGameSave","XboxNetApiSvc","XboxGipSvc")) {
    & sc.exe triggerinfo $svcName delete 2>$null | Out-Null
}
Write-Host "  [SCM] Trigger-starts Xbox supprimes" -ForegroundColor DarkGray

# ── [4/6] Optimisations reseau ─────────────────────────────────────────
Write-Host ""
Write-Host "== [4/6] Optimisations reseau ===============" -ForegroundColor Yellow

# Plan alimentation -> Ultimate Performance (backup du plan actuel)
$origPPlanOut_ = powercfg /getactivescheme
if ($origPPlanOut_ -match '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') { $origPowerPlan_ = $Matches[1] } else { $origPowerPlan_ = $null }
$upGuid_ = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
if (-not ((powercfg /list) -join ' ' -match $upGuid_)) { powercfg -duplicatescheme $upGuid_ 2>$null | Out-Null }
powercfg -setactive $upGuid_ 2>$null | Out-Null
$planLabel_ = if ((powercfg /getactivescheme) -join ' ' -match $upGuid_) { 'Ultimate Performance' } else {
    powercfg -setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 2>$null | Out-Null; 'High Performance (UP non disponible)'
}
$ppSuffix_ = if ($origPowerPlan_) { " (avant : $($origPowerPlan_.Substring(0,8))...)" } else { '' }
Write-Host "  Power Plan  -> $planLabel_$ppSuffix_" -ForegroundColor Green
# Background apps -> toutes suspendues (key HKCU)
$bgAppsKey_ = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
$origBgApps_ = (Get-ItemProperty $bgAppsKey_ -EA SilentlyContinue).GlobalUserDisabled
if (-not (Test-Path $bgAppsKey_)) { New-Item -Path $bgAppsKey_ -Force | Out-Null }
Set-ItemProperty -Path $bgAppsKey_ -Name 'GlobalUserDisabled' -Value 1 -Type DWord -EA SilentlyContinue
Write-Host "  BG Apps     -> suspendues (background refresh desactive)" -ForegroundColor Green
netsh int tcp set global ecncapability=disabled    | Out-Null ; Write-Host "  ECN         -> disabled (NAT 4G incompatible)" -ForegroundColor Green
netsh int tcp set global autotuninglevel=restricted | Out-Null ; Write-Host "  AutoTuning  -> restricted (BW variable)" -ForegroundColor Green
netsh int tcp set global timestamps=disabled        | Out-Null ; Write-Host "  Timestamps  -> disabled (overhead reduit)" -ForegroundColor Green

Set-DnsClientServerAddress -InterfaceAlias $ifName -ServerAddresses "1.0.0.1","1.1.1.1" -ErrorAction SilentlyContinue
ipconfig /flushdns | Out-Null
Write-Host "  DNS         -> 1.0.0.1 / 1.1.1.1 (Cloudflare - ordre benchmark)" -ForegroundColor Green

if (-not (Test-Path $qosKey)) { New-Item -Path $qosKey -Force | Out-Null }
Set-ItemProperty -Path $qosKey -Name NonBestEffortLimit -Value 0 -Type DWord
Write-Host "  QoS         -> 0 (100% bande passante)" -ForegroundColor Green

if ($nagleKey -and (Test-Path $nagleKey)) {
    Set-ItemProperty -Path $nagleKey -Name TcpAckFrequency -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $nagleKey -Name TCPNoDelay      -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Host "  Nagle       -> desactive (latence TCP reduite)" -ForegroundColor Green
}
Set-ItemProperty $mmcssKey -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord -ErrorAction SilentlyContinue
$origSysResp_ = (Get-ItemProperty $mmcssKey -EA SilentlyContinue).SystemResponsiveness
Set-ItemProperty $mmcssKey -Name SystemResponsiveness -Value 0 -Type DWord -EA SilentlyContinue
Write-Host "  Throttling  -> desactive (MMCSS NetworkThrottlingIndex + SystemResponsiveness=0)" -ForegroundColor Green
if ($backupData["NicRegPath"]) {
    Set-ItemProperty -Path $backupData["NicRegPath"] -Name PnPCapabilities -Value 24 -Type DWord -ErrorAction SilentlyContinue
    Write-Host "  NIC Sleep   -> desactive (micro-coupures evitees)" -ForegroundColor Green
}
# NIC : Interrupt Moderation + Flow Control -> Disabled (latence par paquet reduite)
foreach ($nicProp_ in @('Interrupt Moderation', 'Adaptive Interrupt Moderation', 'Interrupt Moderation Rate')) {
    if (Get-NetAdapterAdvancedProperty -Name $ifName -DisplayName $nicProp_ -EA SilentlyContinue) {
        Set-NetAdapterAdvancedProperty -Name $ifName -DisplayName $nicProp_ -DisplayValue 'Disabled' -EA SilentlyContinue
        Write-Host "  NIC IMod    -> Disabled ($nicProp_)" -ForegroundColor Green; break
    }
}
foreach ($nicProp_ in @('Flow Control', 'IEEE 802.3x Flow Control')) {
    if (Get-NetAdapterAdvancedProperty -Name $ifName -DisplayName $nicProp_ -EA SilentlyContinue) {
        Set-NetAdapterAdvancedProperty -Name $ifName -DisplayName $nicProp_ -DisplayValue 'Disabled' -EA SilentlyContinue
        Write-Host "  NIC FC      -> Disabled ($nicProp_)" -ForegroundColor Green
    }
}
netsh int tcp set global initialRto=2000       | Out-Null ; Write-Host "  InitialRTO  -> 2000ms (retransmit plus rapide)" -ForegroundColor Green
netsh int ip delete destinationcache           | Out-Null
netsh int ip delete arpcache                   | Out-Null
Write-Host "  Cache IP    -> flushe (ARP + destination cache)" -ForegroundColor Green
$wt_src = 'using System.Runtime.InteropServices; public class WinTimer { [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p); [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint p); }'
Add-Type -TypeDefinition $wt_src -Language CSharp -EA SilentlyContinue
[WinTimer]::timeBeginPeriod(1) | Out-Null
Write-Host "  Timer       -> 1ms resolution (input lag reduit)" -ForegroundColor Green

# ── [5/6] Windows Defender exclusions ─────────────────────────────────
Write-Host ""
Write-Host "== [5/6] Defender exclusions ================" -ForegroundColor Yellow

$exclPaths = @()
if ($GamePath -and (Test-Path $GamePath)) { $exclPaths += $GamePath }
if ($steamPath) { $exclPaths += "$steamPath\steamapps" }
foreach ($p in $exclPaths) {
    if (Test-Path $p) {
        $existing = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath
        if ($p -notin $existing) {
            Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
            Write-Host "  [EXCLU] $(Split-Path $p -Leaf)" -ForegroundColor Green
        } else {
            Write-Host "  [OK]    $(Split-Path $p -Leaf)" -ForegroundColor DarkGray
        }
    }
}
$exclProcs = @("steam.exe","steamwebhelper.exe")
if ($GameExe -and "$GameExe.exe" -notin $exclProcs) { $exclProcs += "$GameExe.exe" }
foreach ($proc in $exclProcs) {
    $existing = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionProcess
    if ($proc -notin $existing) {
        Add-MpPreference -ExclusionProcess $proc -ErrorAction SilentlyContinue
        Write-Host "  [EXCLU] $proc" -ForegroundColor Green
    } else {
        Write-Host "  [OK]    $proc" -ForegroundColor DarkGray
    }
}

# ── [6/8] MTU auto-optimisation ─────────────────────────────────────────
Write-Host ""
Write-Host "== [6/8] MTU auto-optimisation ==============" -ForegroundColor Yellow
$origMtu_ = (Get-NetIPInterface -InterfaceAlias $ifName -AddressFamily IPv4 -EA SilentlyContinue).NlMtu
if (-not $origMtu_ -or $origMtu_ -le 0) { $origMtu_ = 1500 }
$optMtu_ = 1400; $lo_ = 1200; $hi_ = 1452
while ($hi_ - $lo_ -gt 4) {
    $mid_ = [int](($lo_ + $hi_) / 2)
    $pay_ = $mid_ - 28
    $out_ = (& ping -4 -f -l $pay_ -n 1 -w 1000 8.8.8.8 2>$null) -join ' '
    if ($out_ -match 'TTL|[Rr][eé]ponse|[Rr]eply') { $optMtu_ = $mid_; $lo_ = $mid_ } else { $hi_ = $mid_ }
}
netsh int ipv4 set subinterface "$ifName" mtu=$optMtu_ store=persistent | Out-Null
Write-Host "  MTU         -> $optMtu_ octets (auto-detecte, fragmentation evitee)" -ForegroundColor Green

# ── [7/8] QoS DSCP 46 (Expedited Forwarding) ────────────────────────────
Write-Host ""
Write-Host "== [7/8] QoS DSCP 46 (EF) ==================" -ForegroundColor Yellow
Get-NetQosPolicy -Name "GameOptim-*" -EA SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -EA SilentlyContinue
if ($GameExe) {
    $qosExe_ = "$GameExe.exe"
    if ($GamePath -and (Test-Path (Join-Path $GamePath "$GameExe.exe"))) {
        $qosExe_ = Join-Path $GamePath "$GameExe.exe"
    }
    New-NetQosPolicy -Name "GameOptim-$GameExe" -AppPathNameMatchCondition $qosExe_ -DSCPAction 46 -EA SilentlyContinue | Out-Null
    Write-Host "  DSCP 46     -> $qosExe_ (Expedited Forwarding, priorite max)" -ForegroundColor Green
}
# Throttler tout le trafic background pour preempter l'uplink 4G en faveur du jeu
Get-NetQosPolicy -Name "BgThrottle-*" -EA SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -EA SilentlyContinue
New-NetQosPolicy -Name "BgThrottle-Default" -Default -ThrottleRateActionBitsPerSecond 1000000 -EA SilentlyContinue | Out-Null
Write-Host "  QoS Throttle-> background <= 1Mbps (uplink 4G libre pour le jeu)" -ForegroundColor Green

# ── WireGuard : detection et optimisations supplementaires ───────────────
$wgAdapter_ = Get-NetAdapter -EA SilentlyContinue | Where-Object {
    ($_.InterfaceDescription -like '*WireGuard*' -or $_.Name -eq 'CS2-WG') -and $_.Status -eq 'Up'
} | Select-Object -First 1
$wgActive_ = $null -ne $wgAdapter_
if ($wgActive_) {
    Write-Host ""
    Write-Host "  [WireGuard]  -> ACTIF : $($wgAdapter_.Name) (tunnel vers VPS Paris)" -ForegroundColor Cyan
    # DSCP 46 sur wireguard.exe : les paquets UDP encapsules sortent avec marquage EF sur la 4G
    New-NetQosPolicy -Name "GameOptim-WireGuard" -AppPathNameMatchCondition "wireguard.exe" -DSCPAction 46 -EA SilentlyContinue | Out-Null
    Write-Host "  DSCP 46     -> wireguard.exe (EF marque sur uplink 4G physique)" -ForegroundColor Green
    # MTU WireGuard = MTU physique - 80 octets (overhead WireGuard + UDP + IP)
    if ($optMtu_ -and $optMtu_ -gt 0) {
        $wgMtu_ = [Math]::Max(1280, $optMtu_ - 80)
        netsh int ipv4 set subinterface "$($wgAdapter_.Name)" mtu=$wgMtu_ store=persistent 2>$null | Out-Null
        Write-Host "  WG MTU      -> $wgMtu_ (physique $optMtu_ - 80 overhead)" -ForegroundColor Green
    }
}

# ── [8/8] Lancement CS2 ────────────────────────────────────────────────
Write-Host ""
Write-Host "== [8/8] Lancement $GameName ======================" -ForegroundColor Cyan

# Verifier si le jeu est deja en cours d'execution
$cs2 = $null
if ($GameExe) {
    $cs2 = Get-Process -Name $GameExe -EA SilentlyContinue | Select-Object -First 1
}
if (-not $cs2 -and $GamePath) {
    foreach ($pr_ in @(Get-Process -EA SilentlyContinue)) {
        try {
            $exePath_ = $pr_.MainModule.FileName
            if ($exePath_ -and $exePath_.StartsWith($GamePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $cs2 = $pr_; break
            }
        } catch {}
    }
}

if ($cs2) {
    Write-Host "  $GameName deja en cours (PID $($cs2.Id)) -- lancement ignore" -ForegroundColor DarkYellow
} else {
    # Snapshot des PID actifs avant le lancement (pour detecter le nouveau processus par chemin)
    $pidsBefore = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($pr_ in @(Get-Process -EA SilentlyContinue)) { $pidsBefore.Add($pr_.Id) | Out-Null }

    if ($LaunchUri) {
        Start-Process $LaunchUri
    } else {
        Write-Host "  Aucun URI de lancement configure -- demarrez $GameName manuellement" -ForegroundColor DarkYellow
    }
    Write-Host "  Attente demarrage $GameName (max 120s)..." -ForegroundColor DarkGray

    $waited = 0
    while (-not $cs2 -and $waited -lt 120) {
        Start-Sleep -Seconds 3; $waited += 3

        # M1 : par nom connu ($GameExe issu du scan ACF/manifest)
        if ($GameExe) {
            $cs2 = Get-Process -Name $GameExe -EA SilentlyContinue | Select-Object -First 1
        }

        # M2 : nouveau processus dont l'exe se trouve dans le dossier d'installation
        # (couvre le cas ou $GameExe est incorrect / mauvais exe detecte par le scan)
        if (-not $cs2 -and $GamePath) {
            foreach ($pr_ in @(Get-Process -EA SilentlyContinue | Where-Object { -not $pidsBefore.Contains($_.Id) })) {
                try {
                    $exePath_ = $pr_.MainModule.FileName
                    if ($exePath_ -and $exePath_.StartsWith($GamePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $cs2 = $pr_; break
                    }
                } catch {}
            }
        }
    }
}

if ($cs2) {
    try {
        $cs2.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
        Write-Host "  $GameName PID $($cs2.Id) -> Priorite High" -ForegroundColor Green
        # CPU affinity : exclure le core 0 (gere les IRQ/DPC systeme)
        $coreCount_ = [System.Environment]::ProcessorCount
        if ($coreCount_ -gt 1 -and $coreCount_ -le 62) {
            $affinityMask_ = [IntPtr]((1L -shl $coreCount_) - 1L -band (-bnot 1L))
            $cs2.ProcessorAffinity = $affinityMask_
            Write-Host "  $GameName Affinity  -> cores 1-$($coreCount_-1) (core 0/IRQ exclu)" -ForegroundColor Green
        }
    } catch { Write-Host "  Priorite/Affinity non appliquee : $_" -ForegroundColor DarkYellow }
} else {
    Write-Host "  $GameName non detecte apres 120s" -ForegroundColor DarkYellow
}

# ── Bilan ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Bilan"
Write-Host "  Interface       : $ifName"
Write-Host "  Steam           : $(if ($steamPath) { $steamPath } else { 'non detecte' })"
Write-Host "  Processus tues  : $killCount$(if ($dynKilled.Count -gt 0) { ' (dont ' + $dynKilled.Count + ' detectes dynamiquement : ' + ($dynKilled -join ', ') + ')' })"
Write-Host "  Services stoppes: $stopCount"
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# ── Surveillance continue + attente fermeture CS2 ─────────────────────
if ($cs2) {
    Write-Host "En attente de la fermeture de $GameName..." -ForegroundColor DarkGray
    Write-Host "(Surveillance active toutes les 20s | Restauration automatique a la fermeture)" -ForegroundColor DarkGray

    # Compteur de respawn par process : escalade, puis abandon apres $GiveUpAfter cycles
    $respawnCount    = @{}
    $giveUpList      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $GiveUpAfter     = 8   # apres 8 cycles (160s) sans succes : arreter de cibler ce process
    # Processus UI non-reseau : give-up apres 2 cycles (pas la peine d'insister 160s)
    $fastGiveUpSet   = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@("WidgetBoard","WidgetService","GameBarPresenceWriter"),
        [System.StringComparer]::OrdinalIgnoreCase)

    while ($true) {
        # Attendre 20s par tranches de 5s (compte a rebours visible dans le launcher)
        $remaining = 20
        while ($remaining -gt 0 -and -not $cs2.HasExited) {
            $cs2.WaitForExit(5000) | Out-Null
            if ($cs2.HasExited) { break }
            $remaining -= 5
            if ($remaining -gt 0) {
                # Afficher le compte a rebours seulement si des process non-abandonnes restent actifs
                $hasPending = [bool]($killList | Where-Object { -not $giveUpList.Contains($_) })
                if ($hasPending) {
                    Write-Host "  Prochain cycle dans ${remaining}s..." -ForegroundColor DarkGray
                }
            }
        }

        # CS2 ferme -> sortir
        if ($cs2.HasExited) { break }

        # Mesure de latence live (ping 1.1.1.1 + VPS WireGuard, 2 requetes chacun)
        foreach ($pingTarget_ in @("1.1.1.1", "10.66.66.1")) {
            $pingReply_ = Test-Connection -ComputerName $pingTarget_ -Count 2 -EA SilentlyContinue
            if ($pingReply_) {
                $latProp_  = if ($pingReply_[0].PSObject.Properties['ResponseTime']) { 'ResponseTime' } else { 'Latency' }
                $times_    = $pingReply_ | Select-Object -ExpandProperty $latProp_ -EA SilentlyContinue | Where-Object { $_ -ne $null }
                if ($times_) {
                    $avgMs_  = [int]($times_ | Measure-Object -Average).Average
                    $maxMs_  = [int]($times_ | Measure-Object -Maximum).Maximum
                    $minMs_  = [int]($times_ | Measure-Object -Minimum).Minimum
                    $jitter_ = $maxMs_ - $minMs_
                    $isVps_  = $pingTarget_ -eq "10.66.66.1"
                    $label_  = if ($isVps_) { "VPS WG  " } else { "1.1.1.1 " }
                    if ($isVps_) {
                        # VPS = route CS2 reelle -> spike critique, logue
                        $pCol_  = if ($maxMs_ -gt 150) { 'Red' } elseif ($maxMs_ -gt 80) { 'DarkYellow' } else { 'Green' }
                        $spike_ = if ($maxMs_ -gt 150) { '  ** SPIKE CS2 **' } else { '' }
                        Write-Host "  [PING] $label_  avg=${avgMs_}ms  max=${maxMs_}ms  jitter=${jitter_}ms$spike_" -ForegroundColor $pCol_
                        if ($maxMs_ -gt 150) {
                            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $GameName | VPS | avg=${avgMs_}ms max=${maxMs_}ms jitter=${jitter_}ms" |
                                Add-Content -Path "$PSScriptRoot\latency-spikes.log" -Encoding UTF8 -EA SilentlyContinue
                        }
                    } else {
                        # 1.1.1.1 = indicateur reseau global, pas critique pour CS2
                        $pCol_  = if ($maxMs_ -gt 150) { 'DarkYellow' } elseif ($maxMs_ -gt 80) { 'DarkYellow' } else { 'Green' }
                        $spike_ = if ($maxMs_ -gt 150) { '  (reseau instable)' } else { '' }
                        Write-Host "  [PING] $label_  avg=${avgMs_}ms  max=${maxMs_}ms  jitter=${jitter_}ms$spike_" -ForegroundColor $pCol_
                    }
                }
            }
        }

        # Re-kill toute la killList avec escalade sur respawn persistant
        # systemProcs = processus Windows critiques qu'on ne touche jamais
        $systemProcs = @("services","svchost","wininit","winlogon","csrss","smss",
                         "lsass","System","Idle","Registry","RuntimeBroker",
                         "ApplicationFrameHost","sihost","fontdrvhost",
                         # Protection supplementaire - processus critiques Windows
                         "SearchHost","SearchIndexer","MsMpEng","MpDefenderCoreService",
                         "ShellExperienceHost","StartMenuExperienceHost","TextInputHost")
        foreach ($proc in @($killList)) {
            # Give-up : process protege par Windows, inutile de continuer a le cibler
            if ($giveUpList.Contains($proc)) { continue }

            $running = Get-Process -Name $proc -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $running) { continue }

            $respawnCount[$proc] = ([int]$respawnCount[$proc]) + 1

            # Processus UI non-reseau : give-up apres 2 cycles au lieu de 8
            if ($fastGiveUpSet.Contains($proc) -and $respawnCount[$proc] -ge 2) {
                [void]$giveUpList.Add($proc)
                Write-Host "  [GIVEUP] $proc (cycle #$($respawnCount[$proc])) -- processus UI non-reseau, abandonne" -ForegroundColor DarkGray
                continue
            }

            # Abandon apres GiveUpAfter cycles consecutifs (service protege par package Windows)
            if ($respawnCount[$proc] -ge $GiveUpAfter) {
                [void]$giveUpList.Add($proc)
                Write-Host "  [GIVEUP] $proc (cycle #$($respawnCount[$proc])) -- service protege par Windows/Store, ignore pour cette session" -ForegroundColor DarkYellow
                continue
            }

            # Tree-kill immediat : pas de grace pour les process deja connus mauvais
            # Remonter l'arbre parents (max 3 niveaux) pour trouver le vrai lanceur
            $rootParent = $null
            $current    = $running.Id
            for ($level = 0; $level -lt 3; $level++) {
                $ci2 = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
                if (-not $ci2) { break }
                $pp = Get-Process -Id $ci2.ParentProcessId -ErrorAction SilentlyContinue
                if (-not $pp) { break }

                if ($pp.Name -in $systemProcs -or $pp.Name -in $whitelist) {
                    # Parent systeme (svchost/SCM) : le service ignore Set-Service -> forcer via registre
                    if ($pp.Name -in @("svchost","services")) {
                        $matchingSvc = $services | Where-Object { $_.Name -ieq $proc }
                        if ($matchingSvc) {
                            # Arret multiple : Stop-Service + sc.exe stop (SCM direct) + sc.exe config
                            Stop-Service -Name $matchingSvc.Name -Force -ErrorAction SilentlyContinue
                            & sc.exe stop $matchingSvc.Name 2>$null | Out-Null
                            & sc.exe config $matchingSvc.Name start= disabled 2>$null | Out-Null
                            $rp = "HKLM:\SYSTEM\CurrentControlSet\Services\$($matchingSvc.Name)"
                            if (Test-Path $rp) {
                                Set-ItemProperty $rp -Name Start -Value 4 -ErrorAction SilentlyContinue
                                Write-Host "  [SVC-FORCE] $($matchingSvc.Name) re-desactive (registre+SCM)" -ForegroundColor DarkYellow
                            }
                            # Supprimer les trigger-starts ET vider les recovery actions
                            & sc.exe triggerinfo $matchingSvc.Name delete 2>$null | Out-Null
                            & sc.exe failure $matchingSvc.Name reset= 0 actions= "" 2>$null | Out-Null
                        }
                    }
                    break
                }

                # Parent non-systeme, non-whitelist, de nom different -> candidat root
                if ($pp.Name -ine $proc) { $rootParent = $pp }
                $current = $pp.Id
            }

            # Tuer l'arbre complet du process cible
            & taskkill /F /T /IM "$proc.exe" 2>$null

            # Tuer le parent non-systeme identifie (par PID pour etre precis)
            # SECURITE : ne jamais tuer un parent qui est dans whitelist ou systemProcs
            if ($rootParent -and
                $rootParent.Name -notin $whitelist -and
                $rootParent.Name -notin $systemProcs) {
                & taskkill /F /T /PID $rootParent.Id 2>$null
                Write-Host "  [PARENT-KILL] $($rootParent.Name) PID $($rootParent.Id)" -ForegroundColor Red
                if ($killList.Add($rootParent.Name)) {
                    Save-Blacklist -List $killList -Path $blacklistFile
                }
            } elseif ($rootParent -and ($rootParent.Name -in $whitelist -or $rootParent.Name -in $systemProcs)) {
                Write-Host "  [PARENT-SKIP] $($rootParent.Name) -- protege (whitelist/systeme)" -ForegroundColor DarkGray
            }

            # Desactiver les taches planifiees associees
            $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
                     Where-Object { $_.Actions.Execute -match [regex]::Escape($proc) }
            foreach ($t in $tasks) {
                Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
                Write-Host "  [TASK-OFF] $($t.TaskName)" -ForegroundColor DarkMagenta
            }

            Write-Host "  [TREE-KILL] $proc (cycle #$($respawnCount[$proc]))" -ForegroundColor Red
        }

        # Detection dynamique : nouveaux processus inconnus avec >= 3 TCP
        $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                 Group-Object OwningProcess
        $procs = Get-Process -ErrorAction SilentlyContinue
        $seenThisCycle = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $newDetections = $false
        foreach ($grp in $conns) {
            if ($grp.Count -ge 3) {
                $pid_ = [int]$grp.Name
                $p    = $procs | Where-Object { $_.Id -eq $pid_ } | Select-Object -First 1
                if ($p -and
                    $p.Name -notin $whitelist -and
                    -not $killList.Contains($p.Name) -and
                    $seenThisCycle.Add($p.Name)) {

                    Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue

                    # Ajouter a la killList + sauvegarder dans la DB
                    [void]$killList.Add($p.Name)
                    $newDetections = $true

                    # Si service connu -> desactiver pour eviter respawn
                    $matchingSvc = $services | Where-Object { $_.Name -ieq $p.Name }
                    if ($matchingSvc) {
                        Stop-Service -Name $matchingSvc.Name -Force -ErrorAction SilentlyContinue
                        Set-Service  -Name $matchingSvc.Name -StartupType Disabled -ErrorAction SilentlyContinue
                    }

                    Write-Host "  [NEW-DYN] $($p.Name) ($($grp.Count) TCP) -> ajoute a process-blacklist.json" -ForegroundColor Magenta
                }
            }
        }
        # Sauvegarder la DB si nouvelles detections ce cycle
        if ($newDetections) { Save-Blacklist -List $killList -Path $blacklistFile }
    }

    Start-Sleep -Seconds 3
    # Nettoyage des optimisations temporaires
    try { [WinTimer]::timeEndPeriod(1) | Out-Null } catch {}
    Get-NetQosPolicy -Name "GameOptim-*" -EA SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -EA SilentlyContinue
    if ($origMtu_ -and $origMtu_ -gt 0) {
        netsh int ipv4 set subinterface "$ifName" mtu=$origMtu_ store=persistent | Out-Null
        Write-Host "  MTU         -> $origMtu_ restauree" -ForegroundColor DarkGray
    }
    if ($origPowerPlan_) { powercfg -setactive $origPowerPlan_ 2>$null | Out-Null ; Write-Host "  Power Plan  -> restaure" -ForegroundColor DarkGray }
    if ($null -ne $origBgApps_) { Set-ItemProperty -Path $bgAppsKey_ -Name 'GlobalUserDisabled' -Value $origBgApps_ -Type DWord -EA SilentlyContinue }
    else { Remove-ItemProperty -Path $bgAppsKey_ -Name 'GlobalUserDisabled' -EA SilentlyContinue }
    if ($null -ne $origSysResp_) { Set-ItemProperty $mmcssKey -Name SystemResponsiveness -Value $origSysResp_ -Type DWord -EA SilentlyContinue }
    else { Remove-ItemProperty $mmcssKey -Name SystemResponsiveness -EA SilentlyContinue }
    Get-NetQosPolicy -Name "BgThrottle-*" -EA SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -EA SilentlyContinue
    Write-Host ""
    Write-Host "$GameName ferme. Restauration..." -ForegroundColor Yellow
    & "$PSScriptRoot\Restore-NetworkOptim.ps1"
} else {
    try { [WinTimer]::timeEndPeriod(1) | Out-Null } catch {}
    Get-NetQosPolicy -Name "GameOptim-*" -EA SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -EA SilentlyContinue
    if ($origMtu_ -and $origMtu_ -gt 0) { netsh int ipv4 set subinterface "$ifName" mtu=$origMtu_ store=persistent | Out-Null }
    if ($origPowerPlan_) { powercfg -setactive $origPowerPlan_ 2>$null | Out-Null }
    if ($null -ne $origBgApps_) { Set-ItemProperty -Path $bgAppsKey_ -Name 'GlobalUserDisabled' -Value $origBgApps_ -Type DWord -EA SilentlyContinue }
    else { Remove-ItemProperty -Path $bgAppsKey_ -Name 'GlobalUserDisabled' -EA SilentlyContinue }
    if ($null -ne $origSysResp_) { Set-ItemProperty $mmcssKey -Name SystemResponsiveness -Value $origSysResp_ -Type DWord -EA SilentlyContinue }
    else { Remove-ItemProperty $mmcssKey -Name SystemResponsiveness -EA SilentlyContinue }
    Get-NetQosPolicy -Name "BgThrottle-*" -EA SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -EA SilentlyContinue
    Write-Host "$GameName non detecte. Restauration manuelle :" -ForegroundColor DarkYellow
    Write-Host "  .\Restore-NetworkOptim.ps1" -ForegroundColor DarkGray
}
