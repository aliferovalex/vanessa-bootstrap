#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$TestRoot=[IO.Path]::GetFullPath($TestRoot);[void][IO.Directory]::CreateDirectory($TestRoot)
$code=@'
using System;using System.IO;using System.Linq;using System.Reflection;using System.Text.RegularExpressions;
[assembly:AssemblyFileVersion("8.3.27.1936")]
class Tool {
 static string V(string[] a,string k){int i=Array.IndexOf(a,k);return i<0?null:a[i+1];}
 static void Xml(string dir){Directory.CreateDirectory(dir);File.WriteAllText(Path.Combine(dir,"Configuration.xml"),"<MetaDataObject xmlns=\"http://v8.1c.ru/8.3/MDClasses\" version=\"2.20\"><Configuration><InternalInfo/><Properties><Name>Demo</Name></Properties></Configuration></MetaDataObject>");File.WriteAllBytes(Path.Combine(dir,"Form.bin"),new byte[]{0,255,13,10,128});}
 static int Main(string[] a){
  string stage;
  if(a[0]=="CREATEINFOBASE"){return 0;}
  if(a.Contains("help")){Console.WriteLine("import --project --configuration-files");return 0;}
  if(a.Contains("import"))return 7;
  if(a.Contains("/ConfigurationRepositoryDumpCfg")){File.WriteAllText(V(a,"/ConfigurationRepositoryDumpCfg"),"CF");return 0;}
  if(a.Contains("/LoadCfg") || a.Contains("/LoadConfigFromFiles"))return 0;
  if(!a.Contains("/DumpConfigToFiles"))return 9;
  stage=a.Contains("-AllExtensions")?"dump-extensions":"dump-main";
  File.AppendAllText(Environment.GetEnvironmentVariable("INIT_XML_TRACE"),stage+"\n");
  string dir=V(a,"/DumpConfigToFiles");
  if(stage=="dump-extensions"){Xml(Path.Combine(dir,"Ext"));Xml(Path.Combine(dir,"Other"));}else Xml(dir);
  File.WriteAllText(V(a,"/Out"),"Done");
  return Environment.GetEnvironmentVariable("INIT_XML_FAIL")==stage?7:0;
 }
}
'@
$exe=Join-Path $TestRoot 'designer.exe';$source=Join-Path $TestRoot 'tool.cs'
[IO.File]::WriteAllText($source,$code)
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe ("/out:"+$exe) $source
if($LASTEXITCODE){throw 'Cannot compile fixture'}
$base=Join-Path $TestRoot 'base';[void][IO.Directory]::CreateDirectory($base)
[IO.File]::WriteAllBytes((Join-Path $base '1Cv8.1CD'),[byte[]]@())
$initializer=Join-Path $PSScriptRoot 'Initialize-Project.ps1'
function Assert($value,$message){if(-not $value){throw $message}}
function Read-Host {throw 'XML initialization unexpectedly requested input'}
$oldTrace=$env:INIT_XML_TRACE;$oldFail=$env:INIT_XML_FAIL
try{
 foreach($scenario in @('File','Server','Repository','resume','switch','in-place')){
  $root=Join-Path $TestRoot $scenario;[void][IO.Directory]::CreateDirectory($root)
  $env:INIT_XML_TRACE=Join-Path $root 'trace.txt';$env:INIT_XML_FAIL=''
  $target=Join-Path $root 'project'
  $options=@{SourceFormat='XML';InfobaseType='File';Infobase=$base;TargetDirectory=$target;DesignerPath=$exe;
    Extensions=@('Ext');NonInteractive=$true;NoGitLfs=$true;GitBranch='main';GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=120}
  if($scenario -eq 'Server'){$options.InfobaseType='Server';$options.Infobase='host:1541\demo';$options.Remove('Extensions');$options.NoExtensions=$true}
  if($scenario -eq 'File'){$options.SourceFormat='xml';$options.EdtCliPath='missing-unused.exe'}
  if($scenario -eq 'in-place'){
   [void][IO.Directory]::CreateDirectory($target);[IO.File]::WriteAllText((Join-Path $target 'README.md'),'Template fixture')
   & git init --initial-branch=main $target|Out-Null
   & git -C $target add README.md
   & git -C $target -c user.name=Test -c user.email=test@example.invalid commit -m Template|Out-Null
   if($LASTEXITCODE){throw 'Cannot create in-place fixture'}
   $options.TemplateDirectory=$target;$options.FreshHistory=$true
  }
  if($scenario -eq 'Repository'){
   $options.InfobaseType='Repository';$options.Infobase='tcp://example.invalid:1543/main'
   $options.RepositoryUserName='Reader';$options.RepositoryPassword=New-Object Security.SecureString
   $options.ExtensionRepositoryFile=Join-Path $root 'repositories.json'
   [IO.File]::WriteAllText($options.ExtensionRepositoryFile,'[{"name":"Ext","url":"tcp://example.invalid:1543/ext","version":1}]')
  }
  $preview=& $initializer @options -Preview
  Assert ($preview.SourceFormat -eq 'XML' -and -not(Test-Path (Join-Path $target 'project-init.json'))) 'XML preview or no-EDT mode failed'
  $rejected=$false;try{& $initializer @options -RegisterEdtStart -Preview|Out-Null}catch{$rejected=$_.Exception.Message -like '*require -SourceFormat EDT*'}
  Assert $rejected 'EDT registration accepted for XML'
  if($scenario -in @('resume','switch')){
   if($scenario -eq 'resume'){$env:INIT_XML_FAIL='dump-extensions'}
   else{$options.SourceFormat='EDT';$options.EdtCliPath=$exe}
   $failed=$false;try{& $initializer @options}catch{$failed=$_.Exception.Message -like '*failed (exit 7)*';if(-not $failed){throw}}
   Assert ($failed -and -not(Test-Path $target)) 'Failed initialization published XML'
   $previous=Get-ChildItem -LiteralPath $root -Directory -Filter '.project-init-*'|Select-Object -First 1
   $env:INIT_XML_FAIL=''
   if($scenario -eq 'switch'){
    & $initializer -ResumeFrom $previous.FullName -SourceFormat XML -EdtCliPath 'missing-unused.exe' -NonInteractive
   }else{& $initializer -ResumeFrom $previous.FullName -NonInteractive}
   $trace=@([IO.File]::ReadAllLines($env:INIT_XML_TRACE))
   Assert (@($trace|Where-Object {$_ -eq 'dump-main'}).Count -eq $(if($scenario -eq 'resume'){2}else{1})) 'Wrong snapshot reuse during XML continuation'
  }else{& $initializer @options}
  $manifest=[IO.File]::ReadAllText((Join-Path $target 'project-init.json'))|ConvertFrom-Json
  Assert ($manifest.sourceFormat -eq 'XML') 'Wrong manifest format'
  Assert (Test-Path (Join-Path $target 'src/cf/Configuration.xml')) 'Main XML missing'
  Assert (-not(Test-Path (Join-Path $target 'src/cf/.project'))) 'Unexpected EDT project'
  Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target 'src/cf/Form.bin'))) -eq 'AP8NCoA=') 'Binary resource changed'
  if($scenario -eq 'Server'){Assert (@($manifest.extensions).Count -eq 0) 'NoExtensions ignored'}
  else{
   Assert (Test-Path (Join-Path $target 'src/cfe/Ext/Configuration.xml')) 'Extension XML missing'
   Assert (-not(Test-Path (Join-Path $target 'src/cfe/Other'))) 'Unselected extension copied'
  }
  Assert (-not((& git -C $target status --porcelain) -join '')) 'XML Git worktree is dirty'
  if($scenario -eq 'in-place'){Assert ((& git -C $target rev-list --count HEAD) -eq '1') 'Fresh XML history retained template commits'}
  $latest=Get-ChildItem -LiteralPath $root -Directory -Filter '.project-init-*'|Sort-Object CreationTime -Descending|Select-Object -First 1
  Assert (-not(Test-Path (Join-Path $latest.FullName 'edt-workspace'))) 'XML mode created EDT workspace'
  Assert (-not(Test-Path (Join-Path $latest.FullName 'edt-help-import.launch.json'))) 'XML mode launched EDT'
 }
}finally{$env:INIT_XML_TRACE=$oldTrace;$env:INIT_XML_FAIL=$oldFail;Remove-Item Function:\Read-Host}
Write-Host 'PASS: XML File/Server/Repository, preview, selected extensions, binary resources, Git, no EDT dependency, resume and EDT-to-XML snapshot reuse.'
