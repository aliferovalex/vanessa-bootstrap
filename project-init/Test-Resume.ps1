#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot,[string[]]$Scenarios=@('checkpoint','legacy','failed-export','failed-extensions','selection','none','repository','fresh'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$TestRoot=[IO.Path]::GetFullPath($TestRoot);[void][IO.Directory]::CreateDirectory($TestRoot)
$code=@'
using System;using System.IO;using System.Linq;using System.Reflection;using System.Runtime.InteropServices;using System.Text.RegularExpressions;
[assembly:AssemblyFileVersion("8.3.27.1936")]
class Tool {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectoryW(string p,IntPtr s);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string p,uint a,uint s,IntPtr x,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteFile(IntPtr h,byte[] b,uint n,out uint written,IntPtr o);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 static string V(string[] a,string k){int i=Array.IndexOf(a,k);return i<0?null:a[i+1];}
 static void LongFile(string root){
  string name=new string('\u042F',80);
  string directory=Path.Combine(root,"src","CommonForms",name);
  CreateDirectoryW("\\\\?\\"+Path.Combine(root,"src","CommonForms"),IntPtr.Zero);
  if(!CreateDirectoryW("\\\\?\\"+directory,IntPtr.Zero) && Marshal.GetLastWin32Error()!=183)throw new Exception("CreateDirectory");
  var h=CreateFileW("\\\\?\\"+Path.Combine(directory,name+".mdo"),0x40000000,3,IntPtr.Zero,2,0x80,IntPtr.Zero);
  if(h==new IntPtr(-1))throw new Exception("CreateFile");
  try{byte[] data=System.Text.Encoding.UTF8.GetBytes("<LongFixture/>\r\n");uint written;if(!WriteFile(h,data,(uint)data.Length,out written,IntPtr.Zero))throw new Exception("WriteFile");}finally{CloseHandle(h);}
 }
 static void Xml(string dir){Directory.CreateDirectory(dir);File.WriteAllText(Path.Combine(dir,"Configuration.xml"),"<MetaDataObject xmlns=\"http://v8.1c.ru/8.3/MDClasses\" version=\"2.20\"><Configuration><InternalInfo/><Properties><Name>Ext</Name></Properties></Configuration></MetaDataObject>");}
 static int Main(string[] a){
  string stage;
  if(a[0]=="CREATEINFOBASE"){var m=Regex.Match(string.Join(" ",a.Skip(1)),"File=\"?(.+?)\"?;");Directory.CreateDirectory(m.Groups[1].Value);return 0;}
  if(a[0]=="DESIGNER"){
   if(a.Contains("/ConfigurationRepositoryDumpCfg")){File.WriteAllText(V(a,"/ConfigurationRepositoryDumpCfg"),"CF");File.AppendAllText(Environment.GetEnvironmentVariable("INIT_RESUME_TRACE"),"snapshot\n");return 0;}
   if(a.Contains("/LoadCfg") || a.Contains("/LoadConfigFromFiles"))return 0;
   stage=a.Contains("-AllExtensions")?"dump-extensions":"dump-main";
   string d=V(a,"/DumpConfigToFiles");if(a.Contains("-AllExtensions"))Xml(Path.Combine(d,"Ext"));else Xml(d);
   File.WriteAllText(V(a,"/Out"),"done");
  }else if(a.Contains("help")){Console.WriteLine("import --configuration-files --project-name --base-project-name --version");return 0;}
  else if(a.Contains("import")){
   string name=V(a,"--project-name")??Path.GetFileName(V(a,"--project"));stage="edt-import-"+name;
   if(!a.Contains("--configuration-files")){
    Directory.CreateDirectory(V(a,"-data"));File.WriteAllText(Path.Combine(V(a,"-data"),"registered-base"),name);
    File.AppendAllText(Environment.GetEnvironmentVariable("INIT_RESUME_TRACE"),"register-base\n");return 0;
   }
   string root=V(a,"--project")??Path.Combine(V(a,"-data"),name);Directory.CreateDirectory(Path.Combine(root,"src"));
   File.WriteAllText(Path.Combine(root,".project"),"<projectDescription><name>"+name+"</name></projectDescription>");LongFile(root);
  }else return 9;
  File.AppendAllText(Environment.GetEnvironmentVariable("INIT_RESUME_TRACE"),stage+"\n");
  return Environment.GetEnvironmentVariable("INIT_RESUME_FAIL")==stage?7:0;
 }
}
'@
# C# source contains a Unicode escape rather than depending on console encoding.
$source=Join-Path $TestRoot 'tool.cs';[IO.File]::WriteAllText($source,$code,[Text.UTF8Encoding]::new($false))
$exe=Join-Path $TestRoot 'tool.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe ("/out:"+$exe) $source
if($LASTEXITCODE){throw 'Cannot compile fixture'}
$initializer=Join-Path $PSScriptRoot 'Initialize-Project.ps1'
function Assert($v,$m){if(-not $v){throw $m}}
$env:INIT_RESUME_SELECTION=$null
function Read-Host([string]$Prompt) {
 if($Prompt -like 'Select extension numbers*' -and $null -ne $env:INIT_RESUME_SELECTION){$value=$env:INIT_RESUME_SELECTION;$env:INIT_RESUME_SELECTION=$null;return $value}
 throw 'Unexpected resume prompt'
}
$previousSelection=$env:INIT_RESUME_SELECTION;$previousTrace=$env:INIT_RESUME_TRACE;$previousFail=$env:INIT_RESUME_FAIL
try{
 foreach($scenario in $Scenarios){
  $root=Join-Path $TestRoot $scenario;[void][IO.Directory]::CreateDirectory($root)
  $base=Join-Path $root 'base';[void][IO.Directory]::CreateDirectory($base);[IO.File]::WriteAllBytes((Join-Path $base '1Cv8.1CD'),[byte[]]@())
  $target=Join-Path $root 'project';$trace=Join-Path $root 'trace.txt';$env:INIT_RESUME_TRACE=$trace
  $env:INIT_RESUME_FAIL=switch($scenario){'failed-export'{'dump-main'} 'failed-extensions'{'dump-extensions'} 'none'{'edt-import-ResumeDemo'} default{'edt-import-ResumeDemo_Ext'}}
  $secret=ConvertTo-SecureString 'synthetic-resume-secret' -AsPlainText -Force
  $options=@{InfobaseType='File';Infobase=$base;TargetDirectory=$target;DesignerPath=$exe;EdtCliPath=$exe;UserName='Test';Password=$secret;
   ProjectName='ResumeDemo';Extensions=@('Ext');NoGitLfs=$true;NonInteractive=$true;GitBranch='main';GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=120}
  if($scenario -in @('selection','none')){$options.Remove('Extensions');$options.SelectExtensions=$true;$env:INIT_RESUME_SELECTION=if($scenario -eq 'none'){'0'}else{'1'}}
  if($scenario -eq 'repository'){
   $options.InfobaseType='Repository';$options.Infobase='http://example.invalid/repo/repo.1ccr/Main';$options.Remove('UserName');$options.Remove('Password')
   $options.RepositoryUserName='Test';$options.RepositoryPassword=$secret
   $options.ExtensionRepositoryFile=Join-Path $root 'repositories.json'
   [IO.File]::WriteAllText($options.ExtensionRepositoryFile,'[{"name":"Ext","url":"http://example.invalid/repo/repo.1ccr/Ext","version":2}]')
  }
  if($scenario -eq 'fresh'){
   [void][IO.Directory]::CreateDirectory($target);[IO.File]::WriteAllText((Join-Path $target 'README.md'),'Synthetic template')
   & git init --initial-branch=main $target|Out-Null
   & git -C $target -c core.safecrlf=false add README.md
   & git -C $target -c user.name=Test -c user.email=test@example.invalid commit -m Template|Out-Null
   if($LASTEXITCODE){throw 'Cannot create template fixture'}
   $options.TemplateDirectory=$target;$options.FreshHistory=$true
  }
  $failed=$false;try{& $initializer @options}catch{$failed=$_.Exception.Message -like '*failed (exit 7)*';if(-not $failed){throw}}
  Assert ($failed -and -not(Test-Path (Join-Path $target 'project-init.json'))) 'Failed run published sources'
  $old=Get-ChildItem -LiteralPath $root -Directory -Filter '.project-init-*'|Select-Object -First 1
  $state=Join-Path $old.FullName 'initialization.json'
  Assert (-not [IO.File]::ReadAllText($state).Contains('synthetic-resume-secret')) 'Password persisted'
  $originalState=[IO.File]::ReadAllText($state)
  $active=$originalState|ConvertFrom-Json;$active.status='running'
  [IO.File]::WriteAllText($state,($active|ConvertTo-Json -Depth 10))
  $rejected=$false;try{& $initializer -ResumeFrom $old.FullName -NonInteractive}catch{$rejected=$_.Exception.Message -like '*still running*'}
  Assert $rejected 'Active run accepted for resume'
  [IO.File]::WriteAllText($state,$originalState)
  $rejected=$false;try{& $initializer -ResumeFrom $old.FullName -Infobase 'different-source' -NonInteractive}catch{$rejected=$_.Exception.Message -like '*Resume source setting differs*'}
  Assert $rejected 'Changed source accepted for resume'
  if($scenario -eq 'legacy'){[IO.File]::Delete($state)}
  if($scenario -eq 'fresh'){[IO.File]::WriteAllText((Join-Path $target '.git/project-initialization.lock'),'abandoned fixture lock')}
  $env:INIT_RESUME_FAIL=''
  $resumeOptions=@{ResumeFrom=$old.FullName;NonInteractive=$true;NoGitLfs=$true;EdtMaxHeap='12g'}
  if($scenario -eq 'legacy'){$resumeOptions.TargetDirectory=$target;$resumeOptions.GitUserName='Test';$resumeOptions.GitUserEmail='test@example.invalid'}
  if($scenario -in @('failed-export','failed-extensions')){$resumeOptions.Password=$secret}
  & $initializer @resumeOptions
  $lines=@([IO.File]::ReadAllLines($trace))
  $heapLaunch=Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'edt-import-ResumeDemo_Ext.launch.json'|Where-Object {$_.FullName -notlike ($old.FullName+'*')}|Select-Object -First 1
  if($heapLaunch){$launch=[IO.File]::ReadAllText($heapLaunch.FullName)|ConvertFrom-Json;Assert ('-Xmx12g' -in $launch.arguments) 'Heap argument lost';Assert ([Array]::IndexOf($launch.arguments,'-vmargs') -lt [Array]::IndexOf($launch.arguments,'-command')) 'VM arguments after command'}
  if($scenario -in @('checkpoint','legacy','selection','repository','fresh')){
   Assert (@($lines|Where-Object {$_ -eq 'register-base'}).Count -eq 1) 'Recovery did not register the completed base'
   Assert ($launch.arguments[[Array]::IndexOf($launch.arguments,'-data')+1] -ne (Join-Path $old.FullName 'edt-workspace')) 'Failed workspace was reused'
  }
  if($scenario -eq 'repository'){Assert (@($lines|Where-Object {$_ -eq 'snapshot'}).Count -eq 2) 'Repository snapshots repeated during resume'}
  Assert (@($lines|Where-Object {$_ -eq 'dump-main'}).Count -eq $(if($scenario -in @('failed-export','failed-extensions')){2}else{1})) 'Incorrect export reuse'
  Assert (@($lines|Where-Object {$_ -eq 'dump-extensions'}).Count -eq $(if($scenario -eq 'failed-extensions'){2}else{1})) 'Extension export repeated'
  Assert (@($lines|Where-Object {$_ -eq 'edt-import-ResumeDemo'}).Count -eq $(if($scenario -eq 'none'){2}else{1})) 'Completed EDT import repeated'
  Assert (@($lines|Where-Object {$_ -eq 'edt-import-ResumeDemo_Ext'}).Count -eq $(if($scenario -eq 'none'){0}elseif($scenario -in @('failed-export','failed-extensions')){1}else{2})) 'Failed EDT import was not retried'
  $longName=([string][char]0x042F)*80
  $relative='src/cf/src/CommonForms/'+$longName+'/'+$longName+'.mdo'
  $contents=& git -C $target show ('HEAD:'+$relative)
  Assert ($LASTEXITCODE -eq 0 -and ($contents -join '') -eq '<LongFixture/>') 'Long path lost in committed Git'
  Assert (-not((& git -C $target status --porcelain) -join '')) 'Published working tree is dirty'
  if($scenario -eq 'fresh'){Assert ((& git -C $target rev-list --count HEAD) -eq '1') 'Fresh history publication retained template history'}
  $latest=Get-ChildItem -LiteralPath $root -Directory -Filter '.project-init-*'|Where-Object {$_.FullName -ne $old.FullName}|Select-Object -First 1
  $final=[IO.File]::ReadAllText((Join-Path $latest.FullName 'initialization.json'))|ConvertFrom-Json
  Assert ($final.status -eq 'published' -and @($final.selectedExtensions).Count -eq $(if($scenario -eq 'none'){0}else{1})) 'Final checkpoint incomplete'
  $rejected=$false;try{& $initializer -ResumeFrom $latest.FullName -NonInteractive}catch{$rejected=$_.Exception.Message -like '*publication already started*'}
  Assert $rejected 'Published run replayed'
 }
}finally{$env:INIT_RESUME_SELECTION=$previousSelection;$env:INIT_RESUME_TRACE=$previousTrace;$env:INIT_RESUME_FAIL=$previousFail}
Write-Host 'PASS: long paths, checkpoints, legacy receipts, no duplicate successful exports/imports, failed-stage retry, selected extensions, no password persistence, no publication replay.'
