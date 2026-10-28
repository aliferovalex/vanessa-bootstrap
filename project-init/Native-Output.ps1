#requires -Version 5.1
function Initialize-NativeOutputCapture {
    if('ProjectInitializer.OutputCapture' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
namespace ProjectInitializer {
 public sealed class OutputCapture : IDisposable {
  readonly Task output,error;
  readonly Process process;
  volatile bool stopping;
  public OutputCapture(Process p,string stdout,string stderr,string[] secrets){
   process=p;
   string[] redact=secrets.Where(s=>!String.IsNullOrEmpty(s)).OrderByDescending(s=>s.Length).ToArray();
   output=Task.Factory.StartNew(()=>Pump(p.StandardOutput,stdout,redact),TaskCreationOptions.LongRunning);
   error=Task.Factory.StartNew(()=>Pump(p.StandardError,stderr,redact),TaskCreationOptions.LongRunning);
  }
  void Pump(StreamReader reader,string path,string[] secrets){
   int keep=secrets.Length==0?0:secrets.Max(s=>s.Length)-1;
   bool lineSafe=secrets.All(s=>s.IndexOfAny(new[]{'\r','\n'})<0);
   string pending="";char[] buffer=new char[4096];
   using(var writer=new StreamWriter(new FileStream(path,FileMode.Create,FileAccess.Write,FileShare.ReadWrite),new UTF8Encoding(false))){
    writer.AutoFlush=true;
    try{
     for(;;){
      int n=reader.Read(buffer,0,buffer.Length);
      if(n==0)break;
      pending+=new string(buffer,0,n);
      int cut=Math.Max(0,pending.Length-keep);
      int previous;
      do{previous=cut;foreach(string secret in secrets){
       int start=pending.IndexOf(secret,StringComparison.Ordinal);
       while(start>=0 && start<cut){if(start+secret.Length>cut){cut=start;break;}start=pending.IndexOf(secret,start+1,StringComparison.Ordinal);}
      }}while(previous!=cut);
      if(lineSafe)cut=Math.Max(cut,pending.LastIndexOf('\n')+1);
      if(cut>0){writer.Write(Redact(pending.Substring(0,cut),secrets));pending=pending.Substring(cut);}
     }
    }catch(IOException){if(!stopping)throw;}
     catch(ObjectDisposedException){if(!stopping)throw;}
    finally{writer.Write(Redact(pending,secrets));}
   }
  }
  static string Redact(string value,string[] secrets){foreach(string s in secrets)value=value.Replace(s,"[REDACTED]");return value;}
  public bool Complete(int milliseconds){return Task.WaitAll(new[]{output,error},milliseconds);}
  public void Dispose(){
   stopping=true;
   if(!output.IsCompleted){try{process.StandardOutput.BaseStream.Close();}catch{}}
   if(!error.IsCompleted){try{process.StandardError.BaseStream.Close();}catch{}}
   try{Complete(5000);}catch{}
  }
 }
}
'@
}
function Stop-InitializationProcess([Diagnostics.Process]$Process){
    if($Process.HasExited){return}
    if($PSVersionTable.PSVersion.Major -ge 7){$Process.Kill($true)}else{
        $killer=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') -ArgumentList @('/PID',"$($Process.Id)",'/T','/F') -WindowStyle Hidden -PassThru -Wait
        if($killer.ExitCode -ne 0 -and -not $Process.HasExited){$Process.Kill()}
    }
    if(-not $Process.WaitForExit(30000)){throw 'Unable to stop the owned native process.'}
}
function Read-InitializationEdtLog([string]$Path,[ref]$Position){
    if(-not $Path -or -not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
    $stream=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if($Position.Value -gt $stream.Length){$Position.Value=0L}
        [void]$stream.Seek($Position.Value,[IO.SeekOrigin]::Begin)
        $buffer=New-Object byte[] 1048576
        $count=$stream.Read($buffer,0,$buffer.Length);$Position.Value+=$count
        return [Text.Encoding]::UTF8.GetString($buffer,0,$count)
    }catch [IO.IOException]{return ''}finally{if($stream){$stream.Dispose()}}
}
