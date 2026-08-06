# scripts/apply-names.ps1 (one-off maintenance)

General "Apply Names" — Excel's built-in feature but cross-sheet aware. Rewrites
cell/range references in formulas to use EXISTING workbook-scoped defined names.

- npm: `apply-names` (dry-run, default) / `apply-names:commit` (writes).
- Params: `-WorkbookPath <file>` (single) else ALL top-level `Excel/*.xlsx`
  (skips `~$*`, `*_expanded*`, and any `.bak`).
  `-NamePattern` (regex vs the name, default `.` = all). `-Commit`. `-Backup`
  (OFF by default; when set, one-time copy to `Excel/Backups/Backup_PreApply/`).
- Only WORKBOOK-SCOPED names (skips sheet-local `Sheet!Name`, `_xlnm`/Print_Area/
  Print_Titles/_FilterDatabase). Only names whose RefersTo is a plain single-sheet
  cell or contiguous range (`='Sheet'!$A$1` or `='Sheet'!$A$1:$H$140`); LAMBDA /
  constant / union(comma) / external `[wb]` / `#REF!` names are skipped.
- Reuses the proven regex rewrite approach from name-sourcedata-constants.ps1:
  Qual ref (any host sheet) + Bare same-sheet ref; single-cell range endpoints
  (adjacent to `:`) conservatively skipped; the defining cell's own formula is
  never rewritten to reference itself.

## Relationship to name-sourcedata-constants.ps1
- name-sourcedata-constants CREATES names for `SourceData_*_Data` scalar cells AND
  applies them. apply-names does NOT create names — it applies ALL existing ones.
  Run name-constants first (to create), then apply-names (to propagate broadly).

## Validated
Dry-run on 10_SolidWaste backup: 7 plain names applied, 392 skipped (LAMBDAs/#REF!),
0 rewrites (that file was already named). Script parses clean, no errors.
