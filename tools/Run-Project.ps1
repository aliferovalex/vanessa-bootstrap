#requires -Version 5.1
[CmdletBinding()]param(
    [ValidateSet('Build','Prepare','Update')][string]$Action='Build',
    [string]$ProjectDirectory=(Split-Path $PSScriptRoot -Parent),
    [string]$EdtCliPath=$env:ONEC_EDT_CLI,
    [string]$EdtIniFile=$env:ONEC_EDT_INI,
    [string]$DesignerPath=$env:ONEC_DESIGNER,
    [string]$Runner='vrunner',
    [string[]]$RunnerArguments=@(),
    [ValidateRange(30,86400)][int]$TimeoutSeconds=1800
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'project-init/Native-Tools.ps1')
if (-not $DesignerPath) { throw 'Specify DesignerPath or ONEC_DESIGNER.' }
$DesignerPath=(Get-Command $DesignerPath -CommandType Application -ErrorAction Stop).Source
$ProjectDirectory=(Get-Item -LiteralPath $ProjectDirectory).FullName
$manifest=Get-Content -Raw -LiteralPath (Join-Path $ProjectDirectory 'project-init.json') | ConvertFrom-Json
if ((Get-Item -LiteralPath $DesignerPath).VersionInfo.FileVersion -ne $manifest.platformVersion) { throw 'Designer version differs from the project platform version.' }
$export=& (Join-Path $PSScriptRoot 'Export-Edt.ps1') -ProjectDirectory $ProjectDirectory -EdtCliPath $EdtCliPath -EdtIniFile $EdtIniFile -TimeoutSeconds $TimeoutSeconds
$work=$export.directory;$main=$export.projects[0];$base=Join-Path $work 'build-base'
$artifacts=Join-Path $work 'artifacts';[void][IO.Directory]::CreateDirectory($artifacts)
function Designer([string]$Label,[string[]]$Arguments) {
    Invoke-ProjectNative -Executable $DesignerPath -Arguments (@('DESIGNER','/F',$base,'/DisableStartupDialogs','/DisableStartupMessages')+$Arguments+@('/Out',(Join-Path $work ($Label+'.designer.log')))) -Directory $work -Label $Label -TimeoutSeconds $TimeoutSeconds
}
Invoke-ProjectNative -Executable $DesignerPath -CreateFile $base -Arguments @('/DisableStartupDialogs','/DisableStartupMessages','/Out',(Join-Path $work 'create.designer.log')) -Directory $work -Label 'create' -TimeoutSeconds $TimeoutSeconds
Designer 'load-main' @('/LoadConfigFromFiles',$main.xml)
$files=@()
foreach ($project in $export.projects) {
    $extension=@()
    if ($project.component -ne 'configuration') { $extension=@('-Extension',$project.name) }
    if ($extension.Count) {
        $placeholder=Join-Path $work ('placeholder-'+$project.projectName)
        New-ExtensionPlaceholder (Join-Path $main.xml 'Configuration.xml') $placeholder $project.name
        Designer ($project.projectName+'-placeholder') (@('/LoadConfigFromFiles',$placeholder)+$extension)
        Designer ($project.projectName+'-load') (@('/LoadConfigFromFiles',$project.xml)+$extension)
    }
    $suffix=if ($extension.Count) { '.cfe' } else { '.cf' }
    $file=Join-Path $artifacts ($project.projectName+$suffix)
    Designer ($project.projectName+'-dump') (@('/DumpCfg',$file)+$extension)
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw 'Configuration artifact was not created.' }
    $files+=$file
}
if ($Action -ne 'Build') {
    if ($RunnerArguments -match '^--(v8version|src|root|workspace|settings)(=|$)') { throw 'Runner arguments cannot override project version or source selection.' }
    # These command names target the 2.6.x runner API used by upstream bootstrap.
    $command=if ($Action -eq 'Prepare') { 'init-dev' } else { 'update-dev' }
    Push-Location $ProjectDirectory
    try {
        & $Runner $command --src $main.xml --v8version $manifest.platformVersion @RunnerArguments
        if ($LASTEXITCODE -ne 0) { throw 'Runner configuration update failed.' }
        foreach ($project in $export.projects | Select-Object -Skip 1) {
            & $Runner compileext $project.xml $project.name --v8version $manifest.platformVersion @RunnerArguments
            if ($LASTEXITCODE -ne 0) { throw 'Runner extension update failed.' }
        }
        & $Runner run --command 'ЗапуститьОбновлениеИнформационнойБазы;ЗавершитьРаботуСистемы;' --execute '$runnerRoot\epf\ЗакрытьПредприятие.epf' --v8version $manifest.platformVersion @RunnerArguments
        if ($LASTEXITCODE -ne 0) { throw 'Enterprise update failed.' }
    } finally { Pop-Location }
}
$result=[pscustomobject]@{action=$Action;directory=$work;platformVersion=$manifest.platformVersion;artifacts=$files}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work 'result.json') -Encoding UTF8
$result
