@ignore
Feature: Logout helper

  Scenario: Logout user session
    Given url baseUrl + '/auth/logout'
    And header Authorization = authHeader
    When method POST
    Then status 200
