#requires -Version 7.0
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CyberDrain
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

# staticwebapp.config.json is read out of the payload before the quota check runs, and for a
# downloaded zip that happens without the archive ever having been inflated. A routing file
# does not approach this; a zip bomb entry named like one does.
$script:MaxConfigFileBytes = 8MB

function Get-SwaProperty {
    <#
    .SYNOPSIS
        Reads a property that may not be there, without tripping StrictMode.
    .DESCRIPTION
        Under Set-StrictMode -Version Latest a missing property is a terminating
        PropertyNotFoundException, so an optimistic chain over an API response reports a
        changed payload shape as a PowerShell internal - and does it before the friendly
        guard written to catch exactly that case can run.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $Default }
        $value = $InputObject[$Name]
    } else {
        # Indexed rather than '.Properties.Name -contains': on an object with no properties
        # at all - '{}' from the API, say - enumerating .Name off the empty collection is
        # itself a StrictMode error, which is the exact failure this function exists to stop
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property) { return $Default }
        $value = $property.Value
    }

    if ($null -eq $value) { return $Default }
    return $value
}

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
        # @() around it: on an object with no properties, enumerating .Name off the empty
        # collection is itself a StrictMode error
        $available = @($ErrorObject.PSObject.Properties | ForEach-Object { $_.Name })
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

    $response = Get-SwaProperty -InputObject $Status -Name 'response'

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

    $envelopeError = Get-SwaProperty -InputObject $Status -Name 'errorMessage'

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($detail, $envelopeError)) {
        $text = ConvertTo-SwaErrorText -ErrorObject $candidate
        if ($text -and -not $parts.Contains($text)) { $parts.Add($text) }
    }

    # Regional distribution failures name the regions here rather than in errorDetails
    if ($response) {
        # Wrap the whole pipeline: filtering an empty list yields $null, not an empty array
        $unhealthy = @((Get-SwaProperty -InputObject $response -Name 'unhealthyRegions' -Default @()) | Where-Object { $_ })
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

function Resolve-SwaConfigFilePath {
    <#
    .SYNOPSIS
        Resolves staticwebapp.config.json from an explicit location or app_location.
    .DESCRIPTION
        staticwebapp.config.json carries routing and security policy. When output_location
        points at built files in a child folder like dist, the config commonly stays at
        app_location and must still be copied into the deployment payload root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$AppLocation,
        [string]$ConfigFileLocation
    )

    if ($ConfigFileLocation) {
        return Resolve-SwaWorkspacePath -Root $WorkspaceRoot -Path $ConfigFileLocation -InputName 'config_file_location'
    }

    if (-not $AppLocation) { return $null }

    $appRoot = Resolve-SwaWorkspacePath -Root $WorkspaceRoot -Path $AppLocation -InputName 'app_location'
    $defaultConfig = Join-Path $appRoot 'staticwebapp.config.json'
    if (Test-Path -LiteralPath $defaultConfig -PathType Leaf) {
        return $defaultConfig
    }

    return $null
}

