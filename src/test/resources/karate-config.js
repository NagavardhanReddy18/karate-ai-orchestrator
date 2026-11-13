/**
 * karate-config.js — Global configuration loaded before every feature file.
 *
 * Environment selection:
 *   mvn test -Dkarate.env=dev        (default)
 *   mvn test -Dkarate.env=staging
 *   mvn test -Dkarate.env=production
 *
 * Credentials live HERE and nowhere else. No feature file names an account.
 */
function fn() {

    // ── Environment definitions ───────────────────────────────────────────────
    var env = karate.env || 'dev';

    var config = { env: env };

    // Evaluated first: maps dev to 9090 and staging/test to 9190
    if (env === 'local') {
        config.baseUrl = 'http://localhost:9090/api';
    } else if (env === 'dev') {
        config.baseUrl = 'http://164.52.210.93:9090/api';
    } else if (env === 'staging' || env === 'test' || env === '9190') {
        config.baseUrl = 'http://164.52.210.93:9190/api';
    } else if (env === 'production') {
        config.baseUrl = 'http://prod.beyondlo.internal/api';
    } else {
        config.baseUrl = 'http://localhost:9090/api';
    }

    // Explicit override for any environment — handy for a one-off host or a changed port.
    if (karate.properties['lo.test.baseUrl']) {
        config.baseUrl = karate.properties['lo.test.baseUrl'];
    }

    // ── Passwords ─────────────────────────────────────────────────────────────
    // Two are in use across our machines, so both are probed and the first that works is then used
    // for every account:
    //
    //   'Password123'   our dev databases — this is the one that works on the team's current locals.
    //   'Password@123'  a freshly migrated database. Not a guess: the BCrypt hash V4__seed_data.sql
    //                   assigns to every seeded user,
    //                   $2a$10$FOGx8a8ykVPG8hTeMPQhUewHxPgnhg0xRXJCZ8FmmqFuY7EYCeD2.
    //                   verifies against 'Password@123' and NOT against 'Password123'. So this must
    //                   stay in the list, or the suite breaks on any newly created database.
    //
    // Pin one (and skip probing) with -Dlo.test.password=..., which is also how staging/production
    // passwords are supplied — never commit those.
    var passwordCandidates = ['Password123', 'Password@123'];
    var pinned = karate.properties['lo.test.password']
        || (env === 'staging' ? karate.properties['staging.admin.password'] : null)
        || (env === 'production' ? karate.properties['prod.admin.password'] : null);
    if (pinned) {
        passwordCandidates = [pinned];
    }

    // ── Role slots ────────────────────────────────────────────────────────────
    // One slot per job the suite has to perform, because the server gates each step on a DIFFERENT
    // permission and no single account is guaranteed to hold all of them. Verified against
    // beyond-lo-core (@PreAuthorize) + V4__seed_data.sql / V26__action_permissions.sql (role grants):
    //
    //   slot         needs                     held by role   used for
    //   ───────────────────────────────────────────────────────────────────────────────────────────
    //   admin        MANAGE_APPROVAL_LIMITS      ADMIN, MANAGER approval-limit bootstrap (maker),
    //                MENU_CONFIGURATION                         document/master-data configuration
    //   officer      MENU_APP_CREATE             LOAN_OFFICER   origination: draft, update, submit
    //   underwriter  ACTION_UW_ASSESS            UNDERWRITER    claim at SUBMITTED, intake task,
    //                                                           assessment comment, uw-action
    //   approver1/2  ACTION_APPROVER_REVIEW      APPROVER       the two credit-committee votes
    //   issuer       ACTION_ISSUE_OFFER          ISSUE_OFFER    issue the offer
    //   acceptor     ACTION_ACCEPT_OFFER         ACCEPT_OFFER   accept the offer
    //   setup        ACTION_LOAN_SETUP           SETUP          loan setup + send to CBS
    //
    // Note the first claim of the run: /v1/loans/{id}/claim on a SUBMITTED application requires
    // ACTION_UW_ASSESS (LoanApplicationService.requiredClaimPermission), which is why the intake
    // stage belongs to the underwriter and not to the officer who submitted the application.
    //
    // Each list holds every name the role is known by across our environments, most-expected first.
    // The first one that can sign in wins; a name already used by an earlier slot is skipped, so
    // approver1 and approver2 can never collapse onto the same person. Add a name here — never in a
    // feature file — when an environment uses a different one.
    var slotOrder = ['admin', 'officer', 'underwriter', 'approver1', 'approver2', 'approver3',
        'issuer', 'acceptor', 'setup'];

    var isTest9190 = config.baseUrl.indexOf('9190') !== -1 || env === 'test';

    var roleCandidates = {
        // 'naga' last: on the shared environment admin1 sits behind an email OTP that cannot be
        // automated, and 'naga' is the account that was created there to get around it. Keep it after
        // the real admin names so a properly seeded machine never picks it up.
        admin: ['admin', 'admin1', 'admin2', 'manager1', 'manager2', 'naga'],
        officer: ['appuser01', 'appuser1', 'appuser2'],
        underwriter: ['underwriter1', 'assessmentuser01', 'underwriter2'],
        // Approver 1: on 9190 test server ccuser01 is prioritized, while on 9090 dev server approver1 is used
        approver1: isTest9190
            ? ['ccuser01', 'approver1', 'approver2', 'admin1', 'admin', 'manager1']
            : ['approver1', 'approver2', 'admin1', 'admin', 'manager1'],
        approver2: ['approver2', 'approver1'],
        // Third committee member — only 07 (enterprise overdraft) needs one, and only where the
        // applicable limit sets votesRequired: 3. Absent on a purely seeded environment, which has
        // exactly two APPROVER users; 07 skips the third vote when this is unresolved.
        approver3: ['approver3', 'ccuser01'],
        issuer: ['issueuser1', 'issueuser2'],
        acceptor: ['acceptuser1', 'acceptuser2'],
        setup: ['setupuser1', 'setupuser2']
    };

    // Second ADMIN/MANAGER accounts, probed only to head the four-eyes checker list — see
    // resolve-users.feature. The admin slot itself is excluded automatically (already taken).
    var checkerCandidates = ['admin2', 'admin1', 'manager1', 'manager2'];

    // ── Resolve the accounts that exist here — once per run ───────────────────
    var probe = null;
    try {
        probe = karate.callSingle('classpath:features/auth/resolve-users.feature', {
            baseUrl: config.baseUrl,
            roleCandidates: roleCandidates,
            slotOrder: slotOrder,
            optionalSlots: ['approver3'],
            passwordCandidates: passwordCandidates,
            checkerCandidates: checkerCandidates
        });
    } catch (e) {
        // Almost always "server not running on baseUrl". Fall through to the defaults so the failure
        // surfaces as a connection error in the first feature rather than as a config crash here.
        var message = '[test-users] could not probe accounts on ' + config.baseUrl + ' - falling back to the seeded defaults. Cause: ' + e;
        karate.log(message);
    }

    // Read the probe's flat scalars by plain property access — the form karate.callSingle() results
    // are documented to support. `resolved` keeps the fallbacks working when the probe never ran.
    var resolved = probe ? probe : {};

    function account(username, password, fallbackUser) {
        if (username != null && username != '') {
            return { username: username, password: password };
        }
        return { username: fallbackUser, password: passwordCandidates[0] };
    }

    var admin = account(resolved.adminUsername, resolved.adminPassword, 'admin1');
    var officer = account(resolved.officerUsername, resolved.officerPassword, 'appuser1');
    var underwriter = account(resolved.underwriterUsername, resolved.underwriterPassword, 'underwriter1');
    var approver1 = account(resolved.approver1Username, resolved.approver1Password, 'approver1');
    var approver2 = account(resolved.approver2Username, resolved.approver2Password, 'approver2');
    var issuer = account(resolved.issuerUsername, resolved.issuerPassword, 'issueuser1');
    var acceptor = account(resolved.acceptorUsername, resolved.acceptorPassword, 'acceptuser1');
    var setup = account(resolved.setupUsername, resolved.setupPassword, 'setupuser1');

    // Administration / configuration. Kept under the original names so every existing feature that
    // signs in as `adminUsername` keeps working unchanged.
    config.adminUsername = admin.username;
    config.adminPassword = admin.password;

    // Origination — the loan officer who creates and submits the application.
    config.officerUsername = officer.username;
    config.officerPassword = officer.password;

    // Assessment — claims at intake, comments, and routes to the approver stage.
    config.underwriterUsername = underwriter.username;
    config.underwriterPassword = underwriter.password;

    // Credit committee — two distinct voters, or the quorum can never be reached.
    config.approver1Username = approver1.username;
    config.approver1Password = approver1.password;
    config.approver2Username = approver2.username;
    config.approver2Password = approver2.password;

    // Third committee member, or null where the environment has only two. Consumers MUST handle null
    // rather than fall back to another account — a repeat voter is rejected with "You have already
    // cast your vote for committee 'APPROVER'".
    config.approver3Username = resolved.approver3Username != null ? resolved.approver3Username : null;
    config.approver3Password = resolved.approver3Password != null ? resolved.approver3Password : null;

    // Offer and setup.
    config.issuerUsername = issuer.username;
    config.issuerPassword = issuer.password;
    config.acceptorUsername = acceptor.username;
    config.acceptorPassword = acceptor.password;
    config.setupUsername = setup.username;
    config.setupPassword = setup.password;

    // Explicit default fallbacks for data-driven row calls (prevents Excel column shadowing)
    config.defaultAdminUsername = admin.username;
    config.defaultAdminPassword = admin.password;
    config.defaultOfficerUsername = officer.username;
    config.defaultOfficerPassword = officer.password;
    config.defaultUnderwriterUsername = underwriter.username;
    config.defaultUnderwriterPassword = underwriter.password;
    config.defaultApprover1Username = approver1.username;
    config.defaultApprover1Password = approver1.password;
    config.defaultApprover2Username = approver2.username;
    config.defaultApprover2Password = approver2.password;
    config.defaultApprover3Username = config.approver3Username;
    config.defaultApprover3Password = config.approver3Password;
    config.defaultIssuerUsername = issuer.username;
    config.defaultIssuerPassword = issuer.password;
    config.defaultAcceptorUsername = acceptor.username;
    config.defaultAcceptorPassword = acceptor.password;
    config.defaultSetupUsername = setup.username;
    config.defaultSetupPassword = setup.password;

    // Checker (second pair of eyes) accounts for governed configuration changes.
    //
    // approval-limit-helper.feature has to bootstrap an approval limit before the E2E lifecycle
    // features can route a loan to the approver stage. That is a governed change: POST
    // /v1/approval-limits raises a ChangeRequest under the APPROVAL_LIMIT_CHANGE event code, whose
    // severity is SUPERVISOR_APPROVAL, so the maker (adminUsername) is forbidden from approving it —
    // core-governance enforces four-eyes. Someone else has to. The helper walks this list in order
    // and uses the first account that can approve, so a missing one is not fatal.
    config.governanceCheckers = (resolved.governanceCheckers != null)
        ? resolved.governanceCheckers
        : [
            { username: 'admin2', password: passwordCandidates[0] },
            { username: 'manager1', password: passwordCandidates[0] },
            { username: 'underwriter1', password: passwordCandidates[0] },
            { username: 'approver2', password: passwordCandidates[0] }
        ];

    // ── HTTP settings ─────────────────────────────────────────────────────────
    var connectTimeoutVal = 15000;
    var readTimeoutVal = 120000;
    karate.configure('connectTimeout', connectTimeoutVal);
    karate.configure('readTimeout', readTimeoutVal);

    // Pretty-print JSON responses in reports
    karate.configure('logPrettyResponse', true);
    karate.configure('logPrettyRequest', true);

    // SSL — set to true if using self-signed certs in staging
    karate.configure('ssl', false);

    return config;
}