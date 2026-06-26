param(
  [string] $WorkbookPath,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$syncScript = Join-Path $repoRoot 'scripts\sync-xlf-to-excel-labs.ps1'

$syncArgs = @{ RepoRoot = $repoRoot }
if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
  $syncArgs['WorkbookPath'] = $WorkbookPath
}
& $syncScript @syncArgs

# Refresh the derived source-data JSON artifacts from the .xlf source of truth.
$sourceDataScript = Join-Path $repoRoot 'scripts\build-source-data-json.ps1'
& $sourceDataScript -RepoRoot $repoRoot

# Refresh the derived input-fields JSON artifacts from the module workbooks.
$inputFieldsScript = Join-Path $repoRoot 'scripts\build-input-fields-json.ps1'
& $inputFieldsScript -RepoRoot $repoRoot

$commandArgsInput = @($Command)
if ($commandArgsInput.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($commandArgsInput[0])) {
  $commandName = $commandArgsInput[0]
  $commandArgs = @()
  if ($commandArgsInput.Count -gt 1) {
    $commandArgs = $commandArgsInput[1..($commandArgsInput.Count - 1)]
  }

  if ($commandName -eq 'Sync-CommonSheetsAcrossWorkbooks') {
    Write-Host 'Sync-CommonSheetsAcrossWorkbooks already ran as part of build.ps1.'
    exit 0
  }

  & $commandName @commandArgs
  if (Test-Path -LiteralPath variable:LASTEXITCODE) {
    exit $LASTEXITCODE
  }

  if ($?) {
    exit 0
  }

  exit 1
}

Write-Host 'Sync complete. No downstream command was provided.'