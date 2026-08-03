# Build & Script Instructions

## npm run build

Syncs all `.xlf` files in the repository into the Excel Labs AFE project embedded in every `.xlsx` workbook under `Excel/`, and propagates the shared common sheets across all of those workbooks.

```powershell
npm run build
```

**What it does:**
1. Runs `scripts/sync-xlf-to-excel-labs.ps1` — reads every `.xlf` file and writes its content into the matching Excel Labs module inside each workbook.
2. **Propagates the common sheets across all workbooks** — the same script's
   `Sync-CommonSheetsAcrossWorkbooks` step copies the shared common sheets (e.g.
   `Constants - Common`) from their canonical source into every module workbook under
   `Excel/`, so the common data and Excel Labs (`Module.Func`) definitions stay identical
   everywhere. This runs automatically as part of `npm run build`.
3. Prints a per-workbook summary of which modules were updated (or were already in sync).
4. Workbooks that are open in Excel will be skipped with a warning.

Because the common-sheet propagation is built in, invoking
`Sync-CommonSheetsAcrossWorkbooks` as a downstream command to `build.ps1` is a no-op
(it reports that it already ran as part of the build).

**Dry run** (shows what would change — including the common-sheet propagation — without
writing anything):

```powershell
npm run build:dry
```

---

## npm run build:source-data

Converts the VEERG source-data `.xlf` files into canonical, machine-readable JSON
artifacts. The `.xlf` files remain the source of truth; the JSON is a derived build
output so downstream consumers can read the tables directly without parsing the Excel
`LAMBDA` grammar at runtime. This step also runs automatically as part of `npm run build`.

```powershell
npm run build:source-data
```

**What it does:**
1. Reads every `source-data/SourceData_*.xlf` file.
2. Parses each `<Prefix>_Data =LAMBDA(MAKEARRAY(...))` table plus its sibling
   `_Title`, `_Variable`, `_Unit`, `_Source` and `_Variation` metadata LAMBDAs.
3. Writes one `<basename>.sourcedata.json` into the `generated-sourcedata/` directory at
   the repository root.

**Output location:** the JSON is written to `generated-sourcedata/`, e.g.
`generated-sourcedata/SourceData_PastureBeef.sourcedata.json`.

**JSON schema** (`schemaVersion: 1`):

```jsonc
{
  "generatedFrom": "SourceData_PastureBeef.xlf",
  "generatedAt": "2026-06-26T00:00:00Z",
  "schemaVersion": 1,
  "tables": [
    {
      "name": "SourceData_PastureBeef_Liveweight", // the _Data prefix
      "title": "...",      // _Title
      "variable": "Wjkl",  // _Variable
      "unit": "kg",        // _Unit
      "source": "...",     // _Source
      "variation": "",     // _Variation
      "header": ["State", "Region", "Season", "Bull < 1"], // first matrix row
      "rows": [["SA", "...", "Spring", 500], ["QLD", "...", "Winter", "NO"]]
    }
  ]
}
```

**Value typing:** numeric cells become JSON numbers; everything else stays a string.
Sentinel values (`"NO"`, `"n/a"`, `"na"`, `"-"`) mean *not-applicable* and are
preserved verbatim as strings. Scalar `_Data` constants such as `=LAMBDA(0.08)` are not
tables and are skipped.

**Validation:** each table is round-trip checked against the row/column counts declared
in its `MAKEARRAY(<rows>, <cols>)`. A mismatch is reported as a non-fatal warning and the
table is still emitted with its actual parsed data, so one inconsistent source table does
not block the rest of the build.

**Dry run** (parses and validates but writes nothing):

```powershell
npm run build:source-data:dry
```

---

## Source-data overrides

Lets you replace the values of a generated source-data table in a workbook
**without touching the pristine base `_Data` function**. Intended to run against a
**duplicated** workbook (there is no reset/restore).

### Override files

Overrides live in `overrides/<Module>.overrides.json`. The shape mirrors the
generated `generated-sourcedata/*.sourcedata.json`: each key is a base
source-data function name **without** the `_Data` suffix, with `header` + `rows`.

```json
{
  "Overrides": {
    "SourceData_Dairy_LiveweightCowsAndHeifers": {
      "header": ["Breed", "Milking Cows", "Heifers >1", "Heifers <1 (weaned)"],
      "rows": [["Medium Friesian", 999, 888, 155]]
    }
  }
}
```

Only **matrix** source-data tables (header + rows) are supported, matching the
generated JSON contract.

### How it works