function Invoke-SwaWithRetry {
    <#
    .SYNOPSIS
        Runs a scriptblock, retrying only failures that look transient.
    .DESCRIPTION
        A deployment is a handful of calls with no cheap way to resume, so a single dropped
        connection or 503 on the way through would otherwise cost the whole job. Only signals
        that plausibly succeed on a second attempt are retried: connection faults, timeouts
        and the transient HTTP statuses. A rejection the server meant - a quota breach, a bad
        token, a malformed config - is raised immediately, because retrying turns a precise
        two-second failure into a slow one.
    .EXAMPLE
        Invoke-SwaWithRetry -Operation 'upload app.zip' -ScriptBlock { $client.Send($request) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Operation = 'request',
        [int]$MaxAttempts = 4,
        [double]$BaseDelaySeconds = 2,

        # Seam for tests: replaced with a no-op so backoff costs nothing
        [scriptblock]$WaitAction = { param([double]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    for ($attempt = 1; ; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            $retryable = Test-SwaTransientFailure -ErrorRecord $_
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }

            # Jitter keeps a matrix fan-out from retrying in lockstep against one region,
            # which is how a single 429 becomes a throttling storm
            $delay = [math]::Min($BaseDelaySeconds * [math]::Pow(2, $attempt - 1), 30)
            $delay += (Get-Random -Minimum 0.0 -Maximum 1.0)
            $hint = Get-SwaRetryAfterDelay -ErrorRecord $_
            if ($hint -gt 0) { $delay = [math]::Min($hint, 60) }

            Write-Warning ("[SWA] {0} failed (attempt {1}/{2}): {3}. Retrying in {4}s." -f
                $Operation, $attempt, $MaxAttempts, $_.Exception.Message, [math]::Round($delay, 1))
            & $WaitAction $delay
        }
    }
}

function Invoke-SwaHttpRequest {
    <#
    .SYNOPSIS
        Sends an HTTP request with its own timeout budget, retrying transient failures.
    .DESCRIPTION
        RequestFactory is invoked once per attempt rather than taking a ready-made message:
        an HttpRequestMessage cannot be sent twice, and a retried blob upload has to re-open
        the zip at offset zero rather than resume from wherever the failed attempt stopped.

        Each attempt gets its own CancellationTokenSource instead of a client-wide timeout,
        because one deadline cannot cover both a 2 KB JSON POST and a 300 MB upload. Blowing
        that budget is deliberately not treated as transient - waiting longer will not help.

        A transient status is a response, not an exception, so it is raised as one to reach
        the retry loop. When the attempts run out the last response is handed back rather than
        thrown, leaving the caller to render the server's own reason as it would have anyway.
    #>
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpResponseMessage])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Used inside the retry scriptblock, which the analyzer does not follow.')]
    param(
        [Parameter(Mandatory)][HttpClient]$Client,
        [Parameter(Mandatory)][scriptblock]$RequestFactory,
        [Parameter(Mandatory)][string]$Operation,
        [int]$TimeoutSeconds = 100,
        [int]$MaxAttempts = 4,
        [HttpCompletionOption]$CompletionOption = [HttpCompletionOption]::ResponseContentRead,

        # Empty disables status-based retry, for a call that must not be repeated once it lands
        [int[]]$RetryStatusCodes = @(408, 429, 500, 502, 503, 504),

        [scriptblock]$WaitAction = { param([double]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    # A hashtable rather than a plain variable: a scriptblock assignment would land in the
    # scriptblock's own scope and never reach us
    $state = @{ LastResponse = $null }

    try {
        return Invoke-SwaWithRetry -Operation $Operation -MaxAttempts $MaxAttempts -WaitAction $WaitAction -ScriptBlock {
            # Cleared before the factory runs, not after: a factory that throws on a retry -
            # the zip vanishing under a re-open, say - must not leave the previous attempt's
            # 503 behind for the outer catch to return in place of the real error
            if ($state.LastResponse) { $state.LastResponse.Dispose(); $state.LastResponse = $null }

            $request = & $RequestFactory
            $cancellation = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
            try {
                try {
                    $response = $Client.SendAsync($request, $CompletionOption, $cancellation.Token).GetAwaiter().GetResult()
                } catch [System.OperationCanceledException] {
                    if ($cancellation.IsCancellationRequested) {
                        throw "$Operation timed out after ${TimeoutSeconds}s."
                    }
                    throw
                }

                if ($RetryStatusCodes -contains [int]$response.StatusCode) {
                    $state.LastResponse = $response
                    $hint = ''
                    if ($response.Headers.RetryAfter -and $response.Headers.RetryAfter.Delta) {
                        $hint = " Retry-After: $([int]$response.Headers.RetryAfter.Delta.TotalSeconds)"
                    }
                    throw "$Operation returned $([int]$response.StatusCode) $($response.ReasonPhrase).$hint"
                }

                return $response
            } finally {
                # Disposes the request's content too, which for an upload is the file stream
                $request.Dispose()
                $cancellation.Dispose()
            }
        }
    } catch {
        # Out of attempts on a status the server may yet recover from - let the caller read it
        if ($state.LastResponse) { return $state.LastResponse }
        throw
    }
}

function Test-SwaTransientFailure {
    <#
    .SYNOPSIS
        Decides whether a failure is worth another attempt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($exception) {
        if ($exception -is [System.Net.Http.HttpRequestException] -or
            $exception -is [System.Net.Sockets.SocketException] -or
            $exception -is [System.IO.IOException] -or
            $exception -is [System.TimeoutException] -or
            $exception -is [System.Threading.Tasks.TaskCanceledException] -or
            $exception -is [System.OperationCanceledException]) {
            return $true
        }
        $exception = $exception.InnerException
    }

    # The content server's own rejections are raised as plain messages carrying the status,
    # so the status is what separates 'try again' from 'this will never work'
    $message = "$($ErrorRecord.Exception.Message)"
    if ($message -match '\b(408|429|500|502|503|504)\b') { return $true }
    if ($message -match '(?i)\b(RequestTimeout|TooManyRequests|InternalServerError|BadGateway|ServiceUnavailable|GatewayTimeout|ServerBusy|OperationTimedOut)\b') { return $true }

    return $false
}

function Get-SwaRetryAfterDelay {
    <#
    .SYNOPSIS
        Pulls a Retry-After hint out of a failure message, when the server sent one.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)]$ErrorRecord)

    if ("$($ErrorRecord.Exception.Message)" -match '(?i)retry[- ]after[:= ]+(\d+)') {
        return [double]$Matches[1]
    }
    return 0
}

