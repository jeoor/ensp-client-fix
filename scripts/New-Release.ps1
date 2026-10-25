#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$')]
    [string]$Version,
    [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'dist'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$files=@('Repair-eNSP.ps1','检查.bat','修复.bat','还原.bat','README.md','LICENSE')
$inputs=@($files | ForEach-Object {Join-Path $root $_})
foreach($path in $inputs){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('Missing release file: '+$path)}}
$zipPath=Join-Path $OutputDirectory ('ensp-client-fix-'+$Version+'.zip')
$checksumPath=$zipPath+'.sha256'
if((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $checksumPath)){throw 'Release artifact already exists.'}
Compress-Archive -LiteralPath $inputs -DestinationPath $zipPath -CompressionLevel Optimal
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
try{
    $entries=@($archive.Entries | ForEach-Object {$_.FullName})
    if($entries.Count -ne $files.Count -or (Compare-Object $files $entries)){throw 'Unexpected release archive contents.'}
    foreach($entry in $archive.Entries){
        $stream=$entry.Open()
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$entryHash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}
        finally{$stream.Dispose();$sha.Dispose()}
        if($entryHash -ne (Get-FileHash -LiteralPath (Join-Path $root $entry.FullName) -Algorithm SHA256).Hash){
            throw ('Packed file differs from source: '+$entry.FullName)
        }
    }
}finally{$archive.Dispose()}
$hash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksumPath,$hash+' *'+[IO.Path]::GetFileName($zipPath)+[Environment]::NewLine,[Text.Encoding]::ASCII)
[pscustomobject]@{Version=$Version;ArchivePath=$zipPath;ChecksumPath=$checksumPath;SHA256=$hash}
