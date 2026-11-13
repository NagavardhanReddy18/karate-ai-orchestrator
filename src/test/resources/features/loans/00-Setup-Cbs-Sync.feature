@config-setup @cbs-sync @data-driven
Feature: Excel-driven CBS Sync — Refresh master data, role definitions, and users from Core Banking System

  # ── WHAT THIS DOES ─────────────────────────────────────────────────────────────────────────────
  # Reads testdata/Cbs-Sync-Automation.xlsx and, for every row with run=Y, triggers the CBS sync REST
  # endpoints:
  #
  #   1. CBS-SYNC-01  syncType=all               POST /v1/cbs-sync/all
  #                   Syncs currencies, branches, document configs & types, collaterals, loan products,
  #                   subproducts, loan purposes, interest rates, and party codes from Essence CBS.
  #
  #   2. CBS-SYNC-02  syncType=role-definitions  POST /v1/cbs-sync/role-definitions
  #                   Syncs CBS role definitions into beyondcore.iam_role_def, safely preserving
  #                   existing Beyond LO application permissions.
  #
  #   3. CBS-SYNC-03  syncType=user              POST /v1/cbs-sync/user
  #                   Syncs CBS users and their assigned roles into beyondcore.iam_app_users.
  #
  # This feature is designed to run BEFORE 00-Setup-Configurations.feature and 01-Setup-Approval-Limits.feature
  # in KarateTestRunner.configSetup(), ensuring fresh CBS data exists before scorecards, product types,
  # sub-products, and purposes are configured.
  #
  # Skip CBS sync with -Dkarate.skipCbsSync=true.
  # Run standalone with: mvn test -Dkarate.tags="@cbs-sync"
  # ───────────────────────────────────────────────────────────────────────────────────────────────

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Cbs-Sync-Automation.xlsx')
    * def rows = ExcelDataLoader.load(excelPath)
    * def rowCount = (rows != null) ? rows.length : 0

  Scenario: Run CBS Sync for all enabled Excel rows
    * print '======================================================'
    * print 'STARTING CBS SYNC SETUP EXECUTION'
    * print 'Total Enabled CBS Sync Rows (run=Y):', rowCount
    * print '======================================================'
    * if (rowCount == 0) karate.log('[CBS-SYNC] No run=Y rows found in Cbs-Sync-Automation.xlsx — skipping')
    * if (rowCount > 0) karate.call('classpath:features/loans/00-Setup-Cbs-Sync.feature@executeRow', rows)

  @ignore @executeRow
  Scenario: Execute Single CBS Sync Row
    * def td = typeof __arg !== 'undefined' ? __arg : {}
    * url baseUrl
    * configure retry = { count: 3, interval: 3000 }

    # ── Soft login helper with retry on 429 and session confirmation ─────────────────────────
    * def softLogin =
      """
      function(user, pass) {
        if (user == null || user == '') return null;
        var res = karate.http(baseUrl + '/auth/login').header('Content-Type', 'application/json').post({ username: user, password: pass });
        var waits = 0;
        while (res.status == 429 && waits < 24) {
          waits++;
          karate.log('[CBS-SYNC] Rate limited signing in ' + user + ' — waiting 5s (' + waits + '/24)');
          java.lang.Thread.sleep(5000);
          res = karate.http(baseUrl + '/auth/login').header('Content-Type', 'application/json').post({ username: user, password: pass });
        }
        if (res.status != 200) {
          karate.log('[CBS-SYNC] Login ' + user + ' failed with status: ' + res.status);
          return null;
        }
        var body = res.body;
        if (body.requiresSessionConfirm == true) {
          var c = karate.http(baseUrl + '/auth/confirm-session').header('Content-Type', 'application/json').post({ confirmToken: body.confirmToken });
          if (c.status != 200) {
            karate.log('[CBS-SYNC] confirm-session ' + user + ' failed with status: ' + c.status);
            return null;
          }
          body = c.body;
        }
        if (body.token == null || body.token == '') {
          karate.log('[CBS-SYNC] Login ' + user + ' returned no token');
          return null;
        }
        return 'Bearer ' + body.token;
      }
      """

    # ── Authenticate as Admin ───────────────────────────────────────────────────────────────
    * def user = td.adminUsername ? td.adminUsername : adminUsername
    * def pass = td.adminPassword ? td.adminPassword : adminPassword
    * def authToken = softLogin(user, pass)
    * if (!authToken) karate.fail('[CBS-SYNC] Could not authenticate as admin (' + user + ') to execute CBS sync')

    # ── Trigger Sync API ────────────────────────────────────────────────────────────────────
    * def syncEndpoint = td.endpoint ? td.endpoint : ('/v1/cbs-sync/' + td.syncType)
    * print '------------------------------------------------------'
    * print '[CBS-SYNC] Running:', td.testCaseId, '-', td.description
    * print '[CBS-SYNC] POST', baseUrl + syncEndpoint
    * print '------------------------------------------------------'

    * def syncResponse = karate.http(baseUrl + syncEndpoint).header('Authorization', authToken).header('Content-Type', 'application/json').post({})
    
    * print '[CBS-SYNC] HTTP Status:', syncResponse.status
    * print '[CBS-SYNC] Response Body:', karate.pretty(syncResponse.body)

    # ── Validate Status ─────────────────────────────────────────────────────────────────────
    # Status 200 OK or 207 MULTI_STATUS (when some sub-categories are partial/empty)
    * def expectedStatus = td.expectedStatus ? parseInt(td.expectedStatus) : 200
    * def isOk = syncResponse.status == expectedStatus || (expectedStatus == 200 && (syncResponse.status == 200 || syncResponse.status == 207))
    * if (!isOk) karate.fail('[CBS-SYNC] ' + td.testCaseId + ' failed with HTTP ' + syncResponse.status + ': ' + karate.pretty(syncResponse.body))

    * print '[CBS-SYNC] SUCCESS:', td.testCaseId, 'completed successfully.'
