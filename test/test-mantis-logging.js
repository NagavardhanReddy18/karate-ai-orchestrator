/**
 * Test MantisBT Defect Logging Integration
 */

const { createMantisIssue, checkMantisStatus, buildMantisPayload } = require('../mantis-client');

async function runMantisTest() {
    console.log('--- 1. Testing Mantis Connection Status ---');
    const status = await checkMantisStatus();
    console.log('Status result:', JSON.stringify(status, null, 2));

    console.log('\n--- 2. Testing Mantis Defect Payload Builder ---');
    const sampleFailure = {
        feature: '06',
        env: 'test',
        durationSeconds: 14.8,
        cbsAccountsCreated: ['CBS-LN-992144', 'CBS-LN-992145'],
        triage: {
            failureCategory: 'CODE_REGRESSION',
            severity: 'CRITICAL',
            httpStatus: 503,
            failingEndpoint: 'POST /api/v1/loan/disburse',
            rootCauseSummary: 'Core Banking System (CBS) rejected transaction with 503 Service Unavailable',
            recommendedAction: 'Verify CBS mock/stub service or connectivity on port 9190'
        },
        rawFailures: [
            {
                scenario: 'Submit Retail Loan with Valid Sub-Product',
                error: 'status code was: 503, expected: 200, response: {"error":"CBS connection refused"}'
            }
        ]
    };

    const payload = buildMantisPayload(sampleFailure);
    console.log('Generated Payload Summary:', payload.summary);
    console.log('Generated Severity:', payload.severity);
    console.log('Generated Project:', payload.project);
    console.log('Generated Tags:', payload.tags);

    console.log('\n--- 3. Testing Mantis Issue Creation ---');
    const result = await createMantisIssue(sampleFailure);
    console.log('Creation Result:', JSON.stringify(result, null, 2));

    if (result.success) {
        console.log('\n✅ MantisBT integration verification PASSED!');
    } else {
        console.error('\n❌ MantisBT integration verification FAILED!');
    }
}

runMantisTest().catch(err => console.error(err));
