#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Source-Selection.ps1')
function Read-Host { param($Prompt) return $script:answers.Dequeue() }
try {
    foreach ($entry in @(@('1','File'),@('2','Server'),@('3','Repository'))) {
        $script:answers=[Collections.Queue]::new()
        $script:answers.Enqueue($entry[0])
        if ((Select-ProjectSourceType) -ne $entry[1]) { throw 'Wrong source selection.' }
    }
    $script:answers=[Collections.Queue]::new()
    foreach ($answer in @('','Server','0','4','1.5',' 2 ')) { $script:answers.Enqueue($answer) }
    if ((Select-ProjectSourceType) -ne 'Server' -or $script:answers.Count) { throw 'Invalid source input was accepted.' }
    $script:answers=[Collections.Queue]::new()
    foreach ($answer in @('3','1')) { $script:answers.Enqueue($answer) }
    if ((Select-ProjectSourceType -Types @('File','Server')) -ne 'File' -or $script:answers.Count) { throw 'Unsupported source accepted.' }
} finally { Remove-Item Function:\Read-Host }
Write-Host 'PASS: source menu, all types, invalid input, supported type subset.'
