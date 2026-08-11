BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $manifestPath = Join-Path $moduleRoot 'RLauncher.psd1'
    Import-Module $manifestPath -Force
}

Describe 'RLauncher module manifest' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports only the supported public commands' {
        $commands = @(Get-Command -Module RLauncher).Name | Sort-Object
        $commands | Should -Be @(
            'Connect-RLauncher'
            'Get-RLauncherProfile'
            'New-RLauncherProfileSample'
        )
    }
}

Describe 'New-RLauncherProfileSample' {
    It 'creates a readable sample configuration' {
        $path = Join-Path $TestDrive 'profiles.json'

        $result = New-RLauncherProfileSample -Path $path
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

        $result.FullName | Should -Be $path
        $config.settings.defaultRdpPort | Should -Be 3389
        @($config.profiles.PSObject.Properties.Name) | Should -Contain 'linux-vnc-tunnel'
    }

    It 'does not overwrite an existing file without Force' {
        $path = Join-Path $TestDrive 'existing.json'
        Set-Content -LiteralPath $path -Value 'keep me'

        { New-RLauncherProfileSample -Path $path } | Should -Throw '*Use -Force to overwrite*'
        Get-Content -LiteralPath $path -Raw | Should -Match 'keep me'
    }
}

Describe 'Get-RLauncherProfile' {
    BeforeAll {
        $script:profilePath = Join-Path $TestDrive 'list-profiles.json'
        @'
{
  "settings": {
    "defaultRdpPort": 3389,
    "defaultVncPort": 5900
  },
  "profiles": {
    "server-rdp": {
      "type": "rdp",
      "host": "rdp.example.test"
    },
    "server-tunnel": {
      "type": "vnc-tunnel",
      "sshHost": "user@ssh.example.test",
      "remoteHost": "localhost",
      "localPort": 5901,
      "manageSshAgent": false
    }
  }
}
'@ | Set-Content -LiteralPath $script:profilePath -Encoding UTF8
    }

    It 'returns resolved profile information' {
        $profiles = @(Get-RLauncherProfile -ProfilePath $script:profilePath)

        $profiles.Count | Should -Be 2
        ($profiles | Where-Object Name -EQ 'server-rdp').Port | Should -Be 3389
        ($profiles | Where-Object Name -EQ 'server-tunnel').Port | Should -Be 5900
        ($profiles | Where-Object Name -EQ 'server-tunnel').ManageSshAgent | Should -BeFalse
    }

    It 'returns the compact tunnel host notation with Short' {
        $profile = Get-RLauncherProfile -ProfilePath $script:profilePath -Short |
            Where-Object Name -EQ 'server-tunnel'

        $profile.PSObject.Properties.Name | Should -Be @('Name', 'Type', 'Host')
        $profile.Host | Should -Be 'user@ssh.example.test(localhost)'
    }
}

Describe 'RLauncher internal validation and argument building' {
    InModuleScope RLauncher {
        It 'accepts valid ports and rejects values outside the TCP range' {
            Assert-Port -Port '5901' -FieldName 'port' | Should -Be 5901
            { Assert-Port -Port 0 -FieldName 'port' } | Should -Throw '*between 1 and 65535*'
            { Assert-Port -Port 65536 -FieldName 'port' } | Should -Throw '*between 1 and 65535*'
            { Assert-Port -Port 'abc' -FieldName 'port' } | Should -Throw '*numeric TCP port*'
        }

        It 'uses profile settings before global and built-in port defaults' {
            Resolve-ProfilePort -ProfilePort 5902 -DefaultPort 5901 -FallbackPort 5900 -FieldName 'port' |
                Should -Be 5902
            Resolve-ProfilePort -ProfilePort $null -DefaultPort 5901 -FallbackPort 5900 -FieldName 'port' |
                Should -Be 5901
            Resolve-ProfilePort -ProfilePort $null -DefaultPort $null -FallbackPort 5900 -FieldName 'port' |
                Should -Be 5900
        }

        It 'builds VNC Viewer arguments without starting the viewer' {
            $passwordFile = Join-Path $TestDrive 'vnc-password'
            Set-Content -LiteralPath $passwordFile -Value 'test'
            $profile = [pscustomobject]@{ passwdFile = $passwordFile }

            $arguments = @(New-RLauncherVncViewerArgumentList -Profile $profile -HostName '127.0.0.1' -Port 5901)

            $arguments | Should -Be @('127.0.0.1:5901', '-PasswordFile', $passwordFile)
        }

        It 'reports invalid profile fields without making a connection' {
            $config = [pscustomobject]@{
                settings = [pscustomobject]@{ defaultRdpPort = 70000 }
                profiles = [pscustomobject]@{
                    broken = [pscustomobject]@{ type = 'rdp'; port = 0 }
                }
            }

            $errors = @(Validate-RemoteProfileConfig -Config $config | Where-Object Level -EQ 'Error')

            $errors.Field | Should -Contain 'settings.defaultRdpPort'
            $errors.Field | Should -Contain 'rdpFile,host'
            $errors.Field | Should -Contain 'port'
        }

        It 'builds an RDP command without launching a real client' {
            Mock Ensure-Command { 'C:\\Windows\\System32\\mstsc.exe' }
            Mock Start-Process {}
            $config = [pscustomobject]@{ settings = [pscustomobject]@{ defaultRdpPort = 3389 } }
            $profile = [pscustomobject]@{ host = 'rdp.example.test'; port = 3390 }

            Start-RdpConnection -Config $config -Profile $profile

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'mstsc.exe' -and $ArgumentList[0] -eq '/v:rdp.example.test:3390'
            }
        }

        It 'builds an SSH tunnel command without starting a real process' {
            Mock Ensure-Command { 'C:\\Windows\\System32\\OpenSSH\\ssh.exe' }
            Mock Start-Process { [pscustomobject]@{ Id = 1234; HasExited = $false } }
            $profile = [pscustomobject]@{
                sshHost = 'user@ssh.example.test'
                sshPort = 2222
                remoteHost = 'localhost'
                localPort = 5901
            }

            $null = Start-SshTunnel -Profile $profile -RemotePort 5902 -WindowStyle Hidden

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'ssh.exe' -and
                $WindowStyle -eq 'Hidden' -and
                ($ArgumentList -join ' ') -eq '-N -o ExitOnForwardFailure=yes -L 5901:localhost:5902 -p 2222 user@ssh.example.test'
            }
        }
    }
}
