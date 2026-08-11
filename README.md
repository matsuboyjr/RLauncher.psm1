# RLauncher

RLauncher is a small PowerShell module for managing RDP, VNC, and VNC over SSH tunnel connection profiles on Windows. It uses the built-in Windows OpenSSH Client (`ssh.exe` and `ssh-agent`), requires no WSL, and is compatible with Windows PowerShell 5.1.

## Installation

Add the following line to your PowerShell profile, replacing the path with the
location of `RLauncher.psd1`:

```powershell
Import-Module 'C:\path\to\RLauncher\RLauncher.psd1'
```

Windows PowerShell 5.1 and PowerShell 7 use separate `$PROFILE` files. Add the
line to each profile where you want RLauncher to load automatically.

## Configuration

The default profile path is `$HOME\.rlauncher\profiles.json`. Create and edit a sample as follows:

```powershell
New-RLauncherProfileSample
Copy-Item "$HOME\.rlauncher\profiles.sample.json" "$HOME\.rlauncher\profiles.json"
notepad "$HOME\.rlauncher\profiles.json"
```

Use `-ProfilePath` to select another JSON file:

```powershell
Get-RLauncherProfile -ProfilePath C:\path\to\profiles.json
Connect-RLauncher win-rdp -ProfilePath C:\path\to\profiles.json
```

Set the TigerVNC Viewer path once in `settings.vncViewerPath`. Local file paths may contain `$HOME` and `$env:NAME`. Expansion is supported for `settings.vncViewerPath`, `rdpFile`, `passwdFile`, `identityFile`, `-ProfilePath`, and `New-RLauncherProfileSample -Path`. Variables are not expanded in `host`, `sshHost`, or `remoteHost`. The cmd.exe-style `%USERPROFILE%` syntax is not supported.

```json
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
```

## Usage

List profiles in full or compact form:

```powershell
Get-RLauncherProfile
Get-RLauncherProfile -Short
```

The full list contains `Name`, `Type`, `Host`, `Port`, `SshHost`, `SshPort`, `LocalPort`, `PasswdFile`, `IdentityFile`, and `ManageSshAgent`. The compact list contains only `Name`, `Type`, and `Host`. A tunnel host is displayed as `sshHost(remoteHost)`.

When the profile name is omitted, `Connect-RLauncher` validates the configuration and displays the compact list. Validation errors are displayed instead of the list.

```powershell
Connect-RLauncher
Connect-RLauncher win-rdp
Connect-RLauncher win-rdp-file
Connect-RLauncher linux-vnc-direct
Connect-RLauncher linux-vnc-tunnel
```

For RDP, RLauncher starts either `mstsc.exe <rdpFile>` or `mstsc.exe /v:host:port`.

For VNC over SSH, it starts `ssh.exe -N -L localPort:remoteHost:remotePort sshHost`, waits for `127.0.0.1:localPort`, and starts VNC Viewer once. If `sshPort` is configured, it adds `-p sshPort`. When VNC Viewer exits, RLauncher stops only the SSH process that it started.

SSH uses a visible normal window by default so password, passphrase, and first-time host-key prompts remain visible. Set `settings.sshWindowStyle` or the profile-level `sshWindowStyle` to `"Hidden"` when prompts are not needed.

Use `-Verbose` to inspect the generated arguments:

```powershell
Connect-RLauncher linux-vnc-tunnel -Verbose
```

## ssh-agent

RLauncher manages `ssh-agent` only for `vnc-tunnel` profiles. `settings.manageSshAgent` defaults to `true`, and a profile-level setting takes precedence. You may omit `sshPort` when it is defined by an SSH config alias. The `user@host:2222` syntax is not supported in `sshHost`.

To start `ssh-agent` automatically with Windows, optionally run the following from an elevated PowerShell session. RLauncher does not change the service startup type automatically.

```powershell
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service ssh-agent
```

When `identityFile` is specified, RLauncher runs `ssh-add <identityFile>` each time.

## VNC password files

The password file is passed as `vncviewer.exe 127.0.0.1:5901 -PasswordFile <passwdFile>`. Do not store a plaintext password in the command line or profile JSON.

Some traditional VNC authentication implementations use only the first eight password characters. Depending on the server and viewer, later characters may be ignored.

## Commands

```powershell
Connect-RLauncher [[-Name] <string>] [-ProfilePath <string>]
Get-RLauncherProfile [-ProfilePath <string>] [-Short]
New-RLauncherProfileSample [-Path <string>] [-Force]
```

## Verification

1. Import the module with `Import-Module .\RLauncher.psd1 -Force`.
2. Run `New-RLauncherProfileSample -Path .\profiles.generated.json`.
3. Run `Connect-RLauncher -ProfilePath .\profiles.generated.json` to validate the file and display the list. Missing viewer, RDP, identity, and password files are reported as errors.
4. Create a configuration containing valid paths and run `Connect-RLauncher <profile-name>`.

With Pester 5 installed, run the unit tests. They do not establish real remote connections.

```powershell
Invoke-Pester .\Tests -Output Detailed
```

## License

This project is licensed under the MIT License. See `LICENSE` for details.
