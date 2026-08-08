@{
    RootModule        = 'SwaDeploy.psm1'
    NestedModules     = @('SwaBuild.psm1')
    ModuleVersion     = '0.1.0'
    GUID              = 'b7c4e2a1-9f36-4d58-8e7a-2c1d5f0a3b64'
    Author            = 'CyberDrain'
    Description       = 'Builds and deploys static content to Azure Static Web Apps over the content distribution API, without the official 1.5 GB client container.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'ConvertTo-SwaErrorText',
        'Get-SwaStatusError',
        'Resolve-SwaContentHost',
        'New-SwaPayload',
        'Get-SwaRemoteZip',
        'Resolve-SwaWorkspacePath',
        'Test-SwaQuota',
        'Invoke-SwaDeployment',
        'Get-SwaBuildPlan',
        'Get-SwaPackageManager',
        'Invoke-SwaBuild',
        'Invoke-SwaExternalCommand',
        'Test-SwaVersionRange',
        'Get-SwaNodeVersionCheck'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Azure', 'StaticWebApps', 'Deployment', 'GitHubActions')
            ProjectUri = 'https://github.com/CyberDrain/swa-deploy-action'
        }
    }
}
