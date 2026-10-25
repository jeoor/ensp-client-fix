#Requires -Version 5.1
[CmdletBinding()]
param([string]$OriginalFile)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script = Join-Path $root 'Repair-eNSP-VisualEffects.ps1'
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

$originalHash = 'e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e'
$patchedHash = '8bf1ad0d35310905020b20f0ffef419e34f685c90666162de762006df176d20f'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot = Join-Path $tempParent ('ensp-drag-test-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $tempRoot) { throw 'Temporary test directory already exists.' }

$nativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Invoke-Fixture([string]$Mode,[string]$Target,[bool]$ShouldSucceed) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $nativePowerShell -NoProfile -ExecutionPolicy Bypass -File $tool -Mode $Mode -EnspPath $Target -NoElevation 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($ShouldSucceed -and $exitCode -ne 0) { throw ($output | Out-String) }
    if (-not $ShouldSucceed -and $exitCode -eq 0) { throw 'Unsupported or unsafe operation was accepted.' }
    return ($output | Out-String)
}

$result = [ordered]@{
    Syntax = 'passed'
    UnknownFileReadOnly = 'not-run'
    SupportedRoundTrip = 'not-run (requires a private OriginalFile)'
    SingleByteDifference = 'not-run'
    IdempotentApply = 'not-run'
    ReadOnlyCheck = 'not-run'
    CorruptBackupRefusal = 'not-run'
}
try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $toolDirectory = Join-Path $tempRoot 'tool 中文 空格'
    [void][IO.Directory]::CreateDirectory($toolDirectory)
    $tool = Join-Path $toolDirectory 'Repair-eNSP-VisualEffects.ps1'
    Copy-Item -LiteralPath $script -Destination $tool
    $unknown = Join-Path $tempRoot 'unsupported.bin'
    [IO.File]::WriteAllBytes($unknown,[byte[]](1,2,3,4))
    $unknownHash = (Get-FileHash -LiteralPath $unknown -Algorithm SHA256).Hash
    foreach ($mode in @('Check','Apply','Restore')) {
        [void](Invoke-Fixture $mode $unknown $false)
        if ((Get-FileHash -LiteralPath $unknown -Algorithm SHA256).Hash -ne $unknownHash) {
            throw 'An unsupported file was modified.'
        }
    }
    if (@(Get-ChildItem -LiteralPath $toolDirectory -Force).Count -ne 1) {
        throw 'Rejected operations created unexpected runtime files.'
    }
    $result.UnknownFileReadOnly = 'passed'

    if ($OriginalFile) {
        if ((Get-FileHash -LiteralPath $OriginalFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $originalHash) {
            throw 'The private fixture must be the supported original client.'
        }
        [byte[]]$originalBytes = [IO.File]::ReadAllBytes($OriginalFile)
        $clientDirectory = Join-Path $tempRoot '安装目录 中文 空格'
        [void][IO.Directory]::CreateDirectory($clientDirectory)
        $client = Join-Path $clientDirectory 'eNSP_Client.exe'
        Copy-Item -LiteralPath $OriginalFile -Destination $client

        $apply = Invoke-Fixture 'Apply' $clientDirectory $true | ConvertFrom-Json
        if ((Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash.ToLowerInvariant() -ne $patchedHash) {
            throw 'Patched file hash did not match.'
        }
        [byte[]]$patchedBytes = [IO.File]::ReadAllBytes($client)
        $offsets = @(for ($index=0;$index -lt $originalBytes.Length;$index++) {
            if ($originalBytes[$index] -ne $patchedBytes[$index]) { $index }
        })
        if ($offsets.Count -ne 1 -or $offsets[0] -ne 0x3BE2B) {
            throw 'The modification was not exactly the expected single byte.'
        }
        $result.SingleByteDifference = 'passed'
        $writeTime = (Get-Item -LiteralPath $client).LastWriteTimeUtc.Ticks
        [void](Invoke-Fixture 'Apply' $client $true)
        if ((Get-Item -LiteralPath $client).LastWriteTimeUtc.Ticks -ne $writeTime) {
            throw 'Repeated Apply rewrote the target.'
        }
        $result.IdempotentApply = 'passed'

        $fileCount = @(Get-ChildItem -LiteralPath $toolDirectory -Recurse -File).Count
        $check = Invoke-Fixture 'Check' $client $true | ConvertFrom-Json
        if ($check.State -ne 'Patched' -or
            @(Get-ChildItem -LiteralPath $toolDirectory -Recurse -File).Count -ne $fileCount) {
            throw 'Check was not read-only.'
        }
        $result.ReadOnlyCheck = 'passed'
        [void](Invoke-Fixture 'Restore' $client $true)
        if ((Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash.ToLowerInvariant() -ne $originalHash) {
            throw 'Restored file did not match the original.'
        }
        $result.SupportedRoundTrip = 'passed'

        $backup = [IO.Path]::GetFullPath($apply.Backup)
        if (-not $backup.StartsWith($tempRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fixture backup escaped the temporary directory.'
        }
        [byte[]]$badBackup = [IO.File]::ReadAllBytes($backup)
        $badBackup[0] = $badBackup[0] -bxor 1
        [IO.File]::WriteAllBytes($backup,$badBackup)
        [void](Invoke-Fixture 'Apply' $client $false)
        if ((Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash.ToLowerInvariant() -ne $originalHash) {
            throw 'Backup refusal changed the client.'
        }
        $result.CorruptBackupRefusal = 'passed'
    }
    $result | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $tempRoot).ProviderPath)
        if (-not $resolved.StartsWith($tempParent+'\',[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^ensp-drag-test-[a-f0-9]{32}$') {
            throw 'Refusing to clean an unexpected temporary path.'
        }
        $items = @((Get-Item -LiteralPath $resolved -Force)) + @(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
            throw 'Refusing to clean a reparse point.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
