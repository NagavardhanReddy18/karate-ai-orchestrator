@ignore
Feature: Set the overdraft limit and the debit interest rate on the CBS account (as the UI's Loan Setup screen does)

  Scenario: Apply OD limit and debit interest in CBS
    Given url baseUrl
    And path '/v1/od-accounts/' + appId + '/currentsavings/' + accountId + '/limits'
    And header Authorization = authHeader
    And request limitRequest
    When method PUT
    * if (responseStatus != 200) karate.fail('[CBS OD LIMIT NOT SET] TestCase ' + testCaseId + ': PUT /limits HTTP ' + responseStatus + ' ' + karate.toString(response))
    * def limitResponse = response
    * print '✔ [TESTER VERIFICATION] Step 19d: OD Limit set in CBS -> Account:', accountId, '| Limit:', limitRequest.debitLimit.value, limitRequest.debitLimit.currency, '| Expiry:', limitRequest.limitExpiryDate, '| Review:', limitRequest.limitReviewDate

    Given url baseUrl
    And path '/v1/od-accounts/' + appId + '/accounts/' + accountId + '/interest-rate-change'
    And param interestType = 'DR'
    And header Authorization = authHeader
    And request rateRequest
    When method POST
    * if (responseStatus != 200) karate.fail('[CBS OD RATE NOT SET] TestCase ' + testCaseId + ': POST /interest-rate-change HTTP ' + responseStatus + ' ' + karate.toString(response))
    * def rateResponse = response
    * print '✔ [TESTER VERIFICATION] Step 19e: OD Debit Interest set in CBS -> Account:', accountId, '| Request:', rateRequest
