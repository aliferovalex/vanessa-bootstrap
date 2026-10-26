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
function Run-Native([string]$Exe,[string[]]$Arguments,[string]$Label,[switch]$UnicodeOutput) {
    Write-Host $Label
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($UnicodeOutput) { $info.StandardOutputEncoding = [Text.Encoding]::UTF8 }
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $info
    try {
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            if ($PSVersionTable.PSVersion.Major -ge 7) { $proc.Kill($true) } else {
                # EDT starts child processes; kill the owned tree, not just the launcher.
                $killer = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') -ArgumentList @('/PID',"$($proc.Id)",'/T','/F') -WindowStyle Hidden -PassThru -Wait
            }
            throw "Timeout: $Label"
        }
        $out = Protect-Text ($stdout.GetAwaiter().GetResult())
        $err = Protect-Text ($stderr.GetAwaiter().GetResult())
        Write-Text (Join-Path $work ($Label + '.stdout.log')) $out
        Write-Text (Join-Path $work ($Label + '.stderr.log')) $err
        if ($proc.ExitCode -ne 0) { throw "$Label failed (exit $($proc.ExitCode)). $err $out" }
        return $out.Trim()
    } finally { $proc.Dispose() }
}
function Export-Xml([string]$Directory,[string]$Label,[switch]$AllExtensions) {
    [void][IO.Directory]::CreateDirectory($Directory)
    $log = Join-Path $work ($Label+'.designer.log')
    $arguments = @('DESIGNER',$connectionOption,$Infobase,'/DisableStartupDialogs','/DisableStartupMessages','/DumpConfigToFiles',$Directory)
    if ($AllExtensions) { $arguments += '-AllExtensions' }
    if ($UserName) { $arguments += @('/N',$UserName) }
    if ($secret) { $arguments += @('/P',$secret) }
    if ($RepositoryUserName) { $arguments += @('/ConfigurationRepositoryN',$RepositoryUserName,'/ConfigurationRepositoryP',[string]$repositorySecret) }
    $arguments += @('/Out',$log)
    try { [void](Run-Native $DesignerPath $arguments $Label) } catch {
        $reason = $_.Exception.Message
        if (Test-Path -LiteralPath $log) { $reason += "`n" + (Protect-Text ([IO.File]::ReadAllText($log))) }
        throw $reason
    } finally {
        if (Test-Path -LiteralPath $log) {
            $text = [IO.File]::ReadAllText($log)
            Write-Text $log (Protect-Text $text)
        }
    }
}
function Import-Edt([string]$Xml,[string]$Name,[string]$Destination,[string]$BaseProject) {
    $edtVersion = ($platformVersion -split '\.')[0..2] -join '.'
    $arguments = @('-data',$workspace,'-timeout',"$TimeoutSeconds",'-command','import','--configuration-files',$Xml,'--project-name',$Name,'--version',$edtVersion)
    if ($EdtIniFile) { $arguments = @('-ini-file',$EdtIniFile) + $arguments }
    if ($BaseProject) { $arguments += @('--base-project-name',$BaseProject) }
    [void](Run-Native $EdtCliPath $arguments ('edt-import-'+$Name) -UnicodeOutput)
    $source = Join-Path $workspace $Name
    if (-not (Test-Path -LiteralPath (Join-Path $source '.project')) -or -not (Test-Path -LiteralPath (Join-Path $source 'src') -PathType Container)) {
        throw "EDT did not create expected project: $source"
    }
    # CLI has exited; copy project sources without touching the live workspace.
    Copy-Item -LiteralPath $source -Destination $Destination -Recurse
}

