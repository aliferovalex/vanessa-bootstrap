#requires -Version 5.1
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Select-Extensions.ps1')
$available=@([pscustomobject]@{Name='First'},[pscustomobject]@{Name='Second'},[pscustomobject]@{Name='Third'})
function Assert($condition,$message){if(-not $condition){throw $message}}
$selected=@(Select-ProjectExtensions $available { '3,1,1' })
Assert ($selected.Count -eq 2 -and $selected[0].Name -eq 'First' -and $selected[1].Name -eq 'Third') 'Selected set or source order differs'
$answers=New-Object 'System.Collections.Generic.Queue[string]'
foreach($answer in @('4','1,no','999999999999999999','2')){$answers.Enqueue($answer)}
$selected=@(Select-ProjectExtensions $available { $answers.Dequeue() })
Assert ($selected.Count -eq 1 -and $selected[0].Name -eq 'Second' -and $answers.Count -eq 0) 'Invalid selection did not retry'
Assert (@(Select-ProjectExtensions $available {'*'}).Count -eq 3) 'Select all failed'
Assert (@(Select-ProjectExtensions $available {'0'}).Count -eq 0) 'Select none failed'
Assert (@(Select-ProjectExtensions @() {throw 'Unexpected prompt'}).Count -eq 0) 'Empty list prompted'
Write-Host 'PASS: selected set, duplicate numbers, invalid input retry, all, none and empty list.'
