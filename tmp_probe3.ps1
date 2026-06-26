$ErrorActionPreference = 'Stop'
$path = (Resolve-Path '.\Excel\3_2_Enteric_BeefPasture_WIP_v02.xlsx').Path
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
try {
  $wb = $excel.Workbooks.Open($path, 0, $true)

  Write-Host '=== ALL defined names (full list) ===' -ForegroundColor Cyan
  foreach ($n in $wb.Names) {
    Write-Host ("{0}  ->  {1}" -f ([string]$n.NameLocal), ([string]$n.RefersTo))
  }

  $wb.Close($false)
}
finally {
  $excel.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
}
