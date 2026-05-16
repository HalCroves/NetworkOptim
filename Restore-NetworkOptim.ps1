#Requires -RunAsAdministrator
# ============================================================
#  Restore-NetworkOptim.ps1 - Restauration des reglages originaux
#  Lit le fichier network-backup.json créé par Apply-NetworkOptim.ps1
# ============================================================

$backupFile = "$PSScriptRoot\network-backup.json"

if (-not (Test-Path $backupFile)) {
    Write-Error "Fichier backup introuvable : $backupFile`nLancez d'abord Apply-NetworkOptim.ps1."
    exit 1
}

$backup = Get-Content -Encoding UTF8 $backupFile | ConvertFrom-Json
$ifName = $backup.Interface

Write-Host "Restauration des reglages pour : $ifName" -ForegroundColor Cyan
Write-Host ""

# ── 1. Restaurer les réglages TCP globaux ────────────────────
Write-Host "Restauration TCP globals..." -ForegroundColor Yellow

# Normaliser les valeurs (netsh n'accepte que des mots-clés en minuscules)
function Normalize($val) { if ($val) { return $val.ToLower() } else { return "normal" } }

$autoTuning = Normalize $backup.AutoTuning
$rss        = Normalize $backup.RSS
$rsc        = Normalize $backup.RSC
$timestamps = Normalize $backup.Timestamps
$ecn        = Normalize $backup.ECN

# AutoTuning : valeurs valides = disabled | highlyrestricted | restricted | normal | experimental
$validAutoTuning = @("disabled","highlyrestricted","restricted","normal","experimental")
if ($autoTuning -notin $validAutoTuning) { $autoTuning = "normal" }

# RSC/RSS/Timestamps : enabled | disabled
foreach ($name in @("rss","rsc","timestamps")) {
    $val = Get-Variable $name -ValueOnly
    if ($val -notin @("enabled","disabled")) { Set-Variable $name "enabled" }
}

# ECN : enabled | disabled | default
if ($ecn -notin @("enabled","disabled","default")) { $ecn = "disabled" }

netsh int tcp set global autotuninglevel=$autoTuning | Out-Null
netsh int tcp set global rss=$rss                   | Out-Null
netsh int tcp set global rsc=$rsc                   | Out-Null
netsh int tcp set global timestamps=$timestamps     | Out-Null
netsh int tcp set global ecncapability=$ecn         | Out-Null

Write-Host "  AutoTuning  = $autoTuning"
Write-Host "  RSS         = $rss"
Write-Host "  RSC         = $rsc"
Write-Host "  Timestamps  = $timestamps"
Write-Host "  ECN         = $ecn"

# ── 2. Restaurer le MTU ──────────────────────────────────────
Write-Host ""
Write-Host "Restauration MTU..." -ForegroundColor Yellow

$mtu = [int]$backup.MTU
if ($mtu -gt 0) {
    netsh interface ipv4 set subinterface "$ifName" mtu=$mtu store=persistent | Out-Null
    Write-Host "  MTU restaure : $mtu"
} else {
    Write-Host "  MTU ignore (valeur invalide dans le backup)." -ForegroundColor DarkYellow
}

# ── 3. Restaurer les DNS ─────────────────────────────────────
Write-Host ""
Write-Host "Restauration DNS..." -ForegroundColor Yellow

$dnsServers = @($backup.DNS)  # force tableau même si un seul élément

if ($dnsServers -and $dnsServers.Count -gt 0 -and $dnsServers[0]) {
    netsh interface ip set dns name="$ifName" static $dnsServers[0] | Out-Null
    Write-Host "  DNS primaire   : $($dnsServers[0])"

    for ($i = 1; $i -lt $dnsServers.Count; $i++) {
        netsh interface ip add dns name="$ifName" $dnsServers[$i] index=($i + 1) | Out-Null
        Write-Host "  DNS supplementaire : $($dnsServers[$i])"
    }
} else {
    # Aucun DNS sauvegarde -> repasser en DHCP
    netsh interface ip set dns name="$ifName" dhcp | Out-Null
    Write-Host "  Aucun DNS sauvegarde -> remis en DHCP."
}

# ── 4. Restaurer Nagle (registre) ───────────────────────────────
Write-Host ""
Write-Host "Restauration Nagle..." -ForegroundColor Yellow

$ifGuid   = $backup.InterfaceGuid
$nagleKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$ifGuid"

if ($ifGuid -and (Test-Path $nagleKey)) {
    $ackFreq = $backup.NagleAckFreq
    $noDelay = $backup.NagleNoDelay

    if ($null -ne $ackFreq) {
        Set-ItemProperty -Path $nagleKey -Name TcpAckFrequency -Value ([int]$ackFreq) -Type DWord
        Write-Host "  TcpAckFrequency restaure : $ackFreq"
    } else {
        Remove-ItemProperty -Path $nagleKey -Name TcpAckFrequency -ErrorAction SilentlyContinue
        Write-Host "  TcpAckFrequency supprime (n'existait pas)"
    }

    if ($null -ne $noDelay) {
        Set-ItemProperty -Path $nagleKey -Name TCPNoDelay -Value ([int]$noDelay) -Type DWord
        Write-Host "  TCPNoDelay restaure : $noDelay"
    } else {
        Remove-ItemProperty -Path $nagleKey -Name TCPNoDelay -ErrorAction SilentlyContinue
        Write-Host "  TCPNoDelay supprime (n'existait pas)"
    }
} else {
    Write-Host "  GUID interface introuvable, Nagle ignore." -ForegroundColor DarkYellow
}

