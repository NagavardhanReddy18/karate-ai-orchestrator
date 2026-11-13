@ignore
Feature: Authentication helper — called by other features to get a Bearer token

  # Usage in any feature:
  #   * def session = call read('classpath:features/auth/auth.feature') { username: 'admin', password: 'admin' }
  #   * def authHeader = 'Bearer ' + session.token
  #
  # Or use the shortcuts defined in karate-config.js:
  #   * def session = call read('classpath:features/auth/auth.feature') adminCredentials
  #   * def session = call read('classpath:features/auth/auth.feature') officerCredentials

  Scenario: Login and return token
    # Step 1: Fire Initial Login Request
    #
    # /auth/login is rate limited PER CLIENT IP by core-commons RateLimitFilter — and only loopback
    # is exempt, which is why a suite that is green on localhost:9090 falls over against a shared
    # server. Measured on 164.52.210.93: 20 logins per 60s, then HTTP 429 RATE_LIMITED. One full run
    # of this suite needs far more than that (the resolve-users probe alone spends ~13, then every
    # scenario Background signs in again, and each E2E lifecycle feature signs in as 8 roles), so
    # without this the run dies at whichever login happens to be number 21 — with a 429 that reads
    # like a broken account rather than a throttle.
    #
    # The bucket refills greedily at capacity/refill-seconds, i.e. about one token every 3s here, so
    # a short wait clears it. Only 429 is retried: a 401 is a genuinely bad credential and must
    # still fail immediately.
    #
    # 24 x 5s = 120s, i.e. TWO full refill windows. 12 x 5s (one window) was measured as just barely
    # enough on an idle server and was observed failing on a shared office IP, in the last feature of
    # a full run — by then the suite has spent ~85 logins and is competing with the beyond-ui
    # frontend and other testers behind the same NAT for the same per-IP bucket, so a share of every
    # refill goes to somebody else and one window is no longer sufficient.
    #
    # This is a tolerance, not a cure: a full run is rate-limit-bound end to end. The real fix is
    # server-side — beyond-lo-app/application.yml already specifies app.rate-limit.auth.capacity 5000,
    # and the deployed instance is not honouring it (measured: 20/60s).
    * configure retry = { count: 24, interval: 5000 }
    Given url baseUrl + '/auth/login'
    And request { username: '#(username)', password: '#(password)' }
    And retry until responseStatus != 429
    When method POST
    Then status 200

    # Step 2: If the server reports an existing active session it returns requiresSessionConfirm=true
    # plus a confirmToken. In that case confirm the takeover (delegated to confirm-session.feature,
    # which POSTs to /auth/confirm-session and returns the real bearer token). Otherwise the login
    # response already carries the token.
    * def isConfirm = response.requiresSessionConfirm == true
    * def loginResult = isConfirm ? karate.call('classpath:features/auth/confirm-session.feature', { confirmToken: response.confirmToken }) : response
    * def token = loginResult.token

    # Step 3: Final validation matching for downstream automation contexts.
    # `#notnull` rather than `#present`: `#present` only asserts the key exists, so a login that
    # answers 200 with a null/empty token used to pass here and then surfaced as an unexplained 401
    # in whichever feature happened to use the token next. Fail at the login instead.
    * match token == '#notnull'
    * assert token.length > 0
