@ignore
Feature: Resubmit Draft Application Helper

  Scenario: Resubmit Draft
    * url baseUrl
    * configure headers = { Authorization: '#(authHeader)', 'Content-Type': 'application/json' }
    Given path '/v1/origination/draft/' + draftId + '/submit'
    When method POST
    Then status 200
    * def resubmittedResponse = response
