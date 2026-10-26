#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
& (Join-Path $PSScriptRoot 'Test-InitializeProject.ps1') -TestRoot $TestRoot
$template=Split-Path $PSScriptRoot -Parent
$script=Join-Path $PSScriptRoot 'Initialize-Project.ps1'
$globalBefore=(& git config --global --list | Out-String)
function Assert($condition,$message){if(-not $condition){throw $message}}
function Clone([string]$Name) {
    $path=Join-Path $TestRoot $Name
    & git clone --no-hardlinks $template $path
    if ($LASTEXITCODE) { throw 'Cannot clone fixture.' }
    return $path
}
$common=@{InfobaseType='File';Infobase=(Join-Path $TestRoot 'source base');DesignerPath=(Join-Path $TestRoot 'tool.exe');EdtCliPath=(Join-Path $TestRoot 'tool.exe');ProjectName='Demo';GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=30}
$clone=Clone 'in-place'
$head=(& git -C $clone rev-parse HEAD);$branch=(& git -C $clone branch --show-current)
$origin=(& git -C $clone remote get-url origin)
& $script @common -TemplateDirectory $clone -Preview | Out-Null
Assert (-not (Test-Path (Join-Path $clone 'project-init.json'))) 'Preview changed project'
& $script @common -TemplateDirectory $clone -Extensions ExtTwo -ProjectRemoteUrl https://example.invalid/team/demo.git
Assert ((& git -C $clone rev-parse 'HEAD^') -eq $head) 'Template history was lost'
Assert ((& git -C $clone branch --show-current) -eq $branch) 'Existing branch was replaced'
Assert ((& git -C $clone remote get-url bootstrap) -eq $origin) 'Template remote not preserved'
Assert ((& git -C $clone remote get-url origin) -eq 'https://example.invalid/team/demo.git') 'Project remote not set'
Assert (Test-Path (Join-Path $clone 'src/cfe/ExtTwo/.project')) 'Selected extension missing'
Assert (-not (Test-Path (Join-Path $clone 'src/cfe/ExtOne'))) 'Unselected extension imported'
Assert (-not (& git -C $clone status --porcelain)) 'Initialized repository is dirty'
Assert ((& git -C $clone config --local core.safecrlf) -eq 'true') 'Safe line ending checks disabled'
& (Join-Path $template 'tools/git-global-init.cmd') -ProjectDirectory $clone -NoGitLfs
Assert ((& git -C $clone config --local user.name) -eq 'Test') 'Legacy Git setup replaced the author'
Assert (([IO.File]::ReadAllBytes((Join-Path $clone 'src/cf/src/image.png')) -join ',') -eq '0,13,10,255') 'LFS content was not materialized'
$failed=$false;try { & $script @common -TemplateDirectory $clone } catch {$failed=$true}
Assert $failed 'Repeated initialization was accepted'
$pending=Clone 'without-commit';$head=(& git -C $pending rev-parse HEAD)
& $script @common -TemplateDirectory $pending -SkipInitialCommit -NoExtensions
Assert ((& git -C $pending rev-parse HEAD) -eq $head) 'SkipInitialCommit advanced HEAD'
Assert ([bool](& git -C $pending diff --cached --name-only)) 'Prepared changes not staged'
$dirty=Clone 'dirty'
[IO.File]::AppendAllText((Join-Path $dirty 'README.md'),'User data')
$failed=$false;try { & $script @common -TemplateDirectory $dirty } catch {$failed=$true}
Assert ($failed -and -not (Test-Path (Join-Path $dirty 'project-init.json'))) 'Dirty repository overwritten'
$existing=Clone 'existing-sources'
[IO.File]::WriteAllText((Join-Path $existing 'src/cf/Configuration.xml'),'<UserData/>')
& git -C $existing add -- src/cf/Configuration.xml
& git -C $existing -c user.name=Test -c user.email=test@example.invalid commit -m 'Existing sources' | Out-Null
$failed=$false;try { & $script @common -TemplateDirectory $existing } catch {$failed=$true}
Assert $failed 'Existing committed sources overwritten'
$race=Clone 'concurrent-change';$head=(& git -C $race rev-parse HEAD)
function Read-Host { param($Prompt) [IO.File]::AppendAllText((Join-Path $race 'README.md'),'Concurrent user edit');return '*' }
try {$failed=$false;try { & $script @common -TemplateDirectory $race -SelectExtensions } catch {$failed=$true}}
finally {Remove-Item Function:\Read-Host}
Assert ($failed -and (& git -C $race rev-parse HEAD) -eq $head) 'Concurrent edits were overwritten'
Assert (-not (Test-Path (Join-Path $race 'project-init.json'))) 'Concurrent failure published sources'
Assert ([IO.File]::ReadAllText((Join-Path $race 'README.md')).Contains('Concurrent user edit')) 'User edit was lost'
Assert (-not (Test-Path (Join-Path $race '.git/project-initialization.lock'))) 'Initialization lock leaked'
Assert ((& git config --global --list | Out-String) -eq $globalBefore) 'Global Git configuration changed'
Write-Host 'PASS: in-place history, branch, remotes, LFS content, skipped commit, repeated initialization, existing sources and concurrent edits.'
