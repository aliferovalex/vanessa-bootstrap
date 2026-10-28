#requires -Version 5.1
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Initialize-Project.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Initializer syntax error'}
foreach($name in @('Read-InitializationChoice','Set-InitializationAuthentication','Set-InitializationGitOptions')){
 $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
 . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($value,$message){if(-not $value){throw $message}}
function Answers([string[]]$Values){$script:answers=[Collections.Generic.Queue[string]]::new();foreach($v in $Values){$script:answers.Enqueue($v)}}
function Read-Host([string]$Prompt){
 if(-not $script:answers.Count){throw ('Unexpected question: '+$Prompt)}
 return $script:answers.Dequeue()
}
function Reset {$script:UseOSAuthentication=$false;$script:AskCredential=$false;$script:FreshHistory=$false;$script:GitBranch=''}
Reset;Answers @('','','develop')
Set-InitializationAuthentication @{} File $false
Set-InitializationGitOptions @{} $true master $false
Assert ($UseOSAuthentication -and -not $FreshHistory -and $GitBranch -eq 'develop' -and -not $answers.Count) 'Missing options/defaults were not applied'
Reset;Answers @('2')
Set-InitializationAuthentication @{} Server $false
Assert ($AskCredential -and -not $UseOSAuthentication) 'Declining OS authentication must select infobase credentials'
Reset;Answers @('1','')
Set-InitializationGitOptions @{} $true master $false
Assert ($FreshHistory -and $GitBranch -eq 'main') 'Fresh history should default to main'
Reset;Answers @();$GitBranch='release/test'
$provided=@{UseOSAuthentication=$false;FreshHistory=$false;GitBranch=$GitBranch}
Set-InitializationAuthentication $provided File $false
Set-InitializationGitOptions $provided $true master $false
Assert (-not $UseOSAuthentication -and -not $FreshHistory -and $GitBranch -eq 'release/test') 'Explicit false switches or branch ignored'
foreach($name in @('UserName','Password','AskCredential','UseOSAuthentication')){
 Reset;Answers @();Set-InitializationAuthentication @{$name=$true} File $false
}
Reset;Answers @();Set-InitializationAuthentication @{} Repository $false
Set-InitializationGitOptions @{} $true master $true
Assert ($GitBranch -eq 'master' -and -not $FreshHistory -and -not $UseOSAuthentication) 'Preview/noninteractive defaults changed'
Reset;Answers @('bad','1','release/new')
Set-InitializationGitOptions @{} $true master $false
Assert ($FreshHistory -and $GitBranch -eq 'release/new' -and -not $answers.Count) 'Invalid choice was not retried'
Reset;Answers @('')
Set-InitializationGitOptions @{} $false '' $false
Assert ($GitBranch -eq 'main' -and -not $answers.Count) 'Separate target asked about replacing nonexistent history'
Write-Host 'PASS: missing settings, defaults, explicit false, credentials, Repository, noninteractive/preview, retry and separate target.'
