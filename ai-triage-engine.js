/**
 * AI Test Failure Triage Engine
 * -----------------------------
 * Uses LLMs (Google Gemini or OpenAI) or smart heuristic rules to perform
 * automated root-cause failure analysis for failed Karate API test executions.
 *
 * Author: Naga Vardhan Reddy Borra
 */

require('dotenv').config();

async function performAiTriage({ feature, env, exitCode, failures, logSnippet }) {
    const apiKey = process.env.GEMINI_API_KEY || process.env.OPENAI_API_KEY;
    const provider = process.env.AI_PROVIDER || 'gemini';

    const systemPrompt = `You are a Senior Software Development Engineer in Test (SDET) and QA Architect specializing in Karate Framework and Banking/Loan Origination (Beyond LO) microservices APIs.
Analyze the following automated API test failure log. 

Provide an intelligent root-cause diagnosis. Categorize the failure as one of:
1. "CODE_REGRESSION" (e.g., unexpected 500 NullPointerException, schema mismatch, broken business rule)
2. "ENVIRONMENT_OR_DOWNSTREAM_ISSUE" (e.g., Core Banking CBS mock down, 503 service unavailable, database connection refused)
3. "TEST_DATA_MISMATCH" (e.g., product code not mapped in sheet, customer not found, invalid limit)
4. "TIMEOUT_OR_NETWORK" (e.g., socket timeout, gateway 504)

Respond ONLY with a valid JSON object matching this schema:
{
  "failureCategory": "CODE_REGRESSION | ENVIRONMENT_OR_DOWNSTREAM_ISSUE | TEST_DATA_MISMATCH | TIMEOUT_OR_NETWORK",
  "rootCauseSummary": "Clear 1-2 sentence explanation of why the test failed.",
  "failingEndpoint": "/v1/origination/... or CBS service",
  "httpStatus": 500 or 503 or 400 or "N/A",
  "recommendedAction": "Exact steps for the developer or QA to resolve this issue.",
  "severity": "CRITICAL | HIGH | MEDIUM | LOW"
}`;

    const userContent = `Feature: ${feature}
Environment: ${env} (dev: 9090, test/staging: 9190)
Log Snippet:
${logSnippet}

Failures list: ${JSON.stringify(failures || [])}`;

    // 1. Try Gemini API if key is present
    if (process.env.GEMINI_API_KEY) {
        try {
            const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${process.env.GEMINI_API_KEY}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    contents: [
                        { role: 'user', parts: [{ text: `${systemPrompt}\n\n${userContent}` }] }
                    ],
                    generationConfig: { responseMimeType: 'application/json' }
                })
            });

            if (response.ok) {
                const data = await response.json();
                const text = data.candidates?.[0]?.content?.parts?.[0]?.text;
                if (text) {
                    return JSON.parse(text);
                }
            }
        } catch (e) {
            console.error('[AI Triage] Gemini API call error:', e.message);
        }
    }

    // 2. Try OpenAI API if key is present
    if (process.env.OPENAI_API_KEY) {
        try {
            const response = await fetch('https://api.openai.com/v1/chat/completions', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`
                },
                body: JSON.stringify({
                    model: 'gpt-4o-mini',
                    messages: [
                        { role: 'system', content: systemPrompt },
                        { role: 'user', content: userContent }
                    ],
                    response_format: { type: 'json_object' }
                })
            });

            if (response.ok) {
                const data = await response.json();
                const content = data.choices?.[0]?.message?.content;
                if (content) {
                    return JSON.parse(content);
                }
            }
        } catch (e) {
            console.error('[AI Triage] OpenAI API call error:', e.message);
        }
    }

    // 3. Fallback Heuristic Rule-Based Diagnosis (Guaranteed to work offline / without API key!)
    return performHeuristicTriage(logSnippet, failures);
}

function performHeuristicTriage(logSnippet, failures) {
    const text = (logSnippet || '').toLowerCase();

    if (text.includes('connect timed out') || text.includes('connection refused') || text.includes('failed: connect timed out')) {
        return {
            failureCategory: 'ENVIRONMENT_OR_DOWNSTREAM_ISSUE',
            rootCauseSummary: 'The test environment server or target port was unreachable during execution.',
            failingEndpoint: '/api/auth/login or backend host',
            httpStatus: 'Connection Timeout',
            recommendedAction: 'Verify that the target Docker containers or staging server (port 9090/9190) are running and accessible.',
            severity: 'CRITICAL',
            isHeuristic: true
        };
    }

    if (text.includes('matching sub-product not found') || text.includes('http 503')) {
        return {
            failureCategory: 'ENVIRONMENT_OR_DOWNSTREAM_ISSUE',
            rootCauseSummary: 'Core Banking System (CBS) returned HTTP 503 because the requested sub-product code is not seeded in the CBS mock/staging database.',
            failingEndpoint: '/currentsavings or /loans/setup',
            httpStatus: 503,
            recommendedAction: 'Ensure the subproduct code in the Excel sheet matches active master data or seed it on the CBS staging instance.',
            severity: 'HIGH',
            isHeuristic: true
        };
    }

    if (text.includes('is not available under product type') || text.includes('validation_error')) {
        return {
            failureCategory: 'TEST_DATA_MISMATCH',
            rootCauseSummary: 'The selected product code is not configured under the specified facility product type.',
            failingEndpoint: '/v1/origination/draft submit',
            httpStatus: 400,
            recommendedAction: 'Update the Excel test row so that selectedProductCode belongs to the corresponding product type configuration.',
            severity: 'MEDIUM',
            isHeuristic: true
        };
    }

    if (text.includes('500') || text.includes('internal server error') || text.includes('nullpointerexception')) {
        return {
            failureCategory: 'CODE_REGRESSION',
            rootCauseSummary: 'An unhandled 500 Internal Server Error occurred on the backend during test execution.',
            failingEndpoint: 'Backend API Service',
            httpStatus: 500,
            recommendedAction: 'Inspect the server application logs for the stack trace and file a defect ticket.',
            severity: 'HIGH',
            isHeuristic: true
        };
    }

    return {
        failureCategory: 'CODE_REGRESSION',
        rootCauseSummary: 'One or more assertions failed during the lifecycle test execution.',
        failingEndpoint: 'Unknown / Check logs',
        httpStatus: 'Assert Error',
        recommendedAction: 'Review the failing step log in target/karate-reports/Karate_Test_Execution_Report.xlsx.',
        severity: 'MEDIUM',
        isHeuristic: true
    };
}

module.exports = { performAiTriage };
