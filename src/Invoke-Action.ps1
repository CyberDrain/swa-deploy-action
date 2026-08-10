#requires -Version 7.0
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CyberDrain
<#
.SYNOPSIS
    GitHub Action entrypoint - maps Azure/static-web-apps-deploy inputs onto SwaDeploy.
.DESCRIPTION
    Reads the INPUT_* environment variables GitHub sets for action inputs, validates the ones
    this action cannot honour (anything requiring an Oryx build or managed Functions), and
    deploys the prebuilt content.

    Everything runs inside one try/catch so that every failure - a rejected input, a broken
    build, a refused deployment - lands as an ::error:: annotation and a job summary. A raw
    PowerShell error record scrolling past in the log is not an error report.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/SwaDeploy.psd1" -Force

$totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
$buildSeconds = 0.0
$environmentName = ''
$result = $null
$exitCode = 1

# Named so a failure annotation says which stage broke rather than only what broke
$phase = 'Input validation'

function Write-DeploymentOutput {
    <#
    .SYNOPSIS
        Writes every step output, on the failure paths as well as the success path.
    .DESCRIPTION
        A failed run is when correlation_id and deployment_status are worth the most, so they
        are written before the non-zero exit. Consumers need if: always() to read them.
    #>
    param(
        $Result,
        [Parameter(Mandatory)][string]$Status,
        [double]$BuildSeconds = 0,
        [double]$TotalSeconds = 0,
        [string]$EnvironmentName = ''
    )

    Write-ActionOutput 'deployment_status' $Status
    Write-ActionOutput 'deployment_environment' $EnvironmentName
    Write-ActionOutput 'build_duration_seconds' ([math]::Round($BuildSeconds, 1))
    Write-ActionOutput 'total_duration_seconds' ([math]::Round($TotalSeconds, 1))

    if (-not $Result) { return }

    $siteUrl = Get-SwaProperty -InputObject $Result -Name 'SiteUrl' -Default ''
    if ($siteUrl) { Write-ActionOutput 'static_web_app_url' $siteUrl }

    Write-ActionOutput 'file_count' (Get-SwaProperty -InputObject $Result -Name 'FileCount' -Default 0)
    Write-ActionOutput 'app_size_bytes' (Get-SwaProperty -InputObject $Result -Name 'AppSizeBytes' -Default 0)
    Write-ActionOutput 'compressed_size_bytes' (Get-SwaProperty -InputObject $Result -Name 'CompressedBytes' -Default 0)
    Write-ActionOutput 'has_config_file' ([string](Get-SwaProperty -InputObject $Result -Name 'HasConfigFile' -Default $false)).ToLowerInvariant()
    Write-ActionOutput 'deploy_duration_seconds' (Get-SwaProperty -InputObject $Result -Name 'DurationSeconds' -Default 0)
    Write-ActionOutput 'correlation_id' (Get-SwaProperty -InputObject $Result -Name 'Correlation' -Default '')
}

function Format-ConfigRow {
    <#
    .SYNOPSIS
        One line describing whether the deployment carries its routing and auth rules.
    #>
    param($Result)

    if (-not (Get-SwaProperty -InputObject $Result -Name 'HasConfigFile' -Default $false)) {
        return '⚠️ **missing** - platform defaults apply, so every route is served anonymously'
    }

    $report = Get-SwaProperty -InputObject $Result -Name 'ConfigReport'
    if (-not $report) { return '`staticwebapp.config.json` present' }
    if (-not $report.IsValidJson) {
        return "⚠️ present but **not valid JSON** ($($report.ParseError)) - Azure will not apply it"
    }

    $parts = @("$($report.RouteCount) routes", "$($report.ProtectedRouteCount) role-protected")
    if ($report.Roles.Count -gt 0) { $parts += "roles: $($report.Roles -join ', ')" }
    if ($report.NavigationFallback) { $parts += "fallback: $($report.NavigationFallback)" }
    # Doubled backticks: a single one escapes the next character in a double-quoted string
    return "``staticwebapp.config.json`` - $($parts -join ', ')"
}

