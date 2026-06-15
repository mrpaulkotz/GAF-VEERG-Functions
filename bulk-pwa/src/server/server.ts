import express, { Request, Response } from 'express';
import multer from 'multer';
import AdmZip from 'adm-zip';
const archiver = require('archiver') as (format: string, options: unknown) => {
  on: (event: string, cb: (...args: unknown[]) => void) => void;
  pipe: (dest: NodeJS.WritableStream) => void;
  directory: (source: string, destination: false | string) => void;
  finalize: () => Promise<void>;
};
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

type ManifestEntry = {
  TestID: string;
  TestExcelFile: string;
  TestInputFile: string;
  TestResultsFile?: string;
};

type ProcessItem = {
  TestID: string;
  SourceWorkbook: string;
  InputFileUsed: string;
  CreatedWorkbookPath: string;
  CreatedWorkbookRelativePath: string;
  CreatedWorkbookFileName: string;
  Results: Record<string, number | string | null>;
};

type ProcessScriptResult = {
  RunStamp: string;
  OutputDirectory: string;
  OutputDirectoryRelativePath: string;
  Items: ProcessItem[];
  ValidationWarnings: string[];
};

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const appRoot = path.join(repoRoot, 'bulk-pwa');
const publicRoot = path.join(appRoot, 'public');
const runtimeRoot = path.join(appRoot, 'runtime');
const runtimeUploadsRoot = path.join(runtimeRoot, 'uploads');
const runtimeDownloadsRoot = path.join(runtimeRoot, 'downloads');
const outputRoot = path.join(repoRoot, 'Excel', 'Batch processing');
const scriptPath = path.join(repoRoot, 'scripts', 'process-bulk-input-data.ps1');

for (const dir of [runtimeRoot, runtimeUploadsRoot, runtimeDownloadsRoot, outputRoot]) {
  fs.mkdirSync(dir, { recursive: true });
}

const app = express();
app.use(express.static(publicRoot));

const upload = multer({
  storage: multer.diskStorage({
    destination: (req, _file, cb) => {
      const jobId = String(req.headers['x-job-id'] ?? `${Date.now()}_${Math.floor(Math.random() * 10000)}`);
      const dir = path.join(runtimeUploadsRoot, jobId);
      fs.mkdirSync(dir, { recursive: true });
      cb(null, dir);
    },
    filename: (_req, file, cb) => {
      cb(null, file.originalname);
    }
  })
});

function collectJsonFiles(rootDir: string): string[] {
  const results: string[] = [];
  const queue: string[] = [rootDir];

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current) {
      continue;
    }

    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        queue.push(fullPath);
      } else if (entry.isFile() && path.extname(entry.name).toLowerCase() === '.json') {
        results.push(fullPath);
      }
    }
  }

  return results;
}

function flattenManifestEntries(node: unknown, entries: ManifestEntry[]): void {
  if (!node || typeof node !== 'object') {
    return;
  }

  const obj = node as Record<string, unknown>;
  const hasRequired =
    typeof obj.TestID === 'string' &&
    typeof obj.TestExcelFile === 'string' &&
    typeof obj.TestInputFile === 'string';

  if (hasRequired) {
    entries.push({
      TestID: obj.TestID as string,
      TestExcelFile: obj.TestExcelFile as string,
      TestInputFile: obj.TestInputFile as string,
      TestResultsFile: typeof obj.TestResultsFile === 'string' ? obj.TestResultsFile : undefined
    });
  }

  for (const value of Object.values(obj)) {
    flattenManifestEntries(value, entries);
  }
}

