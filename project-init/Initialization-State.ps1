#requires -Version 5.1
# Checkpoints contain settings and exit receipts, never passwords.
function Read-InitJson([string]$Path) {
    if(Test-Path -LiteralPath $Path -PathType Leaf){return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}
    return $null
}
function Get-InitArgument($Arguments,[string]$Name) {
    $index=[Array]::IndexOf([object[]]$Arguments,$Name)
    if($index -ge 0 -and $index+1 -lt $Arguments.Count){return [string]$Arguments[$index+1]}
    return ''
}
function Get-InitSettingNames {
    @('InfobaseType','SourceFormat','Infobase','TargetDirectory','TemplateDirectory','ProjectRemoteUrl','GitBranch','FreshHistory',
      'DesignerPath','EdtCliPath','EdtIniFile','EdtMaxHeap','RegisterEdtStart','RestartEdtStart','EdtWorkspaceDirectory','GitPath',
      'ProjectName','UserName','RepositoryUserName','RepositoryVersion','ExtensionRepositoryFile','Extensions',
      'SelectExtensions','NoExtensions','AskCredential','AskRepositoryCredential','UseOSAuthentication','NoGitLfs',
      'SkipInitialCommit','GitUserName','GitUserEmail','TimeoutSeconds')
}
function Read-InitializationResume([string]$Directory) {
    $Directory=(Get-Item -LiteralPath $Directory).FullName
    $record=Read-InitJson (Join-Path $Directory 'initialization.json')
    $settings=@{};$chain=@();$seen=@{};$next=$Directory
    while($next){
        $next=[IO.Path]::GetFullPath($next)
        if($seen.ContainsKey($next) -or $chain.Count -ge 32){throw 'Invalid initialization checkpoint chain.'}
        $seen[$next]=$true;$chain+=$next
        $item=Read-InitJson (Join-Path $next 'initialization.json')
        if($item -and $item.schemaVersion -ne 1){throw 'Unsupported initialization checkpoint version.'}
        if($item -and $item.PSObject.Properties['previousDirectory']){$next=[string]$item.previousDirectory}else{$next=''}
    }
    if($record){
        if($record.status -in @('publishing','published')){throw 'Project publication already started. Inspect the project and publication journal before resuming.'}
        if($record.status -eq 'running' -and $record.PSObject.Properties['ownerProcessId']){
            $owner=Get-Process -Id ([int]$record.ownerProcessId) -ErrorAction SilentlyContinue
            if($owner -and $owner.StartTime.ToUniversalTime().ToString('o') -eq $record.ownerStartedUtc){throw 'The previous initializer process is still running. Wait for it to finish before resuming.'}
        }
        foreach($property in $record.settings.PSObject.Properties){
            if($property.Name -in (Get-InitSettingNames)){$settings[$property.Name]=$property.Value}
        }
    }else{
        # Older failures have launch/result receipts but no checkpoint file.
        if(Test-Path (Join-Path $Directory 'configuration-repository.launch.json')){throw 'Old Repository initialization has no checkpoint settings. Start a new initialization; the old diagnostics are retained.'}
        $dump=Read-InitJson (Join-Path $Directory 'dump-main.launch.json')
        if(-not $dump){throw 'No initialization checkpoint or dump-main launch diagnostics found.'}
        $settings.DesignerPath=[string]$dump.executable
        $settings.InfobaseType=if('/S' -in $dump.arguments){'Server'}else{'File'}
        $settings.Infobase=Get-InitArgument $dump.arguments $(if($settings.InfobaseType -eq 'Server'){'/S'}else{'/F'})
        $settings.UseOSAuthentication='/WA+' -in $dump.arguments
        $settings.UserName=Get-InitArgument $dump.arguments '/N'
        $settings.AskCredential=[bool]$settings.UserName
        $settings.FreshHistory=Test-Path (Join-Path $Directory 'git-init.launch.json')
        $init=Read-InitJson (Join-Path $Directory 'git-init.launch.json')
        if($init){foreach($argument in $init.arguments){if($argument -like '--initial-branch=*'){$settings.GitBranch=$argument.Substring(17)}}}
        $imports=@(Get-ChildItem -LiteralPath $Directory -Filter 'edt-import-*.launch.json' -File)
        foreach($file in $imports){
            $launch=Read-InitJson $file.FullName
            if('--base-project-name' -notin $launch.arguments){
                $settings.EdtCliPath=[string]$launch.executable
                $settings.ProjectName=Get-InitArgument $launch.arguments '--project-name'
                if(-not $settings.ProjectName){$settings.ProjectName=Split-Path (Get-InitArgument $launch.arguments '--project') -Leaf}
                $ini=Get-InitArgument $launch.arguments '-ini-file';if($ini){$settings.EdtIniFile=$ini}
                break
            }
        }
        $result=Read-InitJson (Join-Path $Directory 'dump-main.result.json')
        if($result -and $result.PSObject.Properties['timeoutSeconds']){$settings.TimeoutSeconds=[int]$result.timeoutSeconds}
        if(-not $settings.Infobase){throw 'Cannot recover the source address from old diagnostics.'}
    }
    $selectionKnown=[bool]($record -and $record.PSObject.Properties['selectedExtensions'])
    return @{directory=$Directory;chain=$chain;settings=$settings;selectionKnown=$selectionKnown;selectedExtensions=$(if($selectionKnown){@($record.selectedExtensions)}else{@()})}
}
function Write-InitializationCheckpoint([string]$Status) {
    $settings=@{}
    foreach($name in (Get-InitSettingNames)) {
        if($InfobaseType -ne 'Repository' -and $name -in @('RepositoryUserName','RepositoryVersion','ExtensionRepositoryFile','AskRepositoryCredential')){continue}
        $variable=Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        if($variable){
            $value=$variable.Value
            if($name -eq 'Infobase'){$value=$initialSourceInfobase}
            if($value -is [Management.Automation.SwitchParameter]){$value=[bool]$value}
            $settings[$name]=$value
        }
    }
    $record=@{schemaVersion=1;status=$Status;settings=$settings;previousDirectory=$(if($resume){$resume.directory}else{''});ownerProcessId=$PID;ownerStartedUtc=([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'))}
    if($null -ne $selectedExtensionNames){$record.selectedExtensions=@($selectedExtensionNames)}
    $path=Join-Path $work 'initialization.json';$temporary=$path+'.tmp'
    Write-Text $temporary ($record|ConvertTo-Json -Depth 10)
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,[NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
}
function Get-InitializationCachedExport([string]$Label,[bool]$AllExtensions,[string]$CheckpointDirectory) {
    if(-not $resume){return ''}
    foreach($directory in $(if($CheckpointDirectory){@($CheckpointDirectory)}else{$resume.chain})){
        $result=Read-InitJson (Join-Path $directory ($Label+'.result.json'))
        $launch=Read-InitJson (Join-Path $directory ($Label+'.launch.json'))
        if(-not $result -or $result.timedOut -or $result.exitCode -ne 0 -or -not $launch){continue}
        if($result.PSObject.Properties['memoryExhausted'] -and $result.memoryExhausted){continue}
        if($result.PSObject.Properties['commandFailed'] -and $result.commandFailed){continue}
        $path=Get-InitArgument $launch.arguments '/DumpConfigToFiles'
        if(-not $path -or -not [IO.Path]::GetFullPath($path).StartsWith($directory.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
        if(-not(Test-Path -LiteralPath $path -PathType Container)){continue}
        if(-not $AllExtensions -and -not(Test-Path -LiteralPath (Join-Path $path 'Configuration.xml') -PathType Leaf)){continue}
        return $path
    }
    return ''
}
function Get-InitializationCachedSnapshot([bool]$WithoutExtensions) {
    if($resume){foreach($directory in $resume.chain){
        $main=Get-InitializationCachedExport 'dump-main' $false $directory
        $extensions=if($WithoutExtensions){''}else{Get-InitializationCachedExport 'dump-extensions' $true $directory}
        if($main -and ($WithoutExtensions -or $extensions)){return @{main=$main;extensions=$extensions}}
    }}
    return @{main='';extensions=''}
}
function Get-InitializationCachedEdt([string]$Name,[string]$Xml,[string]$BaseProject) {
    if(-not $resume){return ''}
    foreach($directory in $resume.chain){
        $label='edt-import-'+$Name
        $result=Read-InitJson (Join-Path $directory ($label+'.result.json'))
        $launch=Read-InitJson (Join-Path $directory ($label+'.launch.json'))
        if(-not $result -or $result.timedOut -or $result.exitCode -ne 0 -or -not $launch){continue}
        if($result.PSObject.Properties['memoryExhausted'] -and $result.memoryExhausted){continue}
        if($result.PSObject.Properties['commandFailed'] -and $result.commandFailed){continue}
        $projectName=Get-InitArgument $launch.arguments '--project-name'
        $projectPath=Get-InitArgument $launch.arguments '--project'
        if(-not $projectName -and $projectPath){$projectName=Split-Path $projectPath -Leaf}
        if($launch.executable -ne $EdtCliPath -or (Get-InitArgument $launch.arguments '--configuration-files') -ne $Xml -or
            $projectName -ne $Name -or
            (Get-InitArgument $launch.arguments '--base-project-name') -ne $BaseProject -or
            (Get-InitArgument $launch.arguments '-ini-file') -ne [string]$EdtIniFile){continue}
        $data=Get-InitArgument $launch.arguments '-data';$path=Join-Path $data $Name
        $inside=$false
        foreach($root in $resume.chain){if([IO.Path]::GetFullPath($path).StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$inside=$true}}
        if(-not $inside){continue}
        if((Test-Path -LiteralPath (Join-Path $path '.project')) -and (Test-Path -LiteralPath (Join-Path $path 'src') -PathType Container)){return $path}
    }
    return ''
}
function Add-EdtHeapArguments([string[]]$Arguments,[string]$MaxHeap){
    if(-not $MaxHeap){return $Arguments}
    $index=[Array]::IndexOf($Arguments,'-command')
    if($index -lt 0){return @($Arguments)+@('-vmargs',('-Xmx'+$MaxHeap))}
    $prefix=if($index -gt 0){@($Arguments[0..($index-1)])}else{@()}
    return @($prefix)+@('-vmargs',('-Xmx'+$MaxHeap))+@($Arguments[$index..($Arguments.Count-1)])
}
function Copy-InitializationTree([string]$Source,[string]$Destination,[string]$Label) {
    # Robocopy supports long paths without changing the Windows machine policy.
    $arguments=@($Source,$Destination,'/E','/COPY:DAT','/DCOPY:DAT','/XJ','/R:1','/W:1','/NP','/NFL','/NDL','/NJH','/NJS')
    [void](Run-Native (Join-Path $env:WINDIR 'System32\robocopy.exe') $arguments $Label -SuccessExitCodes @(0,1,2,3,4,5,6,7))
}