For each overridden table the script:

1. Serialises `header` + `rows` into an Excel array `LAMBDA` constant.
2. Upserts a `<name>_Data_Override` function into a dedicated Excel Labs (AFE)
   module `SourceData_Overrides` and republishes so the workbook-scoped name
   `SourceData_Overrides.<name>_Data_Override` exists.
3. Repoints every consuming cell formula from the base dotted call
   `<Module>.<name>_Data(` to `SourceData_Overrides.<name>_Data_Override(`.

Overrides whose base table is not present in the target workbook, or whose
serialised constant exceeds Excel's ~8192-char defined-name limit, are skipped.

### Standalone

```powershell
npm run apply-source-data-overrides -- `
  -WorkbookPath .\Excel\TestExcel\<duplicate>.xlsx `
  -OverridesPath .\overrides\SourceData_Dairy.overrides.json
```

Add `-DryRun` to print the generated module text without modifying the workbook.

### With the test workbook generator

`create-test-excel-from-json.ps1` accepts `-IncludeOverrides` (and optional
`-OverridesDir`, default `overrides/`). After the test workbook is created and
test inputs are injected, every `*.overrides.json` under the overrides directory
is applied to the generated workbook:

```powershell
npm run create-test-excel:overrides -- -TestID 3_3_Enteric_Dairy
```

---

## npm run build:input-fields


Generates JSON descriptions of the user-input fields in the VEERG module workbooks
under `Excel/`. The workbooks remain the source of truth; the JSON is a derived build
output so the bulk-input UI and other consumers can read each module's input schema
without opening Excel. This step also runs automatically as part of `npm run build`.

```powershell
npm run build:input-fields
```

**What it does** (via Excel COM automation, one workbook at a time):
1. Opens every eligible `Excel/*.xlsx` workbook read-only, skipping `~$` lock files and
   `*_expanded` copies.
2. **InputCells** — collects workbook-scoped defined names matching `^X_Cell_` and
   resolves each cell's data-validation into a `CellType` (`number`, `text`, `percent`,
   `formula` or `select`) plus, for dropdowns, an `Options` map. Validation lists are
   resolved from static comma literals, range references, named ranges, and
   `INDIRECT("Table[Column]")` structured-table references (read directly from the
   matching `ListObject` column). **Cascading (dependent) dropdowns** whose validation
   reads `INDIRECT(... SUBSTITUTE($Parent," ","") ...)` are fully resolved: the parent
   cell is recorded as `DependentOn` (following single-cell passthrough formulas to the
   ultimate source defined name), the parent's allowed values are enumerated, and
   `Options` becomes a **nested** map keyed by the space-stripped parent value. A branch
   that resolves to nothing — or only to a literal `n/a` placeholder — collapses to the
   bare string `"n/a"`.
3. **InputTables** — collects both Excel `ListObjects` and **defined names** (named
   ranges) matching `^X_Table_` or `^Table_Input` and describes each as a `MatrixType`
   (`RowsToCols` vs `ColsToRows`), `NumberOfRows` / `NumberOfCols` counts, a
   `ColumnNames` map, and a per-field definition (`CellType`, optional `Unit` parsed from
   the header parenthetical, optional `Options`, and `CanOverWriteFormula`).
   `ColumnNames` is an **ordered object** mapping each column's machine key →
   display label (in column order), for both orientations. The machine key is derived
   from the header text, preserving comparison/range semantics that bare PascalCasing
   would lose: `<` → `Under`, `>` → `Over`, and a numeric `a-b` range → `aTob` (so
   `Bulls < 1 year` → `BullsUnder1Year`, `Cows 1-2 years` → `Cows1To2Years`). For
   `RowsToCols` tables these keys match the field keys under `Rows.Row.*`. For
   `ColsToRows` tables the leading row-label/header column (e.g.
   `Method 1 default values (do not edit)`) is **excluded** from both `ColumnNames` and
   `NumberOfCols`. For
   `X_Table_*` named ranges, population is **position-based**: row 1 is treated as the
   header row and each field carries its 1-based `Row`/`Col` within the range plus a
   `Label` (ColsToRows) or `Header` (RowsToCols). Blank headers/labels never drop a
   field — a positional fallback key (`RowN` / `ColN`) is used instead. A `_Method2`
   segment in the table name marks the whole table as user-overwritable. Named ranges
   that resolve to a single row (header only, no data rows) are reported as a non-fatal
   warning and skipped. The `Cols`/`Rows` container uses a single generic key
   (`Column` for ColsToRows, `Row` for RowsToCols) rather than a value pulled from a cell.
