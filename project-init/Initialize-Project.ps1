#requires -Version 5.1
<#
.SYNOPSIS
Creates Git sources in EDT format from an existing 1C infobase.
.DESCRIPTION
Reads the main configuration and extensions using Designer, then imports XML
with EDT CLI into an isolated workspace. Does not update the source infobase,
bind repositories, or push Git commits. By default the template clone is
initialized in place; an explicit different TargetDirectory must not exist.
#>
[CmdletBinding()]
param(
    [ValidateSet('File','Server','Repository')][string]$InfobaseType,
    [string]$Infobase,
    [string]$TargetDirectory,
    [string]$TemplateDirectory,
    [string]$ProjectRemoteUrl,
    [string]$GitBranch,
    [switch]$FreshHistory,
    [string]$DesignerPath,
    [string]$EdtCliPath,
    [string]$EdtIniFile,
    [ValidatePattern('^[1-9][0-9]*[mMgG]$')][string]$EdtMaxHeap,
    [switch]$RegisterEdtStart,
    [switch]$RestartEdtStart,
    [string]$EdtWorkspaceDirectory,
    [string]$GitPath = 'git',
    [string]$ProjectName = 'Configuration',
    [string]$UserName,
    [Security.SecureString]$Password,
    [string]$RepositoryUserName,
    [Security.SecureString]$RepositoryPassword,
    [ValidateRange(-1,2147483647)][int]$RepositoryVersion=-1,
    [string]$ExtensionRepositoryFile,
    [string[]]$Extensions,
    [switch]$SelectExtensions,
    [switch]$NoExtensions,
    [switch]$AskCredential,
    [switch]$AskRepositoryCredential,
    [switch]$UseOSAuthentication,
    [switch]$NonInteractive,
    [string]$ResumeFrom,
    [switch]$Preview,
    [switch]$SkipInitialCommit,
    [switch]$NoGitLfs,
    [string]$GitUserName,
    [string]$GitUserEmail,
    [ValidateRange(30,86400)][int]$TimeoutSeconds = 1800
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$secret = $null
$repositorySecret = $null
. (Join-Path $PSScriptRoot 'Native-Tools.ps1')
. (Join-Path $PSScriptRoot 'Select-Extensions.ps1')
. (Join-Path $PSScriptRoot 'Project-Git.ps1')
. (Join-Path $PSScriptRoot 'Fresh-History.ps1')
. (Join-Path $PSScriptRoot 'Credentials.ps1')
. (Join-Path $PSScriptRoot 'Source-Selection.ps1')
. (Join-Path $PSScriptRoot 'Initialization-State.ps1')
. (Join-Path $PSScriptRoot 'Native-Output.ps1')
$resume=$null;$resumeExportsReady=$false;$selectedExtensionNames=$null;$resumeSelectionOverride=$false;$work=$null
$edtBaseSource='';$edtRecoveryPrepared=$false
$inPlace=$false;$initializationLock=$null;$initializationLockPath=$null;$projectPublished=$false
$interactiveRun=-not $PSBoundParameters.ContainsKey('InfobaseType')
$interactiveExtensions=$SelectExtensions -or (-not $PSBoundParameters.ContainsKey('InfobaseType') -and -not $Extensions -and -not $NoExtensions)

function Resolve-Executable([string]$Value) {
    if (Test-Path -LiteralPath $Value -PathType Leaf) { return (Get-Item -LiteralPath $Value).FullName }
    $command = Get-Command $Value -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "Executable not found: $Value" }
    return $command.Source
}
function Assert-SingleLine([string]$Value,[string]$Label) {
    if ($Value -match '[\x00\r\n"]') { throw "$Label contains unsupported quotes or line breaks." }
}
function Assert-ProjectName([string]$Value) {
    if ($Value -notmatch '^[\p{L}\p{N}_][\p{L}\p{N}_.-]*$' -or $Value.EndsWith('.') -or $Value -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
        throw "Invalid project/folder name: $Value"
    }
}
function Read-InitializationChoice([string]$Prompt,[bool]$Default) {
    $defaultNumber=if($Default){'1'}else{'2'}
    Write-Host $Prompt
    Write-Host '  1. Yes'
    Write-Host '  2. No'
    while($true) {
        $answer=(Read-Host "Choice (1-2) [$defaultNumber]").Trim()
        if(-not $answer){return $Default}
        if($answer -in @('1','y','yes')){return $true}
        if($answer -in @('2','n','no')){return $false}
        Write-Host 'Enter 1 or 2.'
    }
}
function Set-InitializationAuthentication {
    param([Collections.IDictionary]$Provided,[string]$SourceType,[bool]$SkipQuestions)
    if($SourceType -eq 'Repository' -or $SkipQuestions){return}
    foreach($name in @('UseOSAuthentication','AskCredential','UserName','Password')) {
        if($Provided.ContainsKey($name)){return}
    }
    if(Read-InitializationChoice 'Use Windows/OS authentication for the infobase?' $true) {
        $script:UseOSAuthentication=$true
    } else {
        $script:AskCredential=$true
    }
}
function Set-InitializationGitOptions {
    param([Collections.IDictionary]$Provided,[bool]$InPlace,[string]$CurrentBranch,[bool]$SkipQuestions)
    if($InPlace -and -not $Provided.ContainsKey('FreshHistory') -and -not $SkipQuestions) {
        Write-Host 'Fresh history creates a new Git history. The existing history is backed up before replacement.'
        $script:FreshHistory=Read-InitializationChoice 'Create fresh Git history instead of keeping template history?' $false
    }
    $defaultBranch=if($InPlace -and -not $FreshHistory){$CurrentBranch}else{'main'}
    if(-not $Provided.ContainsKey('GitBranch') -and -not $SkipQuestions) {
        $script:GitBranch=Read-Host "Git branch [$defaultBranch]"
    }
    if(-not $GitBranch){$script:GitBranch=$defaultBranch}
}
function Quote-NativeArgument([string]$Value) {
    # Windows CommandLineToArgvW / CRT escaping, including empty strings.
    # 1C also parses its startup mode itself: do not quote bare switches/modes.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    '"' + [regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1') + '"'
}
function Protect-Text([string]$Value) {
    foreach ($item in @($secret,$repositorySecret)) { if ($item) { $Value = $Value.Replace($item,'[REDACTED]') } }
    return $Value
}
function Write-Text([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text.Replace("`r`n","`n"),$utf8) }
function Get-SafeNativeArguments([string[]]$Arguments) {
    $hideNext=$false
    foreach ($argument in $Arguments) {
        if ($hideNext) { '[REDACTED]';$hideNext=$false }
        else { $argument;$hideNext=$argument -in @('/P','/ConfigurationRepositoryP') }
    }
}
function Run-Native([string]$Exe,[string[]]$Arguments,[string]$Label,[switch]$UnicodeOutput,[int[]]$SuccessExitCodes=@(0)) {
    Write-Host $Label
    $safeArguments=@(Get-SafeNativeArguments $Arguments)
    Write-Text (Join-Path $work ($Label+'.launch.json')) (@{executable=$Exe;arguments=$safeArguments}|ConvertTo-Json -Depth 5)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($UnicodeOutput) { $info.StandardOutputEncoding = [Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8 }
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $info
    $capture=$null;$started=$false;$timedOut=$false;$memoryExhausted=$false;$commandFailed=$false
    $stdoutPath=Join-Path $work ($Label+'.stdout.log');$stderrPath=Join-Path $work ($Label+'.stderr.log')
    $watch=[Diagnostics.Stopwatch]::new();$nextStatus=30.0;$nextLogCheck=0.0
    $edtLog='';$logPosition=0L;$logTail=''
    $stdoutPosition=0L;$stderrPosition=0L;$commandTail=''
    $duplicatePattern='(?i)Workspace project with name[^\r\n]*already exists?'
    if($Label -like 'edt-*'){
        $data=Get-InitArgument $Arguments '-data'
        if($data){$edtLog=Join-Path $data '.metadata\.log';if(Test-Path -LiteralPath $edtLog){$logPosition=(Get-Item -LiteralPath $edtLog).Length}}
    }
    try {
        Initialize-NativeOutputCapture
        [void]$proc.Start();$started=$true;$watch.Start()
        $capture=[ProjectInitializer.OutputCapture]::new($proc,$stdoutPath,$stderrPath,[string[]]@($secret,$repositorySecret))
        while(-not $proc.WaitForExit(500)){
            if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){$timedOut=$true;break}
            if($edtLog -and $watch.Elapsed.TotalSeconds -ge $nextLogCheck){
                $delta=Read-InitializationEdtLog $edtLog ([ref]$logPosition)
                $logTail+=$delta
                if($logTail -match 'OutOfMemoryError\s*:\s*(Java heap space|GC overhead limit exceeded)'){$memoryExhausted=$true;break}
                if($Label -like 'edt-import-*' -or $Label -like 'edt-register-*'){
                    $commandTail+=(Read-InitializationEdtLog $stdoutPath ([ref]$stdoutPosition))+(Read-InitializationEdtLog $stderrPath ([ref]$stderrPosition))
                    if($commandTail -match $duplicatePattern){$commandFailed=$true;break}
                    if($commandTail.Length -gt 2048){$commandTail=$commandTail.Substring($commandTail.Length-2048)}
                }
                if($logTail.Length -gt 512){$logTail=$logTail.Substring($logTail.Length-512)}
                $nextLogCheck=$watch.Elapsed.TotalSeconds+2
            }
            if($watch.Elapsed.TotalSeconds -ge $nextStatus){
                $seconds=[int]$watch.Elapsed.TotalSeconds
                Write-Host ("$Label : waiting, elapsed $seconds s, process $($proc.Id). Logs: $stdoutPath")
                Write-Text (Join-Path $work ($Label+'.progress.json')) (@{pid=$proc.Id;elapsedSeconds=$seconds;timeoutSeconds=$TimeoutSeconds;edtLog=$edtLog;edtLogBytesRead=$logPosition}|ConvertTo-Json)
                $nextStatus=$watch.Elapsed.TotalSeconds+30
            }
        }
        if($timedOut -or $memoryExhausted -or $commandFailed){Stop-InitializationProcess $proc}
        if(-not $capture.Complete(10000)){throw "Output streams did not close: $Label. Check the CLI process and its logs."}
        if($edtLog){
            $logTail+=Read-InitializationEdtLog $edtLog ([ref]$logPosition)
            if($logTail -match 'OutOfMemoryError\s*:\s*(Java heap space|GC overhead limit exceeded)'){$memoryExhausted=$true}
        }
        $out=[IO.File]::ReadAllText($stdoutPath);$err=[IO.File]::ReadAllText($stderrPath)
        if(($Label -like 'edt-import-*' -or $Label -like 'edt-register-*') -and ($out+$err) -match $duplicatePattern){$commandFailed=$true}
        Write-Text (Join-Path $work ($Label+'.result.json')) (@{exitCode=$proc.ExitCode;timedOut=$timedOut;memoryExhausted=$memoryExhausted;commandFailed=$commandFailed;timeoutSeconds=$TimeoutSeconds;elapsedSeconds=$watch.Elapsed.TotalSeconds;pid=$proc.Id;edtLog=$edtLog}|ConvertTo-Json)
        if($memoryExhausted){throw "EDT exhausted Java heap space: $Label. Increase -EdtMaxHeap for the available RAM and continue with -ResumeFrom. EDT log: $edtLog"}
        if($commandFailed){throw "EDT rejected the import: a workspace project with this name already exists. Continue with -ResumeFrom using a new recovery workspace. Logs: $stdoutPath"}
        if ($timedOut) { throw "Timeout: $Label after $TimeoutSeconds seconds. The operation may be incomplete." }
        if ($proc.ExitCode -notin $SuccessExitCodes) { throw "$Label failed (exit $($proc.ExitCode)). $err $out" }
        return $out.Trim()
    } finally {
        if($started -and -not $proc.HasExited){Stop-InitializationProcess $proc}
        if($capture){$capture.Dispose()}
        $watch.Stop();$proc.Dispose()
    }
}
function Export-Xml([string]$Directory,[string]$Label,[switch]$AllExtensions) {
    [void][IO.Directory]::CreateDirectory($Directory)
    $log = Join-Path $work ($Label+'.designer.log')
    $arguments = @('DESIGNER',$connectionOption,$Infobase)
    if ($UseOSAuthentication) { $arguments += '/WA+' }
    elseif ($UserName -or $Password) { $arguments += '/WA-' }
    if ($UserName) { $arguments += @('/N',$UserName) }
    if ($secret) { $arguments += @('/P',$secret) }
    # Read the current local configuration, including uncommitted changes.
    # Do not explicitly connect to its repository or change its binding.
    $arguments += @('/DisableStartupDialogs','/DisableStartupMessages','/DumpConfigToFiles',$Directory)
    if ($AllExtensions) { $arguments += '-AllExtensions' }
    $arguments += @('/Out',$log)
    try {
        [void](Run-Native $DesignerPath $arguments $Label)
        if (-not $AllExtensions -and -not (Test-Path -LiteralPath (Join-Path $Directory 'Configuration.xml') -PathType Leaf)) {
            throw "$Label returned success but Configuration.xml was not created."
        }
    } catch {
        $reason = $_.Exception.Message
        if ($InfobaseType -eq 'Repository' -and (Test-Path -LiteralPath $log)) { $reason += "`n" + (Protect-Text ([IO.File]::ReadAllText($log))) }
        $reason+="`nCheck $Label.result.json, $Label.export.json and $Label.designer.log. For a slow export, retry with a larger -TimeoutSeconds value."
        throw $reason
    } finally {
        $files=@(Get-ChildItem -LiteralPath $Directory -Recurse -File)
        $bytes=0L;foreach($file in $files){$bytes+=$file.Length}
        Write-Text (Join-Path $work ($Label+'.export.json')) (@{directory=$Directory;fileCount=$files.Count;bytes=$bytes;allExtensions=[bool]$AllExtensions}|ConvertTo-Json)
        if (Test-Path -LiteralPath $log) {
            $text = [IO.File]::ReadAllText($log)
            Write-Text $log (Protect-Text $text)
        }
    }
}
function Import-Edt([string]$Xml,[string]$Name,[string]$Destination,[string]$BaseProject) {
    $edtVersion = ($platformVersion -split '\.')[0..2] -join '.'
    $source=Get-InitializationCachedEdt $Name $Xml $BaseProject
    if($source){
        Write-Host ('reuse-edt-import-'+$Name)
        if(-not $BaseProject){$script:edtBaseSource=$source;$script:workspace=Split-Path $source -Parent}
    }else{
        if($resume -and $BaseProject -and -not $edtRecoveryPrepared){
            if(-not $edtBaseSource -or -not(Test-Path -LiteralPath (Join-Path $edtBaseSource '.project'))){throw 'Completed EDT base project is required for workspace recovery.'}
            # Never reuse a failed Eclipse project registration. Import only the
            # completed base sources into a new workspace; keep old state intact.
            $script:workspace=Join-Path $work 'edt-recovery-workspace'
            $register=@('-data',$workspace,'-timeout',"$TimeoutSeconds",'-command','import','--project',$edtBaseSource)
            $register=Add-EdtHeapArguments $register $EdtMaxHeap
            if($EdtIniFile){$register=@('-ini-file',$EdtIniFile)+$register}
            [void](Run-Native $EdtCliPath $register ('edt-register-base-'+$BaseProject) -UnicodeOutput)
            $script:edtRecoveryPrepared=$true
        }
        $projectPath=Join-Path $workspace $Name
        $arguments=@('-data',$workspace,'-timeout',"$TimeoutSeconds",'-command','import','--configuration-files',$Xml,'--project',$projectPath,'--version',$edtVersion)
        $arguments=Add-EdtHeapArguments $arguments $EdtMaxHeap
        if ($EdtIniFile) { $arguments = @('-ini-file',$EdtIniFile) + $arguments }
        if ($BaseProject) { $arguments += @('--base-project-name',$BaseProject) }
        [void](Run-Native $EdtCliPath $arguments ('edt-import-'+$Name) -UnicodeOutput)
        $source = Join-Path $workspace $Name
        if(-not $BaseProject){$script:edtBaseSource=$source;$script:edtRecoveryPrepared=$true}
    }
    if (-not (Test-Path -LiteralPath (Join-Path $source '.project')) -or -not (Test-Path -LiteralPath (Join-Path $source 'src') -PathType Container)) {
        throw "EDT did not create expected project: $source"
    }
    # CLI has exited; copy project sources without touching the live workspace.
    Copy-InitializationTree $source $Destination ('copy-edt-'+$Name)
}