function Get-SwaConfigReport {
    <#
    .SYNOPSIS
        Parses staticwebapp.config.json and reports its routing and authentication posture.
    .DESCRIPTION
        The config carries the route rules and allowedRoles that keep an authenticated site
        closed. Reporting what it actually contains turns an accidentally wide-open deployment
        into something visible in the run instead of something discovered in production, and
        gives the upload request real values for HasRoutes and ConfiguredRoles.

        Comments and trailing commas are tolerated. ConvertFrom-Json rejects both outright,
        and hand-maintained configs carry them often enough that failing on one would block a
        deployment Azure would have accepted. A parse failure that survives even the tolerant
        reader is reported rather than thrown, so the caller decides how fatal it is - but
        either way Azure would not apply the rules, which is the case require_config_file
        exists to catch.
    .EXAMPLE
        Get-SwaConfigReport -ConfigFilePath ./dist/staticwebapp.config.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ConfigFilePath
    )

    $report = [ordered]@{
        Path                = $ConfigFilePath
        IsValidJson         = $false
        ParseError          = $null
        HasRoutes           = $false
        RouteCount          = 0
        ProtectedRouteCount = 0
        Roles               = @()
        NavigationFallback  = $null
    }

    $raw = Get-Content -LiteralPath $ConfigFilePath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $report.ParseError = 'the file is empty'
        return [pscustomobject]$report
    }

    try {
        $config = $raw | ConvertFrom-Json -Depth 25
    } catch {
        # Fall back to the tolerant reader before giving up - a // comment is a style choice,
        # not a reason to block a deployment
        try {
            $options = [JsonDocumentOptions]::new()
            $options.CommentHandling = [JsonCommentHandling]::Skip
            $options.AllowTrailingCommas = $true
            $document = [JsonDocument]::Parse($raw, $options)
            try {
                $config = [JsonSerializer]::Serialize($document.RootElement, [JsonSerializerOptions]::new()) |
                    ConvertFrom-Json -Depth 25
            } finally {
                $document.Dispose()
            }
        } catch {
            $report.ParseError = $_.Exception.Message
            return [pscustomobject]$report
        }
    }

    $report.IsValidJson = $true

    # -Default @() matters: @($null) is a one-element array, which would report a config with
    # no routes at all as having one
    $routes = @(Get-SwaProperty -InputObject $config -Name 'routes' -Default @())
    $report.RouteCount = $routes.Count
    $report.HasRoutes = $routes.Count -gt 0

    # anonymous and authenticated are platform built-ins; only custom roles get provisioned,
    # and only anonymous leaves a route open
    $builtIn = @('anonymous', 'authenticated')
    $roles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $protected = 0

    foreach ($route in $routes) {
        $allowed = @(Get-SwaProperty -InputObject $route -Name 'allowedRoles' -Default @()) | Where-Object { $_ }
        if (@($allowed | Where-Object { $_ -ne 'anonymous' }).Count -gt 0) { $protected++ }
        foreach ($role in $allowed) {
            if ($role -notin $builtIn) { $null = $roles.Add($role) }
        }
    }

    $report.ProtectedRouteCount = $protected
    $report.Roles = @($roles | Sort-Object)

    $fallback = Get-SwaProperty -InputObject $config -Name 'navigationFallback'
    if ($fallback) {
        $rewrite = Get-SwaProperty -InputObject $fallback -Name 'rewrite'
        $report.NavigationFallback = if ($rewrite) { $rewrite } else { '(configured)' }
    }

    return [pscustomobject]$report
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
        [long]$MaxBytes = 1GB,

        # The .NET default of 100s covers the body as well as the headers, so a large artifact
        # on an ordinary runner link is cancelled mid-stream with nothing to explain it
        [int]$TimeoutSeconds = 1800
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
    $http.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
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

        # Measure the finished payload (directory entries have an empty Name). Reading the zip
        # rather than the source tree makes this the one place that knows what is really being
        # deployed, whichever way the payload was assembled.
        $fileCount = 0
        $totalBytes = [long]0
        $maxFileBytes = [long]0
        $hasConfig = $false
        $configReport = $null
        $gitFiles = 0
        $nodeModulesFiles = 0
        $workflowFiles = 0
        $envFiles = [System.Collections.Generic.List[string]]::new()

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                $fileCount++
                $totalBytes += $entry.Length
                if ($entry.Length -gt $maxFileBytes) { $maxFileBytes = $entry.Length }

                if ($entry.FullName -eq 'staticwebapp.config.json') {
                    $hasConfig = $true
                    # A downloaded zip reaches here without ever being inflated, so its
                    # declared size is checked before extracting - the config is a routing
                    # file, and anything claiming to be larger than this is not one
                    if ($entry.Length -gt $script:MaxConfigFileBytes) {
                        $configReport = [pscustomobject]@{
                            Path = $null; IsValidJson = $false; HasRoutes = $false
                            RouteCount = 0; ProtectedRouteCount = 0; Roles = @(); NavigationFallback = $null
                            ParseError = ("it declares $([math]::Round($entry.Length / 1MB, 1)) MB, over the " +
                                "$([math]::Round($script:MaxConfigFileBytes / 1MB, 1)) MB limit for a config file")
                        }
                    } else {
                        # Extract while the archive is open - entries are invalid once it closes
                        $extracted = Join-Path $workDir 'staticwebapp.config.json'
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $extracted, $true)
                        $configReport = Get-SwaConfigReport -ConfigFilePath $extracted
                    }
                }

                # Everything under the content root ships and is served publicly, so anything
                # that is plainly not web content is worth naming before it is uploaded
                if ($entry.FullName -like '.git/*') { $gitFiles++ }
                elseif ($entry.FullName -like '.github/*') { $workflowFiles++ }
                if ($entry.FullName -match '(^|/)node_modules/') { $nodeModulesFiles++ }
                if ($entry.Name -match '^\.env($|\.)') { $envFiles.Add($entry.FullName) }
            }
        } finally {
            $archive.Dispose()
        }

        if ($fileCount -eq 0) { throw "No files to deploy - '$Path' produced an empty payload." }

        $warnings = [System.Collections.Generic.List[string]]::new()
        $countFiles = { param([int]$N) "$N file$(if ($N -ne 1) { 's' })" }
        if ($gitFiles -gt 0) {
            $warnings.Add("the payload contains .git ($(& $countFiles $gitFiles)) - repository history would be served publicly. Point output_location at the build folder.")
        }
        if ($nodeModulesFiles -gt 0) {
            $warnings.Add("the payload contains node_modules ($(& $countFiles $nodeModulesFiles)) - this counts against the 15,000 file quota. Point output_location at the build folder.")
        }
        if ($workflowFiles -gt 0) {
            $warnings.Add("the payload contains .github ($(& $countFiles $workflowFiles)) - workflow definitions would be served publicly.")
        }
        foreach ($envFile in $envFiles) {
            $warnings.Add("the payload contains '$envFile' - environment files are served publicly and often hold secrets.")
        }

        return [pscustomobject]@{
            ZipPath         = $zipPath
            WorkDirectory   = $workDir
            FileCount       = $fileCount
            TotalBytes      = $totalBytes
            MaxFileBytes    = $maxFileBytes
            CompressedBytes = (Get-Item -LiteralPath $zipPath).Length
            HasConfigFile   = $hasConfig
            ConfigReport    = $configReport
            # No unary comma: a hashtable value is not unrolled, and ', @()' would wrap the
            # empty array in a one-element array that iterates once with nothing in it
            Warnings        = $warnings.ToArray()
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

function Resolve-SwaConfigFileLeaf {
    <#
    .SYNOPSIS
        Normalises a config location - directory or file - to the file itself.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ConfigFilePath
    )

    $configFile = $ConfigFilePath
    if (Test-Path -LiteralPath $configFile -PathType Container) {
        $configFile = Join-Path $configFile 'staticwebapp.config.json'
    }
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw "config_file_location does not contain staticwebapp.config.json: $ConfigFilePath"
    }

    return $configFile
}