4. Merges a per-field override file `InputFields/_overrides/<Module>.json` over the
   generated result when present, so manual settings survive regeneration.
5. Writes one `<Module>_InputFields.json` per workbook as UTF-8 **without** a BOM.

**Output location:** `InputFields/`, e.g. `InputFields/Fertiliser_InputFields.json`.
The module name is derived from the workbook file name (leading `NN_` ordinals and
trailing `_WIP_v##` / `_v##` suffixes are stripped).

**Formula cells** use the `_Method` naming convention: `*_Method2` cells carry a formula
the user may overwrite (`CanOverWriteFormula: true`), while `*_Method1` cells hold a
protected formula.

**JSON schema** (`schemaVersion: 1`):

```jsonc
{
  "schemaVersion": 1,
  "generatedFrom": "5_Fertiliser_WIP_v07.xlsx",
  "generatedAt": "2026-06-26T00:00:00Z",
  "InputCells": [                       // always an array (empty -> [], never {})
    { "CellName": "X_Cell_Fertiliser_AreaUnderCropping", "CellType": "number" },
    {
      "CellName": "X_Cell_Fertiliser_CropType",
      "CellType": "select",
      "Options": { "Pasture": "Pasture", "Grains": "Grains" }
    },
    {
      "CellName": "X_Cell_PastureBeef_ProductionRegion",
      "CellType": "select",
      "DependentOn": "X_Cell_Site_State",     // cascading dropdown
      "Options": {                            // keyed by space-stripped parent value
        "Queensland": { "High": "High", "Low": "Low" },
        "NewSouthWales": "n/a"                // bare string when the branch is empty
      }
    }
  ],
  "InputTables": [
    {
      "TableName": "Table_Input_OrganicFertiliser",
      "MatrixType": "RowsToCols",       // or "ColsToRows" for period-keyed tables
      "NumberOfCols": 7,
      "ColumnNames": {                  // machineKey -> display label (keys match Rows.Row.*)
        "OrganicFertiliserType": "Organic fertiliser type (select)",
        "AmountApplied": "Amount applied (kg/hectare)"
      },
      "Rows": {
        "Row": {
          "OrganicFertiliserType": { "CellType": "select", "Options": { "...": "..." } },
          "AmountApplied": { "CellType": "number", "Unit": "kg/hectare" },
          "ApplicationArea": { "CellType": "formula", "Unit": "ha" }
        }
      }
    },
    {
      "TableName": "X_Table_Poultry_Movement",   // X_Table_* named range
      "MatrixType": "ColsToRows",
      "NumberOfRows": 3,
      "NumberOfCols": 4,                  // leading row-label column excluded
      "ColumnNames": {                    // class axis: machineKey -> display label
        "Layers": "Layers",
        "MeatChickenGrowers": "Meat chicken growers"
      },
      "Cols": {
        "Column": {
          "AverageDurationOfStay": {
            "CellType": "number", "Row": 2, "Col": 2,
            "Label": "Average duration of stay between 01 Jan 24 and 31 Dec 24"
          }
        }
      }
    }
  ]
}
```

**Overrides:** drop a hand-maintained `InputFields/_overrides/<Module>.json` to correct or
annotate individual fields; it is merged over the generated output on every run and is
never regenerated. The file is keyed by field identity, so only the fields you name are
touched (everything else comes straight from Excel):

```jsonc
{
  "_comment": "Top-level keys starting with '_' are ignored (use them for notes/schema).",
  "InputCells": {
    "<CellName>": { "Label": "...", "Group": "...", "Order": 0, "Hidden": false, "Default": "..." }
  },
  "InputTables": {
    "<TableName>": {
      "Label": "...",
      "Columns": { "<ColumnKey>": { "Label": "...", "Default": "..." } }
    }
  }
}
```

Each override object's properties are applied onto the matching field (added if absent,
replaced if present), so you can inject app-specific metadata (label text, grouping,
visibility, default values, ...) or override a generated property such as `CellType`.
References to unknown cells/tables/columns are reported as non-fatal warnings.

**Validation:** unresolvable validation lists are reported as non-fatal warnings and the
field is still emitted (with empty `Options`), so one problematic dropdown does not block
the rest of the build. Close the target workbook in Excel before running — an open
workbook causes a file-lock error.

