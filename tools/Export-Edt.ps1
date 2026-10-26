#requires -Version 5.1
[CmdletBinding()]param(
    [string]$ProjectDirectory,
    [string]$EdtCliPath=$env:ONEC_EDT_CLI,
    [string]$EdtIniFile=$env:ONEC_EDT_INI,
    [ValidateRange(30,86400)][int]$TimeoutSeconds=1800
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if (-not $ProjectDirectory) { $ProjectDirectory=Split-Path $PSScriptRoot -Parent }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'project-init/Native-Tools.ps1')
if (-not $EdtCliPath) { throw 'Specify EdtCliPath or ONEC_EDT_CLI.' }
$EdtCliPath=(Get-Command $EdtCliPath -CommandType Application -ErrorAction Stop).Source
$ProjectDirectory=(Get-Item -LiteralPath $ProjectDirectory).FullName
$manifest=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $ProjectDirectory 'project-init.json') | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.sourceFormat -ne 'EDT' -or $manifest.platformVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Expected an EDT initializer manifest with full platform version.' }
$work=Join-Path $ProjectDirectory ('build/edt-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$commands=@();$projects=@();$names=@{}
function Quote-Edt([string]$Value) {
    if ($Value -match '["\x00\r\n]') { throw 'Unsupported EDT path.' }
    '"'+$Value.Replace('\','/')+'"'
}
foreach ($entry in @($manifest.configuration)+@($manifest.extensions)) {
    if ($entry.projectName -notmatch '^[\p{L}\p{N}_][\p{L}\p{N}_.-]*$' -or $names.ContainsKey($entry.projectName)) { throw 'Invalid or duplicate EDT project name.' }
    $names[$entry.projectName]=$true
    $source=[IO.Path]::GetFullPath((Join-Path $ProjectDirectory $entry.path))
    if (-not $source.StartsWith($ProjectDirectory+'\src\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Component path must stay inside src.' }
    $ancestor=Get-Item -LiteralPath $source
    while ($ancestor.FullName -ne $ProjectDirectory) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Project junctions and symlinks are not supported.' }
        $ancestor=$ancestor.Parent
    }
    [xml]$description=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $source '.project')
    if ($description.projectDescription.name -ne $entry.projectName) { throw 'EDT project name differs from manifest.' }
    $copy=Join-Path $work ('sources/'+$entry.projectName)
    [void][IO.Directory]::CreateDirectory($copy)
    foreach ($file in Get-ChildItem -LiteralPath $source -Force -Recurse) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source symlinks are not supported.' }
    }
    Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $copy -Recurse -Force
    $component=if ($entry -eq $manifest.configuration) { 'configuration' } else { 'extension:'+$entry.name }
    $relative=if ($component -eq 'configuration') { 'xml/cf' } else { 'xml/cfe/'+$entry.projectName }
    $target=Join-Path $work $relative
    $commands+='import --project '+(Quote-Edt $copy)
    $projects+=@{component=$component;projectName=$entry.projectName;xml=$target;name=$(if($component -eq 'configuration'){''}else{$entry.name})}
}
foreach ($project in $projects) { $commands+='export --project-name '+(Quote-Edt $project.projectName)+' --configuration-files '+(Quote-Edt $project.xml) }
$file=Join-Path $work 'commands.txt'
[IO.File]::WriteAllText($file,($commands -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
$arguments=@('-data',(Join-Path $work 'workspace'),'-timeout',[string]$TimeoutSeconds,'-file',$file)
if ($EdtIniFile) { $arguments=@('-ini-file',(Get-Item -LiteralPath $EdtIniFile).FullName)+$arguments }
Invoke-ProjectNative -Executable $EdtCliPath -Arguments $arguments -Directory $work -Label 'edt-export' -TimeoutSeconds $TimeoutSeconds
foreach ($project in $projects) {
    $configuration=Join-Path $project.xml 'Configuration.xml'
    if (-not (Test-Path -LiteralPath $configuration -PathType Leaf) -or (Get-Item -LiteralPath $configuration).Length -eq 0) { throw 'EDT did not produce Configuration.xml.' }
    [xml]$null=Get-Content -Encoding UTF8 -Raw -LiteralPath $configuration
}
[pscustomobject]@{directory=$work;platformVersion=$manifest.platformVersion;projects=$projects}
