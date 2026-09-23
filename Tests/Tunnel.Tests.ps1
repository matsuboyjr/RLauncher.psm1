BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'RLauncher.psd1') -Global
}

Describe 'RDP tunnel profiles' {
    InModuleScope RLauncher {
        BeforeEach {
            $profile = [pscustomobject]@{ type = 'rdp-tunnel'; sshHost = 'jump'; localPort = 13389; manageSshAgent = $false }
            $config = [pscustomobject]@{ settings = [pscustomobject]@{}; profiles = [pscustomobject]@{ desktop = $profile } }
        }

        It 'accepts an RDP-only configuration without VNC or RDP files' {
            @(Validate-RemoteProfileConfig $config | Where-Object Level -EQ Error).Count | Should -Be 0
        }

        It 'uses RDP defaults and preserves listing columns' {
            $full = Get-RLauncherProfileObject $config
            $full.Port | Should -Be 3389
            $full.Host | Should -Be '127.0.0.1'
            $full.LocalPort | Should -Be 13389
            $full.ManageSshAgent | Should -BeFalse
            (Get-RLauncherProfileObject $config -Short).Host | Should -Be 'jump(127.0.0.1)'
            $config.settings | Add-Member defaultRdpPort 3390
            (Get-RLauncherProfileObject $config).Port | Should -Be 3390
            $profile | Add-Member remotePort 3391
            (Resolve-TunnelRemotePort $config $profile) | Should -Be 3391
            (Get-RLauncherProfileObject $config).Port | Should -Be 3391
        }

        It 'validates required fields, ports, paths and window style' {
            $profile.sshHost = ''
            $profile.localPort = 0
            $profile | Add-Member sshPort 65536
            $profile | Add-Member remotePort 'bad'
            $profile | Add-Member remoteHost ''
            $profile | Add-Member rdpFile (Join-Path $TestDrive 'absent.rdp')
            $profile | Add-Member identityFile (Join-Path $TestDrive 'absent.key')
            $profile | Add-Member sshWindowStyle 'bad'
            $errors = @(Validate-RemoteProfileConfig $config | Where-Object Level -EQ Error)
            foreach ($field in @('sshHost', 'localPort', 'sshPort', 'remotePort', 'remoteHost', 'rdpFile', 'identityFile', 'sshWindowStyle')) {
                $errors.Field | Should -Contain $field
            }
            $profile.localPort = $null
            (Validate-RemoteProfileConfig $config | Where-Object Field -EQ localPort).Message | Should -Match 'requires localPort'
        }

        It 'shows the tunnel destination rather than the optional RDP file' {
            $profile | Add-Member rdpFile 'desktop.rdp'
            (Get-RLauncherProfileObject $config).Host | Should -Be '127.0.0.1'
        }

        It 'reports invalid global defaults without throwing out of validation' {
            $config.settings | Add-Member defaultRdpPort 70000
            $errors = @(Validate-RemoteProfileConfig $config | Where-Object Level -EQ Error)
            $errors.Field | Should -Contain 'settings.defaultRdpPort'
        }

        It 'inherits SSH preferences from settings unless the profile overrides them' {
            $config.settings | Add-Member manageSshAgent $true
            $config.settings | Add-Member sshWindowStyle Hidden
            (Resolve-ManageSshAgent $config $profile) | Should -BeFalse
            (Resolve-SshWindowStyle $config $profile) | Should -Be 'Hidden'
            $profile.PSObject.Properties.Remove('manageSshAgent')
            (Resolve-ManageSshAgent $config $profile) | Should -BeTrue
            $profile | Add-Member sshWindowStyle Minimized
            (Resolve-SshWindowStyle $config $profile) | Should -Be 'Minimized'
        }

        It 'uses the same sample for generated and distributed configurations' {
            $sample = Get-RemoteProfileSampleJson | ConvertFrom-Json
            $distributed = Get-Content (Join-Path (Split-Path (Get-Module RLauncher).Path) 'profiles.sample.json') -Raw | ConvertFrom-Json
            ($sample | ConvertTo-Json -Depth 10) | Should -Be ($distributed | ConvertTo-Json -Depth 10)
            $sample.profiles.'win-rdp-tunnel'.type | Should -Be 'rdp-tunnel'
        }
    }
}

