$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    'C:\Users\HalCroves\NetworkOptim\CS2-Launcher.ps1',
    [ref]$null,
    [ref]$errs
)
if ($errs.Count -eq 0) { 'OK - Pas erreur syntaxe' }
else { $errs | ForEach-Object { $_.ToString() } }
