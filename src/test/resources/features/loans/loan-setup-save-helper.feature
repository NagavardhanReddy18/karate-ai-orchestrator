@ignore
Feature: Reusable Loan Setup Save Helper

  Scenario: Save Loan Setup
    Given url baseUrl
    And path '/v1/loan-setup/' + appId
    And header Authorization = authHeader
    And request requestBody
    When method PUT
    Then status 200
