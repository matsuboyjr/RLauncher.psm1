Set-StrictMode -Version 2.0

function Get-DefaultRemoteProfilePath {
    Join-Path -Path $HOME -ChildPath '.rlauncher\profiles.json'
}

function Get-DefaultRemoteProfileSamplePath {
    Join-Path -Path $HOME -ChildPath '.rlauncher\profiles.sample.json'
}

function Get-RemoteProfileSampleJson {
@'
{
  "settings": {
    "vncViewerPath": "$env:ProgramFiles\\TigerVNC\\vncviewer.exe",
    "defaultRdpPort": 3389,
    "defaultVncPort": 5900,
    "manageSshAgent": true,
    "sshWindowStyle": "Normal"
  },
  "profiles": {
    "win-rdp": {
      "type": "rdp",
      "host": "192.168.1.50",
      "port": 3389
    },
    "win-rdp-file": {
      "type": "rdp",
      "rdpFile": "$HOME\\.rlauncher\\win-rdp.rdp"
    },
    "win-rdp-tunnel": {
      "type": "rdp-tunnel",
      "sshHost": "user@bastion.example.local",
      "remoteHost": "192.168.1.50",
      "remotePort": 3389,
      "localPort": 13389,
      "rdpFile": "$HOME\\.rlauncher\\win-rdp.rdp"
    },
    "linux-vnc-direct": {
      "type": "vnc",
      "host": "192.168.1.60",
      "port": 5900,
      "passwdFile": "$HOME\\.vnc\\linux-passwd"
    },
    "linux-vnc-tunnel": {
      "type": "vnc-tunnel",
      "sshHost": "user@linux.example.local",
      "sshPort": 22,
      "remoteHost": "localhost",
      "remotePort": 5901,
      "localPort": 5901,
      "passwdFile": "$HOME\\.vnc\\linux-passwd",
      "identityFile": "$HOME\\.ssh\\id_ed25519",
      "manageSshAgent": true
    }
  }
}
'@
}

function Test-ObjectProperty {
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.Name -eq $Name) {
            return $true
        }
    }

    return $false
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory = $true)] [string] $Name,
        [object] $Default = $null
    )

    if (Test-ObjectProperty -InputObject $InputObject -Name $Name) {
        return $InputObject.$Name
    }

    return $Default
}

function Assert-Port {
    param(
        [Parameter(Mandatory = $true)] [object] $Port,
        [Parameter(Mandatory = $true)] [string] $FieldName
    )

    $portNumber = 0
    if (-not [int]::TryParse([string]$Port, [ref]$portNumber)) {
        throw "$FieldName must be a numeric TCP port. Value: $Port"
    }

    if ($portNumber -lt 1 -or $portNumber -gt 65535) {
        throw "$FieldName must be between 1 and 65535. Value: $Port"
    }

    return $portNumber
}

function Resolve-ProfilePort {
    param(
        [object] $ProfilePort,
        [object] $DefaultPort,
        [Parameter(Mandatory = $true)] [int] $FallbackPort,
        [Parameter(Mandatory = $true)] [string] $FieldName
    )

    if ($null -ne $ProfilePort -and [string]$ProfilePort -ne '') {
        return Assert-Port -Port $ProfilePort -FieldName $FieldName
    }

    if ($null -ne $DefaultPort -and [string]$DefaultPort -ne '') {
        return Assert-Port -Port $DefaultPort -FieldName $FieldName
    }

    return $FallbackPort
}

function New-ValidationResult {
    param(
        [Parameter(Mandatory = $true)] [string] $Level,
        [string] $ProfileName = '',
        [string] $Field = '',
        [Parameter(Mandatory = $true)] [string] $Message
    )

    New-Object -TypeName PSObject -Property ([ordered]@{
        Level = $Level
        ProfileName = $ProfileName
        Field = $Field
        Message = $Message
    })
}

function Expand-RLauncherPath {
    param(
        [AllowNull()] [object] $Path,
        [string] $FieldName = 'path'
    )

    if ($null -eq $Path) {
        return $null
    }

    $value = [string]$Path
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $value
    }

    if ($value -match '\$HOME(?![A-Za-z0-9_])' -and [string]::IsNullOrWhiteSpace([string]$HOME)) {
        throw "$FieldName references `$HOME, but `$HOME is not set."
    }

    $expanded = [regex]::Replace(
        $value,
        '\$HOME(?![A-Za-z0-9_])',
        [System.Text.RegularExpressions.MatchEvaluator]{ param($match) return [string]$HOME }
    )

    $envMatches = [regex]::Matches($expanded, '\$env:([A-Za-z_][A-Za-z0-9_]*)')
    foreach ($envMatch in $envMatches) {
        $envName = $envMatch.Groups[1].Value
        $envValue = [Environment]::GetEnvironmentVariable($envName)
        if ($null -eq $envValue) {
            throw "$FieldName references undefined environment variable: `$env:$envName"
        }
    }

    $expanded = [regex]::Replace(
        $expanded,
        '\$env:([A-Za-z_][A-Za-z0-9_]*)',
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
        }
    )

    return $expanded
}

