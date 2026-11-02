/**
 * Karate AI QA Orchestrator - REST API Bridge
 * -------------------------------------------
 * Connects n8n workflows, Slack bots, and Webhooks directly to the Beyond LO
 * Karate API automation test suite.
 *
 * Author: Naga Vardhan Reddy Borra
 */

require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const { performAiTriage } = require('./ai-triage-engine');
const { createMantisIssue, checkMantisStatus } = require('./mantis-client');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 5050;
const KARATE_PROJECT_PATH = process.env.KARATE_PROJECT_PATH || 'C:/Latest-BeyondLo-Sep23rd/beyond-lo/beyond-lo-tests';
const DEFAULT_ENV = process.env.DEFAULT_KARATE_ENV || 'test';

// -----------------------------------------------------------------------------
// Health Check
// -----------------------------------------------------------------------------
app.get('/api/health', async (req, res) => {
    const projectExists = fs.existsSync(KARATE_PROJECT_PATH);
    const pomExists = fs.existsSync(path.join(KARATE_PROJECT_PATH, 'pom.xml'));
    const mantisStatus = await checkMantisStatus();

    res.json({
        status: 'UP',
        service: 'Karate AI QA Orchestrator Bridge',
        karateProject: {
            path: KARATE_PROJECT_PATH,
            valid: projectExists && pomExists
        },
        mantis: mantisStatus,
        defaultEnv: DEFAULT_ENV,
        timestamp: new Date().toISOString()
    });
});

// -----------------------------------------------------------------------------
// Run Karate Tests Endpoint (Called by n8n Webhook / Slack)
// -----------------------------------------------------------------------------
app.post('/api/tests/run', async (req, res) => {
    const startTime = Date.now();
    const {
        feature = '04',
        env = DEFAULT_ENV,
        tags = '',
        aiTriage = true,
        autoLogMantis = false,
        triggeredBy = 'n8n-orchestrator'
    } = req.body;

    console.log(`\n[Orchestrator] 🚀 Received execution request for Feature(s): [${feature}] on Env: [${env}] by: ${triggeredBy}`);

    if (!fs.existsSync(KARATE_PROJECT_PATH)) {
        return res.status(500).json({
            success: false,
            error: `Karate project directory not found at: ${KARATE_PROJECT_PATH}`
        });
    }

    // Build Maven arguments
    const args = ['test', '-Dtest=KarateTestRunner', `-Dkarate.env=${env}`];
    if (feature && feature.toLowerCase() !== 'all') {
        args.push(`-Dkarate.features=${feature}`);
    }
    if (tags && tags.trim()) {
        args.push(`-Dkarate.tags=${tags.trim()}`);
    }

    console.log(`[Orchestrator] Running: mvn ${args.join(' ')}`);

    let stdoutLog = '';
    let stderrLog = '';

    const isWindows = process.platform === 'win32';
    const mvnCommand = isWindows ? 'mvn.cmd' : 'mvn';

    const child = spawn(mvnCommand, args, {
        cwd: KARATE_PROJECT_PATH,
        shell: true
    });

    child.stdout.on('data', (data) => {
        const str = data.toString();
        stdoutLog += str;
        // Print essential highlights to orchestrator console
        if (str.includes('[TESTER VERIFICATION]') || str.includes('BUILD') || str.includes('Features')) {
            process.stdout.write(str);
        }
    });

    child.stderr.on('data', (data) => {
        stderrLog += data.toString();
    });

    child.on('close', async (exitCode) => {
        const durationSec = ((Date.now() - startTime) / 1000).toFixed(2);
        console.log(`\n[Orchestrator] Test execution finished with exitCode: ${exitCode} in ${durationSec}s`);

        // Parse Results from target/karate-reports
        const reportsDir = path.join(KARATE_PROJECT_PATH, 'target', 'karate-reports');
        const parsedResults = parseTestExecutionResults(reportsDir, stdoutLog);

        const executionSuccess = exitCode === 0 && parsedResults.failed === 0;

        let triageAnalysis = null;
        let mantisDefect = null;

        if (!executionSuccess && aiTriage) {
            console.log('[Orchestrator] 🤖 Invoking AI Triage Engine for test failure root-cause analysis...');
            triageAnalysis = await performAiTriage({
                feature,
                env,
                exitCode,
                failures: parsedResults.failures,
                logSnippet: extractRelevantErrorLogs(stdoutLog, stderrLog)
            });

            // Automatically create Mantis defect if autoLogMantis is enabled or requested
            if (autoLogMantis) {
                console.log('[Orchestrator] 🐞 Auto-filing defect ticket in MantisBT...');
                const mantisResult = await createMantisIssue({
                    feature,
                    env,
                    triage: triageAnalysis,
                    rawFailures: parsedResults.failures,
                    durationSeconds: parseFloat(durationSec),
                    cbsAccountsCreated: parsedResults.cbsAccounts
                });
                mantisDefect = mantisResult;
            }
        }

        const excelReportPath = path.join(reportsDir, 'Karate_Test_Execution_Report.xlsx');
        const htmlReportPath = path.join(reportsDir, 'karate-summary.html');

        res.json({
            success: executionSuccess,
            exitCode,
            durationSeconds: parseFloat(durationSec),
            feature,
            environment: env,
            triggeredBy,
            metrics: {
                totalScenarios: parsedResults.total,
                passed: parsedResults.passed,
                failed: parsedResults.failed,
                passRate: parsedResults.passRate
            },
            cbsAccountsCreated: parsedResults.cbsAccounts,
            failures: parsedResults.failures,
            aiTriage: triageAnalysis,
            mantisDefect: mantisDefect,
            reports: {
                excelAvailable: fs.existsSync(excelReportPath),
                excelDownloadUrl: `/api/reports/download/excel`,
                htmlAvailable: fs.existsSync(htmlReportPath),
                htmlDownloadUrl: `/api/reports/download/html`
            },
            timestamp: new Date().toISOString()
        });
    });
});

