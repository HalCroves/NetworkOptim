# Auto-elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ============================================================
#  Clean-GhostDevices.ps1
#  Supprime les peripheriques fantomes du Gestionnaire de
#  peripheriques (Status = Unknown = materiel debranche/desinstalle)
#
#  Fonctionne sur n'importe quel PC Windows 7/10/11
#  Necessite les droits administrateur
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Nettoyage des peripheriques fantomes  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Classes a ignorer : infrastructure Windows, pas du vrai materiel
$classesAIgnorer = @(
    'SoftwareDevice',   # periph virtuels Windows
    'System',           # composants systeme
    'VolumeSnapshot',   # cliches VSS
    'AudioEndpoint',    # endpoints audio virtuels
    'SecurityDevices'   # TPM
)

# Prefixes d'InstanceId a ignorer : creees par Windows, pas du materiel physique
$prefixesAIgnorer = '^SWD\\|^ROOT\\|RZVIRT'

$ghosts = Get-PnpDevice | Where-Object {
    $_.Status -eq 'Unknown' -and
    $_.Class -notin $classesAIgnorer -and
    $_.InstanceId -notmatch $prefixesAIgnorer
}

if ($ghosts.Count -eq 0) {
    Write-Host "Aucun peripherique fantome trouve. Le gestionnaire est propre !" -ForegroundColor Green
    Read-Host "`nAppuie sur Entree pour fermer"
    exit 0
}

Write-Host "$($ghosts.Count) peripherique(s) fantome(s) trouve(s) :" -ForegroundColor Yellow
Write-Host ""
$ghosts | Select-Object Class, FriendlyName | Format-Table -AutoSize
Write-Host ""
Write-Host "Ces peripheriques sont grisés dans le Gestionnaire de peripheriques." -ForegroundColor DarkGray
Write-Host "Ils correspondent a du materiel déconnecté ou desinstallé." -ForegroundColor DarkGray
Write-Host "Ils seront recrees automatiquement si le materiel est reconnecte." -ForegroundColor DarkGray
Write-Host ""

$confirm = Read-Host "Supprimer ces peripheriques ? (O/N)"

if ($confirm -ne 'O' -and $confirm -ne 'o') {
    Write-Host "Annule." -ForegroundColor DarkYellow
    Read-Host "`nAppuie sur Entree pour fermer"
    exit 0
}

Write-Host ""
$supprimes = 0
$ignores   = 0

foreach ($device in $ghosts) {
    $id     = $device.InstanceId
    $result = pnputil /remove-device "$id" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK]     $($device.FriendlyName)" -ForegroundColor Green
        $supprimes++
    } else {
        Write-Host "  [IGNORE] $($device.FriendlyName)" -ForegroundColor DarkYellow
        $ignores++
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Termine : $supprimes supprimes, $ignores ignores" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Read-Host "Appuie sur Entree pour fermer"