function Copy-SwaConfigFile {
    <#
    .SYNOPSIS
        Copies staticwebapp.config.json into the root of the content directory.
    .DESCRIPTION
        The payload zip is built from the content directory, so the config has to be sitting
        at its root before packaging. output_location commonly points at a build folder like
        dist while the config stays at app_location, which would otherwise leave it out of the
        deployment. A config already at the content root wins and is left untouched.
        Returns the path it wrote, or $null when it copied nothing.
    .EXAMPLE
        Copy-SwaConfigFile -ConfigFilePath ./app/staticwebapp.config.json -DestinationRoot ./app/dist
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ConfigFilePath,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        throw "Cannot place staticwebapp.config.json: '$DestinationRoot' is not a directory."
    }

    $configFile = Resolve-SwaConfigFileLeaf -ConfigFilePath $ConfigFilePath
    $destination = Join-Path $DestinationRoot 'staticwebapp.config.json'

    # Covers the config already living at the content root, including the case where the
    # source and the destination are the same file
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Write-Verbose '[SWA] staticwebapp.config.json already at the output root; keeping it'
        return $null
    }

    if (-not $PSCmdlet.ShouldProcess($destination, 'Copy staticwebapp.config.json')) { return $null }

    Copy-Item -LiteralPath $configFile -Destination $destination
    Write-Verbose "[SWA] Copied staticwebapp.config.json from $configFile to $DestinationRoot"
    return $destination
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

    $configFile = Resolve-SwaConfigFileLeaf -ConfigFilePath $ConfigFilePath

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

