#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Initialization-State.ps1')
$TestRoot=[IO.Path]::GetFullPath($TestRoot)
function Assert($v,$m){if(-not $v){throw $m}}
function Receipt([string]$Root,[string]$Label,[int]$ExitCode){
 [void][IO.Directory]::CreateDirectory($Root)
 $dir=Join-Path $Root $Label;[void][IO.Directory]::CreateDirectory($dir)
 [IO.File]::WriteAllText((Join-Path $dir 'Configuration.xml'),'<Configuration/>')
 [IO.File]::WriteAllText((Join-Path $Root ($Label+'.launch.json')),(@{arguments=@('/DumpConfigToFiles',$dir)}|ConvertTo-Json))
 [IO.File]::WriteAllText((Join-Path $Root ($Label+'.result.json')),(@{exitCode=$ExitCode;timedOut=$false}|ConvertTo-Json))
 return $dir
}
$older=Join-Path $TestRoot 'complete';$newer=Join-Path $TestRoot 'partial'
$oldMain=Receipt $older 'dump-main' 0;$oldExtensions=Receipt $older 'dump-extensions' 0
$newMain=Receipt $newer 'dump-main' 0;[void](Receipt $newer 'dump-extensions' 7)
$resume=@{chain=@($newer,$older)}
$snapshot=Get-InitializationCachedSnapshot $false
Assert ($snapshot.main -eq $oldMain -and $snapshot.extensions -eq $oldExtensions) 'XML from different generations mixed'
$snapshot=Get-InitializationCachedSnapshot $true
Assert ($snapshot.main -eq $newMain) 'Main-only completed snapshot not reused'
$receipt=Join-Path $older 'dump-extensions.result.json'
[IO.File]::WriteAllText($receipt,'{"exitCode":0,"timedOut":true}')
$snapshot=Get-InitializationCachedSnapshot $false
Assert (-not $snapshot.main -and -not $snapshot.extensions) 'Timed-out snapshot accepted'
$EdtCliPath='fixture.exe';$EdtIniFile=''
$data=Join-Path $older 'workspace';$project=Join-Path $data Demo
[void][IO.Directory]::CreateDirectory((Join-Path $project src));[IO.File]::WriteAllText((Join-Path $project '.project'),'<projectDescription/>')
[IO.File]::WriteAllText((Join-Path $older 'edt-import-Demo.launch.json'),(@{executable=$EdtCliPath;arguments=@('-data',$data,'--project',$project,'--configuration-files',$oldMain)}|ConvertTo-Json))
$edtResult=Join-Path $older 'edt-import-Demo.result.json'
[IO.File]::WriteAllText($edtResult,'{"exitCode":0,"timedOut":false,"memoryExhausted":true}')
Assert (-not(Get-InitializationCachedEdt Demo $oldMain '')) 'EDT result with background OOM accepted'
[IO.File]::WriteAllText($edtResult,'{"exitCode":0,"timedOut":false,"commandFailed":true}')
Assert (-not(Get-InitializationCachedEdt Demo $oldMain '')) 'EDT rejected command accepted as completed'
[IO.File]::WriteAllText($edtResult,'{"exitCode":0,"timedOut":false,"memoryExhausted":false}')
Assert ((Get-InitializationCachedEdt Demo $oldMain '') -eq $project) 'Successful --project result was not reused'
Write-Host 'PASS: XML generations never mixed, main-only snapshot reused, timeout rejected.'
