#requires -Version 5.1
# Integration of orchestration with executable doubles for 1C/EDT and real Git.
[CmdletBinding()]param([string]$TestRoot)
$ErrorActionPreference='Stop'
if(-not $TestRoot){$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('init-project-tests-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
$code=@'
using System;
using System.IO;
using System.Linq;
using System.Reflection;
[assembly: AssemblyFileVersion("8.5.1.1529")]
class Tool {
 static string Value(string[] a,string key) { int n=Array.IndexOf(a,key); return n<0?null:a[n+1]; }
 static void Xml(string dir,string name) { Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir,"Configuration.xml"),"<MetaDataObject><Configuration><Properties><Name>"+name+"</Name></Properties></Configuration></MetaDataObject>"); }
 static int Main(string[] a) {
  if(a.Length>0 && a[0]=="DESIGNER") {
   string expectedUser=Environment.GetEnvironmentVariable("INIT_TEST_USER");
   string expectedPassword=Environment.GetEnvironmentVariable("INIT_TEST_PASSWORD");
   if(expectedUser!=null && (Value(a,"/N")!=expectedUser || (Value(a,"/P")??"")!=(expectedPassword??""))) return 33;
   string dir=Value(a,"/DumpConfigToFiles");
   if(a.Contains("-AllExtensions")){Xml(Path.Combine(dir,"ExtOne"),"ExtOne"); Xml(Path.Combine(dir,"ExtTwo"),"ExtTwo");}
   else Xml(dir,"Configuration");
   File.WriteAllText(Value(a,"/Out"),"Export completed"); return 0;
  }
  if(a.Contains("help")){Console.WriteLine("import --configuration-files --project-name --base-project-name --version");return 0;}
  if(a.Contains("import")){
   if(Environment.GetEnvironmentVariable("INIT_TEST_FAIL")=="1")return 7;
   string dir=Path.Combine(Value(a,"-data"),Value(a,"--project-name"));Directory.CreateDirectory(Path.Combine(dir,"src"));
   File.WriteAllText(Path.Combine(dir,".project"),"<projectDescription><name>"+Value(a,"--project-name")+"</name><base>"+Value(a,"--base-project-name")+"</base></projectDescription>");
   File.WriteAllText(Path.Combine(dir,"src","Configuration.mdo"),"<Configuration/>");
   File.WriteAllBytes(Path.Combine(dir,"src","image.png"),new byte[]{0,13,10,255});
   File.WriteAllBytes(Path.Combine(dir,"src","Template.bin"),new byte[]{0,255,13,10});return 0;
  }
  return 9;
 }
}
'@
$source=Join-Path $TestRoot 'Tool.cs'
[IO.File]::WriteAllText($source,$code,[Text.UTF8Encoding]::new($false))
$exe=Join-Path $TestRoot 'tool.exe'
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:exe ("/out:"+$exe) $source
if($LASTEXITCODE -ne 0){throw 'Cannot compile executable test double'}
$base=Join-Path $TestRoot 'source base'
New-Item -ItemType Directory -Path $base | Out-Null
[IO.File]::WriteAllBytes((Join-Path $base '1Cv8.1CD'),[byte[]]@())
$script=Join-Path $PSScriptRoot 'Initialize-Project.ps1'
$common=@{InfobaseType='File';Infobase=$base;DesignerPath=$exe;EdtCliPath=$exe;ProjectName='TestConfig';GitUserName='Initializer test';GitUserEmail='initializer@example.invalid';TimeoutSeconds=30}
function Assert($condition,$message){if(-not $condition){throw $message}}
$preview=Join-Path $TestRoot 'preview'
& $script @common -TargetDirectory $preview -Preview | Out-Null
Assert (-not(Test-Path $preview)) 'Preview created target'
$target=Join-Path $TestRoot 'project with spaces'
& $script @common -TargetDirectory $target -Extensions 'ExtTwo'
Assert (Test-Path (Join-Path $target 'src\cf\.project')) 'Main project missing'
Assert (Test-Path (Join-Path $target 'src\cfe\ExtTwo\.project')) 'Extension project missing'
Assert (-not(Test-Path (Join-Path $target 'src\cfe\ExtOne'))) 'Unselected extension imported'
$manifest=[IO.File]::ReadAllText((Join-Path $target 'project-init.json')) | ConvertFrom-Json
Assert ($manifest.configuration.path -eq 'src/cf') 'Main manifest path mismatch'
Assert ($manifest.extensions[0].path -eq 'src/cfe/ExtTwo') 'Extension manifest path mismatch'
Assert (-not(Test-Path (Join-Path $target 'src/configuration'))) 'Legacy main directory created'
Assert (-not(Test-Path (Join-Path $target 'src/extensions'))) 'Legacy extensions directory created'
[xml]$project=Get-Content (Join-Path $target 'src\cfe\ExtTwo\.project') -Raw
Assert ($project.projectDescription.base -eq 'TestConfig') 'Extension base association missing'
$tracked=@(& git -C $target ls-files)
Assert (-not($tracked -match '\.metadata|\.1CD|\.log')) 'Internal files tracked in Git'
$count=& git -C $target rev-list --count HEAD
Assert ($count -eq '1') 'Initial commit missing'
$pointerText=(& git -C $target show 'HEAD:src/cf/src/image.png') -join "`n"
Assert ($pointerText.StartsWith('version https://git-lfs.github.com/spec/v1')) 'Image was not stored through LFS in initial commit'
Assert ((Get-Item -LiteralPath (Join-Path $target 'src/cf/src/image.png')).Length -eq 4) 'LFS pointer replaced working content'
Assert (Test-Path -LiteralPath (Join-Path $target '.git/hooks/pre-push')) 'LFS pre-push hook missing'
$lfsRequired=& git -C $target config --local --get filter.lfs.required
Assert ($lfsRequired -eq 'true') 'LFS was not installed locally'
$attributes=[IO.File]::ReadAllText((Join-Path $target '.gitattributes'))
Assert ($attributes.Contains('* text=auto') -and -not $attributes.Contains('eol=lf')) 'Unexpected forced LF rule'
$autocrlf=& git -C $target config --local --get core.autocrlf
$safecrlf=& git -C $target config --local --get core.safecrlf
Assert ($autocrlf -eq 'true' -and $safecrlf -eq 'true') 'Missing local Windows line-ending settings'
$lineReport=(& git -C $target ls-files --eol -- 'project-init.json' '.gitattributes') -join "`n"
Assert ([regex]::Matches($lineReport,'i/lf\s+w/crlf').Count -eq 2) 'Expected LF in index and CRLF in both working files'
$binaryBytes=[IO.File]::ReadAllBytes((Join-Path $target 'src/cf/src/image.png'))
Assert (($binaryBytes -join ',') -eq '0,13,10,255') 'Binary content changed during checkout'
Assert (-not((& git -C $target status --porcelain) -join '')) 'Initial working copy is dirty'
foreach($pattern in @('*.cf','*.bin','*.png','*.gif','*.bmp','*.jpg','*.zip')){
 Assert ($attributes.Contains($pattern+' filter=lfs diff=lfs merge=lfs -text')) ('Missing official EDT LFS pattern: '+$pattern)
}
$withoutLfs=Join-Path $TestRoot 'without-lfs'
& $script @common -TargetDirectory $withoutLfs -NoExtensions -NoGitLfs
Assert (-not([IO.File]::ReadAllText((Join-Path $withoutLfs '.gitattributes')).Contains('filter=lfs'))) 'NoGitLfs unexpectedly installed patterns'
$failed=$false
try { & $script @common -TargetDirectory $target -Preview } catch {$failed=$true}
Assert $failed 'Existing target was accepted'
$bad=Join-Path $TestRoot 'bad-extension'
$failed=$false
try { & $script @common -TargetDirectory $bad -Extensions 'Missing' } catch {$failed=$true}
Assert ($failed -and -not(Test-Path $bad)) 'Missing extension published a repository'
$bad=Join-Path $TestRoot 'failed-import'
$oldFail=$env:INIT_TEST_FAIL
try {
 $env:INIT_TEST_FAIL='1';$failed=$false
 try { & $script @common -TargetDirectory $bad -NoExtensions } catch {$failed=$true}
 Assert ($failed -and -not(Test-Path $bad)) 'Failed EDT import published a repository'
} finally {$env:INIT_TEST_FAIL=$oldFail}
$interactiveTarget=Join-Path $TestRoot 'interactive selection'
function Read-Host { param($Prompt) if($Prompt -like 'Select extension numbers*'){return '2'};throw 'Unexpected interactive prompt' }
try {
 & $script @common -TargetDirectory $interactiveTarget -SelectExtensions
 $interactiveManifest=[IO.File]::ReadAllText((Join-Path $interactiveTarget 'project-init.json')) | ConvertFrom-Json
 Assert ($interactiveManifest.extensions.Count -eq 1 -and $interactiveManifest.extensions[0].name -eq 'ExtTwo') 'Interactive selection imported wrong extensions'
 Assert (-not(Test-Path (Join-Path $interactiveTarget 'src/cfe/ExtOne'))) 'Unselected project was imported'
} finally { Remove-Item Function:\Read-Host }
$oldUser=$env:INIT_TEST_USER;$oldPassword=$env:INIT_TEST_PASSWORD
try {
 $env:INIT_TEST_USER='1C test user'
 function Read-Host {
  param($Prompt,[switch]$AsSecureString)
  if($AsSecureString){
   $value=New-Object Security.SecureString
   foreach($character in ([string]$env:INIT_TEST_PASSWORD).ToCharArray()){$value.AppendChar($character)}
   return $value
  }
  if($Prompt -like '*user name*'){return $env:INIT_TEST_USER}
  throw 'Unexpected credential prompt'
 }
 foreach($case in @('empty','special')){
  $env:INIT_TEST_PASSWORD=if($case -eq 'empty'){''}else{'synthetic p@ss"word\ tail'}
  $authenticated=Join-Path $TestRoot ('authenticated-'+$case)
  $serverOptions=$common.Clone();$serverOptions.InfobaseType='Server';$serverOptions.Infobase='test-server:7541\test-base'
  & $script @serverOptions -TargetDirectory $authenticated -AskCredential -NoExtensions -NoGitLfs
  Assert (Test-Path (Join-Path $authenticated 'project-init.json')) 'Credential export failed'
 }
} finally {
 Remove-Item Function:\Read-Host
 $env:INIT_TEST_USER=$oldUser;$env:INIT_TEST_PASSWORD=$oldPassword
}
Write-Host "PASS: preview, selected extension, base association, Git commit, LFS initial objects and hooks, opt-out, existing target, missing extension, failed import, interactive selection, console credentials with empty/special passwords. Artifacts: $TestRoot"
