#requires -Version 5.1
<#
.SYNOPSIS
Registers an EDT workspace in EDT Start 0.8 (projects.json schema 1.1).
.DESCRIPTION
Optionally imports existing Git projects into a new permanent workspace first.
EDT Start must be stopped, or RestartEdtStart must be explicitly selected.
Only the launcher is restarted; EDT processes are not stopped.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkspacePath,
    [Parameter(Mandatory=$true)][string]$EdtExecutablePath,
    [string]$DisplayName,
    [string]$RepositoryPath,
    [string]$EdtCliPath,
    [string]$EdtIniFile,
    [ValidatePattern('^[1-9][0-9]*[mMgG]$')][string]$EdtMaxHeap,
    [string]$EdtStartHome = (Join-Path $env:LOCALAPPDATA '1C\1cedtstart'),
    [switch]$RestartEdtStart,
    [switch]$Preview,
    [ValidateRange(30,86400)][int]$TimeoutSeconds = 1800
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
function FullPath([string]$path){ [IO.Path]::GetFullPath($path).TrimEnd('\','/') }
function Quote([string]$text){
    if($text.Length -gt 0 -and $text -notmatch '[\s"]'){return $text}
    '"'+[regex]::Replace([regex]::Replace($text,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Get-Launchers {
    @(Get-Process -Name '1cedtstart' -ErrorAction SilentlyContinue)
}
$WorkspacePath=FullPath $WorkspacePath
$EdtExecutablePath=(Get-Item -LiteralPath $EdtExecutablePath).FullName
$registry=Join-Path $EdtStartHome 'projects.json'
$products=[IO.File]::ReadAllText((Join-Path $EdtStartHome 'products.json')) | ConvertFrom-Json
$types=[IO.File]::ReadAllText((Join-Path $EdtStartHome 'project-types.json')) | ConvertFrom-Json
$initial=[IO.File]::ReadAllText($registry)
$projects=$initial | ConvertFrom-Json
if($projects.version -ne '1.1'){throw 'Unsupported EDT Start projects.json schema; no changes made.'}
$product=@($products.data | Where-Object {(FullPath $_.location) -eq (FullPath $EdtExecutablePath)})
if($product.Count -ne 1){throw 'EDT executable must match exactly one registered EDT Start product.'}
$product=$product[0]
$type=@($types.data | Where-Object {$_.installedProducts -contains $product.id})
if($type.Count -ne 1){throw 'Cannot choose a unique EDT Start project type for this product.'}
$type=$type[0]
$manifest=$null
if($RepositoryPath){
    $RepositoryPath=(Get-Item -LiteralPath $RepositoryPath).FullName
    $manifest=[IO.File]::ReadAllText((Join-Path $RepositoryPath 'project-init.json')) | ConvertFrom-Json
    if(-not $DisplayName){$DisplayName=$manifest.configuration.projectName}
    $projectPaths=@($manifest.configuration.path)+@($manifest.extensions | ForEach-Object {$_.path})
    foreach($relative in $projectPaths){
        $path=FullPath (Join-Path $RepositoryPath $relative)
        if(-not $path.StartsWith((FullPath $RepositoryPath)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Project path escapes repository.'}
        if(-not(Test-Path -LiteralPath (Join-Path $path '.project'))){throw "Missing EDT project: $path"}
    }
    if(-not $EdtCliPath){$EdtCliPath=Join-Path (Split-Path $EdtExecutablePath -Parent) '1cedtcli.exe'}
    $EdtCliPath=(Get-Item -LiteralPath $EdtCliPath).FullName
}
if(-not $DisplayName){$DisplayName=Split-Path $WorkspacePath -Leaf}
foreach($value in @($WorkspacePath,$RepositoryPath,$DisplayName)){
    if($value -match '[\r\n"]'){throw 'Quotes and line breaks are not supported in workspace parameters.'}
}
$existing=@($projects.data | Where-Object {(FullPath $_.location) -eq $WorkspacePath})
if($existing.Count -gt 1){throw 'Registry has duplicate workspace locations.'}
if($existing.Count -eq 1 -and $existing[0].productId -ne $product.id){throw 'Workspace is registered with a different EDT version.'}
if($Preview){
    [PSCustomObject]@{Workspace=$WorkspacePath;Label=$DisplayName;ProductId=$product.id;Registry=$registry;AlreadyRegistered=($existing.Count -eq 1);Repository=$RepositoryPath}
    return
}
if($existing.Count -eq 0 -and @(Get-Launchers).Count -gt 0 -and -not $RestartEdtStart){throw 'EDT Start is running. Close it or specify -RestartEdtStart; active settings will not be overwritten.'}
$marker=Join-Path $WorkspacePath '.project-init-workspace.json'
if($RepositoryPath){
    if(Test-Path -LiteralPath $marker){
        $saved=[IO.File]::ReadAllText($marker) | ConvertFrom-Json
        if((FullPath $saved.repository) -ne (FullPath $RepositoryPath)){throw 'Workspace belongs to a different repository.'}
        foreach($relative in $projectPaths){
            [xml]$description=[IO.File]::ReadAllText((Join-Path (Join-Path $RepositoryPath $relative) '.project'))
            $resource=Join-Path $WorkspacePath ('.metadata\.plugins\org.eclipse.core.resources\.projects\'+$description.projectDescription.name+'\.location')
            if(-not(Test-Path -LiteralPath $resource)){throw "Workspace project is missing: $($description.projectDescription.name)"}
            $location=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($resource))
            $uriMatch=[regex]::Match($location,'URI//(file:[^\x00]+)')
            if(-not $uriMatch.Success -or (FullPath ([uri]$uriMatch.Groups[1].Value).LocalPath) -ne (FullPath (Join-Path $RepositoryPath $relative))){throw "Workspace project points to a different location: $($description.projectDescription.name)"}
        }
    } else {
        if((Test-Path -LiteralPath $WorkspacePath) -and @(Get-ChildItem -LiteralPath $WorkspacePath -Force).Count -gt 0){throw 'Choose a new or empty workspace directory.'}
        [void][IO.Directory]::CreateDirectory($WorkspacePath)
        $commands=@($projectPaths | ForEach-Object {'import --project "'+(Join-Path $RepositoryPath $_).Replace('\','/')+'"'})
        $commandFile=Join-Path $WorkspacePath 'import-projects.1cedtcli'
        [IO.File]::WriteAllText($commandFile,($commands -join "`n"),$utf8)
        $argsList=@('-data',$WorkspacePath,'-timeout',"$TimeoutSeconds",'-file',$commandFile)
        if($EdtMaxHeap){$argsList+=@('-vmargs',('-Xmx'+$EdtMaxHeap))}
        if($EdtIniFile){$argsList=@('-ini-file',(Get-Item -LiteralPath $EdtIniFile).FullName)+$argsList}
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$EdtCliPath
        $info.Arguments=($argsList | ForEach-Object {Quote $_}) -join ' '
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $proc=New-Object Diagnostics.Process;$proc.StartInfo=$info
        Write-Host 'Importing existing Git projects into permanent EDT workspace...'
        try {
            [void]$proc.Start();$out=$proc.StandardOutput.ReadToEndAsync();$err=$proc.StandardError.ReadToEndAsync()
            if(-not $proc.WaitForExit($TimeoutSeconds*1000)){
                if($PSVersionTable.PSVersion.Major -ge 7){$proc.Kill($true)}else{& (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $proc.Id /T /F | Out-Null}
                throw 'Workspace import timed out.'
            }
            [IO.File]::WriteAllText((Join-Path $WorkspacePath 'import.stdout.log'),$out.GetAwaiter().GetResult(),$utf8)
            [IO.File]::WriteAllText((Join-Path $WorkspacePath 'import.stderr.log'),$err.GetAwaiter().GetResult(),$utf8)
            if($proc.ExitCode -ne 0){throw "Workspace import failed (exit $($proc.ExitCode)); see logs in $WorkspacePath"}
        } finally {$proc.Dispose()}
        foreach($relative in $projectPaths){
            [xml]$description=[IO.File]::ReadAllText((Join-Path (Join-Path $RepositoryPath $relative) '.project'))
            $resource=Join-Path $WorkspacePath ('.metadata\.plugins\org.eclipse.core.resources\.projects\'+$description.projectDescription.name+'\.location')
            if(-not(Test-Path -LiteralPath $resource)){throw "EDT did not register project $($description.projectDescription.name)"}
        }
        [IO.File]::WriteAllText($marker,(@{repository=$RepositoryPath;projects=@($projectPaths)} | ConvertTo-Json -Depth 5),$utf8)
    }
}
if(-not(Test-Path -LiteralPath (Join-Path $WorkspacePath '.metadata') -PathType Container)){throw 'Workspace must contain .metadata.'}
if($existing.Count -eq 1){Write-Host "Already registered: $WorkspacePath";return}
$restartPaths=@()
try {
    foreach($launcher in Get-Launchers){
        if(-not $RestartEdtStart){throw 'EDT Start was started during workspace preparation. Close it or retry with -RestartEdtStart.'}
        $restartPaths+= $launcher.Path
        Stop-Process -Id $launcher.Id -ErrorAction Stop
        $launcher.WaitForExit()
    }
    # Re-read after stopping the launcher, preserving all records and unknown fields.
    $text=[IO.File]::ReadAllText($registry)
    $projects=$text | ConvertFrom-Json
    if($projects.version -ne '1.1'){throw 'Registry schema changed during workspace preparation.'}
    if(@($projects.data | Where-Object {(FullPath $_.location) -eq $WorkspacePath}).Count){Write-Host 'Workspace was registered concurrently.';return}
    $entry=[ordered]@{id=[guid]::NewGuid().ToString();label=$DisplayName;location=$WorkspacePath;productId=$product.id;projectTypeId=$type.id}
    $template=@($projects.data | Where-Object {$_.productId -eq $product.id -and $_.PSObject.Properties.Name -contains 'jvmPath'}) | Select-Object -First 1
    if($template){$entry['jvmPath']=$template.jvmPath}
    $projects.data=@($projects.data)+[PSCustomObject]$entry
    $newText=$projects | ConvertTo-Json -Depth 50
    $temp=$registry+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$registry+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.'+[guid]::NewGuid().ToString('N')+'.bak'
    [IO.File]::WriteAllText($temp,$newText,$utf8)
    if([IO.File]::ReadAllText($registry) -cne $text){throw 'Registry changed concurrently; no replacement performed.'}
    [IO.File]::Replace($temp,$registry,$backup)
    Write-Host "Registered: $DisplayName ($WorkspacePath)"
    Write-Host "Registry backup: $backup"
} finally {
    foreach($exe in @($restartPaths | Select-Object -Unique)){Start-Process -FilePath $exe -WindowStyle Hidden | Out-Null}
}
