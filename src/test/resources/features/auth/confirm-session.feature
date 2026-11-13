@ignore
Feature: Session confirmation helper

  Scenario: Confirm session takeover
    Given url baseUrl + '/auth/confirm-session'
    And request { confirmToken: '#(confirmToken)' }
    When method POST
    Then status 200
    * def token = response.token
