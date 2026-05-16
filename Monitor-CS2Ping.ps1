# Auto-elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ============================================================
#  Monitor-CS2Ping.ps1 v2
#  - Ping gateway (Wi-Fi local) ET cible externe (4G -> internet)
#  - Jitter (ecart entre 2 pings consecutifs)
#  - Packet loss explicite (timeout = 9999ms, % en resume)
#  - Signal Wi-Fi sur chaque spike (netsh wlan)
#  - Bande passante Wi-Fi consommee sur chaque spike
#  - Duree du spike (pings consecutifs au-dessus du seuil)
#  - Moyenne glissante 10 pings affichee en temps reel
#  - CPU instantane (double snapshot 500ms)
#  - Arret automatique quand CS2 se ferme (ou Ctrl+C)
# ============================================================

$gateway     = "172.20.10.1"   # trajet Wi-Fi local -> iPhone
$externe     = "1.1.1.1"       # trajet 4G -> internet (Cloudflare)
$seuilMs     = 80              # seuil en ms au-dela duquel on log un pic
$intervalleS = 1               # secondes entre chaque ping
$logFile     = "$PSScriptRoot\ping-monitor-$(Get-Date -Format 'yyyy-MM-dd_HH-mm').txt"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Monitor CS2 v2 - Surveillance ping       " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Gateway  : $gateway (Wi-Fi local)"
Write-Host "  Externe  : $externe (4G internet)"
Write-Host "  Seuil    : ${seuilMs}ms  (pic logge au-dela)"
Write-Host "  Log      : $logFile"
Write-Host "  Arret    : ferme CS2 ou Ctrl+C"
Write-Host ""

# Attendre que CS2 soit lance
Write-Host "En attente de CS2..." -ForegroundColor DarkGray
while (-not (Get-Process -Name "cs2" -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 3
}
Write-Host "CS2 detecte - surveillance active !`n" -ForegroundColor Green

"=== Monitor CS2 Ping v2 - $(Get-Date) ===" | Out-File -Encoding UTF8 $logFile
"Gateway : $gateway | Externe : $externe | Seuil : ${seuilMs}ms | Intervalle : ${intervalleS}s" | Out-File -Encoding UTF8 $logFile -Append
"" | Out-File -Encoding UTF8 $logFile -Append

$totalPings  = 0
$totalSpikes = 0
$totalLossGw  = 0
$totalLossExt = 0
$maxGw       = 0
$maxExt      = 0
$prevGw      = $null
$prevExt     = $null
$jitterGwList  = [System.Collections.Generic.List[double]]::new()
$jitterExtList = [System.Collections.Generic.List[double]]::new()
$slidingGw     = [System.Collections.Generic.Queue[int]]::new()
$slidingExt    = [System.Collections.Generic.Queue[int]]::new()
$slidingSize   = 10
$spikeStreak   = 0   # pings consecutifs en spike (duree)

# Nom de l'adaptateur Wi-Fi (premier actif)
$wifiAdapter = (Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.PhysicalMediaType -match "802.11|Native 802.11" } | Select-Object -First 1).Name
if (-not $wifiAdapter) {
    $wifiAdapter = (Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1).Name
}

# Snapshot bande passante
function Get-BandwidthSnap {
    param([string]$adapterName)
    $s = Get-NetAdapterStatistics -Name $adapterName -ErrorAction SilentlyContinue
    if ($s) { return [PSCustomObject]@{ Rx = $s.ReceivedBytes; Tx = $s.SentBytes; Time = [datetime]::Now } }
    return $null
}

# Signal Wi-Fi
function Get-WifiSignal {
    $raw = netsh wlan show interfaces 2>$null | Select-String "Signal"
    if ($raw) { return ($raw -replace '.*:\s*', '').Trim() }
    return "N/A"
}

