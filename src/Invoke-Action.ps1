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
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/SwaDeploy.psd1" -Force

function Get-ActionInput {
    param([Parameter(Mandatory)][string]$Name, [string]$Default = '')
    $value = [Environment]::GetEnvironmentVariable("INPUT_$($Name.ToUpperInvariant())")
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Test-ActionFlag {
    param([Parameter(Mandatory)][string]$Name)
    return (Get-ActionInput $Name) -in @('true', 'True', 'TRUE', '1', 'yes')
}

function Write-ActionOutput {
    param([Parameter(Mandatory)][string]$Name, [string]$Value)
    # A newline in the value would let the rest of it be parsed as further outputs
    $safe = ($Value -replace '[\r\n]', ' ').Trim()
    if ($env:GITHUB_OUTPUT) { "$Name=$safe" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
}

function Write-ActionSummary {
    # AllowEmptyString because blank lines are meaningful markdown separators
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    if ($env:GITHUB_STEP_SUMMARY) { ($Lines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
}

function Write-ActionError {
    param([Parameter(Mandatory)][string]$Message)
    # Workflow commands are line-oriented; a raw newline would truncate the annotation
    Write-Host "::error::$($Message -replace '\r?\n', ' ')"
}

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
$installNode = (Get-ActionInput 'install_node' 'true') -notin @('false', 'False', 'FALSE', '0', 'no')
$verbose = Test-ActionFlag 'verbose'

# ---- reject what we cannot honour, loudly ----
if ($deploymentAction -ne 'upload') {
    throw "action '$deploymentAction' is not supported. This action only uploads content; " +
    "keep Azure/static-web-apps-deploy for 'close' (preview environment teardown)."
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
    if (Get-ActionInput $ignored) { Write-Host "::notice::$ignored is accepted but unused - this action does not comment on pull requests." }
}
if (Test-ActionFlag 'is_static_export') {
    Write-Host '::notice::is_static_export is an Oryx hint and has no effect here - point output_location at the exported folder.'
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
    if (Test-ActionFlag 'skip_app_build') {
        Write-Host 'skip_app_build is set - deploying content as-is.'
    } elseif (Test-Path -LiteralPath $appRoot -PathType Container) {
        $plan = Get-SwaBuildPlan -Path $appRoot -BuildCommand $appBuildCommand
        if ($plan.Platform -ne 'none') {
            Write-Host "::group::Build ($($plan.Platform))"
            try {
                Invoke-SwaBuild -Path $appRoot -Plan $plan -InstallNode $installNode
            } finally {
                Write-Host '::endgroup::'
            }
        } else {
            Write-Host $plan.Reason
        }
    }

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

$configPath = $null
if ($configLocation) {
    $configPath = Resolve-SwaWorkspacePath -Root $workspace -Path $configLocation -InputName 'config_file_location'
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
        Write-Host "::notice::Branch '$branch' is not a valid environment name; using '$environmentName'."
    }
    Write-Host "::notice::Deploying to preview environment '$environmentName' (production_branch is '$productionBranch')."
}

$repositoryUrl = if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY) {
    "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY"
} else { '' }

# ---- deploy ----
$deployParams = @{
    DeploymentToken = $token
    RepositoryUrl   = $repositoryUrl
    Branch          = $branch
    BaseBranch      = $baseBranch
    ErrorAction     = 'Stop'
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
try {
    $result = Invoke-SwaDeployment @deployParams
} catch {
    # Quota and config rejections surface as thrown errors carrying the server's reason -
    # keep them on the same annotated path as a returned failure
    Write-ActionError "Static Web Apps deployment failed: $($_.Exception.Message)"
    Write-ActionSummary @(
        '### ❌ Static Web Apps deployment failed',
        '',
        $_.Exception.Message,
        ''
    )
    exit 1
}

$sizeMb = [math]::Round($result.AppSizeBytes / 1MB, 1)

if ($result.Success) {
    Write-Host "::notice::Deployed $($result.FileCount) files ($sizeMb MB) in $($result.DurationSeconds)s"
    if ($result.SiteUrl) {
        $url = if ($result.SiteUrl -match '^https?://') { $result.SiteUrl } else { "https://$($result.SiteUrl)" }
        Write-ActionOutput 'static_web_app_url' $url
        Write-Host "Site: $url"
    }
    Write-ActionSummary @(
        '### ✅ Static Web Apps deployment succeeded',
        '',
        "- **Files:** $($result.FileCount)",
        "- **Size:** $sizeMb MB",
        "- **Duration:** $($result.DurationSeconds)s",
        ''
    )
    exit 0
}

# Failure - lead with the reason, keep the context Azure support asks for
Write-ActionError "Static Web Apps deployment failed ($($result.Status)): $($result.Error)"
foreach ($violation in $result.QuotaViolations) { Write-ActionError "Quota: $violation" }

Write-ActionSummary @(
    '### ❌ Static Web Apps deployment failed',
    '',
    "**$($result.Status):** $($result.Error)",
    '',
    "- **Files:** $($result.FileCount)",
    "- **Size:** $sizeMb MB",
    "- **Content host:** $($result.ContentHost)",
    "- **Correlation ID:** $($result.Correlation)",
    ''
)
if ($result.ErrorResponse) { Write-Host "Raw response: $($result.ErrorResponse)" }
exit 1
