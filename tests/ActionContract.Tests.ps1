#requires -Version 7.0
#requires -Modules Pester

<#
    Adding an input takes three edits - action.yml inputs:, action.yml env:, and a
    Get-ActionInput call - and getting two of the three done is exactly the kind of mistake
    that only shows up in a live run. These assert the wiring instead.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionYml = Get-Content -LiteralPath (Join-Path $script:repoRoot 'action.yml') -Raw
    $script:entrypoint = Get-Content -LiteralPath (Join-Path $script:repoRoot 'src/Invoke-Action.ps1') -Raw
    Import-Module (Join-Path $script:repoRoot 'src/SwaDeploy.psd1') -Force

    # action.yml is flat and hand-maintained, so section slicing beats a YAML parser dependency
    function Get-YamlSection {
        param([string]$Text, [string]$Start, [string]$End)
        $from = $Text.IndexOf($Start)
        if ($from -lt 0) { return '' }
        $to = if ($End) { $Text.IndexOf($End, $from) } else { -1 }
        if ($to -lt 0) { $to = $Text.Length }
        return $Text.Substring($from, $to - $from)
    }

    $script:inputsBlock = Get-YamlSection $script:actionYml 'inputs:' 'outputs:'
    $script:outputsBlock = Get-YamlSection $script:actionYml 'outputs:' 'runs:'
    $script:envBlock = Get-YamlSection $script:actionYml '      env:' '      run:'

    $script:declaredInputs = @([regex]::Matches($script:inputsBlock, '(?m)^  ([a-z0-9_]+):') |
            ForEach-Object { $_.Groups[1].Value })
    $script:declaredOutputs = @([regex]::Matches($script:outputsBlock, '(?m)^  ([a-z0-9_]+):') |
            ForEach-Object { $_.Groups[1].Value })
    $script:envNames = @([regex]::Matches($script:envBlock, '(?m)^        INPUT_([A-Z0-9_]+):') |
            ForEach-Object { $_.Groups[1].Value })
}

Describe 'action.yml input wiring' {
    It 'declares inputs at all, so a broken regex cannot make these tests vacuous' {
        $script:declaredInputs.Count | Should -BeGreaterThan 10
        $script:envNames.Count | Should -BeGreaterThan 10
    }

    It 'forwards every declared input as INPUT_*' {
        # A composite action gets no automatic INPUT_ variables - each one is forwarded by hand
        $missing = @($script:declaredInputs | Where-Object { $_.ToUpperInvariant() -notin $script:envNames })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'forwards nothing that is not a declared input' {
        $undeclared = @($script:envNames | Where-Object { $_.ToLowerInvariant() -notin $script:declaredInputs })
        $undeclared -join ', ' | Should -BeNullOrEmpty
    }

    It 'reads only inputs that action.yml declares' {
        $read = @([regex]::Matches($script:entrypoint, "Get-ActionInput\s+'([a-z0-9_]+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $read.Count | Should -BeGreaterThan 5
        $undeclared = @($read | Where-Object { $_ -notin $script:declaredInputs })
        $undeclared -join ', ' | Should -BeNullOrEmpty
    }

    It 'tests only flags that action.yml declares' {
        $flags = @([regex]::Matches($script:entrypoint, "Test-ActionFlag\s+'([a-z0-9_]+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $undeclared = @($flags | Where-Object { $_ -notin $script:declaredInputs })
        $undeclared -join ', ' | Should -BeNullOrEmpty
    }

    It 'gives every input a description' {
        foreach ($name in $script:declaredInputs) {
            $section = Get-YamlSection $script:inputsBlock "  ${name}:" "`n  required:"
            $section | Should -Match 'description:' -Because "$name needs a description"
        }
    }
}

Describe 'action.yml output wiring' {
    It 'wires every output to the deploy step output of the same name' {
        foreach ($name in $script:declaredOutputs) {
            $script:outputsBlock | Should -Match "value:\s*\`$\{\{\s*steps\.deploy\.outputs\.$name\s*\}\}" `
                -Because "$name must map to steps.deploy.outputs.$name"
        }
    }

    It 'declares every output the entrypoint writes' {
        $written = @([regex]::Matches($script:entrypoint, "Write-ActionOutput\s+'([a-z0-9_]+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $written.Count | Should -BeGreaterThan 5
        $undeclared = @($written | Where-Object { $_ -notin $script:declaredOutputs })
        $undeclared -join ', ' | Should -BeNullOrEmpty
    }

    It 'writes every output it declares' {
        $written = @([regex]::Matches($script:entrypoint, "Write-ActionOutput\s+'([a-z0-9_]+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $unwritten = @($script:declaredOutputs | Where-Object { $_ -notin $written })
        $unwritten -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'module manifest' {
    It 'exports every name it lists' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'src/SwaDeploy.psd1')
        foreach ($name in $manifest.FunctionsToExport) {
            Get-Command -Name $name -Module SwaDeploy -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "$name is exported but does not resolve"
        }
    }

    It 'lists every module file that ships in src' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'src/SwaDeploy.psd1')
        $onDisk = @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'src') -Filter '*.psm1' |
                ForEach-Object { $_.Name })
        $listed = @($manifest.RootModule) + @($manifest.NestedModules)
        $unlisted = @($onDisk | Where-Object { $_ -notin $listed })
        $unlisted -join ', ' | Should -BeNullOrEmpty
    }

    It 'exports the entrypoint helpers, which live in a module so they can be tested' {
        foreach ($name in @('Get-ActionInput', 'Write-ActionOutput', 'Write-ActionSummary', 'Format-SwaSummaryTable')) {
            Get-Command -Name $name -Module SwaDeploy -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}
