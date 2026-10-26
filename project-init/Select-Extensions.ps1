#requires -Version 5.1
function Select-ProjectExtensions {
    param([object[]]$Available=@(),[scriptblock]$ReadSelection={ Read-Host 'Select extension numbers (1,3), * for all, 0 for none [*]' })
    if (-not $Available.Count) { Write-Host 'No extensions found in the infobase.';return }
    Write-Host 'Extensions found in the infobase:'
    for ($index=0;$index -lt $Available.Count;$index++) { Write-Host ('  {0}. {1}' -f ($index+1),$Available[$index].Name) }
    while ($true) {
        $answer=[string](& $ReadSelection);$answer=$answer.Trim()
        if ($answer -in @('','*','all')) { return $Available }
        if ($answer -in @('0','none')) { return }
        $numbers=@();$valid=$true
        foreach ($part in ($answer -split '[,;\s]+')) {
            $number=0
            if (-not [int]::TryParse($part,[ref]$number) -or $number -lt 1 -or $number -gt $Available.Count) { $valid=$false;break }
            if ($number -notin $numbers) { $numbers+=$number }
        }
        if ($valid -and $numbers.Count) {
            for ($index=0;$index -lt $Available.Count;$index++) { if (($index+1) -in $numbers) { $Available[$index] } }
            return
        }
        Write-Host ('Enter numbers between 1 and {0}, * or 0.' -f $Available.Count)
    }
}