**`Duplicate input cell/table name` warnings (enterprise workbooks):** these come from
sheet-scoped *shadow* copies of workbook-scoped `X_Cell_*`/`X_Table_*` names that Excel
creates when module sheets are copied into an enterprise book (one per sheet plus the
real workbook-scoped name — visible in Name Manager). The builder collapses the `Sheet!`
scope prefix, so each shadow looks like a duplicate. Clean them out of the enterprise
workbook (no full rebuild) with:

```powershell
npm run prune-enterprise-names -- -EnterpriseId Dairy
npm run prune-enterprise-names -- -EnterpriseId PastureBeef
```

Run with no `-EnterpriseId` to prune every enterprise, or add `-DryRun` to preview. Then
re-run `npm run build:input-fields` and the warnings are gone.

**Single workbook:**

```powershell
npm run build:input-fields -- -WorkbookPath .\Excel\5_Fertiliser_WIP_v07.xlsx
```

**Dry run** (discovers and validates but writes nothing):

```powershell
npm run build:input-fields:dry
```

---

## npm run create-test-excel

Generates a ready-to-run **test workbook** for a single module by copying its source
workbook, injecting the module's canned test inputs, and saving a timestamped copy under
`Excel/TestExcel/`. Driven by the test registry in `Test/Test.json`.

```powershell
npm run create-test-excel -- -TestID 13_Scope3
```

> The `--` is required so npm forwards `-TestID` to the script. The parameter name is
> `-TestID` (case-insensitive); the value is the `TestID` of an entry in `Test/Test.json`
> (e.g. `13_Scope3`, `3_1_Enteric_Feedlot`, `Enterprise_PastureBeef`).

**Scenarios:** a `TestInputFile` may hold several named input sets under a top-level
`Scenarios` array instead of a single flat object. Each scenario carries a `ScenarioName`
plus the same `X_Cell_*` fields and optional `InputTables`:

```jsonc
{
  "Scenarios": [
    {
      "ScenarioName": "Scenario 1",
      "X_Cell_Site_FarmName": "My test farm",
      "InputTables": [
        { "TableName": "X_Table_Blah", "MatrixType": "ColsToRows" }
      ]
    }
  ]
}
```

Select one with `-ScenarioName`; if omitted, the **first** scenario is used. The chosen
scenario name is added to the output file name so scenarios don't collide.

```powershell
npm run create-test-excel -- -TestID 13_Scope3 -ScenarioName "Scenario 1"
```

Input files with no `Scenarios` key keep their existing flat behaviour.

**What it does:**
1. Reads `Test/Test.json` and finds the entry whose `TestID` matches (searched
   recursively, so nested groups like `EntericMethane > Feedlot` work).
2. Locates the newest source workbook under `Excel/` whose file name contains the entry's
   `TestExcelFile` needle (optionally scoped to `TestExcelDirectory`, e.g. `Enterprises`).
   Files with `Template` or `bak` in the name, `~$` lock files, `_expanded` copies, and
   previously generated `_test` workbooks are excluded from selection.
3. Copies that workbook to `Excel/TestExcel/<name>_test_<timestamp>.xlsx` (a
   `_<ScenarioName>` tag is inserted before the timestamp when a scenario is selected).
4. Injects the inputs from the entry's `TestInputFile` into the copy (in `Test` context,
   every targeted input cell is written, including protected formula cells).
5. Optionally applies source-data overrides (see below).

**Output location:** `Excel/TestExcel/`, e.g.
`Excel/TestExcel/13_Scope3_WIP_v13_test_<timestamp>.xlsx`.

**Test registry (`Test/Test.json`):** each entry provides:

| Field | Purpose |
|---|---|
| `TestID` | Unique id passed via `-TestID`. |
| `TestExcelFile` | Substring matched against source workbook file names. |
| `TestExcelDirectory` | *(optional)* subfolder under `Excel/` to scope the search (e.g. `Enterprises`). |
| `TestInputFile` | JSON of input values injected into the copy. |
| `TestResultsFile` | Expected results (used by result-comparison tooling). |

**With source-data overrides:** add `-IncludeOverrides` (optional `-OverridesDir`,
default `overrides/`) to apply every `*.overrides.json` to the generated workbook after
inputs are injected:

```powershell
npm run create-test-excel:overrides -- -TestID 3_3_Enteric_Dairy
```

**Notes:**
- Close the source workbook in Excel before running — an open workbook causes a file-lock error.
- Each run creates a new timestamped copy; it never overwrites a previous test workbook.

---

## npm run expand-lambda-functions

Expands VEERG LAMBDA references in a workbook, producing a new `_expanded` copy alongside the source file.

