#requires -Version 7.0
#requires -Modules Pester

BeforeAll {
    Import-Module "$PSScriptRoot/../src/SwaDeploy.psd1" -Force

    # Tokens are prefix(64 + optional slice digits) '-' suffix(>=39, region hex at 36..38)
    function New-TestToken {
        param([int]$Slice = 0, [string]$RegionHex = '003')
        $prefix = ('a' * 64) + $(if ($Slice -gt 0) { "$Slice" } else { '' })
        $suffix = ('b' * 36) + $RegionHex
        return "$prefix-$suffix"
    }
}

Describe 'ConvertTo-SwaErrorText' {
    It 'returns null for null and whitespace' {
        ConvertTo-SwaErrorText -ErrorObject $null | Should -BeNullOrEmpty
        ConvertTo-SwaErrorText -ErrorObject '   ' | Should -BeNullOrEmpty
    }

    It 'trims plain strings' {
        ConvertTo-SwaErrorText -ErrorObject '  boom  ' | Should -Be 'boom'
    }

    It 'joins arrays and drops empties' {
        ConvertTo-SwaErrorText -ErrorObject @('a', $null, '', 'b') | Should -Be 'a | b'
    }

    It 'reads hashtables' {
        ConvertTo-SwaErrorText -ErrorObject @{ errorMessage = 'nope' } | Should -Be 'nope'
    }

    It 'extracts the reason from a real rejection envelope' {
        $envelope = '{"response":null,"statusCode":400,"errorMessage":"The number of static files was too large.","isSuccessStatusCode":false}' | ConvertFrom-Json
        ConvertTo-SwaErrorText -ErrorObject $envelope | Should -Be 'The number of static files was too large.'
    }

    It 'walks nested inner errors instead of stopping at the outer message' {
        $nested = '{"errorCode":"DistributionFailed","message":"Failure during content distribution.","innerError":{"message":"blob upload denied","details":["region eastus2 unavailable"]}}' | ConvertFrom-Json
        ConvertTo-SwaErrorText -ErrorObject $nested |
            Should -Be 'DistributionFailed: Failure during content distribution.: blob upload denied: region eastus2 unavailable'
    }

    It 'falls back to JSON so unknown shapes are never dropped' {
        $unknown = '{"weirdField":"important detail"}' | ConvertFrom-Json
        ConvertTo-SwaErrorText -ErrorObject $unknown | Should -Be '{"weirdField":"important detail"}'
    }

    It 'stops recursing on deeply nested payloads' {
        $deep = '{"innerError":{"innerError":{"innerError":{"innerError":{"innerError":{"innerError":{"message":"too deep"}}}}}}}' | ConvertFrom-Json
        { ConvertTo-SwaErrorText -ErrorObject $deep } | Should -Not -Throw
    }
}

Describe 'Get-SwaStatusError' {
    It 'surfaces the observed content distribution failure' {
        $status = '{"response":{"deploymentStatus":"Failed","errorDetails":"Failure during content distribution.","siteUrl":"","unhealthyRegions":[]},"statusCode":200,"errorMessage":"","isSuccessStatusCode":true}' | ConvertFrom-Json
        Get-SwaStatusError -Status $status -DeploymentStatus 'Failed' | Should -Be 'Failure during content distribution.'
    }

    It 'appends unhealthy regions when the platform names them' {
        $status = '{"response":{"deploymentStatus":"Failed","errorDetails":"Failure during content distribution.","unhealthyRegions":["westeurope","eastus2"]}}' | ConvertFrom-Json
        Get-SwaStatusError -Status $status -DeploymentStatus 'Failed' |
            Should -Be 'Failure during content distribution. | unhealthy regions: westeurope, eastus2'
    }

    It 'falls back to a sentinel when the response carries no error at all' {
        $status = '{"response":{"deploymentStatus":"Canceled"}}' | ConvertFrom-Json
        Get-SwaStatusError -Status $status -DeploymentStatus 'Canceled' |
            Should -Be "Deployment reported 'Canceled' with no error details."
    }

    It 'keeps unrecognized fields rather than discarding them' {
        $status = '{"response":{"deploymentStatus":"Failed","mysteryField":"the real cause"}}' | ConvertFrom-Json
        Get-SwaStatusError -Status $status -DeploymentStatus 'Failed' | Should -Match 'the real cause'
    }
}

Describe 'Resolve-SwaContentHost' {
    It 'omits the slice number for slice 0' {
        $result = Resolve-SwaContentHost -DeploymentToken (New-TestToken -Slice 0 -RegionHex '003')
        $result.ContentHost | Should -Be 'content-am2.infrastructure.azurestaticapps.net'
        $result.Slice | Should -Be 0
        $result.RegionId | Should -Be 3
    }

    It 'includes the slice number for slice 1' {
        $result = Resolve-SwaContentHost -DeploymentToken (New-TestToken -Slice 1 -RegionHex '003')
        $result.ContentHost | Should -Be 'content-am2.infrastructure.1.azurestaticapps.net'
        $result.Slice | Should -Be 1
    }

    It 'applies the canary override instead of the derived pattern' {
        # region 0x021 = 33 = euapbn1, which lives on the canary domain
        $result = Resolve-SwaContentHost -DeploymentToken (New-TestToken -Slice 0 -RegionHex '021')
        $result.ContentHost | Should -Be 'content-euapbn1.infrastructure.azurestaticappscanary.net'
    }

    It 'rejects a token that is too short' {
        { Resolve-SwaContentHost -DeploymentToken 'abc' } | Should -Throw '*shorter than 104*'
    }

    It 'rejects an unknown region rather than guessing a hostname' {
        { Resolve-SwaContentHost -DeploymentToken (New-TestToken -RegionHex '0FF') } | Should -Throw '*not recognized*'
    }
}

