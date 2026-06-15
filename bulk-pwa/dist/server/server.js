"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const multer_1 = __importDefault(require("multer"));
const adm_zip_1 = __importDefault(require("adm-zip"));
const archiver = require('archiver');
const node_fs_1 = __importDefault(require("node:fs"));
const node_path_1 = __importDefault(require("node:path"));
const node_child_process_1 = require("node:child_process");
const repoRoot = node_path_1.default.resolve(__dirname, '..', '..', '..');
const appRoot = node_path_1.default.join(repoRoot, 'bulk-pwa');
const publicRoot = node_path_1.default.join(appRoot, 'public');
const runtimeRoot = node_path_1.default.join(appRoot, 'runtime');
const runtimeUploadsRoot = node_path_1.default.join(runtimeRoot, 'uploads');
const runtimeDownloadsRoot = node_path_1.default.join(runtimeRoot, 'downloads');
const outputRoot = node_path_1.default.join(repoRoot, 'Excel', 'Batch processing');
const scriptPath = node_path_1.default.join(repoRoot, 'scripts', 'process-bulk-input-data.ps1');
for (const dir of [runtimeRoot, runtimeUploadsRoot, runtimeDownloadsRoot, outputRoot]) {
    node_fs_1.default.mkdirSync(dir, { recursive: true });
}
const app = (0, express_1.default)();
app.use(express_1.default.static(publicRoot));
const upload = (0, multer_1.default)({
    storage: multer_1.default.diskStorage({
        destination: (req, _file, cb) => {
            const jobId = String(req.headers['x-job-id'] ?? `${Date.now()}_${Math.floor(Math.random() * 10000)}`);
            const dir = node_path_1.default.join(runtimeUploadsRoot, jobId);
            node_fs_1.default.mkdirSync(dir, { recursive: true });
            cb(null, dir);
        },
        filename: (_req, file, cb) => {
            cb(null, file.originalname);
        }
    })
});
function collectJsonFiles(rootDir) {
    const results = [];
    const queue = [rootDir];
    while (queue.length > 0) {
        const current = queue.shift();
        if (!current) {
            continue;
        }
        for (const entry of node_fs_1.default.readdirSync(current, { withFileTypes: true })) {
            const fullPath = node_path_1.default.join(current, entry.name);
            if (entry.isDirectory()) {
                queue.push(fullPath);
            }
            else if (entry.isFile() && node_path_1.default.extname(entry.name).toLowerCase() === '.json') {
                results.push(fullPath);
            }
        }
    }
    return results;
}
function flattenManifestEntries(node, entries) {
    if (!node || typeof node !== 'object') {
        return;
    }
    const obj = node;
    const hasRequired = typeof obj.TestID === 'string' &&
        typeof obj.TestExcelFile === 'string' &&
        typeof obj.TestInputFile === 'string';
    if (hasRequired) {
        entries.push({
            TestID: obj.TestID,
            TestExcelFile: obj.TestExcelFile,
            TestInputFile: obj.TestInputFile,
            TestResultsFile: typeof obj.TestResultsFile === 'string' ? obj.TestResultsFile : undefined
        });
    }
    for (const value of Object.values(obj)) {
        flattenManifestEntries(value, entries);
    }
}
function stripBom(text) {
    return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}