// -----------------------------------------------------------------------------
// Standalone AI Triage Endpoint (Can analyze any arbitrary error log)
// -----------------------------------------------------------------------------
app.post('/api/triage', async (req, res) => {
    const { errorLog, feature = '04', env = 'test' } = req.body;
    if (!errorLog) {
        return res.status(400).json({ error: 'errorLog payload is required' });
    }

    const analysis = await performAiTriage({
        feature,
        env,
        logSnippet: errorLog
    });

    res.json({
        success: true,
        triage: analysis
    });
});

// -----------------------------------------------------------------------------
// MantisBT Defect Filing Endpoints
// -----------------------------------------------------------------------------
app.post('/api/defects/mantis', async (req, res) => {
    const {
        feature = '04',
        env = 'test',
        triage = {},
        rawFailures = [],
        durationSeconds = 0,
        cbsAccountsCreated = []
    } = req.body;

    console.log(`[Orchestrator] 🐞 Manual Mantis defect creation requested for feature: ${feature}`);

    const result = await createMantisIssue({
        feature,
        env,
        triage,
        rawFailures,
        durationSeconds,
        cbsAccountsCreated
    });

    res.status(result.success ? 200 : 500).json(result);
});

app.get('/api/defects/mantis/status', async (req, res) => {
    const status = await checkMantisStatus();
    res.json(status);
});

// -----------------------------------------------------------------------------
// Download Excel & HTML Reports
// -----------------------------------------------------------------------------
app.get('/api/reports/download/excel', (req, res) => {
    const file = path.join(KARATE_PROJECT_PATH, 'target', 'karate-reports', 'Karate_Test_Execution_Report.xlsx');
    if (!fs.existsSync(file)) {
        return res.status(404).send('Excel report not found. Please run a test execution first.');
    }
    res.download(file, 'Karate_Test_Execution_Report.xlsx');
});

app.get('/api/reports/download/html', (req, res) => {
    const file = path.join(KARATE_PROJECT_PATH, 'target', 'karate-reports', 'karate-summary.html');
    if (!fs.existsSync(file)) {
        return res.status(404).send('HTML report not found. Please run a test execution first.');
    }
    res.sendFile(file);
});

