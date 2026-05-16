#Requires -RunAsAdministrator
# ============================================================
#  Apply-NetworkOptim.ps1 - Optimisation reseau 4G gaming
#  Les réglages actuels sont sauvegardés dans network-backup.json
#  Pour annuler : .\Restore-NetworkOptim.ps1
# ============================================================

$backupFile = "$PSScriptRoot\network-backup.json"

# ── 1. Détecter l'interface active ──────────────────────────
# Priorité : Wi-Fi (71) puis Ethernet (6)
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceType -in @(71, 6) } |
           Sort-Object -Property @{Expression={if($_.InterfaceType -eq 71){0}else{1}}} |
           Select-Object -First 1

if (-not $adapter) {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
}

if (-not $adapter) {
    Write-Error "Aucune interface reseau active trouvee."
    exit 1
}

$ifName = $adapter.InterfaceAlias
Write-Host "Interface detectee : $ifName" -ForegroundColor Cyan

# ── 2. Sauvegarder les reglages actuels
Write-Host "Sauvegarde des reglages actuels..." -ForegroundColor Yellow

$tcpOutput = netsh int tcp show global

function Get-NetshValue($lines, $key) {
    $line = $lines | Where-Object { $_ -match $key }
    if ($line) { return ($line -split ":")[1].Trim() }
    return "unknown"
}

$autoTuning  = Get-NetshValue $tcpOutput "Auto-Tuning Level"
$rss         = Get-NetshValue $tcpOutput "Receive-Side Scaling"
$rsc         = Get-NetshValue $tcpOutput "Receive Segment Coalescing"
$timestamps  = Get-NetshValue $tcpOutput "Timestamps"
$ecn         = Get-NetshValue $tcpOutput "ECN Capability"

# MTU actuel
$mtuLine = netsh interface ipv4 show subinterfaces | Where-Object { $_ -match [regex]::Escape($ifName) }
$mtuValue = if ($mtuLine) { ($mtuLine.Trim() -split "\s+")[0] } else { "1500" }

# DNS actuels
$dnsAddresses = (Get-DnsClientServerAddress -InterfaceAlias $ifName -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

# Nagle algorithm (registre, par interface)
$ifGuid     = $adapter.InterfaceGuid
$nagleKey   = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$ifGuid"
$nagleProp1 = (Get-ItemProperty -Path $nagleKey -Name TcpAckFrequency -ErrorAction SilentlyContinue).TcpAckFrequency
$nagleProp2 = (Get-ItemProperty -Path $nagleKey -Name TCPNoDelay      -ErrorAction SilentlyContinue).TCPNoDelay

# QoS — limite bande passante réservable (défaut Windows = 20%)
$qosKey    = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
$qosExists = Test-Path $qosKey
$qosLimit  = if ($qosExists) { (Get-ItemProperty -Path $qosKey -Name NonBestEffortLimit -ErrorAction SilentlyContinue).NonBestEffortLimit } else { $null }

$backup = [ordered]@{
    Interface        = $ifName
    InterfaceGuid    = $ifGuid
    AutoTuning       = $autoTuning
    RSS              = $rss
    RSC              = $rsc
    Timestamps       = $timestamps
    ECN              = $ecn
    MTU              = $mtuValue
    DNS              = $dnsAddresses
    NagleAckFreq     = $nagleProp1
    NagleNoDelay     = $nagleProp2
    QoSKeyExisted    = $qosExists
    QoSLimit         = $qosLimit
}

$backup | ConvertTo-Json | Set-Content -Encoding UTF8 $backupFile
Write-Host "Backup sauvegarde : $backupFile" -ForegroundColor Green

# ── 3. Reglages TCP globaux
Write-Host ""
Write-Host "Application des reglages TCP..." -ForegroundColor Yellow

netsh int tcp set global autotuninglevel=normal   | Out-Null
netsh int tcp set global rss=enabled              | Out-Null
netsh int tcp set global rsc=disabled             | Out-Null
netsh int tcp set global timestamps=disabled      | Out-Null
netsh int tcp set global ecncapability=enabled    | Out-Null

Write-Host "  AutoTuning  = normal"
Write-Host "  RSS         = enabled"
Write-Host "  RSC         = disabled"
Write-Host "  Timestamps  = disabled"
Write-Host "  ECN         = enabled"

# ── 4. Recherche du MTU optimal ──────────────────────────────
Write-Host ""
Write-Host "Recherche du MTU optimal (test ping DF-bit)..." -ForegroundColor Yellow

$testMtu = 1472
$found   = $false

while ($testMtu -ge 1400) {
    $result = ping 8.8.8.8 -f -l $testMtu -n 2 2>&1 | Out-String
    if ($result -notmatch "fragment") {
        $found = $true
        break
    }
    $testMtu -= 8
}

if ($found) {
    $optimalMtu = $testMtu + 28
    Write-Host "  Taille test OK : $testMtu -> MTU = $optimalMtu" -ForegroundColor Green
    netsh interface ipv4 set subinterface "$ifName" mtu=$optimalMtu store=persistent | Out-Null
    Write-Host "  MTU applique : $optimalMtu"
} else {
    Write-Host "  Impossible de determiner le MTU optimal, valeur inchangee." -ForegroundColor DarkYellow
}

# ── 5. DNS Cloudflare ────────────────────────────────────────
Write-Host ""
Write-Host "Application des DNS Cloudflare..." -ForegroundColor Yellow

netsh interface ip set dns name="$ifName" static 1.1.1.1  | Out-Null
netsh interface ip add dns name="$ifName" 1.0.0.1 index=2 | Out-Null

Write-Host "  DNS primaire   : 1.1.1.1"
Write-Host "  DNS secondaire : 1.0.0.1"

# ── 6. Desactiver l'algorithme de Nagle
Write-Host ""
Write-Host "Desactivation de l'algorithme de Nagle..." -ForegroundColor Yellow

$nagleKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
if (-not (Test-Path $nagleKey)) {
    New-Item -Path $nagleKey -Force | Out-Null
}
Set-ItemProperty -Path $nagleKey -Name TcpAckFrequency -Value 1 -Type DWord
Set-ItemProperty -Path $nagleKey -Name TCPNoDelay      -Value 1 -Type DWord

Write-Host "  TcpAckFrequency = 1 (ACK immediat)"
Write-Host "  TCPNoDelay      = 1 (Nagle desactive)"

# ── 7. QoS — supprimer la limite des 20% ───────────────────────
Write-Host ""
Write-Host "Suppression de la limite QoS (20%)..." -ForegroundColor Yellow

$qosKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
if (-not (Test-Path $qosKey)) {
    New-Item -Path $qosKey -Force | Out-Null
}
Set-ItemProperty -Path $qosKey -Name NonBestEffortLimit -Value 0 -Type DWord

Write-Host "  NonBestEffortLimit = 0 (100% bande passante disponible)"

# ── Résumé ───────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " Optimisation terminée !" -ForegroundColor Green
Write-Host " Pour annuler tous les changements :"
Write-Host "   .\Restore-NetworkOptim.ps1"
Write-Host "==========================================" -ForegroundColor Green
