#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [string]$OriginalFile
)
$ErrorActionPreference='Stop'
$expected=@('Repair-eNSP.ps1','检查.bat','修复.bat','还原.bat','README.md','LICENSE')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArchivePath))
try{
    $entries=@($archive.Entries | ForEach-Object {$_.FullName})
    if($entries.Count -ne $expected.Count -or (Compare-Object $expected $entries)){throw 'Unexpected package contents.'}
}finally{$archive.Dispose()}
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot=Join-Path $tempParent ('ensp-release-test-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $tempRoot){throw 'Test directory already exists.'}
function Invoke-Launcher([string]$Name,[int]$ExpectedExit,[string]$ExpectedMessage){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:WINDIR 'System32\cmd.exe'
    $info.Arguments='/d /c ""'+(Join-Path $tempRoot $Name)+'" -EnspPath "'+$target+'" -NoElevation"'
    $info.WorkingDirectory=$tempParent
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8
    $info.StandardErrorEncoding=[Text.Encoding]::UTF8
    $process=[Diagnostics.Process]::Start($info)
    try{
        $outTask=$process.StandardOutput.ReadToEndAsync()
        $errTask=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine('x')
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(20000)){$process.Kill();throw ('Launcher timed out: '+$Name)}
        $output=$outTask.GetAwaiter().GetResult()+$errTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne $ExpectedExit){throw ($Name+' returned '+$process.ExitCode+': '+$output)}
        if(-not $output.Contains($ExpectedMessage)){throw ($Name+' did not explain the outcome: '+$output)}
        if($output -match '"(?:Target|SHA256|BeforeSHA256)"\s*:'){throw ($Name+' exposed raw JSON instead of the result.')}
        if($ExpectedExit -ne 0 -and $output -match '\[(?:修复成功|还原成功|无需修复|无需还原|检查完成)\]'){
            throw ($Name+' reported success for a failed operation: '+$output)
        }
        if($ExpectedExit -eq 0 -and ($output -notmatch '窗口拖动：' -or $output -notmatch '剪贴板：')){
            throw ($Name+' did not show both repair states: '+$output)
        }
    }finally{$process.Dispose()}
}
try{
    [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($ArchivePath),$tempRoot)
    $directory=Join-Path $tempRoot '安装目录 中文 空格'
    [void][IO.Directory]::CreateDirectory($directory)
    $target=Join-Path $directory 'eNSP_Client.exe'
    if($OriginalFile){
        $originalHash='e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e'
        if((Get-FileHash -LiteralPath $OriginalFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $originalHash){throw 'Unsupported private fixture.'}
        Copy-Item -LiteralPath $OriginalFile -Destination $target
        Invoke-Launcher '检查.bat' 0 '[检查完成] 所选项目尚未修复。'
        Invoke-Launcher '修复.bat' 0 '[修复成功]'
        if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne '50e64999d0f3e9937fb8131066dd22615eda90c64b7bbdd64d5b4b937d2e4ed7'){throw 'Packaged repair hash mismatch.'}
        Invoke-Launcher '修复.bat' 0 '[无需修复]'
        Invoke-Launcher '检查.bat' 0 '[检查完成] 所选项目均已修复。'
        Invoke-Launcher '还原.bat' 0 '[还原成功]'
        if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $originalHash){throw 'Packaged restoration hash mismatch.'}
        Invoke-Launcher '还原.bat' 0 '[无需还原]'
        [byte[]]$partial=[IO.File]::ReadAllBytes($target)
        $partial[0x3BE2B]=0xEB
        [IO.File]::WriteAllBytes($target,$partial)
        Invoke-Launcher '检查.bat' 0 '[检查完成] 所选项目中有一项尚未修复。'
        $before=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        $lock=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{Invoke-Launcher '修复.bat' 1 '[修复失败] 文件正被占用'}finally{$lock.Dispose()}
        $backups=@(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'backups') -Recurse -File -Filter 'eNSP_Client.original.exe')
        if($backups.Count -ne 1){throw 'Expected one private fixture backup.'}
        [IO.File]::WriteAllBytes($backups[0].FullName,[byte[]](1,2,3,4))
        Invoke-Launcher '修复.bat' 1 '[修复失败] 原版备份的校验未通过'
        if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $before){throw 'Failed launchers changed the private fixture.'}
        $coverage='private executable roundtrip'
    }else{
        [IO.File]::WriteAllBytes($target,[byte[]](1,2,3,4))
        $before=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        foreach($name in @('检查.bat','修复.bat','还原.bat')){
            $label=switch($name){'检查.bat'{'检查'};'修复.bat'{'修复'};'还原.bat'{'还原'}}
            Invoke-Launcher $name 1 ('['+$label+'失败] 客户端文件不受支持')
            if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $before){throw 'Unsupported file was changed.'}
        }
        if(@(Get-ChildItem -LiteralPath $tempRoot -Force).Count -ne 7){throw 'Rejected launchers created unexpected runtime files.'}
        $coverage='unsupported-file refusal'
    }
    [pscustomobject]@{ArchiveContents='passed (6 files)';Launchers='passed';Coverage=$coverage} | ConvertTo-Json
}finally{
    if(Test-Path -LiteralPath $tempRoot){
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $tempRoot).ProviderPath)
        if(-not $resolved.StartsWith($tempParent+'\',[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^ensp-release-test-[a-f0-9]{32}$'){throw 'Unexpected cleanup path.'}
        $items=@((Get-Item -LiteralPath $resolved -Force))+@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if($items | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'Cleanup path contains a reparse point.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
exit 0
