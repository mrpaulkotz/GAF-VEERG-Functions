Set-StrictMode -Off
Get-Process EXCEL -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
$excel = New-Object -ComObject Excel.Application
$excel.Visible=$false; $excel.DisplayAlerts=$false; $excel.AskToUpdateLinks=$false
$bak='C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\Enterprises\Enterprise_PastureBeef_WIP_v01.bak.xlsx'
$wb=$excel.Workbooks.Open($bak,0,$true)
Write-Host ("BAK sheets ({0}):" -f $wb.Worksheets.Count)
$i=1; foreach($ws in $wb.Worksheets){ Write-Host ("  {0}. {1}" -f $i,$ws.Name); $i++ }
$wb.Close($false)
$excel.Quit(); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
