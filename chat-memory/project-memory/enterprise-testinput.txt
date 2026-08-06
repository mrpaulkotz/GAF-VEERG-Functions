# Enterprise test-input builder

`scripts/build-enterprise-testinput-json.ps1` (npm `build-enterprise-testinput`[`:dry`]).
Merges per-module `Test/**/TestInput_*.json` into one enterprise test input.

- Module selection = enterprise config `modules` array (Enterprises/Enterprise_PastureBeef.json).
- Mapping chain: module id -> registry `_ModuleRegistry.json` `sourceWorkbook` -> version-stripped
  base -> Test/Test.json entry by exact or token-boundary prefix match (longest wins).
  This prefix match handles `14_Electricity_Scope2` (source) -> `14_Electricity` (TestExcelFile).
- Conflict winner = config-designated master: module WITHOUT a `renameSheets` entry beats one
  WITH it (rank = (hasRename?1000:0)+configIndex, lower wins; ties = config order). Enteric renames
  'Input - Pasture Beef' so Manure wins shared X_Cell_PastureBeef_* fields AND shared X_Table_*
  tables. Applies to both scalars and InputTables (duplicate TableName keeps winner's copy).
- X_Cell_Site_* overridden by options.commonSheetProviders["Input - Site"] (=ManureManagement_BeefPasture);
  mid-merge site conflicts are suppressed (provider override is authoritative).
- Output: Test/Enterprises/TestInput_Enterprise_<enterprise.id>.json, TAB-indented via custom
  ConvertTo-TabJson (NOT ConvertTo-Json — PS5.1 space quirks), UTF-8 no BOM.
- PastureBeef result: 42 cells, 19 tables.
- Per-module `include` subsetting in the enterprise config is NOT applied to test input (full
  module TestInput merged; extra cells/tables with no enterprise named range are ignored downstream).
