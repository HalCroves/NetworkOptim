$sRoot = $null
foreach ($rp in @("HKCU:\Software\Valve\Steam","HKLM:\SOFTWARE\WOW6432Node\Valve\Steam")) {
    $reg = Get-ItemProperty $rp -EA SilentlyContinue
    $v = if ($reg.InstallPath) { $reg.InstallPath } elseif ($reg.SteamPath) { $reg.SteamPath } else { $null }
    if ($v -and (Test-Path $v)) { $sRoot = $v; break }
}
Write-Host "sRoot brut : $sRoot"
if ($sRoot) {
    try { $sRoot = [System.IO.Path]::GetFullPath($sRoot.Replace('/', '\')) } catch {}
    try { $sRoot = (Resolve-Path $sRoot -EA SilentlyContinue).Path } catch {}
    Write-Host "sRoot normalise : $sRoot"
    $libs = [System.Collections.Generic.List[string]]::new()
    if (Test-Path "$sRoot\steamapps") {
        $libs.Add("$sRoot\steamapps")
        $vdf = "$sRoot\steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object {
                $lp = $_.Groups[1].Value -replace "\\\\","\" -replace "/","\"
                try { $lp = (Resolve-Path $lp -EA SilentlyContinue).Path } catch {}
                if ($lp -and (Test-Path "$lp\steamapps") -and -not $libs.Contains("$lp\steamapps")) {
                    $libs.Add("$lp\steamapps")
                }
            }
        }
        Write-Host "Librairies ($($libs.Count)) : $($libs -join ' | ')"
        $total = 0
        foreach ($lib in $libs) {
            $n = (Get-ChildItem "$lib\appmanifest_*.acf" -EA SilentlyContinue).Count
            Write-Host "  $lib  -> $n ACF"
            $total += $n
        }
        Write-Host "Total ACF : $total"
    } else { Write-Host "steamapps introuvable sous $sRoot" }
} else { Write-Host "Steam non trouve" }
