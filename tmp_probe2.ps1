$ErrorActionPreference = 'Stop'
$path = (Resolve-Path '.\Excel\3_2_Enteric_BeefPasture_WIP_v02.xlsx').Path
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
try {
  $wb = $excel.Workbooks.Open($path, 0, $true)

  Write-Host '=== Defined names containing Bull/Steer/Cow/Class/LivestockClass ===' -ForegroundColor Cyan
  foreach ($n in $wb.Names) {
    $nm = [string]$n.NameLocal
    if ($nm -match '(?i)bull|steer|cow|class') {
      Write-Host ("{0}  ->  {1}" -f $nm, $n.RefersTo)
    }
  }

  Write-Host ''
  Write-Host '=== All ListObjects across all worksheets ===' -ForegroundColor Cyan
  foreach ($ws in $wb.Worksheets) {
    foreach ($lo in $ws.ListObjects) {
      Write-Host ("[{0}] ListObject {1}  range={2}" -f $ws.Name, $lo.Name, $lo.Range.Address($false,$false))
      foreach ($lc in $lo.ListColumns) {
        Write-Host ("    col {0}: '{1}'" -f $lc.Index, $lc.Name)
      }
    }
  }

  $wb.Close($false)
}
finally {
  $excel.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
}
