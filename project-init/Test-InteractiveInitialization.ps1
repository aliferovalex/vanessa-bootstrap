#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot,[Parameter(Mandatory=$true)][string]$ToolsRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[void][IO.Directory]::CreateDirectory($TestRoot)
$template=Split-Path $PSScriptRoot -Parent;$initializer=Join-Path $PSScriptRoot 'Initialize-Project.ps1'
function Assert($value,$message){if(-not $value){throw $message}}
function Answers([string[]]$Values){$script:answers=[Collections.Generic.Queue[string]]::new();foreach($v in $Values){$script:answers.Enqueue($v)}}
function Read-Host {
 param([string]$Prompt,[switch]$AsSecureString)
 if(-not $answers.Count){throw ('Unexpected question: '+$Prompt)}
 $value=$answers.Dequeue()
 if($AsSecureString){return ConvertTo-SecureString $value -AsPlainText -Force}
 return $value
}
$common=@{InfobaseType='File';Infobase=(Join-Path $ToolsRoot 'source base');DesignerPath=(Join-Path $ToolsRoot 'tool.exe');EdtCliPath=(Join-Path $ToolsRoot 'tool.exe');ProjectName='InteractiveDemo';GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=30;NoExtensions=$true;NoGitLfs=$true}
foreach($mode in @('fresh','keep','explicit')) {
 $clone=Join-Path $TestRoot $mode
 & git clone --local --no-hardlinks $template $clone
 if($LASTEXITCODE){throw 'Cannot clone fixture'}
 $before=& git -C $clone rev-parse HEAD
 $branch=& git -C $clone branch --show-current
 if($mode -eq 'fresh') {
  Answers @('1','1','release/interactive')
  & $initializer @common -TemplateDirectory $clone
  Assert ((& git -C $clone rev-list --count HEAD) -eq '1') 'Fresh-history answer ignored'
  Assert ((& git -C $clone branch --show-current) -eq 'release/interactive') 'Branch answer ignored'
 } elseif($mode -eq 'keep') {
  Answers @('2','2','','test-user','test-password')
  & $initializer @common -TemplateDirectory $clone
  Assert ((& git -C $clone rev-parse 'HEAD^') -eq $before) 'Keep-history answer ignored'
  Assert ((& git -C $clone branch --show-current) -eq $branch) 'Default branch changed'
  $diagnostics=Get-ChildItem -LiteralPath $TestRoot -Directory -Filter '.project-init-*' |
   Where-Object {Test-Path (Join-Path $_.FullName 'dump-main.launch.json')} |
   Where-Object {([IO.File]::ReadAllText((Join-Path $_.FullName 'dump-main.launch.json'))|ConvertFrom-Json).arguments -contains '/WA-'} | Select-Object -First 1
  Assert ($null -ne $diagnostics) 'Infobase credentials were not selected after declining OS authentication'
 } else {
  Answers @()
  & $initializer @common -TemplateDirectory $clone -FreshHistory:$false -UseOSAuthentication -GitBranch release/explicit
  Assert ((& git -C $clone rev-parse 'HEAD^') -eq $before) 'Explicit false FreshHistory ignored'
  Assert ((& git -C $clone branch --show-current) -eq 'release/explicit') 'Explicit branch ignored'
 }
 Assert (-not $answers.Count) 'A requested setting was never consumed'
 Assert (-not((& git -C $clone status --porcelain) -join '')) 'Initialized worktree is dirty'
}
Write-Host 'PASS: actual interactive initializer: new history, kept history, branch, OS/infobase authentication and no repeated questions for explicit settings.'