function formatBatchStamp(date) {
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    const year = String(date.getFullYear());
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${hours}${minutes}_${year}${month}${day}`;
}
function ensureInside(baseDir, candidatePath) {
    const resolvedBase = node_path_1.default.resolve(baseDir);
    const resolvedPath = node_path_1.default.resolve(candidatePath);
    if (!resolvedPath.toLowerCase().startsWith(resolvedBase.toLowerCase())) {
        throw new Error('Invalid path.');
    }
    return resolvedPath;
}
function createZipFromDirectory(sourceDir, destinationZip) {
    return new Promise((resolve, reject) => {
        const output = node_fs_1.default.createWriteStream(destinationZip);
        const archive = archiver('zip', { zlib: { level: 9 } });
        output.on('close', () => resolve());
        archive.on('error', (err) => reject(err));
        archive.pipe(output);
        archive.directory(sourceDir, false);
        archive.finalize().catch(reject);
    });
}
function runBulkProcessor(args) {
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
        const child = (0, node_child_process_1.spawn)('powershell', psArgs, { cwd: repoRoot });
        let stdErr = '';
        child.stderr.on('data', (chunk) => {
            stdErr += chunk.toString();
        });
        child.on('close', (code) => {
            if (code === 0) {
                resolve();
            }
            else {
                reject(new Error(stdErr || `Bulk processing failed with exit code ${code}.`));
            }
        });
    });
}
app.post('/api/process-bulk-input', upload.fields([
    { name: 'manifest', maxCount: 1 },
    { name: 'inputFiles', maxCount: 100 }
]), async (req, res) => {
    try {
        const filesByField = req.files;
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
        const jobDir = node_path_1.default.dirname(manifest.path);
        const extractedDir = node_path_1.default.join(jobDir, 'extracted');
        const consolidatedInputDir = node_path_1.default.join(jobDir, 'inputs');
        node_fs_1.default.mkdirSync(extractedDir, { recursive: true });
        node_fs_1.default.mkdirSync(consolidatedInputDir, { recursive: true });
        const manifestRaw = node_fs_1.default.readFileSync(manifest.path, 'utf8');
        const manifestJson = JSON.parse(stripBom(manifestRaw));
        const manifestEntries = [];
        flattenManifestEntries(manifestJson, manifestEntries);
        if (manifestEntries.length === 0) {
            res.status(400).send('Manifest file contains no entries with TestID/TestExcelFile/TestInputFile.');
            return;
        }
        const uploadedJsonByBasename = new Map();
        const warnings = [];
        for (const file of inputFiles) {
            const ext = node_path_1.default.extname(file.originalname).toLowerCase();
            if (ext === '.zip') {
                const zipTarget = node_path_1.default.join(extractedDir, node_path_1.default.basename(file.originalname, ext));
                node_fs_1.default.mkdirSync(zipTarget, { recursive: true });
                const zip = new adm_zip_1.default(file.path);
                zip.extractAllTo(zipTarget, true);
                for (const jsonPath of collectJsonFiles(zipTarget)) {
                    const basename = node_path_1.default.basename(jsonPath).toLowerCase();
                    if (uploadedJsonByBasename.has(basename)) {
                        warnings.push(`Duplicate JSON basename ignored: ${node_path_1.default.basename(jsonPath)}`);
                        continue;
                    }
                    const destination = node_path_1.default.join(consolidatedInputDir, node_path_1.default.basename(jsonPath));
                    node_fs_1.default.copyFileSync(jsonPath, destination);
                    uploadedJsonByBasename.set(basename, destination);
                }
                continue;
            }
            if (ext === '.json') {
                const basename = node_path_1.default.basename(file.originalname).toLowerCase();
                if (uploadedJsonByBasename.has(basename)) {
                    warnings.push(`Duplicate JSON basename ignored: ${file.originalname}`);
                    continue;
                }
                const destination = node_path_1.default.join(consolidatedInputDir, node_path_1.default.basename(file.originalname));
                node_fs_1.default.copyFileSync(file.path, destination);
                uploadedJsonByBasename.set(basename, destination);
            }
        }
        const missing = manifestEntries
            .map((entry) => entry.TestInputFile)
            .filter((testInputPath) => !uploadedJsonByBasename.has(node_path_1.default.basename(testInputPath).toLowerCase()));
        if (missing.length > 0) {
            res.status(400).send(`Manifest input files do not match uploaded files. Missing: ${missing.join(', ')}`);
            return;
        }
        const runStamp = formatBatchStamp(new Date());
        const resultPath = node_path_1.default.join(jobDir, 'bulk-process-result.json');
        await runBulkProcessor({
            manifestPath: manifest.path,
            inputRoot: consolidatedInputDir,
            resultPath,
            runStamp
        });
        const resultRaw = node_fs_1.default.readFileSync(resultPath, 'utf8');
        const rawResult = JSON.parse(stripBom(resultRaw));
        const zipFileName = `${rawResult.RunStamp}.zip`;
        const zipOutputPath = node_path_1.default.join(runtimeDownloadsRoot, zipFileName);
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
    }
    catch (error) {
        const message = error instanceof Error ? error.message : 'Unhandled processing error.';
        res.status(500).send(message);
    }
});
app.get('/api/download/:relativePath(*)', (req, res) => {
    try {
        const rel = req.params.relativePath;
        if (!rel) {
            res.status(400).send('Missing path.');
            return;
        }
        const absPath = ensureInside(repoRoot, node_path_1.default.join(repoRoot, rel));
        if (!node_fs_1.default.existsSync(absPath)) {
            res.status(404).send('File not found.');
            return;
        }
        res.download(absPath);
    }
    catch {
        res.status(400).send('Invalid file path.');
    }
});
app.get('/api/download-zip/:zipFileName', (req, res) => {
    try {
        const zipFileName = node_path_1.default.basename(req.params.zipFileName);
        const absPath = ensureInside(runtimeDownloadsRoot, node_path_1.default.join(runtimeDownloadsRoot, zipFileName));
        if (!node_fs_1.default.existsSync(absPath)) {
            res.status(404).send('ZIP not found.');
            return;
        }
        res.download(absPath);
    }
    catch {
        res.status(400).send('Invalid ZIP path.');
    }
});
app.get('*', (_req, res) => {
    res.sendFile(node_path_1.default.join(publicRoot, 'index.html'));
});
const port = Number(process.env.PORT ?? 5173);
app.listen(port, () => {
    console.log(`Bulk PWA server listening on http://localhost:${port}`);
});
