@ignore
Feature: Reusable Loan Setup CBS Helper

  Scenario: Send Loan Setup to CBS
    # Attempt real CBS loan account creation via /create-account
    Given url baseUrl
    And path '/v1/loan-setup/' + appId + '/create-account'
    And header Authorization = authHeader
    And request (typeof createAccountPayload != 'undefined' && createAccountPayload != null) ? createAccountPayload : { loanAccountName: 'Automation Loan Account' }
    When method POST

    # A caller that passes createAccountPayload (04 / 05) wants the real CBS account: a non-200 fails the row.
    # The stub /send-to-cbs fallback (LN-<year>-BLR-<appId> generated locally, no CBS call) stays only for the
    # legacy callers that send no payload.
    * def wantsCbs = typeof createAccountPayload != 'undefined' && createAccountPayload != null
    # A CBS-setup negative row (expectNegative) wants the refusal back instead: the caller matches it against the sheet.
    * def expectNeg = typeof expectNegative != 'undefined' && expectNegative == true
    * if (wantsCbs && !expectNeg && responseStatus != 200) karate.fail('[CBS LOAN ACCOUNT NOT CREATED] appId ' + appId + ': /create-account HTTP ' + responseStatus + ' ' + karate.toString(response))
    * def cbsStatus = responseStatus
    * def cbsBody = response
    * if (!wantsCbs && responseStatus != 200) karate.call('classpath:features/loans/loan-setup-send-to-cbs-fallback.feature', { appId: appId, authHeader: authHeader, baseUrl: baseUrl, requestBody: requestBody })
    * def cbsLoanId = (responseStatus == 200 && response.loanId) ? response.loanId : null
    * if (cbsLoanId != null) karate.log('✔ [TESTER VERIFICATION] Step 18c: Create Loan Account in CBS -> Loan ID:', response.loanId, '| CBS App ID:', response.loanApplicationId, '| Product:', response.productName, '| Maturity:', response.maturityDate)


