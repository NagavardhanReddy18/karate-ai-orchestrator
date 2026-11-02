/**
 * Adds the scorecard negative test case to Retail-Excel-Automation.xlsx
 */

const XLSX = require('xlsx');
const path = require('path');
const fs = require('fs');

const srcExcelPath = 'C:/Latest-BeyondLo-Sep23rd/beyond-lo/beyond-lo-tests/src/test/resources/features/loans/testdata/Retail-Excel-Automation.xlsx';
const targetExcelPath = 'C:/Latest-BeyondLo-Sep23rd/beyond-lo/beyond-lo-tests/target/test-classes/features/loans/testdata/Retail-Excel-Automation.xlsx';

function addTestCaseToFile(filePath) {
    if (!fs.existsSync(filePath)) {
        console.log('Skipping non-existent:', filePath);
        return;
    }

    console.log('Reading Excel from:', filePath);
    const wb = XLSX.readFile(filePath);
    const sheetName = wb.SheetNames[0];
    const sheet = wb.Sheets[sheetName];
    const data = XLSX.utils.sheet_to_json(sheet);

    // Check if test case already exists
    const existingIndex = data.findIndex(r => r.testCaseId === 'TC-SCORECARD-NEG-01-MISSING-MANDATORY-ORIGINATION');

    // Clone base data from TC-COMBO-POS-01-KRT_TA_SC-PL003-ALL-DETAILS
    const baseRow = data.find(r => r.testCaseId === 'TC-COMBO-POS-01-KRT_TA_SC-PL003-ALL-DETAILS') || {};

    const newRow = Object.assign({}, baseRow, {
        run: 'Y',
        runOnEnv: null,
        testCaseId: 'TC-SCORECARD-NEG-01-MISSING-MANDATORY-ORIGINATION',
        description: 'NEGATIVE SCORECARD: Product type KRT_TA_SC has scorecard attached, but mandatory scorecard attributes (incomeDetails, expenseDetails) are missing in Origination -> causes 500 Server Error at Underwriter Assessment',
        expectedStatus: null,
        expectedError: null,
        expectedCode: null,
        // Keep Origination details
        loanProductType: 'KRT_TA_SC',
        selectedProductCode: 'PL003DEFAULTUSD',
        selectedProductName: 'Personal Loans with Flat Interest - USD',
        customerTypeSelected: 'EXISTING',
        customerId: '00000004',
        customerName: 'Thrivikram J',
        branch: '00000001',
        loanPurpose: '002',
        loanTerm: 36,
        termFrequency: 'MONTHS',
        loanAmount: 140000,
        totalAmount: 140000,
        loanAmountCurrency: 'USD',
        totalAmountCurrency: 'USD',
        customerContribution: 20000,
        accountOpenBranch: '00000001',
        employmentType: 'SALARIED',
        // CRITICAL: OMIT mandatory scorecard parameters!
        monthlyGrossIncome: null,
        otherIncome: null,
        incomeDetails: null,
        monthlyLivingExpenses: null,
        expenseDetails: null,
        existingEmiObligations: null,
        periodOfEmployment: null,
        // Workflow stages
        submitDraft: 'true',
        skipUw: 'false',
        skipApprover1: 'false',
        skipApprover2: 'false',
        skipCc: 'false',
        skipIssueOffer: 'false',
        skipOfferAccept: 'false',
        skipLoanSetup: 'false',
        underwriterUsername: 'underwriter1',
        uwAction: 'APPROVE_TO_APPROVER',
        uwComment: 'Scorecard negative verification | Step 14b check'
    });

    if (existingIndex >= 0) {
        console.log('Updating existing test case at row index:', existingIndex + 2);
        data[existingIndex] = newRow;
    } else {
        console.log('Appending new test case row at index:', data.length + 2);
        data.push(newRow);
    }

    const newSheet = XLSX.utils.json_to_sheet(data);
    wb.Sheets[sheetName] = newSheet;
    XLSX.writeFile(wb, filePath);
    console.log('Successfully saved:', filePath);
}

addTestCaseToFile(srcExcelPath);
addTestCaseToFile(targetExcelPath);
console.log('Done!');
