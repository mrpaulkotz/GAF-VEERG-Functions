# Build & Script Instructions

## npm run build

Syncs all `.xlf` files in the repository into the Excel Labs AFE project embedded in every `.xlsx` workbook under `Excel/`.

```powershell
npm run build
```

**What it does:**
1. Runs `scripts/sync-xlf-to-excel-labs.ps1` — reads every `.xlf` file and writes its content into the matching Excel Labs module inside each workbook.
2. Prints a per-workbook summary of which modules were updated (or were already in sync).
3. Workbooks that are open in Excel will be skipped with a warning.

**Dry run** (shows what would change without writing anything):

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

**Single workbook:**

```powershell
npm run build:input-fields -- -WorkbookPath .\Excel\5_Fertiliser_WIP_v07.xlsx
```

**Dry run** (discovers and validates but writes nothing):

```powershell
npm run build:input-fields:dry
```

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

## Notes

- Close the target workbook in Excel before running either command. An open workbook causes a file-lock error and will be skipped.
- `npm run build` does **not** run the expand step. These are separate operations.
- `npm run build` **does** refresh the `*.sourcedata.json` artifacts via `build:source-data`.
- `npm run build` **does** refresh the `InputFields/*_InputFields.json` artifacts via `build:input-fields`.
- `build.cmd` is a thin wrapper that calls `build.ps1` directly and accepts the same arguments.
