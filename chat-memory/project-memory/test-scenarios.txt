# Test scenarios (create-test-excel-from-json.ps1)

TestInput and TestResults JSON files may hold multiple named scenarios under a
top-level `Scenarios` array. Each scenario has `ScenarioName` + flat fields
(X_Cell_* for inputs / result-cell names for results) + optional `InputTables`.

## Invocation
`npm run create-test-excel -- -TestID <id> -ScenarioName "Scenario 2"`
- `-ScenarioName` param selects by name (case-insensitive). Omit => first scenario.
- Output filename gets a sanitized `_<ScenarioName>` tag before the timestamp so
  scenarios don't collide.
- Files with NO `Scenarios` key keep the old flat behaviour (backward compatible).

## Delta-merge (key behaviour)
- The FIRST scenario is the full "default". Any LATER scenario inherits from it
  and needs to list only what it changes.
- Cells: omitted X_Cell_* inherited from scenario[0]; included ones override.
- Tables matched by `TableName`: omitted tables inherited whole; an included
  table deep-merges by column/field (Cols/Rows). New TableName => appended.
- scenario[0] is deep-cloned before merge (never mutated).
- Applies to BOTH inputs and results (same Select-ScenarioObject helper).

## Implementation (scripts/create-test-excel-from-json.ps1)
- Helpers near line ~148: Copy-JsonObject (JSON round-trip clone), Set-ObjProp,
  Merge-ColumnMap, Merge-InputTables (by TableName), Merge-ScenarioOnDefault,
  Select-ScenarioObject (does the merge for non-first selections).
- Results scenario matched by explicit -ScenarioName else the input's resolved
  name. Results loop skips keys `ScenarioName`/`Scenarios`; `$skipJsonKeys`
  (input loop) also includes both.
- Docs: SCRIPTS.md "## npm run create-test-excel" section covers scenarios.

## Gotchas
- PS 5.1: `if(...){}else{}` works as an assignment expression, but NOT inside a
  string/`-f` argument position (throws "term 'if' is not recognized"). Compute
  into a variable first (e.g. $scenarioDisplay).
