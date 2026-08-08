#requires -Version 7.0
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CyberDrain
<#
    Build support without Oryx.

    Oryx ships a 1.5 GB image because it bundles every language runtime. A GitHub runner
    already has Node, Python, .NET, Go and Java installed, so the only thing actually needed
    is the detection logic - work out which package manager the project uses and run its
    install/build scripts against the toolchain that is already there.
#>

Set-StrictMode -Version Latest

function Invoke-SwaExternalCommand {
    <#
    .SYNOPSIS
        Runs a build command in the platform shell, streaming output, throwing on failure.
    .DESCRIPTION
        Build commands are run through the native shell rather than evaluated in-process.
        Users write them expecting shell semantics ('export FOO=bar && npm run build'), which
        PowerShell would not parse, and a child process keeps the build out of module scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$Label
    )

    $display = if ($Label) { $Label } else { $Command }
    Write-Host "==> $display" -ForegroundColor Cyan

    Push-Location -LiteralPath $WorkingDirectory
    try {
        if ($IsWindows) {
            & pwsh -NoProfile -Command $Command
        } else {
            & bash -c $Command
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $Command"
    }
}

function Get-SwaBuildPlan {
    <#
    .SYNOPSIS
        Works out how to build a project, the way Oryx would, using the runner's toolchain.
    .DESCRIPTION
        Detects the Node package manager from the lockfile and reads package.json to see
        whether a build script exists. Returns a plan describing what would run; nothing is
        executed here so the decision can be logged or asserted in tests.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        # Overrides detection entirely, matching app_build_command on the official action
        [string]$BuildCommand
    )

    $plan = [pscustomobject]@{
        Platform       = 'none'
        PackageManager = $null
        InstallCommand = $null
        BuildCommand   = $null
        NodeVersion    = $null
        Reason         = 'No build needed - deploying content as-is.'
    }

    if ($BuildCommand) {
        $plan.Platform = 'custom'
        $plan.BuildCommand = $BuildCommand
        $plan.Reason = 'Using the supplied build command.'

        # A custom command still needs dependencies when the project is a Node app
        if (Test-Path -LiteralPath (Join-Path $Path 'package.json')) {
            $manager = Get-SwaPackageManager -Path $Path
            $plan.PackageManager = $manager.Name
            $plan.InstallCommand = $manager.InstallCommand
            $plan.NodeVersion = Get-SwaNodeVersionCheck -Path $Path
        }
        return $plan
    }

    $packageJsonPath = Join-Path $Path 'package.json'
    if (-not (Test-Path -LiteralPath $packageJsonPath)) {
        return $plan
    }

    try {
        $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
    } catch {
        throw "package.json in '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    $manager = Get-SwaPackageManager -Path $Path
    $plan.Platform = 'node'
    $plan.PackageManager = $manager.Name
    $plan.InstallCommand = $manager.InstallCommand
    $plan.NodeVersion = Get-SwaNodeVersionCheck -Path $Path

    $scripts = $null
    if ($packageJson.PSObject.Properties.Name -contains 'scripts') { $scripts = $packageJson.scripts }

    if ($scripts -and $scripts.PSObject.Properties.Name -contains 'build') {
        $plan.BuildCommand = $manager.BuildCommand
        $plan.Reason = "Detected a $($manager.Name) project with a build script."
    } else {
        $plan.Reason = "Detected a $($manager.Name) project with no build script - installing dependencies only."
    }

    return $plan
}

function ConvertTo-SwaVersion {
    <#
    .SYNOPSIS
        Parses a possibly-partial version ('22', '22.11', 'v22.11.0') into a comparable object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version
    )

    $text = $Version.Trim().TrimStart('v', 'V')
    if ($text -notmatch '^(\d+)(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?') { return $null }

    $toInt = {
        param($value)
        if ($null -eq $value -or $value -eq '' -or $value -in @('x', 'X', '*')) { return $null }
        return [int]$value
    }

    return [pscustomobject]@{
        Major = [int]$Matches[1]
        Minor = & $toInt $Matches[2]
        Patch = & $toInt $Matches[3]
    }
}

function Compare-SwaVersion {
    <#
    .SYNOPSIS
        Compares two full versions. Returns -1, 0 or 1.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    foreach ($part in @('Major', 'Minor', 'Patch')) {
        $l = if ($null -ne $Left.$part) { $Left.$part } else { 0 }
        $r = if ($null -ne $Right.$part) { $Right.$part } else { 0 }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }
    return 0
}