function Format-RLauncherPathForMessage {
    param(
        [AllowNull()] [object] $OriginalPath,
        [AllowNull()] [object] $ExpandedPath
    )

    if ($null -eq $OriginalPath) {
        return [string]$ExpandedPath
    }

    if ([string]$OriginalPath -ne [string]$ExpandedPath) {
        return ('{0} (expanded: {1})' -f $OriginalPath, $ExpandedPath)
    }

    return [string]$ExpandedPath
}

function Test-RLauncherPathExistsForValidation {
    param(
        [AllowNull()] [object] $Path,
        [Parameter(Mandatory = $true)] [string] $Field,
        [string] $ProfileName = '',
        [Parameter(Mandatory = $true)] [string] $MissingMessage
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return @()
    }

    try {
        $expandedPath = Expand-RLauncherPath -Path $Path -FieldName $Field
    }
    catch {
        return @(New-ValidationResult -Level 'Error' -ProfileName $ProfileName -Field $Field -Message $_.Exception.Message)
    }

    if (-not (Test-Path -LiteralPath $expandedPath -PathType Leaf)) {
        $displayPath = Format-RLauncherPathForMessage -OriginalPath $Path -ExpandedPath $expandedPath
        return @(New-ValidationResult -Level 'Error' -ProfileName $ProfileName -Field $Field -Message "$MissingMessage $displayPath")
    }

    return @()
}

function Wait-RLauncherTcpPort {
    param(
        [string] $HostName = 'localhost',
        [Parameter(Mandatory = $true)] [int] $Port,
        [int] $TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
            if ($asyncResult.AsyncWaitHandle.WaitOne(500, $false)) {
                try {
                    $client.EndConnect($asyncResult)
                    return $true
                }
                catch {
                    Start-Sleep -Milliseconds 200
                }
            }
            else {
                Start-Sleep -Milliseconds 200
            }
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
        finally {
            if ($null -ne $client) {
                $client.Close()
            }
        }
    }

    return $false
}

function Read-RemoteProfileConfig {
    param(
        [string] $ProfilePath = (Get-DefaultRemoteProfilePath)
    )

    $expandedProfilePath = Expand-RLauncherPath -Path $ProfilePath -FieldName 'ProfilePath'

    if (-not (Test-Path -LiteralPath $expandedProfilePath -PathType Leaf)) {
        $sampleCommand = 'New-RLauncherProfileSample'
        if ($expandedProfilePath -ne (Get-DefaultRemoteProfilePath)) {
            $sampleCommand = "New-RLauncherProfileSample -Path `"$expandedProfilePath.sample`""
        }

        throw "Profile JSON was not found: $(Format-RLauncherPathForMessage -OriginalPath $ProfilePath -ExpandedPath $expandedProfilePath)`nCreate a sample first, for example: $sampleCommand"
    }

    try {
        $json = Get-Content -LiteralPath $expandedProfilePath -Raw -ErrorAction Stop
        return ($json | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Failed to read profile JSON: $(Format-RLauncherPathForMessage -OriginalPath $ProfilePath -ExpandedPath $expandedProfilePath)`n$($_.Exception.Message)"
    }
}

function Resolve-RemoteProfile {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if (-not (Test-ObjectProperty -InputObject $Config -Name 'profiles')) {
        throw "Profile JSON does not contain a 'profiles' object."
    }

    if (-not (Test-ObjectProperty -InputObject $Config.profiles -Name $Name)) {
        $names = @($Config.profiles.PSObject.Properties.Name) | Sort-Object
        $available = if ($names.Count -gt 0) { $names -join ', ' } else { '(none)' }
        throw "Remote profile was not found: $Name`nAvailable profiles: $available"
    }

    return $Config.profiles.$Name
}

function Resolve-VncViewerPath {
    param(
        [Parameter(Mandatory = $true)] [object] $Config
    )

    $settings = Get-ObjectPropertyValue -InputObject $Config -Name 'settings'
    $viewerPath = Get-ObjectPropertyValue -InputObject $settings -Name 'vncViewerPath'

    if ([string]::IsNullOrWhiteSpace([string]$viewerPath)) {
        throw "settings.vncViewerPath is required for VNC profiles."
    }

    $expandedViewerPath = Expand-RLauncherPath -Path $viewerPath -FieldName 'settings.vncViewerPath'
    if (-not (Test-Path -LiteralPath $expandedViewerPath -PathType Leaf)) {
        throw "TigerVNC Viewer was not found at settings.vncViewerPath: $(Format-RLauncherPathForMessage -OriginalPath $viewerPath -ExpandedPath $expandedViewerPath)"
    }

    return [string]$expandedViewerPath
}

function Ensure-Command {
    param(
        [Parameter(Mandatory = $true)] [string] $CommandName
    )

    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command was not found: $CommandName"
    }

    return $command.Source
}

function Resolve-ManageSshAgent {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [object] $Profile
    )

    if (Test-ObjectProperty -InputObject $Profile -Name 'manageSshAgent') {
        return [bool]$Profile.manageSshAgent
    }

    $settings = Get-ObjectPropertyValue -InputObject $Config -Name 'settings'
    if (Test-ObjectProperty -InputObject $settings -Name 'manageSshAgent') {
        return [bool]$settings.manageSshAgent
    }

    return $true
}

