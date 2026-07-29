# Load just the helper functions (lines 149-294) from the real script.
$lines = Get-Content -LiteralPath 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\scripts\create-test-excel-from-json.ps1'
$funcText = ($lines[148..293] -join "`n")
Invoke-Expression $funcText

$path = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Test\EntericMethane\Dairy\TestInput_EntericMethane_Dairy.json'
$o = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$standalone = $o.Scenarios[1]   # Scenario 2 as authored
$sel = Select-ScenarioObject -Object $o -RequestedName 'Scenario 2' -SourceLabel 'test'
$merged = $sel.Object

Write-Host ("Standalone tables : {0}" -f (@($standalone.InputTables).Count))
Write-Host ("Merged tables     : {0}" -f (@($merged.InputTables).Count))
Write-Host ("Standalone Milk   : {0}" -f $standalone.X_Cell_Dairy_MilkProductionAmount)
Write-Host ("Merged Milk       : {0}" -f $merged.X_Cell_Dairy_MilkProductionAmount)

$sHerd = $standalone.InputTables | Where-Object { $_.TableName -eq 'X_Table_Dairy_HerdMovement' }
$mHerd = $merged.InputTables     | Where-Object { $_.TableName -eq 'X_Table_Dairy_HerdMovement' }
Write-Host ("Standalone HerdMovement count: {0}" -f (@($merged.InputTables | Where-Object { $_.TableName -eq 'X_Table_Dairy_HerdMovement' }).Count))
Write-Host ("Standalone MilkingCows Head: {0}" -f $sHerd.Cols.MilkingCows.Head)
Write-Host ("Merged     MilkingCows Head: {0}" -f $mHerd.Cols.MilkingCows.Head)

# Deep diff standalone vs merged via JSON
$sJson = ($standalone | ConvertTo-Json -Depth 50)
$mJson = ($merged     | ConvertTo-Json -Depth 50)
Write-Host ("JSON identical (ignoring ScenarioName): {0}" -f ($sJson -eq $mJson))
if ($sJson -ne $mJson) {
  $sTmp = [System.IO.Path]::GetTempFileName(); $mTmp = [System.IO.Path]::GetTempFileName()
  Set-Content -LiteralPath $sTmp -Value $sJson; Set-Content -LiteralPath $mTmp -Value $mJson
  $d = Compare-Object (Get-Content $sTmp) (Get-Content $mTmp)
  $d | Select-Object -First 40 | Format-Table -AutoSize | Out-String | Write-Host
  Remove-Item $sTmp,$mTmp -Force
}
# Count duplicate table names in merged
$dupes = $merged.InputTables | Group-Object TableName | Where-Object { $_.Count -gt 1 }
Write-Host ("Duplicate table names in merged: {0}" -f (($dupes | ForEach-Object { $_.Name + '(x' + $_.Count + ')' }) -join ', '))
