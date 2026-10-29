#requires -Version 5.1
function Select-ProjectSourceFormat {
    Write-Host 'Select project format:'
    Write-Host '  1. EDT projects (requires EDT CLI)'
    Write-Host '  2. Designer XML files (without EDT)'
    while($true){
        $answer=([string](Read-Host 'Format number (1-2) [1]')).Trim()
        if(-not $answer -or $answer -eq '1'){return 'EDT'}
        if($answer -eq '2'){return 'XML'}
        Write-Host 'Enter 1 or 2.'
    }
}
function Select-ProjectSourceType {
    param([string[]]$Types=@('File','Server','Repository'))
    $labels=@{File='File infobase';Server='Server infobase';Repository='Configuration repository'}
    Write-Host 'Select source type:'
    for ($index=0;$index -lt $Types.Count;$index++) {
        Write-Host ('  {0}. {1}' -f ($index+1),$labels[$Types[$index]])
    }
    while ($true) {
        $answer=[string](Read-Host ('Source number (1-{0})' -f $Types.Count))
        $number=0
        if ([int]::TryParse($answer.Trim(),[ref]$number) -and $number -ge 1 -and $number -le $Types.Count) {
            return $Types[$number-1]
        }
        Write-Host ('Enter a number between 1 and {0}.' -f $Types.Count)
    }
}
