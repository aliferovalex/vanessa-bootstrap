#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[void][IO.Directory]::CreateDirectory($TestRoot)
$code=@'
using System;using System.IO;using System.Linq;using System.Text.RegularExpressions;using System.Reflection;
[assembly:AssemblyFileVersion("8.5.1.1529")]
class Tool {
 static string V(string[] a,string k){int i=Array.IndexOf(a,k);return i<0?null:a[i+1];}
 static void Xml(string dir,string name){Directory.CreateDirectory(dir);File.WriteAllText(Path.Combine(dir,"Configuration.xml"),"<MetaDataObject xmlns=\"http://v8.1c.ru/8.3/MDClasses\" version=\"2.20\"><Configuration uuid=\"00000000-0000-0000-0000-000000000001\"><InternalInfo/><Properties><Name>"+name+"</Name></Properties></Configuration></MetaDataObject>");}
 static int Main(string[] a){
  string trace=Environment.GetEnvironmentVariable("PROJECT_TEST_TRACE");if(trace!=null)File.AppendAllText(trace,string.Join("|",a)+"\n");
  if(Environment.GetEnvironmentVariable("PROJECT_TEST_FAIL")=="1")return 7;
  if(a[0]=="CREATEINFOBASE"){string p=string.Join(" ",a.Skip(1));var m=Regex.Match(p,"File=\"?(.+?)\"?;");Directory.CreateDirectory(m.Groups[1].Value);return 0;}
  if(a[0]=="DESIGNER"){
   string b=V(a,"/F");Directory.CreateDirectory(b);string ext=V(a,"-Extension");
   if(a.Contains("/ConfigurationRepositoryDumpCfg")){File.WriteAllText(V(a,"/ConfigurationRepositoryDumpCfg"),"CF");return 0;}
   if(a.Contains("/LoadConfigFromFiles")){if(ext!=null)File.WriteAllText(Path.Combine(b,ext+".extension"),ext);return 0;}
   if(a.Contains("/LoadCfg"))return 0;
   if(a.Contains("/DumpCfg")){File.WriteAllText(V(a,"/DumpCfg"),"Artifact");return 0;}
   if(a.Contains("/DumpConfigToFiles")){string d=V(a,"/DumpConfigToFiles");if(a.Contains("-AllExtensions")){foreach(string f in Directory.GetFiles(b,"*.extension"))Xml(Path.Combine(d,Path.GetFileNameWithoutExtension(f)),Path.GetFileNameWithoutExtension(f));}else Xml(d,"Main");File.WriteAllText(V(a,"/Out"),"Export complete");return 0;}
  }
  if(a.Contains("help")){Console.WriteLine("import --configuration-files --project-name --base-project-name --version");return 0;}
  if(a.Contains("import")){string d=Path.Combine(V(a,"-data"),V(a,"--project-name"));Directory.CreateDirectory(Path.Combine(d,"src"));File.WriteAllText(Path.Combine(d,".project"),"<projectDescription><name>"+V(a,"--project-name")+"</name></projectDescription>");File.WriteAllText(Path.Combine(d,"src/Configuration.mdo"),"<Configuration/>");return 0;}
  if(a.Contains("-file")){foreach(string line in File.ReadAllLines(V(a,"-file"))){if(line.StartsWith("export ")){var m=Regex.Match(line,"--configuration-files \"(.+)\"");Xml(m.Groups[1].Value,"Main");}}return 0;}
  // The runner double accepts only the commands used by the template.
  if(new[]{"init-dev","update-dev","compileext","run"}.Contains(a[0]))return 0;
  return 9;
 }
}
'@
$source=Join-Path $TestRoot 'tool.cs';[IO.File]::WriteAllText($source,$code,[Text.UTF8Encoding]::new($false))
$exe=Join-Path $TestRoot 'tool.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe ("/out:"+$exe) $source
if ($LASTEXITCODE) { throw 'Cannot compile test double.' }
$extensions=Join-Path $TestRoot 'repositories.json'
'[{"name":"Extra","url":"http://example.invalid/repo/repo.1ccr/Extra","version":4}]' | Set-Content -LiteralPath $extensions -Encoding UTF8
$trace=Join-Path $TestRoot 'trace.txt';$env:PROJECT_TEST_TRACE=$trace
$target=Join-Path $TestRoot 'project'
$template=Split-Path $PSScriptRoot -Parent
$common=@{InfobaseType='Repository';Infobase='http://example.invalid/repo/repo.1ccr/Main';RepositoryVersion=12;ExtensionRepositoryFile=$extensions;RepositoryUserName='reader';RepositoryPassword=(ConvertTo-SecureString 'secret-test' -AsPlainText -Force);DesignerPath=$exe;EdtCliPath=$exe;TemplateDirectory=$template;ProjectName='Demo';TargetDirectory=$target;GitUserName='Test';GitUserEmail='test@example.invalid';TimeoutSeconds=30}
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
 & (Join-Path $PSScriptRoot 'Initialize-Project.ps1') @common
 $manifest=Get-Content -Raw -LiteralPath (Join-Path $target 'project-init.json') | ConvertFrom-Json
 Assert ($manifest.initializationSource.requestedVersion -eq 12) 'Main repository version missing'
 Assert (-not $manifest.initializationSource.baselineVerified) 'Unverified baseline claimed'
 Assert ($manifest.extensions[0].name -eq 'Extra') 'Repository extension missing'
 Assert (-not ((Get-Content -Raw -LiteralPath (Join-Path $target 'project-init.json')).Contains('secret-test'))) 'Password leaked to manifest'
 $result=& (Join-Path $template 'tools/Run-Project.ps1') -ProjectDirectory $target -DesignerPath $exe -EdtCliPath $exe -TimeoutSeconds 30
 Assert ($result.artifacts.Count -eq 2) 'CF/CFE artifacts missing'
 Assert ((Get-Content -Raw -LiteralPath $trace).Contains('/ConfigurationRepositoryDumpCfg')) 'Repository not read'
 Assert (-not ((Get-Content -Raw -LiteralPath $trace) -match '/ConfigurationRepository(Bind|Commit|Capture)')) 'Repository write attempted'
 $result=& (Join-Path $template 'tools/Run-Project.ps1') -Action Prepare -ProjectDirectory $target -DesignerPath $exe -EdtCliPath $exe -Runner $exe -TimeoutSeconds 30
 Assert ((Get-Content -Raw -LiteralPath $trace).Contains('compileext|')) 'Runner did not receive extension XML'
 Assert (-not (& git -C $target status --porcelain)) 'Build changed source files'
 $env:PROJECT_TEST_FAIL='1';$failed=$false
 try { & (Join-Path $template 'tools/Run-Project.ps1') -ProjectDirectory $target -DesignerPath $exe -EdtCliPath $exe -TimeoutSeconds 30 } catch {$failed=$true}
 Assert $failed 'EDT failure was ignored'
 Write-Host 'PASS: repository snapshots, extension context, manifest, CF/CFE build, runner integration and failed export.'
} finally { Remove-Item Env:PROJECT_TEST_TRACE -ErrorAction SilentlyContinue;Remove-Item Env:PROJECT_TEST_FAIL -ErrorAction SilentlyContinue }