Describe 'Get-SwaPackageManager' {
    BeforeEach {
        $script:projectDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-pm-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $script:projectDir
    }
    AfterEach {
        Remove-Item -LiteralPath $script:projectDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'uses npm ci when a package-lock is present' {
        $null = New-Item -ItemType File -Path (Join-Path $script:projectDir 'package-lock.json')
        (Get-SwaPackageManager -Path $script:projectDir).InstallCommand | Should -Be 'npm ci'
    }

    It 'uses npm install when there is no lockfile' {
        (Get-SwaPackageManager -Path $script:projectDir).InstallCommand | Should -Be 'npm install'
    }

    It 'detects yarn' {
        $null = New-Item -ItemType File -Path (Join-Path $script:projectDir 'yarn.lock')
        (Get-SwaPackageManager -Path $script:projectDir).Name | Should -Be 'yarn'
    }

    It 'prefers pnpm when several lockfiles exist' {
        $null = New-Item -ItemType File -Path (Join-Path $script:projectDir 'package-lock.json')
        $null = New-Item -ItemType File -Path (Join-Path $script:projectDir 'pnpm-lock.yaml')
        (Get-SwaPackageManager -Path $script:projectDir).Name | Should -Be 'pnpm'
    }
}

Describe 'Get-SwaBuildPlan' {
    BeforeEach {
        $script:projectDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-plan-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $script:projectDir
    }
    AfterEach {
        Remove-Item -LiteralPath $script:projectDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'plans no build for a plain static folder' {
        $plan = Get-SwaBuildPlan -Path $script:projectDir
        $plan.Platform | Should -Be 'none'
        $plan.BuildCommand | Should -BeNullOrEmpty
    }

    It 'plans a build when package.json declares one' {
        '{"scripts":{"build":"vite build"}}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        $plan = Get-SwaBuildPlan -Path $script:projectDir
        $plan.Platform | Should -Be 'node'
        $plan.BuildCommand | Should -Be 'npm run build'
    }

    It 'installs but does not build when there is no build script' {
        '{"dependencies":{}}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        $plan = Get-SwaBuildPlan -Path $script:projectDir
        $plan.InstallCommand | Should -Be 'npm install'
        $plan.BuildCommand | Should -BeNullOrEmpty
    }

    It 'lets a custom command override detection but still installs deps' {
        '{"scripts":{"build":"vite build"}}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        $plan = Get-SwaBuildPlan -Path $script:projectDir -BuildCommand 'make site'
        $plan.Platform | Should -Be 'custom'
        $plan.BuildCommand | Should -Be 'make site'
        $plan.InstallCommand | Should -Be 'npm install'
    }

    It 'reports invalid package.json clearly' {
        'not json' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        { Get-SwaBuildPlan -Path $script:projectDir } | Should -Throw '*not valid JSON*'
    }
}

Describe 'Resolve-SwaWorkspacePath' {
    BeforeAll {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "swa-root-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path (Join-Path $script:root 'app/dist') -Force
        $script:rootFull = [System.IO.Path]::GetFullPath($script:root)
    }
    AfterAll {
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns the root for an empty path' {
        Resolve-SwaWorkspacePath -Root $script:root -Path '' -InputName 'app_location' | Should -Be $script:rootFull
    }

    It "treats '/' as the workspace root, like the official action" {
        Resolve-SwaWorkspacePath -Root $script:root -Path '/' -InputName 'app_location' | Should -Be $script:rootFull
    }

    It 'strips a leading separator rather than treating the path as absolute' {
        Resolve-SwaWorkspacePath -Root $script:root -Path '/app/dist' -InputName 'app_location' |
            Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:root 'app/dist')))
    }

    It 'resolves a normal relative path' {
        Resolve-SwaWorkspacePath -Root $script:root -Path 'app/dist' -InputName 'app_location' |
            Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:root 'app/dist')))
    }

    It 'allows .. that stays inside the root' {
        Resolve-SwaWorkspacePath -Root $script:root -Path 'app/../app/dist' -InputName 'app_location' |
            Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:root 'app/dist')))
    }

    It 'rejects traversal out of the workspace' -ForEach @(
        @{ Bad = '../outside' }
        @{ Bad = '../../etc' }
        @{ Bad = 'app/../../outside' }
        @{ Bad = '..' }
    ) {
        { Resolve-SwaWorkspacePath -Root $script:root -Path $Bad -InputName 'app_location' } |
            Should -Throw '*resolves outside the workspace*'
    }

    It 'rejects a sibling directory sharing the root name prefix' {
        # '/work' must not be treated as containing '/work-evil'
        { Resolve-SwaWorkspacePath -Root $script:root -Path "../$(Split-Path $script:root -Leaf)-evil" -InputName 'app_location' } |
            Should -Throw '*resolves outside the workspace*'
    }
}

