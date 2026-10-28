#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Initialize-Project.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors){throw 'Initializer syntax error'}
foreach($name in @('Quote-NativeArgument','Get-SafeNativeArguments','Protect-Text','Write-Text','Export-Xml')){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$false)
 if(-not $node){throw ('Missing function: '+$name)}
 . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($value,$message){if(-not $value){throw $message}}
# Capture the real argument builder; never start Designer or EDT in this test.
function Run-Native([string]$Exe,[string[]]$Arguments,[string]$Label){
 $script:captured=$Arguments
 $dir=$Arguments[[Array]::IndexOf($Arguments,'/DumpConfigToFiles')+1]
 [IO.File]::WriteAllText((Join-Path $dir 'Configuration.xml'),'<MetaDataObject/>')
 [IO.File]::WriteAllText($Arguments[[Array]::IndexOf($Arguments,'/Out')+1],'Configuration repository connection not established')
 if($script:failure){throw 'Timeout: synthetic export'}
}
$script:failure=$false
$work=[IO.Path]::GetFullPath($TestRoot);[void][IO.Directory]::CreateDirectory($work)
$utf8=[Text.UTF8Encoding]::new($false);$DesignerPath='C:\tools\1cv8.exe';$connectionOption='/S';$Infobase='server:7541\test'
$InfobaseType='Server'
$UseOSAuthentication=$true;$UserName='';$Password=$null;$secret=$null
$RepositoryUserName=([string][char]0x0410)+' Name Surname';$repositorySecret='synthetic password " with spaces\'
Export-Xml (Join-Path $work 'main') 'main'
function Check-Order {
 $dump=[Array]::IndexOf($script:captured,'/DumpConfigToFiles')
 foreach($name in @('/S','/WA+','/WA-','/N','/P','/ConfigurationRepositoryF','/ConfigurationRepositoryN','/ConfigurationRepositoryP')){
  $index=[Array]::IndexOf($script:captured,$name)
  Assert ($index -lt $dump) ('Startup argument after dump: '+$name)
 }
}
Check-Order
Assert (-not ($script:captured -match '^/ConfigurationRepository')) 'Repository arguments passed during local configuration export'
Assert ((Quote-NativeArgument $RepositoryUserName) -eq ('"'+$RepositoryUserName+'"')) 'Repository login quoting failed'
$safe=@(Get-SafeNativeArguments $script:captured)
Assert ($safe.Count -eq $script:captured.Count -and $repositorySecret -notin $safe) 'Password in launch diagnostics'
$redacted=@(Get-SafeNativeArguments @('/P','ib secret','/ConfigurationRepositoryP',$repositorySecret))
Assert (($redacted -join ',') -eq '/P,[REDACTED],/ConfigurationRepositoryP,[REDACTED]') 'Password redaction failed'
$UseOSAuthentication=$false;$UserName='IB user';$secret='synthetic IB password';$Password=ConvertTo-SecureString $secret -AsPlainText -Force
Export-Xml (Join-Path $work 'extensions') 'extensions' -AllExtensions
Check-Order
Assert ('-AllExtensions' -in $script:captured -and '/WA-' -in $script:captured -and '/WA+' -notin $script:captured) 'Wrong extension/IB authentication arguments'
$safe=@(Get-SafeNativeArguments $script:captured)
Assert ($secret -notin $safe -and $repositorySecret -notin $safe) 'One of two passwords leaked'
$InfobaseType='Repository';$connectionOption='/F';$UserName='';$Password=$null;$secret=$null
Export-Xml (Join-Path $work 'unbound-read-base') 'unbound'
Assert ('/ConfigurationRepositoryN' -notin $script:captured -and '/ConfigurationRepositoryF' -notin $script:captured -and '/ConfigurationRepositoryP' -notin $script:captured) 'Repository credentials passed to an unbound read base'
$InfobaseType='Server';$script:failure=$true;$caught=''
try {Export-Xml (Join-Path $work 'partial') 'partial'}catch{$caught=$_.Exception.Message}
Assert ($caught -like '*Timeout: synthetic export*') 'Export failure swallowed'
Assert ($caught -notmatch '(?i)repository') 'Repository text in infobase export failure'
Assert ([IO.File]::ReadAllText((Join-Path $work 'partial.designer.log')) -like '*repository*') 'Original platform log lost'
Assert (Test-Path (Join-Path $work 'partial.export.json')) 'Missing partial-export diagnostics'
Write-Host 'PASS: local export without repository arguments; repository warning with exit zero; main/extensions; password redaction; failure preserved with diagnostics. No native tools executed.'
# Exercise actual process exit/timeout diagnostics with PowerShell, not 1C/EDT.
$node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Run-Native'},$false)
. ([scriptblock]::Create($node.Extent.Text))
$TimeoutSeconds=1;$shell=Join-Path $PSHOME 'powershell.exe'
$caught=''
try {Run-Native $shell @('-NoProfile','-Command','exit 7') 'exit-seven'}catch{$caught=$_.Exception.Message}
Assert ($caught -like '*failed (exit 7)*') 'Native failure lost'
$result=[IO.File]::ReadAllText((Join-Path $work 'exit-seven.result.json'))|ConvertFrom-Json
Assert ($result.exitCode -eq 7 -and -not $result.timedOut) 'Incorrect nonzero-exit diagnostics'
$caught=''
try {Run-Native $shell @('-NoProfile','-Command','Start-Sleep -Seconds 10') 'timeout'}catch{$caught=$_.Exception.Message}
Assert ($caught -like 'Timeout: timeout after 1 seconds*') 'Native timeout lost'
$result=[IO.File]::ReadAllText((Join-Path $work 'timeout.result.json'))|ConvertFrom-Json
Assert ($result.timedOut -and $result.timeoutSeconds -eq 1) 'Incorrect timeout diagnostics'
Write-Host 'PASS: real process nonzero exit and timeout persisted; no 1C/EDT processes started.'