function Resolve-SshWindowStyle {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [object] $Profile
    )

    $style = $null
    if (Test-ObjectProperty -InputObject $Profile -Name 'sshWindowStyle') {
        $style = $Profile.sshWindowStyle
    }
    else {
        $settings = Get-ObjectPropertyValue -InputObject $Config -Name 'settings'
        $style = Get-ObjectPropertyValue -InputObject $settings -Name 'sshWindowStyle' -Default 'Normal'
    }

    if ([string]::IsNullOrWhiteSpace([string]$style)) {
        return 'Normal'
    }

    switch ([string]$style) {
        'Normal' { return 'Normal' }
        'Hidden' { return 'Hidden' }
        'Minimized' { return 'Minimized' }
        'Maximized' { return 'Maximized' }
        default {
            throw "sshWindowStyle must be one of: Normal, Hidden, Minimized, Maximized. Value: $style"
        }
    }
}

function Ensure-SshAgent {
    param(
        [string] $IdentityFile
    )

    try {
        $service = Get-Service -Name 'ssh-agent' -ErrorAction Stop
    }
    catch {
        throw "Windows ssh-agent service was not found. Install or enable Windows OpenSSH Client."
    }

    if ($service.Status -ne 'Running') {
        try {
            Start-Service -Name 'ssh-agent' -ErrorAction Stop
        }
        catch {
            throw "Failed to start ssh-agent service. Start it manually or run with manageSshAgent set to false. $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $expandedIdentityFile = Expand-RLauncherPath -Path $IdentityFile -FieldName 'identityFile'
        if (-not (Test-Path -LiteralPath $expandedIdentityFile -PathType Leaf)) {
            throw "identityFile was specified but does not exist: $(Format-RLauncherPathForMessage -OriginalPath $IdentityFile -ExpandedPath $expandedIdentityFile)"
        }

        Ensure-Command -CommandName 'ssh-add.exe' | Out-Null
        $process = Start-Process -FilePath 'ssh-add.exe' -ArgumentList @(ConvertTo-RLauncherNativeArgument -Value $expandedIdentityFile) -NoNewWindow -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -ne 0) {
            throw "ssh-add failed for identityFile: $(Format-RLauncherPathForMessage -OriginalPath $IdentityFile -ExpandedPath $expandedIdentityFile)"
        }
    }
}

function ConvertTo-RLauncherNativeArgument {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Value)

    # Start-Process joins ArgumentList with spaces; quote using Windows argv rules.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Resolve-TunnelRemotePort {
    param([object] $Config, [object] $Profile)

    $isRdp = (Get-ObjectPropertyValue $Profile 'type') -eq 'rdp-tunnel'
    $field = if ($isRdp) { 'defaultRdpPort' } else { 'defaultVncPort' }
    $fallback = if ($isRdp) { 3389 } else { 5900 }
    $settings = Get-ObjectPropertyValue $Config 'settings'
    Resolve-ProfilePort -ProfilePort (Get-ObjectPropertyValue $Profile 'remotePort') -DefaultPort (Get-ObjectPropertyValue $settings $field) -FallbackPort $fallback -FieldName 'remotePort'
}

function Assert-RLauncherLocalPortAvailable {
    param([Parameter(Mandatory = $true)] [int] $Port)

    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Port
    try {
        $listener.Server.ExclusiveAddressUse = $true
        $listener.Start()
    }
    catch {
        throw "Local port 127.0.0.1:$Port is unavailable. Choose a different localPort. $($_.Exception.Message)"
    }
    finally { $listener.Stop() }
}

function Start-SshTunnel {
    param(
        [Parameter(Mandatory = $true)] [object] $Profile,
        [Parameter(Mandatory = $true)] [int] $RemotePort,
        [string] $WindowStyle = 'Normal'
    )

    Ensure-Command -CommandName 'ssh.exe' | Out-Null

    $sshHost = Get-ObjectPropertyValue -InputObject $Profile -Name 'sshHost'
    $sshPort = Get-ObjectPropertyValue -InputObject $Profile -Name 'sshPort'
    $localPort = Get-ObjectPropertyValue -InputObject $Profile -Name 'localPort'
    $remoteHost = Get-ObjectPropertyValue -InputObject $Profile -Name 'remoteHost' -Default '127.0.0.1'
    $identityFile = Get-ObjectPropertyValue -InputObject $Profile -Name 'identityFile'

    if ([string]::IsNullOrWhiteSpace([string]$sshHost)) {
        throw "SSH tunnel profile requires sshHost."
    }

    if ([string]::IsNullOrWhiteSpace([string]$localPort)) {
        throw "SSH tunnel profile requires localPort."
    }

    $localPortNumber = Assert-Port -Port $localPort -FieldName 'localPort'
    $forward = ('{0}:{1}:{2}' -f $localPortNumber, $remoteHost, $RemotePort)
    if ((Get-ObjectPropertyValue $Profile 'type') -eq 'rdp-tunnel') {
        $forward = '127.0.0.1:' + $forward
    }
    $arguments = @('-N', '-o', 'ExitOnForwardFailure=yes', '-L', $forward)

    if ($null -ne $sshPort -and [string]$sshPort -ne '') {
        $sshPortNumber = Assert-Port -Port $sshPort -FieldName 'sshPort'
        $arguments += @('-p', [string]$sshPortNumber)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$identityFile)) {
        $expandedIdentityFile = Expand-RLauncherPath -Path $identityFile -FieldName 'identityFile'
        if (-not (Test-Path -LiteralPath $expandedIdentityFile -PathType Leaf)) {
            throw "identityFile was specified but does not exist: $(Format-RLauncherPathForMessage -OriginalPath $identityFile -ExpandedPath $expandedIdentityFile)"
        }
        $arguments += @('-i', [string]$expandedIdentityFile)
    }

    $arguments += [string]$sshHost
    $arguments = @($arguments | ForEach-Object { ConvertTo-RLauncherNativeArgument -Value $_ })

    try {
        Write-Verbose ("Starting SSH tunnel: ssh.exe {0}" -f ($arguments -join ' '))
        return Start-Process -FilePath 'ssh.exe' -ArgumentList $arguments -PassThru -WindowStyle $WindowStyle -ErrorAction Stop
    }
    catch {
        throw "Failed to start SSH tunnel. Command: ssh.exe $($arguments -join ' ')`n$($_.Exception.Message)"
    }
}