Describe 'Resolve-SwaConfigFilePath' {
    BeforeEach {
        $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "swa-config-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path (Join-Path $script:workspace 'app/dist') -Force
    }
    AfterEach {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'finds staticwebapp.config.json at app_location when config_file_location is omitted' {
        $configPath = Join-Path $script:workspace 'app/staticwebapp.config.json'
        '{"globalHeaders":{"X-Frame-Options":"DENY"}}' | Set-Content -Path $configPath

        Resolve-SwaConfigFilePath -WorkspaceRoot $script:workspace -AppLocation 'app' |
            Should -Be ([System.IO.Path]::GetFullPath($configPath))
    }

    It 'prefers an explicit config_file_location' {
        $configDir = Join-Path $script:workspace 'security'
        $null = New-Item -ItemType Directory -Path $configDir -Force
        $configPath = Join-Path $configDir 'staticwebapp.config.json'
        '{"routes":[]}' | Set-Content -Path $configPath

        Resolve-SwaConfigFilePath -WorkspaceRoot $script:workspace -AppLocation 'app' -ConfigFileLocation 'security' |
            Should -Be ([System.IO.Path]::GetFullPath($configDir))
    }
}

Describe 'Copy-SwaConfigFile' {
    BeforeEach {
        $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "swa-copycfg-$([guid]::NewGuid().ToString('n'))"
        $script:appDir = Join-Path $script:workspace 'app'
        $script:outDir = Join-Path $script:appDir 'dist'
        $null = New-Item -ItemType Directory -Path $script:outDir -Force
        $script:sourceConfig = Join-Path $script:appDir 'staticwebapp.config.json'
        '{"routes":[{"route":"/api/*","allowedRoles":["authenticated"]}]}' | Set-Content -Path $script:sourceConfig
    }
    AfterEach {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'copies the config from app_location into the output root' {
        $destination = Copy-SwaConfigFile -ConfigFilePath $script:sourceConfig -DestinationRoot $script:outDir

        $destination | Should -Be (Join-Path $script:outDir 'staticwebapp.config.json')
        Get-Content -LiteralPath $destination -Raw | Should -Be (Get-Content -LiteralPath $script:sourceConfig -Raw)
    }

    It 'accepts a directory as the config location' {
        $destination = Copy-SwaConfigFile -ConfigFilePath $script:appDir -DestinationRoot $script:outDir

        Test-Path -LiteralPath $destination -PathType Leaf | Should -BeTrue
    }

    It 'leaves a config already at the output root alone' {
        $existing = Join-Path $script:outDir 'staticwebapp.config.json'
        '{"routes":[]}' | Set-Content -Path $existing

        Copy-SwaConfigFile -ConfigFilePath $script:sourceConfig -DestinationRoot $script:outDir |
            Should -BeNullOrEmpty
        Get-Content -LiteralPath $existing -Raw | Should -Match '"routes":\[\]'
    }

    It 'is a no-op when the output root is app_location itself' {
        Copy-SwaConfigFile -ConfigFilePath $script:sourceConfig -DestinationRoot $script:appDir |
            Should -BeNullOrEmpty
    }

    It 'throws when the config location has no staticwebapp.config.json' {
        { Copy-SwaConfigFile -ConfigFilePath $script:outDir -DestinationRoot $script:outDir } |
            Should -Throw '*does not contain staticwebapp.config.json*'
    }

    It 'throws when the destination is not a directory' {
        { Copy-SwaConfigFile -ConfigFilePath $script:sourceConfig -DestinationRoot $script:sourceConfig } |
            Should -Throw '*is not a directory*'
    }

    It 'lands the config in the zip once the payload is built from the output directory' {
        'hello' | Set-Content -Path (Join-Path $script:outDir 'index.html')
        $null = Copy-SwaConfigFile -ConfigFilePath $script:sourceConfig -DestinationRoot $script:outDir

        $payload = New-SwaPayload -Path $script:outDir
        try {
            $payload.HasConfigFile | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $payload.WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'ConvertTo-SwaEnvironmentName' {
    # Azure rejects anything outside 0-9a-zA-Z with
    # 'The environment name provided has invalid character(s)'
    It 'strips characters Azure rejects' -ForEach @(
        @{ Branch = 'feature/new-ui'; Expected = 'featurenewui' }
        @{ Branch = 'release-1.2.3'; Expected = 'release123' }
        @{ Branch = 'dependabot/npm_and_yarn/pkg-1.0'; Expected = 'dependabotnpmandyarnpkg10' }
        @{ Branch = 'main'; Expected = 'main' }
        @{ Branch = 'PR42'; Expected = 'PR42' }
    ) {
        ConvertTo-SwaEnvironmentName -Branch $Branch | Should -Be $Expected
    }

    It 'returns empty when nothing usable remains, so the caller can fail loudly' {
        ConvertTo-SwaEnvironmentName -Branch '---' | Should -BeNullOrEmpty
        ConvertTo-SwaEnvironmentName -Branch '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-SwaRemoteZip' {
    BeforeEach {
        $script:target = Join-Path ([System.IO.Path]::GetTempPath()) "swa-dl-$([guid]::NewGuid().ToString('n')).zip"
    }
    AfterEach {
        Remove-Item -LiteralPath $script:target -Force -ErrorAction SilentlyContinue
    }

    It 'rejects a malformed URL before opening a connection' {
        { Get-SwaRemoteZip -ZipUrl 'not a url' -Destination $script:target } |
            Should -Throw '*not a valid absolute URL*'
    }

    It 'rejects non-http schemes' -ForEach @(
        @{ Bad = 'file:///etc/passwd' }, @{ Bad = 'ftp://example.com/x.zip' }
    ) {
        { Get-SwaRemoteZip -ZipUrl $Bad -Destination $script:target } | Should -Throw '*must be http or https*'
    }
}

Describe 'Copy-SwaZipSubdirectory zip-bomb guard' {
    It 'refuses to expand a zip declaring more than the limit' {
        $sourceDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-bomb-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path (Join-Path $sourceDir 'out') -Force
        # Highly compressible, so the declared size dwarfs the zip on disk
        ('a' * 200000) | Set-Content -Path (Join-Path $sourceDir 'out/big.txt') -NoNewline
        $zipFile = "$sourceDir.zip"
        $dest = Join-Path ([System.IO.Path]::GetTempPath()) "swa-bombout-$([guid]::NewGuid().ToString('n')).zip"
        try {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDir, $zipFile)
            { New-SwaPayload -Path $zipFile -ZipSubdirectory 'out' -MaxAppSizeBytes 1024 } |
                Should -Throw '*Refusing to expand the zip*'
        } finally {
            Remove-Item -LiteralPath $sourceDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-SwaVersionRange' {
    It 'accepts wildcards' {
        Test-SwaVersionRange -Version '22.11.0' -Range '*' | Should -BeTrue
    }

    It 'treats a bare major as an X-range' {
        Test-SwaVersionRange -Version '22.11.0' -Range '22' | Should -BeTrue
        Test-SwaVersionRange -Version '23.0.0' -Range '22' | Should -BeFalse
        Test-SwaVersionRange -Version '21.9.9' -Range '22' | Should -BeFalse
    }

    It 'honours minor precision in an X-range' {
        Test-SwaVersionRange -Version '22.11.5' -Range '22.11' | Should -BeTrue
        Test-SwaVersionRange -Version '22.12.0' -Range '22.11' | Should -BeFalse
    }

    It 'matches caret ranges on the minor and patch, not just the major' {
        Test-SwaVersionRange -Version '22.11.0' -Range '^22.10.0' | Should -BeTrue
        # The major-only comparison this replaced wrongly accepted this
        Test-SwaVersionRange -Version '22.9.0' -Range '^22.10.0' | Should -BeFalse
        Test-SwaVersionRange -Version '23.0.0' -Range '^22.10.0' | Should -BeFalse
    }

    It 'pins the minor for caret ranges on 0.x' {
        Test-SwaVersionRange -Version '0.2.9' -Range '^0.2.3' | Should -BeTrue
        Test-SwaVersionRange -Version '0.3.0' -Range '^0.2.3' | Should -BeFalse
    }

    It 'matches tilde ranges on the minor' {
        Test-SwaVersionRange -Version '22.11.9' -Range '~22.11.0' | Should -BeTrue
        Test-SwaVersionRange -Version '22.12.0' -Range '~22.11.0' | Should -BeFalse
    }

    It 'handles comparison operators' {
        Test-SwaVersionRange -Version '22.11.0' -Range '>=20' | Should -BeTrue
        Test-SwaVersionRange -Version '18.0.0' -Range '>=20' | Should -BeFalse
        Test-SwaVersionRange -Version '20.0.0' -Range '>20' | Should -BeFalse
        Test-SwaVersionRange -Version '18.1.0' -Range '<20' | Should -BeTrue
    }

    It 'ANDs space-separated comparators' {
        Test-SwaVersionRange -Version '20.1.0' -Range '>=18 <21' | Should -BeTrue
        Test-SwaVersionRange -Version '22.0.0' -Range '>=18 <21' | Should -BeFalse
    }

    It 'ORs alternatives separated by ||' {
        Test-SwaVersionRange -Version '20.1.0' -Range '18.x || 20.x' | Should -BeTrue
        Test-SwaVersionRange -Version '19.1.0' -Range '18.x || 20.x' | Should -BeFalse
    }

    It 'matches an exact pin exactly' {
        Test-SwaVersionRange -Version '22.11.0' -Range '22.11.0' | Should -BeTrue
        Test-SwaVersionRange -Version '22.11.1' -Range '22.11.0' | Should -BeFalse
    }

    It 'strips a leading v on either side' {
        Test-SwaVersionRange -Version 'v22.11.0' -Range 'v22' | Should -BeTrue
    }

    It 'returns null for a range it cannot parse, rather than guessing' {
        Test-SwaVersionRange -Version '22.11.0' -Range 'lts/hydrogen' | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SwaNodeVersion' {
    BeforeAll {
        # A stand-in for nodejs.org/dist/index.json so the test needs no network
        $script:index = @(
            [pscustomobject]@{ version = 'v23.5.0'; lts = $false }
            [pscustomobject]@{ version = 'v22.12.0'; lts = 'Jod' }
            [pscustomobject]@{ version = 'v22.11.0'; lts = 'Jod' }
            [pscustomobject]@{ version = 'v20.18.1'; lts = 'Iron' }
            [pscustomobject]@{ version = 'v18.20.5'; lts = 'Hydrogen' }
        )
    }

    It 'picks the newest release satisfying the range' {
        (Resolve-SwaNodeVersion -Range '>=20' -Index $script:index).Version | Should -Be '23.5.0'
    }

    It 'stays inside an X-range' {
        (Resolve-SwaNodeVersion -Range '22.x' -Index $script:index).Version | Should -Be '22.12.0'
    }

    It 'respects an upper bound' {
        (Resolve-SwaNodeVersion -Range '>=18 <22' -Index $script:index).Version | Should -Be '20.18.1'
    }

    It 'reports the LTS codename when there is one' {
        (Resolve-SwaNodeVersion -Range '20.x' -Index $script:index).Lts | Should -Be 'Iron'
    }

    It 'returns nothing when no release matches' {
        Resolve-SwaNodeVersion -Range '>=99' -Index $script:index | Should -BeNullOrEmpty
    }
}

Describe 'Get-SwaNodePlatform' {
    It 'maps this machine onto a nodejs.org distribution slug' {
        $platform = Get-SwaNodePlatform
        $platform.Slug | Should -Match '^(linux|darwin|win)-(x64|arm64|x86)$'
        $platform.Extension | Should -BeIn @('tar.gz', 'zip')
    }
}

Describe 'Get-SwaNodeVersionCheck' {
    BeforeEach {
        $script:projectDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-node-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $script:projectDir
    }
    AfterEach {
        Remove-Item -LiteralPath $script:projectDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports nothing requested for a project without engines' {
        '{"name":"x"}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        (Get-SwaNodeVersionCheck -Path $script:projectDir).Requested | Should -BeNullOrEmpty
    }

    It 'reads engines.node like Oryx does' {
        '{"engines":{"node":">=20"}}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        $check = Get-SwaNodeVersionCheck -Path $script:projectDir
        $check.Requested | Should -Be '>=20'
        $check.Source | Should -Be 'package.json engines.node'
        # Named so the warning can suggest node-version-file instead of a literal version
        $check.VersionFile | Should -Be 'package.json'
    }

    It 'prefers engines.node over .nvmrc' {
        '{"engines":{"node":"20.x"}}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        '18' | Set-Content -Path (Join-Path $script:projectDir '.nvmrc')
        (Get-SwaNodeVersionCheck -Path $script:projectDir).Requested | Should -Be '20.x'
    }

    It 'falls back to .nvmrc' {
        '{"name":"x"}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        '18' | Set-Content -Path (Join-Path $script:projectDir '.nvmrc')
        $check = Get-SwaNodeVersionCheck -Path $script:projectDir
        $check.Requested | Should -Be '18'
        $check.Source | Should -Be '.nvmrc'
        $check.VersionFile | Should -Be '.nvmrc'
    }

    It 'flags a mismatch against the installed runtime' {
        # 999 can never be the runner's Node, so this is a deterministic mismatch
        '{"engines":{"node":"999.x"}}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        $check = Get-SwaNodeVersionCheck -Path $script:projectDir
        if ($check.Installed) { $check.Satisfied | Should -BeFalse }
    }

    It 'does not flag a range it cannot parse' {
        '{"engines":{"node":"lts/hydrogen"}}' | Set-Content -Path (Join-Path $script:projectDir 'package.json')
        (Get-SwaNodeVersionCheck -Path $script:projectDir).Satisfied | Should -BeTrue
    }
}

Describe 'New-SwaPayload and Test-SwaQuota' {
    BeforeEach {
        $script:contentDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-payload-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path (Join-Path $script:contentDir 'assets') -Force
        'hello' | Set-Content -Path (Join-Path $script:contentDir 'index.html')
        'x' * 2048 | Set-Content -Path (Join-Path $script:contentDir 'assets/app.js')
        $script:payloads = [System.Collections.Generic.List[string]]::new()
    }
    AfterEach {
        Remove-Item -LiteralPath $script:contentDir -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($dir in $script:payloads) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'measures files and size, excluding directory entries' {
        $payload = New-SwaPayload -Path $script:contentDir
        $script:payloads.Add($payload.WorkDirectory)
        $payload.FileCount | Should -Be 2
        $payload.TotalBytes | Should -BeGreaterThan 2048
        $payload.HasConfigFile | Should -BeFalse
    }

    It 'injects staticwebapp.config.json from config_file_location' {
        $configDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-cfg-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $configDir
        '{"navigationFallback":{"rewrite":"/index.html"}}' | Set-Content -Path (Join-Path $configDir 'staticwebapp.config.json')
        try {
            $payload = New-SwaPayload -Path $script:contentDir -ConfigFilePath $configDir
            $script:payloads.Add($payload.WorkDirectory)
            $payload.HasConfigFile | Should -BeTrue
            $payload.FileCount | Should -Be 3
        } finally {
            Remove-Item -LiteralPath $configDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses an empty payload' {
        $emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-empty-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $emptyDir
        try {
            { New-SwaPayload -Path $emptyDir } | Should -Throw '*empty payload*'
        } finally {
            Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports no violations for a small payload' {
        $payload = New-SwaPayload -Path $script:contentDir
        $script:payloads.Add($payload.WorkDirectory)
        (Test-SwaQuota -Payload $payload) | Should -BeNullOrEmpty
    }

    It 'names the file-count breach and by how much' {
        $payload = New-SwaPayload -Path $script:contentDir
        $script:payloads.Add($payload.WorkDirectory)
        $violations = Test-SwaQuota -Payload $payload -MaxFileCount 1
        $violations | Should -HaveCount 1
        $violations[0] | Should -Match 'file count 2 exceeds .* limit of 1 by 1'
    }

    It 'names the size breach' {
        $payload = New-SwaPayload -Path $script:contentDir
        $script:payloads.Add($payload.WorkDirectory)
        $violations = Test-SwaQuota -Payload $payload -MaxAppSizeBytes 10
        $violations[0] | Should -Match 'app size .* exceeds'
    }

    It 'extracts a subdirectory from an existing zip' {
        $zipSource = Join-Path ([System.IO.Path]::GetTempPath()) "swa-zipsrc-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path (Join-Path $zipSource 'out') -Force
        'built' | Set-Content -Path (Join-Path $zipSource 'out/index.html')
        'ignore me' | Set-Content -Path (Join-Path $zipSource 'readme.txt')
        $zipFile = "$zipSource.zip"
        try {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($zipSource, $zipFile)
            $payload = New-SwaPayload -Path $zipFile -ZipSubdirectory 'out'
            $script:payloads.Add($payload.WorkDirectory)
            $payload.FileCount | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $zipSource -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails clearly when the requested subdirectory is not in the zip' {
        $zipSource = Join-Path ([System.IO.Path]::GetTempPath()) "swa-zipsrc2-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $zipSource
        'x' | Set-Content -Path (Join-Path $zipSource 'index.html')
        $zipFile = "$zipSource.zip"
        try {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($zipSource, $zipFile)
            { New-SwaPayload -Path $zipFile -ZipSubdirectory 'nope' } | Should -Throw '*was not found inside the zip*'
        } finally {
            Remove-Item -LiteralPath $zipSource -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-SwaProperty' {
    It 'returns the default instead of throwing when the property is absent' {
        # StrictMode makes a bare $x.missing a terminating error, which is how a changed API
        # shape used to surface as a PowerShell internal
        $object = [pscustomobject]@{ present = 'yes' }
        Get-SwaProperty -InputObject $object -Name 'missing' -Default 'fallback' | Should -Be 'fallback'
        Get-SwaProperty -InputObject $object -Name 'present' | Should -Be 'yes'
    }

    It 'treats a null value as absent, so an empty API field takes the fallback' {
        $object = [pscustomobject]@{ siteUrl = $null }
        Get-SwaProperty -InputObject $object -Name 'siteUrl' -Default 'fallback' | Should -Be 'fallback'
    }

    It 'reads hashtables as well as objects' {
        Get-SwaProperty -InputObject @{ a = 1 } -Name 'a' | Should -Be 1
        Get-SwaProperty -InputObject @{ a = 1 } -Name 'b' -Default 'none' | Should -Be 'none'
    }

    It 'survives a null input' {
        Get-SwaProperty -InputObject $null -Name 'anything' -Default 'none' | Should -Be 'none'
    }
}

Describe 'Get-SwaConfigReport' {
    BeforeEach {
        $script:configDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-cfg-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $script:configDir
        $script:configFile = Join-Path $script:configDir 'staticwebapp.config.json'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:configDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'counts routes and the roles they name' {
        @'
{
  "routes": [
    { "route": "/admin/*", "allowedRoles": ["admin"] },
    { "route": "/editor/*", "allowedRoles": ["admin", "editor"] },
    { "route": "/public/*" }
  ],
  "navigationFallback": { "rewrite": "/index.html" }
}
'@ | Set-Content -LiteralPath $script:configFile

        $report = Get-SwaConfigReport -ConfigFilePath $script:configFile
        $report.IsValidJson | Should -BeTrue
        $report.HasRoutes | Should -BeTrue
        $report.RouteCount | Should -Be 3
        $report.ProtectedRouteCount | Should -Be 2
        $report.Roles | Should -Be @('admin', 'editor')
        $report.NavigationFallback | Should -Be '/index.html'
    }

    It 'does not count an anonymous route as protected - that is the platform default, not a restriction' {
        '{"routes":[{"route":"/*","allowedRoles":["anonymous"]}]}' | Set-Content -LiteralPath $script:configFile
        $report = Get-SwaConfigReport -ConfigFilePath $script:configFile
        $report.RouteCount | Should -Be 1
        $report.ProtectedRouteCount | Should -Be 0
    }

    It 'counts an authenticated route as protected but not as a custom role' {
        # 'authenticated' requires a login; it is not a role Azure has to provision
        '{"routes":[{"route":"/me","allowedRoles":["authenticated"]}]}' | Set-Content -LiteralPath $script:configFile
        $report = Get-SwaConfigReport -ConfigFilePath $script:configFile
        $report.ProtectedRouteCount | Should -Be 1
        $report.Roles | Should -BeNullOrEmpty
    }

    It 'deduplicates roles named on more than one route' {
        '{"routes":[{"allowedRoles":["admin"]},{"allowedRoles":["admin"]},{"allowedRoles":["Admin"]}]}' |
            Set-Content -LiteralPath $script:configFile
        (Get-SwaConfigReport -ConfigFilePath $script:configFile).Roles | Should -HaveCount 1
    }

    It 'tolerates comments and trailing commas rather than blocking a deployment Azure would accept' {
        @'
{
  // the admin area
  "routes": [
    { "route": "/admin/*", "allowedRoles": ["admin"] },
  ],
}
'@ | Set-Content -LiteralPath $script:configFile

        $report = Get-SwaConfigReport -ConfigFilePath $script:configFile
        $report.IsValidJson | Should -BeTrue
        $report.RouteCount | Should -Be 1
    }

    It 'reports a parse failure instead of throwing, leaving the caller to decide how fatal it is' {
        '{ "routes": [ {' | Set-Content -LiteralPath $script:configFile
        $report = Get-SwaConfigReport -ConfigFilePath $script:configFile
        $report.IsValidJson | Should -BeFalse
        $report.ParseError | Should -Not -BeNullOrEmpty
    }

    It 'reports an empty file as unparseable' {
        '' | Set-Content -LiteralPath $script:configFile
        $report = Get-SwaConfigReport -ConfigFilePath $script:configFile
        $report.IsValidJson | Should -BeFalse
        $report.ParseError | Should -Be 'the file is empty'
    }

    It 'handles a config with no routes at all' {
        '{"navigationFallback":{"rewrite":"/index.html"}}' | Set-Content -LiteralPath $script:configFile
        $report = Get-SwaConfigReport -ConfigFilePath $script:configFile
        $report.IsValidJson | Should -BeTrue
        $report.HasRoutes | Should -BeFalse
        $report.RouteCount | Should -Be 0
    }
}

Describe 'New-SwaPayload config and hygiene reporting' {
    BeforeEach {
        $script:contentDir = Join-Path ([System.IO.Path]::GetTempPath()) "swa-hyg-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $script:contentDir
        'x' | Set-Content -Path (Join-Path $script:contentDir 'index.html')
        $script:payload = $null
    }

    AfterEach {
        if ($script:payload) { Remove-Item -LiteralPath $script:payload.WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:contentDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads the config out of the finished zip, so a build that emitted it into the output dir still counts' {
        # Detection used to look at app_location only, reporting a payload that had a config
        # as one that did not
        '{"routes":[{"route":"/admin/*","allowedRoles":["admin"]}]}' |
            Set-Content -Path (Join-Path $script:contentDir 'staticwebapp.config.json')

        $script:payload = New-SwaPayload -Path $script:contentDir
        $script:payload.HasConfigFile | Should -BeTrue
        $script:payload.ConfigReport.RouteCount | Should -Be 1
        $script:payload.ConfigReport.Roles | Should -Be @('admin')
    }

    It 'reports no config report when there is no config' {
        $script:payload = New-SwaPayload -Path $script:contentDir
        $script:payload.HasConfigFile | Should -BeFalse
        $script:payload.ConfigReport | Should -BeNullOrEmpty
    }

    It 'finds the config inside a zip subdirectory too' {
        $zipSource = Join-Path ([System.IO.Path]::GetTempPath()) "swa-zipcfg-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path (Join-Path $zipSource 'out')
        'x' | Set-Content -Path (Join-Path $zipSource 'out/index.html')
        '{"routes":[{"allowedRoles":["reader"]}]}' | Set-Content -Path (Join-Path $zipSource 'out/staticwebapp.config.json')
        $zipFile = "$zipSource.zip"
        try {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($zipSource, $zipFile)
            $script:payload = New-SwaPayload -Path $zipFile -ZipSubdirectory 'out'
            $script:payload.HasConfigFile | Should -BeTrue
            $script:payload.ConfigReport.Roles | Should -Be @('reader')
        } finally {
            Remove-Item -LiteralPath $zipSource -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a config that will not parse as present but invalid' {
        '{ broken' | Set-Content -Path (Join-Path $script:contentDir 'staticwebapp.config.json')
        $script:payload = New-SwaPayload -Path $script:contentDir
        $script:payload.HasConfigFile | Should -BeTrue
        $script:payload.ConfigReport.IsValidJson | Should -BeFalse
    }

    It 'names anything in the payload that is plainly not web content' {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:contentDir '.git')
        'ref: x' | Set-Content -Path (Join-Path $script:contentDir '.git/HEAD')
        $null = New-Item -ItemType Directory -Path (Join-Path $script:contentDir 'node_modules/pkg')
        'x' | Set-Content -Path (Join-Path $script:contentDir 'node_modules/pkg/index.js')
        'SECRET=x' | Set-Content -Path (Join-Path $script:contentDir '.env.production')

        $script:payload = New-SwaPayload -Path $script:contentDir
        $joined = $script:payload.Warnings -join ' | '
        $joined | Should -Match '\.git'
        $joined | Should -Match 'node_modules'
        $joined | Should -Match '\.env\.production'
    }

    It 'warns about nothing for an ordinary build output' {
        $script:payload = New-SwaPayload -Path $script:contentDir
        # Not just falsy: ', @()' would produce a one-element array that iterates once with
        # an empty string, which is how a blank warning reaches the log
        $script:payload.Warnings.Count | Should -Be 0
    }
}

Describe 'Test-SwaTransientFailure' {
    It 'retries <Message>' -ForEach @(
        @{ Message = 'The content server rejected /api/upload/request with 503 ServiceUnavailable.' }
        @{ Message = 'POST /api/upload/checkstatus returned 429 TooManyRequests.' }
        @{ Message = 'Uploading app.zip failed with 502: BadGateway' }
        @{ Message = 'something 500 something' }
    ) {
        $record = try { throw $Message } catch { $_ }
        Test-SwaTransientFailure -ErrorRecord $record | Should -BeTrue
    }

    It 'does not retry <Message> - the server meant it' -ForEach @(
        @{ Message = 'The content server rejected /api/upload/request with 400. Reason: too many files' }
        @{ Message = 'Invalid deployment token: null/empty or shorter than 104 chars.' }
        @{ Message = 'Uploading app.zip timed out after 1800s.' }
    ) {
        $record = try { throw $Message } catch { $_ }
        Test-SwaTransientFailure -ErrorRecord $record | Should -BeFalse
    }

    It 'retries a connection fault however deeply it is wrapped' {
        $inner = [System.Net.Sockets.SocketException]::new(104)
        $outer = [System.Exception]::new('wrapper', [System.Exception]::new('middle', $inner))
        $record = try { throw $outer } catch { $_ }
        Test-SwaTransientFailure -ErrorRecord $record | Should -BeTrue
    }
}

Describe 'Invoke-SwaWithRetry' {
    It 'retries a transient failure and returns the eventual success' {
        $script:attempts = 0
        $result = Invoke-SwaWithRetry -Operation 'flaky' -WaitAction { } -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 3) { throw 'upstream returned 503 ServiceUnavailable' }
            return 'ok'
        } -WarningAction SilentlyContinue

        $result | Should -Be 'ok'
        $script:attempts | Should -Be 3
    }

    It 'gives up on a failure the server meant, without a second attempt' {
        # Retrying turns a precise two-second rejection into a slow one
        $script:attempts = 0
        {
            Invoke-SwaWithRetry -Operation 'rejected' -WaitAction { } -ScriptBlock {
                $script:attempts++
                throw 'The content server rejected /api/upload/request with 400. Reason: quota'
            } -WarningAction SilentlyContinue
        } | Should -Throw '*400*'
        $script:attempts | Should -Be 1
    }

    It 'stops at MaxAttempts and rethrows the last failure' {
        $script:attempts = 0
        {
            Invoke-SwaWithRetry -Operation 'always down' -MaxAttempts 3 -WaitAction { } -ScriptBlock {
                $script:attempts++
                throw 'upstream returned 503'
            } -WarningAction SilentlyContinue
        } | Should -Throw '*503*'
        $script:attempts | Should -Be 3
    }

    It 'passes a Retry-After hint through to the delay' {
        $script:delays = [System.Collections.Generic.List[double]]::new()
        $script:attempts = 0
        Invoke-SwaWithRetry -Operation 'throttled' -WarningAction SilentlyContinue `
            -WaitAction { param([double]$Seconds) $script:delays.Add($Seconds) } -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 2) { throw 'returned 429 TooManyRequests. Retry-After: 7' }
            return 'ok'
        } | Out-Null

        $script:delays[0] | Should -Be 7
    }
}

Describe 'Read-SwaUploadTicket' {
    It 'reads the SAS URL and polling handle' {
        $response = '{"response":{"packageUris":{"app":"https://blob/app.zip?sig=x"},"pollingInfo":{"defaultHostname":"site.azurestaticapps.net","stageSiteIdentifier":"default","version":"3"}}}' |
            ConvertFrom-Json
        $ticket = Read-SwaUploadTicket -UploadRequest $response
        $ticket.SasUrl | Should -Be 'https://blob/app.zip?sig=x'
        $ticket.DefaultHostname | Should -Be 'site.azurestaticapps.net'
        $ticket.StageSiteIdentifier | Should -Be 'default'
    }

    It 'defaults a missing tenantId rather than tripping StrictMode' {
        $response = '{"response":{"packageUris":{"app":"https://blob/app.zip"},"pollingInfo":{}}}' | ConvertFrom-Json
        (Read-SwaUploadTicket -UploadRequest $response).TenantId | Should -Be ''
    }

    It 'raises the friendly message rather than PropertyNotFoundException when <Case>' -ForEach @(
        @{ Case = 'packageUris is empty'; Json = '{"response":{"packageUris":{}}}'; Expected = '*did not return a SAS URL*' }
        @{ Case = 'the app URL is blank'; Json = '{"response":{"packageUris":{"app":""}}}'; Expected = '*did not return a SAS URL*' }
        @{ Case = 'response is null'; Json = '{"response":null}'; Expected = '*no response body*' }
        @{ Case = 'the body is empty'; Json = '{}'; Expected = '*no response body*' }
    ) {
        # The guard used to be unreachable: the optimistic chain threw first
        $response = $Json | ConvertFrom-Json
        { Read-SwaUploadTicket -UploadRequest $response } | Should -Throw $Expected
    }
}

Describe 'Read-SwaDeploymentStatus' {
    It 'reports a successful deployment as terminal' {
        $status = '{"response":{"deploymentStatus":"Succeeded","siteUrl":"https://site.azurestaticapps.net"}}' | ConvertFrom-Json
        $verdict = Read-SwaDeploymentStatus -Status $status
        $verdict.IsTerminal | Should -BeTrue
        $verdict.Success | Should -BeTrue
        $verdict.SiteUrl | Should -Be 'https://site.azurestaticapps.net'
    }

    It 'falls back to the default hostname when siteUrl comes back empty' {
        # An observed response shape: the deployment is fine, the URL field is not
        $status = '{"response":{"deploymentStatus":"Succeeded","siteUrl":""}}' | ConvertFrom-Json
        $verdict = Read-SwaDeploymentStatus -Status $status -DefaultHostname 'site.azurestaticapps.net'
        $verdict.SiteUrl | Should -Be 'https://site.azurestaticapps.net'
    }

    It 'leaves an absolute URL alone' {
        $status = '{"response":{"deploymentStatus":"Succeeded","siteUrl":"https://already.example"}}' | ConvertFrom-Json
        (Read-SwaDeploymentStatus -Status $status).SiteUrl | Should -Be 'https://already.example'
    }

    It 'treats <DeploymentStatus> as terminal=<Terminal>' -ForEach @(
        @{ DeploymentStatus = 'Succeeded'; Terminal = $true }
        @{ DeploymentStatus = 'Failed'; Terminal = $true }
        @{ DeploymentStatus = 'Canceled'; Terminal = $true }
        @{ DeploymentStatus = 'InProgress'; Terminal = $false }
        @{ DeploymentStatus = 'WaitingForDeployment'; Terminal = $false }
    ) {
        $status = [pscustomobject]@{ response = [pscustomobject]@{ deploymentStatus = $DeploymentStatus } }
        (Read-SwaDeploymentStatus -Status $status).IsTerminal | Should -Be $Terminal
    }

    It 'survives a response shape it has never seen' {
        { Read-SwaDeploymentStatus -Status $null } | Should -Not -Throw
        (Read-SwaDeploymentStatus -Status ('{}' | ConvertFrom-Json)).IsTerminal | Should -BeFalse
    }
}

Describe 'New-SwaDeploymentResult' {
    It 'emits the same properties whichever path built it' {
        # StrictMode makes a property missing from one branch a terminating error on that
        # branch alone - invisible to the linter and to any test taking another path
        $payload = [pscustomobject]@{
            FileCount = 3; TotalBytes = 100; CompressedBytes = 40
            HasConfigFile = $true; ConfigReport = $null; Warnings = @()
        }
        $shapes = @(
            New-SwaDeploymentResult -Status 'WhatIf' -Success $true -Payload $payload
            New-SwaDeploymentResult -Status 'Succeeded' -Success $true -SiteUrl 'https://x' -Payload $payload
            New-SwaDeploymentResult -Status 'Failed' -ErrorText 'boom' -Payload $payload
            New-SwaDeploymentResult -Status 'TimedOut' -ErrorText 'slow' -Payload $payload
            New-SwaDeploymentResult -Status 'Unknown' -ErrorText 'lost contact' -Payload $payload
        )

        $expected = @($shapes[0].PSObject.Properties.Name | Sort-Object)
        $expected | Should -Contain 'Error'
        $expected | Should -Contain 'SiteUrl'
        foreach ($shape in $shapes) {
            @($shape.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
        }
    }

    It 'reads the payload figures rather than making the caller restate them' {
        $payload = [pscustomobject]@{
            FileCount = 7; TotalBytes = 2048; CompressedBytes = 512
            HasConfigFile = $true; ConfigReport = $null; Warnings = @('careful')
        }
        $result = New-SwaDeploymentResult -Status 'Succeeded' -Success $true -Payload $payload
        $result.FileCount | Should -Be 7
        $result.AppSizeBytes | Should -Be 2048
        $result.CompressedBytes | Should -Be 512
        $result.HasConfigFile | Should -BeTrue
        $result.PayloadWarnings | Should -Be @('careful')
    }

    It 'copes with no payload at all, for a failure that never got that far' {
        $result = New-SwaDeploymentResult -Status 'Error' -ErrorText 'bad token'
        $result.FileCount | Should -Be 0
        $result.Success | Should -BeFalse
        $result.Error | Should -Be 'bad token'
    }

    It 'rounds phase timings to a tenth, so a fast package is not reported as zero' {
        $result = New-SwaDeploymentResult -Status 'Succeeded' -Success $true -PackageSeconds 0.34
        $result.PackageSeconds | Should -Be 0.3
    }
}

Describe 'New-SwaPayload config size guard' {
    It 'refuses to inflate an oversized config rather than extracting it' {
        # A downloaded zip reaches the config read without ever having been inflated, so a
        # crafted entry named staticwebapp.config.json is the one thing that could fill the
        # runner's disk before the quota check runs
        $source = Join-Path ([System.IO.Path]::GetTempPath()) "swa-bigcfg-$([guid]::NewGuid().ToString('n'))"
        $null = New-Item -ItemType Directory -Path $source
        'x' | Set-Content -Path (Join-Path $source 'index.html')
        # Highly compressible, so the zip stays small while the entry declares 9 MB
        [System.IO.File]::WriteAllText((Join-Path $source 'staticwebapp.config.json'), ('a' * 9MB))
        $zipFile = "$source.zip"
        $payload = $null
        try {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $zipFile)
            $payload = New-SwaPayload -Path $zipFile
            $payload.HasConfigFile | Should -BeTrue
            $payload.ConfigReport.IsValidJson | Should -BeFalse
            $payload.ConfigReport.ParseError | Should -Match 'over the .* limit'
            # Nothing was written out
            Test-Path (Join-Path $payload.WorkDirectory 'staticwebapp.config.json') | Should -BeFalse
        } finally {
            if ($payload) { Remove-Item -LiteralPath $payload.WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Read-SwaDeploymentStatus hostname fallback' {
    It 'reports no URL rather than a wrong one when there is no fallback to use' {
        # A preview deploy passes no fallback: the upload ticket names the production site,
        # and printing that as the preview URL would send people to the wrong place
        $status = '{"response":{"deploymentStatus":"Succeeded","siteUrl":""}}' | ConvertFrom-Json
        (Read-SwaDeploymentStatus -Status $status -DefaultHostname '').SiteUrl | Should -BeNullOrEmpty
    }
}