**Single workbook:**

```powershell
npm run expand-lambda-functions -- .\Excel\YourWorkbook.xlsx
```

The output is saved next to the source as `YourWorkbook_expanded.xlsx`.

**All workbooks under `Excel/` at once** (excluding `Old/` subfolders and files already named `_expanded`):

```powershell
npm run expand-lambda-functions:auto
```

**Variants:**

| Command | Description |
|---|---|
| `npm run expand-lambda-functions -- <path>` | Expand a single workbook |
| `npm run expand-lambda-functions:auto` | Expand all workbooks |
| `npm run expand-lambda-functions:dry -- <path>` | Dry run — single workbook, no file written |
| `npm run expand-lambda-functions:auto:dry` | Dry run — all workbooks, no files written |
| `npm run expand-lambda-functions:debug -- <path>` | Single workbook with extra debug output on failed writes |

---

## npm run apply-names

Rewrites cell/range references in formulas to use an existing **defined name**
instead of the raw address — the equivalent of Excel's built-in **Apply Names**
feature, but it also rewrites **cross-sheet** references (Excel's built-in only
handles same-sheet ones).

```powershell
npm run apply-names
```

**What it does (per workbook):**
1. Enumerates every **workbook-scoped** defined name whose `RefersTo` is a plain
   single-sheet cell or contiguous range (e.g. `='Constants'!$G$5` or
   `='Data'!$D$83:$H$140`). Names that refer to formulas/`LAMBDA`s, unions,
   external workbooks, `#REF!` errors or Excel built-ins (`Print_Area`, …) are
   skipped.
2. Rewrites every reference to that cell/range — same-sheet or cross-sheet,
   qualified or bare, pure or embedded — to use the name. Single-cell range
   endpoints (address adjacent to `:`) are left alone so multi-cell ranges are
   not partially rewritten.

Runs on **all** top-level `Excel/*.xlsx` by default (skips lock files,
`*_expanded*` and `*.bak` backups). Pass `-WorkbookPath` to target one workbook,
or `-NamePattern` (regex, default `.`) to restrict which names are applied.

**Dry run is the default** — proposed rewrites are reported as `old -> new` but
nothing is written. To apply and save (add `-Backup` to first write a one-time
copy under `Excel/Backups/Backup_PreApply/`):

```powershell
npm run apply-names:commit
```

**Variants:**

| Command | Description |
|---|---|
| `npm run apply-names` | Dry run — all workbooks, report only |
| `npm run apply-names -- -WorkbookPath <path>` | Dry run — single workbook |
| `npm run apply-names:commit` | Apply and save (all workbooks) |
| `npm run apply-names:commit -- -WorkbookPath <path>` | Apply and save — single workbook |

> Related: `npm run name-constants` (`scripts/name-sourcedata-constants.ps1`)
> *creates* workbook-scoped names for scalar `*_Data` constant cells (both
> `SourceData_*_Data` and module-prefixed constants like
> `Fertiliser_FracGASMSoil_Data`) and applies them. Run it first to create
> names, then `apply-names` to propagate all existing names broadly. Backups are
> off by default here too; pass `-Backup` for a one-time copy under
> `Excel/Backups/Backup_PreName/`.

---

## npm run audit-names

Standalone **defined-name hygiene** audit. Scans every defined name in each
workbook and reports issues; optionally deletes the clearly-safe cruft. Run it
whenever you like — e.g. after `npm run build-enterprise`.

```powershell
npm run audit-names
```

**Issue categories:**

| Category | Meaning | Action on `:commit` |
|---|---|---|
| `dangling` | Plain reference that resolves to an Excel error, e.g. `=#REF!#REF!`, `=#NAME?` — leftover cruft | **Deleted** |
| `broken-fn` | A `LAMBDA`/formula name that *contains* a broken internal reference (a real Excel-Labs function maintained in the `.xlf` source) | Kept — reported only |
| `external` | A plain reference to another workbook **file**, e.g. `=[Book.xlsx]Sheet!$A$1` | Deleted only with `-RemoveExternal` |
| `empty` | Blank `RefersTo` | Kept — reported only |
| `hidden` | `Name.Visible = False` (often import/add-in cruft) | Deleted only with `-RemoveHidden` |
| `dup` | Two or more names pointing at the **same** target cell/range | Kept — reported only |

