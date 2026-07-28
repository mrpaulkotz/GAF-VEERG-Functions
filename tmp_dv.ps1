$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
function Get-SheetXml($path,$sheetName){
  $z=[System.IO.Compression.ZipFile]::OpenRead($path)
  try{
    $e=$z.GetEntry('xl/workbook.xml');$r=New-Object System.IO.StreamReader($e.Open());$wbT=$r.ReadToEnd();$r.Close()
    $m=[regex]::Match($wbT,'<sheet[^>]*name="'+[regex]::Escape($sheetName)+'"[^>]*r:id="(rId\d+)"'); if(-not $m.Success){$m=[regex]::Match($wbT,'<sheet[^>]*r:id="(rId\d+)"[^>]*name="'+[regex]::Escape($sheetName)+'"')}
    $rid=$m.Groups[1].Value
    $e=$z.GetEntry('xl/_rels/workbook.xml.rels');$r=New-Object System.IO.StreamReader($e.Open());$relT=$r.ReadToEnd();$r.Close()
    $tgt=[regex]::Match($relT,'Id="'+$rid+'"[^>]*Target="([^"]+)"').Groups[1].Value
    $part='xl/'+($tgt -replace '^/xl/','' -replace '^\./','')
    $e=$z.GetEntry($part);$r=New-Object System.IO.StreamReader($e.Open());$shT=$r.ReadToEnd();$r.Close()
    return $shT
  } finally { $z.Dispose() }
}
$sn='Input - Solid waste'
$s=Get-SheetXml 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\10_SolidWaste_WIP_v02.xlsx' $sn
$o=Get-SheetXml 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\13_Scope3_WIP_v13.xlsx' $sn
Write-Host '--- SOURCE dataValidations ---'
foreach($m in [regex]::Matches($s,'<dataValidation [^>]*?>.*?</dataValidation>|<dataValidation [^>]*?/>')){ Write-Host $m.Value }
Write-Host '--- OUTPUT dataValidations ---'
foreach($m in [regex]::Matches($o,'<dataValidation [^>]*?>.*?</dataValidation>|<dataValidation [^>]*?/>')){ Write-Host $m.Value }
Write-Host ('--- SOURCE formula cells (<f>) count: {0}' -f ([regex]::Matches($s,'<f[ >]')).Count)
Write-Host ('--- OUTPUT formula cells (<f>) count: {0}' -f ([regex]::Matches($o,'<f[ >]')).Count)
Write-Host '--- SOURCE <f> samples ---'
foreach($m in ([regex]::Matches($s,'<c r="([A-Z]+\d+)"[^>]*><f[^>]*>(.*?)</f>') | Select-Object -First 20)){ Write-Host ("  {0}: {1}" -f $m.Groups[1].Value,$m.Groups[2].Value) }
Write-Host '--- OUTPUT <f> samples ---'
foreach($m in ([regex]::Matches($o,'<c r="([A-Z]+\d+)"[^>]*><f[^>]*>(.*?)</f>') | Select-Object -First 20)){ Write-Host ("  {0}: {1}" -f $m.Groups[1].Value,$m.Groups[2].Value) }
