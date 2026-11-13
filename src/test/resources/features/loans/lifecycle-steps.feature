@ignore
Feature: Reusable lifecycle steps — called after a successful wizard submission

  Scenario: Claim, add note, and verify history
    Given url baseUrl
    And path '/v1/loans/' + appId + '/claim'
    And header Authorization = authHeader
    When method POST
    Then status 200
    And match response.id == appId

    Given url baseUrl
    And path '/v1/loans/' + appId + '/notes'
    And header Authorization = authHeader
    And request { note: 'Customer documents verified. Proceeding with assessment.' }
    When method POST
    Then status 201
    And match response.note == '#string'

    Given url baseUrl
    And path '/v1/loans/' + appId + '/notes'
    And header Authorization = authHeader
    When method GET
    Then status 200
    And match response == '#array'

    Given url baseUrl
    And path '/v1/loans/' + appId + '/status-history'
    And header Authorization = authHeader
    When method GET
    Then status 200
    And match response == '#array'
