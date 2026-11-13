@regression @phases
Feature: Phase transitions and execution

  Background:
    * url baseUrl
    * def session = call read('classpath:features/auth/auth.feature') { username: '#(adminUsername)', password: '#(adminPassword)' }
    * header Authorization = 'Bearer ' + session.token

  @smoke
  Scenario: List available phases
    Given path '/v1/phases'
    When method GET
    Then status 200
    And match response == '#array'

  @smoke
  Scenario: List available phase statuses
    Given path '/v1/phases/statuses'
    When method GET
    Then status 200
    And match response == '#array'

  @regression
  Scenario: Get current phase for application
    Given path '/v1/phases/applications/1/current'
    When method GET
    Then match [200, 404] contains responseStatus

  @regression
  Scenario: Get phase history for application
    Given path '/v1/phases/applications/1/history'
    When method GET
    Then match [200, 404, 500] contains responseStatus

  @regression
  Scenario: Check if application can transition to a phase
    Given path '/v1/phases/applications/1/can-transition/SUBMITTED'
    When method GET
    Then match [200, 404] contains responseStatus