try {
    # ---- inputs ----
    $token = Get-ActionInput 'azure_static_web_apps_api_token'
    if (-not $token) { throw 'azure_static_web_apps_api_token is required.' }

    # Secrets are masked automatically; a token passed any other way is not, so register it
    Write-Host "::add-mask::$token"

    $deploymentAction = Get-ActionInput 'action' 'upload'
    $appLocation = Get-ActionInput 'app_location' '/'
    $outputLocation = Get-ActionInput 'output_location'
    $artifactLocation = Get-ActionInput 'app_artifact_location'
    $configLocation = Get-ActionInput 'config_file_location'
    $environmentName = Get-ActionInput 'deployment_environment'
    $productionBranch = Get-ActionInput 'production_branch'
    $appBuildCommand = Get-ActionInput 'app_build_command'
    $zipUrl = Get-ActionInput 'zip_url'
    $zipSubdirectory = Get-ActionInput 'zip_subdirectory'
    $maxDownloadMb = Get-ActionInput 'max_download_mb' '1024'
    $requireConfigFile = (Get-ActionInput 'require_config_file' 'warn').ToLowerInvariant()
    $installNode = (Get-ActionInput 'install_node' 'true') -notin @('false', 'False', 'FALSE', '0', 'no')
    $verbose = Test-ActionFlag 'verbose'

    # ---- reject what we cannot honour, loudly ----
    if ($deploymentAction -ne 'upload') {
        throw "action '$deploymentAction' is not supported. This action only uploads content; " +
        "keep Azure/static-web-apps-deploy for 'close' (preview environment teardown)."
    }
    if ($requireConfigFile -notin @('off', 'warn', 'error')) {
        throw "require_config_file must be 'off', 'warn' or 'error', got '$requireConfigFile'."
    }
    foreach ($unsupported in @('api_location', 'data_api_location', 'api_build_command')) {
        if (Get-ActionInput $unsupported) {
            throw "$unsupported is not supported - managed Azure Functions and the Data API need the " +
            'official action. Static content only.'
        }
    }
    if (Get-ActionInput 'routes_location') {
        throw 'routes_location is not supported - routes.json is deprecated. Use config_file_location ' +
        'with staticwebapp.config.json.'
    }
    foreach ($ignored in @('repo_token', 'github_id_token')) {
        if (Get-ActionInput $ignored) { Write-ActionNotice "$ignored is accepted but unused - this action does not comment on pull requests." }
    }
    if (Test-ActionFlag 'is_static_export') {
        Write-ActionNotice 'is_static_export is an Oryx hint and has no effect here - point output_location at the exported folder.'
    }

    if ($zipSubdirectory -and ($zipSubdirectory -split '[/\\]') -contains '..') {
        throw "zip_subdirectory must not contain '..': '$zipSubdirectory'"
    }

    $workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
    $contentPath = $null

    if ($zipUrl) {
        # Deploying a prebuilt artifact from a URL - nothing local to build or resolve
        if ($appBuildCommand) { throw 'zip_url and app_build_command cannot be combined - the download is already built.' }
        Write-Host "Deploying from zip_url (max ${maxDownloadMb} MB)."
    } else {
        # ---- resolve locations, refusing anything that escapes the workspace ----
        $appRoot = Resolve-SwaWorkspacePath -Root $workspace -Path $appLocation -InputName 'app_location'

        if (-not (Test-Path -LiteralPath $appRoot)) {
            throw "app_location not found: $appRoot"
        }

        # ---- build, using the runner's own toolchain instead of an Oryx image ----
        $phase = 'Build'
        if (Test-ActionFlag 'skip_app_build') {
            Write-Host 'skip_app_build is set - deploying content as-is.'
        } elseif (Test-Path -LiteralPath $appRoot -PathType Container) {
            $plan = Get-SwaBuildPlan -Path $appRoot -BuildCommand $appBuildCommand
            if ($plan.Platform -ne 'none') {
                $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()
                Write-Host "::group::Build ($($plan.Platform))"
                try {
                    Invoke-SwaBuild -Path $appRoot -Plan $plan -InstallNode $installNode
                } finally {
                    $buildWatch.Stop()
                    $buildSeconds = $buildWatch.Elapsed.TotalSeconds
                    Write-Host '::endgroup::'
                    Write-Host "Build finished in $([math]::Round($buildSeconds, 1))s"
                }
            } else {
                Write-Host $plan.Reason
            }
        }

        $phase = 'Content resolution'
        $built = $outputLocation
        if (-not $built) { $built = $artifactLocation }
        $contentPath = if ($built) {
            # Relative to app_location, which is itself already confined to the workspace
            Resolve-SwaWorkspacePath -Root $appRoot -Path $built -InputName 'output_location'
        } else { $appRoot }

        if (-not (Test-Path -LiteralPath $contentPath)) {
            throw "Content path not found: $contentPath (app_location='$appLocation', output_location='$built'). " +
            'Check that the build produced output there.'
        }
    }

    $phase = 'Configuration'
    $configPath = $null
    if ($configLocation) {
        $configPath = Resolve-SwaConfigFilePath -WorkspaceRoot $workspace -ConfigFileLocation $configLocation
    } elseif (-not $zipUrl) {
        $configPath = Resolve-SwaConfigFilePath -WorkspaceRoot $workspace -AppLocation $appLocation
    }

    # The zip is built from the content directory, so the config has to be at its root before
    # packaging - output_location usually points at a build folder like dist while the config
    # stays at app_location. Once it is there the payload carries it and there is nothing left
    # to inject into the finished zip.
    #
    # Whether the payload really ended up with one is not decided here: New-SwaPayload reads
    # the finished zip, which is the only answer that holds for a downloaded zip too.
    if ($configPath -and $contentPath -and (Test-Path -LiteralPath $contentPath -PathType Container)) {
        $copied = Copy-SwaConfigFile -ConfigFilePath $configPath -DestinationRoot $contentPath
        if ($copied) {
            Write-Host "Copied staticwebapp.config.json from $configPath to the output root $contentPath"
        } else {
            Write-Host "staticwebapp.config.json is already at the output root $contentPath - keeping it."
        }
        $configPath = $null
    } elseif ($configPath) {
        # A zip rather than a directory, so it gets injected at the payload root instead
        Write-Host "staticwebapp.config.json will be added to the payload root from $configPath"
    }

    # ---- environment / PR context ----
    $branch = $env:GITHUB_HEAD_REF
    if (-not $branch) { $branch = ($env:GITHUB_REF_NAME ?? '') }
    $baseBranch = $env:GITHUB_BASE_REF
    if (-not $baseBranch) { $baseBranch = $productionBranch }
    $isPullRequest = $env:GITHUB_EVENT_NAME -eq 'pull_request'

    # A non-production branch is a preview environment when production_branch is declared
    if (-not $environmentName -and $productionBranch -and $branch -and $branch -ne $productionBranch) {
        # Azure only accepts 0-9a-zA-Z here, so a branch like 'feature/new-ui' has to be folded
        # down or the content server rejects the deployment outright
        $environmentName = ConvertTo-SwaEnvironmentName -Branch $branch
        if (-not $environmentName) {
            throw "Cannot derive an environment name from branch '$branch' - it has no alphanumeric " +
            'characters. Set deployment_environment explicitly.'
        }
        if ($environmentName -ne $branch) {
            Write-ActionNotice "Branch '$branch' is not a valid environment name; using '$environmentName'."
        }
        Write-ActionNotice "Deploying to preview environment '$environmentName' (production_branch is '$productionBranch')."
    }

    $repositoryUrl = if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY) {
        "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY"
    } else { '' }

    # ---- deploy ----
    $phase = 'Deployment'
    $deployParams = @{
        DeploymentToken   = $token
        RepositoryUrl     = $repositoryUrl
        Branch            = $branch
        BaseBranch        = $baseBranch
        RequireConfigFile = $requireConfigFile
        ErrorAction       = 'Stop'
    }
    if ($zipUrl) {
        $deployParams.ZipUrl = $zipUrl
        $deployParams.MaxDownloadBytes = [long]$maxDownloadMb * 1MB
    } else {
        $deployParams.Path = $contentPath
    }
    if ($zipSubdirectory) { $deployParams.ZipSubdirectory = $zipSubdirectory }
    if ($configPath) { $deployParams.ConfigFilePath = $configPath }
    if ($environmentName) { $deployParams.EnvironmentName = $environmentName }
    if ($isPullRequest) {
        $deployParams.IsPullRequest = $true
        if ($env:GITHUB_REF_NAME) { $deployParams.PullRequestId = ($env:GITHUB_REF_NAME -split '/')[0] }
    }
    if ($verbose) { $deployParams.Verbose = $true }

    Write-Host "Deploying $(if ($zipUrl) { 'downloaded zip' } else { $contentPath }) to Azure Static Web Apps..."
    $result = Invoke-SwaDeployment @deployParams

    $phase = 'Reporting'
    $totalWatch.Stop()
    $sizeMb = [math]::Round($result.AppSizeBytes / 1MB, 1)
    $zippedMb = [math]::Round($result.CompressedBytes / 1MB, 1)
    $environmentLabel = if ($result.EnvironmentName) { $result.EnvironmentName } else { 'production' }

    # Anything plainly not web content, and a missing config, are worth an annotation rather
    # than a log line - they are the failures nobody notices until production
    foreach ($warning in $result.PayloadWarnings) { Write-ActionWarning $warning }
    if (-not $result.HasConfigFile -and $requireConfigFile -ne 'off') {
        Write-ActionWarning ('No staticwebapp.config.json at the payload root. Azure applies platform ' +
            'defaults, so routes and allowedRoles are not enforced and every path is served anonymously.')
    }

    $rows = [ordered]@{
        'URL'         = $(if ($result.SiteUrl) { $result.SiteUrl } else { $null })
        'Environment' = $environmentLabel
        'Files'       = $result.FileCount
        'Size'        = "$sizeMb MB uncompressed / $zippedMb MB zipped"
        'Config'      = (Format-ConfigRow -Result $result)
        'Build'       = $(if ($buildSeconds -gt 0) { "$([math]::Round($buildSeconds, 1))s" } else { $null })
        'Deploy'      = "$($result.PackageSeconds)s package / $($result.UploadSeconds)s upload / $($result.PollSeconds)s distribute"
        'Total'       = "$([math]::Round($totalWatch.Elapsed.TotalSeconds, 1))s"
    }

    if ($result.Success) {
        Write-ActionNotice "Deployed $($result.FileCount) files ($sizeMb MB) in $($result.DurationSeconds)s"
        if ($result.SiteUrl) {
            Write-ActionOutput 'static_web_app_url' $result.SiteUrl
            Write-Host "Site: $($result.SiteUrl)"
        }

        Write-ActionSummary (Format-SwaSummaryTable -Title '### ✅ Static Web Apps deployment succeeded' -Rows $rows)
        if ($result.PayloadWarnings.Count -gt 0) {
            Write-ActionSummary (@('<details><summary>⚠️ Payload warnings</summary>', '') +
                ($result.PayloadWarnings | ForEach-Object { "- $_" }) + @('', '</details>', ''))
        }
        # Useful when something goes wrong later, noise on a green run
        Write-ActionSummary @(
            '<details><summary>Deployment details</summary>', '',
            "- **Content host:** $($result.ContentHost)",
            "- **Correlation ID:** $($result.Correlation)",
            '', '</details>', ''
        )
    } else {
        Write-ActionError "Static Web Apps deployment failed ($($result.Status)): $($result.Error)"
        foreach ($violation in $result.QuotaViolations) { Write-ActionError "Quota: $violation" }

        # Lead with the reason, keep the context Azure support asks for
        $failureRows = [ordered]@{ 'Status' = $result.Status; 'Error' = $result.Error }
        foreach ($key in $rows.Keys) { $failureRows[$key] = $rows[$key] }
        $failureRows['Quota'] = $(if ($result.QuotaViolations.Count -gt 0) { $result.QuotaViolations -join '; ' } else { $null })
        $failureRows['Content host'] = $result.ContentHost
        $failureRows['Correlation ID'] = $result.Correlation

        Write-ActionSummary (Format-SwaSummaryTable -Title '### ❌ Static Web Apps deployment failed' -Rows $failureRows)
        if ($result.ErrorResponse) { Write-Host "Raw response: $($result.ErrorResponse)" }
    }

    Write-DeploymentOutput -Result $result -Status $result.Status -BuildSeconds $buildSeconds `
        -TotalSeconds $totalWatch.Elapsed.TotalSeconds -EnvironmentName $result.EnvironmentName

    $exitCode = if ($result.Success) { 0 } else { 1 }
} catch {
    $totalWatch.Stop()
    Write-ActionError "$phase failed: $($_.Exception.Message)"

    Write-ActionSummary (Format-SwaSummaryTable -Title '### ❌ Static Web Apps deployment failed' -Rows ([ordered]@{
                'Stage' = $phase
                'Error' = $_.Exception.Message
                'Total' = "$([math]::Round($totalWatch.Elapsed.TotalSeconds, 1))s"
            }))

    # 'Error' rather than a deployment status: this never got far enough to have one
    Write-DeploymentOutput -Result $result -Status 'Error' -BuildSeconds $buildSeconds `
        -TotalSeconds $totalWatch.Elapsed.TotalSeconds -EnvironmentName $environmentName

    $exitCode = 1
}

exit $exitCode
