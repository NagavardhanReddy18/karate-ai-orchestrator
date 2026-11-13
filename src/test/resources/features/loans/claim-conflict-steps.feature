@ignore
Feature: Reusable claim conflict steps

  # LoanApplicationService.claimApplication() raises ApplicationAlreadyClaimedException only when
  #     app.getAssignedTo() != null && !app.getAssignedTo().equals(currentUser)
  # i.e. the exclusive working lock conflicts on a DIFFERENT user. Re-claiming as the SAME user is
  # idempotent and returns 200 — so the previous version of this helper, which POSTed /claim twice
  # with one token, could never produce a 409. The second claim must come from another account.
  #
  # Note the assignedTo check runs BEFORE the claim-permission check, so the second user does not
  # need claim rights on the application's current state to observe the conflict.
  #
  # Params: appId, baseUrl, authHeader (first claimant), otherAuthHeader (second, different user)

  Scenario: Claim twice as two different users and expect conflict on the second attempt
    Given url baseUrl
    And path '/v1/loans/' + appId + '/claim'
    And header Authorization = authHeader
    When method POST
    Then status 200

    Given url baseUrl
    And path '/v1/loans/' + appId + '/claim'
    And header Authorization = otherAuthHeader
    When method POST
    Then status 409
    # ErrorCode.APPLICATION_ALREADY_CLAIMED — not the shorter 'ALREADY_CLAIMED' this asserted
    # before. Matches LoanApplicationControllerTest, which expects $.code = APPLICATION_ALREADY_CLAIMED.
    And match response.code == 'APPLICATION_ALREADY_CLAIMED'
    And match response.detail contains 'already claimed by'
