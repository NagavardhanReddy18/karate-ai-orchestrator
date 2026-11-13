@ignore
Feature: Reusable Workflow Task Helper

  Scenario: Complete Workflow Task
    Given url baseUrl
    And path '/v1/loans/tasks/' + taskId + '/complete'
    And header Authorization = authHeader
    And request requestBody
    When method POST
    Then status 200
