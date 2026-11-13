@ignore
Feature: Open the overdraft's current/savings account in CBS (OD new-account flow, as the UI's Loan Setup screen does)

  Scenario: Create current/savings account in CBS
    Given url baseUrl
    And path '/v1/od-accounts/' + appId + '/currentsavings'
    And header Authorization = authHeader
    And request requestBody
    When method POST
    * if (responseStatus != 200) karate.fail('[CBS OD ACCOUNT NOT CREATED] TestCase ' + testCaseId + ': POST /currentsavings HTTP ' + responseStatus + ' ' + karate.toString(response))
    * def accountId = response.accountId
    * if (!accountId) karate.fail('[CBS OD ACCOUNT NOT CREATED] TestCase ' + testCaseId + ': CBS answered 200 without an accountId: ' + karate.toString(response))
    * def details = response.accountDetails ? response.accountDetails : {}
    * print '✔ [TESTER VERIFICATION] Step 19c: OD Current/Savings Account opened in CBS -> Account:', accountId, '| Product:', details.productDescription, '| Ownership:', details.accountOwnership, '| Branch:', details.branchCode
