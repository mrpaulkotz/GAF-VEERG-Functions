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
- `build.cmd` is a thin wrapper that calls `build.ps1` directly and accepts the same arguments.
