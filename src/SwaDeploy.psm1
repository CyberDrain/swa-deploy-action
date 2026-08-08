#requires -Version 7.0
using namespace System.Net.Http
using namespace System.Net.Http.Headers
using namespace System.Text
using namespace System.Text.Json

Set-StrictMode -Version Latest

# Platform quotas: https://learn.microsoft.com/azure/static-web-apps/quotas
# Breaching either one makes the content server fail the deployment, so they are measured
# up front and reported to the API - understating them turns a precise rejection into an
# unexplained 'Failure during content distribution.' much later in the deployment.
$script:DefaultMaxFileCount = 15000
$script:DefaultMaxAppSizeBytes = 500MB

function ConvertTo-SwaErrorText {
    <#
    .SYNOPSIS
        Flattens a Static Web Apps error payload into a single readable line.
    .DESCRIPTION
        The content server returns errors as strings, nested objects, or arrays depending on
        where the failure happened. Interpolating those directly yields 'System.Object[]' or
        an outer message with the real cause buried underneath, so walk the known error
        properties and fall back to compressed JSON rather than dropping detail.
    .EXAMPLE
        ConvertTo-SwaErrorText -ErrorObject $response
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        $ErrorObject,

        [int]$Depth = 0
    )

    if ($null -eq $ErrorObject) { return $null }
    if ($Depth -ge 6) { return $null }

    if ($ErrorObject -is [string]) {
        $text = $ErrorObject.Trim()
        return $(if ($text) { $text } else { $null })
    }

    if ($ErrorObject -is [System.Collections.IDictionary]) {
        $ErrorObject = [pscustomobject]$ErrorObject
    } elseif ($ErrorObject -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($item in $ErrorObject) { ConvertTo-SwaErrorText -ErrorObject $item -Depth ($Depth + 1) })
        return (($items | Where-Object { $_ } | Select-Object -Unique) -join ' | ')
    }

    if ($ErrorObject -is [psobject]) {
        # Ordered general to specific so the line reads 'code: message: inner cause'
        $errorProperties = @(
            'errorCode', 'code',
            'message', 'errorMessage', 'error', 'errorDetails', 'description', 'reason',
            'innerError', 'innerErrorDetails', 'innerException', 'details', 'detail', 'exceptionMessage'
        )
        $available = $ErrorObject.PSObject.Properties.Name
        $parts = [System.Collections.Generic.List[string]]::new()

        foreach ($name in $errorProperties) {
            if ($available -notcontains $name) { continue }
            $text = ConvertTo-SwaErrorText -ErrorObject $ErrorObject.$name -Depth ($Depth + 1)
            if ($text -and -not $parts.Contains($text)) { $parts.Add($text) }
        }

        if ($parts.Count -gt 0) { return ($parts -join ': ') }

        # Nothing recognizable - emit the payload rather than silently dropping it
        try { return ($ErrorObject | ConvertTo-Json -Compress -Depth 6) } catch { return "$ErrorObject" }
    }

    return "$ErrorObject"
}

function Get-SwaStatusError {
    <#
    .SYNOPSIS
        Builds the failure message for a checkstatus response, preferring the inner error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Status,

        [string]$DeploymentStatus
    )

    # Fields that describe the deployment rather than the failure. Dropping them means a
    # response carrying no actual error falls through to the sentinel below, while any
    # unrecognized field still survives as JSON instead of being silently discarded.
    $informational = @(
        'deploymentStatus', 'siteUrl', 'stageSiteIdentifier', 'version', 'defaultHostname',
        'tenantId', 'snippetsMap', 'sku', 'environmentName', 'unhealthyRegions'
    )

    $response = $null
    if ($Status.PSObject.Properties.Name -contains 'response') { $response = $Status.response }

    $detail = $null
    if ($response) {
        $errorProps = @($response.PSObject.Properties | Where-Object {
                $informational -notcontains $_.Name -and $null -ne $_.Value -and "$($_.Value)".Trim()
            })
        if ($errorProps.Count -gt 0) {
            $filtered = [pscustomobject]@{}
            foreach ($property in $errorProps) {
                $filtered | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
            }
            $detail = ConvertTo-SwaErrorText -ErrorObject $filtered
        }
    }

    $envelopeError = $null
    if ($Status.PSObject.Properties.Name -contains 'errorMessage') { $envelopeError = $Status.errorMessage }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($detail, $envelopeError)) {
        $text = ConvertTo-SwaErrorText -ErrorObject $candidate
        if ($text -and -not $parts.Contains($text)) { $parts.Add($text) }
    }

    # Regional distribution failures name the regions here rather than in errorDetails
    if ($response -and $response.PSObject.Properties.Name -contains 'unhealthyRegions') {
        # Wrap the whole pipeline: filtering an empty list yields $null, not an empty array
        $unhealthy = @($response.unhealthyRegions | Where-Object { $_ })
        if ($unhealthy.Count -gt 0) { $parts.Add("unhealthy regions: $($unhealthy -join ', ')") }
    }

    if ($parts.Count -eq 0) {
        return "Deployment reported '$DeploymentStatus' with no error details."
    }
    return ($parts -join ' | ')
}