Excel-internal names (anything with the reserved `_xl` prefix — `_xlpm.*`,
`_xlop.*` `LAMBDA` parameter placeholders, `_xlfn.*`/`_xlws.*` shims,
`_xlnm.*` built-ins) are ignored. Any formulas that reference a name about to be
deleted are reported first so you can see the impact.

Runs on **all** top-level `Excel/*.xlsx` by default (skips lock files,
`*_expanded*` and `*.bak` backups). Pass `-WorkbookPath` to target one workbook.

**Dry run is the default** — issues are reported but nothing is written. To apply
deletions and save (add `-Backup` to first write a one-time copy under
`Excel/Backups/Backup_PreAudit/`):

```powershell
npm run audit-names:commit
```

**Variants:**

| Command | Description |
|---|---|
| `npm run audit-names` | Dry run — all workbooks, report only |
| `npm run audit-names -- -WorkbookPath <path>` | Dry run — single workbook |
| `npm run audit-names:commit` | Delete `dangling` names and save |
| `npm run audit-names:commit -- -RemoveExternal -RemoveHidden` | Also delete `external` and `hidden` names |

---

## npm run find-errors

One read-only checker that scans every workbook and reports remaining errors in a
single place. It reads the `.xlsx` package XML directly — no Excel, no COM, no
add-in — so it is fast and never produces the false `#NAME?` a headless recalc
would (VEERG.* LAMBDAs only resolve with the Excel Labs add-in loaded). It reports
whatever was last computed and saved into the file:

- **`[cell]`** — cells whose cached value is an Excel error (`#REF!`, `#NAME?`,
  `#VALUE!`, `#DIV/0!`, `#N/A`, `#NULL!`, `#NUM!`, `#SPILL!`, `#CALC!`), with the
  sheet, address, error token and stored formula. Cells carrying a `vm`
  (value-metadata) pointer are **skipped**: those are rich values — a modern
  "Place in Cell" image (e.g. the logo pasted into `A1` on most sheets), a linked
  data type, etc. — whose `#VALUE!` is only the fallback text for clients that
  can't render them, not a real error.
- **`[name]`** — defined names whose RefersTo contains an error token (`dangling`
  plain ref) or is empty. The `.xlf`-maintained library LAMBDAs that carry an
  internal `#REF!` (`broken-fn`) are **hidden by default** as known noise; pass
  `-IncludeLibraryFunctions` to list them too.
- **`[link]`** — leftover external links to other workbook files.

```
npm run find-errors
```

Scans `Excel/*.xlsx` and `Excel/Enterprises/*.xlsx` (excluding lock files,
`*_expanded*`, `*_template*` and `*.bak`).

**Variants:**

| Command | Description |
|---|---|
| `npm run find-errors` | Scan all workbooks; list up to 50 per category each |
| `npm run find-errors -- -WorkbookPath <path>` | Scan a single workbook |
| `npm run find-errors -- -Max 0` | List every finding (no per-category cap) |
| `npm run find-errors -- -IncludeLibraryFunctions` | Also list the `broken-fn` `.xlf` library LAMBDAs |
| `npm run find-errors -- -FailOnError` | Exit code 1 if any `[cell]` or `[name]` error is found (CI gate) |

> **Cached-value caveat:** cell errors reflect the values Excel last *saved*. A
> workbook that a build touched but that has not since been opened in Excel *with
> the add-in* and recalculated may show stale `#NAME?`/`#VALUE!` that clear on the
> next real recalc. `broken-fn` names are the `.xlf`-maintained library LAMBDAs
> with internal `#REF!` (hidden unless `-IncludeLibraryFunctions`, and never the
> target of automated deletion); `dangling` names are cruft that
> `npm run audit-names:commit` removes.

---

## Notes

- Close the target workbook in Excel before running either command. An open workbook causes a file-lock error and will be skipped.
- `npm run build` does **not** run the expand step. These are separate operations.
- `npm run build` **does** refresh the `*.sourcedata.json` artifacts via `build:source-data`.
- `npm run build` **does** refresh the `InputFields/*_InputFields.json` artifacts via `build:input-fields`.
- `apply-names` and `audit-names` are **on-demand** maintenance tasks — they are *not* part of `npm run build`. Both default to a dry run and only write when invoked with `:commit`. Backups are **off by default** (commit regularly instead); pass `-Backup` to write a one-time copy under `Excel/Backups/Backup_PreApply/` / `Excel/Backups/Backup_PreAudit/` before saving. Any `*.bak` files are ignored by the workbook-discovery step.
- `build.cmd` is a thin wrapper that calls `build.ps1` directly and accepts the same arguments.
