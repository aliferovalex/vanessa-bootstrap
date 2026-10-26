#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot,[Parameter(Mandatory=$true)][string]$ToolsRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[void][IO.Directory]::CreateDirectory($TestRoot)
$template=Split-Path $PSScriptRoot -Parent;$script=Join-Path $PSScriptRoot 'Initialize-Project.ps1'
$common=@{InfobaseType='File';Infobase=(Join-Path $ToolsRoot 'source base');DesignerPath=(Join-Path $ToolsRoot 'tool.exe');EdtCliPath=(Join-Path $ToolsRoot 'tool.exe');ProjectName='Demo';GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=30;NoExtensions=$true}
function Assert($condition,$message){if(-not $condition){throw $message}}
$clone=Join-Path $TestRoot 'clone'; & git clone --no-hardlinks $template $clone
if ($LASTEXITCODE) {throw 'Clone failed'}
$head=& git -C $clone rev-parse HEAD;$oldBranch=& git -C $clone branch --show-current
$preview=& $script @common -TemplateDirectory $clone -GitBranch project/develop -Preview
Assert ($preview.GitBranch -eq 'project/develop') 'Preview does not show branch'
Assert ((& git -C $clone branch --show-current) -eq $oldBranch) 'Preview switched branches'
$failed=$false;try { & $script @common -TemplateDirectory $clone -GitBranch '../invalid' -Preview } catch {$failed=$true}
Assert $failed 'Invalid branch accepted'
& git -C $clone branch existing
$failed=$false;try { & $script @common -TemplateDirectory $clone -GitBranch existing -Preview } catch {$failed=$true}
Assert $failed 'Existing different branch accepted'
& $script @common -TemplateDirectory $clone -GitBranch project/develop
Assert ((& git -C $clone branch --show-current) -eq 'project/develop') 'Requested branch not selected'
Assert ((& git -C $clone rev-parse $oldBranch) -eq $head) 'Original branch changed'
Assert ((& git -C $clone rev-parse 'HEAD^') -eq $head) 'Initialization history incorrect'
$target=Join-Path $TestRoot 'separate'
& $script @common -TargetDirectory $target -GitBranch develop
Assert ((& git -C $target branch --show-current) -eq 'develop') 'Separate repository branch incorrect'
$pending=Join-Path $TestRoot 'pending';& git clone --no-hardlinks $template $pending
if ($LASTEXITCODE) {throw 'Clone failed'}
& $script @common -TemplateDirectory $pending -GitBranch feature/start -SkipInitialCommit
Assert ((& git -C $pending branch --show-current) -eq 'feature/start') 'Skipped commit branch missing'
Assert ((& git -C $pending rev-parse HEAD) -eq $head) 'Skipped commit advanced branch'
Assert ([bool](& git -C $pending diff --cached --name-only)) 'Skipped changes not staged'
Write-Host 'PASS: branch preview, invalid/existing rejection, new project branch, preserved original, separate repository and staged-only mode.'
