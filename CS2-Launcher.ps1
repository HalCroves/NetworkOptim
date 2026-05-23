# ================================================================
#  CS2-Launcher.ps1  —  Interface graphique pour CS2 Optimizer v2
#  Lance CS2-HighPriority.ps1 en background et affiche ses logs
#  en temps reel avec couleurs, stats et boutons utiles.
# ================================================================

# ── Elevation ──────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Masquer la fenetre console PowerShell (ne laisser que la fenetre WinForms)
Add-Type -Name ConsoleUtils -Namespace Win32 -MemberDefinition '
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
' -ErrorAction SilentlyContinue
[Win32.ConsoleUtils]::ShowWindow([Win32.ConsoleUtils]::GetConsoleWindow(), 0) | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptDir  = $PSScriptRoot
$mainScript = Join-Path $scriptDir "CS2-HighPriority.ps1"
$jsonFile   = Join-Path $scriptDir "process-blacklist.json"
$restorePs  = Join-Path $scriptDir "Restore-NetworkOptim.ps1"

# ── Etat session ───────────────────────────────────────────────────────
$g = @{ PS = $null; RS = $null; Async = $null
         Queue = $null; Kills = 0; Cycles = 0; Iface = "-" }

# ── Logs persistants + historique ─────────────────────────────────────
$logDir      = Join-Path $scriptDir "logs"
$historyFile = Join-Path $scriptDir "sessions-history.json"
$prefsFile   = Join-Path $scriptDir "prefs.json"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:sessionLogFile = $null
$script:sessionData    = $null
# ── Lecture DB initiale ───────────────────────────────────────────────
$dbCount = 0; $dbDate = ""
if (Test-Path $jsonFile) {
    $jd = Get-Content $jsonFile -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
    if ($jd.count)       { $dbCount = $jd.count }
    if ($jd.lastUpdated) { $dbDate  = $jd.lastUpdated }
}

# ================================================================
#  SCRIPTBLOCK RUNSPACE — Write-Host surcharge -> queue live
# ================================================================
$optimBlock = {
    param($queue, $mainScript, $gameParams)

    # Surcharge Write-Host : redirige chaque appel vers la ConcurrentQueue
    # (recupere couleur exacte, pas de bufferisation)
    function Write-Host {
        param(
            [Parameter(ValueFromPipeline=$true, Position=0)]$Object,
            [System.ConsoleColor]$ForegroundColor,
            [System.ConsoleColor]$BackgroundColor,
            [switch]$NoNewline
        )
        $text = if ($null -ne $Object) { "$Object" } else { "" }
        $col  = if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
                    $ForegroundColor.ToString()
                } else { "White" }
        # Prefixe horodatage sur toutes les lignes non vides
        if ($text -ne "") {
            $ts   = [datetime]::Now.ToString("HH:mm:ss")
            $text = "[$ts] $text"
        }
        $queue.Enqueue([PSCustomObject]@{ T = $text; C = $col })
    }

    # Injecter les params du jeu selectionne (lisibles dans le script dot-source)
    if ($gameParams) {
        $GameExe      = $gameParams.Exe
        $GameName     = $gameParams.Name
        $GamePlatform = if ($gameParams.Platform) { $gameParams.Platform } else { "Steam" }
        $GamePath     = if ($gameParams.InstallPath) { $gameParams.InstallPath } else { "" }
        $LaunchUri    = if ($gameParams.LaunchUri)   { $gameParams.LaunchUri   } else { "" }
    }
    # Dot-source le script principal dans ce contexte :
    # toutes ses fonctions heritent de notre Write-Host ci-dessus
    . $mainScript
}