function New-SwaDeploymentResult {
    <#
    .SYNOPSIS
        Builds the result object every Invoke-SwaDeployment exit path returns.
    .DESCRIPTION
        Declaring the shape once is not tidiness. Callers run under
        Set-StrictMode -Version Latest, where a property missing from one branch is a
        terminating error on that branch only - invisible to the linter and to every test
        that happens to take a different path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Assembles and returns an object; changes no state.')]
    param(
        [Parameter(Mandatory)][string]$Status,
        [bool]$Success = $false,
        [string]$SiteUrl,
        # Not -Error: that would shadow the automatic variable
        [string]$ErrorText,
        [string]$ErrorResponse,
        $Payload,
        [string]$EnvironmentName = '',
        [string]$ContentHost = '',
        [string]$Correlation = '',
        [string[]]$QuotaViolations = @(),
        [double]$PackageSeconds = 0,
        [double]$UploadSeconds = 0,
        [double]$PollSeconds = 0,
        [int]$DurationSeconds = 0
    )

    return [pscustomobject]@{
        Success         = $Success
        Status          = $Status
        SiteUrl         = $(if ($SiteUrl) { $SiteUrl } else { $null })
        Error           = $(if ($ErrorText) { $ErrorText } else { $null })
        ErrorResponse   = $(if ($ErrorResponse) { $ErrorResponse } else { $null })
        FileCount       = (Get-SwaProperty -InputObject $Payload -Name 'FileCount' -Default 0)
        AppSizeBytes    = (Get-SwaProperty -InputObject $Payload -Name 'TotalBytes' -Default 0)
        CompressedBytes = (Get-SwaProperty -InputObject $Payload -Name 'CompressedBytes' -Default 0)
        HasConfigFile   = [bool](Get-SwaProperty -InputObject $Payload -Name 'HasConfigFile' -Default $false)
        ConfigReport    = (Get-SwaProperty -InputObject $Payload -Name 'ConfigReport')
        PayloadWarnings = @(Get-SwaProperty -InputObject $Payload -Name 'Warnings' -Default @())
        EnvironmentName = $EnvironmentName
        DurationSeconds = $DurationSeconds
        PackageSeconds  = [math]::Round($PackageSeconds, 1)
        UploadSeconds   = [math]::Round($UploadSeconds, 1)
        PollSeconds     = [math]::Round($PollSeconds, 1)
        ContentHost     = $ContentHost
        Correlation     = $Correlation
        QuotaViolations = $QuotaViolations
    }
}

function Read-SwaUploadTicket {
    <#
    .SYNOPSIS
        Pulls the SAS URL and polling handle out of an upload/request response.
    .DESCRIPTION
        Reading these through Get-SwaProperty rather than an optimistic chain is what lets the
        'no SAS URL' message actually fire. Under StrictMode the chain throws
        PropertyNotFoundException first, so a changed API shape used to surface as a
        PowerShell internal instead of as the guard written for it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($UploadRequest)

    $response = Get-SwaProperty -InputObject $UploadRequest -Name 'response'
    if ($null -eq $response) {
        throw 'Upload request returned no response body. The content distribution API may have changed.'
    }

    $packageUris = Get-SwaProperty -InputObject $response -Name 'packageUris'
    $sasUrl = Get-SwaProperty -InputObject $packageUris -Name 'app' -Default ''
    if ([string]::IsNullOrWhiteSpace($sasUrl)) {
        throw 'Upload request did not return a SAS URL for app.zip.'
    }

    $polling = Get-SwaProperty -InputObject $response -Name 'pollingInfo'
    return [pscustomobject]@{
        SasUrl              = $sasUrl
        DefaultHostname     = (Get-SwaProperty -InputObject $polling -Name 'defaultHostname' -Default '')
        StageSiteIdentifier = (Get-SwaProperty -InputObject $polling -Name 'stageSiteIdentifier' -Default '')
        Version             = (Get-SwaProperty -InputObject $polling -Name 'version' -Default '')
        TenantId            = (Get-SwaProperty -InputObject $polling -Name 'tenantId' -Default '')
    }
}

