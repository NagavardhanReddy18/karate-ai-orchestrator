@ignore
Feature: Get Origination Draft Helper

  Background:
    * url baseUrl
    * configure headers = { Authorization: '#(authHeader)' }

  Scenario: Get draft application by ID
    Given path '/v1/origination/draft/' + draftId
    When method GET
    * def draft = (responseStatus == 200 && response) ? response : null
