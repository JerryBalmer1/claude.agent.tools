#Requires -Version 7.4
<#
.SYNOPSIS
Resolves references to retired repositories and verifies they don't exist on disk.

.DESCRIPTION
Scans all five active repositories (core, docs, images, interrogator, tools) for
references to three archived repositories:
  - claude.build.inspector
  - claude.build.fuzzer
  - claude.pwsh.image.builder

Uses git grep to find textual references, then parses path-like references (non-URLs)
and tries to resolve them against:
  1. The file's directory
  2. The repository root
  3. The workspace root

Exits 0 when zero path-like references resolve to existing files or directories.
Exits 1 only if an error occurs, not if grep finds text (grep returns 1 when no
matches, which is not an error for this use case).

.PARAMETER Verbose
If specified, prints git grep output and resolution attempts.
#>

param(
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repos = @(
    'c:\__Code\____Claude.Build\claude.agent.core',
    'c:\__Code\____Claude.Build\claude.agent.docs',
    'c:\__Code\____Claude.Build\claude.agent.images',
    'c:\__Code\____Claude.Build\claude.agent.interrogator',
    'c:\__Code\____Claude.Build\claude.agent.tools'
)

$retired = @(
    'claude.build.inspector',
    'claude.build.fuzzer',
    'claude.pwsh.image.builder'
)

$resolvedCount = 0
$resolvedPaths = @()

Write-Host "`n=== RESOLVE RETIRED PATHS ===" -ForegroundColor Cyan

foreach ($repo in $repos) {
    $repoName = Split-Path $repo -Leaf
    Push-Location $repo
    
    foreach ($name in $retired) {
        # Use git grep; exit code 1 when no matches is normal, not an error
        $ErrorActionPreference = 'Continue'
        $grepResult = @(git grep $name 2>&1)
        $grepExitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        
        if ($grepExitCode -eq 0) {
            if ($Verbose) {
                Write-Host "`n[$repoName] Found references to $name" -ForegroundColor Yellow
            }
            
            foreach ($line in $grepResult) {
                # Parse: filename:content
                if ($line -match '^([^:]+):(.*)$') {
                    $fileName = $matches[1]
                    $content = $matches[2]
                    
                    # Skip URLs and pure text references
                    # Look for path-like patterns: paths with / or \ or . followed by a folder name
                    # Match patterns like ../claude.build.xyz or claude.build.xyz@sha
                    if ($content -match '(\.\./)|(^\./)' -or $content -match 'claude\.(build|agent)\.' -and $content -notmatch 'https?://') {
                        
                        # Extract potential paths from the content
                        # Try: ../claude.build.xyz, ./claude.build.xyz, just claude.build.xyz
                        if ($content -match '(\.\./)?claude\.build\.\w+') {
                            $potentialPath = $matches[0]
                            
                            # Resolve against three locations
                            $fileDir = Split-Path $fileName -Parent
                            if (-not $fileDir) { $fileDir = $repo }
                            
                            $candidates = @(
                                (Join-Path $fileDir $potentialPath),
                                (Join-Path $repo $potentialPath),
                                (Join-Path 'c:\__Code\____Claude.Build' $potentialPath)
                            )
                            
                            foreach ($candidate in $candidates) {
                                if (Test-Path $candidate) {
                                    $resolvedCount++
                                    $resolvedPaths += @{
                                        repo     = $repoName
                                        file     = $fileName
                                        pattern  = $potentialPath
                                        resolved = (Resolve-Path $candidate).Path
                                    }
                                    Write-Host "  RESOLVED: $fileName" -ForegroundColor Red
                                    Write-Host "    Pattern: $potentialPath" -ForegroundColor Red
                                    Write-Host "    Resolved to: $(Resolve-Path $candidate)" -ForegroundColor Red
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    Pop-Location
}

Write-Host "`n=== RESULT ===" -ForegroundColor Cyan
if ($resolvedCount -eq 0) {
    Write-Host "✓ Zero path-like references resolved on disk." -ForegroundColor Green
    exit 0
} else {
    Write-Host "✗ $resolvedCount reference(s) resolved to existing paths:" -ForegroundColor Red
    $resolvedPaths | ForEach-Object {
        Write-Host "  [$($_.repo)] $($_.file) -> $($_.resolved)" -ForegroundColor Red
    }
    exit 1
}