function Resolve-SwaContentHost {
    <#
    .SYNOPSIS
        Derives the content distribution host from a deployment token.
    .DESCRIPTION
        Ports the token parsing the official client does: the token encodes a deployment
        slice and a region id, which together name the content server that accepts uploads.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$DeploymentToken
    )

    if ([string]::IsNullOrWhiteSpace($DeploymentToken) -or $DeploymentToken.Length -lt 104) {
        throw 'Invalid deployment token: null/empty or shorter than 104 chars.'
    }

    $parts = $DeploymentToken.Split('-', 2)
    if ($parts.Count -lt 2) { throw "Invalid deployment token: missing '-' separator." }

    $prefix = $parts[0]
    $suffix = $parts[1]
    if ($prefix.Length -lt 64) { throw 'Invalid deployment token: prefix shorter than 64.' }
    if ($suffix.Length -lt 39) { throw 'Invalid deployment token: suffix shorter than 39.' }

    $slice = 0
    if ($prefix.Length -gt 64) {
        $sliceStr = $prefix.Substring(64)
        if (-not [int]::TryParse($sliceStr, [ref]$slice) -or $slice -lt 0) {
            throw "Invalid deployment token: slice part '$sliceStr' is not a non-negative integer."
        }
    }

    $regionId = -1
    $idHex = $suffix.Substring(36, 3)
    if (-not [int]::TryParse($idHex, [System.Globalization.NumberStyles]::HexNumber, $null, [ref]$regionId)) {
        throw "Invalid deployment token: cannot parse region id hex '$idHex'."
    }

    # Non-standard domains (beta/canary) that can't be derived from the pattern
    $overrides = @{
        0 = @{
            21 = 'content-msftinthk1.infrastructure.azurestaticappsbeta.net'
            26 = 'content-msftinthk1.infrastructure.azurestaticappsbeta.net'
            33 = 'content-euapbn1.infrastructure.azurestaticappscanary.net'
            34 = 'content-euapdm1.infrastructure.azurestaticappscanary.net'
        }
        1 = @{
            33 = 'content-euapbn1.infrastructure.1.azurestaticappscanary.net'
            34 = 'content-euapdm1.infrastructure.1.azurestaticappscanary.net'
        }
    }

    $regionCodeMap = @{
        0  = 'hk1'
        3  = 'am2'
        15 = 'eus2'
        16 = 'dm1'
        21 = 'msftinthk1'
        26 = 'msftinthk1'
        30 = 'wus2'
        33 = 'euapbn1'
        34 = 'euapdm1'
    }

    if ($overrides.ContainsKey($slice) -and $overrides[$slice].ContainsKey($regionId)) {
        $contentHost = $overrides[$slice][$regionId]
    } elseif ($regionCodeMap.ContainsKey($regionId)) {
        $regionCode = $regionCodeMap[$regionId]
        # Slice 0 omits the slice number from the hostname
        $contentHost = if ($slice -eq 0) {
            "content-$regionCode.infrastructure.azurestaticapps.net"
        } else {
            "content-$regionCode.infrastructure.$slice.azurestaticapps.net"
        }
    } else {
        throw "Token regionId '$regionId' is not recognized for slice '$slice'. Cannot determine content host."
    }

    return [pscustomobject]@{
        ContentHost = $contentHost.Trim()
        Slice       = $slice
        RegionId    = $regionId
    }
}

