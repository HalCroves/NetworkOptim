#Requires -RunAsAdministrator
# ============================================================
#  WireGuard Client Setup — Windows (CS2 Gaming)
#  Tunnel : CS2-WG  |  Client : 10.66.66.2  |  Serveur : 10.66.66.1
#  Lance en administrateur : .\WG-Client-Setup.ps1
# ============================================================

# ── Recherche de wg.exe (genere les cles) ────────────────────
$wgExe_   = 'C:\Program Files\WireGuard\wireguard.exe'
$wgTool_  = 'C:\Program Files\WireGuard\wg.exe'

# ── 1. Installation WireGuard si absent ──────────────────────
if (-not (Test-Path $wgExe_)) {
    Write-Host "WireGuard non detecte — installation..." -ForegroundColor Yellow
    $installed_ = $false

    # Tentative winget
    if (Get-Command winget -EA SilentlyContinue) {
        winget install --id WireGuard.WireGuard -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        if (Test-Path $wgExe_) { $installed_ = $true; Write-Host "  WireGuard installe (winget)." -ForegroundColor Green }
    }

    # Fallback : telechargement direct
    if (-not $installed_) {
        $dlPath_ = "$env:TEMP\wireguard-installer.exe"
        Write-Host "  Telechargement depuis wireguard.com..." -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "https://download.wireguard.com/windows-client/wireguard-installer.exe" -OutFile $dlPath_ -UseBasicParsing
        Start-Process $dlPath_ -Wait -ArgumentList '/S'
        Remove-Item $dlPath_ -EA SilentlyContinue
        if (Test-Path $wgExe_) { Write-Host "  WireGuard installe (direct)." -ForegroundColor Green }
        else { Write-Error "Installation echouee. Installe manuellement : https://www.wireguard.com/install/"; exit 1 }
    }
    Start-Sleep 3
}

Write-Host "WireGuard : OK ($wgExe_)" -ForegroundColor Green

# ── 2. Generation des cles client ────────────────────────────
Write-Host ""
Write-Host "Generation des cles client..." -ForegroundColor Cyan

$clientPriv_ = & $wgTool_ genkey
if (-not $clientPriv_) { Write-Error "Echec generation cle privee (wg.exe introuvable ?)"; exit 1 }
$clientPub_  = $clientPriv_ | & $wgTool_ pubkey

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  CLE PUBLIQUE CLIENT — copie sur le VPS Ionos          ║" -ForegroundColor Green
Write-Host "╠════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "  $clientPub_" -ForegroundColor White
Write-Host "╚════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  -> Sur le VPS : bash wg-add-peer.sh $clientPub_" -ForegroundColor DarkYellow
Write-Host ""

# ── 3. Infos VPS ─────────────────────────────────────────────
$serverIp_  = Read-Host "IP publique du VPS Ionos (ex: 185.201.x.x)"
$serverPub_ = Read-Host "Cle publique SERVEUR — affichee par wg-server-setup.sh (commence par ex: Fdya9...)"

# Valider que les champs ne sont pas vides
if (-not $serverIp_ -or -not $serverPub_) {
    Write-Error "IP ou cle serveur manquante. Abandonne."
    exit 1
}
# Detecter si l'utilisateur a entre sa propre cle client au lieu de la cle serveur
if ($serverPub_ -eq $clientPub_) {
    Write-Host ""
    Write-Host "  ERREUR : tu as entre ta propre cle CLIENT comme cle serveur !" -ForegroundColor Red
    Write-Host "  La cle SERVEUR est affichee sur le VPS par wg-server-setup.sh." -ForegroundColor Red
    Write-Host "  Ta cle client : $clientPub_" -ForegroundColor DarkGray
    Write-Host ""
    $serverPub_ = Read-Host "Re-entre la cle publique SERVEUR (celle du VPS)"
    if ($serverPub_ -eq $clientPub_) { Write-Error "Toujours la meme cle. Abandonne."; exit 1 }
}

$endpoint_ = "${serverIp_}:51820"

