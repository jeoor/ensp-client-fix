#Requires -Version 5.1
<#
.SYNOPSIS
One-time, reversible repair for eNSP disabling full-window dragging.
.DESCRIPTION
Check is read-only. Apply and Restore validate the complete executable hash,
use an exclusive file handle, and verify the final hash. Only the documented
eNSP client build is supported. No vendor executable is distributed.
.EXAMPLE
.\Repair-eNSP-VisualEffects.ps1 -Mode Check
.EXAMPLE
.\Repair-eNSP-VisualEffects.ps1 -Mode Apply
.EXAMPLE
.\Repair-eNSP-VisualEffects.ps1 -Mode Restore -EnspPath 'E:\Huawei\eNSP'
.NOTES
Copyright (c) 2026 Kayro (jeoor). MIT License.
Patch analysis reference: https://cmxz.top/2541/
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Apply', 'Restore')]
    [string]$Mode = 'Check',
    [string]$EnspPath,
    [switch]$NoElevation,
    [string]$ErrorLog
)

# One-time repair for the verified eNSP 1.3 client. Not a startup script.
# Skip the startup call that disables full-window dragging.
# Other versions are refused. Apply/Restore require eNSP to be closed.
$ErrorActionPreference = 'Stop'
$originalHash = 'e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e'
$patchedHash  = '8bf1ad0d35310905020b20f0ffef419e34f685c90666162de762006df176d20f'
$patchOffset = 0x3BE2B
$packageRoot = $PSScriptRoot

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
            if ($hash -in @($originalHash, $patchedHash)) { $supported += $candidate }
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

function Invoke-VisualRepair {
$EnspPath = Resolve-EnspExecutable $EnspPath
[byte[]]$before = [IO.File]::ReadAllBytes($EnspPath)
$beforeHash = Get-BytesHash $before
if ($beforeHash -notin @($originalHash, $patchedHash)) {
    throw 'Unsupported or changed eNSP executable. Nothing has been modified.'
}
if ($before.Length -ne 3547136) { throw 'Unexpected executable size.' }
$expected = [byte[]](0x74, 0x0A, 0x6A, 0, 0x6A, 0, 0x6A, 0, 0x6A, 0x25, 0xFF, 0xD6)
if ($beforeHash -eq $patchedHash) { $expected[0] = 0xEB }
for ($index = 0; $index -lt $expected.Length; $index++) {
    if ($before[$patchOffset + $index] -ne $expected[$index]) {
        throw 'Unexpected instructions at the repair location.'
    }
}

$state = if ($beforeHash -eq $patchedHash) { 'Patched' } else { 'Original' }
if ($Mode -eq 'Check') {
    [pscustomobject]@{Target=$EnspPath; State=$state; SHA256=$beforeHash; Offset='0x3BE2B'; Backup=(Find-OriginalBackup $EnspPath)} |
        ConvertTo-Json
    return
}
if (($Mode -eq 'Apply' -and $state -eq 'Patched') -or
    ($Mode -eq 'Restore' -and $state -eq 'Original')) {
    Write-Output ('Already in requested state: ' + $state)
    return
}
foreach ($runningClient in @(Get-Process -Name eNSP_Client -ErrorAction SilentlyContinue)) {
    $runningPath = $null
    try { $runningPath = $runningClient.Path } catch { }
    if ($runningPath -and [IO.Path]::GetFullPath($runningPath) -ieq $EnspPath) {
        throw 'Save your experiment and close eNSP before applying or restoring the repair.'
    }
}
# If process-path access is restricted, the exclusive writable file handle
# below still prevents modifying a running executable. No process is killed.
if ([string]::IsNullOrEmpty($PSScriptRoot)) { throw 'Save this script to a file before Apply/Restore.' }


$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $NoElevation -and -not $isAdministrator) {
    $logDirectory = Join-Path $packageRoot 'logs'
    [void][IO.Directory]::CreateDirectory($logDirectory)
    $childErrorLog = Join-Path $logDirectory ('error-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $nativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $nativePowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath +
        '" -Mode ' + $Mode + ' -EnspPath "' + $EnspPath +
        '" -NoElevation -ErrorLog "' + $childErrorLog + '"'
    Write-Host 'Requesting administrator permission for this one-time file modification.'
    $child = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($child.ExitCode -ne 0) {
        $detail = if (Test-Path -LiteralPath $childErrorLog) {
            Get-Content -LiteralPath $childErrorLog -Raw
        } else { 'Administrator permission was cancelled, or the child process could not start.' }
        throw $detail
    }
    & $PSCommandPath -Mode Check -EnspPath $EnspPath
    return
}

$backupDirectory = Get-BackupLocation $EnspPath
$backupPath = Join-Path $backupDirectory 'eNSP_Client.original.exe'
[void][IO.Directory]::CreateDirectory($backupDirectory)
if ($Mode -eq 'Apply') {
    if (Test-Path -LiteralPath $backupPath) {
        if ((Get-BytesHash ([IO.File]::ReadAllBytes($backupPath))) -ne $originalHash) {
            throw 'An unrelated backup already exists. Refusing to overwrite it.'
        }
    } else {
        $backupStream = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $backupStream.Write($before, 0, $before.Length)
            $backupStream.Flush($true)
        } finally { $backupStream.Dispose() }
    }
}
if ($Mode -eq 'Restore' -and -not (Test-Path -LiteralPath $backupPath)) {
    $previousBackup = Find-OriginalBackup $EnspPath
    if ($previousBackup) {
        Copy-Item -LiteralPath $previousBackup -Destination $backupPath -ErrorAction Stop
    }
}
if (-not (Test-Path -LiteralPath $backupPath)) { throw 'Original backup is missing.' }
if ((Get-BytesHash ([IO.File]::ReadAllBytes($backupPath))) -ne $originalHash) {
    throw 'Backup verification failed. Nothing has been modified.'
}

