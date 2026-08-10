#requires -Version 7.0
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CyberDrain
<#
    The GitHub Actions surface: reading INPUT_* variables and writing workflow commands,
    outputs and job summaries. Kept apart from the deployment modules so the entrypoint is
    thin orchestration and this layer can be tested without a runner - point GITHUB_OUTPUT
    and GITHUB_STEP_SUMMARY at temp files and assert what lands in them.
#>

Set-StrictMode -Version Latest

function Get-ActionInput {
    <#
    .SYNOPSIS
        Reads an action input from the INPUT_* environment variable GitHub sets for it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    $value = [Environment]::GetEnvironmentVariable("INPUT_$($Name.ToUpperInvariant())")
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Test-ActionFlag {
    <#
    .SYNOPSIS
        Truthiness for a boolean-ish action input.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    return (Get-ActionInput $Name) -in @('true', 'True', 'TRUE', '1', 'yes')
}

function Write-ActionOutput {
    <#
    .SYNOPSIS
        Appends a step output to GITHUB_OUTPUT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    # A newline in the value would let the rest of it be parsed as further outputs
    $safe = ($Value -replace '[\r\n]', ' ').Trim()
    if ($env:GITHUB_OUTPUT) { "$Name=$safe" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
}

function Write-ActionSummary {
    <#
    .SYNOPSIS
        Appends markdown to the job summary.
    #>
    [CmdletBinding()]
    # AllowEmptyString because blank lines are meaningful markdown separators
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    if ($env:GITHUB_STEP_SUMMARY) { ($Lines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
}

function Write-ActionError {
    <#
    .SYNOPSIS
        Emits an ::error:: annotation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    # Workflow commands are line-oriented; a raw newline would truncate the annotation
    Write-Host "::error::$($Message -replace '\r?\n', ' ')"
}

function Write-ActionWarning {
    <#
    .SYNOPSIS
        Emits a ::warning:: annotation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    Write-Host "::warning::$($Message -replace '\r?\n', ' ')"
}

function Write-ActionNotice {
    <#
    .SYNOPSIS
        Emits a ::notice:: annotation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    Write-Host "::notice::$($Message -replace '\r?\n', ' ')"
}

function Format-SwaSummaryTable {
    <#
    .SYNOPSIS
        Renders an ordered map as a two-column markdown table for the job summary.
    .DESCRIPTION
        Rows whose value is null or empty are dropped, so a caller can build one row set for
        every code path and let the missing pieces fall away rather than branching per row.
        Pipes inside a value would break the table, so they are escaped.
    .EXAMPLE
        Format-SwaSummaryTable -Title '### Deployed' -Rows ([ordered]@{ Files = 42 })
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Rows,
        [string]$Title
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Title) {
        $lines.Add($Title)
        $lines.Add('')
    }
    $lines.Add('| | |')
    $lines.Add('|---|---|')

    foreach ($key in $Rows.Keys) {
        $value = $Rows[$key]
        if ($null -eq $value) { continue }
        $text = "$value"
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        # A literal pipe would start a new column; a newline would end the row
        $text = ($text -replace '\r?\n', ' ') -replace '\|', '\|'
        $lines.Add("| **$key** | $text |")
    }

    $lines.Add('')
    return , $lines.ToArray()
}

# Exports are controlled by FunctionsToExport in SwaDeploy.psd1 so that this module and the
# others it is nested alongside present a single, explicit surface.