# ── 4. Creation du fichier tunnel ────────────────────────────
$tunnelName_ = "CS2-WG"
# ProgramData : accessible au compte SYSTEM qui execute le service WireGuard
$confDir_    = "$env:ProgramData\WireGuard"
New-Item -Path $confDir_ -ItemType Directory -Force | Out-Null
$confPath_ = "$confDir_\$tunnelName_.conf"

@"
[Interface]
PrivateKey = $clientPriv_
Address = 10.66.66.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $serverPub_
Endpoint = $endpoint_
# Split tunnel : seul le trafic Valve/Steam/CS2 passe par le VPS.
# Si WireGuard tombe, internet 4G reste intact.
# Ranges Valve (SDR relays + game servers EU/US) + sous-reseau WireGuard
AllowedIPs = 10.66.66.0/24, 155.133.224.0/19, 155.133.248.0/21, 185.25.182.0/23, 192.69.96.0/22, 208.64.200.0/22, 205.196.6.0/24, 209.197.3.0/24
PersistentKeepalive = 25
"@  | Out-File -FilePath `$confPath_ -Encoding utf8 -Force

Write-Host "Fichier tunnel cree : $confPath_" -ForegroundColor DarkGray

# ── 5. Import et demarrage du tunnel ─────────────────────────
Write-Host ""
Write-Host "Import du tunnel '$tunnelName_' dans WireGuard..." -ForegroundColor Cyan

# Supprimer l'ancien tunnel du meme nom s'il existe
$svcName_ = "WireGuardTunnel`$$tunnelName_"
if (Get-Service $svcName_ -EA SilentlyContinue) {
    Write-Host "  Suppression de l'ancien tunnel '$tunnelName_'..." -ForegroundColor DarkYellow
    & $wgExe_ /uninstalltunnelservice $tunnelName_ 2>&1 | Out-Null
    Start-Sleep 2
}

# Installer le tunnel comme service Windows
& $wgExe_ /installtunnelservice $confPath_
Start-Sleep 3

# Verifier etat
$svc_ = Get-Service $svcName_ -EA SilentlyContinue
if ($svc_ -and $svc_.Status -eq 'Running') {
    Write-Host "  Service '$svcName_' : RUNNING" -ForegroundColor Green
} else {
    Write-Host "  Service '$svcName_' : $($svc_.Status)" -ForegroundColor DarkYellow
    Write-Host "  Si le tunnel ne demarre pas, verifie que wg-add-peer.sh a ete execute sur le VPS." -ForegroundColor DarkYellow
}

# La conf reste dans ProgramData — necessaire pour que le service redemarre apres reboot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SETUP COMPLET" -ForegroundColor Cyan
Write-Host "============================================================"
Write-Host ""
Write-Host "  Prochaines etapes :" -ForegroundColor White
Write-Host "  1. Sur le VPS Ionos, ajoute ce client :" -ForegroundColor DarkGray
Write-Host "       bash wg-add-peer.sh $clientPub_" -ForegroundColor Yellow
Write-Host "  2. Demarre/relance le tunnel dans l'app WireGuard" -ForegroundColor DarkGray
Write-Host "     ou : sc.exe start `"$svcName_`"" -ForegroundColor DarkGray
Write-Host "  3. Teste la connexion : ping 10.66.66.1" -ForegroundColor DarkGray
Write-Host "  4. Lance CS2 via CS2-Launcher.ps1 — WireGuard sera detecte automatiquement" -ForegroundColor DarkGray
Write-Host ""

# Test ping rapide vers le VPS
Write-Host "Ping vers 10.66.66.1 (serveur WireGuard)..." -ForegroundColor Cyan
$p_ = Test-Connection 10.66.66.1 -Count 3 -EA SilentlyContinue
if ($p_) {
    $latProp_ = 'ResponseTime'
    if (-not ($p_[0].PSObject.Properties[$latProp_])) { $latProp_ = 'Latency' }
    $avgPing_ = [Math]::Round(($p_ | Measure-Object -Property $latProp_ -Average).Average)
    Write-Host "  -> Latence vers VPS Paris : ${avgPing_} ms" -ForegroundColor Green
} else {
    Write-Host "  -> Pas de reponse (tunnel pas encore demarre ou peer pas encore ajoute sur VPS)" -ForegroundColor DarkYellow
}