function Start-RdpConnection {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [object] $Profile,
        [string] $HostName,
        [int] $Port,
        [switch] $Wait
    )

    Ensure-Command -CommandName 'mstsc.exe' | Out-Null

    $rdpFile = Get-ObjectPropertyValue -InputObject $Profile -Name 'rdpFile'
    $arguments = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$rdpFile)) {
        $expandedRdpFile = Expand-RLauncherPath -Path $rdpFile -FieldName 'rdpFile'
        if (-not (Test-Path -LiteralPath $expandedRdpFile -PathType Leaf)) {
            throw "rdpFile was specified but does not exist: $(Format-RLauncherPathForMessage -OriginalPath $rdpFile -ExpandedPath $expandedRdpFile)"
        }

        $arguments += ConvertTo-RLauncherNativeArgument -Value $expandedRdpFile
    }

    if ($PSBoundParameters.ContainsKey('HostName')) {
        $port = Assert-Port -Port $Port -FieldName 'localPort'
        $arguments += ConvertTo-RLauncherNativeArgument -Value ('/v:{0}:{1}' -f $HostName, $port)
    }
    elseif ($arguments.Count -eq 0) {
        $hostName = Get-ObjectPropertyValue -InputObject $Profile -Name 'host'
        if ([string]::IsNullOrWhiteSpace([string]$hostName)) {
            throw 'rdp profile requires rdpFile or host.'
        }
        $settings = Get-ObjectPropertyValue -InputObject $Config -Name 'settings'
        $defaultPort = Get-ObjectPropertyValue -InputObject $settings -Name 'defaultRdpPort'
        $profilePort = Get-ObjectPropertyValue -InputObject $Profile -Name 'port'
        $port = Resolve-ProfilePort -ProfilePort $profilePort -DefaultPort $defaultPort -FallbackPort 3389 -FieldName 'port'
        $arguments += ConvertTo-RLauncherNativeArgument -Value ('/v:{0}:{1}' -f $hostName, $port)
    }

    try {
        Write-Verbose ("Starting RDP: mstsc.exe {0}" -f ($arguments -join ' '))
        # Start-Process -Wait also waits for descendants on Windows.
        Start-Process -FilePath 'mstsc.exe' -ArgumentList $arguments -Wait:$Wait -ErrorAction Stop
    }
    catch {
        throw "Failed to start RDP connection. Command: mstsc.exe $($arguments -join ' ')`n$($_.Exception.Message)"
    }
}

