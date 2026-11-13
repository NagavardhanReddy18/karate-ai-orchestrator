@ignore
Feature: Ensure an ACTIVE approval limit covers a loan amount

  # Called from the Background of every E2E lifecycle feature, BEFORE the wizard runs:
  #
  #   * def limitSetup = karate.call('classpath:features/loans/approval-limit-helper.feature',
  #       { baseUrl: baseUrl, makerAuthHeader: calculatedHeader, makerUsername: adminUsername,
  #         loanType: 'PERSONAL_LOAN', partyType: 'PERSONAL', facilityType: 'LOAN',
  #         currencyCode: 'USD', requiredAmount: 140000, limitAmount: 1000000 })
  #
  # ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────
  # `POST /v1/assessment/{id}/uw-action` with action APPROVE_TO_APPROVER refuses to route to the
  # approver stage unless an ACTIVE approval limit covers the loan amount:
  #
  #   400 "No approval limit is configured that covers the loan amount 140000.000000 USD."
  #
  # That limit is server *configuration*, not test data. On a machine where somebody once created
  # it through the UI the E2E features pass; on a freshly migrated database they fail — which is
  # exactly the local-passes / other-environment-fails split this helper was written to close.
  #
  # ── WHY THE OLD INLINE `setupLimit()` NEVER WORKED ON A FRESH DATABASE ───────────────────────
  # Each of the four lifecycle features carried its own copy of the bootstrap and each copy was
  # wrong in its own way:
  #
  #   * 04 tested for HTTP 201. `POST /v1/approval-limits` returns **202 Accepted** — it does not
  #     create a limit at all, it raises a governance ChangeRequest (ApprovalLimitController:
  #     "there are no approve/reject endpoints on this controller any more"). 201 never happens,
  #     so 04 always took the `else` branch and created nothing.
  #   * 05/06/07 did handle 202 and the change-request flow, but hard-coded `admin1`/`Password123`
  #     as the checker and hard-coded `/approve` + `/commit` with no check that either succeeded.
  #   * All four swallowed every failure into `karate.log(...)` and returned normally, so the
  #     Background always "passed" and the run died ~100 lines later at uw-action with a message
  #     that says nothing about the real cause.
  #
  # ── WHAT THE SERVER ACTUALLY REQUIRES (verified against beyond-lo-core + core-governance) ────
  #   1. `POST /v1/approval-limits` -> 202 + a ChangeRequest. Needs MANAGE_APPROVAL_LIMITS.
  #   2. Event code APPROVAL_LIMIT_CHANGE is seeded (core-db V21) with severity
  #      SUPERVISOR_APPROVAL, so the request lands PENDING_APPROVAL and **four-eyes applies**:
  #      ChangeRequestService.canApprove() returns false for the initiator ("Cannot approve your
  #      own request"), so the admin cannot sign off its own submission. A second user must.
  #   3. Who that second user may be is decided by AuthorityEngine -> SupervisorAuthorityResolver
  #      -> ApproverChainResolver -> core-iam's UserSupervisorLinkService, i.e. by the rows in
  #      `/v1/supervisor-links`. With no link for the maker, `AuthorityDecision.none()` comes back
  #      and *nobody* can approve — the request is stuck forever. This helper creates the link.
  #   4. `POST /v1/change-requests/{id}/commit` by someone holding MANAGE_APPROVAL_LIMITS is what
  #      finally writes the ACTIVE row (ApprovalLimitService.apply -> applyCreate).
  #
  # ── CONTRACT ─────────────────────────────────────────────────────────────────────────────────
  # Idempotent: if an ACTIVE limit already covers the amount it does nothing, so it is a no-op on
  # an environment that is already configured and on every re-run.
  # Fail-fast: if it cannot end with a covering limit it fails HERE, in the Background, with the
  # server's own status codes and response bodies in the message — not 100 lines downstream.
  #
  # ── PARAMETERS ───────────────────────────────────────────────────────────────────────────────
  #   baseUrl          required  as per karate-config
  #   makerAuthHeader  required  'Bearer …' of the user submitting the change (the admin)
  #   makerUsername    required  that user's username — needed for the supervisor link
  #   loanType         required  MUST equal the draft's `loanProductType`: the server resolves
  #                              limits by LoanApplication.loanType, which submit copies verbatim
  #                              from loanProductType (LoanOriginationService).
  #   partyType        required  PERSONAL | ENTERPRISE — as PartyTypeResolver classifies the app
  #   currencyCode     required  must equal the draft's loanAmountCurrency
  #   requiredAmount   required  the loan amount the limit has to cover
  #   limitAmount      required  the limit to create. Must be UNIQUE across every limit on this
  #                              loanType/partyType/currency (ApprovalLimitService.validateCcConfig
  #                              rule 2 rejects a duplicate amount) and >= requiredAmount.
  #   facilityType     optional  LOAN | OVERDRAFT, default LOAN. Recorded on the limit; resolution
  #                              itself keys on loanType, so this is descriptive only.
  #   committeeName    optional  committee role name, default APPROVER
  #   votesRequired    optional  default 2. Must be <= the number of active members of that role
  #                              (validateCcConfig rule 1), i.e. approver1 + approver2.
  #   effectiveFrom    optional  default 2020-01-01 — any past date; resolution requires
  #                              effectiveFrom <= CURRENT_DATE.

  Scenario: Ensure an ACTIVE approval limit exists

    * def facility = karate.get('facilityType', 'LOAN')
    * def committee = karate.get('committeeName', 'APPROVER')
    * def votes = karate.get('votesRequired', 2)
    * def fromDate = karate.get('effectiveFrom', '2020-01-01')
    * def today = java.time.LocalDate.now().toString()
    * def party = karate.get('partyType', null)
    * def partyType = (party && party != '') ? party : null

    # Render any response body — including a non-JSON error page — without throwing.
    * def show =
    """
    function(res) {
      var body = '';
      try { body = res.body == null ? '' : karate.pretty(res.body); } catch (e) { body = '' + res.body; }
      return 'HTTP ' + res.status + ' ' + body;
    }
    """

    # Sign in without the hard `status 200` of auth.feature: a checker account that does not exist
    # on this environment must be skipped, not blow up the whole run.
    * def softLogin =
    """
    function(user, pass, note) {
      var res = karate.http(baseUrl + '/auth/login')
                      .header('Content-Type', 'application/json')
                      .post({ username: user, password: pass });
     
      // 429 is the login rate limiter, not a bad checker. Treating it as one skips an account that
      // would have worked and can exhaust the whole list, failing the bootstrap with "no configured
      // checker could approve" on an environment that is in fact configured correctly.
      var rateLimitWaits = 0;
      while (res.status == 429 && rateLimitWaits < 24) {
        rateLimitWaits = rateLimitWaits + 1;
        note('rate limited signing in ' + user + ' — waiting 5s (' + rateLimitWaits + '/24)');
        java.lang.Thread.sleep(5000);
        res = karate.http(baseUrl + '/auth/login')
                    .header('Content-Type', 'application/json')
                    .post({ username: user, password: pass });
      }
      if (res.status != 200) {
        note('login ' + user + ' -> HTTP ' + res.status);
        return null;
      }
      var body = res.body;
      // Same session-takeover dance as auth.feature.
      if (body.requiresSessionConfirm == true) {
        var confirmRes = karate.http(baseUrl + '/auth/confirm-session')
                               .header('Content-Type', 'application/json')
                               .post({ confirmToken: body.confirmToken });
        if (confirmRes.status != 200) {
          note('confirm-session for ' + user + ' -> HTTP ' + confirmRes.status);
          return null;
        }
        body = confirmRes.body;
      }
      if (body.token == null || body.token == '') {
        note('login ' + user + ' returned no token');
        return null;
      }
      return 'Bearer ' + body.token;
    }
    """

    # core-iam decides who may approve a governed change from these rows. entityType left null so
    # the link applies to every governed entity type, APPROVAL_LIMIT included.
    * def linkSupervisor =
    """
    function(user, supervisor, note) {
      var existing = karate.http(baseUrl + '/v1/supervisor-links/by-user/' + user)
                           .header('Authorization', makerAuthHeader)
                           .get();
      if (existing.status == 200 && existing.body != null) {
        for (var i = 0; i < existing.body.length; i++) {
          if (existing.body[i].supervisorUsername == supervisor && existing.body[i].active) {
            note(supervisor + ' is already a supervisor of ' + user);
            return;
          }
        }
      }
      var res = karate.http(baseUrl + '/v1/supervisor-links')
                      .header('Authorization', makerAuthHeader)
                      .header('Content-Type', 'application/json')
                      .post({ userUsername: user, supervisorUsername: supervisor, active: true });
      note('link ' + user + ' -> ' + supervisor + ': HTTP ' + res.status);
    }
    """

    * def coveringLimit =
    """
    function(note) {
      var url = baseUrl + '/v1/approval-limits?status=ACTIVE&size=200'
              + '&loanType=' + encodeURIComponent(loanType)
              + '&currencyCode=' + encodeURIComponent(currencyCode);
      var res = karate.http(url).header('Authorization', makerAuthHeader).get();
      if (res.status != 200) {
        note('GET /v1/approval-limits -> ' + show(res));
        return null;
      }
      var rows = res.body.content;
      if (rows == null) rows = [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (partyType != null && row.partyType != null && row.partyType != partyType) continue;
        if (row.subProductCode != null && row.subProductCode != '') {
          note('ignoring limit ' + row.id + ' — it is bound to subProductCode '
               + row.subProductCode + ', so it does not cover every product of this loanType');
          continue;
        }
        if (row.effectiveFrom != null && row.effectiveFrom > today) continue;
        if (row.effectiveTo != null && row.effectiveTo < today) continue;
        if (Number(row.limitAmount) >= Number(requiredAmount)) return row;
      }
      return null;
    }
    """

    * def ensureLimit =
    """
    function() {
      var steps = [];
      var note = function(m) { steps.push(m); karate.log('[approval-limit]', m); };
      var done = function(ok, msg) {
        note(msg);
        return { ready: ok, loanType: loanType, requiredAmount: requiredAmount, steps: steps };
      };

      // ── 1. Is the environment already configured? ──────────────────────────────────────────
      var existing = coveringLimit(note);
      if (existing != null) {
        return done(true, 'already configured: limit ' + existing.id + ' (' + existing.authorityType
                 + '/' + existing.authorityName + ') covers ' + requiredAmount + ' ' + currencyCode
                 + ' with ' + existing.limitAmount + ' — nothing to do');
      }
      note('no ACTIVE limit covers ' + requiredAmount + ' ' + currencyCode + ' for loanType '
           + loanType + ' — bootstrapping/amending one');

      // ── 2. Raise the change request (CREATE or AMEND) ──────────────────────────────────────
      var targetLimitAmount = Math.max(Number(limitAmount), Number(requiredAmount) * 2, 1000000000);
      
      var searchUrl = baseUrl + '/v1/approval-limits?status=ACTIVE&loanType=' + encodeURIComponent(loanType)
                    + '&currencyCode=' + encodeURIComponent(currencyCode);
      var searchRes = karate.http(searchUrl).header('Authorization', makerAuthHeader).get();
      var existingList = (searchRes.status == 200 && searchRes.body && searchRes.body.content) ? searchRes.body.content : [];
      var existingObj = null;
      for (var e = 0; e < existingList.length; e++) {
        if (existingList[e].authorityType == 'CREDIT_COMMITTEE') { existingObj = existingList[e]; break; }
      }

      var cr = null;
      if (existingObj != null) {
        note('found existing ACTIVE limit ' + existingObj.id + ' with limitAmount ' + existingObj.limitAmount + ' < ' + requiredAmount + ' — requesting amendment to ' + targetLimitAmount);
        var amendPayload = {
          id: existingObj.id,
          authorityType: existingObj.authorityType || 'CREDIT_COMMITTEE',
          authorityName: existingObj.authorityName || committee,
          facilityType: existingObj.facilityType || facility,
          loanType: loanType,
          partyType: existingObj.partyType || partyType,
          currencyCode: currencyCode,
          limitAmount: targetLimitAmount,
          votesRequired: existingObj.votesRequired || votes,
          effectiveFrom: existingObj.effectiveFrom || fromDate
        };
        var amendRes = karate.http(baseUrl + '/v1/approval-limits/' + existingObj.id + '/request-amendment')
                             .header('Authorization', makerAuthHeader)
                             .header('Content-Type', 'application/json')
                             .put(amendPayload);
        if (amendRes.status == 200 || amendRes.status == 202) {
          cr = amendRes.body;
        } else {
          return done(false, 'PUT /v1/approval-limits/' + existingObj.id + '/request-amendment returned ' + show(amendRes) + ' for payload ' + karate.pretty(amendPayload));
        }
      } else {
        var createPayload = {
          authorityType: 'CREDIT_COMMITTEE',
          authorityName: committee,
          facilityType: facility,
          loanType: loanType,
          currencyCode: currencyCode,
          limitAmount: targetLimitAmount,
          votesRequired: votes,
          effectiveFrom: fromDate
        };
        var createRes = karate.http(baseUrl + '/v1/approval-limits')
                              .header('Authorization', makerAuthHeader)
                              .header('Content-Type', 'application/json')
                              .post(createPayload);
        if (createRes.status == 202) {
          cr = createRes.body;
        } else {
          return done(false, 'POST /v1/approval-limits was expected to raise a change request (202) but returned ' + show(createRes) + ' for payload ' + karate.pretty(createPayload));
        }
      }

      note('change request ' + cr.id + ' raised (status=' + cr.status
           + ', severity=' + cr.eventSeverity + ')');

      // ── 3. Get it APPROVED ─────────────────────────────────────────────────────────────────
      if (cr.status != 'APPROVED') {
        if (cr.eventSeverity == 'WARNING') {
          // A WARNING severity request may be self-acknowledged by its initiator.
          var proceedRes = karate.http(baseUrl + '/v1/change-requests/' + cr.id + '/proceed')
                                 .header('Authorization', makerAuthHeader)
                                 .header('Content-Type', 'application/json')
                                 .post({});
          if (proceedRes.status != 200) {
            return done(false, 'self-proceed on change request ' + cr.id + ' -> ' + show(proceedRes));
          }
          note('change request ' + cr.id + ' self-approved (WARNING severity)');
        } else {
          // Four-eyes: a *different* user, named as the maker's supervisor, has to sign off.
          var approved = false;
          for (var c = 0; c < governanceCheckers.length && !approved; c++) {
            var candidate = governanceCheckers[c];
            if (candidate.username == makerUsername) continue;

            var checkerHeader = softLogin(candidate.username, candidate.password, note);
            if (checkerHeader == null) {
              note('checker ' + candidate.username + ' could not sign in — trying the next one');
              continue;
            }
            linkSupervisor(makerUsername, candidate.username, note);

            var approveRes = karate.http(baseUrl + '/v1/change-requests/' + cr.id + '/approve')
                                   .header('Authorization', checkerHeader)
                                   .header('Content-Type', 'application/json')
                                   .post({ comment: 'Approved by the Karate E2E approval-limit bootstrap' });
            if (approveRes.status == 200) {
              note('change request ' + cr.id + ' approved by ' + candidate.username);
              approved = true;
            } else {
              note('checker ' + candidate.username + ' could not approve: ' + show(approveRes));
            }

            // Clean up checker session
            var logoutRes = karate.http(baseUrl + '/auth/logout')
                                  .header('Authorization', checkerHeader)
                                  .post({});
            note('logout checker ' + candidate.username + ': HTTP ' + logoutRes.status);
          }
          if (!approved) {
            return done(false, 'no configured checker could approve change request ' + cr.id + '. '
                     + 'Four-eyes means the maker (' + makerUsername + ') cannot approve its own '
                     + 'submission, and the approver is resolved from /v1/supervisor-links. Add a '
                     + 'working checker account to governanceCheckers in karate-config.js, or link '
                     + 'a supervisor to ' + makerUsername + ' on the server.');
          }
        }
      }

      // ── 4. Commit — this is what actually writes the ACTIVE row ────────────────────────────
      var commitRes = karate.http(baseUrl + '/v1/change-requests/' + cr.id + '/commit')
                            .header('Authorization', makerAuthHeader)
                            .header('Content-Type', 'application/json')
                            .post({});
      if (commitRes.status != 200) {
        return done(false, 'commit of change request ' + cr.id + ' -> ' + show(commitRes));
      }
      note('change request ' + cr.id + ' committed');

      // ── 5. Prove it — do not trust the write, re-read it ───────────────────────────────────
      var created = coveringLimit(note);
      if (created == null) {
        return done(false, 'change request ' + cr.id + ' committed but no ACTIVE limit covering '
                 + requiredAmount + ' ' + currencyCode + ' can be resolved for loanType ' + loanType
                 + '. Check that loanType matches the draft loanProductType exactly.');
      }
      return done(true, 'created limit ' + created.id + ' — ' + created.limitAmount + ' '
               + currencyCode + ' for ' + loanType);
    }
    """

    * def result = ensureLimit()
    * print '[approval-limit]', loanType, '=>', result

    # On failure the mismatch report prints `result` in full, so the reason — the server's own
    # status codes and response bodies, collected in `steps` — lands in the build log.
    * match result contains { ready: true }
