$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$tables=@('Table_SourceData_WasteSolid_WasteTreatmentEFs','Table_SourceData_ElectricityEFs','Table_SourceData_Swine_IrrigationMethods','Table_SourceData_Dairy_ProductionSystemTemplates','Table_SourceData_PoultryMMSStage1')
function Get-Tables($path){
  $z=[System.IO.Compression.ZipFile]::OpenRead($path)
  try{ $names=@(); foreach($e in ($z.Entries | Where-Object { $_.FullName -like 'xl/tables/*.xml' })){ $r=New-Object System.IO.StreamReader($e.Open()); $t=$r.ReadToEnd(); $r.Close(); $m=[regex]::Match($t,'<table[^>]*name="([^"]+)"'); if($m.Success){ $names+=$m.Groups[1].Value } }; return $names } finally { $z.Dispose() }
}
$out='C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\13_Scope3_WIP_v13.xlsx'
$ot=Get-Tables $out
Write-Host ("Output total tables: {0}" -f $ot.Count)
foreach($tn in $tables){ Write-Host ("  {0} present in output: {1}" -f $tn, ($ot -contains $tn)) }
Write-Host '--- WasteTypes tables in output ---'
$ot | Where-Object { $_ -like 'Table_WasteTypes_*' } | ForEach-Object { Write-Host "  $_" }
