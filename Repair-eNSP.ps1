#Requires -Version 5.1
<#
.SYNOPSIS
Reversible fixes for eNSP window dragging and clipboard release.
.DESCRIPTION
Check is read-only. Apply and Restore validate full file hashes, preserve a
verified original backup, use an exclusive handle, and verify every write.
.EXAMPLE
.\Repair-eNSP.ps1 -Mode Check
.EXAMPLE
.\Repair-eNSP.ps1 -Mode Apply
.EXAMPLE
.\Repair-eNSP.ps1 -Mode Apply -Fix Clipboard -EnspPath 'E:\Huawei\eNSP'
.EXAMPLE
.\Repair-eNSP.ps1 -Mode Restore -Fix Clipboard
.NOTES
Copyright (c) 2026 Kayro (jeoor). MIT License.
Window-drag analysis reference: https://cmxz.top/2541/
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Apply', 'Restore')]
    [string]$Mode = 'Check',
    [ValidateSet('All', 'VisualEffects', 'Clipboard')]
    [string]$Fix = 'All',
    [string]$EnspPath,
    [switch]$NoElevation,
    [string]$ErrorLog
)

$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$originalHash = 'e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e'
# Flags are ordered: window-drag repair, clipboard-release repair.
$stateTable = @{
    'e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e' = '00'
    '8bf1ad0d35310905020b20f0ffef419e34f685c90666162de762006df176d20f' = '10'
    'e567ddfabd65000b440211dd5e5a3b149b36e766c7619daaf0fdcd0ea65e230b' = '01'
    '50e64999d0f3e9937fb8131066dd22615eda90c64b7bbdd64d5b4b937d2e4ed7' = '11'
}
$definitions = @(
    [pscustomobject]@{
        Id='VisualEffects'; Index=0; Offset=0x3BE2B; Original=0x74; Patched=0xEB
        ContextOffset=0x3BE2B; ContextIndex=0
        Context=[byte[]](0x74,0x0A,0x6A,0,0x6A,0,0x6A,0,0x6A,0x25,0xFF,0xD6)
    }
    [pscustomobject]@{
        Id='Clipboard'; Index=1; Offset=0xD5A90; Original=0xB6; Patched=0x7A
        ContextOffset=0xD5A8E; ContextIndex=2
        Context=[byte[]](0x0F,0x84,0xB6,0,0,0)
    }
)

function Get-BytesHash([byte[]]$Data) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Data))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Read-LockedBytes([IO.FileStream]$Stream) {
    $memory = New-Object IO.MemoryStream
    try {
        [void]$Stream.Seek(0, [IO.SeekOrigin]::Begin)
        $Stream.CopyTo($memory)
        return ,$memory.ToArray()
    } finally { $memory.Dispose() }
}


function Resolve-EnspExecutable([string]$RequestedPath) {
    if ($RequestedPath) {
        $resolved = [Environment]::ExpandEnvironmentVariables($RequestedPath)
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $resolved = Join-Path $resolved 'eNSP_Client.exe'
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw ('eNSP executable not found: ' + $resolved)
        }
        return [IO.Path]::GetFullPath($resolved)
    }
    $candidates = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser,
                       [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32,
                           [Microsoft.Win32.RegistryView]::Registry64)) {
            $baseKey = $null
            $uninstall = $null
            try {
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $uninstall = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                if ($uninstall) {
                    foreach ($name in $uninstall.GetSubKeyNames()) {
                        $entry = $null
                        try {
                            $entry = $uninstall.OpenSubKey($name)
                            if ($entry -and [string]$entry.GetValue('DisplayName') -match '(?i)eNSP') {
                                $location = [string]$entry.GetValue('InstallLocation')
                                if ($location) {
                                    [void]$candidates.Add([IO.Path]::GetFullPath(
                                        (Join-Path $location 'eNSP_Client.exe')))
                                }
                            }
                        } catch { continue } finally { if ($entry) { $entry.Dispose() } }
                    }
                }
            } catch { continue } finally {
                if ($uninstall) { $uninstall.Dispose() }
                if ($baseKey) { $baseKey.Dispose() }
            }
        }
    }
    foreach ($programRoot in @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))) {
        if ($programRoot) {
            [void]$candidates.Add((Join-Path $programRoot 'Huawei\eNSP\eNSP_Client.exe'))
        }
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($desktop in @([Environment]::GetFolderPath('DesktopDirectory'),
                               [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
            if (-not $desktop) { continue }
            foreach ($link in @(Get-ChildItem -LiteralPath $desktop -Filter '*eNSP*.lnk' -ErrorAction SilentlyContinue)) {
                $target = $shell.CreateShortcut($link.FullName).TargetPath
                if ($target -and [IO.Path]::GetFileName($target) -ieq 'eNSP_Client.exe') {
                    [void]$candidates.Add([IO.Path]::GetFullPath($target))
                }
            }
        }
    } catch { } finally {
        if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    $supported = @()
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $hash = Get-BytesHash ([IO.File]::ReadAllBytes($candidate))
            if ($stateTable.ContainsKey($hash)) { $supported += $candidate }
        }
    }
    if ($supported.Count -eq 1) { return $supported[0] }
    if ($supported.Count -gt 1) {
        throw ('Multiple supported installations found. Specify -EnspPath: ' + ($supported -join '; '))
    }
    throw 'No supported eNSP client found. Use -EnspPath to specify the executable or its folder.'
}