// -----------------------------------------------------------------------------
// Helper: Parse Test Results from Files and Console Logs
// -----------------------------------------------------------------------------
function parseTestExecutionResults(reportsDir, stdoutLog) {
    let total = 0;
    let passed = 0;
    let failed = 0;
    const failures = [];
    const cbsAccounts = [];

    // Extract CBS accounts from stdout
    const cbsRegex = /(?:CBS Loan Account Number|CBS OD Limit \/ Account|Loan ID)\s*:\s*([A-Za-z0-9_-]+)/gi;
    let match;
    while ((match = cbsRegex.exec(stdoutLog)) !== null) {
        const acct = match[1].trim();
        if (acct && acct !== 'null' && acct !== 'N/A' && !cbsAccounts.includes(acct)) {
            cbsAccounts.push(acct);
        }
    }

    // Try reading karate-summary.json
    const summaryFile = path.join(reportsDir, 'karate-summary-json.txt');
    const summaryJson = path.join(reportsDir, 'karate-summary.json');
    const activeSummary = fs.existsSync(summaryFile) ? summaryFile : (fs.existsSync(summaryJson) ? summaryJson : null);

    // 1. Try parsing from KarateTestRunner custom summary banner in stdout
    const testRunnerRegex = /Total Test Cases:\s*(\d+)\s*\(Passed:\s*(\d+),\s*Failed:\s*(\d+)/i;
    const trMatch = stdoutLog.match(testRunnerRegex);
    if (trMatch) {
        total = parseInt(trMatch[1], 10);
        passed = parseInt(trMatch[2], 10);
        failed = parseInt(trMatch[3], 10);
    }

    // 2. Try reading karate-summary-json.txt or karate-summary.json if total is still 0
    if (total === 0 && activeSummary) {
        try {
            const data = JSON.parse(fs.readFileSync(activeSummary, 'utf8'));
            if (data.featureSummary && Array.isArray(data.featureSummary)) {
                data.featureSummary.forEach(f => {
                    const p = (f.passedCount !== undefined) ? f.passedCount : (f.scenariosPassed || 0);
                    const fl = (f.failedCount !== undefined) ? f.failedCount : (f.scenariosFailed || 0);
                    total += (p + fl);
                    passed += p;
                    failed += fl;
                    if (fl > 0) {
                        failures.push({
                            feature: f.packageQualifiedName || f.relativePath,
                            failedCount: fl
                        });
                    }
                });
            } else if (data.scenariosPassed !== undefined || data.scenariosfailed !== undefined) {
                passed = data.scenariosPassed || 0;
                failed = data.scenariosfailed || 0;
                total = passed + failed;
            }
        } catch (e) {
            console.error('[Orchestrator] Warning reading summary JSON:', e.message);
        }
    }

    // 3. Fallback standard Karate regex from console output
    if (total === 0) {
        const scenariosRegex = /scenarios:\s*(\d+)\s*\|\s*passed:\s*(\d+)\s*\|\s*failed:\s*(\d+)/i;
        const sMatch = stdoutLog.match(scenariosRegex);
        if (sMatch) {
            total = parseInt(sMatch[1], 10);
            passed = parseInt(sMatch[2], 10);
            failed = parseInt(sMatch[3], 10);
        }
    }

    // Extract failure snippets from log
    const failureSnippetRegex = /\[ERROR\]\s+Failures:\s*\n([\s\S]*?)\[INFO\]\s+Results:/i;
    const fMatch = stdoutLog.match(failureSnippetRegex);
    if (fMatch) {
        failures.push({
            rawFailureSnippet: fMatch[1].trim().substring(0, 1500)
        });
    }

    const passRate = total > 0 ? `${((passed / total) * 100).toFixed(1)}%` : '0%';

    return { total, passed, failed, passRate, failures, cbsAccounts };
}

function extractRelevantErrorLogs(stdout, stderr) {
    const combined = `${stdout}\n${stderr}`;
    const lines = combined.split('\n');
    const errorLines = lines.filter(l =>
        l.includes('ERROR') ||
        l.includes('Failures:') ||
        l.includes('Exception:') ||
        l.includes('HTTP 5') ||
        l.includes('HTTP 4') ||
        l.includes('FAILED')
    );
    return errorLines.slice(-40).join('\n') || combined.slice(-2000);
}

// -----------------------------------------------------------------------------
// Start Server
// -----------------------------------------------------------------------------
app.listen(PORT, () => {
    console.log(`================================================================`);
    console.log(`  KARATE AI QA ORCHESTRATOR BRIDGE ACTIVE`);
    console.log(`  Listening on : http://localhost:${PORT}`);
    console.log(`  Health Check : http://localhost:${PORT}/api/health`);
    console.log(`  Test Runner  : POST http://localhost:${PORT}/api/tests/run`);
    console.log(`  Mantis Defect: POST http://localhost:${PORT}/api/defects/mantis`);
    console.log(`  Mantis Status: GET http://localhost:${PORT}/api/defects/mantis/status`);
    console.log(`  Karate Tests : ${KARATE_PROJECT_PATH}`);
    console.log(`================================================================`);
});
