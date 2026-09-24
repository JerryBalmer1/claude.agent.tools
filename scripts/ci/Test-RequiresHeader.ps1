#Requires -Version 7.4
#
# COPIED, NOT VENDORED.
#   origin repo   : claude.agent.substrate
#   origin file   : scripts/ci/Test-RequiresHeader.ps1
#   origin commit : 912c1c9eb48ab0b639d257bc7b10661d7212f985
#   origin sha256 : 12b0ae02e453320afb381f16e47abf258025f742527434f211f98556a40931a7
#   adapted here  : no - byte-identical at copy time
#
# There is no submodule here and substrate does not follow this copy. If substrate's
# version moves, this one does not move with it. Diff the two against the origin commit
# above before assuming they still agree.
#
<#
.SYNOPSIS
    CI check "requires-header": every tracked .ps1/.psm1 declares the version floor on line 1.

.DESCRIPTION
    The floor comes from config/repo.json -> scripts.requires_version. It is not hard-coded
    here, because then the config would not be the source of truth.

    Line 1 exactly, not "somewhere in the file". `#Requires` is honoured by PowerShell wherever
    it appears at statement level, so a lenient check would pass a file whose header sits below
    200 lines of code that already failed to parse on 5.1. Line 1 is the only position that is
    unambiguous to a human opening the file.

    Only tracked files are checked (`git ls-files`), so a stray scratch script in the working
    tree cannot fail CI and, more importantly, cannot sneak past it either - if it is not
    tracked it is not in the repo.

.EXAMPLE
    pwsh -NoProfile -File scripts/ci/Test-RequiresHeader.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$config   = (Get-Content -LiteralPath (Join-Path $RepoRoot 'config/repo.json') -Raw | ConvertFrom-Json -Depth 20)
$floor    = $config.scripts.requires_version
$expected = "#Requires -Version $floor"

Write-Host "requires-header: floor '$floor' from config/repo.json -> scripts.requires_version"

Push-Location $RepoRoot
try {
    $files = @(git ls-files -- '*.ps1' '*.psm1' | Where-Object { $_ -notmatch '^vendor/' })
}
finally { Pop-Location }

if ($files.Count -eq 0) {
    Write-Host 'requires-header: FAIL -- no tracked .ps1/.psm1 files found; a check that checks nothing is not a check'
    exit 1
}

$bad = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $files) {
    $full = Join-Path $RepoRoot $rel
    $first = @(Get-Content -LiteralPath $full -TotalCount 1)
    $line1 = if ($first.Count -gt 0) { $first[0].TrimEnd() } else { '' }
    if ($line1 -ceq $expected) {
        Write-Host "  OK    $rel"
    }
    else {
        Write-Host "  MISS  $rel -- line 1 is '$line1', expected '$expected'"
        $bad.Add($rel)
    }
}

Write-Host "requires-header: $($files.Count) file(s) checked, $($bad.Count) missing the header"
if ($bad.Count -gt 0) {
    Write-Host 'requires-header: FAIL'
    exit 1
}
Write-Host 'requires-header: PASS'
exit 0
