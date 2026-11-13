@ignore
Feature: External Screening Helper

  Background:
    * configure headers = authHeader

  Scenario: Execute external screening run-all
    * configure readTimeout = 15000
    Given url baseUrl
    And path '/v1/origination/draft/ref/' + appRef + '/external-screening/run-all'
    And request {}
    When method POST
