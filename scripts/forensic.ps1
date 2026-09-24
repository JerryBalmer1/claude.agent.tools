#Requires -Version 7.4
<#
.SYNOPSIS
    The forensic chain: an append-only, hash-chained record of who did what to the law.

.DESCRIPTION
    This is the SECOND chain, and it is deliberately not the first.

    The receipt ledger that core's ledger module writes is schema v1: eight frozen keys,
    one writer, and every hash already written depends on that set never changing. A
    continuity or forensic entry is not a receipt and must never be forced into that
    schema - a ninth key invalidates the entire history. The continuity design this
    script was born under said that if continuity were ever to be hash-chained for real
    it would be a second, separate NDJSON chain reusing the same canonical-JSON
    discipline, and that it must not be started without being asked. Jerry asked on
    2026-09-20.

    Schema forensic-v1, eight keys, in this order, frozen from birth:

        ts        ISO-8601 UTC, the moment the record was appended
        seq       monotonic integer, 1-based, gapless
        actor     grok | claude | jerry | fable   -- operator-asserted, see SHARP EDGES
        kind      finding | confession | repair | decision | verification
        subject   short kebab-case slug
        evidence  the falsifiable part: a sha, a command, a count. Prose is not evidence.
        prev      the previous record's `self`, '' for the genesis record
        self      sha256 of this record's canonical payload, `self` excluded

    SHARP EDGES, stated because the rest of this repo states its own:

    - **This is tamper-EVIDENT, not tamper-proof.** Anyone with write access can rewrite
      the whole file and recompute every hash. What the chain buys is that a *partial*
      edit is detectable and that a *full* rewrite changes the tip. The tip is therefore
      worth exactly what its off-tree anchor is worth.
    - **The anchor is the part no agent can reach, and it is not in this repo.**
      `-Anchor` prints one line: record count, git HEAD, tip hash. Screenshotted, pasted
      into a chat, or quoted in a commit message, that line lives outside any agent's
      write access. Inside the repo it is just a file.
    - **`actor` is operator-asserted.** Exactly like the `who:` trailer, exactly like the
      image builder's identity claim. It is not a signature. It is a place to be caught
      lying.
    - **Appending does not verify the tip** - the same limitation `Add-LedgerRecord`
      documents. `-Append` reads the tail to learn `prev`. It differs from the receipt
      writer in one way: it refuses outright when the tail does not verify, unless
      `-Force` is passed, and then it says so on stderr.

.EXAMPLE
    pwsh -NoProfile -File scripts/forensic.ps1 -Verify

.EXAMPLE
    pwsh -NoProfile -File scripts/forensic.ps1 -Anchor

.EXAMPLE
    pwsh -NoProfile -File scripts/forensic.ps1 -Append -Actor claude -Kind finding -Subject agents-md-content-loss -Evidence '85 lines absent at eb41572'
#>
[CmdletBinding(DefaultParameterSetName = 'Verify')]
param(
    [Parameter(ParameterSetName = 'Append', Mandatory)] [switch]$Append,
    [Parameter(ParameterSetName = 'Append', Mandatory)]
    [ValidateSet('grok', 'claude', 'jerry', 'fable')] [string]$Actor,
    [Parameter(ParameterSetName = 'Append', Mandatory)]
    [ValidateSet('finding', 'confession', 'repair', 'decision', 'verification')] [string]$Kind,
    [Parameter(ParameterSetName = 'Append', Mandatory)]
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string]$Subject,
    [Parameter(ParameterSetName = 'Append', Mandatory)]
    [ValidateNotNullOrEmpty()] [string]$Evidence,
    [Parameter(ParameterSetName = 'Append')] [switch]$Force,

    [Parameter(ParameterSetName = 'Verify')] [switch]$Verify,
    [Parameter(ParameterSetName = 'Anchor')] [switch]$Anchor,

    [string]$Path
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

$script:Keys = @('ts', 'seq', 'actor', 'kind', 'subject', 'evidence', 'prev', 'self')

function Resolve-ForensicPath {
    param([AllowEmptyString()] [AllowNull()] [string]$P)
    if (-not [string]::IsNullOrWhiteSpace($P)) { return [System.IO.Path]::GetFullPath($P) }
    $root = Split-Path $PSScriptRoot -Parent
    return [System.IO.Path]::GetFullPath((Join-Path $root '.continuity/forensic.jsonl'))
}

