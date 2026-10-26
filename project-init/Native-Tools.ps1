#requires -Version 5.1
function ConvertTo-NativeArgument([string]$Value) {
    if ($Value -match '[\x00\r\n]') { throw 'Unsupported native argument.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-ProjectNative {
    param([string]$Executable,[string[]]$Arguments,[string]$Directory,[string]$Label,[int]$TimeoutSeconds=1800,[string]$CreateFile,[string[]]$Secrets=@())
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable
    $info.Arguments=($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    if ($CreateFile) {
        if ($CreateFile -match '["\x00\r\n]') { throw 'Unsupported base path.' }
        $info.Arguments='CREATEINFOBASE File="'+$CreateFile+'"; '+$info.Arguments
    }
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
            if ($PSVersionTable.PSVersion.Major -ge 7) { $process.Kill($true) }
            else { Start-Process -FilePath "$env:WINDIR\System32\taskkill.exe" -ArgumentList @('/PID',"$($process.Id)",'/T','/F') -WindowStyle Hidden -Wait | Out-Null }
            throw "Timeout: $Label"
        }
        $text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        foreach ($secretValue in $Secrets) { if ($secretValue) { $text=$text.Replace($secretValue,'[REDACTED]') } }
        [IO.File]::WriteAllText((Join-Path $Directory ($Label+'.output.log')),$text,[Text.UTF8Encoding]::new($false))
        if ($process.ExitCode -ne 0) { throw "Native operation failed: $Label (exit $($process.ExitCode)); see logs." }
    } finally { $process.Dispose() }
}
function New-ExtensionPlaceholder([string]$Template,[string]$Directory,[string]$Name) {
    if ($Name -notmatch '^[\p{L}\p{N}_][\p{L}\p{N}_.-]*$') { throw 'Invalid extension name.' }
    [xml]$source=[IO.File]::ReadAllText($Template)
    $ns='http://v8.1c.ru/8.3/MDClasses'
    $manager=New-Object Xml.XmlNamespaceManager($source.NameTable);$manager.AddNamespace('md',$ns)
    $internal=$source.SelectSingleNode('/md:MetaDataObject/md:Configuration/md:InternalInfo',$manager)
    if (-not $internal) { throw 'Missing native configuration InternalInfo.' }
    $doc=New-Object Xml.XmlDocument
    $root=$doc.CreateElement('MetaDataObject',$ns);[void]$doc.AppendChild($root)
    $root.SetAttribute('version',$source.DocumentElement.GetAttribute('version'))
    $configuration=$doc.CreateElement('Configuration',$ns);$configuration.SetAttribute('uuid',[guid]::NewGuid().ToString())
    [void]$root.AppendChild($configuration)
    $copy=$doc.ImportNode($internal,$true)
    foreach ($node in $copy.SelectNodes('.//*[local-name()="ObjectId" and namespace-uri()="http://v8.1c.ru/8.3/xcf/readable"]')) { $node.InnerText=[guid]::NewGuid().ToString() }
    [void]$configuration.AppendChild($copy)
    $properties=$doc.CreateElement('Properties',$ns);[void]$configuration.AppendChild($properties)
    $values=[ordered]@{ObjectBelonging='Adopted';Name=$Name;ConfigurationExtensionPurpose='Customization';NamePrefix='Init_';ConfigurationExtensionCompatibilityMode='Version8_3_11'}
    foreach ($key in $values.Keys) { $node=$doc.CreateElement($key,$ns);$node.InnerText=$values[$key];[void]$properties.AppendChild($node) }
    [void]$configuration.AppendChild($doc.CreateElement('ChildObjects',$ns))
    [void][IO.Directory]::CreateDirectory($Directory)
    $doc.Save((Join-Path $Directory 'Configuration.xml'))
}
