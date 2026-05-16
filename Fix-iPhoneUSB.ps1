# Auto-elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ============================================================
#  Fix-iPhoneUSB.ps1
#  Empeche Windows de couper la connexion USB de l'iPhone
#  (ou de n'importe quel autre peripherique USB)
#
#  Ce que ca fait :
#   1. Desactive USB Selective Suspend (secteur + batterie)
#      -> Windows ne met plus les ports USB en veille apres inactivite
#   2. Desactive EnhancedPowerManagement sur les Hub USB racine
#      -> Windows ne coupe plus l'alimentation des hubs USB
# ============================================================

Write-Host ""
Write-Host "== Fix deconnexion iPhone / USB ==" -ForegroundColor Cyan
Write-Host ""

# ── 1. USB Selective Suspend -> desactive (secteur ET batterie)
$sub  = "2a737441-1930-4402-8d77-b2bebba308a3"
$guid = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"

powercfg /setacvalueindex SCHEME_CURRENT $sub $guid 0
powercfg /setdcvalueindex SCHEME_CURRENT $sub $guid 0
powercfg /setactive SCHEME_CURRENT

# Verification
$check = powercfg /query SCHEME_CURRENT $sub $guid | Select-String "courant alternatif"
if ($check -match "0x00000000") {
    Write-Host "  [OK] USB Selective Suspend desactive (secteur + batterie)" -ForegroundColor Green
} else {
    Write-Host "  [WARN] USB Selective Suspend : verifier manuellement" -ForegroundColor Yellow
}

# ── 2. EnhancedPowerManagement desactive sur tous les Hub USB racine
Write-Host ""
$hubs = Get-PnpDevice -Class USB -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match "Hub USB racine|USB Root Hub" }

if ($hubs.Count -eq 0) {
    Write-Host "  [WARN] Aucun Hub USB racine trouve" -ForegroundColor Yellow
} else {
    foreach ($hub in $hubs) {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($hub.InstanceId)\Device Parameters"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name "EnhancedPowerManagementEnabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Write-Host "  [OK] $($hub.FriendlyName) -> power management desactive" -ForegroundColor Green
        } else {
            Write-Host "  [SKIP] $($hub.FriendlyName) -> clef registre absente" -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "Termine. Debranche et rebranche l'iPhone." -ForegroundColor Cyan
Write-Host ""
Write-Host "Si ca deconnecte encore :" -ForegroundColor Yellow
Write-Host "  -> Gestionnaire de peripheriques -> appareil Apple -> Proprietes"
Write-Host "     -> onglet Gestion alimentation -> decocher 'Autoriser l'ordinateur a eteindre...'"
Write-Host ""
Read-Host "Appuie sur Entree pour fermer"
