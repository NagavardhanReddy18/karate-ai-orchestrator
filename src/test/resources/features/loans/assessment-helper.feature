@ignore
Feature: Reusable Assessment Helper

  Scenario: Add Underwriter Assessment Comments
    Given url baseUrl
    And path '/v1/assessment/' + appId + '/comments'
    And header Authorization = authHeader
    And request
      """
      {
        "commentText": "Income details and CUSTCOL collateral verified dynamically."
      }
      """
    When method POST
    Then match [200, 201, 404] contains responseStatus