# ── 5. Restaurer QoS ─────────────────────────────────────────────
Write-Host ""
Write-Host "Restauration QoS..." -ForegroundColor Yellow

$qosKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"

if ($backup.QoSKeyExisted -eq $false) {
    Remove-Item -Path $qosKey -Recurse -ErrorAction SilentlyContinue
    Write-Host "  Cle Psched supprimee (elle n'existait pas avant)"
} elseif ($null -ne $backup.QoSLimit) {
    if (-not (Test-Path $qosKey)) { New-Item -Path $qosKey -Force | Out-Null }
    Set-ItemProperty -Path $qosKey -Name NonBestEffortLimit -Value ([int]$backup.QoSLimit) -Type DWord
    Write-Host "  NonBestEffortLimit restaure : $($backup.QoSLimit)"
} else {
    Remove-ItemProperty -Path $qosKey -Name NonBestEffortLimit -ErrorAction SilentlyContinue
    Write-Host "  NonBestEffortLimit supprime (n'existait pas)"
}

# ── 6. Relancer les services suspendus par CS2-HighPriority ─────
Write-Host ""
Write-Host "Relance des services suspendus..." -ForegroundColor Yellow

foreach ($svc in @("BITS", "wuauserv", "SysMain", "DiagTrack")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Running') {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        Write-Host "  [START] $svc"
    }
}

# WSearch : remettre en Automatic et relancer
$ws = Get-Service -Name WSearch -ErrorAction SilentlyContinue
if ($ws) {
    Set-Service -Name WSearch -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name WSearch -ErrorAction SilentlyContinue
    Write-Host "  [START+ENABLE] WSearch"
}

# SteelSeries GG Update Service : remettre en Automatic
$ss = Get-Service -Name SteelSeriesGGUpdateServiceProxy -ErrorAction SilentlyContinue
if ($ss) {
    Set-Service -Name SteelSeriesGGUpdateServiceProxy -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name SteelSeriesGGUpdateServiceProxy -ErrorAction SilentlyContinue
    Write-Host "  [START+ENABLE] SteelSeries GG Update Service"
}

# AutoTuning remis a normal (CS2-HighPriority l'avait mis en restricted)
netsh int tcp set global autotuninglevel=normal | Out-Null
Write-Host "  AutoTuning remis a normal"

# ── 7. Restaurer les reglages Wi-Fi et reseau (wifi-gaming-backup.json) ─────
$wifiBackupFile = "$PSScriptRoot\wifi-gaming-backup.json"
if (Test-Path $wifiBackupFile) {
    Write-Host ""
    Write-Host "Restauration reglages Wi-Fi gaming..." -ForegroundColor Yellow
    $wb = Get-Content -Encoding UTF8 $wifiBackupFile | ConvertFrom-Json

    # Wi-Fi Power Save : desactive definitivement (PC fixe), pas de restauration
    # WMM : active definitivement (PC fixe), pas de restauration

    $dnsServers = @($wb.DNS) | Where-Object { $_ }
    $restoreIfName = if ($wb.Interface) { $wb.Interface } else { "Wi-Fi" }
    if ($dnsServers.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceAlias $restoreIfName -ServerAddresses $dnsServers -ErrorAction SilentlyContinue
        Write-Host "  DNS restaure : $($dnsServers -join ', ')"
    } else {
        Set-DnsClientServerAddress -InterfaceAlias $restoreIfName -ResetServerAddresses -ErrorAction SilentlyContinue
        Write-Host "  DNS remis en DHCP (aucun DNS sauvegarde)"
    }

    if ($wb.Timestamps) {
        netsh int tcp set global timestamps=$($wb.Timestamps) | Out-Null
        Write-Host "  RFC1323 Timestamps restaure : $($wb.Timestamps)"
    }

    if ($wb.QoSKeyCreated -eq $true) {
        $qosKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
        Remove-Item -Path $qosKey -Recurse -ErrorAction SilentlyContinue
        Write-Host "  Cle QoS Psched supprimee"
    }
    # MMCSS NetworkThrottlingIndex
    $mmcssKeyR  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    $restoreNTI = if ($null -ne $wb.NetworkThrottlingIndex) { [uint32]$wb.NetworkThrottlingIndex } else { [uint32]10 }
    Set-ItemProperty $mmcssKeyR -Name NetworkThrottlingIndex -Value $restoreNTI -Type DWord -ErrorAction SilentlyContinue
    Write-Host "  NetworkThrottlingIndex restaure : $restoreNTI"
    # NIC power management
    if ($wb.NicRegPath) {
        $restoreCaps = if ($null -ne $wb.NicPnPCaps) { [uint32]$wb.NicPnPCaps } else { [uint32]0 }
        Set-ItemProperty -Path $wb.NicRegPath -Name PnPCapabilities -Value $restoreCaps -Type DWord -ErrorAction SilentlyContinue
        Write-Host "  NIC PnPCapabilities restaure : $restoreCaps"
    }

    Remove-Item -Path $wifiBackupFile -ErrorAction SilentlyContinue
}

# ── Resume
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " Restauration terminee !" -ForegroundColor Green
Write-Host " Redemarre le PC pour que tous les"
Write-Host " changements soient pris en compte."
Write-Host "==========================================" -ForegroundColor Green