function Start-VncConnection {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [object] $Profile,
        [Parameter(Mandatory = $true)] [string] $HostName,
        [Parameter(Mandatory = $true)] [int] $Port,
        [switch] $Wait
    )

    $viewerPath = Resolve-VncViewerPath -Config $Config
    $passwdFile = Get-ObjectPropertyValue -InputObject $Profile -Name 'passwdFile'
    $arguments = New-RLauncherVncViewerArgumentList -Profile $Profile -HostName $HostName -Port $Port

    try {
        Write-Verbose ("Starting VNC Viewer: `"{0}`" {1}" -f $viewerPath, ($arguments -join ' '))
        $process = Start-Process -FilePath $viewerPath -ArgumentList $arguments -PassThru
        if ($Wait -and $null -ne $process) {
            $process.WaitForExit()
        }
        return $process
    }
    catch {
        throw "Failed to start VNC connection. Command: `"$viewerPath`" $($arguments -join ' ')`n$($_.Exception.Message)"
    }
}

function New-RLauncherVncViewerArgumentList {
    param(
        [Parameter(Mandatory = $true)] [object] $Profile,
        [Parameter(Mandatory = $true)] [string] $HostName,
        [Parameter(Mandatory = $true)] [int] $Port
    )

    $passwdFile = Get-ObjectPropertyValue -InputObject $Profile -Name 'passwdFile'
    $target = ('{0}:{1}' -f $HostName, $Port)
    $arguments = @($target)

    if (-not [string]::IsNullOrWhiteSpace([string]$passwdFile)) {
        $expandedPasswdFile = Expand-RLauncherPath -Path $passwdFile -FieldName 'passwdFile'
        if (-not (Test-Path -LiteralPath $expandedPasswdFile -PathType Leaf)) {
            throw "passwdFile was specified but does not exist: $(Format-RLauncherPathForMessage -OriginalPath $passwdFile -ExpandedPath $expandedPasswdFile)"
        }
        $arguments += @('-PasswordFile', [string]$expandedPasswdFile)
    }

    return $arguments
}

function Validate-RemoteProfileConfig {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [string] $ProfileName
    )

    $results = @()
    $settings = Get-ObjectPropertyValue -InputObject $Config -Name 'settings'
    $profiles = Get-ObjectPropertyValue -InputObject $Config -Name 'profiles'

    if ($null -eq $settings) {
        $results += New-ValidationResult -Level 'Error' -Field 'settings' -Message "JSON requires a top-level 'settings' object."
    }

    if ($null -eq $profiles) {
        $results += New-ValidationResult -Level 'Error' -Field 'profiles' -Message "JSON requires a top-level 'profiles' object."
        return $results
    }

    $profileProperties = @($profiles.PSObject.Properties)
    if (-not [string]::IsNullOrWhiteSpace($ProfileName)) {
        $profileProperties = @($profileProperties | Where-Object { $_.Name -eq $ProfileName })
        if ($profileProperties.Count -eq 0) {
            $results += New-ValidationResult -Level 'Error' -ProfileName $ProfileName -Field 'profiles' -Message "Remote profile was not found: $ProfileName"
            return $results
        }
    }

    $sshWindowStyle = Get-ObjectPropertyValue -InputObject $settings -Name 'sshWindowStyle'
    if ($null -ne $sshWindowStyle -and [string]$sshWindowStyle -ne '') {
        try {
            Resolve-SshWindowStyle -Config $Config -Profile (New-Object -TypeName PSObject) | Out-Null
        }
        catch {
            $results += New-ValidationResult -Level 'Error' -Field 'settings.sshWindowStyle' -Message $_.Exception.Message
        }
    }

    $requiresVncViewer = $false
    foreach ($property in $profileProperties) {
        $profileType = Get-ObjectPropertyValue -InputObject $property.Value -Name 'type'
        if ([string]$profileType -eq 'vnc' -or [string]$profileType -eq 'vnc-tunnel') {
            $requiresVncViewer = $true
        }
    }

    if ($requiresVncViewer) {
        $viewerPath = Get-ObjectPropertyValue -InputObject $settings -Name 'vncViewerPath'
        if ([string]::IsNullOrWhiteSpace([string]$viewerPath)) {
            $results += New-ValidationResult -Level 'Error' -Field 'settings.vncViewerPath' -Message 'settings.vncViewerPath is required for VNC profiles.'
        }
        else {
            $results += Test-RLauncherPathExistsForValidation -Path $viewerPath -Field 'settings.vncViewerPath' -MissingMessage 'TigerVNC Viewer was not found:'
        }
    }

    foreach ($defaultPortField in @('defaultRdpPort', 'defaultVncPort')) {
        $defaultPort = Get-ObjectPropertyValue -InputObject $settings -Name $defaultPortField
        if ($null -ne $defaultPort -and [string]$defaultPort -ne '') {
            try {
                Assert-Port -Port $defaultPort -FieldName "settings.$defaultPortField" | Out-Null
            }
            catch {
                $results += New-ValidationResult -Level 'Error' -Field "settings.$defaultPortField" -Message $_.Exception.Message
            }
        }
    }

    foreach ($property in $profileProperties) {
        $name = $property.Name
        $profile = $property.Value
        $type = Get-ObjectPropertyValue -InputObject $profile -Name 'type'

        if ([string]::IsNullOrWhiteSpace([string]$type)) {
            $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'type' -Message 'Profile requires type.'
            continue
        }

        switch ([string]$type) {
            'rdp' {
                $rdpFile = Get-ObjectPropertyValue -InputObject $profile -Name 'rdpFile'
                $hostName = Get-ObjectPropertyValue -InputObject $profile -Name 'host'
                if ([string]::IsNullOrWhiteSpace([string]$rdpFile) -and [string]::IsNullOrWhiteSpace([string]$hostName)) {
                    $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'rdpFile,host' -Message 'rdp profile requires rdpFile or host.'
                }
                $results += Test-RLauncherPathExistsForValidation -Path $rdpFile -Field 'rdpFile' -ProfileName $name -MissingMessage 'rdpFile does not exist:'
                $port = Get-ObjectPropertyValue -InputObject $profile -Name 'port'
                if ($null -ne $port -and [string]$port -ne '') {
                    try {
                        Assert-Port -Port $port -FieldName 'port' | Out-Null
                    }
                    catch {
                        $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'port' -Message $_.Exception.Message
                    }
                }
            }
            'vnc' {
                $hostName = Get-ObjectPropertyValue -InputObject $profile -Name 'host'
                if ([string]::IsNullOrWhiteSpace([string]$hostName)) {
                    $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'host' -Message 'vnc profile requires host.'
                }
                $port = Get-ObjectPropertyValue -InputObject $profile -Name 'port'
                if ($null -ne $port -and [string]$port -ne '') {
                    try {
                        Assert-Port -Port $port -FieldName 'port' | Out-Null
                    }
                    catch {
                        $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'port' -Message $_.Exception.Message
                    }
                }
                $passwdFile = Get-ObjectPropertyValue -InputObject $profile -Name 'passwdFile'
                $results += Test-RLauncherPathExistsForValidation -Path $passwdFile -Field 'passwdFile' -ProfileName $name -MissingMessage 'passwdFile does not exist:'
            }
            { $_ -in @('vnc-tunnel', 'rdp-tunnel') } {
                $sshHost = Get-ObjectPropertyValue -InputObject $profile -Name 'sshHost'
                if ([string]::IsNullOrWhiteSpace([string]$sshHost)) {
                    $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'sshHost' -Message "$type profile requires sshHost."
                }
                $sshPort = Get-ObjectPropertyValue -InputObject $profile -Name 'sshPort'
                if ($null -ne $sshPort -and [string]$sshPort -ne '') {
                    try {
                        Assert-Port -Port $sshPort -FieldName 'sshPort' | Out-Null
                    }
                    catch {
                        $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'sshPort' -Message $_.Exception.Message
                    }
                }
                $profileSshWindowStyle = Get-ObjectPropertyValue -InputObject $profile -Name 'sshWindowStyle'
                if ($null -ne $profileSshWindowStyle -and [string]$profileSshWindowStyle -ne '') {
                    try {
                        Resolve-SshWindowStyle -Config $Config -Profile $profile | Out-Null
                    }
                    catch {
                        $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'sshWindowStyle' -Message $_.Exception.Message
                    }
                }
                $localPort = Get-ObjectPropertyValue -InputObject $profile -Name 'localPort'
                if ([string]::IsNullOrWhiteSpace([string]$localPort)) {
                    $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'localPort' -Message "$type profile requires localPort."
                }
                else {
                    try {
                        Assert-Port -Port $localPort -FieldName 'localPort' | Out-Null
                    }
                    catch {
                        $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'localPort' -Message $_.Exception.Message
                    }
                }
                $remotePort = Get-ObjectPropertyValue -InputObject $profile -Name 'remotePort'
                $remotePortIsValid = $true
                if ($null -ne $remotePort -and [string]$remotePort -ne '') {
                    try {
                        Assert-Port -Port $remotePort -FieldName 'remotePort' | Out-Null
                    }
                    catch {
                        $remotePortIsValid = $false
                        $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'remotePort' -Message $_.Exception.Message
                    }
                }
                if ($type -eq 'vnc-tunnel' -and -not [string]::IsNullOrWhiteSpace([string]$localPort) -and $remotePortIsValid) {
                    try {
                        $effectiveRemotePort = Resolve-TunnelRemotePort -Config $Config -Profile $profile
                        $localPortNumber = Assert-Port -Port $localPort -FieldName 'localPort'
                        $remotePortNumber = Assert-Port -Port $effectiveRemotePort -FieldName 'remotePort'
                        if ($localPortNumber -ne $remotePortNumber) {
                            $remoteHost = Get-ObjectPropertyValue -InputObject $profile -Name 'remoteHost' -Default '127.0.0.1'
                            $message = ('SSH forwarding will use -L {0}:{1}:{2}. Verify this matches your manual ssh -L local:host:remote command.' -f $localPortNumber, $remoteHost, $remotePortNumber)
                            $results += New-ValidationResult -Level 'Warning' -ProfileName $name -Field 'remotePort' -Message $message
                        }
                    }
                    catch {
                    }
                }
                if ($type -eq 'rdp-tunnel') {
                    $rdpFile = Get-ObjectPropertyValue $profile 'rdpFile'
                    $results += Test-RLauncherPathExistsForValidation -Path $rdpFile -Field 'rdpFile' -ProfileName $name -MissingMessage 'rdpFile does not exist:'
                    $remoteHost = Get-ObjectPropertyValue $profile 'remoteHost' -Default '127.0.0.1'
                    if ([string]::IsNullOrWhiteSpace([string]$remoteHost)) {
                        $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'remoteHost' -Message 'remoteHost must not be empty.'
                    }
                }
                $identityFile = Get-ObjectPropertyValue -InputObject $profile -Name 'identityFile'
                $results += Test-RLauncherPathExistsForValidation -Path $identityFile -Field 'identityFile' -ProfileName $name -MissingMessage 'identityFile does not exist:'
                if ($type -eq 'vnc-tunnel') {
                    $passwdFile = Get-ObjectPropertyValue -InputObject $profile -Name 'passwdFile'
                    $results += Test-RLauncherPathExistsForValidation -Path $passwdFile -Field 'passwdFile' -ProfileName $name -MissingMessage 'passwdFile does not exist:'
                }
            }
            default {
                $results += New-ValidationResult -Level 'Error' -ProfileName $name -Field 'type' -Message "Unknown profile type: $type"
            }
        }
    }

    if ($results.Count -eq 0) {
        $results += New-ValidationResult -Level 'Info' -Message 'Profile configuration is valid.'
    }

    return $results
}

function Assert-RLauncherValidation {
    param(
        [object[]] $Results
    )

    foreach ($warning in @($Results | Where-Object { $_.Level -eq 'Warning' })) {
        $prefix = ''
        if (-not [string]::IsNullOrWhiteSpace([string]$warning.ProfileName)) {
            $prefix = "[$($warning.ProfileName)] "
        }
        Write-Warning "$prefix$($warning.Field): $($warning.Message)"
    }

    $errors = @($Results | Where-Object { $_.Level -eq 'Error' })
    if ($errors.Count -gt 0) {
        $messages = @()
        foreach ($errorResult in $errors) {
            $prefix = ''
            if (-not [string]::IsNullOrWhiteSpace([string]$errorResult.ProfileName)) {
                $prefix = "[$($errorResult.ProfileName)] "
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$errorResult.Field)) {
                $messages += ('{0}{1}: {2}' -f $prefix, $errorResult.Field, $errorResult.Message)
            }
            else {
                $messages += ('{0}{1}' -f $prefix, $errorResult.Message)
            }
        }

        throw "Profile validation failed:`n$($messages -join "`n")"
    }
}