Describe 'RDP and SSH native arguments' {
    InModuleScope RLauncher {
        BeforeEach {
            Mock Ensure-Command { 'mock.exe' }
            Mock Start-Process { [pscustomobject]@{ Id = 1234; HasExited = $false; ExitCode = 0 } }
            $config = [pscustomobject]@{ settings = [pscustomobject]@{} }
            $profile = [pscustomobject]@{ type = 'rdp-tunnel'; sshHost = 'jump'; localPort = 13389 }
        }

        It 'starts RDP with a local endpoint and waits for the process tree' {
            Start-RdpConnection $config $profile -HostName '127.0.0.1' -Port 13389 -Wait
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'mstsc.exe' -and $Wait -and $ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq '/v:127.0.0.1:13389'
            }
        }

        It 'quotes an RDP file, overrides its destination, and preserves its contents' {
            $rdpPath = Join-Path $TestDrive '日本語 desktop.rdp'
            Set-Content $rdpPath 'full address:s:original.example'
            $before = (Get-FileHash $rdpPath).Hash
            $profile | Add-Member rdpFile $rdpPath
            Start-RdpConnection $config $profile -HostName '127.0.0.1' -Port 13389 -Wait
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[0] -eq ('"' + $rdpPath + '"') -and $ArgumentList[1] -eq '/v:127.0.0.1:13389' -and $Wait
            }
            (Get-FileHash $rdpPath).Hash | Should -Be $before
        }

        It 'keeps direct file connections nonblocking and file-only' {
            $rdpPath = Join-Path $TestDrive 'desktop.rdp'
            Set-Content $rdpPath 'full address:s:original.example'
            $profile | Add-Member rdpFile $rdpPath
            Start-RdpConnection $config $profile
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { -not $Wait -and $ArgumentList.Count -eq 1 }
        }

        It 'binds RDP forwarding explicitly to IPv4 loopback and quotes the identity path' {
            $identity = Join-Path $TestDrive '日本語 key'
            Set-Content $identity 'test'
            $profile | Add-Member identityFile $identity
            $null = Start-SshTunnel $profile -RemotePort 3389 -WindowStyle Hidden
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'ssh.exe' -and $ArgumentList[4] -eq '127.0.0.1:13389:127.0.0.1:3389' -and
                $ArgumentList[6] -eq ('"' + $identity + '"') -and $ArgumentList[-1] -eq 'jump' -and $WindowStyle -eq 'Hidden'
            }
        }

        It 'quotes the same identity when adding it to ssh-agent' {
            Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
            $identity = Join-Path $TestDrive '日本語 key'
            Set-Content $identity 'test'
            Ensure-SshAgent -IdentityFile $identity
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'ssh-add.exe' -and $ArgumentList[0] -eq ('"' + $identity + '"')
            }
        }
    }
}