function stripBom(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function formatBatchStamp(date: Date): string {
  const hours = String(date.getHours()).padStart(2, '0');
  const minutes = String(date.getMinutes()).padStart(2, '0');
  const year = String(date.getFullYear());
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${hours}${minutes}_${year}${month}${day}`;
}

function ensureInside(baseDir: string, candidatePath: string): string {
  const resolvedBase = path.resolve(baseDir);
  const resolvedPath = path.resolve(candidatePath);
  if (!resolvedPath.toLowerCase().startsWith(resolvedBase.toLowerCase())) {
    throw new Error('Invalid path.');
  }
  return resolvedPath;
}

function createZipFromDirectory(sourceDir: string, destinationZip: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(destinationZip);
    const archive = archiver('zip', { zlib: { level: 9 } });

    output.on('close', () => resolve());
    archive.on('error', (err: unknown) => reject(err));

    archive.pipe(output);
    archive.directory(sourceDir, false);
    archive.finalize().catch(reject);
  });
}

function runBulkProcessor(args: {
  manifestPath: string;
  inputRoot: string;
  resultPath: string;
  runStamp: string;
}): Promise<void> {
  return new Promise((resolve, reject) => {
    const psArgs = [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-RepoRoot',
      repoRoot,
      '-ManifestPath',
      args.manifestPath,
      '-InputRoot',
      args.inputRoot,
      '-OutputRoot',
      outputRoot,
      '-RunStamp',
      args.runStamp,
      '-ResultJsonPath',
      args.resultPath
    ];

    const child = spawn('powershell', psArgs, { cwd: repoRoot });
    let stdErr = '';

    child.stderr.on('data', (chunk: Buffer) => {
      stdErr += chunk.toString();
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(stdErr || `Bulk processing failed with exit code ${code}.`));
      }
    });
  });
}

app.post(
  '/api/process-bulk-input',
  upload.fields([
    { name: 'manifest', maxCount: 1 },
    { name: 'inputFiles', maxCount: 100 }
  ]),
  async (req: Request, res: Response) => {
    try {
      const filesByField = req.files as Record<string, Express.Multer.File[]>;
      const manifest = filesByField?.manifest?.[0];
      const inputFiles = filesByField?.inputFiles ?? [];

      if (!manifest) {
        res.status(400).send('Manifest JSON file is required.');
        return;
      }

      if (inputFiles.length === 0) {
        res.status(400).send('At least one input JSON or ZIP file is required.');
        return;
      }

      const jobDir = path.dirname(manifest.path);
      const extractedDir = path.join(jobDir, 'extracted');
      const consolidatedInputDir = path.join(jobDir, 'inputs');
      fs.mkdirSync(extractedDir, { recursive: true });
      fs.mkdirSync(consolidatedInputDir, { recursive: true });

      const manifestRaw = fs.readFileSync(manifest.path, 'utf8');
      const manifestJson = JSON.parse(stripBom(manifestRaw)) as unknown;
      const manifestEntries: ManifestEntry[] = [];
      flattenManifestEntries(manifestJson, manifestEntries);

      if (manifestEntries.length === 0) {
        res.status(400).send('Manifest file contains no entries with TestID/TestExcelFile/TestInputFile.');
        return;
      }

      const uploadedJsonByBasename = new Map<string, string>();
      const warnings: string[] = [];

      for (const file of inputFiles) {
        const ext = path.extname(file.originalname).toLowerCase();

        if (ext === '.zip') {
          const zipTarget = path.join(extractedDir, path.basename(file.originalname, ext));
          fs.mkdirSync(zipTarget, { recursive: true });
          const zip = new AdmZip(file.path);
          zip.extractAllTo(zipTarget, true);

          for (const jsonPath of collectJsonFiles(zipTarget)) {
            const basename = path.basename(jsonPath).toLowerCase();
            if (uploadedJsonByBasename.has(basename)) {
              warnings.push(`Duplicate JSON basename ignored: ${path.basename(jsonPath)}`);
              continue;
            }
            const destination = path.join(consolidatedInputDir, path.basename(jsonPath));
            fs.copyFileSync(jsonPath, destination);
            uploadedJsonByBasename.set(basename, destination);
          }
          continue;
        }

        if (ext === '.json') {
          const basename = path.basename(file.originalname).toLowerCase();
          if (uploadedJsonByBasename.has(basename)) {
            warnings.push(`Duplicate JSON basename ignored: ${file.originalname}`);
            continue;
          }

          const destination = path.join(consolidatedInputDir, path.basename(file.originalname));
          fs.copyFileSync(file.path, destination);
          uploadedJsonByBasename.set(basename, destination);
        }
      }

      const missing = manifestEntries
        .map((entry) => entry.TestInputFile)
        .filter((testInputPath) => !uploadedJsonByBasename.has(path.basename(testInputPath).toLowerCase()));

      if (missing.length > 0) {
        res.status(400).send(`Manifest input files do not match uploaded files. Missing: ${missing.join(', ')}`);
        return;
      }

      const runStamp = formatBatchStamp(new Date());
      const resultPath = path.join(jobDir, 'bulk-process-result.json');

      await runBulkProcessor({
        manifestPath: manifest.path,
        inputRoot: consolidatedInputDir,
        resultPath,
        runStamp
      });

      const resultRaw = fs.readFileSync(resultPath, 'utf8');
      const rawResult = JSON.parse(stripBom(resultRaw)) as ProcessScriptResult;
      const zipFileName = `${rawResult.RunStamp}.zip`;
      const zipOutputPath = path.join(runtimeDownloadsRoot, zipFileName);
      await createZipFromDirectory(rawResult.OutputDirectory, zipOutputPath);

      const responsePayload = {
        runStamp: rawResult.RunStamp,
        outputDirectoryRelativePath: rawResult.OutputDirectoryRelativePath.replace(/\\/g, '/').replace(/\/+/g, '/'),
        zipFileName,
        items: rawResult.Items.map((item) => ({
          testId: item.TestID,
          sourceWorkbook: item.SourceWorkbook,
          inputFileUsed: item.InputFileUsed,
          createdWorkbookRelativePath: item.CreatedWorkbookRelativePath.replace(/\\/g, '/').replace(/\/+/g, '/'),
          createdWorkbookFileName: item.CreatedWorkbookFileName,
          results: item.Results
        })),
        validationWarnings: [...rawResult.ValidationWarnings, ...warnings]
      };

      res.json(responsePayload);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Unhandled processing error.';
      res.status(500).send(message);
    }
  }
);

app.get('/api/download/:relativePath(*)', (req: Request, res: Response) => {
  try {
    const rel = req.params.relativePath;
    if (!rel) {
      res.status(400).send('Missing path.');
      return;
    }

    const absPath = ensureInside(repoRoot, path.join(repoRoot, rel));
    if (!fs.existsSync(absPath)) {
      res.status(404).send('File not found.');
      return;
    }

    res.download(absPath);
  } catch {
    res.status(400).send('Invalid file path.');
  }
});

app.get('/api/download-zip/:zipFileName', (req: Request, res: Response) => {
  try {
    const zipFileName = path.basename(req.params.zipFileName);
    const absPath = ensureInside(runtimeDownloadsRoot, path.join(runtimeDownloadsRoot, zipFileName));

    if (!fs.existsSync(absPath)) {
      res.status(404).send('ZIP not found.');
      return;
    }

    res.download(absPath);
  } catch {
    res.status(400).send('Invalid ZIP path.');
  }
});

app.get('*', (_req: Request, res: Response) => {
  res.sendFile(path.join(publicRoot, 'index.html'));
});

const port = Number(process.env.PORT ?? 5173);
app.listen(port, () => {
  console.log(`Bulk PWA server listening on http://localhost:${port}`);
});