function Get-RLauncherProfileObject {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [switch] $Short
    )

    $config = $Config
    if (-not (Test-ObjectProperty -InputObject $config -Name 'profiles')) {
        throw "Profile JSON does not contain a 'profiles' object."
    }

    $settings = Get-ObjectPropertyValue -InputObject $config -Name 'settings'
    foreach ($property in ($config.profiles.PSObject.Properties | Sort-Object Name)) {
        $profile = $property.Value
        $type = Get-ObjectPropertyValue -InputObject $profile -Name 'type'
        $hostValue = Get-ObjectPropertyValue -InputObject $profile -Name 'host'
        $rdpFile = Get-ObjectPropertyValue -InputObject $profile -Name 'rdpFile'
        $port = Get-ObjectPropertyValue -InputObject $profile -Name 'port'
        $sshHost = Get-ObjectPropertyValue -InputObject $profile -Name 'sshHost'
        $sshPort = Get-ObjectPropertyValue -InputObject $profile -Name 'sshPort'
        $localPort = Get-ObjectPropertyValue -InputObject $profile -Name 'localPort'
        $passwdFile = Get-ObjectPropertyValue -InputObject $profile -Name 'passwdFile'
        $identityFile = Get-ObjectPropertyValue -InputObject $profile -Name 'identityFile'
        $manageSshAgent = $null

        if ([string]$type -eq 'rdp' -and [string]::IsNullOrWhiteSpace([string]$port) -and [string]::IsNullOrWhiteSpace([string]$rdpFile)) {
            $port = Get-ObjectPropertyValue -InputObject $settings -Name 'defaultRdpPort' -Default 3389
        }
        elseif ([string]$type -eq 'vnc' -and [string]::IsNullOrWhiteSpace([string]$port)) {
            $port = Get-ObjectPropertyValue -InputObject $settings -Name 'defaultVncPort' -Default 5900
        }
        elseif ([string]$type -in @('vnc-tunnel', 'rdp-tunnel')) {
            $hostValue = Get-ObjectPropertyValue -InputObject $profile -Name 'remoteHost' -Default '127.0.0.1'
            $port = Get-ObjectPropertyValue -InputObject $profile -Name 'remotePort'
            if ([string]::IsNullOrWhiteSpace([string]$port)) {
                $port = Resolve-TunnelRemotePort -Config $config -Profile $profile
            }
            $manageSshAgent = Resolve-ManageSshAgent -Config $config -Profile $profile
        }

        $displayHost = if ($type -eq 'rdp' -and -not [string]::IsNullOrWhiteSpace([string]$rdpFile)) { $rdpFile } else { $hostValue }
        if ($Short) {
            if ([string]$type -in @('vnc-tunnel', 'rdp-tunnel')) {
                $displayHost = ('{0}({1})' -f $sshHost, $hostValue)
            }

            New-Object -TypeName PSObject -Property ([ordered]@{
                Name = $property.Name
                Type = $type
                Host = $displayHost
            })
            continue
        }

        New-Object -TypeName PSObject -Property ([ordered]@{
            Name = $property.Name
            Type = $type
            Host = $displayHost
            Port = $port
            SshHost = $sshHost
            SshPort = $sshPort
            LocalPort = $localPort
            PasswdFile = $passwdFile
            IdentityFile = $identityFile
            ManageSshAgent = $manageSshAgent
        })
    }
}

