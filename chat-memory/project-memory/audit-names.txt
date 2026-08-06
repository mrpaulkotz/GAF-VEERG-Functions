# scripts/audit-names.ps1 (standalone name-hygiene audit)

Standalone maintenance script (run any time, e.g. after `build-enterprise`).
Supersedes the earlier remove-broken-names.ps1 (that file was deleted).
Audits every defined name in Excel/*.xlsx and categorises issues.

- npm: `audit-names` (dry-run) / `audit-names:commit` (deletes + saves).
- Params: `-WorkbookPath <file>` else ALL top-level `Excel/*.xlsx` (skips `~$*`,
  `*_expanded*`, and any `.bak`). `-Commit`, `-RemoveExternal`, `-RemoveHidden`,
  `-Backup` (OFF by default; when set, one-time copy to `Excel/Backups/Backup_PreAudit/`).

## Categories
- `dangling`  : plain ref (no `(`) that is an Excel error (`=#REF!#REF!`, `=#NAME?`).
                DELETED on -Commit (safe cruft).
- `broken-fn` : RefersTo contains `(` AND an error -> real Excel-Labs LAMBDA with
                broken INTERNAL refs (maintained in .xlf). KEPT, report only.
- `external`  : plain ref to another workbook FILE (`\[[^\]]*\.xls[a-z]{0,2}\]`).
                Report; deleted only with -RemoveExternal.
- `empty`     : blank RefersTo. Report only.
- `hidden`    : Name.Visible=False. Report; deleted only with -RemoveHidden.
- `dup`       : >1 name sharing the same (non-error, non-formula) target. Report only.

## CRITICAL gotchas (learned from dry-runs)
- EXCLUDE Excel-internal names: any name matching `^_xl` (case-insensitive).
  Engine-managed: `_xlpm.*` (LAMBDA param), `_xlop.*` (optional param),
  `_xlfn.*`/`_xlws.*` (function shims), `_xlnm.*` (Print_Area builtins). They
  legitimately show `=#NAME?`; deleting them is wrong.
- External detection must require a NON-formula ref to a `.xls*` file. Square
  brackets inside a formula are LAMBDA optional params `[Arg]`, string literals
  `[1, p. 11]`, or table refs `Table[Col]` — NOT external links.
- Error regex covers #REF!/#NAME?/#DIV0/#VALUE!/#N/A/#NULL!/#NUM!/#SPILL!/#CALC!/etc.

## Validated
Dry-run 10_SolidWaste_WIP_v02.xlsx: dangling=17, broken-fn=10, external=0,
empty=0, hidden=0, dup=0. Grand-total line reports delete-candidates in dry-run,
actual deletions on commit. Reports [used] formulas referencing a to-be-deleted name.
