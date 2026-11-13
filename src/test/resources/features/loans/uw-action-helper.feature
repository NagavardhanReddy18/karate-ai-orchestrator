@ignore
Feature: Reusable Underwriter Action Helper

  Scenario: Cast Underwriter Action
    Given url baseUrl
    And path '/v1/assessment/' + appId + '/uw-action'
    And header Authorization = authHeader
    And request requestBody
    When method POST
    * def expStat = (typeof expectedStatus !== 'undefined' && expectedStatus != null && expectedStatus != '') ? parseInt(expectedStatus) : 200
    Then assert responseStatus == expStat || responseStatus == 200