# Fonction CPU instantane : deux snapshots a 500ms d'ecart
function Get-InstantCPU {
    $snap1 = Get-Process | Where-Object { $_.Name -notmatch '^(Idle|System|cs2)$' } |
             Select-Object Name, Id, CPU, WorkingSet
    Start-Sleep -Milliseconds 500
    $snap2 = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(Idle|System|cs2)$' } |
             Select-Object Name, Id, CPU, WorkingSet

    $snap2 | ForEach-Object {
        $p2 = $_
        $p1 = $snap1 | Where-Object { $_.Id -eq $p2.Id } | Select-Object -First 1
        if ($p1 -and $p2.CPU -and $p1.CPU) {
            [PSCustomObject]@{
                Name   = $p2.Name
                CPUPct = [math]::Round(($p2.CPU - $p1.CPU) / 0.5 * 100, 1)
                RAM_MB = [math]::Round($p2.WorkingSet / 1MB, 1)
            }
        }
    } | Where-Object { $_.CPUPct -gt 1 } | Sort-Object CPUPct -Descending | Select-Object -First 8
}

$bwSnap = Get-BandwidthSnap -adapterName $wifiAdapter

while (Get-Process -Name "cs2" -ErrorAction SilentlyContinue) {

    $pingGw  = Test-Connection -ComputerName $gateway -Count 1 -ErrorAction SilentlyContinue
    $pingExt = Test-Connection -ComputerName $externe -Count 1 -ErrorAction SilentlyContinue
    $msGw    = if ($pingGw)  { [int]$pingGw.ResponseTime  } else { 9999 }
    $msExt   = if ($pingExt) { [int]$pingExt.ResponseTime } else { 9999 }
    $time    = Get-Date -Format "HH:mm:ss"
    $totalPings++

    # Packet loss
    if ($msGw  -eq 9999) { $totalLossGw++ }
    if ($msExt -eq 9999) { $totalLossExt++ }

    # Max
    if ($msGw  -ne 9999 -and $msGw  -gt $maxGw)  { $maxGw  = $msGw  }
    if ($msExt -ne 9999 -and $msExt -gt $maxExt) { $maxExt = $msExt }

    # Jitter (ecart avec ping precedent)
    $jGw  = if ($null -ne $prevGw  -and $msGw  -ne 9999 -and $prevGw  -ne 9999) { [math]::Abs($msGw  - $prevGw)  } else { $null }
    $jExt = if ($null -ne $prevExt -and $msExt -ne 9999 -and $prevExt -ne 9999) { [math]::Abs($msExt - $prevExt) } else { $null }
    if ($null -ne $jGw)  { [void]$jitterGwList.Add($jGw)  }
    if ($null -ne $jExt) { [void]$jitterExtList.Add($jExt) }
    $prevGw  = $msGw
    $prevExt = $msExt

    # Moyenne glissante 10 pings
    if ($msGw  -ne 9999) { $slidingGw.Enqueue($msGw)   ; if ($slidingGw.Count  -gt $slidingSize) { [void]$slidingGw.Dequeue()  } }
    if ($msExt -ne 9999) { $slidingExt.Enqueue($msExt) ; if ($slidingExt.Count -gt $slidingSize) { [void]$slidingExt.Dequeue() } }
    $avgGw  = if ($slidingGw.Count  -gt 0) { [math]::Round(($slidingGw  | Measure-Object -Average).Average, 0) } else { "?" }
    $avgExt = if ($slidingExt.Count -gt 0) { [math]::Round(($slidingExt | Measure-Object -Average).Average, 0) } else { "?" }

    $isSpike = ($msGw -ge $seuilMs) -or ($msExt -ge $seuilMs)

    if ($isSpike) {
        $totalSpikes++
        $spikeStreak++

        $tag   = if ($msGw -ge $seuilMs -and $msExt -ge $seuilMs) { "GW+4G" }
                 elseif ($msGw -ge $seuilMs) { "GW" }
                 else { "4G" }
        $color = if (($msGw + $msExt) -gt 200) { "Red" } elseif (($msGw + $msExt) -gt 100) { "Yellow" } else { "DarkYellow" }

        # Signal Wi-Fi au moment du spike
        $signal = Get-WifiSignal

        # Bande passante consommee depuis dernier snapshot
        $bwSnap2 = Get-BandwidthSnap -adapterName $wifiAdapter
        $bwText  = "N/A"
        if ($bwSnap -and $bwSnap2) {
            $dt = ($bwSnap2.Time - $bwSnap.Time).TotalSeconds
            if ($dt -gt 0) {
                $rxKb   = [math]::Round(($bwSnap2.Rx - $bwSnap.Rx) / $dt / 1KB, 1)
                $txKb   = [math]::Round(($bwSnap2.Tx - $bwSnap.Tx) / $dt / 1KB, 1)
                $bwText = "RX:${rxKb}KB/s TX:${txKb}KB/s"
            }
        }
        $bwSnap = $bwSnap2

        # Duree spike
        $dureeText = if ($spikeStreak -gt 1) { " [DURE:${spikeStreak}s]" } else { "" }

        # Jitter
        $jitterText = ""
        if ($null -ne $jGw)  { $jitterText += " JGW:${jGw}ms" }
        if ($null -ne $jExt) { $jitterText += " JEXT:${jExt}ms" }

        $consoleLine = "[$time] SPIKE [$tag]  GW:${msGw}ms  4G:${msExt}ms  Moy10:GW${avgGw}/4G${avgExt}ms${jitterText}  Signal:${signal}  BW:${bwText}${dureeText}"
        Write-Host $consoleLine -ForegroundColor $color

        # CPU instantane au moment du spike
        $topProcs = Get-InstantCPU

        # Log complet
        $consoleLine | Out-File -Encoding UTF8 $logFile -Append
        $topProcs | ForEach-Object {
            "  CPU:$($_.CPUPct)%  RAM:$($_.RAM_MB)MB  -> $($_.Name)" | Out-File -Encoding UTF8 $logFile -Append
        }
        "" | Out-File -Encoding UTF8 $logFile -Append

        # Console CPU
        $topProcs | Select-Object -First 5 | ForEach-Object {
            Write-Host "         CPU:$($_.CPUPct)%  RAM:$($_.RAM_MB)MB  $($_.Name)" -ForegroundColor DarkGray
        }

    } else {
        $spikeStreak = 0
        $bwSnap = Get-BandwidthSnap -adapterName $wifiAdapter  # reset snapshot hors spike
        $jitterText = ""
        if ($null -ne $jGw)  { $jitterText += "  JGW:${jGw}ms" }
        if ($null -ne $jExt) { $jitterText += "  JEXT:${jExt}ms" }
        Write-Host "[$time] GW:${msGw}ms  4G:${msExt}ms  Moy10:GW${avgGw}/4G${avgExt}ms${jitterText}" -ForegroundColor DarkGreen
    }

    Start-Sleep -Seconds $intervalleS
}