function Test-SwaVersionRange {
    <#
    .SYNOPSIS
        Tests a concrete version against an npm-style range.
    .DESCRIPTION
        Supports the comparators that actually appear in engines.node: >=, >, <=, <, ^, ~, =,
        bare versions, X-ranges, space-separated AND, and '||' alternatives. Precision matters
        here because the same range decides which runtime gets downloaded, not just whether to
        warn. Ranges it cannot parse return null so callers can decline to act.
    .EXAMPLE
        Test-SwaVersionRange -Version '22.11.0' -Range '>=20 <23'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Range
    )

    $actual = ConvertTo-SwaVersion -Version $Version
    if (-not $actual) { return $null }

    $range = $Range.Trim()
    if (-not $range -or $range -in @('*', 'x', 'X', 'latest')) { return $true }

    foreach ($alternative in $range -split '\|\|') {
        $comparators = @($alternative.Trim() -split '\s+' | Where-Object { $_ })
        if ($comparators.Count -eq 0) { continue }

        $allMatch = $true
        foreach ($comparator in $comparators) {
            if ($comparator -notmatch '^(>=|<=|>|<|\^|~|=)?\s*(v?[\dxX*][^\s]*)$') { return $null }
            $operator = $Matches[1]
            $bound = ConvertTo-SwaVersion -Version $Matches[2]
            if (-not $bound) { return $null }

            # Lower bound is the partial version with missing parts zeroed
            $lower = [pscustomobject]@{
                Major = $bound.Major
                Minor = $(if ($null -ne $bound.Minor) { $bound.Minor } else { 0 })
                Patch = $(if ($null -ne $bound.Patch) { $bound.Patch } else { 0 })
            }

            # Upper bound for the range operators: the first version that is too new
            $upper = $null
            switch ($operator) {
                '^' {
                    # ^0.2.3 pins the minor; ^1.2.3 pins the major
                    $upper = if ($bound.Major -eq 0 -and $null -ne $bound.Minor) {
                        [pscustomobject]@{ Major = 0; Minor = $bound.Minor + 1; Patch = 0 }
                    } else {
                        [pscustomobject]@{ Major = $bound.Major + 1; Minor = 0; Patch = 0 }
                    }
                }
                '~' {
                    $upper = if ($null -ne $bound.Minor) {
                        [pscustomobject]@{ Major = $bound.Major; Minor = $bound.Minor + 1; Patch = 0 }
                    } else {
                        [pscustomobject]@{ Major = $bound.Major + 1; Minor = 0; Patch = 0 }
                    }
                }
                default {
                    # A partial bare/= version is an X-range: '22' means >=22.0.0 <23.0.0
                    if ($operator -in @($null, '', '=') -and $null -eq $bound.Patch) {
                        $upper = if ($null -ne $bound.Minor) {
                            [pscustomobject]@{ Major = $bound.Major; Minor = $bound.Minor + 1; Patch = 0 }
                        } else {
                            [pscustomobject]@{ Major = $bound.Major + 1; Minor = 0; Patch = 0 }
                        }
                    }
                }
            }

            $satisfied = switch ($operator) {
                '>=' { (Compare-SwaVersion $actual $lower) -ge 0 }
                '>' { (Compare-SwaVersion $actual $lower) -gt 0 }
                '<=' { (Compare-SwaVersion $actual $lower) -le 0 }
                '<' { (Compare-SwaVersion $actual $lower) -lt 0 }
                default {
                    if ($upper) {
                        (Compare-SwaVersion $actual $lower) -ge 0 -and (Compare-SwaVersion $actual $upper) -lt 0
                    } else {
                        (Compare-SwaVersion $actual $lower) -eq 0
                    }
                }
            }

            if (-not $satisfied) { $allMatch = $false; break }
        }
        if ($allMatch) { return $true }
    }
    return $false
}