function ConvertTo-SwaEnvironmentName {
    <#
    .SYNOPSIS
        Folds a branch name into a valid Static Web Apps environment name.
    .DESCRIPTION
        Azure accepts only letters and digits here. Passing a branch through verbatim fails
        the deployment with 'The environment name provided has invalid character(s)', so
        everything else is stripped. Returns an empty string when nothing usable remains.
    .EXAMPLE
        ConvertTo-SwaEnvironmentName -Branch 'feature/new-ui'   # -> featurenewui
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Branch
    )

    return ($Branch -replace '[^0-9a-zA-Z]', '')
}

function Resolve-SwaWorkspacePath {
    <#
    .SYNOPSIS
        Resolves a user-supplied path and asserts it stays inside the workspace.
    .DESCRIPTION
        Location inputs decide what gets zipped and uploaded to a public URL, so a traversal
        like '../../.ssh' would exfiltrate runner state. Paths are normalized and rejected if
        they land outside the root. Leading separators are stripped first so '/dist' means
        workspace-relative, matching the official action.
    .EXAMPLE
        Resolve-SwaWorkspacePath -Root $env:GITHUB_WORKSPACE -Path 'app/dist' -InputName app_location
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$InputName
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $relative = $Path.Trim().TrimStart('/', '\')
    if (-not $relative) { return $rootFull }

    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootFull, $relative))

    # GetRelativePath applies the platform's own casing rules, so this is correct on
    # case-insensitive filesystems without loosening the check on case-sensitive ones
    $back = [System.IO.Path]::GetRelativePath($rootFull, $full)
    if ([System.IO.Path]::IsPathRooted($back) -or $back -eq '..' -or
        $back.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal)) {
        throw "$InputName resolves outside the workspace: '$Path'. Paths must stay within GITHUB_WORKSPACE."
    }

    return $full
}

function Get-SwaRemoteZip {
    <#
    .SYNOPSIS
        Downloads a zip to disk, streaming, with a hard cap on how much it will accept.
    .DESCRIPTION
        The cap is enforced while streaming rather than from Content-Length alone, so a server
        that understates or omits the header cannot fill the runner's disk. Query strings are
        never logged - SAS tokens live there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipUrl,
        [Parameter(Mandatory)][string]$Destination,
        [long]$MaxBytes = 1GB
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($ZipUrl, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "zip_url is not a valid absolute URL: '$ZipUrl'"
    }
    if ($uri.Scheme -notin @('https', 'http')) {
        throw "zip_url must be http or https, got '$($uri.Scheme)'."
    }
    if ($uri.Scheme -eq 'http') {
        Write-Warning "[SWA] Downloading over plain HTTP: $($uri.Host). Prefer https."
    }

    $safeUrl = "$($uri.Scheme)://$($uri.Authority)$($uri.AbsolutePath)"
    Write-Verbose "[SWA] Downloading $safeUrl"

    $http = [HttpClient]::new()
    try {
        $response = $http.GetAsync($uri, [HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Downloading $safeUrl failed with $([int]$response.StatusCode) $($response.ReasonPhrase)."
        }

        $declared = $response.Content.Headers.ContentLength
        if ($declared -and $declared -gt $MaxBytes) {
            throw "$safeUrl is $([math]::Round($declared / 1MB, 1)) MB, over the $([math]::Round($MaxBytes / 1MB, 1)) MB download limit."
        }

        $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $target = [System.IO.File]::Create($Destination)
        try {
            $buffer = [byte[]]::new(81920)
            $total = [long]0
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $read
                if ($total -gt $MaxBytes) {
                    throw "$safeUrl exceeded the $([math]::Round($MaxBytes / 1MB, 1)) MB download limit."
                }
                $target.Write($buffer, 0, $read)
            }
            Write-Verbose "[SWA] Downloaded $([math]::Round($total / 1MB, 1)) MB"
        } finally {
            $target.Dispose()
            $source.Dispose()
        }
    } finally {
        $http.Dispose()
    }
}

