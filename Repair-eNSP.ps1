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
    [switch]$HumanReadable,
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
            throw ('找不到 eNSP 程序：' + $resolved)
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
        throw ('发现多个受支持的安装，请用 -EnspPath 指定一个：' + ($supported -join '; '))
    }
    throw '未找到受支持的 eNSP 客户端，请用 -EnspPath 指定程序或安装目录。'
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
        throw '客户端文件不受支持或已被其他工具修改，已停止操作，未修改文件。'
    }
    $flags = $stateTable[$hash]
    foreach ($definition in $definitions) {
        [byte[]]$context = $definition.Context.Clone()
        $context[$definition.ContextIndex] = if ($flags[$definition.Index] -eq '1') {
            $definition.Patched
        } else { $definition.Original }
        for ($index=0; $index -lt $context.Length; $index++) {
            if ($Bytes[$definition.ContextOffset+$index] -ne $context[$index]) {
                throw ('修复位置的指令与预期不符，已停止操作：' + $definition.Id)
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

function Write-RepairStep([int]$Step, [string]$Message) {
    if ($HumanReadable) {
        $total = if ($Mode -eq 'Check') { 2 } else { 3 }
        Write-Host ('[' + $Step + '/' + $total + '] ' + $Message) -ForegroundColor Cyan
    }
}

function Write-RepairResult([string]$Target, $Verified, [bool]$Changed) {
    $status = Get-Status $Target $Verified
    if (-not $HumanReadable) {
        $status | ConvertTo-Json
        return
    }
    $color = 'Green'
    if ($Mode -eq 'Check') {
        $summary = switch ($status.State) {
            'Patched' { '所选项目均已修复。' }
            'PartiallyPatched' { '所选项目中有一项尚未修复。' }
            default { '所选项目尚未修复。' }
        }
        $headline = '[检查完成] ' + $summary
        if ($status.State -ne 'Patched') { $color = 'Yellow' }
    } elseif ($Mode -eq 'Apply') {
        $headline = if ($Changed) { '[修复成功] 所选项目已修复，文件校验通过。' }
            else { '[无需修复] 所选项目已经修复，文件校验通过。' }
    } else {
        $headline = if ($Changed) { '[还原成功] 所选项目已恢复原版，文件校验通过。' }
            else { '[无需还原] 所选项目已经是原版，文件校验通过。' }
    }
    Write-Host ''
    Write-Host $headline -ForegroundColor $color
    Write-Host ''
    $originalLabel = if ($Mode -eq 'Restore') { '原版' } else { '未修复（原版）' }
    $visualLabel = if ($status.VisualEffects -eq 'Patched') { '已修复' } else { $originalLabel }
    $clipboardLabel = if ($status.Clipboard -eq 'Patched') { '已修复' } else { $originalLabel }
    Write-Host ('窗口拖动：' + $visualLabel)
    Write-Host ('剪贴板：  ' + $clipboardLabel)
    if ($Fix -ne 'All') {
        $selectedLabel = if ($Fix -eq 'Clipboard') { '剪贴板' } else { '窗口拖动' }
        Write-Host ('本次选择：' + $selectedLabel)
    }
    Write-Host ''
    Write-Host ('程序位置：' + $Target)
    if ($status.Backup) { Write-Host ('原版备份：' + $status.Backup) }
}

function Get-RepairErrorText($Failure) {
    $exception = $Failure.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    if ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) {
        return '已取消管理员授权，本次操作未完成。重新运行后，请在授权弹窗中选择[是]。'
    }
    if ($exception -is [UnauthorizedAccessException]) {
        return '访问权限不足，请检查程序、工具和备份目录的权限，并允许管理员授权。'
    }
    if ($exception -is [IO.IOException] -and ($exception.HResult -band 0xFFFF) -in @(32,33)) {
        return '文件正被占用，请保存实验并退出 eNSP，关闭占用该文件的其他程序后重试。'
    }
    return $Failure.Exception.Message
}

function Invoke-EnspRepair {
    Write-RepairStep 1 '正在查找并校验 eNSP 客户端...'
    $target = Resolve-EnspExecutable $EnspPath
    [byte[]]$before = [IO.File]::ReadAllBytes($target)
    $verified = Get-VerifiedState $before
    if ($Mode -eq 'Check') {
        Write-RepairStep 2 '文件校验通过，正在汇总状态。'
        Write-RepairResult $target $verified $false
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
        Write-RepairResult $target $verified $false
        return
    }
    $required = Get-VerifiedState $after

    foreach ($client in @(Get-Process -Name eNSP_Client -ErrorAction SilentlyContinue)) {
        $runningPath = $null
        try { $runningPath = $client.Path } catch { }
        if ($runningPath -and [IO.Path]::GetFullPath($runningPath) -ieq $target) {
            throw '请先保存实验并退出 eNSP，再运行修复或还原。'
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
        if ($HumanReadable) { $arguments += ' -HumanReadable' }
        $actionLabel = if ($Mode -eq 'Apply') { '修复' } else { '还原' }
        Write-RepairStep 2 ('正在通过管理员进程执行' + $actionLabel + '...')
        Write-Host '正在请求管理员权限，请在授权弹窗中选择[是]。'
        $child = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($child.ExitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $childErrorLog) {
                Get-Content -LiteralPath $childErrorLog -Raw
            } else { '管理员授权已取消，或管理员进程未能完成操作。' }
            throw $detail
        }
        Write-RepairStep 3 '正在重新核验客户端文件...'
        $completed = Get-VerifiedState ([IO.File]::ReadAllBytes($target))
        if ($completed.Hash -ne $required.Hash) {
            throw '管理员操作结束后，文件状态与预期不符，请重新检查客户端。'
        }
        Write-RepairResult $target $completed $true
        return
    }

    $step = if ($Mode -eq 'Apply') { '正在保存原版备份并修复所选项目...' }
        else { '正在核对原版备份并还原所选项目...' }
    Write-RepairStep 2 $step
    $backupDirectory = Get-BackupLocation $target
    $backupPath = Join-Path $backupDirectory 'eNSP_Client.original.exe'
    [void][IO.Directory]::CreateDirectory($backupDirectory)
    if ($Mode -eq 'Apply') {
        if (Test-Path -LiteralPath $backupPath) {
            if ((Get-BytesHash ([IO.File]::ReadAllBytes($backupPath))) -ne $originalHash) {
                throw '原版备份的校验未通过，已停止操作并保留现有备份。'
            }
        } else {
            [byte[]]$original = $before.Clone()
            foreach ($definition in $definitions) { $original[$definition.Offset] = $definition.Original }
            if ((Get-BytesHash $original) -ne $originalHash) {
                throw '生成原版备份时校验失败，已停止操作，未修改客户端。'
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
        throw '缺少有效的原版备份，请保留并使用此前修复时的工具目录；客户端未修改。'
    }

    $stream = [IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $verified.Hash) {
            throw '准备操作期间客户端文件发生变化，已停止写入，请重新检查。'
        }
        try {
            foreach ($change in $changes) {
                [void]$stream.Seek($change.Offset,[IO.SeekOrigin]::Begin)
                $stream.WriteByte($change.After)
            }
            $stream.Flush($true)
            Write-RepairStep 3 '正在校验修改后的客户端文件...'
            if ((Get-BytesHash (Read-LockedBytes $stream)) -ne $required.Hash) {
                throw '写入后文件校验失败，正在尝试恢复操作前的字节。'
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
                    throw '自动恢复操作前字节后的文件校验失败。'
                }
            } catch {
                throw ('文件修改和自动恢复均未完成，请使用已验证的原版备份恢复：' +
                    $backupPath + '。详细原因：' + $_.Exception.Message)
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
    catch { Write-Warning ('文件修改已校验通过，但操作记录保存失败：' + $_.Exception.Message) }
    if ($HumanReadable) { Write-RepairResult $target $required $true }
    else { $record | ConvertTo-Json -Depth 4 }
}

try {
    Invoke-EnspRepair
} catch {
    $detail = Get-RepairErrorText $_
    if ($ErrorLog -and $Mode -ne 'Check') {
        try { [IO.File]::WriteAllText($ErrorLog,$detail,[Text.UTF8Encoding]::new($true)) }
        catch { }
    }
    if ($HumanReadable) {
        $operation = switch ($Mode) { 'Check' { '检查' }; 'Apply' { '修复' }; 'Restore' { '还原' } }
        Write-Host ('[' + $operation + '失败] ' + $detail) -ForegroundColor Red
    } else { Write-Error $_ -ErrorAction Continue }
    exit 1
}
