/**
 * MantisBT REST API Client for Karate AI Orchestrator
 * ----------------------------------------------------
 * Connects to MantisBT REST API (/api/rest/issues) to automatically file
 * defect tickets when Karate API test regressions or failures occur.
 *
 * Author: Naga Vardhan Reddy Borra
 */

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '.env') });

function getMantisConfig() {
    const baseUrl = (process.env.MANTIS_BASE_URL || 'https://mantis.irdsoft.com/api/rest').replace(/\/+$/, '');
    const token = process.env.MANTIS_API_TOKEN || '';
    const project = process.env.MANTIS_PROJECT_NAME || 'LOS system';
    const category = process.env.MANTIS_CATEGORY || 'Issue';
    const webUrl = baseUrl.replace(/\/api\/rest\/?$/, '');
    return { baseUrl, token, project, category, webUrl };
}

/**
 * Maps AI Triage severity to MantisBT severity levels.
 * Mantis levels: feature, trivial, text, tweak, minor, major, crash, block
 */
function mapSeverityToMantis(aiSeverity) {
    const sev = (aiSeverity || '').toUpperCase();
    switch (sev) {
        case 'CRITICAL':
            return 'crash';
        case 'HIGH':
            return 'major';
        case 'MEDIUM':
            return 'minor';
        case 'LOW':
            return 'trivial';
        default:
            return 'major';
    }
}

/**
 * Builds standard MantisBT defect payload from Karate test run & AI Triage data
 */
function buildMantisPayload(data) {
    const cfg = getMantisConfig();
    const {
        feature = 'Unknown Feature',
        env = 'test',
        triage = {},
        rawFailures = [],
        durationSeconds = 0,
        cbsAccountsCreated = []
    } = data;

    const summary = `[Karate Auto-Bug] [Env: ${env.toUpperCase()}] ${triage.failingEndpoint || feature} - ${triage.rootCauseSummary || 'API Regression'}`.substring(0, 128);

    const accountsStr = cbsAccountsCreated.length > 0 ? cbsAccountsCreated.join(', ') : 'None created';
    const failureSnippet = (rawFailures && rawFailures.length > 0)
        ? JSON.stringify(rawFailures.slice(0, 3), null, 2)
        : (triage.rawSnippet || 'No stack trace available');

    const description = [
        `======================================================================`,
        `🚨 AUTOMATED DEFECT LOGGED BY KARATE AI TEST ORCHESTRATOR`,
        `======================================================================`,
        `* Feature File        : ${feature}`,
        `* Target Environment  : ${env.toUpperCase()} (dev=9090, test=9190)`,
        `* Test Execution Time : ${durationSeconds} seconds`,
        `* CBS Accounts Gen    : ${accountsStr}`,
        ``,
        `----------------------------------------------------------------------`,
        `🤖 AI ROOT-CAUSE TRIAGE DIAGNOSTIC`,
        `----------------------------------------------------------------------`,
        `* Category            : ${triage.failureCategory || 'CODE_REGRESSION'}`,
        `* Assessed Severity   : ${triage.severity || 'HIGH'}`,
        `* Failing Service/URL : ${triage.failingEndpoint || 'N/A'}`,
        `* HTTP Status Code    : ${triage.httpStatus || 'N/A'}`,
        `* Root Cause Summary  : ${triage.rootCauseSummary || 'Assertion failed'}`,
        `* Recommended Action  : ${triage.recommendedAction || 'Inspect service logs'}`,
        ``,
        `----------------------------------------------------------------------`,
        `📄 FAILURE LOG SNIPPET`,
        `----------------------------------------------------------------------`,
        failureSnippet.substring(0, 3000),
        ``,
        `----------------------------------------------------------------------`,
        `📊 ARTIFACTS & REPORTS`,
        `----------------------------------------------------------------------`,
        `* Full Excel Report   : http://localhost:5050/api/reports/download/excel`,
        `* HTML Summary Report : http://localhost:5050/api/reports/download/html`,
        `======================================================================`
    ].join('\n');

    const categoryId = cfg.category.toLowerCase() === 'backlog' ? 16 : 19;

    const payload = {
        summary,
        description,
        category: { id: categoryId, name: cfg.category },
        project: { id: 5, name: cfg.project },
        severity: { name: mapSeverityToMantis(triage.severity) },
        priority: { name: triage.severity === 'CRITICAL' ? 'urgent' : 'high' },
        reproducibility: { name: 'always' }
    };

    return payload;
}

