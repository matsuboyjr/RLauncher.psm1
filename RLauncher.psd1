@{
    RootModule        = 'RLauncher.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '228f8ac8-df8d-483d-ad53-d5fb5d8b0443'
    Author            = 'MATSUOKA Hiroshi <matsuboyjr@gmail.com>'
    Copyright         = 'Copyright (c) 2026 MATSUOKA Hiroshi <matsuboyjr@gmail.com>. Licensed under the MIT License.'
    Description       = 'Manage RDP and VNC, directly or over SSH tunnel connection profiles on Windows.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Connect-RLauncher'
        'Get-RLauncherProfile'
        'New-RLauncherProfileSample'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('RDP', 'VNC', 'SSH', 'Windows')
            LicenseUri = 'https://opensource.org/license/mit'
        }
    }
}
