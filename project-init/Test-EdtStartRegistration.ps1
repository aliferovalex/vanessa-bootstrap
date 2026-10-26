#requires -Version 5.1
[CmdletBinding()]param([string]$TestRoot)
$ErrorActionPreference='Stop'
if(-not $TestRoot){$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('edtstart-test-'+[guid]::NewGuid().ToString('N'))}
$null=New-Item -ItemType Directory -Path $TestRoot -Force
$homePath=Join-Path $TestRoot 'launcher'
$workspacePath=Join-Path $TestRoot 'workspace'
$null=New-Item -ItemType Directory -Path $homePath
$null=New-Item -ItemType Directory -Path (Join-Path $workspacePath '.metadata')
$exePath=Join-Path $TestRoot 'edt.exe'
[IO.File]::WriteAllText($exePath,'fixture')
$utf8=New-Object Text.UTF8Encoding($false)
function Save($name,$value){[IO.File]::WriteAllText((Join-Path $homePath $name),($value | ConvertTo-Json -Depth 20),$utf8)}
Save 'products.json' @{version='1.1';data=@(@{id='product';location=$exePath})}
Save 'project-types.json' @{version='1.1';data=@(@{id='type';installedProducts=@('product')})}
Save 'projects.json' @{version='1.1';extra='preserve';data=@(@{id='old';label='Existing';location=(Join-Path $TestRoot 'existing');productId='product';projectTypeId='type';jvmPath='file:///java/';custom=42})}
# Isolate process discovery: these tests must never stop a real launcher.
function Get-Process {param($Name,$ErrorAction) @()}
$script=Join-Path $PSScriptRoot 'Register-EdtStartWorkspace.ps1'
$options=@{WorkspacePath=$workspacePath;EdtExecutablePath=$exePath;EdtStartHome=$homePath;DisplayName='Demo'}
$original=[IO.File]::ReadAllText((Join-Path $homePath 'projects.json'))
$null=& $script @options -Preview
if([IO.File]::ReadAllText((Join-Path $homePath 'projects.json')) -cne $original){throw 'Preview modified registry'}
& $script @options
$saved=[IO.File]::ReadAllText((Join-Path $homePath 'projects.json')) | ConvertFrom-Json
if($saved.data.Count -ne 2 -or $saved.extra -ne 'preserve' -or $saved.data[0].custom -ne 42 -or $saved.data[1].jvmPath -ne 'file:///java/'){throw 'Registry preservation failed'}
$backups=@(Get-ChildItem -LiteralPath $homePath -Filter '*.bak')
if($backups.Count -ne 1 -or [IO.File]::ReadAllText($backups[0].FullName) -cne $original){throw 'Backup failed'}
& $script @options
$saved=[IO.File]::ReadAllText((Join-Path $homePath 'projects.json')) | ConvertFrom-Json
if($saved.data.Count -ne 2){throw 'Duplicate registration'}
$saved.version='unknown';Save 'projects.json' $saved
$rejected=$false
try {& $script @options}catch{$rejected=$true}
if(-not $rejected){throw 'Unknown schema accepted'}
Write-Host "PASS: preview, preservation, backup, repeat registration, unknown schema. $TestRoot"