function Get-RLauncherProfile {
    [CmdletBinding()]
    param(
        [string] $ProfilePath = (Get-DefaultRemoteProfilePath),
        [switch] $Short
    )

    $config = Read-RemoteProfileConfig -ProfilePath $ProfilePath
    Get-RLauncherProfileObject -Config $config -Short:$Short
}

function New-RLauncherProfileSample {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string] $Path = (Get-DefaultRemoteProfileSamplePath),
        [switch] $Force
    )

    $expandedPath = Expand-RLauncherPath -Path $Path -FieldName 'Path'
    $directory = Split-Path -Parent $expandedPath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($directory, 'Create directory')) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
    }

    if ((Test-Path -LiteralPath $expandedPath -PathType Leaf) -and -not $Force) {
        throw "Sample profile already exists: $(Format-RLauncherPathForMessage -OriginalPath $Path -ExpandedPath $expandedPath). Use -Force to overwrite."
    }

    if ($PSCmdlet.ShouldProcess($expandedPath, 'Write sample profile JSON')) {
        Get-RemoteProfileSampleJson | Set-Content -LiteralPath $expandedPath -Encoding UTF8 -ErrorAction Stop
    }

    Get-Item -LiteralPath $expandedPath -ErrorAction Stop
}

function Invoke-RLauncherTunnelConnection {
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [object] $Profile
    )

    $type = Get-ObjectPropertyValue $Profile 'type'
    $remotePort = Resolve-TunnelRemotePort -Config $Config -Profile $Profile
    $localPort = Assert-Port -Port (Get-ObjectPropertyValue $Profile 'localPort') -FieldName 'localPort'
    $remoteHost = Get-ObjectPropertyValue $Profile 'remoteHost' -Default '127.0.0.1'
    $sshHost = Get-ObjectPropertyValue $Profile 'sshHost'
    $sshPort = Get-ObjectPropertyValue $Profile 'sshPort'
    $forward = '{0}:{1}:{2}' -f $localPort, $remoteHost, $remotePort
    if ($type -eq 'rdp-tunnel') { $forward = '127.0.0.1:' + $forward }
    $context = "sshHost: $sshHost, sshPort: $sshPort, forwarding: -L $forward"
    $sshWindowStyle = Resolve-SshWindowStyle -Config $Config -Profile $Profile
    $identityFile = Get-ObjectPropertyValue $Profile 'identityFile'
    $sshProcess = $null

    Assert-RLauncherLocalPortAvailable -Port $localPort
    if ($type -eq 'rdp-tunnel') { Ensure-Command -CommandName 'mstsc.exe' | Out-Null }
    if (Resolve-ManageSshAgent -Config $Config -Profile $Profile) {
        Ensure-SshAgent -IdentityFile $identityFile
    }

    try {
        $sshProcess = Start-SshTunnel -Profile $Profile -RemotePort $remotePort -WindowStyle $sshWindowStyle
        Start-Sleep -Milliseconds 300
        if ($null -eq $sshProcess -or $sshProcess.HasExited) {
            throw "SSH tunnel process exited before the client was started. $context"
        }
        if (-not (Wait-RLauncherTcpPort -HostName '127.0.0.1' -Port $localPort -TimeoutSeconds 10)) {
            throw "SSH tunnel did not open 127.0.0.1:$localPort within 10 seconds. $context"
        }
        if ($sshProcess.HasExited) {
            throw "SSH tunnel process exited after opening check and before the client was started. $context"
        }

        if ($type -eq 'rdp-tunnel') {
            # The port can be claimed by another process while SSH authentication is pending.
            $listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $localPort -State Listen -ErrorAction Stop)
            if (-not ($listeners | Where-Object { $_.OwningProcess -eq $sshProcess.Id })) {
                throw "Local port 127.0.0.1:$localPort is not owned by the SSH tunnel process. $context"
            }
            Start-RdpConnection -Config $Config -Profile $Profile -HostName '127.0.0.1' -Port $localPort -Wait
        }
        else {
            $null = Start-VncConnection -Config $Config -Profile $Profile -HostName '127.0.0.1' -Port $localPort -Wait
        }
    }
    finally {
        if ($null -ne $sshProcess -and -not $sshProcess.HasExited) {
            Stop-Process -Id $sshProcess.Id -ErrorAction SilentlyContinue
        }
    }
}

