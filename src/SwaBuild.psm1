#requires -Version 7.0
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

function Test-SwaVersionRange {
    <#
    .SYNOPSIS
        Checks an installed major version against a semver range, the way Oryx resolves engines.node.
    .DESCRIPTION
        Deliberately compares major versions only. Oryx picks a bundled runtime by major, and a
        full semver implementation would be a lot of surface for a check whose only job is to
        warn. Unparseable ranges return null so the caller reports both versions without judging.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Range,
        [Parameter(Mandatory)][int]$InstalledMajor
    )

    $range = $Range.Trim()
    if (-not $range -or $range -in @('*', 'x', 'latest')) { return $true }

    # '||' separates alternatives; any satisfied alternative satisfies the range
    foreach ($alternative in $range -split '\|\|') {
        $comparators = $alternative.Trim() -split '\s+' | Where-Object { $_ }
        if (-not $comparators) { continue }

        $allMatch = $true
        foreach ($comparator in $comparators) {
            if ($comparator -notmatch '^(>=|<=|>|<|\^|~|=)?\s*v?(\d+)') {
                return $null   # something we don't understand - let the caller decide
            }
            $operator = $Matches[1]
            $major = [int]$Matches[2]

            $satisfied = switch ($operator) {
                '>=' { $InstalledMajor -ge $major }
                '>' { $InstalledMajor -gt $major }
                '<=' { $InstalledMajor -le $major }
                '<' { $InstalledMajor -lt $major }
                default { $InstalledMajor -eq $major }   # ^, ~, =, bare, and X.x all pin the major
            }
            if (-not $satisfied) { $allMatch = $false; break }
        }
        if ($allMatch) { return $true }
    }
    return $false
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
    $installedMajor = [int](($result.Installed -split '\.')[0])

    $satisfied = Test-SwaVersionRange -Range $result.Requested -InstalledMajor $installedMajor
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
        [Parameter(Mandatory)]$Plan
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

    # Oryx would switch runtimes to match; the runner's Node is fixed, so say so plainly
    $node = $Plan.NodeVersion
    if ($node -and $node.Requested) {
        if ($node.Installed) {
            Write-Host "Node $($node.Installed) (project asks for '$($node.Requested)' via $($node.Source))"
        }
        if (-not $node.Satisfied) {
            # Point at the file the version came from rather than a literal, so it stays
            # declared in one place
            Write-Host ("::warning::Node $($node.Installed) does not satisfy '$($node.Requested)' from " +
                "$($node.Source). This action builds with the runner's Node - add a setup step before it: " +
                "uses: actions/setup-node@v7 with: node-version-file: $($node.VersionFile)")
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
Invoke-SwaExternalCommand, Test-SwaVersionRange, Get-SwaNodeVersionCheck
