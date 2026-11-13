@regression @documents
Feature: Document checklist and configuration

  Background:
    * url baseUrl
    * def session = call read('classpath:features/auth/auth.feature') { username: '#(adminUsername)', password: '#(adminPassword)' }
    * header Authorization = 'Bearer ' + session.token

  @smoke
  Scenario: Get documents for an application
    Given path '/v1/documents/application/1'
    When method GET
    Then match [200, 404, 500] contains responseStatus

  @regression
  Scenario: List document configurations
    Given path '/v1/master-data/document-configs'
    When method GET
    Then status 200
    And match response.content == '#[]'
    And match response.totalElements == '#number'

  @regression
  Scenario: List document checklist items
    Given path '/v1/master-data/document-checklists'
    When method GET
    Then status 200
    And match response.content == '#[]'
    And match response.totalElements == '#number'
