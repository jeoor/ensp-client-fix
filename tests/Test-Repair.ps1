#Requires -Version 5.1
[CmdletBinding()]
param([string]$OriginalFile)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script = Join-Path $root 'Repair-eNSP.ps1'
$tokens=$null; $parseErrors=$null
[void][Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

$hashes = @{
    '00'='e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e'
    '10'='8bf1ad0d35310905020b20f0ffef419e34f685c90666162de762006df176d20f'
    '01'='e567ddfabd65000b440211dd5e5a3b149b36e766c7619daaf0fdcd0ea65e230b'
    '11'='50e64999d0f3e9937fb8131066dd22615eda90c64b7bbdd64d5b4b937d2e4ed7'
}
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot = Join-Path $tempParent ('ensp-drag-test-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $tempRoot) { throw 'Temporary test directory already exists.' }
$nativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-Fixture([string]$Mode,[string]$Fix,[string]$Target,[bool]$ShouldSucceed) {
    $savedPreference=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try {
        $output = & $nativePowerShell -NoProfile -ExecutionPolicy Bypass -File $tool -Mode $Mode -Fix $Fix -EnspPath $Target -NoElevation 2>&1
        $exitCode=$LASTEXITCODE
    } finally { $ErrorActionPreference=$savedPreference }
    if ($ShouldSucceed -and $exitCode -ne 0) { throw ($output | Out-String) }
    if (-not $ShouldSucceed -and $exitCode -eq 0) { throw 'An unsafe operation was accepted.' }
    return ($output | Out-String)
}

function Assert-Hash([string]$Path,[string]$Flags) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes[$Flags]) {
        throw ('Unexpected file hash; expected state ' + $Flags)
    }
}