function Get-BackupLocation([string]$Target) {
    $machine = [Environment]::MachineName
    $safeMachine = $machine -replace '[^A-Za-z0-9_.-]', '_'
    $machineTag = (Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($machine))).Substring(0, 8)
    $pathTag = (Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($Target.ToUpperInvariant()))).Substring(0, 16)
    return Join-Path $packageRoot ('backups\' + $safeMachine + '-' + $machineTag + '\' + $pathTag)
}

function Find-OriginalBackup([string]$Target) {
    if ([string]::IsNullOrEmpty($PSScriptRoot)) { return $null }
    $preferred = Join-Path (Get-BackupLocation $Target) 'eNSP_Client.original.exe'
    $legacy = Join-Path $packageRoot 'backups\eNSP_Client.original.exe'
    foreach ($candidate in @($preferred, $legacy)) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
            (Get-BytesHash ([IO.File]::ReadAllBytes($candidate))) -eq $originalHash) {
            return $candidate
        }
    }
    return $null
}

function Get-VerifiedState([byte[]]$Bytes) {
    $hash = Get-BytesHash $Bytes
    if ($Bytes.Length -ne 3547136 -or -not $stateTable.ContainsKey($hash)) {
        throw 'Unsupported or changed eNSP executable. Nothing has been modified.'
    }
    $flags = $stateTable[$hash]
    foreach ($definition in $definitions) {
        [byte[]]$context = $definition.Context.Clone()
        $context[$definition.ContextIndex] = if ($flags[$definition.Index] -eq '1') {
            $definition.Patched
        } else { $definition.Original }
        for ($index=0; $index -lt $context.Length; $index++) {
            if ($Bytes[$definition.ContextOffset+$index] -ne $context[$index]) {
                throw ('Unexpected instructions for ' + $definition.Id)
            }
        }
    }
    return [pscustomobject]@{Hash=$hash; Flags=$flags}
}

function Get-Status([string]$Target, $Verified) {
    $selected = @($definitions | Where-Object { $Fix -eq 'All' -or $_.Id -eq $Fix })
    $active = @($selected | Where-Object { $Verified.Flags[$_.Index] -eq '1' }).Count
    $overall = if ($active -eq 0) { 'Original' }
        elseif ($active -eq $selected.Count) { 'Patched' } else { 'PartiallyPatched' }
    return [pscustomobject][ordered]@{
        Target=$Target
        Fix=$Fix
        State=$overall
        VisualEffects=if ($Verified.Flags[0] -eq '1') { 'Patched' } else { 'Original' }
        Clipboard=if ($Verified.Flags[1] -eq '1') { 'Patched' } else { 'Original' }
        SHA256=$Verified.Hash
        Backup=(Find-OriginalBackup $Target)
    }
}

