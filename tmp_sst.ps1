$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
function Get-SST($path){
  $z=[System.IO.Compression.ZipFile]::OpenRead($path)
  try{ $e=$z.GetEntry('xl/sharedStrings.xml'); $r=New-Object System.IO.StreamReader($e.Open()); $t=$r.ReadToEnd(); $r.Close(); $xml=[xml]$t; $a=@(); foreach($si in $xml.sst.si){ $a+=,([string]$si.InnerText) }; return $a } finally { $z.Dispose() }
}
$s=Get-SST 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\10_SolidWaste_WIP_v02.xlsx'
$o=Get-SST 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\13_Scope3_WIP_v13.xlsx'
$pairs=@(@(1,67),@(86,249),@(85,259),@(147,885),@(140,894),@(159,903),@(160,904),@(161,905),@(142,897),@(139,893))
foreach($p in $pairs){ $ss=$s[$p[0]]; $oo=$o[$p[1]]; Write-Host ("src[{0}]=[{1}]  out[{2}]=[{3}]  MATCH={4}" -f $p[0],$ss,$p[1],$oo,($ss -eq $oo)) }