function Get-SwaNodePlatform {
    <#
    .SYNOPSIS
        Maps the current OS and architecture onto nodejs.org's distribution naming.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) {
        'X64' { 'x64' }
        'Arm64' { 'arm64' }
        'X86' { 'x86' }
        default { throw "Unsupported processor architecture for a Node download: $_" }
    }

    if ($IsWindows) {
        return [pscustomobject]@{ Slug = "win-$arch"; Arch = $arch; Extension = 'zip'; BinSubPath = ''; Executable = 'node.exe' }
    }
    if ($IsMacOS) {
        return [pscustomobject]@{ Slug = "darwin-$arch"; Arch = $arch; Extension = 'tar.gz'; BinSubPath = 'bin'; Executable = 'node' }
    }
    return [pscustomobject]@{ Slug = "linux-$arch"; Arch = $arch; Extension = 'tar.gz'; BinSubPath = 'bin'; Executable = 'node' }
}

function Resolve-SwaNodeVersion {
    <#
    .SYNOPSIS
        Picks the newest Node release satisfying a range, from nodejs.org's live index.
    .DESCRIPTION
        This is the part Oryx cannot do. Its runtimes are baked into the image, so the set
        goes stale the moment the image is published and '>=22' resolves to whatever happened
        to be current at build time. Resolving against the published index means a range
        always picks up the newest matching release without anything being rebuilt.
    .EXAMPLE
        Resolve-SwaNodeVersion -Range '>=22'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Range,

        # Pre-fetched index (list of {version, lts, ...}); fetched when omitted
        $Index,

        [string]$IndexUrl = 'https://nodejs.org/dist/index.json',
        [int]$TimeoutSeconds = 60
    )

    if (-not $Index) {
        Write-Verbose "[SWA] Fetching Node release index from $IndexUrl"
        $Index = Invoke-RestMethod -Uri $IndexUrl -Method Get -TimeoutSec $TimeoutSeconds
    }

    $best = $null
    foreach ($entry in $Index) {
        if (-not $entry.version) { continue }
        if ((Test-SwaVersionRange -Version $entry.version -Range $Range) -ne $true) { continue }

        $parsed = ConvertTo-SwaVersion -Version $entry.version
        if (-not $parsed) { continue }
        if (-not $best -or (Compare-SwaVersion -Left $parsed -Right $best.Parsed) -gt 0) {
            # lts is either false or the codename string
            $lts = if ($entry.lts -is [string]) { $entry.lts } else { $null }
            $best = [pscustomobject]@{
                Version = "$($entry.version)".TrimStart('v')
                Parsed  = $parsed
                Lts     = $lts
            }
        }
    }

    return $best
}

function Install-SwaNode {
    <#
    .SYNOPSIS
        Makes a specific Node version available on PATH, reusing the tool cache when possible.
    .DESCRIPTION
        Checks the runner's tool cache first, so a version setup-node already installed costs
        nothing. Otherwise downloads from nodejs.org, verifies the SHA256 against the release's
        published SHASUMS256.txt, extracts, and prepends to PATH for this process and for
        later workflow steps via GITHUB_PATH.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$InstallRoot,
        [string]$DistBaseUrl = 'https://nodejs.org/dist'
    )

    $version = $Version.TrimStart('v')
    $platform = Get-SwaNodePlatform

    # 1. Reuse whatever the runner already has
    if ($env:RUNNER_TOOL_CACHE) {
        $cached = Join-Path $env:RUNNER_TOOL_CACHE (Join-Path 'node' (Join-Path $version $platform.Arch))
        $cachedBin = if ($platform.BinSubPath) { Join-Path $cached $platform.BinSubPath } else { $cached }
        if (Test-Path -LiteralPath (Join-Path $cachedBin $platform.Executable)) {
            Write-Host "Node $version already in the runner tool cache."
            Add-SwaPathEntry -Path $cachedBin
            return $cachedBin
        }
    }

    if (-not $InstallRoot) { $InstallRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'swa-node' }
    $extractRoot = Join-Path $InstallRoot $version
    $folderName = "node-v$version-$($platform.Slug)"
    $installed = Join-Path $extractRoot $folderName
    $installedBin = if ($platform.BinSubPath) { Join-Path $installed $platform.BinSubPath } else { $installed }

    # 2. Already downloaded earlier in this job
    if (Test-Path -LiteralPath (Join-Path $installedBin $platform.Executable)) {
        Add-SwaPathEntry -Path $installedBin
        return $installedBin
    }

    if (-not $PSCmdlet.ShouldProcess("Node $version", 'Download and install')) { return $null }

    $fileName = "$folderName.$($platform.Extension)"
    $downloadUrl = "$DistBaseUrl/v$version/$fileName"
    $null = New-Item -ItemType Directory -Path $extractRoot -Force
    $archivePath = Join-Path $extractRoot $fileName

    Write-Host "Installing Node $version ($($platform.Slug))..."
    Write-Verbose "[SWA] Downloading $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 300

    # 3. Verify against the release's published checksums before trusting the archive
    try {
        $sums = Invoke-RestMethod -Uri "$DistBaseUrl/v$version/SHASUMS256.txt" -Method Get -TimeoutSec 60
        $expected = ($sums -split "`n" | Where-Object { $_ -match "\s\*?$([regex]::Escape($fileName))\s*$" } |
                Select-Object -First 1) -split '\s+' | Select-Object -First 1
        if (-not $expected) { throw "no checksum published for $fileName" }

        $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($actual -ne $expected.ToUpperInvariant()) {
            throw "SHA256 mismatch for ${fileName}: expected $expected, got $actual"
        }
        Write-Verbose '[SWA] Checksum verified'
    } catch {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw "Could not verify the Node $version download: $($_.Exception.Message)"
    }

    # 4. Extract
    if ($platform.Extension -eq 'zip') {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractRoot)
    } else {
        & tar -xzf $archivePath -C $extractRoot
        if ($LASTEXITCODE -ne 0) { throw "Extracting $fileName failed with exit code $LASTEXITCODE." }
    }
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath (Join-Path $installedBin $platform.Executable))) {
        throw "Node $version did not extract to the expected layout ($installedBin)."
    }

    Add-SwaPathEntry -Path $installedBin
    return $installedBin
}