# Resume final
$avgJGw     = if ($jitterGwList.Count  -gt 0) { [math]::Round(($jitterGwList  | Measure-Object -Average).Average, 1) } else { "N/A" }
$avgJExt    = if ($jitterExtList.Count -gt 0) { [math]::Round(($jitterExtList | Measure-Object -Average).Average, 1) } else { "N/A" }
$pctLossGw  = if ($totalPings -gt 0) { [math]::Round($totalLossGw  / $totalPings * 100, 1) } else { 0 }
$pctLossExt = if ($totalPings -gt 0) { [math]::Round($totalLossExt / $totalPings * 100, 1) } else { 0 }

$resume = @"

=== RESUME SESSION ===
Duree             : $totalPings pings ($($totalPings * $intervalleS)s de surveillance)
Pics detectes     : $totalSpikes (>= ${seuilMs}ms)
Ping max GW       : ${maxGw}ms  (Wi-Fi local)
Ping max 4G       : ${maxExt}ms (internet)
Jitter moyen GW   : ${avgJGw}ms
Jitter moyen 4G   : ${avgJExt}ms
Packet loss GW    : $totalLossGw timeouts ($pctLossGw%)
Packet loss 4G    : $totalLossExt timeouts ($pctLossExt%)
Log complet       : $logFile
"@

Write-Host $resume -ForegroundColor Cyan
$resume | Out-File -Encoding UTF8 $logFile -Append

Write-Host "CS2 ferme. Surveillance terminee." -ForegroundColor Yellow
Read-Host "Appuie sur Entree pour fermer"
