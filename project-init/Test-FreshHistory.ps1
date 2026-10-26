#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot,[Parameter(Mandatory=$true)][string]$ToolsRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[void][IO.Directory]::CreateDirectory($TestRoot)
$template=Split-Path $PSScriptRoot -Parent;$script=Join-Path $PSScriptRoot 'Initialize-Project.ps1'
$common=@{InfobaseType='File';Infobase=(Join-Path $ToolsRoot 'source base');DesignerPath=(Join-Path $ToolsRoot 'tool.exe');EdtCliPath=(Join-Path $ToolsRoot 'tool.exe');ProjectName='Demo';GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=30;NoExtensions=$true;FreshHistory=$true}
function Assert($condition,$message){if(-not $condition){throw $message}}
function Clone([string]$Name) {
    $clone=Join-Path $TestRoot $Name;& git clone --no-hardlinks $template $clone
    if($LASTEXITCODE){throw 'Clone failed'};return $clone
}
$clone=Clone 'fresh';$old=& git -C $clone rev-parse HEAD
$preview=& $script @common -TemplateDirectory $clone -Preview
Assert ($preview.FreshHistory -and $preview.GitBranch -eq 'main') 'Fresh preview incorrect'
Assert ((& git -C $clone rev-parse HEAD) -eq $old) 'Preview changed history'
& $script @common -TemplateDirectory $clone
Assert ((& git -C $clone rev-list --all --count) -eq '1') 'Template history retained'
Assert (($old | & git -C $clone cat-file --batch-check) -eq ($old+' missing')) 'Original commit exists in new Git'
Assert ((& git -C $clone branch --show-current) -eq 'main') 'Fresh default branch differs'
Assert (-not (& git -C $clone remote)) 'Template remotes retained'
Assert (-not (& git -C $clone status --porcelain)) 'Fresh working tree is dirty'
Assert (([IO.File]::ReadAllBytes((Join-Path $clone 'src/cf/src/image.png')) -join ',') -eq '0,13,10,255') 'LFS working content differs'
$journal=Get-ChildItem -LiteralPath $TestRoot -Filter fresh-history-publication.json -Recurse -Force | Select-Object -First 1
$record=Get-Content -Raw -Encoding UTF8 -LiteralPath $journal.FullName | ConvertFrom-Json
Assert ($record.phase -eq 'complete') 'Publication journal incomplete'
Assert ((& git ('--git-dir='+(Join-Path $record.backup '.git')) rev-parse HEAD) -eq $old) 'Original Git backup missing'
$pending=Clone 'pending'
& $script @common -TemplateDirectory $pending -SkipInitialCommit -GitBranch develop
Assert ((& git -C $pending symbolic-ref --short HEAD) -eq 'develop') 'Unborn branch incorrect'
$refs=& git -C $pending for-each-ref --format='%(refname)'
Assert (-not $refs -and [bool](& git -C $pending diff --cached --name-only)) 'Fresh staged-only mode retained references or lost changes'
$rollback=Clone 'rollback';$old=& git -C $rollback rev-parse HEAD
function Move-Item {
    param([string]$LiteralPath,[string]$Destination)
    if ($LiteralPath -like '*\repository\.git') { throw 'Simulated Git installation failure' }
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
}
try {$failed=$false;try { & $script @common -TemplateDirectory $rollback } catch {$failed=$true}}
finally {Remove-Item Function:\Move-Item}
Assert ($failed -and (& git -C $rollback rev-parse HEAD) -eq $old) 'Original Git not restored after failure'
Assert (-not (& git -C $rollback status --porcelain)) 'Original files not restored after failure'
Assert (-not (Test-Path (Join-Path $rollback 'project-init.json'))) 'Failed publication left new sources'
$linked=Clone 'linked';$worktree=Join-Path $TestRoot 'other-worktree'
& git -C $linked worktree add -b another $worktree
if($LASTEXITCODE){throw 'Worktree fixture failed'}
$failed=$false;try { & $script @common -TemplateDirectory $linked -Preview } catch {$failed=$true}
Assert $failed 'Shared Git directory was accepted'
Write-Host 'PASS: fresh history, original backup, LFS, unborn branch, publication rollback and linked worktree rejection.'
