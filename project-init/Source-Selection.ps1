#requires -Version 5.1
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
