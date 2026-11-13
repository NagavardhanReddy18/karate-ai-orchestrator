@smoke @regression @auth
Feature: Authentication — login, logout, invalid credentials

  Background:
    * url baseUrl

  @smoke
  Scenario: Successful login with valid credentials
    Given path '/auth/login'
    And request { username: '#(adminUsername)', password: '#(adminPassword)' }
    When method POST
    Then status 200
    # /auth/login has two valid 200 shapes. When the account has no active session it returns the
    # bearer directly { token, username, roles }. When one IS active — which is the normal case for
    # this shared account, and always the case once another feature in the run has logged in — the
    # server answers the session-takeover challenge instead:
    # { requiresSessionConfirm: true, confirmToken, existingSessions }, and the bearer is only
    # issued by POST /auth/confirm-session. Asserting `response.token` unconditionally therefore
    # fails purely on run order. Accept either shape.
    #
    # Deliberately NOT calling /auth/confirm-session here: confirming would take over the session
    # and revoke the token every other feature in this run is holding.
    And assert response.token != null || response.confirmToken != null
    * def loggedInDirectly = response.token != null
    * if (loggedInDirectly) karate.match(response.username, '#string')
    * if (loggedInDirectly) karate.match(response.roles, '#array')
    * if (!loggedInDirectly) karate.match(response.requiresSessionConfirm, true)

  @regression
  Scenario: Login fails with wrong password
    Given path '/auth/login'
    And request { username: '#(adminUsername)', password: 'wrongpassword' }
    When method POST
    Then status 401

  @regression
  Scenario: Login fails with non-existent user
    Given path '/auth/login'
    And request { username: 'nobody@nowhere.com', password: 'irrelevant' }
    When method POST
    Then status 401

  @regression
  Scenario: Login request with missing username returns 400
    Given path '/auth/login'
    And request { password: 'admin' }
    When method POST
    Then status 400

  @regression
  Scenario: Protected endpoint rejects request without token
    Given path '/v1/loans'
    When method GET
    # 401 UNAUTHORIZED ("Authentication required"), not 403. The entry point now distinguishes
    # unauthenticated (401) from authenticated-but-forbidden (403); the old comment here claimed
    # this app returned 403 for unauthenticated requests, which is no longer true.
    Then status 401

  @regression
  Scenario: Protected endpoint rejects request with expired/fake token
    Given path '/v1/loans'
    And header Authorization = 'Bearer this.is.not.a.real.token'
    When method GET
    # An unparseable/expired bearer is still "not authenticated" -> 401, not 403.
    Then status 401
