$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
function Dump($path,$sheetName,$refs){
  $z=[System.IO.Compression.ZipFile]::OpenRead($path)
  try{
    $e=$z.GetEntry('xl/workbook.xml');$r=New-Object System.IO.StreamReader($e.Open());$wbT=$r.ReadToEnd();$r.Close()
    $m=[regex]::Match($wbT,'<sheet[^>]*name="'+[regex]::Escape($sheetName)+'"[^>]*r:id="(rId\d+)"'); if(-not $m.Success){$m=[regex]::Match($wbT,'<sheet[^>]*r:id="(rId\d+)"[^>]*name="'+[regex]::Escape($sheetName)+'"')}
    $rid=$m.Groups[1].Value
    $e=$z.GetEntry('xl/_rels/workbook.xml.rels');$r=New-Object System.IO.StreamReader($e.Open());$relT=$r.ReadToEnd();$r.Close()
    $tgt=[regex]::Match($relT,'Id="'+$rid+'"[^>]*Target="([^"]+)"').Groups[1].Value
    $part='xl/'+($tgt -replace '^/xl/','' -replace '^\./','')
    $e=$z.GetEntry($part);$r=New-Object System.IO.StreamReader($e.Open());$shT=$r.ReadToEnd();$r.Close()
    foreach($ref in $refs){ $cm=[regex]::Match($shT,'<c r="'+$ref+'"[^>]*>.*?</c>'); Write-Host ("  {0}: {1}" -f $ref,$cm.Value) }
  } finally { $z.Dispose() }
}
$refs=@('A6','A9','K32')
Write-Host 'SOURCE:'; Dump 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\10_SolidWaste_WIP_v02.xlsx' 'Input - Solid waste' $refs
Write-Host 'OUTPUT:'; Dump 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\13_Scope3_WIP_v13.xlsx' 'Input - Solid waste' $refs
