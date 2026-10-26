#requires -Version 5.1
function Invoke-InitGit([string]$Git,[string]$Repository,[string[]]$Arguments) {
    $output=& $Git -C $Repository @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Git failed: '+($Arguments[0])) }
    return ($output -join "`n").Trim()
}
function Get-InPlaceState([string]$Git,[string]$Repository) {
    $root=Invoke-InitGit $Git $Repository @('rev-parse','--show-toplevel')
    if ([IO.Path]::GetFullPath($root).TrimEnd('\','/') -ne $Repository.TrimEnd('\','/')) { throw 'Initialize the repository root, not a nested directory.' }
    if (Invoke-InitGit $Git $Repository @('status','--porcelain','--untracked-files=all')) { throw 'Commit or remove working tree changes before initialization.' }
    if (Test-Path -LiteralPath (Join-Path $Repository 'project-init.json')) { throw 'Project is already initialized.' }
    foreach ($relative in @('src/cf','src/cfe')) {
        $path=Join-Path $Repository $relative
        if (Test-Path -LiteralPath $path) {
            foreach ($item in Get-ChildItem -LiteralPath $path -Force -Recurse) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer -or $item.Name -notin @('README.md','.gitkeep')) { throw 'Configuration or extension sources already exist.' }
            }
        }
    }
    $branch=Invoke-InitGit $Git $Repository @('symbolic-ref','--short','HEAD')
    $head=Invoke-InitGit $Git $Repository @('rev-parse','HEAD')
    $directory=Invoke-InitGit $Git $Repository @('rev-parse','--absolute-git-dir')
    [pscustomobject]@{head=$head;branch=$branch;gitDirectory=$directory}
}
function Set-ProjectGit([string]$Git,[string]$Repository,[string]$UserName,[string]$UserEmail,[bool]$NoLfs=$false) {
    foreach ($setting in @(@('core.quotepath','false'),@('core.autocrlf','true'),@('core.safecrlf','true'),@('core.longpaths','true'))) {
        [void](Invoke-InitGit $Git $Repository @('config','--local',$setting[0],$setting[1]))
    }
    if ($UserName) { [void](Invoke-InitGit $Git $Repository @('config','--local','user.name',$UserName)) }
    if ($UserEmail) { [void](Invoke-InitGit $Git $Repository @('config','--local','user.email',$UserEmail)) }
    if (-not $NoLfs) { [void](Invoke-InitGit $Git $Repository @('lfs','install','--local')) }
}
function Assert-ProjectRemote([string]$Url) {
    if (-not $Url -or $Url -match '["\x00\r\n]' -or $Url.StartsWith('-')) { throw 'Invalid project remote URL.' }
    $uri=$null
    if ([Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('http','https') -and ($uri.UserInfo -or $uri.Query -or $uri.Fragment)) { throw 'Do not put credentials in the Git URL.' }
}
function Set-ProjectRemote([string]$Git,[string]$Repository,[string]$Url) {
    Assert-ProjectRemote $Url
    $remotes=@((Invoke-InitGit $Git $Repository @('remote')) -split "`n")
    $current=if ('origin' -in $remotes) { Invoke-InitGit $Git $Repository @('remote','get-url','origin') } else { '' }
    if ($current -eq $Url) { return }
    if ($current) {
        if ('bootstrap' -in $remotes) {
            if ((Invoke-InitGit $Git $Repository @('remote','get-url','bootstrap')) -ne $current) { throw 'bootstrap remote already points elsewhere; configure remotes manually.' }
        } else { [void](Invoke-InitGit $Git $Repository @('remote','add','bootstrap',$current)) }
        [void](Invoke-InitGit $Git $Repository @('remote','set-url','origin',$Url))
    } else { [void](Invoke-InitGit $Git $Repository @('remote','add','origin',$Url)) }
}