Describe 'Tunnel lifetime and failure cleanup' {
    InModuleScope RLauncher {
        BeforeEach {
            $profile = [pscustomobject]@{ type = 'rdp-tunnel'; sshHost = 'jump'; localPort = 13389; manageSshAgent = $false }
            $config = [pscustomobject]@{ settings = [pscustomobject]@{}; profiles = [pscustomobject]@{ desktop = $profile } }
            $script:tunnelProcess = [pscustomobject]@{ Id = 1234; HasExited = $false }
            Mock Assert-RLauncherLocalPortAvailable {}
            Mock Ensure-Command { 'mock.exe' }
            Mock Ensure-SshAgent {}
            Mock Start-Sleep {}
            Mock Start-SshTunnel { $script:tunnelProcess }
            Mock Wait-RLauncherTcpPort { $true }
            Mock Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 1234 } }
            Mock Start-RdpConnection {}
            Mock Start-VncConnection {}
            Mock Stop-Process {}
        }

        It 'routes the public command through the tunnel and cleans up after the client' {
            Mock Read-RemoteProfileConfig { $config }
            Connect-RLauncher desktop
            Should -Invoke Start-RdpConnection -Times 1 -Exactly -ParameterFilter { $Wait -and $HostName -eq '127.0.0.1' -and $Port -eq 13389 }
            Should -Invoke Start-SshTunnel -Times 1 -Exactly -ParameterFilter { $RemotePort -eq 3389 }
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 1234 }
            Should -Invoke Ensure-SshAgent -Times 0 -Exactly
        }

        It 'does not stop SSH until the client returns' {
            Mock Start-RdpConnection { Should -Invoke Stop-Process -Times 0 -Exactly }
            Invoke-RLauncherTunnelConnection $config $profile
            Should -Invoke Stop-Process -Times 1 -Exactly
        }

        It 'respects profile agent and window preferences' {
            $profile.manageSshAgent = $true
            $profile | Add-Member sshWindowStyle Hidden
            Invoke-RLauncherTunnelConnection $config $profile
            Should -Invoke Ensure-SshAgent -Times 1 -Exactly
            Should -Invoke Start-SshTunnel -Times 1 -Exactly -ParameterFilter { $WindowStyle -eq 'Hidden' }
        }

        It 'does not start anything if the local port is unavailable' {
            Mock Assert-RLauncherLocalPortAvailable { throw 'occupied' }
            { Invoke-RLauncherTunnelConnection $config $profile } | Should -Throw '*occupied*'
            Should -Invoke Start-SshTunnel -Times 0 -Exactly
            Should -Invoke Start-RdpConnection -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 0 -Exactly
        }

        It 'does not launch a client or stop unrelated processes if SSH fails to start' {
            Mock Start-SshTunnel { throw 'start failed' }
            { Invoke-RLauncherTunnelConnection $config $profile } | Should -Throw '*start failed*'
            Should -Invoke Start-RdpConnection -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 0 -Exactly
        }

        It 'rejects SSH early exit without killing an already exited process' {
            $script:tunnelProcess.HasExited = $true
            { Invoke-RLauncherTunnelConnection $config $profile } | Should -Throw '*exited before*'
            Should -Invoke Start-RdpConnection -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 0 -Exactly
        }

        It 'cleans up on readiness timeout' {
            Mock Wait-RLauncherTcpPort { $false }
            { Invoke-RLauncherTunnelConnection $config $profile } | Should -Throw '*within 10 seconds*'
            Should -Invoke Start-RdpConnection -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 1234 }
        }

        It 'checks SSH again after probing the port' {
            Mock Wait-RLauncherTcpPort { $script:tunnelProcess.HasExited = $true; $true }
            { Invoke-RLauncherTunnelConnection $config $profile } | Should -Throw '*after opening check*'
            Should -Invoke Start-RdpConnection -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 0 -Exactly
        }

        It 'cleans up when RDP fails to launch' {
            Mock Start-RdpConnection { throw 'client failed' }
            { Invoke-RLauncherTunnelConnection $config $profile } | Should -Throw '*client failed*'
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 1234 }
        }

        It 'rejects a port claimed by another process during SSH authentication' {
            Mock Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 9999 } }
            { Invoke-RLauncherTunnelConnection $config $profile } | Should -Throw '*not owned by the SSH tunnel*'
            Should -Invoke Start-RdpConnection -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 1234 }
        }

        It 'also waits and cleans up for VNC' {
            $profile.type = 'vnc-tunnel'
            Invoke-RLauncherTunnelConnection $config $profile
            Should -Invoke Start-VncConnection -Times 1 -Exactly -ParameterFilter { $Wait -and $HostName -eq '127.0.0.1' }
            Should -Invoke Start-SshTunnel -Times 1 -Exactly -ParameterFilter { $RemotePort -eq 5900 }
            Should -Invoke Start-RdpConnection -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 1234 }
        }
    }
}

Describe 'Local port availability' {
    InModuleScope RLauncher {
        It 'rejects an occupied loopback port and releases its own probe' {
            $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
            $listener.Start()
            $port = $listener.LocalEndpoint.Port
            try {
                { Assert-RLauncherLocalPortAvailable $port } | Should -Throw '*unavailable*'
            }
            finally { $listener.Stop() }
            { Assert-RLauncherLocalPortAvailable $port } | Should -Not -Throw
            { Assert-RLauncherLocalPortAvailable $port } | Should -Not -Throw
        }
    }
}
