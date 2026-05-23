# ================================================================
#  diag-tunnel.ps1  —  Diagnostic packet loss et latence tunnel
# ================================================================
Write-Host "=== Diagnostic WireGuard tunnel ===" -ForegroundColor Cyan

# 1. VPS : 50 pings, mesure packet loss et jitter
Write-Host "`n[1] Packet loss VPS (10.66.66.1) sur 50 pings..." -ForegroundColor Yellow
$rawVPS = ping.exe -n 50 10.66.66.1
$lossLineVPS = $rawVPS | Where-Object { $_ -match 'perte|Lost|lost' }
$statsVPS    = $rawVPS | Where-Object { $_ -match 'Minimum|Min|min' }
Write-Host "  $lossLineVPS"
Write-Host "  $statsVPS"

# 2. EU Valve IP via tunnel : 30 pings
Write-Host "`n[2] Packet loss EU Valve (185.25.182.1) via tunnel..." -ForegroundColor Yellow
$rawEU = ping.exe -n 30 185.25.182.1
$lossEU  = $rawEU | Where-Object { $_ -match 'perte|Lost|lost' }
$statsEU = $rawEU | Where-Object { $_ -match 'Minimum|Min|min' }
Write-Host "  $lossEU"
Write-Host "  $statsEU"

# 3. Route utilisee pour EU Valve
Write-Host "`n[3] Route utilisee pour 185.25.182.1..." -ForegroundColor Yellow
Find-NetRoute -RemoteIPAddress 185.25.182.1 | Select-Object InterfaceAlias, NextHop | Format-Table -AutoSize

# 4. MTU actuel
Write-Host "[4] MTU CS2-WG :" -ForegroundColor Yellow
(Get-NetIPInterface -InterfaceAlias "CS2-WG" -AddressFamily IPv4 -EA SilentlyContinue).NlMtu

# 5. Resultat
Write-Host "`n=== Interpretation ===" -ForegroundColor Cyan
Write-Host "Si VPS loss > 5%  → Bouygues filtre UDP 51820 → fix : changer port WireGuard" -ForegroundColor White
Write-Host "Si VPS loss = 0%  → le probleme vient du routage VPS→Valve             " -ForegroundColor White
Write-Host "Si route EU != CS2-WG → tunnel non actif, les IPs ne passent pas dedans" -ForegroundColor White
