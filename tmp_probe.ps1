$ErrorActionPreference = 'Stop'
$path = (Resolve-Path '.\Excel\3_2_Enteric_BeefPasture_WIP_v02.xlsx').Path
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
try {
  $wb = $excel.Workbooks.Open($path, 0, $true)

  Write-Host '=== Defined names matching Duration_Method1 ===' -ForegroundColor Cyan
  foreach ($n in $wb.Names) {
    $nm = [string]$n.NameLocal
    if ($nm -match 'Duration_Method1') {
      Write-Host ("{0}  ->  {1}" -f $nm, $n.RefersTo)
    }
  }

  Write-Host ''
  Write-Host '=== X_Table_PastureBeef_Duration_Method1 range + per-cell ===' -ForegroundColor Cyan
  $rng = $null
  foreach ($n in $wb.Names) {
    if (([string]$n.NameLocal) -match 'X_Table_PastureBeef_Duration_Method1$') { $rng = $n.RefersToRange; break }
  }
  if ($null -ne $rng) {
    Write-Host ("Range address: {0} on {1} ({2} rows x {3} cols)" -f $rng.Address($true,$true), $rng.Worksheet.Name, $rng.Rows.Count, $rng.Columns.Count)
    $ws = $rng.Worksheet
    # header row addresses
    for ($j = 1; $j -le $rng.Columns.Count; $j++) {
      $cell = $rng.Cells.Item(1, $j)
      Write-Host ("  col $j  addr=$($cell.Address($false,$false))  value='$($cell.Value2)'")
    }
    # Is there a ListObject overlapping this range?
    Write-Host ''
    Write-Host '=== ListObjects on the same worksheet ===' -ForegroundColor Cyan
    foreach ($lo in $ws.ListObjects) {
      Write-Host ("ListObject: {0}  range={1}" -f $lo.Name, $lo.Range.Address($false,$false))
      foreach ($lc in $lo.ListColumns) {
        Write-Host ("    col {0}: Name='{1}'" -f $lc.Index, $lc.Name)
      }
    }
  } else {
    Write-Host 'Range not found'
  }

  $wb.Close($false)
}
finally {
  $excel.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
}
