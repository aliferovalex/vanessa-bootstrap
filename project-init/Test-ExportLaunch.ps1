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
function Run-Native([string]$Exe,[string[]]$Arguments,[string]$Label){$script:captured=$Arguments}
$work=[IO.Path]::GetFullPath($TestRoot);[void][IO.Directory]::CreateDirectory($work)
$utf8=[Text.UTF8Encoding]::new($false);$DesignerPath='C:\tools\1cv8.exe';$connectionOption='/S';$Infobase='server:7541\test'
$InfobaseType='Server'
$UseOSAuthentication=$true;$UserName='';$Password=$null;$secret=$null
$RepositoryAddress='tcp://repo.invalid:3542/ka/release/general'
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
Assert ($script:captured[[Array]::IndexOf($script:captured,'/ConfigurationRepositoryF')+1] -eq $RepositoryAddress) 'Repository address lost'
Assert ($script:captured[[Array]::IndexOf($script:captured,'/ConfigurationRepositoryN')+1] -eq $RepositoryUserName) 'Unicode/spaces in repository login lost'
Assert ((Quote-NativeArgument $RepositoryUserName) -eq ('"'+$RepositoryUserName+'"')) 'Repository login quoting failed'
$safe=@(Get-SafeNativeArguments $script:captured)
Assert ($safe.Count -eq $script:captured.Count -and $repositorySecret -notin $safe) 'Password in launch diagnostics'
Assert ($safe[[Array]::IndexOf($safe,'/ConfigurationRepositoryP')+1] -eq '[REDACTED]') 'Repository password not redacted'
$UseOSAuthentication=$false;$UserName='IB user';$secret='synthetic IB password';$Password=ConvertTo-SecureString $secret -AsPlainText -Force
Export-Xml (Join-Path $work 'extensions') 'extensions' -AllExtensions
Check-Order
Assert ('-AllExtensions' -in $script:captured -and '/WA-' -in $script:captured -and '/WA+' -notin $script:captured) 'Wrong extension/IB authentication arguments'
$safe=@(Get-SafeNativeArguments $script:captured)
Assert ($secret -notin $safe -and $repositorySecret -notin $safe) 'One of two passwords leaked'
$InfobaseType='Repository';$connectionOption='/F';$UserName='';$Password=$null;$secret=$null
Export-Xml (Join-Path $work 'unbound-read-base') 'unbound'
Assert ('/ConfigurationRepositoryN' -notin $script:captured -and '/ConfigurationRepositoryF' -notin $script:captured -and '/ConfigurationRepositoryP' -notin $script:captured) 'Repository credentials passed to an unbound read base'
Write-Host 'PASS: startup arguments precede export; explicit repository address; Unicode/spaces; main/extensions; redaction of both passwords. No native tools executed.'
