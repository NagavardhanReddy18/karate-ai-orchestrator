@ignore
Feature: Loan Setup Send-To-CBS Fallback Helper

  Scenario: Fallback Send Loan Setup to CBS
    Given url baseUrl
    And path '/v1/loan-setup/' + appId + '/send-to-cbs'
    And header Authorization = authHeader
    And request requestBody
    When method POST
    Then assert responseStatus == 200 || responseStatus == 204