function ConvertTo-ForensicJsonString {
    <#
    .SYNOPSIS
        Minimal, explicit JSON string escaping.
    .DESCRIPTION
        Not ConvertTo-Json. That cmdlet pretty-prints by default, escapes non-ASCII
        inconsistently across hosts, and is banned on a chain for the same reason
        ConvertFrom-Json is: the bytes must be reproducible exactly or every hash fails.
    #>
    param([AllowEmptyString()] [string]$Text)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append([char]0x22)
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq [char]0x22) { [void]$sb.Append([char]0x5C); [void]$sb.Append([char]0x22) }
        elseif ($code -eq 0x5C) { [void]$sb.Append([char]0x5C); [void]$sb.Append([char]0x5C) }
        elseif ($code -eq 0x08) { [void]$sb.Append([char]0x5C); [void]$sb.Append('b') }
        elseif ($code -eq 0x0C) { [void]$sb.Append([char]0x5C); [void]$sb.Append('f') }
        elseif ($code -eq 0x0A) { [void]$sb.Append([char]0x5C); [void]$sb.Append('n') }
        elseif ($code -eq 0x0D) { [void]$sb.Append([char]0x5C); [void]$sb.Append('r') }
        elseif ($code -eq 0x09) { [void]$sb.Append([char]0x5C); [void]$sb.Append('t') }
        elseif ($code -lt 0x20) { [void]$sb.Append([char]0x5C); [void]$sb.AppendFormat('u{0:x4}', $code) }
        else                    { [void]$sb.Append($ch) }
    }
    [void]$sb.Append([char]0x22)
    return $sb.ToString()
}

function ConvertTo-ForensicCanonicalJson {
    <#
    .SYNOPSIS
        The exact bytes hashed into 'self'. Key order is the schema, not a hashtable's
        whim. No whitespace. 'self' is excluded by construction, never by deletion.
    #>
    param(
        [Parameter(Mandatory)] [string]$Ts,
        [Parameter(Mandatory)] [int]$Seq,
        [Parameter(Mandatory)] [string]$Actor,
        [Parameter(Mandatory)] [string]$Kind,
        [Parameter(Mandatory)] [string]$Subject,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Evidence,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Prev
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    return '{"ts":'       + (ConvertTo-ForensicJsonString $Ts)       +
           ',"seq":'      + $Seq.ToString($inv)                      +
           ',"actor":'    + (ConvertTo-ForensicJsonString $Actor)    +
           ',"kind":'     + (ConvertTo-ForensicJsonString $Kind)     +
           ',"subject":'  + (ConvertTo-ForensicJsonString $Subject)  +
           ',"evidence":' + (ConvertTo-ForensicJsonString $Evidence) +
           ',"prev":'     + (ConvertTo-ForensicJsonString $Prev)     + '}'
}

function Get-ForensicSha256Hex {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Text)
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($digest).ToLowerInvariant()
}

function Test-ForensicHex64 {
    <#
    .SYNOPSIS
        64 lowercase hex characters and nothing else.
    .DESCRIPTION
        Anchored with \z, not $. In .NET '$' also matches immediately before a trailing
        newline, so a hash with a newline welded on would validate and then hash
        differently. -cmatch keeps it case-sensitive: uppercase hex is a different
        string and must not be waved through.
    #>
    param([AllowNull()] $Value)
    return ($Value -is [string]) -and ($Value -cmatch '^[0-9a-f]{64}\z')
}