[byte[]]$after = $before.Clone()
$after[$patchOffset] = if ($Mode -eq 'Apply') { 0xEB } else { 0x74 }
$afterHash = Get-BytesHash $after
$requiredHash = if ($Mode -eq 'Apply') { $patchedHash } else { $originalHash }
if ($afterHash -ne $requiredHash) { throw 'Repair verification failed before writing.' }
# $after is a clone with exactly one assignment; both complete hashes above
# must also match the audited original/patched pair.
if ($before[$patchOffset] -eq $after[$patchOffset]) { throw 'Expected byte did not change.' }
$differenceCount = 1

$stream = [IO.File]::Open($EnspPath, [IO.FileMode]::Open,
    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $beforeHash) {
        throw 'The executable changed while preparing the repair.'
    }
    try {
        [void]$stream.Seek($patchOffset, [IO.SeekOrigin]::Begin)
        $stream.WriteByte($after[$patchOffset])
        $stream.Flush($true)
        if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $requiredHash) {
            throw 'Verification after writing failed.'
        }
    } catch {
        $writeFailure = $_
        try {
            [void]$stream.Seek($patchOffset, [IO.SeekOrigin]::Begin)
            $stream.WriteByte($before[$patchOffset])
            $stream.Flush($true)
            if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $beforeHash) {
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
    TimeUtc = [DateTime]::UtcNow.ToString('o')
    Computer = [Environment]::MachineName
    Mode = $Mode
    Target = $EnspPath
    Backup = $backupPath
    BeforeSHA256 = $beforeHash
    AfterSHA256 = $afterHash
    ChangedBytes = $differenceCount
    FileOffset = '0x3BE2B'
    InstructionAddress = '0x43BE2B'
    OriginalInstruction = '74 0A (JE)'
    PatchedInstruction = 'EB 0A (JMP)'
    Purpose = 'Skip disabling SPI_SETDRAGFULLWINDOWS at startup'
    Reference = 'https://cmxz.top/2541/'
}
$recordPath = Join-Path $packageRoot ('repair-' + $Mode + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
try {
    $record | ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding UTF8
} catch {
    Write-Warning ('File modification verified, but the audit record could not be saved: ' + $_.Exception.Message)
}
$record | ConvertTo-Json

}

try {
    Invoke-VisualRepair
} catch {
    if ($ErrorLog -and $Mode -ne 'Check') {
        try { [IO.File]::WriteAllText($ErrorLog, ($_ | Out-String), (New-Object Text.UTF8Encoding($true))) }
        catch { }
    }
    Write-Error $_ -ErrorAction Continue
    exit 1
}