function Connect-RLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $Name,
        [string] $ProfilePath = (Get-DefaultRemoteProfilePath)
    )

    $config = Read-RemoteProfileConfig -ProfilePath $ProfilePath

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $validationResults = Validate-RemoteProfileConfig -Config $config
        Assert-RLauncherValidation -Results $validationResults
        return Get-RLauncherProfileObject -Config $config -Short
    }

    $profile = Resolve-RemoteProfile -Config $config -Name $Name
    $validationResults = Validate-RemoteProfileConfig -Config $config -ProfileName $Name
    Assert-RLauncherValidation -Results $validationResults
    $type = Get-ObjectPropertyValue -InputObject $profile -Name 'type'

    switch ([string]$type) {
        'rdp' {
            Start-RdpConnection -Config $config -Profile $profile
        }
        'vnc' {
            $hostName = Get-ObjectPropertyValue -InputObject $profile -Name 'host'
            if ([string]::IsNullOrWhiteSpace([string]$hostName)) {
                throw "vnc profile requires host."
            }

            $settings = Get-ObjectPropertyValue -InputObject $config -Name 'settings'
            $defaultPort = Get-ObjectPropertyValue -InputObject $settings -Name 'defaultVncPort'
            $profilePort = Get-ObjectPropertyValue -InputObject $profile -Name 'port'
            $port = Resolve-ProfilePort -ProfilePort $profilePort -DefaultPort $defaultPort -FallbackPort 5900 -FieldName 'port'
            $null = Start-VncConnection -Config $config -Profile $profile -HostName ([string]$hostName) -Port $port
        }
        { $_ -in @('vnc-tunnel', 'rdp-tunnel') } {
            Invoke-RLauncherTunnelConnection -Config $config -Profile $profile
        }
        default {
            if ([string]::IsNullOrWhiteSpace([string]$type)) {
                throw "Profile '$Name' does not specify type."
            }
            throw "Unknown profile type for '$Name': $type"
        }
    }
}

Export-ModuleMember -Function Connect-RLauncher, Get-RLauncherProfile, New-RLauncherProfileSample