function Invoke-EnspRepair {
    $target = Resolve-EnspExecutable $EnspPath
    [byte[]]$before = [IO.File]::ReadAllBytes($target)
    $verified = Get-VerifiedState $before
    if ($Mode -eq 'Check') {
        Get-Status $target $verified | ConvertTo-Json
        return
    }

    [byte[]]$after = $before.Clone()
    $changes = @(
        foreach ($definition in $definitions) {
            if ($Fix -ne 'All' -and $definition.Id -ne $Fix) { continue }
            $desired = if ($Mode -eq 'Apply') { $definition.Patched } else { $definition.Original }
            if ($before[$definition.Offset] -ne $desired) {
                $after[$definition.Offset] = $desired
                [pscustomobject]@{
                    Fix=$definition.Id; Offset=$definition.Offset
                    Before=[int]$before[$definition.Offset]; After=[int]$desired
                }
            }
        }
    )
    if ($changes.Count -eq 0) {
        Get-Status $target $verified | ConvertTo-Json
        return
    }
    $required = Get-VerifiedState $after

    foreach ($client in @(Get-Process -Name eNSP_Client -ErrorAction SilentlyContinue)) {
        $runningPath = $null
        try { $runningPath = $client.Path } catch { }
        if ($runningPath -and [IO.Path]::GetFullPath($runningPath) -ieq $target) {
            throw 'Save your experiment and close eNSP before applying or restoring the repair.'
        }
    }
    # A restricted process-path lookup does not bypass the exclusive file lock below.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }

    if (-not $NoElevation -and -not $isAdministrator) {
        $logDirectory = Join-Path $packageRoot 'logs'
        [void][IO.Directory]::CreateDirectory($logDirectory)
        $childErrorLog = Join-Path $logDirectory ('error-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $nativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            $nativePowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath +
            '" -Mode ' + $Mode + ' -Fix ' + $Fix + ' -EnspPath "' + $target +
            '" -NoElevation -ErrorLog "' + $childErrorLog + '"'
        Write-Host 'Requesting administrator permission for this one-time file modification.'
        $child = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($child.ExitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $childErrorLog) {
                Get-Content -LiteralPath $childErrorLog -Raw
            } else { 'Administrator permission was cancelled, or the child process could not start.' }
            throw $detail
        }
        & $PSCommandPath -Mode Check -Fix $Fix -EnspPath $target
        return
    }

    $backupDirectory = Get-BackupLocation $target
    $backupPath = Join-Path $backupDirectory 'eNSP_Client.original.exe'
    [void][IO.Directory]::CreateDirectory($backupDirectory)
    if ($Mode -eq 'Apply') {
        if (Test-Path -LiteralPath $backupPath) {
            if ((Get-BytesHash ([IO.File]::ReadAllBytes($backupPath))) -ne $originalHash) {
                throw 'An unrelated backup already exists. Refusing to overwrite it.'
            }
        } else {
            [byte[]]$original = $before.Clone()
            foreach ($definition in $definitions) { $original[$definition.Offset] = $definition.Original }
            if ((Get-BytesHash $original) -ne $originalHash) {
                throw 'Original backup verification failed before writing.'
            }
            $backupStream = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $backupStream.Write($original,0,$original.Length)
                $backupStream.Flush($true)
            } finally { $backupStream.Dispose() }
        }
    }
    if ($Mode -eq 'Restore' -and -not (Test-Path -LiteralPath $backupPath)) {
        $previousBackup = Find-OriginalBackup $target
        if ($previousBackup) { Copy-Item -LiteralPath $previousBackup -Destination $backupPath }
    }
    if (-not (Test-Path -LiteralPath $backupPath) -or
        (Get-BytesHash ([IO.File]::ReadAllBytes($backupPath))) -ne $originalHash) {
        throw 'A verified original backup is required. Nothing has been modified.'
    }

    $stream = [IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $verified.Hash) {
            throw 'The executable changed while preparing the repair.'
        }
        try {
            foreach ($change in $changes) {
                [void]$stream.Seek($change.Offset,[IO.SeekOrigin]::Begin)
                $stream.WriteByte($change.After)
            }
            $stream.Flush($true)
            if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $required.Hash) {
                throw 'Verification after writing failed.'
            }
        } catch {
            $writeFailure = $_
            try {
                foreach ($change in $changes) {
                    [void]$stream.Seek($change.Offset,[IO.SeekOrigin]::Begin)
                    $stream.WriteByte($change.Before)
                }
                $stream.Flush($true)
                if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $verified.Hash) {
                    throw 'Rollback hash verification failed.'
                }
            } catch {
                throw ('Repair and automatic rollback failed. Verified original backup: ' +
                    $backupPath + '. Error: ' + $_.Exception.Message)
            }
            throw $writeFailure
        }
    } finally { $stream.Dispose() }

    $record = [ordered]@{
        TimeUtc=[DateTime]::UtcNow.ToString('o')
        Mode=$Mode; Fix=$Fix; Target=$target; Backup=$backupPath
        BeforeSHA256=$verified.Hash; AfterSHA256=$required.Hash
        ChangedBytes=$changes.Count; Changes=$changes
        VisualEffects=if ($required.Flags[0] -eq '1') { 'Patched' } else { 'Original' }
        Clipboard=if ($required.Flags[1] -eq '1') { 'Patched' } else { 'Original' }
    }
    $recordPath = Join-Path $packageRoot ('repair-' + $Mode + '-' +
        (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
    try { $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding UTF8 }
    catch { Write-Warning ('File modification verified, but the audit record could not be saved: ' + $_.Exception.Message) }
    $record | ConvertTo-Json -Depth 4
}

try {
    Invoke-EnspRepair
} catch {
    if ($ErrorLog -and $Mode -ne 'Check') {
        try { [IO.File]::WriteAllText($ErrorLog,($_ | Out-String),[Text.UTF8Encoding]::new($true)) }
        catch { }
    }
    Write-Error $_ -ErrorAction Continue
    exit 1
}
