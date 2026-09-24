#Requires -Version 7.4

<#
    No test file reads $env:TEMP.

    $env:TEMP is Windows-only. On the ubuntu runner it is unset, so a path built from it
    collapses to a relative path under whatever the current directory is - usually the
    repository - and the suite writes its scratch files into the tree it is testing. The
    portable answer is [System.IO.Path]::GetTempPath(), which is what TestHelpers.psm1's
    sandbox uses.

    Measured on the AST, not the text: a comment or a string that names the variable (this
    one, for a start) is not a read. A VariableExpressionAst whose path is env:TEMP is.
#>

BeforeDiscovery {
    $script:TestFiles = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' } |
            ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
    )
}

Describe 'Test files resolve temp from GetTempPath, never from $env:TEMP' {
    # Discovery-phase variables do not survive into the run phase, so the list is
    # handed in as data rather than read back from $script: scope.
    It 'finds test files to measure (<Count> found at discovery)' -ForEach @(@{ Count = $script:TestFiles.Count }) {
        $Count | Should -BeGreaterThan 0
    }

    It '<Name> does not read $env:TEMP' -ForEach $script:TestFiles {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty -Because "$Name must parse before it can be measured"

        $reads = @(
            $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath -ieq 'env:TEMP'
                }, $true) |
                ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" }
        )
        $reads | Should -BeNullOrEmpty -Because 'use [System.IO.Path]::GetTempPath()'
    }
}