function Add-SwaPathEntry {
    <#
    .SYNOPSIS
        Prepends a directory to PATH for this process and for later workflow steps.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Prepend to PATH')) { return }

    $env:PATH = "$Path$([System.IO.Path]::PathSeparator)$env:PATH"
    if ($env:GITHUB_PATH) { $Path | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8 }
}

function Get-SwaNodeVersionCheck {
    <#
    .SYNOPSIS
        Compares the runner's Node against the version the project asks for.
    .DESCRIPTION
        Oryx reads engines.node from package.json and selects a matching runtime from the ones
        baked into its image. Nothing is baked in here - the runner's Node is what builds - so
        the mismatch is surfaced with the setup-node snippet that fixes it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = [pscustomobject]@{
        Requested   = $null
        Installed   = $null
        Satisfied   = $true
        Source      = $null
        # File to hand to setup-node's node-version-file, so the version stays declared once
        VersionFile = $null
    }

    $packageJsonPath = Join-Path $Path 'package.json'
    if (Test-Path -LiteralPath $packageJsonPath) {
        try {
            $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
            if ($packageJson.PSObject.Properties.Name -contains 'engines' -and $packageJson.engines -and
                $packageJson.engines.PSObject.Properties.Name -contains 'node') {
                $result.Requested = "$($packageJson.engines.node)".Trim()
                $result.Source = 'package.json engines.node'
                $result.VersionFile = 'package.json'
            }
        } catch {
            Write-Verbose "[SWA] Could not read engines.node: $($_.Exception.Message)"
        }
    }

    # .nvmrc is not an Oryx input, but it is the other place people pin Node
    if (-not $result.Requested) {
        $nvmrcPath = Join-Path $Path '.nvmrc'
        if (Test-Path -LiteralPath $nvmrcPath) {
            $result.Requested = (Get-Content -LiteralPath $nvmrcPath -Raw).Trim()
            $result.Source = '.nvmrc'
            $result.VersionFile = '.nvmrc'
        }
    }

    if (-not $result.Requested) { return $result }

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCommand) { return $result }

    $installedRaw = (& node --version 2>$null)
    if (-not $installedRaw) { return $result }

    $result.Installed = "$installedRaw".Trim().TrimStart('v')

    $satisfied = Test-SwaVersionRange -Version $result.Installed -Range $result.Requested
    # A null verdict means the range was unparseable - don't cry wolf
    $result.Satisfied = ($null -eq $satisfied) -or $satisfied
    return $result
}

