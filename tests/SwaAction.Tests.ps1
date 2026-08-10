#requires -Version 7.0
#requires -Modules Pester

BeforeAll {
    Import-Module "$PSScriptRoot/../src/SwaDeploy.psd1" -Force
}

Describe 'Get-ActionInput' {
    AfterEach {
        Remove-Item Env:INPUT_SAMPLE_INPUT -ErrorAction SilentlyContinue
    }

    It 'reads the INPUT_ variable GitHub sets for the input' {
        $env:INPUT_SAMPLE_INPUT = 'value'
        Get-ActionInput 'sample_input' | Should -Be 'value'
    }

    It 'is case insensitive about the input name' {
        $env:INPUT_SAMPLE_INPUT = 'value'
        Get-ActionInput 'Sample_Input' | Should -Be 'value'
    }

    It 'trims, because YAML block scalars pick up trailing newlines' {
        $env:INPUT_SAMPLE_INPUT = "  spaced  `n"
        Get-ActionInput 'sample_input' | Should -Be 'spaced'
    }

    It 'falls back to the default when unset or whitespace' -ForEach @(
        @{ Value = $null }
        @{ Value = '' }
        @{ Value = '   ' }
    ) {
        if ($null -ne $Value) { $env:INPUT_SAMPLE_INPUT = $Value }
        Get-ActionInput 'sample_input' 'fallback' | Should -Be 'fallback'
    }
}

Describe 'Test-ActionFlag' {
    AfterEach {
        Remove-Item Env:INPUT_SAMPLE_FLAG -ErrorAction SilentlyContinue
    }

    It 'accepts <Value> as true' -ForEach @(
        @{ Value = 'true' }, @{ Value = 'True' }, @{ Value = 'TRUE' }
        @{ Value = '1' }, @{ Value = 'yes' }
    ) {
        $env:INPUT_SAMPLE_FLAG = $Value
        Test-ActionFlag 'sample_flag' | Should -BeTrue
    }

    It 'treats <Value> as false' -ForEach @(
        @{ Value = 'false' }, @{ Value = '0' }, @{ Value = 'no' }
        @{ Value = 'maybe' }, @{ Value = '' }
    ) {
        $env:INPUT_SAMPLE_FLAG = $Value
        Test-ActionFlag 'sample_flag' | Should -BeFalse
    }
}

Describe 'Write-ActionOutput' {
    BeforeEach {
        # Saved and restored or the suite writes into the real job summary when CI runs it
        $script:savedOutput = $env:GITHUB_OUTPUT
        $script:outputFile = Join-Path ([System.IO.Path]::GetTempPath()) "swa-out-$([guid]::NewGuid().ToString('n'))"
        $env:GITHUB_OUTPUT = $script:outputFile
    }

    AfterEach {
        if ($null -eq $script:savedOutput) {
            Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        } else {
            $env:GITHUB_OUTPUT = $script:savedOutput
        }
        Remove-Item -LiteralPath $script:outputFile -Force -ErrorAction SilentlyContinue
    }

    It 'writes name=value' {
        Write-ActionOutput 'site_url' 'https://example.net'
        Get-Content -LiteralPath $script:outputFile | Should -Be 'site_url=https://example.net'
    }

    It 'appends rather than replacing, so every output survives' {
        Write-ActionOutput 'a' '1'
        Write-ActionOutput 'b' '2'
        Get-Content -LiteralPath $script:outputFile | Should -HaveCount 2
    }

    It 'flattens newlines so the rest of a value cannot be parsed as further outputs' {
        Write-ActionOutput 'evil' "safe`nmalicious=1"
        $lines = @(Get-Content -LiteralPath $script:outputFile)
        $lines | Should -HaveCount 1
        $lines[0] | Should -Be 'evil=safe malicious=1'
    }

    It 'writes nothing when GITHUB_OUTPUT is unset, rather than throwing' {
        Remove-Item Env:GITHUB_OUTPUT
        { Write-ActionOutput 'a' '1' } | Should -Not -Throw
    }
}

Describe 'Write-ActionSummary' {
    BeforeEach {
        $script:savedSummary = $env:GITHUB_STEP_SUMMARY
        $script:summaryFile = Join-Path ([System.IO.Path]::GetTempPath()) "swa-sum-$([guid]::NewGuid().ToString('n'))"
        $env:GITHUB_STEP_SUMMARY = $script:summaryFile
    }

    AfterEach {
        if ($null -eq $script:savedSummary) {
            Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
        } else {
            $env:GITHUB_STEP_SUMMARY = $script:savedSummary
        }
        Remove-Item -LiteralPath $script:summaryFile -Force -ErrorAction SilentlyContinue
    }

    It 'keeps blank lines, which are meaningful markdown separators' {
        Write-ActionSummary @('# Title', '', 'body')
        (Get-Content -LiteralPath $script:summaryFile -Raw) | Should -Match "# Title\r?\n\r?\nbody"
    }
}

Describe 'Format-SwaSummaryTable' {
    It 'emits a markdown table with a separator row' {
        $lines = Format-SwaSummaryTable -Rows ([ordered]@{ Files = 42 })
        $lines | Should -Contain '|---|---|'
        $lines | Should -Contain '| **Files** | 42 |'
    }

    It 'puts the title first when one is given' {
        $lines = Format-SwaSummaryTable -Title '### Deployed' -Rows ([ordered]@{ Files = 1 })
        $lines[0] | Should -Be '### Deployed'
    }

    It 'preserves row order so the table reads the way it was written' {
        $lines = Format-SwaSummaryTable -Rows ([ordered]@{ First = 'a'; Second = 'b'; Third = 'c' })
        $body = @($lines | Where-Object { $_ -like '| **T*' -or $_ -like '| **F*' -or $_ -like '| **S*' })
        $body[0] | Should -Match 'First'
        $body[1] | Should -Match 'Second'
        $body[2] | Should -Match 'Third'
    }

    It 'drops rows with no value, so one row set can serve every code path' {
        $lines = Format-SwaSummaryTable -Rows ([ordered]@{ Present = 'yes'; Absent = $null; Blank = '' })
        ($lines -join "`n") | Should -Match 'Present'
        ($lines -join "`n") | Should -Not -Match 'Absent'
        ($lines -join "`n") | Should -Not -Match 'Blank'
    }

    It 'escapes pipes and flattens newlines, which would otherwise break the table' {
        $lines = Format-SwaSummaryTable -Rows ([ordered]@{ Error = "a | b`nc" })
        $row = $lines | Where-Object { $_ -like '| **Error***' }
        $row | Should -Be '| **Error** | a \| b c |'
    }

    It 'renders a table with no rows rather than throwing' {
        { Format-SwaSummaryTable -Rows ([ordered]@{}) } | Should -Not -Throw
    }
}

Describe 'Write-ActionError, Write-ActionWarning and Write-ActionNotice' {
    It '<Function> emits a single-line <Command> workflow command' -ForEach @(
        @{ Function = 'Write-ActionError'; Command = '::error::' }
        @{ Function = 'Write-ActionWarning'; Command = '::warning::' }
        @{ Function = 'Write-ActionNotice'; Command = '::notice::' }
    ) {
        # Workflow commands are line-oriented: a raw newline would truncate the annotation
        $out = & $Function "first`nsecond" 6>&1
        "$out" | Should -Be "${Command}first second"
    }
}