function ConvertFrom-ForensicLine {
    <#
    .SYNOPSIS
        Parse one line into a validated record, or throw.
    .DESCRIPTION
        System.Text.Json, not ConvertFrom-Json: the latter infers types and turns an
        ISO-8601 'ts' into a [datetime], which does not re-stringify to the same bytes.
        Checks JSON well-formedness, the exact eight-key set in order with no
        duplicates, field shapes, and that 'self' equals the sha256 of this record's
        own canonical payload. Chain linkage is the caller's job.
    #>
    param([Parameter(Mandatory)] [string]$Line, [Parameter(Mandatory)] [int]$Number)

    try { $doc = [System.Text.Json.JsonDocument]::Parse($Line) }
    catch { throw "line ${Number}: not well-formed JSON -- $($_.Exception.Message)" }

    try {
        $root = $doc.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw "line ${Number}: record is not a JSON object"
        }
        $seen = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $root.EnumerateObject()) {
            if ($seen.Contains($p.Name)) { throw "line ${Number}: duplicate key '$($p.Name)'" }
            $seen.Add($p.Name)
        }
        if ($seen.Count -ne $script:Keys.Count) {
            throw "line ${Number}: expected $($script:Keys.Count) keys, found $($seen.Count) [$($seen -join ',')]"
        }
        for ($i = 0; $i -lt $script:Keys.Count; $i++) {
            if ($seen[$i] -cne $script:Keys[$i]) {
                throw "line ${Number}: key $($i + 1) is '$($seen[$i])', schema says '$($script:Keys[$i])'"
            }
        }
        $rec = [ordered]@{}
        foreach ($k in $script:Keys) {
            $el = $root.GetProperty($k)
            $rec[$k] = if ($k -eq 'seq') { $el.GetInt32() } else { $el.GetString() }
        }
    }
    finally { $doc.Dispose() }

    if (-not (Test-ForensicHex64 $rec['self'])) {
        throw "line ${Number}: 'self' is not 64 lowercase hex"
    }
    if ($rec['prev'] -ne '' -and -not (Test-ForensicHex64 $rec['prev'])) {
        throw "line ${Number}: 'prev' is neither empty nor 64 lowercase hex"
    }

    $payload = ConvertTo-ForensicCanonicalJson -Ts $rec['ts'] -Seq $rec['seq'] -Actor $rec['actor'] `
        -Kind $rec['kind'] -Subject $rec['subject'] -Evidence $rec['evidence'] -Prev $rec['prev']
    $computed = Get-ForensicSha256Hex $payload
    if ($computed -cne $rec['self']) {
        throw "line ${Number}: self mismatch -- record says $($rec['self']), payload hashes to $computed"
    }
    return [pscustomobject]$rec
}

function Get-ForensicChain {
    param([Parameter(Mandatory)] [string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($File, [System.Text.UTF8Encoding]::new($false))
    $out = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($line in $lines) {
        $n++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $out.Add((ConvertFrom-ForensicLine -Line $line -Number $n))
    }
    for ($i = 0; $i -lt $out.Count; $i++) {
        $expectedPrev = if ($i -eq 0) { '' } else { $out[$i - 1].self }
        if ($out[$i].prev -cne $expectedPrev) {
            throw "record $($i + 1): prev is '$($out[$i].prev)', the chain says '$expectedPrev'"
        }
        if ($out[$i].seq -ne ($i + 1)) {
            throw "record $($i + 1): seq is $($out[$i].seq), expected $($i + 1)"
        }
    }
    return $out.ToArray()
}

# ------------------------------------------------------------------- actions

$file = Resolve-ForensicPath $Path

if ($PSCmdlet.ParameterSetName -eq 'Append') {
    Write-Verbose "forensic chain: $file"
    $tail = @()
    try {
        $tail = @(Get-ForensicChain -File $file)
        Write-Debug "tail verified, records=$($tail.Count)"
    }
    catch {
        if (-not $Force) {
            throw "refusing to append to an unverifiable chain: $($_.Exception.Message)"
        }
        Write-Warning "appending over an unverifiable tail because -Force was passed: $($_.Exception.Message)"
        $tail = @()
    }

    $prev = if ($tail.Count -gt 0) { $tail[-1].self } else { '' }
    $seq  = $tail.Count + 1
    $ts   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $payload = ConvertTo-ForensicCanonicalJson -Ts $ts -Seq $seq -Actor $Actor -Kind $Kind `
        -Subject $Subject -Evidence $Evidence -Prev $prev
    $self = Get-ForensicSha256Hex $payload
    $line = $payload.Substring(0, $payload.Length - 1) +
            ',"self":' + (ConvertTo-ForensicJsonString $self) + '}'

    $dir = Split-Path $file -Parent
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    # One handle, exclusive, append, flushed. Same discipline as Add-LedgerRecord.
    $fs = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
        try { $sw.NewLine = "`n"; $sw.WriteLine($line); $sw.Flush() }
        finally { $sw.Dispose() }
    }
    finally { $fs.Dispose() }

    Write-Verbose "appended seq=$seq self=$self"
    [pscustomobject]@{
        Seq = $seq; Actor = $Actor; Kind = $Kind; Subject = $Subject; Prev = $prev; Self = $self
    }
    return
}

$chain = @(Get-ForensicChain -File $file)

if ($PSCmdlet.ParameterSetName -eq 'Anchor') {
    $repo = Split-Path $PSScriptRoot -Parent
    $head = & git -C $repo rev-parse --short HEAD 2>$null
    if ([string]::IsNullOrWhiteSpace($head)) { $head = 'no-git' }
    $tip = if ($chain.Count -gt 0) { $chain[-1].self } else { '(empty)' }
    Write-Host "FORENSIC ANCHOR  records=$($chain.Count)  git=$head  tip=$tip"
    Write-Host 'Any change to any earlier record changes this tip. Keep a copy off the tree.'
    exit 0
}

Write-Host "forensic chain: $file"
Write-Host "records: $($chain.Count) -- every self recomputed, every prev walked, seq gapless"
foreach ($r in $chain) {
    Write-Host ('  {0,3}  {1,-7} {2,-12} {3,-36} {4}' -f
        $r.seq, $r.actor, $r.kind, $r.subject, $r.self.Substring(0, 12))
}
if ($chain.Count -gt 0) { Write-Host "tip: $($chain[-1].self)" }
Write-Host 'FORENSIC CHAIN OK'
exit 0
