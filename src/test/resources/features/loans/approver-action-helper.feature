@ignore
Feature: Reusable Approver Action Helper

  Scenario: Cast Approver Vote/Action
    Given url baseUrl
    And path '/v1/assessment/' + appId + '/approver-action'
    And header Authorization = authHeader
    And request requestBody
    When method POST
    Then status 200
