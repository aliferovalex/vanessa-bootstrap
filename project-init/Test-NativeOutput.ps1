#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$work=[IO.Path]::GetFullPath($TestRoot);[void][IO.Directory]::CreateDirectory($work)
. (Join-Path $PSScriptRoot 'Native-Output.ps1')
. (Join-Path $PSScriptRoot 'Initialization-State.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Initialize-Project.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Initializer syntax error'}
foreach($name in @('Quote-NativeArgument','Protect-Text','Get-SafeNativeArguments','Write-Text','Run-Native')){
 $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
 . ([scriptblock]::Create($node.Extent.Text))
}
$utf8=[Text.UTF8Encoding]::new($false);$secret="private`nlong-password";$repositorySecret=$null;$TimeoutSeconds=30
$code=@'
using System;using System.IO;using System.Threading;using System.Text;
class Tool {
 static string V(string[] a,string k){int i=Array.IndexOf(a,k);return i<0?null:a[i+1];}
 static int Main(string[] a){
  Console.OutputEncoding=new UTF8Encoding(false);
  string mode=V(a,"--mode");
  if(mode=="live"){
   string secret=V(a,"/P");int cut=secret.Length/2;
   Console.Write("FIRST\n"+secret.Substring(0,cut));Console.Out.Flush();Thread.Sleep(300);
   Console.Write(secret.Substring(cut)+" suffix\n");Console.Out.Flush();
   Console.Error.Write("ERR "+secret);Console.Error.Flush();Thread.Sleep(1500);
   string path=V(a,"--inspect");if(!File.Exists(path))return 13;
   using(var f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))using(var r=new StreamReader(f)){
    string live=r.ReadToEnd();if(!live.Contains("FIRST") || live.Contains(secret))return 14;
   }
   return 0;
  }
  if(mode=="oom"){
   string data=V(a,"-data");Directory.CreateDirectory(Path.Combine(data,".metadata"));
   File.AppendAllText(Path.Combine(data,".metadata/.log"),"java.lang.OutOfMemoryError: Java heap space\n");
   Thread.Sleep(20000);return 7;
  }
  if(mode=="nul"){Console.Write("a\0b\0");return 0;}
  return 0;
 }
}
'@
$source=Join-Path $work 'tool.cs';[IO.File]::WriteAllText($source,$code,$utf8)
$exe=Join-Path $work 'tool.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe ("/out:"+$exe) $source
if($LASTEXITCODE){throw 'Cannot compile fixture'}
function Assert($v,$m){if(-not $v){throw $m}}
[void](Run-Native $exe @('--mode','live','/P',$secret,'--inspect',(Join-Path $work 'live.stdout.log')) live -UnicodeOutput)
foreach($path in @('live.stdout.log','live.stderr.log','live.launch.json')){
 Assert (-not [IO.File]::ReadAllText((Join-Path $work $path)).Contains($secret)) 'Secret leaked across streamed chunks'
}
$value=Run-Native $exe @('--mode','nul') binary-output -UnicodeOutput
Assert ($value -eq "a`0b`0") 'NUL-delimited Git output damaged'
$data=Join-Path $work 'workspace';[void][IO.Directory]::CreateDirectory((Join-Path $data '.metadata'))
[IO.File]::WriteAllText((Join-Path $data '.metadata/.log'),"old java.lang.OutOfMemoryError: Java heap space`n")
[void](Run-Native $exe @('--mode','success','-data',$data) 'edt-old-log' -UnicodeOutput)
$watch=[Diagnostics.Stopwatch]::StartNew();$failed=$false
try{Run-Native $exe @('--mode','oom','-data',$data) 'edt-memory' -UnicodeOutput|Out-Null}catch{$failed=$_.Exception.Message -like '*exhausted Java heap space*'}
Assert ($failed -and $watch.Elapsed.TotalSeconds -lt 15) 'OOM did not fail promptly'
$result=[IO.File]::ReadAllText((Join-Path $work 'edt-memory.result.json'))|ConvertFrom-Json
Assert ($result.memoryExhausted -and -not $result.timedOut) 'OOM confused with timeout'
Assert (-not(Get-Process -Id $result.pid -ErrorAction SilentlyContinue)) 'OOM process left running'
$argsList=@('-data','workspace','-timeout','30','-command','import','--project-name','Demo')
$argsList=@(Add-EdtHeapArguments $argsList '12g')
Assert (($argsList -join '|') -eq '-data|workspace|-timeout|30|-vmargs|-Xmx12g|-command|import|--project-name|Demo') 'JVM arguments misplaced'
Write-Host 'PASS: live output before exit, cross-chunk secret redaction, NUL output, historical OOM ignored, fresh OOM detected and process stopped, JVM argument order.'
