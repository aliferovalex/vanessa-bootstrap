#requires -Version 5.1
function Assert-FreshHistoryRepository([string]$Git,[string]$Repository,[object]$State) {
    $path=Join-Path $Repository '.git'
    if (-not (Test-Path -LiteralPath $path -PathType Container) -or
        [IO.Path]::GetFullPath($State.gitDirectory).TrimEnd('\','/') -ne [IO.Path]::GetFullPath($path).TrimEnd('\','/') -or
        ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'FreshHistory requires a standalone clone, not a linked worktree.'
    }
    $trees=Invoke-InitGit $Git $Repository @('worktree','list','--porcelain')
    if (@($trees -split "`n" | Where-Object { $_.StartsWith('worktree ') }).Count -ne 1) { throw 'FreshHistory is not supported while additional worktrees are attached.' }
}
function Publish-FreshHistory {
    param([string]$Git,[string]$Repository,[string]$Staging,[string]$Work,[bool]$SkipCommit)
    $backup=Join-Path $Work 'previous-project'
    $journal=Join-Path $Work 'fresh-history-publication.json'
    $paths=@('src/cf','src/cfe','project-init.json','.gitignore','.gitattributes','env.json','tools/JSON/vrunner.json')
    $saved=@();$installed=@();$oldGitMoved=$false;$newGitMoved=$false
    $root=[IO.Path]::GetFullPath($Repository).TrimEnd('\')+'\'
    $scratch=[IO.Path]::GetFullPath($Work).TrimEnd('\')+'\'
    $stage=[IO.Path]::GetFullPath($Staging).TrimEnd('\')+'\'
    function Check-Path([string]$Path,[string]$Prefix) {
        if (-not [IO.Path]::GetFullPath($Path).StartsWith($Prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe publication path.' }
    }
    Check-Path $backup $scratch;Check-Path $Staging $scratch
    [void][IO.Directory]::CreateDirectory($backup)
    function Journal([string]$Phase) {
        @{phase=$Phase;project=$Repository;backup=$backup;staging=$Staging;saved=@($saved);installed=@($installed)} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journal -Encoding UTF8
    }
    Journal 'prepared'
    try {
        foreach ($relative in $paths) {
            $target=Join-Path $Repository $relative;$previous=Join-Path $backup $relative
            $source=Join-Path $Staging $relative
            Check-Path $target $root;Check-Path $previous $scratch;Check-Path $source $stage
            if (Test-Path -LiteralPath $target) {
                [void][IO.Directory]::CreateDirectory((Split-Path $previous -Parent))
                Move-Item -LiteralPath $target -Destination $previous
                $saved+=$relative;Journal 'saving-original'
            }
            if (Test-Path -LiteralPath $source) {
                [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
                Move-Item -LiteralPath $source -Destination $target
                $installed+=$relative;Journal 'installing-sources'
            }
        }
        $originalGit=Join-Path $Repository '.git';$backupGit=Join-Path $backup '.git';$stageGit=Join-Path $Staging '.git'
        Check-Path $originalGit $root;Check-Path $backupGit $scratch;Check-Path $stageGit $stage
        Move-Item -LiteralPath $originalGit -Destination $backupGit
        $oldGitMoved=$true;Journal 'git-backed-up'
        Move-Item -LiteralPath $stageGit -Destination $originalGit
        $newGitMoved=$true;Journal 'git-installed'
        if (-not $SkipCommit -and (Invoke-InitGit $Git $Repository @('status','--porcelain'))) { throw 'Fresh repository verification failed.' }
        Journal 'complete'
        return $backup
    } catch {
        $failure=$_.Exception.Message
        try {
            if ($newGitMoved) { Move-Item -LiteralPath (Join-Path $Repository '.git') -Destination (Join-Path $Staging '.git') }
            if ($oldGitMoved) { Move-Item -LiteralPath (Join-Path $backup '.git') -Destination (Join-Path $Repository '.git') }
            [array]::Reverse($installed)
            foreach ($relative in $installed) { Move-Item -LiteralPath (Join-Path $Repository $relative) -Destination (Join-Path $Staging $relative) }
            foreach ($relative in $saved) { Move-Item -LiteralPath (Join-Path $backup $relative) -Destination (Join-Path $Repository $relative) }
            Journal 'rolled-back'
        } catch {
            Journal 'recovery-required'
            throw "Publication interrupted; recover using $journal. Original Git backup: $backup"
        }
        throw $failure
    }
}
