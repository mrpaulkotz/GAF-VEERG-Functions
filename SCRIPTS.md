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
- `build.cmd` is a thin wrapper that calls `build.ps1` directly and accepts the same arguments.
