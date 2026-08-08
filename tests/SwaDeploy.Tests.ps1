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

Describe 'Test-SwaVersionSatisfies' {
    It 'accepts wildcards' {
        Test-SwaVersionSatisfies -Version '22.11.0' -Range '*' | Should -BeTrue
    }

    It 'treats a bare major as an X-range' {
        Test-SwaVersionSatisfies -Version '22.11.0' -Range '22' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '23.0.0' -Range '22' | Should -BeFalse
        Test-SwaVersionSatisfies -Version '21.9.9' -Range '22' | Should -BeFalse
    }

    It 'honours minor precision in an X-range' {
        Test-SwaVersionSatisfies -Version '22.11.5' -Range '22.11' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '22.12.0' -Range '22.11' | Should -BeFalse
    }

    It 'matches caret ranges on the minor and patch, not just the major' {
        Test-SwaVersionSatisfies -Version '22.11.0' -Range '^22.10.0' | Should -BeTrue
        # The major-only comparison this replaced wrongly accepted this
        Test-SwaVersionSatisfies -Version '22.9.0' -Range '^22.10.0' | Should -BeFalse
        Test-SwaVersionSatisfies -Version '23.0.0' -Range '^22.10.0' | Should -BeFalse
    }

    It 'pins the minor for caret ranges on 0.x' {
        Test-SwaVersionSatisfies -Version '0.2.9' -Range '^0.2.3' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '0.3.0' -Range '^0.2.3' | Should -BeFalse
    }

    It 'matches tilde ranges on the minor' {
        Test-SwaVersionSatisfies -Version '22.11.9' -Range '~22.11.0' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '22.12.0' -Range '~22.11.0' | Should -BeFalse
    }

    It 'handles comparison operators' {
        Test-SwaVersionSatisfies -Version '22.11.0' -Range '>=20' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '18.0.0' -Range '>=20' | Should -BeFalse
        Test-SwaVersionSatisfies -Version '20.0.0' -Range '>20' | Should -BeFalse
        Test-SwaVersionSatisfies -Version '18.1.0' -Range '<20' | Should -BeTrue
    }

    It 'ANDs space-separated comparators' {
        Test-SwaVersionSatisfies -Version '20.1.0' -Range '>=18 <21' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '22.0.0' -Range '>=18 <21' | Should -BeFalse
    }

    It 'ORs alternatives separated by ||' {
        Test-SwaVersionSatisfies -Version '20.1.0' -Range '18.x || 20.x' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '19.1.0' -Range '18.x || 20.x' | Should -BeFalse
    }

    It 'matches an exact pin exactly' {
        Test-SwaVersionSatisfies -Version '22.11.0' -Range '22.11.0' | Should -BeTrue
        Test-SwaVersionSatisfies -Version '22.11.1' -Range '22.11.0' | Should -BeFalse
    }

    It 'strips a leading v on either side' {
        Test-SwaVersionSatisfies -Version 'v22.11.0' -Range 'v22' | Should -BeTrue
    }

    It 'returns null for a range it cannot parse, rather than guessing' {
        Test-SwaVersionSatisfies -Version '22.11.0' -Range 'lts/hydrogen' | Should -BeNullOrEmpty
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
