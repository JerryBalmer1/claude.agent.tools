#Requires -Version 7.4

<#
.SYNOPSIS
    Shared test plumbing for the claude.agent.tools Pester suite.

    Copied from claude.agent.images@249752d (blob ec48d5c1), then adapted:
    Invoke-Native is removed because it existed to drive docker, and tools
    builds no image. Everything else is unchanged.

.DESCRIPTION
    Everything here exists so the suite can make exact claims about a script's
    three observable outputs — stdout, stderr, exit code — without PowerShell
    getting in the way of any of them.

    Why a raw Process and not `pwsh -File ... 2>$err`:

      * Exact stdout. The sentinel contract says a non-gated tool emits exactly
        "{}" and a malformed payload emits NOTHING. Asserting "nothing" needs a
        stream that has not been trimmed, re-encoded or turned into an object
        array on the way back.
      * Expected non-zero exits. $PSNativeCommandUseErrorActionPreference is
        $true across this repo, which turns exit 2 into a terminating error —
        and exit 2 is a PASSING case here. A Process does not care.
      * Per-call environment. Both scripts under test are configured by
        environment variable, and $env: assignment leaks into the rest of the
        session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PwshPath {
    <#
    .SYNOPSIS
        The pwsh running this suite, so child processes match the parent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($self -and (Test-Path -LiteralPath $self)) { return $self }

    $cmd = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    throw 'cannot locate pwsh for child-process tests'
}

function Invoke-LeashScript {
    <#
    .SYNOPSIS
        Run a .ps1 in a child pwsh and capture stdout, stderr and exit code.

    .PARAMETER Stdin
        Written to the child's stdin, which is then closed. Pass '' to close it
        immediately with nothing in it.

    .PARAMETER Environment
        Applied to the child only. A $null value removes the variable, which is
        how "LEDGER_PRINCIPAL unset" is tested without unsetting it here.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [string[]]$Arguments = @(),

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Stdin,

        [Parameter()]
        [hashtable]$Environment = @{},

        [Parameter()]
        [int]$TimeoutSeconds = 120
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "script under test does not exist: $Path"
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Get-PwshPath
    foreach ($a in @('-NoProfile', '-File', $Path) + $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    foreach ($key in $Environment.Keys) {
        $value = $Environment[$key]
        if ($null -eq $value) { [void]$psi.Environment.Remove($key) }
        else { $psi.Environment[$key] = [string]$value }
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()

    # Start both reads BEFORE writing stdin: a child that fills its stdout pipe
    # while this side is still writing would deadlock both processes.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if ($null -ne $Stdin) { $proc.StandardInput.Write($Stdin) }
    $proc.StandardInput.Close()

    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        throw "script timed out after ${TimeoutSeconds}s: $Path"
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $code = $proc.ExitCode
    $proc.Dispose()

    return [pscustomobject]@{
        PSTypeName = 'Leash.ScriptResult'
        Path       = $Path
        ExitCode   = $code
        StdOut     = $stdout
        StdErr     = $stderr
    }
}

function New-LeashSandbox {
    <#
    .SYNOPSIS
        A throwaway directory with a ledger subdirectory inside it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("leash-" + [guid]::NewGuid().ToString('n').Substring(0, 12))
    $ledgerDir = Join-Path $root 'ledger'
    [void](New-Item -ItemType Directory -Path $ledgerDir -Force)

    return [pscustomobject]@{
        Root       = $root
        LedgerDir  = $ledgerDir
        LedgerPath = Join-Path $ledgerDir 'ledger.jsonl'
    }
}

function Remove-LeashSandbox {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    if (Test-Path -LiteralPath $Root) {
        [System.IO.Directory]::Delete($Root, $true)
    }
}

function Get-RepoRoot {
    <#
    .SYNOPSIS
        Repository root, resolved from this module rather than the working
        directory, so the suite runs the same whatever cwd Pester was started in
        and whether that is C:\... on the host or /work in the container.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-LedgerManifestPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Join-Path (Get-RepoRoot) 'vendor' 'claude.agent.core' 'modules' 'ledger' 'ledger.psd1'
}

function ConvertFrom-JsonSafe {
    <#
    .SYNOPSIS
        Parse JSON, or fail the assertion with the text that would not parse.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'expected JSON but got an empty string' }
    try { return $Text | ConvertFrom-Json -Depth 100 }
    catch { throw "expected JSON but could not parse: <$Text>" }
}

Export-ModuleMember -Function 'Get-PwshPath', 'Invoke-LeashScript',
    'New-LeashSandbox', 'Remove-LeashSandbox', 'Get-RepoRoot', 'Get-LedgerManifestPath',
    'ConvertFrom-JsonSafe'
