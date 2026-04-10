param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$syncScript = Join-Path $repoRoot 'scripts\sync-xlf-to-excel-labs.ps1'

& $syncScript -RepoRoot $repoRoot

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
  exit $LASTEXITCODE
}

Write-Host 'Sync complete. No downstream command was provided.'