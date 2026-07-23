$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$src = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\Common_v02.xlsx'
$tmp = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\tmp_com_test.xlsx'
Copy-Item -LiteralPath $src -Destination $tmp -Force

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
$excel.ScreenUpdating = $false
$excel.EnableEvents = $false
$wb = $null
try {
  $wb = $excel.Workbooks.Open($tmp)

  function Set-LambdaName {
    param([string] $Name, [string] $Formula)
    # Delete existing then re-add (mirrors the user's manual delete+republish).
    try { $wb.Names.Item($Name).Delete() } catch { }
    [void] $wb.Names.Add($Name, $Formula)
  }

  # Case 1: simple LAMBDA, required params only.
  Set-LambdaName -Name 'Common_InputFunctions.Utility_GetArrayTableRowStartNumber' `
    -Formula '=LAMBDA(TableheaderCell, RowsBetweenHeaderandArray, ROW(TableheaderCell) + RowsBetweenHeaderandArray - 1)'

  # Case 2: future funcs (UNIQUE, ISOMITTED), optional param, sibling calls.
  # Sibling calls qualified with the module name (as the published form requires).
  Set-LambdaName -Name 'Common_InputFunctions.Utility_DisplayArrayInTable' `
    -Formula '=LAMBDA(ArrayData, TableheaderCell, RowsBetweenHeaderandArray, [ColumnsBetweenHeaderAndArray], IFERROR(INDEX(UNIQUE(ArrayData), ROW()-Common_InputFunctions.Utility_GetArrayTableRowStartNumber(TableheaderCell, RowsBetweenHeaderandArray), COLUMN()-Common_InputFunctions.Utility_GetArrayTableColumnStartNumber(TableheaderCell) + IF(ISOMITTED(ColumnsBetweenHeaderAndArray), 1, ColumnsBetweenHeaderAndArray)), ""))'

  $wb.Save()
  Write-Host 'COM save OK'
}
finally {
  if ($null -ne $wb) { try { $wb.Close($false) } catch { } }
  try { $excel.Quit() } catch { }
  [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel)
}

# Inspect the resulting refersTo.
$zip = [System.IO.Compression.ZipFile]::Open($tmp, 'Read')
try {
  $e = $zip.GetEntry('xl/workbook.xml')
  $r = [System.IO.StreamReader]::new($e.Open()); $xml = $r.ReadToEnd(); $r.Dispose()
  $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($xml)
  $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace('x', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
  foreach ($nm in @('Common_InputFunctions.Utility_GetArrayTableRowStartNumber', 'Common_InputFunctions.Utility_DisplayArrayInTable')) {
    $n = $doc.SelectSingleNode("//x:definedName[@name='$nm']", $ns)
    Write-Host "=== $nm ==="
    if ($null -eq $n) { Write-Host '  (not found)' } else { Write-Host $n.InnerText }
    Write-Host ''
  }
}
finally { $zip.Dispose() }