function New-SwaPayload {
    <#
    .SYNOPSIS
        Builds the deployment zip and measures it against the platform quotas.
    .DESCRIPTION
        Accepts a directory of built output, an existing zip, or a URL to download a zip from
        (optionally selecting a subdirectory inside it). Always returns the measured file
        count, uncompressed size and largest single file, because the content server validates
        the deployment against those numbers and only explains itself when they are accurate.
    .EXAMPLE
        New-SwaPayload -ZipUrl https://example.blob.core.windows.net/cipp/latest.zip -ZipSubdirectory out
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Only writes to a temp directory it creates and returns; the caller deletes it.')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string]$Path,

        # Zip to download and deploy, e.g. a release artifact in blob storage
        [Parameter(Mandatory, ParameterSetName = 'Url')]
        [string]$ZipUrl,

        # Subdirectory inside an existing zip to deploy, e.g. 'out'. Ignored for directories.
        [string]$ZipSubdirectory,

        # staticwebapp.config.json to inject at the payload root when it isn't already there
        [string]$ConfigFilePath,

        [long]$MaxDownloadBytes = 1GB,

        # Refuse to expand a zip that declares more than this, so a zip bomb is never inflated
        [long]$MaxAppSizeBytes = $script:DefaultMaxAppSizeBytes
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path' -and -not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-deploy-$([guid]::NewGuid().ToString('n'))"
    $null = New-Item -ItemType Directory -Path $workDir -Force
    $zipPath = Join-Path $workDir 'app.zip'

    try {
        $sourcePath = $Path
        if ($PSCmdlet.ParameterSetName -eq 'Url') {
            $sourcePath = Join-Path $workDir 'source.zip'
            Get-SwaRemoteZip -ZipUrl $ZipUrl -Destination $sourcePath -MaxBytes $MaxDownloadBytes
        }

        $item = Get-Item -LiteralPath $sourcePath
        if ($item.PSIsContainer) {
            Write-Verbose "[SWA] Packaging directory: $($item.FullName)"
            [System.IO.Compression.ZipFile]::CreateFromDirectory(
                $item.FullName, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        } else {
            Write-Verbose "[SWA] Using zip: $($item.Name)"
            $prefix = if ($ZipSubdirectory) { $ZipSubdirectory.Trim().Trim('/').Trim('\') -replace '\\', '/' } else { '' }
            if (-not $prefix -or $prefix -eq '.') {
                # A downloaded zip is already in the work directory, so move rather than copy
                if ($PSCmdlet.ParameterSetName -eq 'Url') {
                    Move-Item -LiteralPath $item.FullName -Destination $zipPath
                } else {
                    Copy-Item -LiteralPath $item.FullName -Destination $zipPath
                }
            } else {
                Copy-SwaZipSubdirectory -SourceZip $item.FullName -DestinationZip $zipPath -Prefix $prefix `
                    -MaxUncompressedBytes $MaxAppSizeBytes
            }
        }

        if ($ConfigFilePath) { Add-SwaConfigFile -ZipPath $zipPath -ConfigFilePath $ConfigFilePath }

        # Measure the finished payload (directory entries have an empty Name)
        $fileCount = 0
        $totalBytes = [long]0
        $maxFileBytes = [long]0
        $hasConfig = $false

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                $fileCount++
                $totalBytes += $entry.Length
                if ($entry.Length -gt $maxFileBytes) { $maxFileBytes = $entry.Length }
                if ($entry.FullName -eq 'staticwebapp.config.json') { $hasConfig = $true }
            }
        } finally {
            $archive.Dispose()
        }

        if ($fileCount -eq 0) { throw "No files to deploy - '$Path' produced an empty payload." }

        return [pscustomobject]@{
            ZipPath          = $zipPath
            WorkDirectory    = $workDir
            FileCount        = $fileCount
            TotalBytes       = $totalBytes
            MaxFileBytes     = $maxFileBytes
            CompressedBytes  = (Get-Item -LiteralPath $zipPath).Length
            HasConfigFile    = $hasConfig
        }
    } catch {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Copy-SwaZipSubdirectory {
    <#
    .SYNOPSIS
        Re-zips one subdirectory out of an existing zip, stripping the prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceZip,
        [Parameter(Mandatory)][string]$DestinationZip,
        [Parameter(Mandatory)][string]$Prefix,
        [long]$MaxUncompressedBytes = 0
    )

    $prefixWithSlash = "$Prefix/"
    $source = [System.IO.Compression.ZipFile]::OpenRead($SourceZip)
    try {
        # Check the declared sizes from the central directory before inflating anything.
        # This is the only path that decompresses, so it is the only zip-bomb exposure.
        if ($MaxUncompressedBytes -gt 0) {
            $declared = [long]0
            foreach ($entry in $source.Entries) { $declared += $entry.Length }
            if ($declared -gt $MaxUncompressedBytes) {
                throw ("Refusing to expand the zip: it declares $([math]::Round($declared / 1MB, 1)) MB " +
                    "uncompressed, over the $([math]::Round($MaxUncompressedBytes / 1MB, 1)) MB limit.")
            }
        }

        $matched = $false
        $destination = [System.IO.Compression.ZipFile]::Open($DestinationZip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $source.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }

                $full = $entry.FullName -replace '\\', '/'
                if (-not $full.StartsWith($prefixWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

                $relative = $full.Substring($prefixWithSlash.Length)
                if ([string]::IsNullOrWhiteSpace($relative)) { continue }
                $matched = $true

                $newEntry = $destination.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
                try { $newEntry.LastWriteTime = $entry.LastWriteTime } catch {
                    Write-Verbose "[SWA] Could not preserve timestamp for ${relative}: $($_.Exception.Message)"
                }

                $inStream = $entry.Open()
                try {
                    $outStream = $newEntry.Open()
                    try { $inStream.CopyTo($outStream) } finally { $outStream.Dispose() }
                } finally {
                    $inStream.Dispose()
                }
            }
        } finally {
            $destination.Dispose()
        }

        if (-not $matched) {
            throw "Subdirectory '$Prefix' was not found inside the zip (no entries matched prefix '$prefixWithSlash')."
        }
    } finally {
        $source.Dispose()
    }
}

function Add-SwaConfigFile {
    <#
    .SYNOPSIS
        Injects staticwebapp.config.json at the payload root if it isn't already present.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ConfigFilePath
    )

    $configFile = $ConfigFilePath
    if (Test-Path -LiteralPath $configFile -PathType Container) {
        $configFile = Join-Path $configFile 'staticwebapp.config.json'
    }
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw "config_file_location does not contain staticwebapp.config.json: $ConfigFilePath"
    }

    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $existing = $archive.GetEntry('staticwebapp.config.json')
        if ($existing) {
            Write-Verbose '[SWA] staticwebapp.config.json already at payload root; keeping it'
            return
        }
        Write-Verbose "[SWA] Adding staticwebapp.config.json from $configFile"
        $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $configFile, 'staticwebapp.config.json', [System.IO.Compression.CompressionLevel]::Optimal)
    } finally {
        $archive.Dispose()
    }
}

function Test-SwaQuota {
    <#
    .SYNOPSIS
        Returns human-readable quota violations for a measured payload.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Payload,
        [int]$MaxFileCount = $script:DefaultMaxFileCount,
        [long]$MaxAppSizeBytes = $script:DefaultMaxAppSizeBytes
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    if ($Payload.FileCount -gt $MaxFileCount) {
        $violations.Add("file count $($Payload.FileCount) exceeds the Static Web Apps limit of $MaxFileCount by $($Payload.FileCount - $MaxFileCount)")
    }
    if ($Payload.TotalBytes -gt $MaxAppSizeBytes) {
        $violations.Add("app size $([math]::Round($Payload.TotalBytes / 1MB, 1)) MB exceeds the Static Web Apps limit of $([math]::Round($MaxAppSizeBytes / 1MB, 1)) MB")
    }
    # Unary comma stops PowerShell unrolling a single violation into a bare string
    return , $violations.ToArray()
}

function Invoke-SwaDeployment {
    <#
    .SYNOPSIS
        Deploys prebuilt static content to Azure Static Web Apps using a deployment token.
    .DESCRIPTION
        Talks to the same content distribution API as the official StaticSitesClient, without
        the 1.5 GB container. Reports the payload's true file count and uncompressed size, so
        quota rejections come back naming the quota instead of surfacing later as
        'Failure during content distribution.'
    .EXAMPLE
        Invoke-SwaDeployment -DeploymentToken $token -Path ./dist
    .EXAMPLE
        Invoke-SwaDeployment -DeploymentToken $token -Path ./release.zip -ZipSubdirectory out
    .EXAMPLE
        Invoke-SwaDeployment -DeploymentToken $token -ZipUrl https://example.com/latest.zip -ZipSubdirectory out
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$DeploymentToken,

        # Directory of built output, or a .zip containing it
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string]$Path,

        # Zip to download and deploy, e.g. a release artifact in blob storage
        [Parameter(Mandatory, ParameterSetName = 'Url')]
        [string]$ZipUrl,

        [long]$MaxDownloadBytes = 1GB,

        [string]$ZipSubdirectory,
        [string]$ConfigFilePath,

        # Named/preview environment. Empty deploys to production.
        [string]$EnvironmentName,

        [string]$RepositoryUrl,
        [string]$Branch,
        [string]$BaseBranch,
        [switch]$IsPullRequest,
        [string]$PullRequestId,
        [string]$PullRequestTitle,

        [int]$PollIntervalSeconds = 2,
        [int]$MaxPollAttempts = 120,
        [int]$MaxFileCount = $script:DefaultMaxFileCount,
        [long]$MaxAppSizeBytes = $script:DefaultMaxAppSizeBytes
    )

    $tokenInfo = Resolve-SwaContentHost -DeploymentToken $DeploymentToken
    $swaHost = "https://$($tokenInfo.ContentHost)"
    $apiVersion = 'v1'
    $correlationId = ([guid]::NewGuid()).ToString()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $payloadParams = @{
        ZipSubdirectory = $ZipSubdirectory
        ConfigFilePath  = $ConfigFilePath
        MaxAppSizeBytes = $MaxAppSizeBytes
    }
    if ($PSCmdlet.ParameterSetName -eq 'Url') {
        $payloadParams.ZipUrl = $ZipUrl
        $payloadParams.MaxDownloadBytes = $MaxDownloadBytes
    } else {
        $payloadParams.Path = $Path
    }

    $payload = New-SwaPayload @payloadParams
    $quotaViolations = Test-SwaQuota -Payload $payload -MaxFileCount $MaxFileCount -MaxAppSizeBytes $MaxAppSizeBytes

    Write-Verbose ("[SWA] Payload: {0} files, {1} MB uncompressed ({2} MB zipped), largest file {3} MB" -f
        $payload.FileCount,
        [math]::Round($payload.TotalBytes / 1MB, 1),
        [math]::Round($payload.CompressedBytes / 1MB, 1),
        [math]::Round($payload.MaxFileBytes / 1MB, 1))
    if (-not $payload.HasConfigFile) {
        Write-Verbose '[SWA] No staticwebapp.config.json at payload root; platform defaults apply'
    }
    foreach ($violation in $quotaViolations) {
        Write-Warning "[SWA] Quota exceeded: $violation"
    }

    if (-not $PSCmdlet.ShouldProcess($tokenInfo.ContentHost, "Deploy $($payload.FileCount) files")) {
        Remove-Item -LiteralPath $payload.WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
        # Same shape as a real result so callers never hit a missing property under StrictMode
        return [pscustomobject]@{
            Success         = $true
            Status          = 'WhatIf'
            SiteUrl         = $null
            FileCount       = $payload.FileCount
            AppSizeBytes    = $payload.TotalBytes
            DurationSeconds = 0
            ContentHost     = $tokenInfo.ContentHost
            Correlation     = $correlationId
            QuotaViolations = $quotaViolations
        }
    }

    $http = [HttpClient]::new()
    $zipStream = $null

    # Correlate every request the way the official client does
    $buildUrl = {
        param([string]$RequestPath)
        $builder = [System.UriBuilder]::new($swaHost)
        $builder.Path = $RequestPath.TrimStart('/')
        $builder.Query = "apiVersion=$apiVersion&deploymentCorrelationId=$correlationId"
        return $builder.Uri.AbsoluteUri
    }

    $sendJson = {
        param([string]$Url, [object]$BodyObject, [ref]$RawContent)

        $json = [JsonSerializer]::Serialize($BodyObject, [JsonSerializerOptions]::new())
        $uri = [System.Uri]::new($Url)
        Write-Verbose "[SWA] POST $($uri.AbsolutePath)"

        $request = [HttpRequestMessage]::new([HttpMethod]::Post, $uri)
        $null = $request.Headers.TryAddWithoutValidation('Authorization', "token $DeploymentToken")
        $request.Content = [StringContent]::new($json, [Encoding]::UTF8, 'application/json')

        $response = $http.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($RawContent) { $RawContent.Value = $content }

        if (-not $response.IsSuccessStatusCode) {
            $reason = $content
            try {
                $parsedReason = ConvertTo-SwaErrorText -ErrorObject ($content | ConvertFrom-Json -Depth 25)
                if ($parsedReason) { $reason = $parsedReason }
            } catch {
                Write-Verbose "[SWA] Rejection body was not JSON: $($_.Exception.Message)"
            }
            throw "The content server rejected $($uri.AbsolutePath) with $($response.StatusCode). Reason: $reason"
        }

        if ([string]::IsNullOrWhiteSpace($content)) { return $null }
        $parsed = $content | ConvertFrom-Json -Depth 25

        # Quota and config rejections come back as HTTP 200 wrapping a failure envelope, so
        # the envelope has to be checked on every call or the real reason is lost and the
        # deployment only fails later with 'Failure during content distribution.'
        if ($parsed.PSObject.Properties.Name -contains 'isSuccessStatusCode' -and $parsed.isSuccessStatusCode -eq $false) {
            $reason = ConvertTo-SwaErrorText -ErrorObject $parsed
            if (-not $reason) { $reason = $content }
            throw "The content server rejected $($uri.AbsolutePath) with $($parsed.statusCode). Reason: $reason"
        }

        return $parsed
    }

    try {
        $eventInfo = [ordered]@{
            RepoUrl            = $RepositoryUrl
            IsPullRequest      = [bool]$IsPullRequest
            IsNamedEnvironment = [bool]$EnvironmentName
            PullRequestId      = $(if ($PullRequestId) { $PullRequestId } else { $null })
            PullRequestTitle   = $(if ($PullRequestTitle) { $PullRequestTitle } else { $null })
            HeadBranch         = $Branch
            BaseBranch         = $BaseBranch
            EnvironmentName    = $(if ($EnvironmentName) { $EnvironmentName } else { $null })
            TenantId           = $null
            DefaultHostname    = $null
            Slice              = $tokenInfo.Slice
        }

        # 1) validate the deployment token
        Write-Verbose "[SWA] Validating token (slice $($tokenInfo.Slice), region $($tokenInfo.RegionId), host $($tokenInfo.ContentHost))"
        $validation = & $sendJson (& $buildUrl '/api/upload/validateapitoken') $eventInfo $null
        if ($validation -and $validation.PSObject.Properties.Name -contains 'statusCode' -and
            $validation.statusCode -and $validation.statusCode -ne 200) {
            throw "Token validation returned unexpected status: $($validation.statusCode)"
        }

        # 2) request an upload slot - the server validates quotas against these numbers
        $uploadInfo = [ordered]@{
            TotalAppSizeInBytes       = $payload.TotalBytes
            ApiSizeInBytes            = 0
            HasFunctions              = $false
            HasDataApiFiles           = $false
            HasDataApiConfigFile      = $false
            DatabaseType              = ''
            HasRoutes                 = $false
            Status                    = 'RequestingUpload'
            DefaultFileType           = 'index.html'
            ApiContentHash            = $null
            ConfiguredRoles           = @()
            AppFileCount              = $payload.FileCount
            FunctionLanguage          = $null
            FunctionLanguageVersion   = $null
            ServerRenderFramework     = 'StaticWebApp'
            DeploymentProvider        = 'GitHub'
            MaxSingleFileSizeInBytes  = $payload.MaxFileBytes
            BackendStartupCommandType = 0
            ShouldDeployToWebApp      = $false
            TenantId                  = ''
            DefaultHostname           = $null
            Slice                     = $tokenInfo.Slice
        }

        $uploadRequest = & $sendJson (& $buildUrl '/api/upload/request') @{
            EventInfo   = $eventInfo
            UploadInfo  = $uploadInfo
            PollingInfo = $null
        } $null

        $sasUrl = $uploadRequest.response.packageUris.app
        $polling = $uploadRequest.response.pollingInfo
        if ([string]::IsNullOrWhiteSpace($sasUrl)) { throw 'Upload request did not return a SAS URL for app.zip.' }

        # 3) upload the zip to blob storage
        Write-Verbose "[SWA] Uploading $([math]::Round($payload.CompressedBytes / 1MB, 1)) MB"
        $zipStream = [System.IO.File]::OpenRead($payload.ZipPath)
        $blobRequest = [HttpRequestMessage]::new([HttpMethod]::Put, $sasUrl)
        $null = $blobRequest.Headers.TryAddWithoutValidation('x-ms-blob-type', 'BlockBlob')
        $null = $blobRequest.Headers.TryAddWithoutValidation('x-ms-version', '2023-11-03')
        $blobContent = [StreamContent]::new($zipStream)
        $blobContent.Headers.ContentType = [MediaTypeHeaderValue]::Parse('application/octet-stream')
        $blobContent.Headers.ContentLength = $payload.CompressedBytes
        $blobRequest.Content = $blobContent

        $blobResponse = $http.SendAsync($blobRequest, [HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $blobResponse.IsSuccessStatusCode) {
            $blobError = $blobResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Uploading app.zip failed with $($blobResponse.StatusCode): $blobError"
        }

        # 4) tell the server the upload finished
        $uploadInfo.Status = 'Succeeded'
        $pollingInfo = [ordered]@{
            DefaultHostname     = $polling.defaultHostname
            StageSiteIdentifier = $polling.stageSiteIdentifier
            Version             = $polling.version
            TenantId            = ($polling.tenantId ?? '')
            Slice               = $tokenInfo.Slice
            GitHubRepoUrl       = $RepositoryUrl
        }

        $null = & $sendJson (& $buildUrl '/api/upload/updatestatus') @{
            EventInfo   = $eventInfo
            UploadInfo  = $uploadInfo
            PollingInfo = $pollingInfo
        } $null

        # 5) poll until the content is distributed
        $statusUrl = & $buildUrl '/api/upload/checkstatus'
        $rawStatus = $null
        for ($attempt = 0; $attempt -lt $MaxPollAttempts; $attempt++) {
            Start-Sleep -Seconds $PollIntervalSeconds
            $status = & $sendJson $statusUrl $pollingInfo ([ref]$rawStatus)
            $deploymentStatus = $status.response.deploymentStatus
            Write-Verbose "[SWA] deploymentStatus=$deploymentStatus"

            if ($deploymentStatus -eq 'Succeeded') {
                $stopwatch.Stop()
                return [pscustomobject]@{
                    Success         = $true
                    Status          = $deploymentStatus
                    SiteUrl         = $status.response.siteUrl
                    FileCount       = $payload.FileCount
                    AppSizeBytes    = $payload.TotalBytes
                    DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds
                    ContentHost     = $tokenInfo.ContentHost
                    Correlation     = $correlationId
                    QuotaViolations = $quotaViolations
                }
            }

            if ($deploymentStatus -in @('Failed', 'Canceled')) {
                $stopwatch.Stop()
                $errorText = Get-SwaStatusError -Status $status -DeploymentStatus $deploymentStatus
                # Azure never names the quota that was hit, so attach what we measured
                if ($quotaViolations.Count -gt 0) {
                    $errorText = "$errorText | Likely cause: $($quotaViolations -join '; ')"
                }
                Write-Verbose "[SWA] Failure response: $rawStatus"
                return [pscustomobject]@{
                    Success         = $false
                    Status          = $deploymentStatus
                    Error           = $errorText
                    ErrorResponse   = $rawStatus
                    FileCount       = $payload.FileCount
                    AppSizeBytes    = $payload.TotalBytes
                    DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds
                    ContentHost     = $tokenInfo.ContentHost
                    Correlation     = $correlationId
                    QuotaViolations = $quotaViolations
                }
            }
        }

        $stopwatch.Stop()
        return [pscustomobject]@{
            Success         = $false
            Status          = 'TimedOut'
            Error           = "Timed out after $($MaxPollAttempts * $PollIntervalSeconds)s waiting for deployment."
            ErrorResponse   = $rawStatus
            FileCount       = $payload.FileCount
            AppSizeBytes    = $payload.TotalBytes
            DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds
            ContentHost     = $tokenInfo.ContentHost
            Correlation     = $correlationId
            QuotaViolations = $quotaViolations
        }
    } finally {
        if ($zipStream) { $zipStream.Dispose() }
        $http.Dispose()
        Remove-Item -LiteralPath $payload.WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Exports are controlled by FunctionsToExport in SwaDeploy.psd1 so that this module and the
# nested SwaBuild module share one list.