function New-Fixture([string]$Name,[string]$Flags) {
    $directory=Join-Path $tempRoot $Name
    [void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $directory 'eNSP_Client.exe'
    [byte[]]$bytes=$originalBytes.Clone()
    $bytes[0x3BE2B]=if ($Flags[0] -eq '1') {0xEB} else {0x74}
    $bytes[0xD5A90]=if ($Flags[1] -eq '1') {0x7A} else {0xB6}
    [IO.File]::WriteAllBytes($path,$bytes)
    Assert-Hash $path $Flags
    return $path
}

function Get-DesiredFlags([string]$Initial,[string]$Fix,[char]$Value) {
    $flags=$Initial.ToCharArray()
    if ($Fix -in @('All','VisualEffects')) { $flags[0]=$Value }
    if ($Fix -in @('All','Clipboard')) { $flags[1]=$Value }
    return -join $flags
}

$result=[ordered]@{
    Syntax='passed'
    UnknownFileReadOnly='not-run'
    SupportedTransitions='not-run (requires a private OriginalFile)'
    ClipboardFailureBranch='not-run'
    IdempotentApply='not-run'
    ReadOnlyCheck='not-run'
    CorruptBackupRefusal='not-run'
    LockedFileRefusal='not-run'
}
try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $toolDirectory=Join-Path $tempRoot 'tool 中文 空格'
    [void][IO.Directory]::CreateDirectory($toolDirectory)
    $tool=Join-Path $toolDirectory 'Repair-eNSP.ps1'
    Copy-Item -LiteralPath $script -Destination $tool
    $unknown=Join-Path $tempRoot 'unsupported.bin'
    [IO.File]::WriteAllBytes($unknown,[byte[]](1,2,3,4))
    $unknownHash=(Get-FileHash -LiteralPath $unknown -Algorithm SHA256).Hash
    foreach ($fix in @('All','VisualEffects','Clipboard')) {
        foreach ($mode in @('Check','Apply','Restore')) {
            [void](Invoke-Fixture $mode $fix $unknown $false)
            if ((Get-FileHash -LiteralPath $unknown -Algorithm SHA256).Hash -ne $unknownHash) {
                throw 'An unsupported file was modified.'
            }
        }
    }
    if (@(Get-ChildItem -LiteralPath $toolDirectory -Force).Count -ne 1) {
        throw 'Rejected operations created unexpected runtime files.'
    }
    $result.UnknownFileReadOnly='passed'
    Write-Host 'Unknown-file refusal verified for all modes and fixes.'

    if ($OriginalFile) {
        Assert-Hash $OriginalFile '00'
        [byte[]]$originalBytes=[IO.File]::ReadAllBytes($OriginalFile)
        $legacyDirectory=Join-Path $toolDirectory 'backups'
        [void][IO.Directory]::CreateDirectory($legacyDirectory)
        Copy-Item -LiteralPath $OriginalFile -Destination (Join-Path $legacyDirectory 'eNSP_Client.original.exe')
        $cases=0
        foreach ($initial in @('00','10','01','11')) {
            foreach ($fix in @('All','VisualEffects','Clipboard')) {
                $client=New-Fixture ('安装目录 中文 空格 '+$initial+' '+$fix) $initial
                $fileCount=@(Get-ChildItem -LiteralPath $toolDirectory -Recurse -File).Count
                $beforeCheck=(Get-Item -LiteralPath $client).LastWriteTimeUtc.Ticks
                $status=Invoke-Fixture 'Check' $fix $client $true | ConvertFrom-Json
                if ($status.SHA256 -ne $hashes[$initial] -or
                    @(Get-ChildItem -LiteralPath $toolDirectory -Recurse -File).Count -ne $fileCount -or
                    (Get-Item -LiteralPath $client).LastWriteTimeUtc.Ticks -ne $beforeCheck) {
                    throw 'Check was not read-only or returned the wrong state.'
                }
                [void](Invoke-Fixture 'Apply' $fix (Split-Path -Parent $client) $true)
                $applied=Get-DesiredFlags $initial $fix '1'
                Assert-Hash $client $applied
                $writeTime=(Get-Item -LiteralPath $client).LastWriteTimeUtc.Ticks
                [void](Invoke-Fixture 'Apply' $fix $client $true)
                if ((Get-Item -LiteralPath $client).LastWriteTimeUtc.Ticks -ne $writeTime) {
                    throw 'Repeated Apply rewrote the target.'
                }
                [byte[]]$bytes=[IO.File]::ReadAllBytes($client)
                if ($applied[1] -eq '1') {
                    # Decode the actual x86 branch rather than relying on script metadata.
                    $destination=0x4D5A94+[BitConverter]::ToInt32($bytes,0xD5A90)
                    if ($destination -ne 0x4D5B0E -or
                        [BitConverter]::ToString($bytes,0xD5B0E,6) -ne 'FF-15-B0-36-59-00' -or
                        [BitConverter]::ToString($bytes,0xD5A7D,6) -ne '0F-84-C7-00-00-00') {
                        throw 'Clipboard failure does not reach CloseClipboard, or the OpenClipboard failure path changed.'
                    }
                }
                [void](Invoke-Fixture 'Restore' $fix $client $true)
                $restored=Get-DesiredFlags $initial $fix '0'
                Assert-Hash $client $restored
                $cases++
                Write-Host ('Verified initial state '+$initial+' / '+$fix)
            }
        }
        $result.SupportedTransitions='passed ('+$cases+' combinations)'
        $result.ClipboardFailureBranch='passed'
        $result.IdempotentApply='passed'
        $result.ReadOnlyCheck='passed'

        $client=New-Fixture '损坏备份测试' '00'
        $apply=Invoke-Fixture 'Apply' 'Clipboard' $client $true | ConvertFrom-Json
        [void](Invoke-Fixture 'Restore' 'Clipboard' $client $true)
        $backup=[IO.Path]::GetFullPath($apply.Backup)
        if (-not $backup.StartsWith($tempRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fixture backup escaped the temporary directory.'
        }
        [byte[]]$badBackup=[IO.File]::ReadAllBytes($backup)
        $badBackup[0]=$badBackup[0] -bxor 1
        [IO.File]::WriteAllBytes($backup,$badBackup)
        [void](Invoke-Fixture 'Apply' 'Clipboard' $client $false)
        Assert-Hash $client '00'
        $result.CorruptBackupRefusal='passed'

        $lockedClient=New-Fixture '独占锁测试' '00'
        $lock=[IO.File]::Open($lockedClient,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { [void](Invoke-Fixture 'Apply' 'All' $lockedClient $false) }
        finally { $lock.Dispose() }
        Assert-Hash $lockedClient '00'
        $result.LockedFileRefusal='passed'
    }
    $result | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $tempRoot).ProviderPath)
        if (-not $resolved.StartsWith($tempParent+'\',[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^ensp-drag-test-[a-f0-9]{32}$') {
            throw 'Refusing to clean an unexpected temporary path.'
        }
        $items=@((Get-Item -LiteralPath $resolved -Force))+@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if ($items | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}) {
            throw 'Refusing to clean a reparse point.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
# All expected refusals were checked; report overall success to the CI host.
exit 0
