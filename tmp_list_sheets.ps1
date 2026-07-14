Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$files = @(
  '3_2_Enteric_BeefPasture_WIP_v03.xlsx',
  '4_2_ManureManagement_BeefPasture_WIP_v08.xlsx'
)
foreach ($f in $files) {
  $wb = (Get-ChildItem -Path .\Excel -File -Filter $f | Select-Object -First 1).FullName
  Write-Host "== $f =="
  $zip = [System.IO.Compression.ZipFile]::OpenRead($wb)
  try {
    $e = $zip.GetEntry('xl/workbook.xml')
    $r = [System.IO.StreamReader]::new($e.Open()); $t = $r.ReadToEnd(); $r.Dispose()
  } finally { $zip.Dispose() }
  $d = New-Object System.Xml.XmlDocument; $d.LoadXml($t)
  $ns = New-Object System.Xml.XmlNamespaceManager($d.NameTable)
  $ns.AddNamespace('x','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
  $d.SelectNodes('//x:sheets/x:sheet',$ns) | ForEach-Object { Write-Host ("   [{0}]" -f $_.GetAttribute('name')) }
}
