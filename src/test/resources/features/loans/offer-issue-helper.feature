@ignore
Feature: Reusable Offer Issue Helper

  Scenario: Issue Offer
    Given url baseUrl
    And path '/v1/offer/' + appId + '/issue'
    And header Authorization = authHeader
    And request requestBody
    When method POST
    Then status 200