# ================================================================
#  DETECTION DES JEUX INSTALLES
# ================================================================
function Get-InstalledGames {
    $found   = [System.Collections.Generic.List[psobject]]::new()
    $added   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $dbg     = [System.Text.StringBuilder]::new()
    $dbgFile = "$PSScriptRoot\cs2opt_debug.txt"

    # ── Steam ── tout dans un try pour capturer ScriptStackTrace en cas d'erreur
    try {
        $sRoot = $null

        # P1 : scan tous les hives HKEY_USERS charges
        $null = $dbg.AppendLine("[P1] Scan HKEY_USERS...")
        try {
            $hkuKeys = @(Get-ChildItem "Registry::HKEY_USERS" -EA SilentlyContinue |
                Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' })
            foreach ($hkuKey in $hkuKeys) {
                if ($sRoot) { break }
                $sk  = "Registry::HKEY_USERS\$($hkuKey.PSChildName)\Software\Valve\Steam"
                $reg = Get-ItemProperty $sk -EA SilentlyContinue
                $v   = $null
                if ($reg) {
                    if ($reg.InstallPath) { $v = $reg.InstallPath }
                    elseif ($reg.SteamPath) { $v = $reg.SteamPath }
                }
                if ($v) { $v = ($v -replace '/', '\').TrimEnd('\') }
                $null = $dbg.AppendLine("  SID=$($hkuKey.PSChildName) -> $v")
                if ($v -and (Test-Path $v)) { $sRoot = $v }
            }
        } catch { $null = $dbg.AppendLine("  [ERREUR HKU] $($_.Exception.Message)") }

        # P2 : HKCU / HKLM
        if (-not $sRoot) {
            $null = $dbg.AppendLine("[P2] Fallback HKCU/HKLM...")
            foreach ($rp in @("HKCU:\Software\Valve\Steam","HKLM:\SOFTWARE\WOW6432Node\Valve\Steam","HKLM:\SOFTWARE\Valve\Steam")) {
                $reg = Get-ItemProperty $rp -EA SilentlyContinue
                $v   = $null
                if ($reg) {
                    if ($reg.InstallPath) { $v = $reg.InstallPath }
                    elseif ($reg.SteamPath) { $v = $reg.SteamPath }
                }
                if ($v) { $v = ($v -replace '/', '\').TrimEnd('\') }
                $null = $dbg.AppendLine("  $rp -> $v")
                if ($v -and (Test-Path $v)) { $sRoot = $v; break }
            }
        }
        $null = $dbg.AppendLine("[sRoot] = $sRoot")

        $sLibs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($sRoot) {
            $sLibs.Add("$sRoot\steamapps") | Out-Null
            $vdf = "$sRoot\steamapps\libraryfolders.vdf"
            $vdfExists = Test-Path $vdf
            $null = $dbg.AppendLine("[VDF] '$vdf' existe=$vdfExists")
            if ($vdfExists) {
                $vdfText = Get-Content $vdf -Raw -EA SilentlyContinue
                if ($vdfText) {
                    $vdfMatches = [regex]::Matches($vdfText, '"path"\s+"([^"]+)"')
                    $null = $dbg.AppendLine("[VDF] $($vdfMatches.Count) correspondances path")
                    foreach ($vm in $vdfMatches) {
                        $lp  = ($vm.Groups[1].Value -replace "\\\\","\" -replace "/","\").TrimEnd('\')
                        $lpe = Test-Path "$lp\steamapps"
                        $null = $dbg.AppendLine("  path=$lp steamapps=$lpe")
                        if ($lp -and $lpe) { $sLibs.Add("$lp\steamapps") | Out-Null }
                    }
                } else { $null = $dbg.AppendLine("[VDF] contenu vide") }
            }
        }

        # P3 : scan brut tous disques fixes
        $null = $dbg.AppendLine("[P3] Scan disques fixes...")
        $steamCandidates = @('Steam\steamapps','SteamLibrary\steamapps','Games\Steam\steamapps',
            'Games\SteamLibrary\steamapps','Program Files (x86)\Steam\steamapps','Program Files\Steam\steamapps')
        try {
            foreach ($di in [System.IO.DriveInfo]::GetDrives()) {
                if ($di.DriveType -ne 'Fixed' -or -not $di.IsReady) { continue }
                $dr = $di.RootDirectory.FullName
                foreach ($cand in $steamCandidates) {
                    $p = Join-Path $dr $cand
                    if (Test-Path $p) {
                        $null = $dbg.AppendLine("  Trouve: $p")
                        $sLibs.Add($p) | Out-Null
                    }
                }
            }
        } catch { $null = $dbg.AppendLine("  [ERREUR P3] $($_.Exception.Message)") }

        $libArr = [string[]]$sLibs
        $null = $dbg.AppendLine("[Libs] total=$($sLibs.Count): $([string]::Join(', ', $libArr))")

        foreach ($lib in $sLibs) {
            $acfs = @(Get-ChildItem "$lib\appmanifest_*.acf" -EA SilentlyContinue)
            $null = $dbg.AppendLine("[Lib] '$lib' -> $($acfs.Count) ACF")
            foreach ($acfFile in $acfs) {
                $acf = Get-Content $acfFile.FullName -Raw -EA SilentlyContinue
                if (-not $acf) { continue }

                $appid   = 0;    if ($acf -match '"appid"\s+"(\d+)"')        { $appid   = [int]$Matches[1] }
                $acfName = $null; if ($acf -match '"name"\s+"([^"]+)"')       { $acfName = $Matches[1] }
                $acfDir  = $null; if ($acf -match '"installdir"\s+"([^"]+)"') { $acfDir  = $Matches[1] }

                if (-not $acfName -or -not $acfDir) { continue }
                $path = "$lib\common\$acfDir"
                if (-not (Test-Path $path)) { continue }
                if ($acfName -match 'Redistributable|Steamworks Common|DirectX|PhysX|Visual C\+\+|\.NET|Steam Linux') { continue }
                if (-not $added.Add($acfName)) { continue }

                $exeF = Get-ChildItem $path -Filter "*.exe" -Depth 2 -EA SilentlyContinue |
                        Where-Object { $_.Name -notmatch "UnityCrash|CrashReport|UE4|Unins|vcredist|dxsetup|PhysX|oalinst|Setup|Install|crashpad|dxc|shadertool|DepotDownloader|SteamCmd" } |
                        Sort-Object Length -Descending | Select-Object -First 1
                $exeVal = $acfDir
                if ($exeF) { $exeVal = [IO.Path]::GetFileNameWithoutExtension($exeF.Name) }

                $found.Add([PSCustomObject]@{
                    Name=$acfName; Exe=$exeVal
                    LaunchUri="steam://rungameid/$appid"; Platform="Steam"; InstallPath=$path
                })
            }
        }
    } catch {
        $null = $dbg.AppendLine("[FATAL] $($_.Exception.GetType().Name): $($_.Exception.Message)")
        $null = $dbg.AppendLine("[STACK] $($_.ScriptStackTrace)")
    }

    $null = $dbg.AppendLine("[Steam total] $($found.Count) jeux")
    try { [System.IO.File]::WriteAllText($dbgFile, $dbg.ToString(), [System.Text.Encoding]::UTF8) } catch {}

    # ── Epic : lecture manifests JSON ──
    $epicDir = "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path $epicDir) {
        Get-ChildItem "$epicDir\*.item" -EA SilentlyContinue | ForEach-Object {
            try {
                $m = [System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json
                $d = $m.InstallLocation
                if (-not $d -or -not (Test-Path $d)) { return }
                $name = if ($m.DisplayName) { $m.DisplayName } else { $m.AppName }
                if (-not $name -or -not $added.Add($name)) { return }
                $exeF = Get-ChildItem $d -Filter "*.exe" -Depth 3 -EA SilentlyContinue |
                        Where-Object { $_.Name -notmatch "Unreal|CrashReport|UE4|Setup|Install|EpicGames|Launcher" } |
                        Sort-Object Length -Descending | Select-Object -First 1
                if ($exeF) {
                    $found.Add([PSCustomObject]@{
                        Name=$name; Exe=[IO.Path]::GetFileNameWithoutExtension($exeF.Name)
                        LaunchUri="com.epicgames.launcher://apps/$($m.AppName)?action=launch&silent=true"
                        Platform="Epic"; InstallPath=$d
                    })
                }
            } catch {}
        }
    }

    # ── Battle.net — detection dynamique via registre (aucun hardcodage) ──
    $bnetReg = "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment"
    if (Test-Path $bnetReg) {
        foreach ($bk in @(Get-ChildItem $bnetReg -EA SilentlyContinue)) {
            $ip = (Get-ItemProperty $bk.PSPath -EA SilentlyContinue).InstallPath
            if (-not $ip -or -not (Test-Path $ip)) { continue }
            $bname = $bk.PSChildName
            if (-not $added.Add($bname)) { continue }
            $bexe = Get-ChildItem $ip -Filter "*.exe" -Depth 3 -EA SilentlyContinue |
                    Where-Object { $_.Name -notmatch "Crash|Report|Setup|Install|Unins|Helper|Agent|Battle\.net|Launcher" } |
                    Sort-Object Length -Descending | Select-Object -First 1
            if (-not $bexe) { continue }
            $found.Add([PSCustomObject]@{
                Name=$bname; Exe=[IO.Path]::GetFileNameWithoutExtension($bexe.Name)
                LaunchUri=$bexe.FullName; Platform='Battle.net'; InstallPath=$ip
            })
        }
    }

    # ── Riot Games — detection entierement dynamique ──
    $riotRoot   = $null
    $riotUriMap = @{}   # protocol-name (lowercase, ex: "valorant") -> uri (ex: "valorant://")
    $riotSvcExe = $null

    # M1 : scan de TOUS les protocoles utilisateur (HKCU:\Software\Classes) en un seul passage
    # Tous les jeux Riot utilisent RiotClientServices.exe -> on mappe protocol-name -> uri
    # (le nom du protocole = le product-name du jeu, ex: "valorant", "leagueoflegends")
    foreach ($hkc in @(Get-ChildItem 'HKCU:\Software\Classes' -EA SilentlyContinue)) {
        $rcmd = (Get-ItemProperty "$($hkc.PSPath)\shell\open\command" -EA SilentlyContinue).'(default)'
        if (-not $rcmd) { continue }
        if ($rcmd -match '"([^"]+[/\\]RiotClientServices\.exe)"') {
            if (-not $riotSvcExe) { $riotSvcExe = $Matches[1] }
            if (-not $riotRoot)   { $riotRoot = Split-Path (Split-Path $Matches[1]) }
            $proto = $hkc.PSChildName.ToLower()
            if (-not $riotUriMap.ContainsKey($proto)) { $riotUriMap[$proto] = "${proto}://" }
        }
    }

    # M2 : cle Uninstall Windows (Riot Client)
    if (-not $riotRoot) {
        $riotUninstPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        foreach ($up in $riotUninstPaths) {
            if ($riotRoot) { break }
            foreach ($uk in @(Get-ChildItem $up -EA SilentlyContinue)) {
                $rp2 = Get-ItemProperty $uk.PSPath -EA SilentlyContinue
                if ($rp2.DisplayName -match '^Riot Client' -and $rp2.InstallLocation) {
                    $loc    = $rp2.InstallLocation.TrimEnd('\')
                    $parent = Split-Path $loc
                    if ($parent -and (Test-Path $parent)) { $riotRoot = $parent; break }
                }
            }
        }
    }

    if ($riotRoot) {
        foreach ($rDir in @(Get-ChildItem $riotRoot -Directory -EA SilentlyContinue)) {
            if ($rDir.Name -match 'Riot.?Client') { continue }
            $rpath = $null
            if     (Test-Path "$($rDir.FullName)\live") { $rpath = "$($rDir.FullName)\live" }
            elseif (Test-Path $rDir.FullName)           { $rpath = $rDir.FullName }
            if (-not $rpath) { continue }

            # Trouver l'URI : le nom du protocole Riot = dir-name normalise (sans espaces/tirets, lowercase)
            # ex: "VALORANT" -> "valorant", "League of Legends" -> "leagueoflegends"
            $dirKey = ($rDir.Name.ToLower() -replace '[^a-z0-9]', '')
            $ruri = ''
            if ($riotUriMap.ContainsKey($dirKey)) {
                $ruri = $riotUriMap[$dirKey]
            } else {
                # Fuzzy : protocole qui commence par ou contient le dirKey
                $fmatch = $riotUriMap.Keys | Where-Object { $_ -like "$dirKey*" -or $dirKey -like "$_*" } | Select-Object -First 1
                if ($fmatch) { $ruri = $riotUriMap[$fmatch] }
            }

            # Si toujours pas d'URI, lancer via RiotClientServices directement avec --launch-product
            if (-not $ruri -and $riotSvcExe) {
                $ruri = "`"$riotSvcExe`" --launch-product=$dirKey --launch-patchline=live"
            }

            # Trouver l'exe du jeu (depth 5 pour couvrir ShooterGame\Binaries\Win64\)
            $rexe = Get-ChildItem $rpath -Filter '*.exe' -Depth 5 -EA SilentlyContinue |
                    Where-Object { $_.Name -notmatch 'Crash|Setup|Unins|RiotClient|Launcher|vcredist|directx|UnityCrash' } |
                    Sort-Object Length -Descending | Select-Object -First 1
            $exeName = if ($rexe) { [IO.Path]::GetFileNameWithoutExtension($rexe.Name) } else { $rDir.Name }

            if (-not $added.Add($rDir.Name)) { continue }
            $found.Add([PSCustomObject]@{
                Name=$rDir.Name; Exe=$exeName
                LaunchUri=$ruri; Platform='Riot'; InstallPath=$rpath
            })
        }
    }

    # ── Jeux standalone — detection via protocole URI (enregistre par le jeu a l'installation) ──
    # Le jeu enregistre son protocole au moment de l'install -> on recupere son exe depuis le registre.
    # Pas de chemin hardcode : le protocole pointe vers l'exe reel, quel que soit le disque.
    foreach ($sproto in @('fivem', 'redm')) {
        $sval = $null
        foreach ($shive in @('Registry::HKEY_CLASSES_ROOT', 'HKCU:\Software\Classes')) {
            $skp = $null
            if ($shive -eq 'Registry::HKEY_CLASSES_ROOT') { $skp = "Registry::HKEY_CLASSES_ROOT\$sproto\shell\open\command" }
            else { $skp = "HKCU:\Software\Classes\$sproto\shell\open\command" }
            $sv = (Get-ItemProperty $skp -EA SilentlyContinue).'(default)'
            if ($sv) { $sval = $sv; break }
        }
        if (-not $sval -or -not ($sval -match '"([^"]+\.exe)"')) { continue }
        $sexe  = $Matches[1]
        $sname = [IO.Path]::GetFileNameWithoutExtension($sexe)
        if ((Test-Path $sexe) -and $added.Add($sname)) {
            $found.Add([PSCustomObject]@{
                Name=$sname; Exe=$sname
                LaunchUri=$sexe; Platform='Standalone'; InstallPath=(Split-Path $sexe)
            })
        }
    }

    # ── Ubisoft Connect ──
    $ubisoftReg = "HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs"
    if (Test-Path $ubisoftReg) {
        foreach ($uk in @(Get-ChildItem $ubisoftReg -EA SilentlyContinue)) {
            $uid = $uk.PSChildName
            $ud  = (Get-ItemProperty $uk.PSPath -EA SilentlyContinue).InstallDir
            if (-not $ud -or -not (Test-Path $ud)) { continue }
            $uexe = Get-ChildItem $ud -Filter "*.exe" -Depth 2 -EA SilentlyContinue |
                    Where-Object { $_.Name -notmatch "Unins|Setup|Crash|Uplay|UbisoftConnect|UbisoftGameLauncher" } |
                    Sort-Object Length -Descending | Select-Object -First 1
            if (-not $uexe) { continue }
            $uname = [IO.Path]::GetFileNameWithoutExtension($uexe.Name)
            if (-not $added.Add($uname)) { continue }
            $found.Add([PSCustomObject]@{
                Name=$uname; Exe=[IO.Path]::GetFileNameWithoutExtension($uexe.Name)
                LaunchUri="uplay://launch/$uid/0"; Platform="Ubisoft"; InstallPath=$ud
            })
        }
    }

    # Fallback absolu
    if ($found.Count -eq 0) {
        $found.Add([PSCustomObject]@{ Name="CS2"; Exe="cs2"; LaunchUri="steam://rungameid/730"; Platform="Steam"; InstallPath="" })
    }

    return $found
}

# ================================================================
#  FENETRE PRINCIPALE
# ================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "CS2 Optimizer"
$form.ClientSize      = New-Object System.Drawing.Size(700, 730)
$form.BackColor       = [System.Drawing.Color]::FromArgb(16, 16, 26)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false

# ── Header ─────────────────────────────────────────────────────────────
$pnlHead = New-Object System.Windows.Forms.Panel
$pnlHead.Dock      = "Top"
$pnlHead.Height    = 40
$pnlHead.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 36)
$form.Controls.Add($pnlHead)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "   CS2 OPTIMIZER  v2  —  MODE 4G"
$lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(60, 210, 230)
$lblTitle.Location  = New-Object System.Drawing.Point(0, 0)
$lblTitle.Size      = New-Object System.Drawing.Size(285, 40)
$lblTitle.TextAlign = "MiddleLeft"
$pnlHead.Controls.Add($lblTitle)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text      = "●  En attente"
$lblStatus.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 125)
$lblStatus.Location  = New-Object System.Drawing.Point(290, 0)
$lblStatus.Size      = New-Object System.Drawing.Size(180, 40)
$lblStatus.TextAlign = "MiddleLeft"
$pnlHead.Controls.Add($lblStatus)

$lblTether = New-Object System.Windows.Forms.Label
$lblTether.Text      = "USB ○"
$lblTether.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$lblTether.ForeColor = [System.Drawing.Color]::FromArgb(215, 80, 80)
$lblTether.Location  = New-Object System.Drawing.Point(472, 0)
$lblTether.Size      = New-Object System.Drawing.Size(50, 40)
$lblTether.TextAlign = "MiddleCenter"
$pnlHead.Controls.Add($lblTether)


# ── Game bar ─────────────────────────────────────────────────────
$pnlGame = New-Object System.Windows.Forms.Panel
$pnlGame.Location  = New-Object System.Drawing.Point(0, 40)
$pnlGame.Size      = New-Object System.Drawing.Size(700, 50)
$pnlGame.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 22)
$form.Controls.Add($pnlGame)

$lblGameLbl = New-Object System.Windows.Forms.Label
$lblGameLbl.Text      = "  Jeu :"
$lblGameLbl.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblGameLbl.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 110)
$lblGameLbl.Location  = New-Object System.Drawing.Point(0, 0)
$lblGameLbl.Size      = New-Object System.Drawing.Size(52, 50)
$lblGameLbl.TextAlign = "MiddleLeft"
$pnlGame.Controls.Add($lblGameLbl)

$cmbGame = New-Object System.Windows.Forms.ComboBox
$cmbGame.Location      = New-Object System.Drawing.Point(58, 13)
$cmbGame.Size          = New-Object System.Drawing.Size(452, 24)
$cmbGame.DropDownStyle = "DropDownList"
$cmbGame.BackColor     = [System.Drawing.Color]::FromArgb(28, 28, 46)
$cmbGame.ForeColor     = [System.Drawing.Color]::FromArgb(195, 195, 215)
$cmbGame.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbGame.FlatStyle     = "Flat"
$pnlGame.Controls.Add($cmbGame)

$lblPlatform = New-Object System.Windows.Forms.Label
$lblPlatform.Font      = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblPlatform.ForeColor = [System.Drawing.Color]::FromArgb(80, 160, 80)
$lblPlatform.Location  = New-Object System.Drawing.Point(520, 0)
$lblPlatform.Size      = New-Object System.Drawing.Size(172, 50)
$lblPlatform.TextAlign = "MiddleLeft"
$pnlGame.Controls.Add($lblPlatform)

# ── RichTextBox log ──────────────────────────────────────────────
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Location    = New-Object System.Drawing.Point(8, 92)
$rtb.Size        = New-Object System.Drawing.Size(503, 564)
$rtb.BackColor   = [System.Drawing.Color]::FromArgb(9, 9, 16)
$rtb.ForeColor   = [System.Drawing.Color]::FromArgb(165, 165, 185)
$rtb.Font        = New-Object System.Drawing.Font("Consolas", 8.5)
$rtb.ReadOnly    = $true
$rtb.ScrollBars  = "Vertical"
$rtb.WordWrap    = $false
$rtb.BorderStyle = "None"
$form.Controls.Add($rtb)

# ── Panel droit ───────────────────────────────────────────────────────
$pnlR = New-Object System.Windows.Forms.Panel
$pnlR.Location  = New-Object System.Drawing.Point(519, 92)
$pnlR.Size      = New-Object System.Drawing.Size(173, 632)
$pnlR.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 32)
$form.Controls.Add($pnlR)

# Helper : cree un bouton dans pnlR
function mkBtn([string]$txt, [int]$y, $bg, [bool]$bold = $false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $txt
    $b.Location  = New-Object System.Drawing.Point(8, $y)
    $b.Size      = New-Object System.Drawing.Size(157, 40)
    $b.BackColor = $bg
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(40, 40, 60)
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $fs = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $b.Font      = New-Object System.Drawing.Font("Segoe UI", 9, $fs)
    $pnlR.Controls.Add($b)
    return $b
}

$cGreen  = [System.Drawing.Color]::FromArgb(26, 128, 72)
$cRed    = [System.Drawing.Color]::FromArgb(160, 35, 35)
$cOrange = [System.Drawing.Color]::FromArgb(160, 85, 15)
$cDark   = [System.Drawing.Color]::FromArgb(38, 38, 56)
$cDarker = [System.Drawing.Color]::FromArgb(28, 28, 42)

$btnStart    = mkBtn "  Lancer le jeu"      8   $cGreen  $true
$btnStop     = mkBtn "  Arreter"           54  $cRed    $true
$btnRelaunch = mkBtn "  Relancer"         100  $cOrange $true

# Separateur
$sep1 = New-Object System.Windows.Forms.Label
$sep1.Location  = New-Object System.Drawing.Point(8, 149)
$sep1.Size      = New-Object System.Drawing.Size(157, 1)
$sep1.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 60)
$pnlR.Controls.Add($sep1)

$btnJson    = mkBtn "  Ouvrir .json"     158  $cDark   $false
$btnRestore = mkBtn "  Restaurer reseau" 204  $cDark   $false
$btnClearDB = mkBtn "  Vider blacklist"  250  $cDark   $false
$btnRefresh = mkBtn "  Rafraichir jeux"  296  $cDark   $false

$chkForceFull = $null  # Supprime - plus de tunnel

# Separateur
$sep2 = New-Object System.Windows.Forms.Label
$sep2.Location  = New-Object System.Drawing.Point(8, 375)
$sep2.Size      = New-Object System.Drawing.Size(157, 1)
$sep2.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 60)
$pnlR.Controls.Add($sep2)

$btnClearLog  = mkBtn "  Effacer logs"    383  $cDarker $false
$btnSpeedtest = mkBtn "  Speedtest"       429  $cDark   $false

$btnStop.Enabled     = $false
$btnRelaunch.Enabled = $false

# ── Remplissage ComboBox jeux ────────────────────────────────────────
$gameMap = @{}
try {
    foreach ($g_ in (Get-InstalledGames | Sort-Object Name)) {
        $key = "$($g_.Name)  [$($g_.Platform)]"
        $gameMap[$key] = $g_
        $cmbGame.Items.Add($key) | Out-Null
    }
} catch {
    # Fallback : CS2 + log de l'exception
    $fallback = [PSCustomObject]@{ Name="CS2"; Exe="cs2"; LaunchUri="steam://rungameid/730"; Platform="Steam"; InstallPath="" }
    $gameMap["CS2  [Steam]"] = $fallback
    $cmbGame.Items.Add("CS2  [Steam]") | Out-Null
    $errTxt = "[EXCEPTION Get-InstalledGames] $($_.Exception.Message)"
    try { Add-Content "$scriptDir\cs2opt_debug.txt" $errTxt -Encoding UTF8 } catch {}
}
function Update-GameSelection {
    $sel = $cmbGame.SelectedItem
    if ($sel -and $gameMap.ContainsKey($sel)) {
        $g_ = $gameMap[$sel]
        $lblPlatform.Text = "  $($g_.Platform)"
        $sn = $g_.Name
        if ($sn.Length -gt 13) { $sn = $sn.Substring(0, 13) + "..." }
        $btnStart.Text = "  Lancer $sn"
    }
}
if ($cmbGame.Items.Count -gt 0) {
    $cmbGame.SelectedIndex = 0
    Update-GameSelection
}
# Recharger la derniere selection depuis prefs
if (Test-Path $prefsFile) {
    $prefs_ = Get-Content $prefsFile -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
    if ($prefs_ -and $prefs_.lastGame) {
        $idx_ = $cmbGame.Items.IndexOf($prefs_.lastGame)
        if ($idx_ -ge 0) { $cmbGame.SelectedIndex = $idx_; Update-GameSelection }
    }
}
$cmbGame.add_SelectedIndexChanged({
    Update-GameSelection
    try { @{ lastGame = $cmbGame.SelectedItem } | ConvertTo-Json | Set-Content -Encoding UTF8 $prefsFile -EA SilentlyContinue } catch {}
})

# ── Stats label ───────────────────────────────────────────────────────
$lblStats = New-Object System.Windows.Forms.Label
$lblStats.Font      = New-Object System.Drawing.Font("Consolas", 7.5)
$lblStats.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 120)
$lblStats.Location  = New-Object System.Drawing.Point(8, 477)
$lblStats.Size      = New-Object System.Drawing.Size(157, 52)
$lblStats.Text      = "Tues      : 0`nCycles    : 0`nInterface : -"
$pnlR.Controls.Add($lblStats)

# ── DB info ───────────────────────────────────────────────────────────
$lblDB = New-Object System.Windows.Forms.Label
$lblDB.Font      = New-Object System.Drawing.Font("Consolas", 7.5)
$lblDB.ForeColor = [System.Drawing.Color]::FromArgb(65, 65, 95)
$lblDB.Location  = New-Object System.Drawing.Point(8, 598)
$lblDB.Size      = New-Object System.Drawing.Size(157, 28)
$lblDB.Text      = "DB : $dbCount entrees"
$pnlR.Controls.Add($lblDB)

# ================================================================
#  FONCTIONS LOG
# ================================================================

# Map nom ConsoleColor (string) -> Drawing.Color
$colorMap = @{
    "Green"       = [System.Drawing.Color]::FromArgb(75, 200, 115)
    "Red"         = [System.Drawing.Color]::FromArgb(215, 80, 80)
    "DarkYellow"  = [System.Drawing.Color]::FromArgb(190, 150, 45)
    "Cyan"        = [System.Drawing.Color]::FromArgb(75, 205, 215)
    "Magenta"     = [System.Drawing.Color]::FromArgb(190, 95, 190)
    "DarkRed"     = [System.Drawing.Color]::FromArgb(160, 50, 50)
    "DarkGray"    = [System.Drawing.Color]::FromArgb(115, 115, 135)
    "DarkMagenta" = [System.Drawing.Color]::FromArgb(145, 72, 145)
    "Yellow"      = [System.Drawing.Color]::FromArgb(220, 210, 70)
    "White"       = [System.Drawing.Color]::FromArgb(195, 195, 210)
    "Gray"        = [System.Drawing.Color]::FromArgb(145, 145, 160)
}
$defCol = [System.Drawing.Color]::FromArgb(155, 155, 175)

function Append-Log([string]$text, [System.Drawing.Color]$col = $defCol) {
    $rtb.SelectionStart  = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor  = $col
    $rtb.AppendText($text + "`n")
    $rtb.ScrollToCaret()
    if ($script:sessionLogFile -and $text -ne "") {
        try { Add-Content -Path $script:sessionLogFile -Value $text -Encoding UTF8 -EA SilentlyContinue } catch {}
    }
}

function Refresh-Stats {
    $lblStats.Text = "Tues      : $($g.Kills)`nCycles    : $($g.Cycles)`nInterface : $($g.Iface)"
}

function Refresh-DB {
    if (Test-Path $jsonFile) {
        $d = Get-Content $jsonFile -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
        if ($d.count -ne $null) { $lblDB.Text = "DB : $($d.count) entrees" }
    }
}

function Save-SessionHistory {
    if (-not $script:sessionData) { return }
    $d        = $script:sessionData
    $avgPing  = if ($d.pingCount -gt 0) { [math]::Round($d.pingTotal / $d.pingCount) } else { 0 }
    $duration = if ($d.startTime) {
        $span = (Get-Date) - [datetime]$d.startTime
        "{0}m {1:D2}s" -f [int]$span.TotalMinutes, $span.Seconds
    } else { "?" }
    $entry = [PSCustomObject]@{
        date     = (Get-Date -Format "yyyy-MM-dd HH:mm")
        game     = $d.game
        platform = $d.platform
        duration = $duration
        avgPing  = $avgPing
        maxPing  = $d.maxPing
        spikes   = $d.spikes
        kills    = $g.Kills
    }
    $history = @()
    if (Test-Path $historyFile) {
        $raw = Get-Content $historyFile -Raw -EA SilentlyContinue | ConvertFrom-Json -EA SilentlyContinue
        if ($raw) { $history = @($raw) }
    }
    $history += $entry
    $history | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 $historyFile
}

function Show-SessionSummary {
    if (-not $script:sessionData) { return }
    $d       = $script:sessionData
    $avgPing = if ($d.pingCount -gt 0) { [math]::Round($d.pingTotal / $d.pingCount) } else { 0 }
    $dur     = if ($d.startTime) {
        $span = (Get-Date) - [datetime]$d.startTime
        "{0}m {1:D2}s" -f [int]$span.TotalMinutes, $span.Seconds
    } else { "?" }
    Save-SessionHistory
    $colS = [System.Drawing.Color]::FromArgb(75, 205, 215)
    $colV = [System.Drawing.Color]::FromArgb(195, 195, 215)
    Append-Log "" $defCol
    Append-Log "  +------ RESUME SESSION ------------------------+" $colS
    Append-Log "  | Jeu      : $($d.game)" $colV
    Append-Log "  | Duree    : $dur" $colV
    Append-Log "  | Ping moy : ${avgPing}ms   Max : $($d.maxPing)ms" $colV
    Append-Log "  | Spikes   : $($d.spikes)" $colV
    Append-Log "  | Tues     : $($g.Kills)" $colV
    Append-Log "  +----------------------------------------------+" $colS
    $script:sessionData = $null
}

# ================================================================
#  VERIFICATIONS PRE-LANCEMENT (iPhone tethering)
# ================================================================
function Test-PreLaunch {

    # --- iPhone USB tethering ---
    $iphoneUp = Get-NetAdapter -EA SilentlyContinue |
                Where-Object { $_.InterfaceDescription -like "*Apple Mobile Device*" -and $_.Status -eq "Up" }
    if (-not $iphoneUp) {
        $res = [System.Windows.Forms.MessageBox]::Show("Tethering iPhone USB non detecte.`nVerifie le cable et 'Partage de connexion'.`n`nLancer quand meme ?", "iPhone non detecte", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    }

    return $true
}

# ================================================================
#  TIMER — polling du background job toutes les 200ms
# ================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$script:_tickCount      = 0
$script:_lastSpikeToast = [datetime]::MinValue

function Send-SpikeToast([string]$gameName) {
    if (([datetime]::Now - $script:_lastSpikeToast).TotalSeconds -lt 30) { return }
    $script:_lastSpikeToast = [datetime]::Now
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml  = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastText02'><text id='1'>SPIKE — $gameName</text><text id='2'>Spike reseau detecte</text></binding></visual></toast>")
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("CS2 Optimizer").Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {}
}

$timer.add_Tick({
    if (-not $g.Queue) { return }

    # Drainer la ConcurrentQueue : chaque item = une ligne Write-Host avec sa couleur
    $item = $null
    while ($g.Queue.TryDequeue([ref]$item)) {
        $col = if ($colorMap.ContainsKey($item.C)) { $colorMap[$item.C] } else { $defCol }
        Append-Log $item.T $col

        # Parsing stats
        $t = $item.T
        if ($t -match '\[TREE-KILL\]|\[KILL-DYN\]|\[KILL\]|\[NEW-DYN\]') { $g.Kills++ }
        if ($t -match 'cycle #(\d+)')           { $g.Cycles = [int]$Matches[1] }
        if ($t -match 'Interface\s+:\s+(\S+)')  { $g.Iface  = $Matches[1] }
        # Ping stats pour resume
        if ($t -match '\[PING\].*avg=(\d+)ms.*max=(\d+)ms' -and $script:sessionData) {
            $script:sessionData.pingTotal += [int]$Matches[1]
            $script:sessionData.pingCount++
            if ([int]$Matches[2] -gt $script:sessionData.maxPing) { $script:sessionData.maxPing = [int]$Matches[2] }
        }
        if ($t -match '\*\* SPIKE') {
            if ($script:sessionData) { $script:sessionData.spikes++ }
            $spGn_ = if ($cmbGame.SelectedItem -and $gameMap.ContainsKey($cmbGame.SelectedItem)) { $gameMap[$cmbGame.SelectedItem].Name } else { "Jeu" }
            Send-SpikeToast $spGn_
        }

        # Statut selon evenements cles
        if ($t -match 'PID \d+ -> Priorite High') {
            $gn  = if ($cmbGame.SelectedItem -and $gameMap.ContainsKey($cmbGame.SelectedItem)) { $gameMap[$cmbGame.SelectedItem].Name } else { "Jeu" }
            $lblStatus.Text      = "  $gn en cours  -  surveillance active"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(75, 200, 115)
        } elseif ($t -match 'Attente demarrage') {
            $gn  = if ($cmbGame.SelectedItem -and $gameMap.ContainsKey($cmbGame.SelectedItem)) { $gameMap[$cmbGame.SelectedItem].Name } else { "Jeu" }
            $lblStatus.Text      = "  Demarrage $gn..."
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 75)
        } elseif ($t -match '\[1/6\]') {
            $lblStatus.Text      = "  Optimisation en cours..."
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 75)
        }
    }

    Refresh-Stats

    # Indicateur tethering iPhone (toutes les 5s = 25 ticks)
    $script:_tickCount++
    if ($script:_tickCount % 25 -eq 0) {
        $iOk = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.InterfaceDescription -like '*Apple Mobile Device*' -and $_.Status -eq 'Up' }
        $lblTether.Text      = if ($iOk) { 'USB ●' } else { 'USB ○' }
        $lblTether.ForeColor = if ($iOk) { [System.Drawing.Color]::FromArgb(75, 200, 115) } else { [System.Drawing.Color]::FromArgb(215, 80, 80) }
    }
    if ($g.Async -and $g.Async.IsCompleted) {
        # Drainer les derniers items restants
        while ($g.Queue.TryDequeue([ref]$item)) {
            $col = if ($colorMap.ContainsKey($item.C)) { $colorMap[$item.C] } else { $defCol }
            Append-Log $item.T $col
        }
        try { $g.PS.EndInvoke($g.Async) } catch {}
        try { $g.RS.Close(); $g.RS.Dispose() } catch {}
        $g.PS = $null; $g.RS = $null; $g.Async = $null
        $timer.Stop()
        $btnStart.Enabled    = $true
        $btnStop.Enabled     = $false
        $btnRelaunch.Enabled = $false
        $lblStatus.Text      = "  Session terminee"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 125)
        Show-SessionSummary
        Append-Log "" $defCol
        Append-Log "-----------------------------------------------------" ([System.Drawing.Color]::FromArgb(50, 50, 75))
        Append-Log "  Session terminee. Tues : $($g.Kills)  |  Cycles : $($g.Cycles)" ([System.Drawing.Color]::FromArgb(90, 90, 115))
        Refresh-DB
    }
})

# ================================================================
#  BOUTON : Lancer CS2
# ================================================================
$btnStart.add_Click({
    if (-not (Test-Path $mainScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            "CS2-HighPriority.ps1 introuvable dans :`n$scriptDir",
            "Fichier manquant", "OK", "Error") | Out-Null
        return
    }

    if (-not (Test-PreLaunch)) { return }

    $rtb.Clear()
    $g.Kills = 0; $g.Cycles = 0; $g.Iface = "-"
    Refresh-Stats

    # Init session
    $selKeyInit  = $cmbGame.SelectedItem
    $selGameInit = if ($selKeyInit -and $gameMap.ContainsKey($selKeyInit)) { $gameMap[$selKeyInit] } else { $null }
    $script:sessionLogFile = Join-Path $logDir ("session-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".txt")
    $script:sessionData    = @{ startTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); game = if ($selGameInit) { $selGameInit.Name } else { "Inconnu" }; platform = if ($selGameInit) { $selGameInit.Platform } else { "-" }; spikes = 0; pingTotal = 0; pingCount = 0; maxPing = 0 }

    # File de logs thread-safe partagee entre Runspace (ecrit) et timer UI (lit)
    $g.Queue = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()

    # Creer et ouvrir le Runspace
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"
    $rs.ThreadOptions  = "ReuseThread"
    $rs.Open()
    $g.RS = $rs

    # Pipeline PowerShell dans ce Runspace
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $selKey     = $cmbGame.SelectedItem
    $selGame    = if ($selKey -and $gameMap.ContainsKey($selKey)) { $gameMap[$selKey] } else { $null }
    $gameName_  = if ($selGame) { $selGame.Name } else { "Jeu" }
    $ps.AddScript($optimBlock)     | Out-Null
    $ps.AddArgument($g.Queue)      | Out-Null
    $ps.AddArgument($mainScript)   | Out-Null
    $ps.AddArgument($selGame)      | Out-Null
    $g.PS    = $ps
    $g.Async = $ps.BeginInvoke()   # lancement asynchrone

    $btnStart.Enabled    = $false
    $btnStop.Enabled     = $true
    $btnRelaunch.Enabled = $true
    $lblStatus.Text      = "  Initialisation..."
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 75)

    Append-Log "  $gameName_ - optimiseur demarre (Runspace)" ([System.Drawing.Color]::FromArgb(70, 70, 105))
    Append-Log "" $defCol
    $timer.Start()
})

# ================================================================
#  BOUTON : Relancer
# ================================================================
$btnRelaunch.add_Click({
    # Arreter la session en cours sans restauration reseau
    if ($g.PS -or $g.RS) {
        try { $g.PS.Stop() }  catch {}
        try { $g.RS.Close(); $g.RS.Dispose() } catch {}
        $g.PS = $null; $g.RS = $null; $g.Async = $null
        $timer.Stop()
    }
    if (-not (Test-Path $mainScript)) { return }
    if (-not (Test-PreLaunch)) { return }

    $rtb.Clear()
    $g.Kills = 0; $g.Cycles = 0; $g.Iface = "-"
    Refresh-Stats

    # Init session (nouvelle session au relancement)
    $selKeyInitR  = $cmbGame.SelectedItem
    $selGameInitR = if ($selKeyInitR -and $gameMap.ContainsKey($selKeyInitR)) { $gameMap[$selKeyInitR] } else { $null }
    $script:sessionLogFile = Join-Path $logDir ("session-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".txt")
    $script:sessionData    = @{ startTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); game = if ($selGameInitR) { $selGameInitR.Name } else { "Inconnu" }; platform = if ($selGameInitR) { $selGameInitR.Platform } else { "-" }; spikes = 0; pingTotal = 0; pingCount = 0; maxPing = 0 }

    $g.Queue = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"; $rs.ThreadOptions = "ReuseThread"; $rs.Open()
    $g.RS = $rs
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $selKey_r  = $cmbGame.SelectedItem
    $selGame_r = if ($selKey_r -and $gameMap.ContainsKey($selKey_r)) { $gameMap[$selKey_r] } else { $null }
    $gameName_r = if ($selGame_r) { $selGame_r.Name } else { "Jeu" }
    $ps.AddScript($optimBlock) | Out-Null
    $ps.AddArgument($g.Queue)  | Out-Null
    $ps.AddArgument($mainScript) | Out-Null
    $ps.AddArgument($selGame_r)  | Out-Null
    $g.PS    = $ps
    $g.Async = $ps.BeginInvoke()
    $btnStart.Enabled    = $false
    $btnStop.Enabled     = $true
    $btnRelaunch.Enabled = $true
    $lblStatus.Text      = "  Relance en cours..."
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(190, 150, 45)
    Append-Log "  $gameName_r - relance (Runspace)" ([System.Drawing.Color]::FromArgb(70, 70, 105))
    Append-Log "" $defCol
    $timer.Start()
})

# ================================================================
#  BOUTON : Arreter
# ================================================================
$btnStop.add_Click({
    if ($g.PS -or $g.RS) {
        try { $g.PS.Stop() }  catch {}
        try { $g.RS.Close(); $g.RS.Dispose() } catch {}
        $g.PS = $null; $g.RS = $null; $g.Async = $null
        $timer.Stop()
        $btnStart.Enabled    = $true
        $btnStop.Enabled     = $false
        $btnRelaunch.Enabled = $false
        $lblStatus.Text      = "  Arrete manuellement"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(195, 75, 75)
        Append-Log "" $defCol
        Append-Log "  Session arretee." ([System.Drawing.Color]::FromArgb(195, 75, 75))
        Show-SessionSummary
        if (Test-Path $restorePs) {
            Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$restorePs`"" -Verb RunAs -WindowStyle Hidden
            Append-Log "  Restauration reseau lancee en arriere-plan..." ([System.Drawing.Color]::FromArgb(75, 200, 115))
        }
        Refresh-DB
    }
})

# ================================================================
#  BOUTON : Ouvrir .json
# ================================================================
$btnJson.add_Click({
    if (Test-Path $jsonFile) {
        Start-Process notepad.exe "`"$jsonFile`""
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "process-blacklist.json introuvable.", "CS2 Optimizer", "OK", "Warning") | Out-Null
    }
})

# ================================================================
#  BOUTON : Restaurer reseau
# ================================================================
$btnRestore.add_Click({
    if (-not (Test-Path $restorePs)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Restore-NetworkOptim.ps1 introuvable.", "CS2 Optimizer", "OK", "Warning") | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Restaurer les parametres reseau maintenant ?`n(DNS, TCP, QoS, Nagle...)",
        "Restauration", "YesNo", "Question")
    if ($r -eq "Yes") {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$restorePs`"" -Verb RunAs -WindowStyle Hidden
        Append-Log "  Restauration reseau lancee." ([System.Drawing.Color]::FromArgb(75, 200, 115))
    }
})

# ================================================================
#  BOUTON : Vider blacklist
# ================================================================
$btnClearDB.add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Vider la blacklist apprise automatiquement ?`n`nLes processus de base (Xbox, iCloud, etc.) seront recrees au prochain lancement.",
        "Vider blacklist", "YesNo", "Warning")
    if ($r -eq "Yes") {
        @{ processes = @(); count = 0; lastUpdated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } |
            ConvertTo-Json | Set-Content -Encoding UTF8 $jsonFile
        $lblDB.Text = "DB : 0 entrees"
        Append-Log "  Blacklist videe (process-blacklist.json)." ([System.Drawing.Color]::FromArgb(190, 150, 45))
    }
})

# ================================================================
#  BOUTON : Effacer logs
# ================================================================
$btnClearLog.add_Click({ $rtb.Clear() })

# ================================================================
#  BOUTON : Rafraichir jeux
# ================================================================
$btnRefresh.add_Click({
    $btnRefresh.Enabled = $false
    $cmbGame.Items.Clear()
    $gameMap.Clear()
    try {
        foreach ($g_ in (Get-InstalledGames | Sort-Object Name)) {
            $key = "$($g_.Name)  [$($g_.Platform)]"
            $gameMap[$key] = $g_
            $cmbGame.Items.Add($key) | Out-Null
        }
    } catch {}
    if ($cmbGame.Items.Count -gt 0) { $cmbGame.SelectedIndex = 0; Update-GameSelection }
    Append-Log "  Liste de jeux actualisee ($($cmbGame.Items.Count) jeux detectes)." ([System.Drawing.Color]::FromArgb(75, 205, 215))
    $btnRefresh.Enabled = $true
})

# ================================================================
#  BOUTON : Speedtest
# ================================================================
$btnSpeedtest.add_Click({
    $btnSpeedtest.Enabled = $false
    Append-Log "" $defCol
    Append-Log "  ── Speedtest ──────────────────────────────────" ([System.Drawing.Color]::FromArgb(55, 130, 200))

    $script:_stQ  = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()
    $stRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $stRS.ApartmentState = "MTA"; $stRS.ThreadOptions = "ReuseThread"; $stRS.Open()
    $stPS = [powershell]::Create()
    $stPS.Runspace = $stRS
    $stPS.AddScript({
        param($q)
        function qLog([string]$txt, [string]$col = "White") {
            $ts = [datetime]::Now.ToString("HH:mm:ss")
            $q.Enqueue([PSCustomObject]@{ T = "[$ts] $txt"; C = $col })
        }
        # 1. Ping base
        qLog "  Ping 1.1.1.1..." "Gray"
        $p1 = Test-Connection "1.1.1.1" -Count 4 -BufferSize 32 -EA SilentlyContinue
        if ($p1) {
            $a1 = [math]::Round(($p1 | Measure-Object ResponseTime -Average).Average)
            $m1 = ($p1 | Measure-Object ResponseTime -Maximum).Maximum
            qLog "  1.1.1.1    avg $a1 ms  max $m1 ms" "Green"
        } else { qLog "  1.1.1.1    timeout" "Red" }
        # 2. Download 10 MB
        qLog "  Download 10 MB (Cloudflare)..." "Gray"
        try {
            $wc = New-Object System.Net.WebClient
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $dl = $wc.DownloadData("https://speed.cloudflare.com/__down?bytes=10485760")
            $sw.Stop()
            $dlM = [math]::Round(($dl.Length * 8) / $sw.Elapsed.TotalSeconds / 1e6, 1)
            qLog "  Download   $dlM Mbps  ($([math]::Round($sw.Elapsed.TotalSeconds,1))s)" "Green"
        } catch { qLog "  Download   erreur : $($_.Exception.Message)" "Red" }
        # 3. Upload 4 MB
        qLog "  Upload 4 MB (Cloudflare)..." "Gray"
        try {
            $buf = [byte[]]::new(4 * 1024 * 1024)
            [System.Random]::new().NextBytes($buf)
            $wc2 = New-Object System.Net.WebClient
            $wc2.Headers.Add("Content-Type", "application/octet-stream")
            $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
            $null = $wc2.UploadData("https://speed.cloudflare.com/__up", $buf)
            $sw2.Stop()
            $ulM = [math]::Round(($buf.Length * 8) / $sw2.Elapsed.TotalSeconds / 1e6, 1)
            qLog "  Upload     $ulM Mbps  ($([math]::Round($sw2.Elapsed.TotalSeconds,1))s)" "Green"
        } catch { qLog "  Upload     erreur : $($_.Exception.Message)" "Red" }
        qLog "  ── Fin speedtest ──────────────────────────" "Cyan"
    }) | Out-Null
    $stPS.AddArgument($script:_stQ) | Out-Null
    $script:_stPS    = $stPS
    $script:_stRS    = $stRS
    $script:_stAsync = $stPS.BeginInvoke()

    $script:_stTmr = New-Object System.Windows.Forms.Timer
    $script:_stTmr.Interval = 200
    $script:_stTmr.add_Tick({
        $it = $null
        while ($script:_stQ.TryDequeue([ref]$it)) {
            $cl = if ($colorMap.ContainsKey($it.C)) { $colorMap[$it.C] } else { $defCol }
            Append-Log $it.T $cl
        }
        if ($script:_stAsync.IsCompleted) {
            while ($script:_stQ.TryDequeue([ref]$it)) {
                $cl = if ($colorMap.ContainsKey($it.C)) { $colorMap[$it.C] } else { $defCol }
                Append-Log $it.T $cl
            }
            try { $script:_stPS.EndInvoke($script:_stAsync) } catch {}
            try { $script:_stRS.Close(); $script:_stRS.Dispose() } catch {}
            $script:_stTmr.Stop()
            $btnSpeedtest.Enabled = $true
        }
    })
    $script:_stTmr.Start()
})

# ================================================================
#  FERMETURE
# ================================================================
$form.add_FormClosing({
    $timer.Stop()
    try { $g.PS.Stop() }  catch {}
    try { $g.RS.Close(); $g.RS.Dispose() } catch {}
    try { $script:_stTmr.Stop() } catch {}
    try { $script:_stPS.Stop()  } catch {}
    try { $script:_stRS.Close(); $script:_stRS.Dispose() } catch {}
})

# ================================================================
#  MESSAGE DE BIENVENUE
# ================================================================
Append-Log "  CS2 Optimizer v2  —  Interface graphique" ([System.Drawing.Color]::FromArgb(60, 205, 225))
Append-Log "  $scriptDir" ([System.Drawing.Color]::FromArgb(60, 60, 95))
Append-Log "" $defCol
if ($dbCount -gt 0) {
    Append-Log "  DB : $dbCount processus connus" ([System.Drawing.Color]::FromArgb(110, 110, 140))
    if ($dbDate) { Append-Log "  Mise a jour : $dbDate" ([System.Drawing.Color]::FromArgb(70, 70, 100)) }
    Append-Log "" $defCol
}
if (-not (Test-Path $mainScript)) {
    Append-Log "  ATTENTION : CS2-HighPriority.ps1 introuvable !" ([System.Drawing.Color]::FromArgb(215, 80, 80))
    Append-Log "" $defCol
}
Append-Log "  $($cmbGame.Items.Count) jeu(x) detecte(s). Selectionnez puis cliquez Lancer." ([System.Drawing.Color]::FromArgb(185, 185, 70))
# Affichage du rapport de diagnostic Steam (ecrit par Get-InstalledGames)
$dbgFile_ = "$scriptDir\cs2opt_debug.txt"
if (Test-Path $dbgFile_) {
    Append-Log "" $defCol
    Append-Log "  -- Diagnostic detection --" ([System.Drawing.Color]::FromArgb(80, 80, 120))
    Get-Content $dbgFile_ | ForEach-Object { Append-Log "  $_" ([System.Drawing.Color]::FromArgb(70, 70, 110)) }
}

# ================================================================
#  LANCEMENT DE LA FENETRE
# ================================================================
[System.Windows.Forms.Application]::Run($form)