function Read-SwaDeploymentStatus {
    <#
    .SYNOPSIS
        Interprets a checkstatus response into a terminal verdict and a usable site URL.
    .DESCRIPTION
        siteUrl comes back empty on deployments that succeeded perfectly well, which used to
        leave the action green with no URL to show for it. The default hostname from the
        upload ticket names the same site and is already in hand, so it stands in.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        $Status,
        [string]$DefaultHostname = ''
    )

    $response = Get-SwaProperty -InputObject $Status -Name 'response'
    $deploymentStatus = Get-SwaProperty -InputObject $response -Name 'deploymentStatus' -Default ''

    $siteUrl = "$(Get-SwaProperty -InputObject $response -Name 'siteUrl' -Default '')".Trim()
    if (-not $siteUrl) { $siteUrl = "$DefaultHostname".Trim() }
    if ($siteUrl -and $siteUrl -notmatch '^https?://') { $siteUrl = "https://$siteUrl" }

    return [pscustomobject]@{
        DeploymentStatus = $deploymentStatus
        IsTerminal       = $deploymentStatus -in @('Succeeded', 'Failed', 'Canceled')
        Success          = $deploymentStatus -eq 'Succeeded'
        SiteUrl          = $siteUrl
    }
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Read inside the request scriptblocks, which the analyzer does not follow.')]
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

        # A status call that fails is a lost look at the deployment, not a failed deployment.
        # Only this many consecutive failures means we have genuinely lost the thread.
        [int]$MaxPollErrors = 5,

        [int]$MaxFileCount = $script:DefaultMaxFileCount,
        [long]$MaxAppSizeBytes = $script:DefaultMaxAppSizeBytes,

        # Refuse to deploy when staticwebapp.config.json is missing from the payload root:
        # without it Azure applies platform defaults and every route is served anonymously
        [ValidateSet('off', 'warn', 'error')]
        [string]$RequireConfigFile = 'off',

        [int]$RequestTimeoutSeconds = 100,
        [int]$UploadTimeoutSeconds = 1800,
        [int]$MaxAttempts = 4
    )

    $tokenInfo = Resolve-SwaContentHost -DeploymentToken $DeploymentToken
    $swaHost = "https://$($tokenInfo.ContentHost)"
    $apiVersion = 'v1'
    $correlationId = ([guid]::NewGuid()).ToString()
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $uploadSeconds = 0.0

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

    # Covers the zip_url download too - it is part of getting to a payload, not a phase of its own
    $packageWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $payload = New-SwaPayload @payloadParams
    $packageWatch.Stop()
    $packageSeconds = $packageWatch.Elapsed.TotalSeconds

    $quotaViolations = Test-SwaQuota -Payload $payload -MaxFileCount $MaxFileCount -MaxAppSizeBytes $MaxAppSizeBytes

    # Nothing below opens the try/finally that owns the work directory, so every early exit
    # from here to the HttpClient has to remove it by hand or the runner keeps the zip
    $discardPayload = {
        Remove-Item -LiteralPath $payload.WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Verbose ("[SWA] Payload: {0} files, {1} MB uncompressed ({2} MB zipped), largest file {3} MB" -f
        $payload.FileCount,
        [math]::Round($payload.TotalBytes / 1MB, 1),
        [math]::Round($payload.CompressedBytes / 1MB, 1),
        [math]::Round($payload.MaxFileBytes / 1MB, 1))
    foreach ($violation in $quotaViolations) {
        Write-Warning "[SWA] Quota exceeded: $violation"
    }
    foreach ($warning in $payload.Warnings) {
        Write-Warning "[SWA] $warning"
    }

    # ---- config gate: the last point before anything is uploaded ----
    $configProblem = $null
    if (-not $payload.HasConfigFile) {
        $configProblem = 'staticwebapp.config.json is not at the payload root'
    } elseif ($payload.ConfigReport -and -not $payload.ConfigReport.IsValidJson) {
        $configProblem = "staticwebapp.config.json could not be parsed ($($payload.ConfigReport.ParseError))"
    }

    if ($configProblem) {
        $consequence = 'Azure applies platform defaults, so routes and allowedRoles are not enforced ' +
        'and every path is served anonymously.'
        if ($RequireConfigFile -eq 'error') {
            & $discardPayload
            throw "$configProblem, and require_config_file is 'error'. Nothing was uploaded. $consequence"
        }
        if ($RequireConfigFile -eq 'warn') {
            Write-Warning "[SWA] $configProblem. $consequence"
        } else {
            Write-Verbose "[SWA] $configProblem; platform defaults apply"
        }
    } elseif ($payload.ConfigReport) {
        Write-Verbose ("[SWA] Config: {0} routes, {1} role-protected, roles [{2}]" -f
            $payload.ConfigReport.RouteCount,
            $payload.ConfigReport.ProtectedRouteCount,
            ($payload.ConfigReport.Roles -join ', '))
    }

    $resultDefaults = @{
        Payload         = $payload
        EnvironmentName = $EnvironmentName
        ContentHost     = $tokenInfo.ContentHost
        Correlation     = $correlationId
        QuotaViolations = $quotaViolations
        PackageSeconds  = $packageSeconds
    }

    if (-not $PSCmdlet.ShouldProcess($tokenInfo.ContentHost, "Deploy $($payload.FileCount) files")) {
        & $discardPayload
        return New-SwaDeploymentResult -Status 'WhatIf' -Success $true @resultDefaults
    }

    $http = [HttpClient]::new()
    # Per-call budgets instead of one client-wide deadline: the .NET default of 100s covers
    # the whole operation including the request body, which a large blob upload blows through
    # as an opaque TaskCanceledException that names neither the request nor the cause
    $http.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

    # Correlate every request the way the official client does
    $buildUrl = {
        param([string]$RequestPath)
        $builder = [System.UriBuilder]::new($swaHost)
        $builder.Path = $RequestPath.TrimStart('/')
        $builder.Query = "apiVersion=$apiVersion&deploymentCorrelationId=$correlationId"
        return $builder.Uri.AbsoluteUri
    }

    $sendJson = {
        param(
            [string]$Url,
            [object]$BodyObject,
            [ref]$RawContent,
            [int]$Attempts = $MaxAttempts,
            [int[]]$RetryStatuses = @(408, 429, 500, 502, 503, 504)
        )

        $json = [JsonSerializer]::Serialize($BodyObject, [JsonSerializerOptions]::new())
        $uri = [System.Uri]::new($Url)
        Write-Verbose "[SWA] POST $($uri.AbsolutePath)"

        # A fresh message per attempt: HttpRequestMessage cannot be sent twice. The token
        # header goes on the request, never on the client - the client also sends the blob
        # PUT, and that SAS URL belongs to a storage account that must not see the token.
        $response = Invoke-SwaHttpRequest -Client $http -Operation "POST $($uri.AbsolutePath)" `
            -TimeoutSeconds $RequestTimeoutSeconds -MaxAttempts $Attempts `
            -RetryStatusCodes $RetryStatuses -RequestFactory {
            $request = [HttpRequestMessage]::new([HttpMethod]::Post, $uri)
            $null = $request.Headers.TryAddWithoutValidation('Authorization', "token $DeploymentToken")
            $request.Content = [StringContent]::new($json, [Encoding]::UTF8, 'application/json')
            return $request
        }

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
        if ((Get-SwaProperty -InputObject $parsed -Name 'isSuccessStatusCode') -eq $false) {
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
        $validationStatus = Get-SwaProperty -InputObject $validation -Name 'statusCode'
        if ($validationStatus -and $validationStatus -ne 200) {
            throw "Token validation returned unexpected status: $validationStatus"
        }

        # 2) request an upload slot - the server validates quotas against these numbers
        $uploadInfo = [ordered]@{
            TotalAppSizeInBytes       = $payload.TotalBytes
            ApiSizeInBytes            = 0
            HasFunctions              = $false
            HasDataApiFiles           = $false
            HasDataApiConfigFile      = $false
            DatabaseType              = ''
            # Reported from the config we packaged rather than assumed away: Azure provisions
            # the roles it is told about, and understating them is how a route that should
            # ask for a login ends up open
            HasRoutes                 = [bool](Get-SwaProperty -InputObject $payload.ConfigReport -Name 'HasRoutes' -Default $false)
            Status                    = 'RequestingUpload'
            DefaultFileType           = 'index.html'
            ApiContentHash            = $null
            ConfiguredRoles           = @(Get-SwaProperty -InputObject $payload.ConfigReport -Name 'Roles' -Default @())
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

        # This one allocates an upload slot, so it is retried only on throttling and refusals
        # the server never acted on. A 502 from a gateway could mean the slot was allocated
        # and the answer lost on the way back.
        $uploadRequest = & $sendJson (& $buildUrl '/api/upload/request') @{
            EventInfo   = $eventInfo
            UploadInfo  = $uploadInfo
            PollingInfo = $null
        } $null $MaxAttempts @(429, 503)

        $ticket = Read-SwaUploadTicket -UploadRequest $uploadRequest

        # 3) upload the zip to blob storage
        Write-Verbose "[SWA] Uploading $([math]::Round($payload.CompressedBytes / 1MB, 1)) MB"
        $uploadWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $blobResponse = Invoke-SwaHttpRequest -Client $http -Operation 'Uploading app.zip' `
            -TimeoutSeconds $UploadTimeoutSeconds -MaxAttempts $MaxAttempts `
            -CompletionOption ([HttpCompletionOption]::ResponseHeadersRead) -RequestFactory {
            # Re-opened per attempt: a retry has to start the body at offset zero, and the
            # previous attempt's stream was disposed along with its request
            $blobRequest = [HttpRequestMessage]::new([HttpMethod]::Put, $ticket.SasUrl)
            $null = $blobRequest.Headers.TryAddWithoutValidation('x-ms-blob-type', 'BlockBlob')
            $null = $blobRequest.Headers.TryAddWithoutValidation('x-ms-version', '2023-11-03')
            $blobContent = [StreamContent]::new([System.IO.File]::OpenRead($payload.ZipPath))
            $blobContent.Headers.ContentType = [MediaTypeHeaderValue]::Parse('application/octet-stream')
            $blobContent.Headers.ContentLength = $payload.CompressedBytes
            $blobRequest.Content = $blobContent
            return $blobRequest
        }
        $uploadWatch.Stop()
        $uploadSeconds = $uploadWatch.Elapsed.TotalSeconds

        if (-not $blobResponse.IsSuccessStatusCode) {
            $blobError = $blobResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Uploading app.zip failed with $($blobResponse.StatusCode): $blobError"
        }

        # 4) tell the server the upload finished
        $uploadInfo.Status = 'Succeeded'
        $pollingInfo = [ordered]@{
            DefaultHostname     = $ticket.DefaultHostname
            StageSiteIdentifier = $ticket.StageSiteIdentifier
            Version             = $ticket.Version
            TenantId            = $ticket.TenantId
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
        $pollWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $consecutiveErrors = 0

        for ($attempt = 0; $attempt -lt $MaxPollAttempts; $attempt++) {
            Start-Sleep -Seconds $PollIntervalSeconds

            try {
                # One attempt per poll: the loop itself is the retry, and burning four
                # attempts here would stretch a two-second interval into half a minute
                $status = & $sendJson $statusUrl $pollingInfo ([ref]$rawStatus) 1
                $consecutiveErrors = 0
            } catch {
                # The content is still being distributed whether or not we can see it, so a
                # failed status check is a lost look rather than a failed deployment
                $consecutiveErrors++
                Write-Warning "[SWA] Status check failed ($consecutiveErrors/$MaxPollErrors): $($_.Exception.Message)"
                if ($consecutiveErrors -ge $MaxPollErrors) {
                    $pollWatch.Stop()
                    $totalWatch.Stop()
                    return New-SwaDeploymentResult -Status 'Unknown' @resultDefaults `
                        -UploadSeconds $uploadSeconds -PollSeconds $pollWatch.Elapsed.TotalSeconds `
                        -DurationSeconds ([int]$totalWatch.Elapsed.TotalSeconds) -ErrorResponse $rawStatus `
                        -ErrorText ("Lost contact with the content server after $MaxPollErrors consecutive " +
                        "status checks: $($_.Exception.Message). The deployment may still complete - " +
                        "check the Azure portal (correlation $correlationId).")
                }
                continue
            }

            # No fallback hostname for a named environment: the ticket's defaultHostname is
            # the production site, and reporting that as the preview URL would be worse than
            # reporting none at all
            $fallbackHostname = if ($EnvironmentName) { '' } else { $ticket.DefaultHostname }
            $verdict = Read-SwaDeploymentStatus -Status $status -DefaultHostname $fallbackHostname
            Write-Verbose "[SWA] deploymentStatus=$($verdict.DeploymentStatus)"
            if (-not $verdict.IsTerminal) { continue }

            $pollWatch.Stop()
            $totalWatch.Stop()
            $pollSeconds = $pollWatch.Elapsed.TotalSeconds
            $phases = @{
                UploadSeconds   = $uploadSeconds
                PollSeconds     = $pollSeconds
                DurationSeconds = [int]$totalWatch.Elapsed.TotalSeconds
            }

            if ($verdict.Success) {
                return New-SwaDeploymentResult -Status $verdict.DeploymentStatus -Success $true `
                    -SiteUrl $verdict.SiteUrl @resultDefaults @phases
            }

            $errorText = Get-SwaStatusError -Status $status -DeploymentStatus $verdict.DeploymentStatus
            # Azure never names the quota that was hit, so attach what we measured
            if ($quotaViolations.Count -gt 0) {
                $errorText = "$errorText | Likely cause: $($quotaViolations -join '; ')"
            }
            Write-Verbose "[SWA] Failure response: $rawStatus"
            return New-SwaDeploymentResult -Status $verdict.DeploymentStatus -ErrorText $errorText `
                -ErrorResponse $rawStatus @resultDefaults @phases
        }

        $pollWatch.Stop()
        $totalWatch.Stop()
        return New-SwaDeploymentResult -Status 'TimedOut' @resultDefaults `
            -UploadSeconds $uploadSeconds -PollSeconds $pollWatch.Elapsed.TotalSeconds `
            -DurationSeconds ([int]$totalWatch.Elapsed.TotalSeconds) -ErrorResponse $rawStatus `
            -ErrorText ("Stopped waiting after $($MaxPollAttempts * $PollIntervalSeconds)s. Azure had not " +
            "reported the deployment finished - it may still complete (correlation $correlationId).")
    } finally {
        $http.Dispose()
        & $discardPayload
    }
}

# Exports are controlled by FunctionsToExport in SwaDeploy.psd1 so that this module and the
# nested SwaBuild module share one list.