/**
 * Creates an issue in MantisBT via REST API
 * POST /api/rest/issues
 */
async function createMantisIssue(data) {
    const cfg = getMantisConfig();
    const payload = buildMantisPayload(data);

    // If Mantis URL or API token is not yet configured, provide simulated response for local testing
    const isMock = !cfg.token || cfg.baseUrl.includes('your-mantis-host');

    if (isMock) {
        const mockIssueId = Math.floor(2000 + Math.random() * 900);
        const formattedId = String(mockIssueId).padStart(7, '0');
        console.log(`\n[Mantis Client - SIMULATION MODE] (Token or Host not configured in .env)`);
        console.log(`[Mantis Client] Simulated issue #${formattedId} created for project "${cfg.project}"`);
        console.log(`[Mantis Client] Summary: "${payload.summary}"`);

        return {
            success: true,
            simulated: true,
            issue: {
                id: mockIssueId,
                formattedId,
                summary: payload.summary,
                severity: payload.severity.name,
                project: payload.project.name,
                category: payload.category.name,
                url: `${cfg.webUrl}/view.php?id=${mockIssueId}`,
                payloadPreview: payload
            },
            message: 'Mantis issue logged in simulation mode. Configure MANTIS_BASE_URL and MANTIS_API_TOKEN in .env for live sync.'
        };
    }

    try {
        const response = await fetch(`${cfg.baseUrl}/issues`, {
            method: 'POST',
            headers: {
                'Authorization': cfg.token,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(payload)
        });

        const json = await response.json();

        if (!response.ok) {
            throw new Error(json.message || `Mantis HTTP ${response.status}: ${JSON.stringify(json)}`);
        }

        const issueId = json.issue ? json.issue.id : (json.id || 'N/A');
        const formattedId = typeof issueId === 'number' ? String(issueId).padStart(7, '0') : issueId;

        console.log(`[Mantis Client] ✅ Successfully created Mantis Defect #${formattedId}`);

        return {
            success: true,
            simulated: false,
            issue: {
                id: issueId,
                formattedId,
                summary: payload.summary,
                url: `${cfg.webUrl}/view.php?id=${issueId}`
            }
        };
    } catch (err) {
        console.error(`[Mantis Client] ❌ Failed to create Mantis issue: ${err.message}`);
        return {
            success: false,
            error: err.message,
            payloadPreview: payload
        };
    }
}

/**
 * Verify Mantis connectivity and list projects
 * GET /api/rest/projects
 */
async function checkMantisStatus() {
    const cfg = getMantisConfig();
    if (!cfg.token || cfg.baseUrl.includes('your-mantis-host')) {
        return {
            configured: false,
            baseUrl: cfg.baseUrl,
            project: cfg.project,
            category: cfg.category,
            status: 'PENDING_CONFIG',
            message: 'Please set MANTIS_BASE_URL and MANTIS_API_TOKEN in .env'
        };
    }

    try {
        const response = await fetch(`${cfg.baseUrl}/projects`, {
            headers: {
                'Authorization': cfg.token
            }
        });
        const json = await response.json();
        return {
            configured: true,
            status: response.ok ? 'CONNECTED' : 'AUTH_FAILED',
            statusCode: response.status,
            projects: json.projects || []
        };
    } catch (err) {
        return {
            configured: true,
            status: 'UNREACHABLE',
            error: err.message
        };
    }
}

module.exports = {
    createMantisIssue,
    buildMantisPayload,
    checkMantisStatus,
    mapSeverityToMantis
};
