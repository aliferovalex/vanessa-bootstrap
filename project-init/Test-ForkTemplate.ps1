#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Test-InitializeProject.ps1') -TestRoot $TestRoot
if ($LASTEXITCODE) { throw 'Initializer regression failed.' }
$template=Split-Path $PSScriptRoot -Parent
$target=Join-Path $TestRoot 'hybrid project'
$options=@{InfobaseType='File';Infobase=(Join-Path $TestRoot 'source base');DesignerPath=(Join-Path $TestRoot 'tool.exe');EdtCliPath=(Join-Path $TestRoot 'tool.exe');ProjectName='Hybrid';GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=30;TemplateDirectory=$template}
& (Join-Path $PSScriptRoot 'Initialize-Project.ps1') @options -TargetDirectory $target
function Assert($condition,$message){if(-not $condition){throw $message}}
$manifest=Get-Content -Raw -LiteralPath (Join-Path $target 'project-init.json') | ConvertFrom-Json
Assert ($manifest.template.commit -eq (& git -C $template rev-parse HEAD)) 'Template version missing'
Assert (Test-Path (Join-Path $target 'initialize.cmd')) 'Initializer missing'
Assert (Test-Path (Join-Path $target 'tools/JSON/vrunner.json')) 'Template tools missing'
Assert (Test-Path (Join-Path $target 'src/cfe/ExtOne/.project')) 'Extension missing'
Assert ((& git -C $target rev-list --count HEAD) -eq '1') 'Upstream history leaked into project'
Assert (-not (& git -C $target remote)) 'Template remote leaked into project'
Assert (-not (& git -C $target status --porcelain)) 'Generated working tree is dirty'
$settings=Get-Content -Raw -LiteralPath (Join-Path $target 'env.json') | ConvertFrom-Json
Assert ($settings.default.'--v8version' -eq $manifest.platformVersion) 'Runner platform mismatch'
$attributes=Get-Content -Raw -LiteralPath (Join-Path $target '.gitattributes')
Assert ($attributes.Contains('*.sh text eol=lf')) 'Upstream line-ending rule lost'
Assert ($attributes.Contains('filter=lfs')) 'LFS rules missing'
$without=Join-Path $TestRoot 'hybrid without lfs'
& (Join-Path $PSScriptRoot 'Initialize-Project.ps1') @options -TargetDirectory $without -NoGitLfs -NoExtensions
Assert (-not (Get-Content -Raw -LiteralPath (Join-Path $without '.gitattributes')).Contains('filter=lfs')) 'LFS opt-out failed'
Write-Host 'PASS: template preservation, fresh history, no remote, platform settings, LFS and opt-out.'