try {
    if (-not $InfobaseType) { $InfobaseType = Read-Host 'Source type (File/Server/Repository)'; if ($InfobaseType -notin @('File','Server','Repository')) { throw 'Expected File, Server or Repository' } }
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
    if ($inPlace -and $FreshHistory) { Assert-FreshHistoryRepository $GitPath $TargetDirectory $originalState }
    $defaultBranch=if ($inPlace -and -not $FreshHistory) { $originalState.branch } else { 'main' }
    if (-not $GitBranch -and $interactiveRun -and -not $Preview) {
        $GitBranch=Read-Host ("Git branch [$defaultBranch]")
    }
    if (-not $GitBranch) { $GitBranch=$defaultBranch }
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
    if ($AskCredential -and -not $Preview -and $InfobaseType -eq 'Repository') {
        $credential=Get-Credential -Message 'Repository account'
        $RepositoryUserName=$credential.UserName;$RepositoryPassword=$credential.Password
    } elseif ($AskCredential -and -not $Preview) {
        $credential = Get-Credential -Message 'Source infobase account'
        $UserName = $credential.UserName; $Password = $credential.Password
    }
    if ($Preview) {
        [PSCustomObject]@{Mode='Preview';SourceType=$InfobaseType;Source=$Infobase;Platform=$platformVersion;Target=$TargetDirectory;FreshHistory=[bool]$FreshHistory;GitBranch=$GitBranch;MainProject=$ProjectName;Extensions=$(if($NoExtensions){'None'}elseif($Extensions){$Extensions -join ', '}else{'All'});Designer=$DesignerPath;EdtCli=$EdtCliPath;InitialCommit=(-not $SkipInitialCommit);GitLfs=(-not $NoGitLfs);RegisterEdtStart=[bool]$RegisterEdtStart;EdtWorkspace=$(if($RegisterEdtStart){if($EdtWorkspaceDirectory){$EdtWorkspaceDirectory}else{$TargetDirectory+'-workspace'}}else{$null})}
        return
    }
    if ($UserName -and -not $Password) { $Password = Read-Host 'Infobase password (empty allowed)' -AsSecureString }
    if ($Password) {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try { $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    if ($RepositoryUserName -and -not $RepositoryPassword) { $RepositoryPassword = Read-Host 'Repository password (empty allowed)' -AsSecureString }
    if ($RepositoryPassword) {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($RepositoryPassword)
        try { $repositorySecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    $work = Join-Path $parent ('.project-init-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $workspace = Join-Path $work 'edt-workspace'
    $staging = Join-Path $work 'repository'
    $templateCommit = $null
    if ($inPlace) {
        $initializationLockPath=Join-Path $originalState.gitDirectory 'project-initialization.lock'
        $initializationLock=[IO.File]::Open($initializationLockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    }
    if ($inPlace -and -not $FreshHistory) {
        [void](Run-Native $GitPath @('clone','--no-hardlinks','--single-branch','--branch',$originalState.branch,$TargetDirectory,$staging) 'clone-project')
        if ((Run-Native $GitPath @('-C',$staging,'rev-parse','HEAD') 'clone-head') -ne $originalState.head) { throw 'Repository changed during initialization.' }
        # Fixed paths inside the newly created staging repository only.
        if (-not ([IO.Path]::GetFullPath($staging)).StartsWith([IO.Path]::GetFullPath($work)+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe staging path.' }
        [void](Run-Native $GitPath @('-C',$staging,'rm','-r','--ignore-unmatch','--','src/cf','src/cfe') 'remove-placeholders')
        $templateCommit=$originalState.head
        foreach ($setting in @('user.name','user.email')) {
            $value=& $GitPath -C $TargetDirectory config $setting
            if ($LASTEXITCODE -eq 0 -and $value) { [void](Run-Native $GitPath @('-C',$staging,'config','--local',$setting,[string]$value) ('copy-'+$setting)) }
        }
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
    [void](Run-Native $GitPath @('-C',$staging,'config','--local','core.autocrlf','true') 'git-windows-line-endings')
    [void](Run-Native $GitPath @('-C',$staging,'config','--local','core.safecrlf','true') 'git-safe-line-endings')
    if (-not $NoGitLfs) {
        [void](Run-Native $GitPath @('lfs','version') 'git-lfs-check')
        [void](Run-Native $GitPath @('-C',$staging,'lfs','install','--local') 'git-lfs-install')
    }
    $gitIdentity = @()
    if ($GitUserName) { $gitIdentity += @('-c',('user.name='+$GitUserName)) }
    if ($GitUserEmail) { $gitIdentity += @('-c',('user.email='+$GitUserEmail)) }
    if ($inPlace -and -not $FreshHistory -and $SkipInitialCommit) { $gitIdentity=@('-c','user.name=Project initializer','-c','user.email=initializer@localhost') }
    if (-not $SkipInitialCommit) { [void](Run-Native $GitPath ($gitIdentity + @('-C',$staging,'var','GIT_AUTHOR_IDENT')) 'git-check-identity') }
    $xmlMain = Join-Path $work 'xml-configuration'
    if ($InfobaseType -eq 'Repository') {
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
    Export-Xml $xmlMain 'dump-main'
    foreach ($entry in $repositories) {
        $placeholder=Join-Path $work ('placeholder-'+$entry.name)
        New-ExtensionPlaceholder (Join-Path $xmlMain 'Configuration.xml') $placeholder $entry.name
        [void](Run-Native $DesignerPath @('DESIGNER','/F',$Infobase,'/DisableStartupDialogs','/DisableStartupMessages','/LoadConfigFromFiles',$placeholder,'-Extension',$entry.name,'/Out',(Join-Path $work ($entry.name+'-placeholder.log'))) ($entry.name+'-placeholder'))
        Read-RepositorySnapshot $entry.url $entry.version $entry.name
    }
    if (-not (Test-Path -LiteralPath (Join-Path $xmlMain 'Configuration.xml'))) { throw 'Designer did not export Configuration.xml.' }
    $extensionDirs = @()
    if (-not $NoExtensions) {
        $xmlExtensions = Join-Path $work 'xml-extensions'
        Export-Xml $xmlExtensions 'dump-extensions' -AllExtensions
        $available = @(Get-ChildItem -LiteralPath $xmlExtensions -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Configuration.xml') })
        if ($InfobaseType -eq 'Repository') {
            $exportedNames=@($available | ForEach-Object { $_.Name })
            foreach ($entry in $repositories) { if ($entry.name -notin $exportedNames) { throw 'Repository extension name differs from the requested name.' } }
        }
        if ($Extensions) {
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
    $helpArgs = @('-data',$workspace,'-timeout',"$TimeoutSeconds",'-command','help','import')
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
    foreach ($file in Get-ChildItem -LiteralPath $windowsCheckout -Recurse -File -Force) {
        $relative = $file.FullName.Substring($windowsCheckout.Length).TrimStart('\','/')
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $staging $relative) -Force
    }
    [void](Run-Native $GitPath @('-C',$staging,'add','--all') 'git-verify-line-endings')
    if (-not $SkipInitialCommit -or ($inPlace -and -not $FreshHistory)) { [void](Run-Native $GitPath ($gitIdentity + @('-C',$staging,'commit','-m','Initialize EDT projects from source')) 'git-commit') }
    # Publish only after all exports, imports and Git operations succeeded.
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
    if ($ProjectRemoteUrl) { Set-ProjectRemote $GitPath $TargetDirectory $ProjectRemoteUrl }
    elseif ($inPlace -and $interactiveRun) {
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
        try { & (Join-Path $PSScriptRoot 'Register-EdtStartWorkspace.ps1') @registration }
        catch { throw "Repository created at $TargetDirectory. EDT Start registration failed; retry Register-EdtStartWorkspace.ps1 separately. $($_.Exception.Message)" }
    } else { Write-Host 'Open EDT: Import existing projects from the repository. Configure a personal debug infobase separately.' }
} catch {
    $message = Protect-Text $_.Exception.Message
    if ($projectPublished) { Write-Host "Project initialization is already applied at $TargetDirectory; finish Git/EDT setup separately." }
    if (Get-Variable work -ErrorAction SilentlyContinue) { Write-Host "Diagnostics: $work" }
    throw $message
} finally {
    if ($initializationLock) { $initializationLock.Dispose();Remove-Item -LiteralPath $initializationLockPath }
    $secret = $null; $Password = $null; $repositorySecret = $null; $RepositoryPassword = $null
}
