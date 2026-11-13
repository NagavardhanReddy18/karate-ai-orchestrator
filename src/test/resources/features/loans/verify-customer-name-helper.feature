@ignore
Feature: Verify Customer Name Helper

  Scenario: Fetch application by ID and assert expected customer name and details
    Given url baseUrl + '/v1/loans/' + appId
    And header Authorization = authHeader
    When method GET
    Then status 200
    And match response.firstName == expectedFirstName
    And match response.lastName == expectedLastName
    And match response.email == expectedEmail
    * karate.log('Customer name verified for appId ' + appId + ': ' + response.firstName + ' ' + response.lastName)
