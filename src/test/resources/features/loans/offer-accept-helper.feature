@ignore
Feature: Reusable Offer Accept Helper

  Scenario: Accept Offer
    Given url baseUrl
    And path '/v1/offer/' + appId + '/accept'
    And header Authorization = authHeader
    And request requestBody
    When method POST
    Then status 200