try {
    if($ResumeFrom){
        $resumeSelectionOverride=$PSBoundParameters.ContainsKey('Extensions') -or $PSBoundParameters.ContainsKey('SelectExtensions') -or $PSBoundParameters.ContainsKey('NoExtensions')
        $resume=Read-InitializationResume $ResumeFrom
        if($resume.selectionKnown -and -not $resumeSelectionOverride){$selectedExtensionNames=@($resume.selectedExtensions)}
        foreach($name in $resume.settings.Keys){
            if($resume.settings.InfobaseType -ne 'Repository' -and $name -in @('RepositoryUserName','RepositoryVersion','ExtensionRepositoryFile','AskRepositoryCredential')){continue}
            if($PSBoundParameters.ContainsKey($name)){
                if($name -in @('InfobaseType','Infobase','DesignerPath','RepositoryVersion','ExtensionRepositoryFile') -and
                    [string](Get-Variable -Name $name -ValueOnly) -ne [string]$resume.settings[$name]){throw "Resume source setting differs: $name. Start a new initialization instead."}
                continue
            }
            $value=$resume.settings[$name]
            if($null -eq $value -or ($value -is [string] -and -not $value)){continue}
            Set-Variable -Name $name -Value $value -Scope Script
            $PSBoundParameters[$name]=$value
        }
        $interactiveExtensions=$SelectExtensions -or (-not $Extensions -and -not $NoExtensions -and -not $NonInteractive)
        Write-Host ('Resume snapshots: '+$resume.directory)
    }
    if($NonInteractive -and (-not $InfobaseType -or -not $Infobase -or -not $DesignerPath -or -not $EdtCliPath)) {
        throw 'NonInteractive requires InfobaseType, Infobase, DesignerPath and EdtCliPath.'
    }
    if (-not $InfobaseType) { $InfobaseType = Select-ProjectSourceType }
    if ($InfobaseType -ne 'Repository') {
        foreach($name in @('AskRepositoryCredential','RepositoryUserName','RepositoryPassword','RepositoryVersion','ExtensionRepositoryFile')) {
            if($PSBoundParameters.ContainsKey($name)){throw "$name requires -InfobaseType Repository."}
        }
    }
    Set-InitializationAuthentication $PSBoundParameters $InfobaseType ([bool]($NonInteractive -or $Preview))
    if ($UseOSAuthentication) {
        if ($InfobaseType -eq 'Repository') { throw 'UseOSAuthentication requires a File or Server infobase; repository accounts use RepositoryUserName.' }
        if ($AskCredential -or $PSBoundParameters.ContainsKey('UserName') -or $PSBoundParameters.ContainsKey('Password')) {
            throw 'UseOSAuthentication cannot be combined with AskCredential, UserName or Password.'
        }
    }
    if (-not $Infobase) { $Infobase = Read-Host 'Infobase path or server\name' }
    if (-not $TargetDirectory) {
        if (-not $TemplateDirectory) { $TemplateDirectory=Split-Path $PSScriptRoot -Parent }
        $TargetDirectory=$TemplateDirectory
        $inPlace=$true
    }
    if (-not $DesignerPath) { $DesignerPath = Read-Host 'Full path to 1cv8.exe' }
    if (-not $EdtCliPath) { $EdtCliPath = Read-Host 'Full path to 1cedtcli.exe' }
    foreach ($value in @($Infobase,$TargetDirectory,$DesignerPath,$EdtCliPath,$ProjectName,$UserName,$RepositoryUserName)) { Assert-SingleLine $value 'Parameter' }
    Assert-ProjectName $ProjectName
    if ($ProjectRemoteUrl) { Assert-ProjectRemote $ProjectRemoteUrl }
    if ($NoExtensions -and $Extensions) { throw 'Use Extensions or NoExtensions, not both.' }
    if ($SelectExtensions -and ($NoExtensions -or $Extensions)) { throw 'SelectExtensions conflicts with Extensions and NoExtensions.' }
    $DesignerPath = Resolve-Executable $DesignerPath
    $EdtCliPath = Resolve-Executable $EdtCliPath
    if ($EdtIniFile) { $EdtIniFile = (Get-Item -LiteralPath $EdtIniFile).FullName; Assert-SingleLine $EdtIniFile 'EdtIniFile' }
    if ([IO.Path]::GetExtension($EdtCliPath) -ne '.exe') { throw 'This version requires native 1cedtcli.exe (modern EDT CLI), not a bat/cmd wrapper.' }
    $GitPath = Resolve-Executable $GitPath
    $platformVersion = (Get-Item -LiteralPath $DesignerPath).VersionInfo.FileVersion
    if (-not $platformVersion) { throw 'Cannot determine 1C platform version.' }
    if ($InfobaseType -eq 'File') {
        $Infobase = (Get-Item -LiteralPath $Infobase).FullName
        if (-not (Test-Path -LiteralPath (Join-Path $Infobase '1Cv8.1CD') -PathType Leaf)) { throw 'File infobase must contain 1Cv8.1CD.' }
        $connectionOption = '/F'
    } else { $connectionOption = '/S' }
    $TargetDirectory = [IO.Path]::GetFullPath($TargetDirectory)
    if ($TemplateDirectory -and (Test-Path -LiteralPath $TemplateDirectory)) {
        $TemplateDirectory=(Get-Item -LiteralPath $TemplateDirectory).FullName
        if ($TargetDirectory.TrimEnd('\','/') -eq $TemplateDirectory.TrimEnd('\','/')) { $inPlace=$true }
    }
    if ($inPlace) { $originalState=Get-InPlaceState $GitPath $TargetDirectory }
    elseif (Test-Path -LiteralPath $TargetDirectory) { throw 'TargetDirectory already exists. Choose a new directory; existing files are never overwritten.' }
    $parent = Split-Path -Parent $TargetDirectory
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Target parent directory must exist.' }
    Set-InitializationGitOptions $PSBoundParameters $inPlace $(if($inPlace){$originalState.branch}else{''}) ([bool]($NonInteractive -or $Preview))
    if ($inPlace -and $FreshHistory) { Assert-FreshHistoryRepository $GitPath $TargetDirectory $originalState }
    Assert-InitializationBranch $GitPath $(if($inPlace){$TargetDirectory}else{$parent}) $GitBranch $(if($inPlace -and -not $FreshHistory){$originalState.branch}else{''})
    $repositories=@()
    if ($InfobaseType -eq 'Repository') {
        if ($RepositoryVersion -eq 0 -or $UserName -or $Password) { throw 'Use repository credentials and version -1 or a positive version.' }
        $sourceRepositoryUrl=$Infobase
        if ($ExtensionRepositoryFile) {
            $parsedRepositories=[IO.File]::ReadAllText((Get-Item -LiteralPath $ExtensionRepositoryFile).FullName) | ConvertFrom-Json
            $repositories=@($parsedRepositories)
            $names=@{}
            foreach ($entry in $repositories) {
                if (@($entry.PSObject.Properties.Name | Where-Object { $_ -notin @('name','url','version') }).Count -or -not $entry.name -or -not $entry.url) { throw 'Extension entry requires name, url and optional version.' }
                Assert-ProjectName $entry.name;Assert-SingleLine $entry.url 'Repository URL'
                if ($names.ContainsKey($entry.name)) { throw 'Duplicate extension repository.' };$names[$entry.name]=$true
                if ($entry.PSObject.Properties.Name -notcontains 'version') { $entry | Add-Member -NotePropertyName version -NotePropertyValue -1 }
                if ($entry.version -isnot [int] -or $entry.version -lt -1 -or $entry.version -eq 0) { throw 'Invalid extension version.' }
            }
            if ($NoExtensions) { throw 'ExtensionRepositoryFile conflicts with NoExtensions.' }
        }
    } elseif ($ExtensionRepositoryFile) { throw 'ExtensionRepositoryFile requires Repository source.' }
    if ($InfobaseType -eq 'Repository') {
        foreach ($url in @($sourceRepositoryUrl)+@($repositories | ForEach-Object { $_.url })) {
            $uri=$null
            if (-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https','tcp') -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Repository URL must use HTTP(S) or TCP without credentials, query or fragment.' }
        }
    }
    $initialSourceInfobase=$Infobase
    $cachedSnapshot=Get-InitializationCachedSnapshot ([bool]$NoExtensions)
    $cachedMain=$cachedSnapshot.main;$cachedExtensions=$cachedSnapshot.extensions
    $resumeExportsReady=[bool]($cachedMain -and ($NoExtensions -or $cachedExtensions))
    if($resume -and -not $resumeExportsReady){$cachedMain='';$cachedExtensions=''}
    if (($AskRepositoryCredential -or ($AskCredential -and $InfobaseType -eq 'Repository')) -and -not $Preview -and -not $resumeExportsReady) {
        $credential=Read-ProjectCredential -Account 'Repository' -DefaultUserName $RepositoryUserName
        $RepositoryUserName=$credential.UserName;$RepositoryPassword=$credential.Password
    }
    if ($AskCredential -and -not $Preview -and $InfobaseType -ne 'Repository' -and -not $resumeExportsReady) {
        $credential = Read-ProjectCredential -Account 'Infobase' -DefaultUserName $UserName
        $UserName = $credential.UserName; $Password = $credential.Password
    }
    if ($Preview) {
        [PSCustomObject]@{Mode='Preview';SourceType=$InfobaseType;InfobaseAuthentication=$(if($UseOSAuthentication){'OS'}elseif($AskCredential -or $UserName -or $Password){'Infobase'}else{'Default'});Source=$Infobase;Platform=$platformVersion;Target=$TargetDirectory;FreshHistory=[bool]$FreshHistory;GitBranch=$GitBranch;MainProject=$ProjectName;Extensions=$(if($NoExtensions){'None'}elseif($Extensions){$Extensions -join ', '}else{'All'});Designer=$DesignerPath;EdtCli=$EdtCliPath;EdtMaxHeap=$EdtMaxHeap;InitialCommit=(-not $SkipInitialCommit);GitLfs=(-not $NoGitLfs);RegisterEdtStart=[bool]$RegisterEdtStart;EdtWorkspace=$(if($RegisterEdtStart){if($EdtWorkspaceDirectory){$EdtWorkspaceDirectory}else{$TargetDirectory+'-workspace'}}else{$null})}
        return
    }
    if ($UserName -and -not $Password -and -not $resumeExportsReady) {
        if($NonInteractive -and -not $AskCredential){throw 'NonInteractive requires Password with UserName (use an empty SecureString for an empty password).'}
        $Password = Read-Host 'Infobase password (empty allowed)' -AsSecureString
    }
    if ($Password) {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try { $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    if ($RepositoryUserName -and -not $RepositoryPassword -and -not $resumeExportsReady) {
        if($NonInteractive -and -not ($AskRepositoryCredential -or $AskCredential)){throw 'NonInteractive requires RepositoryPassword with RepositoryUserName.'}
        $RepositoryPassword = Read-Host 'Repository password (empty allowed)' -AsSecureString
    }
    if ($RepositoryPassword) {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($RepositoryPassword)
        try { $repositorySecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    $work = Join-Path $parent ('.project-init-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    Write-Host ("Diagnostics: $work")
    $workspace = Join-Path $work 'edt-workspace'
    $staging = Join-Path $work 'repository'
    Write-InitializationCheckpoint 'running'
    $templateCommit = $null
    if ($inPlace) {
        $initializationLockPath=Join-Path $originalState.gitDirectory 'project-initialization.lock'
        if($resume -and (Test-Path -LiteralPath $initializationLockPath)){
            if((Get-Item -LiteralPath $initializationLockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Invalid initialization lock.'}
            # An active owner holds FileShare.None, so this cannot remove its lock.
            $stale=[IO.FileStream]::new($initializationLockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)
            $stale.Dispose()
        }
        $initializationLock=[IO.File]::Open($initializationLockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    }
    if ($inPlace -and -not $FreshHistory) {
        [void](Run-Native $GitPath @('clone','--no-hardlinks','--single-branch','--branch',$originalState.branch,$TargetDirectory,$staging) 'clone-project')
        if ((Run-Native $GitPath @('-C',$staging,'rev-parse','HEAD') 'clone-head') -ne $originalState.head) { throw 'Repository changed during initialization.' }
        # Fixed paths inside the newly created staging repository only.
        if (-not ([IO.Path]::GetFullPath($staging)).StartsWith([IO.Path]::GetFullPath($work)+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe staging path.' }
        [void](Run-Native $GitPath @('-C',$staging,'rm','-r','--ignore-unmatch','--','src/cf','src/cfe') 'remove-placeholders')
        $templateCommit=$originalState.head
    } elseif ($TemplateDirectory) {
        $TemplateDirectory = (Get-Item -LiteralPath $TemplateDirectory).FullName
        if (Run-Native $GitPath @('-C',$TemplateDirectory,'status','--porcelain') 'template-clean') { throw 'Commit template changes before initialization.' }
        $templateCommit = Run-Native $GitPath @('-C',$TemplateDirectory,'rev-parse','HEAD') 'template-version'
        $files = Run-Native $GitPath @('-C',$TemplateDirectory,'-c','core.quotepath=false','ls-files','-z') 'template-files' -UnicodeOutput
        foreach ($relative in $files.Split([char]0)) {
            if (-not $relative -or $relative -match '^src/(cf|cfe)(/|$)') { continue }
            $source = [IO.Path]::GetFullPath((Join-Path $TemplateDirectory $relative))
            $destination = [IO.Path]::GetFullPath((Join-Path $staging $relative))
            if (-not $source.StartsWith($TemplateDirectory.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $destination.StartsWith($staging+'\',[StringComparison]::OrdinalIgnoreCase) -or $relative -match '(^|/)\.git(/|$)') { throw 'Unsafe template path.' }
            $item = Get-Item -LiteralPath $source
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Template symlinks are not supported.' }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath $source -Destination $destination
        }
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $staging 'src\cfe'))
    if (-not $inPlace -or $FreshHistory) { [void](Run-Native $GitPath @('-C',$staging,'init',('--initial-branch='+$GitBranch)) 'git-init') }
    if ($inPlace) {
        foreach ($setting in @('user.name','user.email')) {
            $value=& $GitPath -C $TargetDirectory config $setting
            if ($LASTEXITCODE -eq 0 -and $value) { [void](Run-Native $GitPath @('-C',$staging,'config','--local',$setting,[string]$value) ('copy-'+$setting)) }
        }
    }
    [void](Run-Native $GitPath @('-C',$staging,'config','--local','core.autocrlf','true') 'git-windows-line-endings')
    [void](Run-Native $GitPath @('-C',$staging,'config','--local','core.safecrlf','true') 'git-safe-line-endings')
    [void](Run-Native $GitPath @('-C',$staging,'config','--local','core.longpaths','true') 'git-long-paths')
    if (-not $NoGitLfs) {
        [void](Run-Native $GitPath @('lfs','version') 'git-lfs-check')
        [void](Run-Native $GitPath @('-C',$staging,'lfs','install','--local') 'git-lfs-install')
    }
    $gitIdentity = @()
    if ($GitUserName) { $gitIdentity += @('-c',('user.name='+$GitUserName)) }
    if ($GitUserEmail) { $gitIdentity += @('-c',('user.email='+$GitUserEmail)) }
    if ($inPlace -and -not $FreshHistory -and $SkipInitialCommit) { $gitIdentity=@('-c','user.name=Project initializer','-c','user.email=initializer@localhost') }
    if (-not $SkipInitialCommit) { [void](Run-Native $GitPath ($gitIdentity + @('-C',$staging,'var','GIT_AUTHOR_IDENT')) 'git-check-identity') }
    $xmlMain = if($cachedMain){$cachedMain}else{Join-Path $work 'xml-configuration'}
    if ($InfobaseType -eq 'Repository' -and -not $resumeExportsReady) {
        if (-not $RepositoryUserName) { throw 'RepositoryUserName is required.' }
        $Infobase=Join-Path $work 'read-base';$connectionOption='/F'
        Invoke-ProjectNative -Executable $DesignerPath -Arguments @('/DisableStartupDialogs','/DisableStartupMessages','/Out',(Join-Path $work 'create-base.log')) -CreateFile $Infobase -Directory $work -Label 'create-base' -TimeoutSeconds $TimeoutSeconds
        function Read-RepositorySnapshot([string]$Url,[int]$Version,[string]$Name) {
            $suffix=if ($Name) { $Name } else { 'configuration' }
            $snapshotExtension=if ($Name) { '.cfe' } else { '.cf' }
            $file=Join-Path $work ($suffix+$snapshotExtension)
            $extension=if ($Name) { @('-Extension',$Name) } else { @() }
            $common=@('DESIGNER','/F',$Infobase,'/DisableStartupDialogs','/DisableStartupMessages')
            [void](Run-Native $DesignerPath ($common+@('/ConfigurationRepositoryF',$Url,'/ConfigurationRepositoryN',$RepositoryUserName,'/ConfigurationRepositoryP',[string]$repositorySecret,'/ConfigurationRepositoryDumpCfg',$file,'-v',[string]$Version)+$extension+@('/Out',(Join-Path $work ($suffix+'-repository.log')))) ($suffix+'-repository'))
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw 'Repository snapshot was not created.' }
            [void](Run-Native $DesignerPath ($common+@('/LoadCfg',$file)+$extension+@('/Out',(Join-Path $work ($suffix+'-load.log')))) ($suffix+'-load'))
        }
        Read-RepositorySnapshot $sourceRepositoryUrl $RepositoryVersion ''
    }
    if($cachedMain){Write-Host 'reuse-dump-main'}else{Export-Xml $xmlMain 'dump-main'}
    foreach ($entry in $(if(-not $resumeExportsReady){$repositories}else{@()})) {
        $placeholder=Join-Path $work ('placeholder-'+$entry.name)
        New-ExtensionPlaceholder (Join-Path $xmlMain 'Configuration.xml') $placeholder $entry.name
        [void](Run-Native $DesignerPath @('DESIGNER','/F',$Infobase,'/DisableStartupDialogs','/DisableStartupMessages','/LoadConfigFromFiles',$placeholder,'-Extension',$entry.name,'/Out',(Join-Path $work ($entry.name+'-placeholder.log'))) ($entry.name+'-placeholder'))
        Read-RepositorySnapshot $entry.url $entry.version $entry.name
    }
    if (-not (Test-Path -LiteralPath (Join-Path $xmlMain 'Configuration.xml'))) { throw 'Designer did not export Configuration.xml.' }
    $extensionDirs = @()
    if (-not $NoExtensions) {
        $xmlExtensions = if($cachedExtensions){$cachedExtensions}else{Join-Path $work 'xml-extensions'}
        if($cachedExtensions){Write-Host 'reuse-dump-extensions'}else{Export-Xml $xmlExtensions 'dump-extensions' -AllExtensions}
        $available = @(Get-ChildItem -LiteralPath $xmlExtensions -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Configuration.xml') })
        if ($InfobaseType -eq 'Repository') {
            $exportedNames=@($available | ForEach-Object { $_.Name })
            foreach ($entry in $repositories) { if ($entry.name -notin $exportedNames) { throw 'Repository extension name differs from the requested name.' } }
        }
        if($resume -and $resume.selectionKnown -and -not $resumeSelectionOverride){
            $extensionDirs=@($available|Where-Object {$_.Name -in $resume.selectedExtensions})
        } elseif ($Extensions) {
            $availableNames = @($available | ForEach-Object { $_.Name })
            foreach ($name in $Extensions) { if ($name -notin $availableNames) { throw "Extension not found in export: $name" } }
            $extensionDirs = @($available | Where-Object Name -In $Extensions)
        } elseif ($interactiveExtensions) { $extensionDirs=@(Select-ProjectExtensions -Available $available) }
        else { $extensionDirs = $available }
    }
    $names = @($ProjectName)
    foreach ($extension in $extensionDirs) {
        Assert-ProjectName $extension.Name
        $name = $ProjectName+'_'+$extension.Name
        if ($name -in $names) { throw "Duplicate EDT project name: $name" }
        $names += $name
    }
    $selectedExtensionNames=@($extensionDirs|ForEach-Object {$_.Name})
    Write-InitializationCheckpoint 'running'
    $helpArgs = @('-data',$workspace,'-timeout',"$TimeoutSeconds",'-command','help','import')
    $helpArgs=Add-EdtHeapArguments $helpArgs $EdtMaxHeap
    if ($EdtIniFile) { $helpArgs = @('-ini-file',$EdtIniFile) + $helpArgs }
    [void](Run-Native $EdtCliPath $helpArgs 'edt-help-import' -UnicodeOutput)
    Import-Edt $xmlMain $ProjectName (Join-Path $staging 'src\cf') ''
    $mapping = @()
    foreach ($extension in $extensionDirs) {
        $name = $ProjectName+'_'+$extension.Name
        Import-Edt $extension.FullName $name (Join-Path $staging ('src\cfe\'+$extension.Name)) $ProjectName
        $mapping += [PSCustomObject]@{name=$extension.Name;projectName=$name;path=('src/cfe/'+$extension.Name)}
    }
    $manifest = [ordered]@{schemaVersion=1;sourceFormat='EDT';platformVersion=$platformVersion;configuration=@{projectName=$ProjectName;path='src/cf'};extensions=@($mapping);synchronization=@{enabled=$false;status='Unconfigured: repository baseline must be established separately'}}
    if ($TemplateDirectory) { $manifest['template'] = @{repository='https://github.com/aliferovalex/vanessa-bootstrap';commit=$templateCommit} }
    if ($InfobaseType -eq 'Repository') { $manifest['initializationSource']=@{kind='repository';url=$sourceRepositoryUrl;requestedVersion=$RepositoryVersion;extensions=@($repositories);baselineVerified=$false} }
    Write-Text (Join-Path $staging 'project-init.json') ($manifest | ConvertTo-Json -Depth 8)
    foreach ($relative in @('env.json','tools/JSON/vrunner.json')) {
        $settingsPath = Join-Path $staging $relative
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
            $settings.default.'--v8version' = $platformVersion
            Write-Text $settingsPath ($settings | ConvertTo-Json -Depth 16)
        }
    }
    $ignorePath = Join-Path $staging '.gitignore'
    $existingIgnore = if (Test-Path -LiteralPath $ignorePath) { [IO.File]::ReadAllText($ignorePath) } else { '' }
    Write-Text $ignorePath ($existingIgnore+"`n.metadata/`n.init/`n*.log`n*.1CD`n*.1CL`n*.cfl`n.env`n")
    $attributesPath = Join-Path $staging '.gitattributes'
    $attributes = if (Test-Path -LiteralPath $attributesPath) { [IO.File]::ReadAllText($attributesPath) } else { "* text=auto`n" }
    if ($NoGitLfs) { $attributes = (($attributes -split "`r?`n" | Where-Object { $_ -notmatch 'filter=lfs' }) -join "`n")+"`n" }
    Write-Text $attributesPath $attributes
    if (-not $NoGitLfs) {
        # Official EDT documentation: configure these before the first commit.
        [void](Run-Native $GitPath @('-C',$staging,'lfs','track','*.cf','*.bin','*.png','*.gif','*.bmp','*.jpg','*.zip') 'git-lfs-track')
    }
    [void](Run-Native $GitPath @('-c','core.safecrlf=false','-C',$staging,'add','--all') 'git-add')
    # Only newly generated staging files: normalize the initial export, then
    # obtain Windows working files through Git and verify with safecrlf enabled.
    $windowsCheckout = Join-Path $work 'windows-checkout'
    [void][IO.Directory]::CreateDirectory($windowsCheckout)
    # A clean prefix avoids Git retaining unchanged LF-only working files.
    [void](Run-Native $GitPath @('-C',$staging,'checkout-index','--all',('--prefix='+$windowsCheckout.Replace('\','/')+'/')) 'git-windows-working-copy')
    Copy-InitializationTree $windowsCheckout $staging 'copy-windows-working-copy'
    [void](Run-Native $GitPath @('-C',$staging,'add','--all') 'git-verify-line-endings')
    if (-not $SkipInitialCommit -or ($inPlace -and -not $FreshHistory)) { [void](Run-Native $GitPath ($gitIdentity + @('-C',$staging,'commit','-m','Initialize EDT projects from source')) 'git-commit') }
    # Publish only after all exports, imports and Git operations succeeded.
    Write-InitializationCheckpoint 'publishing'
    if ($inPlace) {
        $current=Get-InPlaceState $GitPath $TargetDirectory
        if ($current.head -ne $originalState.head -or $current.branch -ne $originalState.branch) { throw 'Repository changed before publication; original project was not updated.' }
        if ($FreshHistory) {
            Assert-FreshHistoryRepository $GitPath $TargetDirectory $current
            Set-ProjectGit $GitPath $staging $GitUserName $GitUserEmail ([bool]$NoGitLfs)
            $initializationLock.Dispose();$initializationLock=$null
            Remove-Item -LiteralPath $initializationLockPath
            $backup=Publish-FreshHistory -Git $GitPath -Repository $TargetDirectory -Staging $staging -Work $work -SkipCommit ([bool]$SkipInitialCommit)
            Write-Host "Original Git history backup: $backup"
        } else {
        $prepared=Run-Native $GitPath @('-C',$staging,'rev-parse','HEAD') 'prepared-head'
        Set-ProjectGit $GitPath $TargetDirectory $GitUserName $GitUserEmail ([bool]$NoGitLfs)
        $objects=Join-Path $staging '.git/lfs/objects'
        if (Test-Path -LiteralPath $objects) {
            $destination=Join-Path $originalState.gitDirectory 'lfs/objects'
            [void][IO.Directory]::CreateDirectory($destination)
            foreach ($file in Get-ChildItem -LiteralPath $objects -Recurse -File) {
                $relative=$file.FullName.Substring($objects.Length).TrimStart('\','/')
                $output=Join-Path $destination $relative
                [void][IO.Directory]::CreateDirectory((Split-Path $output -Parent))
                if (Test-Path -LiteralPath $output) {
                    if ((Get-FileHash -LiteralPath $output).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw 'Existing LFS object differs; publication stopped.' }
                } else { Copy-Item -LiteralPath $file.FullName -Destination $output }
            }
        }
        [void](Run-Native $GitPath @('-C',$TargetDirectory,'fetch','--no-tags','--no-write-fetch-head',$staging,$prepared) 'fetch-prepared')
        Assert-InitializationBranch $GitPath $TargetDirectory $GitBranch $originalState.branch
        if ($GitBranch -ne $originalState.branch) {
            $start=if ($SkipInitialCommit) { $originalState.head } else { $prepared }
            [void](Run-Native $GitPath @('-C',$TargetDirectory,'switch','--no-track','-c',$GitBranch,$start) 'create-project-branch')
        }
        if ($GitBranch -eq $originalState.branch -or $SkipInitialCommit) {
            $merge=if ($SkipInitialCommit) { @('merge','--squash',$prepared) } else { @('merge','--ff-only','--no-edit',$prepared) }
            [void](Run-Native $GitPath (@('-C',$TargetDirectory)+$merge) 'publish-project')
        }
        }
    } else { Move-Item -LiteralPath $staging -Destination $TargetDirectory }
    $projectPublished=$true
    Write-InitializationCheckpoint 'published'
    if ($ProjectRemoteUrl) { Set-ProjectRemote $GitPath $TargetDirectory $ProjectRemoteUrl }
    elseif ($inPlace -and $interactiveRun -and -not $NonInteractive) {
        $remote=Read-Host 'Project Git URL (empty: keep current origin; configure it before pushing)'
        if ($remote) { Set-ProjectRemote $GitPath $TargetDirectory $remote }
    }
    Write-Host "Created: $TargetDirectory"
    Write-Host "Git branch: $GitBranch"
    Write-Host "Diagnostics and intermediate exports: $work"
    if ($RegisterEdtStart) {
        if (-not $EdtWorkspaceDirectory) { $EdtWorkspaceDirectory = $TargetDirectory + '-workspace' }
        $registration = @{WorkspacePath=$EdtWorkspaceDirectory;RepositoryPath=$TargetDirectory;DisplayName=$ProjectName;EdtExecutablePath=(Join-Path (Split-Path $EdtCliPath -Parent) '1cedt.exe');EdtCliPath=$EdtCliPath;TimeoutSeconds=$TimeoutSeconds;RestartEdtStart=$RestartEdtStart}
        if ($EdtIniFile) { $registration.EdtIniFile=$EdtIniFile }
        if ($EdtMaxHeap) { $registration.EdtMaxHeap=$EdtMaxHeap }
        try { & (Join-Path $PSScriptRoot 'Register-EdtStartWorkspace.ps1') @registration }
        catch { throw "Repository created at $TargetDirectory. EDT Start registration failed; retry Register-EdtStartWorkspace.ps1 separately. $($_.Exception.Message)" }
    } else { Write-Host 'Open EDT: Import existing projects from the repository. Configure a personal debug infobase separately.' }
} catch {
    $message = Protect-Text $_.Exception.Message
    if($work -and (Test-Path -LiteralPath (Join-Path $work 'initialization.json'))){
        try{$checkpoint=Read-InitJson (Join-Path $work 'initialization.json');if($checkpoint.status -in @('running','failed')){Write-InitializationCheckpoint 'failed'}}catch{}
    }
    if ($projectPublished) { Write-Host "Project initialization is already applied at $TargetDirectory; finish Git/EDT setup separately." }
    if ($work) { Write-Host "Diagnostics: $work" }
    throw $message
} finally {
    if ($initializationLock) { $initializationLock.Dispose();Remove-Item -LiteralPath $initializationLockPath }
    $secret = $null; $Password = $null; $repositorySecret = $null; $RepositoryPassword = $null
}
