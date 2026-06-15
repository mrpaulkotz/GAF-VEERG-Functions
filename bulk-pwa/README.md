# Bulk PWA

Single-page Progressive Web App for bulk VEERG test input processing.

## What it does

1. Upload one manifest JSON using the same structure as Test/Test.json.
2. Upload either:
- multiple input JSON files, or
- one ZIP containing input JSON files.
3. Validate that manifest TestInputFile entries match uploaded input files.
4. Copy matching source workbooks into Excel/Batch processing/<timestamp>.
5. Populate named input cells and InputTables from each input JSON.
6. Recalculate workbook and read named result cells from each TestResults file mapping.
7. Show results in the page and provide workbook + ZIP downloads.

## Run

From bulk-pwa:

powershell
npm install
npm run build
npm start

Open http://localhost:5173

## Key files

- src/client/app.ts: Browser UI logic.
- src/server/server.ts: Upload API, validation, processor orchestration, downloads.
- public/index.html: One-page app shell.
- public/sw.js: Service worker cache for app shell.
- ../scripts/process-bulk-input-data.ps1: Excel COM bulk processor.
