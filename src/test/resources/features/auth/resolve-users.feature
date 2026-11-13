@ignore
Feature: Resolve which seeded test accounts actually exist on THIS environment

  # Called ONCE per run from karate-config.js via karate.callSingle(), before any feature starts.
  # Everything it returns is exposed as a config variable, so feature files never name an account.
  #
  # ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────
  # karate-config.js used to hard-code one account per role — 'naga', 'AppUser2', 'manager1' — and
  # the lifecycle features hard-coded 'underwriter1'/'approver1'/'approver2' with 'Password123'.
  # Those are the names that happened to exist on the machine the suite was written on. On anybody
  # else's machine the same run fails in one of two ways, and neither error names the real cause:
  #
  #   * the account does not exist          -> 401 at login, or
  #   * it exists but holds the wrong role  -> 403 a hundred steps later, e.g.
  #       POST /v1/loans/{id}/claim                -> 403 ACCESS_DENIED (needs ACTION_UW_ASSESS)
  #       POST /v1/approval-limits                 -> 403 ACCESS_DENIED (needs MANAGE_APPROVAL_LIMITS)
  #       GET  /v1/master-data/document-checklists -> 403 ACCESS_DENIED (needs MENU_CONFIGURATION)
  #
  # ── WHAT IT DOES ─────────────────────────────────────────────────────────────────────────────
  # For each role SLOT the suite needs, it walks that slot's candidate usernames in order and keeps
  # the first one that can actually sign in. The candidate lists hold every name the role is known
  # by across our environments (V4__seed_data.sql seeds admin1/appuser1/underwriter1/...; some
  # machines also carry admin/appuser01/assessmentuser01/ccuser01), so ONE config now works on all
  # of them without anybody editing a file.
  #
  # Passwords are probed the same way: 'Password123' works on the team's current dev databases, while
  # a freshly migrated one uses 'Password@123' (the BCrypt hash V4__seed_data.sql assigns to every
  # seeded user verifies against that and not against 'Password123'). The first password that works
  # is remembered and tried first for every later account, so a normal run makes at most one wasted
  # attempt overall. Pin it with -Dlo.test.password=... to skip probing entirely.
  #
  # A username already taken by an earlier slot is never handed to a later one. That matters for the
  # credit committee: approver1 and approver2 MUST be two different people, otherwise the second
  # vote comes back "You have already cast your vote for committee 'APPROVER'".
  #
  # Every probe logs out immediately. The server allows one live session per user, so leaving these
  # sessions open would make each feature's own login a session takeover for no reason.
  #
  # Nothing here fails the run. A slot that could not be resolved falls back to its first candidate,
  # so the feature that needs it fails with that account's own 401/403 — and the summary printed
  # before the first feature says which slot was never found.
  #
  # ── PARAMETERS (all supplied by karate-config.js) ────────────────────────────────────────────
  #   baseUrl             required  as per karate-config
  #   roleCandidates      required  { slot: [username, ...] } in preference order
  #   slotOrder           required  the slot names, in the order they are resolved
  #   optionalSlots       required  slots whose absence is normal and must not warn
  #   passwordCandidates  required  passwords to try, in order
  #   checkerCandidates   required  extra accounts to probe for the four-eyes checker list
  #
  # ── RETURNS ──────────────────────────────────────────────────────────────────────────────────
  # Flat scalars only — <slot>Username / <slot>Password per slot, plus governanceCheckers,
  # resolvedSummary and unresolvedSlots. Deliberately flat: a nested object crossing the step
  # boundary comes back as a Java Map/List, whose JS members are not the ones plain JS expects.

  Scenario: Probe every role slot

    * def resolveAll =
    """
    function() {
      var notes = [];
      var taken = {};
      var knownPassword = null;

      // A login that does not throw on failure: an account that is absent on this environment has
      // to be skipped, not blow up the whole run before the first feature has even started.
      //
      // It also does NOT complete the session takeover. A 200 carrying requiresSessionConfirm already
      // proves the credentials are good, which is the only thing this probe needs to establish.
      // Calling /auth/confirm-session would seize that user's single allowed session — on a shared
      // environment that logs a colleague out of the UI, and it would do it to every account in the
      // candidate list before the first test even runs. No token is issued in that case, so there is
      // also nothing left behind to log out.
      function login(user, pass) {
        var res = karate.http(baseUrl + '/auth/login')
                        .header('Content-Type', 'application/json')
                        .post({ username: user, password: pass });
        // A 429 is the /auth/login rate limiter (core-commons RateLimitFilter, ~20 per 60s per IP
        // on a non-loopback server), NOT a missing account — but every non-200 below is read as
        // "this account does not exist here". Without this wait the probe silently mis-resolves
        // every slot after the twentieth attempt: each one is recorded UNRESOLVED, falls back to a
        // default that may be wrong, and the failure surfaces a hundred steps later as a 401/403
        // that names an account nobody chose. The bucket refills at roughly a token every 3s.
        var rateLimitWaits = 0;
        while (res.status == 429 && rateLimitWaits < 24) {
          rateLimitWaits = rateLimitWaits + 1;
          karate.log('[test-users] rate limited probing ' + user + ' — waiting 5s (' + rateLimitWaits + '/24)');
          java.lang.Thread.sleep(5000);
          res = karate.http(baseUrl + '/auth/login')
                      .header('Content-Type', 'application/json')
                      .post({ username: user, password: pass });
        }
        if (res.status != 200) return null;
        var body = res.body;
        if (body.requiresSessionConfirm == true) {
          return { token: null, roles: null, sessionElsewhere: true };
        }
        if (body.token == null || body.token == '') return null;
        return { token: body.token, roles: body.roles, sessionElsewhere: false };
      }

      function logout(token) {
        if (token == null) return;
        karate.http(baseUrl + '/auth/logout').header('Authorization', 'Bearer ' + token).post({});
      }

      // The password that already worked somewhere is by far the likeliest to work again, so try it
      // first and keep the number of failed login attempts on this environment to a minimum.
      function passwordsToTry() {
        var list = [];
        if (knownPassword != null) list.push(knownPassword);
        for (var i = 0; i < passwordCandidates.length; i++) {
          if (passwordCandidates[i] != knownPassword) list.push(passwordCandidates[i]);
        }
        return list;
      }

      function resolve(slot, candidates) {
        for (var i = 0; i < candidates.length; i++) {
          var user = candidates[i];
          if (taken[user] == true) continue;
          var passwords = passwordsToTry();
          for (var j = 0; j < passwords.length; j++) {
            var body = login(user, passwords[j]);
            if (body != null) {
              knownPassword = passwords[j];
              taken[user] = true;
              logout(body.token);
              notes.push(slot + ' -> ' + user + ' ' + (body.sessionElsewhere
                ? '(credentials valid; session already active elsewhere — not taken over)'
                : karate.toString(body.roles)));
              return { username: user, password: passwords[j] };
            }
          }
        }
        notes.push(slot + ' -> UNRESOLVED');
        return null;
      }

      // Lists arriving from karate-config.js are ProxyArrays: indexing and .length work, JS Array
      // methods such as indexOf() and join() do not. Hence the explicit loop.
      function isOptional(slot) {
        for (var i = 0; i < optionalSlots.length; i++) {
          if (optionalSlots[i] == slot) return true;
        }
        return false;
      }

      var users = {};
      var unresolved = [];
      for (var s = 0; s < slotOrder.length; s++) {
        var slot = slotOrder[s];
        users[slot] = resolve(slot, roleCandidates[slot]);
        if (users[slot] == null && !isOptional(slot)) unresolved.push(slot);
      }

      // ── Four-eyes checkers for approval-limit-helper ────────────────────────────────────────
      // POST /v1/approval-limits raises a ChangeRequest whose severity is SUPERVISOR_APPROVAL, so
      // the maker (the admin slot) may not approve its own submission — somebody else must. Prefer
      // a second ADMIN/MANAGER account, since only those two roles hold MANAGE_APPROVAL_LIMITS and
      // a checker that also holds it can never be the reason the flow stalls. Fall back to the
      // ordinary role accounts already resolved: the helper links whoever it uses as the maker's
      // supervisor itself, so any second account can act as the checker.
      var checkers = [];
      for (var c = 0; c < checkerCandidates.length; c++) {
        var extra = resolve('checker', [checkerCandidates[c]]);
        if (extra != null) checkers.push(extra);
      }
      var fallbackSlots = ['underwriter', 'approver2', 'setup', 'issuer', 'acceptor', 'officer'];
      for (var f = 0; f < fallbackSlots.length; f++) {
        var u = users[fallbackSlots[f]];
        if (u != null) checkers.push({ username: u.username, password: u.password });
      }

      // Flat result. A slot that resolved to nothing falls back to its first candidate so the error
      // it eventually produces names a real account; approver3 is the exception — see below.
      function username(slot, fallback) {
        return users[slot] != null ? users[slot].username : fallback;
      }
      function password(slot) {
        return users[slot] != null ? users[slot].password : passwordCandidates[0];
      }

      return {
        adminUsername:       username('admin',       'admin1'),
        adminPassword:       password('admin'),
        officerUsername:     username('officer',     'appuser1'),
        officerPassword:     password('officer'),
        underwriterUsername: username('underwriter', 'underwriter1'),
        underwriterPassword: password('underwriter'),
        approver1Username:   username('approver1',   'approver1'),
        approver1Password:   password('approver1'),
        approver2Username:   username('approver2',   'approver2'),
        approver2Password:   password('approver2'),
        // No fallback for approver3: a second vote from an account that has already voted is
        // rejected ("You have already cast your vote"), so an absent third member must stay absent.
        approver3Username:   users['approver3'] != null ? users['approver3'].username : null,
        approver3Password:   users['approver3'] != null ? users['approver3'].password : null,
        issuerUsername:      username('issuer',      'issueuser1'),
        issuerPassword:      password('issuer'),
        acceptorUsername:    username('acceptor',    'acceptuser1'),
        acceptorPassword:    password('acceptor'),
        setupUsername:       username('setup',       'setupuser1'),
        setupPassword:       password('setup'),
        governanceCheckers:  checkers,
        // Pre-joined here on purpose: these strings cross the step boundary, where a JS array would
        // arrive as a Java List and lose .join().
        resolvedSummary:     notes.join('\n  '),
        unresolvedSlots:     unresolved.join(', ')
      };
    }
    """

    * def probe = resolveAll()

    * print '[test-users] resolved accounts:\n  ' + probe.resolvedSummary
    * if (probe.unresolvedSlots != '') karate.log('[test-users] WARNING — no account found for:', probe.unresolvedSlots, '- features needing them will fail. Check which users are seeded on this environment, add the name to roleCandidates in karate-config.js, or pin the password with -Dlo.test.password=...')

    # karate-config.js reads these straight off the callSingle result.
    * def adminUsername       = probe.adminUsername
    * def adminPassword       = probe.adminPassword
    * def officerUsername     = probe.officerUsername
    * def officerPassword     = probe.officerPassword
    * def underwriterUsername = probe.underwriterUsername
    * def underwriterPassword = probe.underwriterPassword
    * def approver1Username   = probe.approver1Username
    * def approver1Password   = probe.approver1Password
    * def approver2Username   = probe.approver2Username
    * def approver2Password   = probe.approver2Password
    * def approver3Username   = probe.approver3Username
    * def approver3Password   = probe.approver3Password
    * def issuerUsername      = probe.issuerUsername
    * def issuerPassword      = probe.issuerPassword
    * def acceptorUsername    = probe.acceptorUsername
    * def acceptorPassword    = probe.acceptorPassword
    * def setupUsername       = probe.setupUsername
    * def setupPassword       = probe.setupPassword
    * def governanceCheckers  = probe.governanceCheckers
