"use strict";
const form = document.getElementById('bulk-form');
const manifestInput = document.getElementById('manifest-file');
const inputFiles = document.getElementById('input-files');
const processButton = document.getElementById('process-btn');
const statusEl = document.getElementById('status');
const resultsPanel = document.getElementById('results-panel');
const summaryEl = document.getElementById('summary');
const resultList = document.getElementById('result-list');
function setStatus(message, isError = false) {
    statusEl.textContent = message;
    statusEl.style.color = isError ? '#b3261e' : '#c44b2d';
}
function renderResults(data) {
    resultsPanel.hidden = false;
    summaryEl.innerHTML = '';
    resultList.innerHTML = '';
    const summary = document.createElement('div');
    summary.innerHTML = [
        `<p><strong>Run stamp:</strong> ${data.runStamp}</p>`,
        `<p><strong>Output directory:</strong> ${data.outputDirectoryRelativePath}</p>`,
        `<div class="links"><a href="/api/download-zip/${encodeURIComponent(data.zipFileName)}">Download all generated files (ZIP)</a></div>`
    ].join('');
    if (data.validationWarnings.length > 0) {
        const warningBlock = document.createElement('div');
        warningBlock.innerHTML = `<p><strong>Warnings</strong></p><p>${data.validationWarnings.join('<br/>')}</p>`;
        summary.appendChild(warningBlock);
    }
    summaryEl.appendChild(summary);
    for (const item of data.items) {
        const card = document.createElement('article');
        card.className = 'result-item';
        const resultRows = Object.entries(item.results)
            .map(([name, value]) => `<p><strong>${name}:</strong> ${value ?? ''}</p>`)
            .join('');
        card.innerHTML = [
            `<h3>${item.testId}</h3>`,
            `<p><strong>Source workbook:</strong> ${item.sourceWorkbook}</p>`,
            `<p><strong>Input file:</strong> ${item.inputFileUsed}</p>`,
            resultRows,
            `<div class="links"><a href="/api/download/${encodeURIComponent(item.createdWorkbookRelativePath)}">Download generated workbook</a></div>`
        ].join('');
        resultList.appendChild(card);
    }
}
form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!manifestInput.files || manifestInput.files.length !== 1) {
        setStatus('Select one manifest JSON file.', true);
        return;
    }
    if (!inputFiles.files || inputFiles.files.length === 0) {
        setStatus('Select JSON input files or one ZIP archive.', true);
        return;
    }
    processButton.disabled = true;
    setStatus('Uploading and processing...');
    resultsPanel.hidden = true;
    const payload = new FormData();
    payload.append('manifest', manifestInput.files[0]);
    for (const file of Array.from(inputFiles.files)) {
        payload.append('inputFiles', file);
    }
    try {
        const response = await fetch('/api/process-bulk-input', {
            method: 'POST',
            body: payload
        });
        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(errorText || `Processing failed with status ${response.status}.`);
        }
        const data = (await response.json());
        renderResults(data);
        setStatus(`Processed ${data.items.length} item(s).`);
    }
    catch (error) {
        const message = error instanceof Error ? error.message : 'Processing failed.';
        setStatus(message, true);
    }
    finally {
        processButton.disabled = false;
    }
});
if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {
        // Service worker registration is non-critical for this workflow.
    });
}
