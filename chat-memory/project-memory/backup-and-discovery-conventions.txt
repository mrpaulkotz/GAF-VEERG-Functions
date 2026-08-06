# Backup + workbook-discovery conventions

- Backups are OPT-IN via a `-Backup` switch (default OFF) on each script
  (name-constants, apply-names, audit-names, name-table-ranges). User commits
  regularly so rarely needs them. Only create a backup when -Backup is set.
- When -Backup is set, backups go under a Backups dir beside the workbook, in a
  per-operation subdir: `<workbookParent>/Backups/Backup_<Round>/<originalName>.xlsx`.
  Rounds: PreName (name-constants), PreApply (apply-names), PreAudit (audit-names),
  PreTableRanges (name-table-ranges). Keep the one-time guard (only copy if the
  target backup file doesn't already exist).
- Workbook discovery (Get-TargetWorkbooks) must EXCLUDE `.bak` files:
  `$_.Name -notmatch '(?i)\.bak'` (in addition to `~$*` and `_expanded`).
  Backups subdir is not recursed so its files aren't picked up, but the
  `.bak` filter also covers stray legacy `*.prename.bak.xlsx` in Excel/ root.
- Legacy backups still in Excel/ root from earlier runs: `*.prename.bak.xlsx`,
  `*.preapply.bak.xlsx`, `*.preaudit.bak.xlsx` — safe to move into Backups/.