function Get-SwaPackageManager {
    <#
    .SYNOPSIS
        Picks the package manager from the lockfile present, the way Oryx does.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Order matters: a repo with several lockfiles is resolved most-specific first
    if (Test-Path -LiteralPath (Join-Path $Path 'pnpm-lock.yaml')) {
        return [pscustomobject]@{ Name = 'pnpm'; InstallCommand = 'pnpm install --frozen-lockfile'; BuildCommand = 'pnpm run build' }
    }
    if (Test-Path -LiteralPath (Join-Path $Path 'yarn.lock')) {
        return [pscustomobject]@{ Name = 'yarn'; InstallCommand = 'yarn install --frozen-lockfile'; BuildCommand = 'yarn run build' }
    }
    if (Test-Path -LiteralPath (Join-Path $Path 'package-lock.json')) {
        return [pscustomobject]@{ Name = 'npm'; InstallCommand = 'npm ci'; BuildCommand = 'npm run build' }
    }
    # No lockfile - npm install rather than npm ci, which requires one
    return [pscustomobject]@{ Name = 'npm'; InstallCommand = 'npm install'; BuildCommand = 'npm run build' }
}

function Invoke-SwaBuild {
    <#
    .SYNOPSIS
        Executes a build plan against the runner's own toolchain.
    .EXAMPLE
        $plan = Get-SwaBuildPlan -Path ./app
        Invoke-SwaBuild -Path ./app -Plan $plan
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Plan,

        # Install a matching Node when the runner's version doesn't satisfy engines.node
        [bool]$InstallNode = $true
    )

    if ($Plan.Platform -eq 'none') {
        Write-Host $Plan.Reason
        return
    }

    Write-Host $Plan.Reason

    if ($Plan.Platform -in @('node', 'custom') -and $Plan.PackageManager) {
        $tool = $Plan.PackageManager
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' is not on PATH. Add the matching setup step (e.g. actions/setup-node, " +
            'pnpm/action-setup) before this action.'
        }
    }

    # Match the runtime the project asks for. Unlike Oryx the candidate set is nodejs.org's
    # live index, so a range keeps resolving to current releases with nothing to rebuild.
    $node = $Plan.NodeVersion
    if ($node -and $node.Requested) {
        if ($node.Installed) {
            Write-Host "Node $($node.Installed) (project asks for '$($node.Requested)' via $($node.Source))"
        }
        if (-not $node.Satisfied) {
            if (-not $InstallNode) {
                Write-Host ("::warning::Node $($node.Installed) does not satisfy '$($node.Requested)' from " +
                    "$($node.Source), and install_node is off. Add a setup step before this action: " +
                    "uses: actions/setup-node@v7 with: node-version-file: $($node.VersionFile)")
            } else {
                try {
                    $resolved = Resolve-SwaNodeVersion -Range $node.Requested
                    if (-not $resolved) { throw "no published release satisfies '$($node.Requested)'" }

                    $ltsNote = if ($resolved.Lts) { " (LTS $($resolved.Lts))" } else { '' }
                    Write-Host "Resolved '$($node.Requested)' to Node $($resolved.Version)$ltsNote"
                    $null = Install-SwaNode -Version $resolved.Version

                    $now = "$(& node --version 2>$null)".Trim().TrimStart('v')
                    if ($now) { Write-Host "Building with Node $now" }
                } catch {
                    # A build on the wrong major usually still works; failing the deploy over a
                    # download hiccup would be worse than saying so and carrying on
                    Write-Host ("::warning::Could not install a Node matching '$($node.Requested)': " +
                        "$($_.Exception.Message). Building with Node $($node.Installed) instead.")
                }
            }
        }
    }

    if ($Plan.InstallCommand -and $PSCmdlet.ShouldProcess($Path, $Plan.InstallCommand)) {
        Invoke-SwaExternalCommand -Command $Plan.InstallCommand -WorkingDirectory $Path
    }
    if ($Plan.BuildCommand -and $PSCmdlet.ShouldProcess($Path, $Plan.BuildCommand)) {
        Invoke-SwaExternalCommand -Command $Plan.BuildCommand -WorkingDirectory $Path
    }
}

Export-ModuleMember -Function Get-SwaBuildPlan, Get-SwaPackageManager, Invoke-SwaBuild,
Invoke-SwaExternalCommand, Get-SwaNodeVersionCheck, ConvertTo-SwaVersion, Compare-SwaVersion,
Test-SwaVersionRange, Get-SwaNodePlatform, Resolve-SwaNodeVersion, Install-SwaNode,
Add-SwaPathEntry
