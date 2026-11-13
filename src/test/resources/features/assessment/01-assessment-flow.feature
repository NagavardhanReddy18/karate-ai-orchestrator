@regression @assessment
Feature: Underwriter assessment workflow

  Background:
    * url baseUrl
    # The Underwriter owns assessment. /v1/assessment/{id} and its comments thread only require an
    # authenticated caller, but uw-action is gated on ACTION_UW_ASSESS, so the Underwriter is the role
    # this feature is actually about — and it is not the account every other feature signs in as,
    # which is what used to make the shared-session 401 below so frequent.
    * def session = call read('classpath:features/auth/auth.feature') { username: '#(underwriterUsername)', password: '#(underwriterPassword)' }

    # `configure headers` (persistent) rather than a bare `header` step (one-shot). A `header` set
    # here is dropped after the first request of the scenario, so it does NOT survive the
    # `retry until` below — attempt 2 onwards would go out unauthenticated and 401 forever.
    * def bearer = 'Bearer ' + session.token
    * configure headers = { Authorization: '#(bearer)', 'Content-Type': 'application/json' }

    # Every feature in this suite signs in as the same shared account. The server allows one live
    # session per user (that is what auth.feature's requiresSessionConfirm branch handles), so a
    # login elsewhere — including a human logged into the UI on the same environment — takes the
    # session over and can leave the freshly issued token rejected for a moment. Three quick
    # retries ride that out; a token that is genuinely not valid still fails, it is not papered over.
    * configure retry = { count: 3, interval: 1000 }

  @regression
  Scenario: Get or create assessment record for an application
    Given path '/v1/assessment/1'
    And retry until responseStatus != 401
    When method GET
    Then match [200, 404] contains responseStatus

  @regression
  Scenario: Add a comment to the assessment thread
    Given path '/v1/assessment/1/comments'
    And request
      """
      {
        "commentText": "Income documents reviewed. Customer salary slips for 3 months verified."
      }
      """
    And retry until responseStatus != 401
    When method POST
    Then match [200, 404] contains responseStatus

  @regression
  Scenario: Get scorecard evaluation for an application
    Given path '/v1/assessment/1/scorecard-evaluation'
    And retry until responseStatus != 401
    When method GET
    Then match [200, 404] contains responseStatus

  @regression
  Scenario: Assessment comment cannot be empty
    Given path '/v1/assessment/1/comments'
    And request { commentText: '' }
    And retry until responseStatus != 401
    When method POST
    # Expect 400 (validation) or 404 (application not found)
    * def sc = responseStatus
    * assert sc == 400 || sc == 404
