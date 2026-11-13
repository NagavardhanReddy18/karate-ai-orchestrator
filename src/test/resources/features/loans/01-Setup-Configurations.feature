@config-setup @data-driven
Feature: Excel-driven configuration setup — Scorecard, Product Type, Role Access, Sub-products, Purposes, Approval Limit

  # ── WHAT THIS DOES ───────────────────────────────────────────────────────────────────────────
  # Reads Product-Configuration-Automation.xlsx (sheet 1) and, for every row with run=Y, makes the
  # server look exactly like the row says — the same thing an admin would click through in the
  # Configuration screens before a regression run:
  #
  #   1. Scorecard        create (or reuse/update) and PUBLISH it, so it shows ACTIVE in the UI, and
  #                       delete stale DRAFT versions of it (deleteStaleScorecardDrafts=true);
  #                       or, with createScorecard=false, attach an existing one by newScorecardCode
  #   2. Product type     create it with the scorecard attached at the product-type level
  #   3. Role access      grant the roles in roleAccessList (this is what makes the product type
  #                       appear in Loan Origination for a loan officer)
  #   4. Field schema     add the extended fields in extendedFields
  #   5. Sub-products     link every code in selectedProductCode and attach the scorecard to each
  #                       (a different one per sub-product via subProductScorecards)
  #   6. Purposes         attach linkedPurposes — dropdown labels or codes — (every dropdown option
  #                       when blank) and detach purposes that are not dropdown options
  #   7. Verify           re-read everything, and confirm a loan officer can actually submit for
  #                       the product type (GET /v1/product-types/submittable)
  #
  # Approval limits (user / role / credit committee, per loan type and sub-product) are NOT in this
  # sheet any more: see testdata/Approval-Limits-Automation.xlsx and 01-Setup-Approval-Limits.feature,
  # which the runner executes right after this feature.
  #
  # Every governed change (202 + ChangeRequest) is approved by a checker and committed here, so the
  # configuration is live when the row finishes — nothing is left PENDING_APPROVAL.
  #
  # ── WHY THE PREVIOUS VERSION LEFT THE SCORECARD INACTIVE AND THE PRODUCT TYPE INVISIBLE ────
  #   * The Excel admin account had only LOAN_OFFICER, so every scorecard call returned 403. The
  #     product type was then created with scorecardId=null, which the server rejects with
  #     "Scorecard is required when the Assessment Method is AUTO" — and every later step 404'd.
  #   * Scorecard attributes were sent with made-up codes. Publishing needs every attribute to be a
  #     row of the LOAN_APPLICATION attribute catalogue ("no attribute catalogue row for domain"),
  #     so the scorecard stayed DRAFT. Attributes are now resolved against the live catalogue.
  #   * Bands had gaps (10000 -> 10001) and no open-ended band, which the activation validator
  #     rejects. Bands are now normalised (gaps closed, last band open-ended).
  #   * Role access raised change requests that were never approved (PENDING_CHANGE_EXISTS on the
  #     next run), so the loan officer got "not authorised to submit applications for product type".
  #     Pending requests are now resolved and every request is approved + committed + re-read.
  #   * Every failure was swallowed into karate.log and the feature "passed". It now fails on the
  #     step that broke, with the server's own response in the message.
  #
  # ── NO DEFAULTS ──────────────────────────────────────────────────────────────────────────────
  # Every value is read from the sheet. A column that an action needs and that is blank fails the row
  # with the column name; nothing falls back to a value written in this file. The only things not in
  # the sheet are what the server itself provides (attribute catalogue, purpose dropdown, workflows).
  #
  # ── ACCOUNTS ─────────────────────────────────────────────────────────────────────────────────
  # adminUsername/adminPassword, checkerUsername/checkerPassword and officerUsername/officerPassword
  # in the sheet are optional. Blank means "use the accounts karate-config.js resolved for this
  # environment". A sheet admin that cannot read the scorecard configuration (403) is replaced by the
  # resolved admin, with a warning.
  #
  # ── RUN ──────────────────────────────────────────────────────────────────────────────────────
  #   mvn test -pl beyond-lo-tests -Dkarate.env=dev -Dkarate.tags="@config-setup"
  # KarateTestRunner also runs this feature first, before the lifecycle features, unless
  # -Dkarate.skipConfigSetup=true is given.

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Product-Configuration-Automation.xlsx')
    * def rawData = ExcelDataLoader.load(excelPath)
    * def rows = karate.filter(rawData, function(x){ return x.run && x.run.toString().toUpperCase() == 'Y' })
    * def rowCount = rows.length

  Scenario: Run Product Configuration Setup for all enabled Excel rows
    * print '======================================================'
    * print 'STARTING PRODUCT CONFIGURATION SETUP EXECUTION'
    * print 'Total Enabled Configuration Rows:', rowCount
    * print '======================================================'
    * if (rowCount > 0) karate.call('classpath:features/loans/01-Setup-Configurations.feature@executeRow', rows)

  @ignore @executeRow
  Scenario: Execute Single Configuration Setup Row
    * def td = typeof __arg !== 'undefined' ? __arg : {}
    * url baseUrl
    * configure retry = { count: 24, interval: 5000 }

    # ── small helpers ─────────────────────────────────────────────────────────────────────────
    * def strVal = function(val, defVal) { return (val != null && val.toString().trim() != '') ? val.toString().trim() : defVal }
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def numVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; var n = parseFloat(s.replace(/,/g, '')); return isNaN(n) ? defVal : n; }
    * def splitList = function(val) { var out = []; var s = strVal(val, ''); if (s == '') return out; var parts = s.split(','); for (var i = 0; i < parts.length; i++) { if (parts[i].trim() != '') out.push(parts[i].trim()); } return out; }
    * def rowTag = '[CONFIG-SETUP ' + strVal(td.configId, 'row') + ']'
    * def note = function(m) { karate.log(rowTag, m); }
    # karate.fail() only marks the step failed; the throw is what actually stops the JS function.
    * def fail = function(m) { var msg = rowTag + ' ' + m; karate.log(msg); karate.fail(msg); throw new Error(msg); }
    # Every value comes from the sheet. A required column left blank fails the row here, naming the
    # column — nothing falls back to a value written into this feature.
    * def req = function(col, why) { var v = strVal(td[col], null); if (v == null) fail('column "' + col + '" is blank but is required ' + why); return v; }
    * def show =
      """
      function(res) {
        var body = '';
        try { body = res.body == null ? '' : (typeof res.body == 'string' ? res.body : karate.pretty(res.body)); } catch (e) { body = '' + res.body; }
        return 'HTTP ' + res.status + ' ' + body;
      }
      """
    * def api =
      """
      function(method, path, header, body) {
        var h = karate.http(baseUrl + path).header('Authorization', header).header('Content-Type', 'application/json');
        var m = method.toUpperCase();
        if (m == 'GET') return h.get();
        if (m == 'DELETE') return h.delete();
        if (m == 'PUT') return h.put(body == null ? {} : body);
        return h.post(body == null ? {} : body);
      }
      """
    * def today = java.time.LocalDate.now().toString()

    # Login that survives the /auth/login rate limiter and the single-session takeover, and returns
    # null (instead of failing the run) for an account that does not exist here.
    * def softLogin =
      """
      function(user, pass) {
        if (user == null || user == '') return null;
        var res = karate.http(baseUrl + '/auth/login').header('Content-Type', 'application/json').post({ username: user, password: pass });
        var waits = 0;
        while (res.status == 429 && waits < 24) {
          waits++;
          note('rate limited signing in ' + user + ' - waiting 5s (' + waits + '/24)');
          java.lang.Thread.sleep(5000);
          res = karate.http(baseUrl + '/auth/login').header('Content-Type', 'application/json').post({ username: user, password: pass });
        }
        if (res.status != 200) { note('login ' + user + ' -> HTTP ' + res.status); return null; }
        var body = res.body;
        if (body.requiresSessionConfirm == true) {
          var c = karate.http(baseUrl + '/auth/confirm-session').header('Content-Type', 'application/json').post({ confirmToken: body.confirmToken });
          if (c.status != 200) { note('confirm-session ' + user + ' -> HTTP ' + c.status); return null; }
          body = c.body;
        }
        if (body.token == null || body.token == '') { note('login ' + user + ' returned no token'); return null; }
        return 'Bearer ' + body.token;
      }
      """
    * def logout = function(header) { if (header == null) return; try { karate.http(baseUrl + '/auth/logout').header('Authorization', header).post({}); } catch (e) { } }

    # ── inputs from the sheet ─────────────────────────────────────────────────────────────────
    * def reqScorecard = isTrue(td.createScorecard)
    * def reqProductType = isTrue(td.createProductType)
    * def usesScorecard = reqScorecard || strVal(td.newScorecardCode, null) != null || strVal(td.subProductScorecards, null) != null
    * def rowDescription = req('description', 'on every row (it is stored as the scorecard / product type description)')
    * def scDomain = usesScorecard ? req('scorecardDomain', 'whenever a scorecard is created or attached (e.g. LOAN_APPLICATION)') : null
    * def ptCode = strVal(td.newProductTypeCode, null)
    * def scCode = reqScorecard ? req('newScorecardCode', 'when createScorecard=true') : strVal(td.newScorecardCode, null)
    * def scName = reqScorecard ? req('newScorecardName', 'when createScorecard=true') : strVal(td.newScorecardName, scCode)
    * def ptName = reqProductType ? req('newProductTypeName', 'when createProductType=true') : strVal(td.newProductTypeName, ptCode)
    * def ptCategory = (reqProductType ? req('newProductCategory', 'when createProductType=true (RETAIL | ENTERPRISE | OVERDRAFT | ENTERPRISE_OVERDRAFT)') : strVal(td.newProductCategory, '')).toUpperCase().replace(/[ -]+/g, '_')
    * def wfKeyWanted = reqProductType ? req('newWorkflowKey', 'when createProductType=true (a published workflow key)') : strVal(td.newWorkflowKey, null)
    * def assessmentMethod = (reqProductType ? req('assessmentMethod', 'when createProductType=true (e.g. AUTO)') : strVal(td.assessmentMethod, '')).toUpperCase()
    * def routingMethod = (reqProductType ? req('routingMethod', 'when createProductType=true (e.g. DIRECT)') : strVal(td.routingMethod, '')).toUpperCase()
    * def roleList = splitList(reqProductType ? req('roleAccessList', 'when createProductType=true (roles allowed to originate, e.g. LOAN_OFFICER, ADMIN)') : td.roleAccessList)
    * def productCodes = splitList(td.selectedProductCode)
    * def purposeCodes = splitList(td.linkedPurposes)
    * def attachToProducts = (productCodes.length > 0 && usesScorecard) ? isTrue(req('attachScorecardToProduct', 'when sub-products are linked and a scorecard is in use (true | false)')) : false
    * def verifyOfficer = isTrue(td.verifyOfficerSubmittable)
    * def removeUnlisted = isTrue(td.removeUnlistedPurposes)
    * def officerUserForCheck = strVal(td.officerUsername, defaultOfficerUsername)
    * def officerPassForCheck = strVal(td.officerUsername, null) != null ? strVal(td.officerPassword, defaultOfficerPassword) : defaultOfficerPassword
    * if (reqProductType && ptCode == null) fail('newProductTypeCode is required when createProductType=true')
    * if (!reqProductType && ptCode == null && (productCodes.length > 0 || purposeCodes.length > 0)) fail('newProductTypeCode is required to link sub-products or purposes')

    * print rowTag, 'Processing:', td.description, '| scorecard:', scCode, '| productType:', ptCode

    # ── 0. ACCOUNTS: an admin that can configure, a checker that can approve ─────────────────
    * def excelAdminUser = strVal(td.adminUsername, null)
    * def excelAdminPass = strVal(td.adminPassword, defaultAdminPassword)
    * def excelCheckerUser = strVal(td.checkerUsername, null)
    * def excelCheckerPass = strVal(td.checkerPassword, defaultAdminPassword)

    * def canConfigure = function(header) { var r = api('GET', '/v1/config/scorecards/attribute-catalog?domain=' + scDomain, header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canConfigure(h)) return { user: excelAdminUser, header: h, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot read scorecard configuration (403) - falling back to the resolved admin ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        if (excelAdminUser != defaultAdminUsername) {
          var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
          if (h2 != null && canConfigure(h2)) return { user: defaultAdminUsername, header: h2, source: 'karate-config' };
          if (h2 != null) logout(h2);
          tried.push(defaultAdminUsername);
        }
        fail('no admin account can configure scorecards/product types (needs MENU_CONFIGURATION or the SCORECARD_* permissions). Tried: ' + tried.join(', ') + '. Fill adminUsername/adminPassword in the sheet with an ADMIN account, or fix the roleCandidates.admin list in karate-config.js.');
      }
      """
    * def admin = resolveAdmin()
    * def adminUser = admin.user
    * def adminHeader = admin.header
    * note('admin account: ' + adminUser + ' (' + admin.source + ')')

    # Checker candidates: the sheet's checker first, then karate-config's governanceCheckers.
    * def checkerCandidates =
      """
      function() {
        var list = [];
        if (excelCheckerUser != null && excelCheckerUser != adminUser) list.push({ username: excelCheckerUser, password: excelCheckerPass });
        var gc = (typeof governanceCheckers !== 'undefined' && governanceCheckers != null) ? governanceCheckers : [];
        for (var i = 0; i < gc.length; i++) {
          var u = gc[i].username;
          if (u == adminUser) continue;
          var dup = false;
          for (var j = 0; j < list.length; j++) { if (list[j].username == u) dup = true; }
          if (!dup) list.push({ username: u, password: gc[i].password });
        }
        return list;
      }
      """
    * def checkers = checkerCandidates()
    # One checker session is opened lazily and reused for every approval in this row (login is
    # rate limited, so one login per change request is not affordable).
    # A JS function cannot reassign a scenario variable, so the checker session goes through karate.set/get.
    * def ckUsername = null
    * def ckHeaderVal = null
    * def ckPassword = null
    * def ckUser = function() { return karate.get('ckUsername'); }
    * def ckHeader = function() { return karate.get('ckHeaderVal'); }
    * def ckSet = function(u, h, p) { karate.set('ckUsername', u); karate.set('ckHeaderVal', h); karate.set('ckPassword', p); }
    * def checkerSession =
      """
      function(excludeUser) {
        if (ckHeader() != null && ckUser() != excludeUser) return ckHeader();
        for (var i = 0; i < checkers.length; i++) {
          var c = checkers[i];
          if (c.username == excludeUser) continue;
          if (ckUser() == c.username && ckHeader() != null) return ckHeader();
          var h = softLogin(c.username, c.password);
          if (h == null) { note('checker ' + c.username + ' could not sign in - trying the next one'); continue; }
          if (ckHeader() != null) logout(ckHeader());
          ckSet(c.username, h, c.password);
          note('checker account: ' + c.username);
          return h;
        }
        return null;
      }
      """
    * def relogCheckerIfNeeded =
      """
      function() {
        if (ckUser() == null) return;
        var h = softLogin(ckUser(), karate.get('ckPassword'));
        if (h != null) karate.set('ckHeaderVal', h);
      }
      """

    # ── CHANGE-REQUEST HANDLING (maker-checker) ───────────────────────────────────────────────
    * def ensureSupervisorLink =
      """
      function(user, supervisor) {
        if (user == null || user == supervisor) return;
        var ex = api('GET', '/v1/supervisor-links/by-user/' + user, adminHeader, null);
        if (ex.status == 200 && ex.body != null) {
          for (var i = 0; i < ex.body.length; i++) {
            if (ex.body[i].supervisorUsername == supervisor && ex.body[i].active) return;
          }
        }
        var r = api('POST', '/v1/supervisor-links', adminHeader, { userUsername: user, supervisorUsername: supervisor, active: true });
        note('supervisor link ' + user + ' -> ' + supervisor + ': HTTP ' + r.status);
      }
      """
    * def crGet = function(id) { return api('GET', '/v1/change-requests/' + id, adminHeader, null); }
    # Drives one change request to COMMITTED. Returns null on success, or the reason it could not.
    * def settleCr =
      """
      function(cr, what) {
        var id = cr.id;
        var status = cr.status;
        var initiator = cr.initiatedBy != null ? cr.initiatedBy : adminUser;
        if (status == 'PENDING_APPROVAL') {
          if (cr.eventSeverity == 'WARNING') {
            var p = api('POST', '/v1/change-requests/' + id + '/proceed', adminHeader, {});
            if (p.status != 200) return what + ': self-proceed on change request ' + id + ' -> ' + show(p);
            status = 'APPROVED';
          } else {
            var votes = 0;
            var lastErr = null;
            var usedCheckers = {};
            var guard = 0;
            while (status == 'PENDING_APPROVAL' && guard < 4) {
              guard++;
              var csUser = null;
              var csHeader = null;
              for (var i = 0; i < checkers.length && csUser == null; i++) {
                var c = checkers[i];
                if (c.username == initiator || usedCheckers[c.username] == true) continue;
                if (ckUser() == c.username && ckHeader() != null) { csUser = c.username; csHeader = ckHeader(); break; }
                var h = softLogin(c.username, c.password);
                if (h == null) { usedCheckers[c.username] = true; continue; }
                if (ckHeader() != null && ckUser() != c.username) logout(ckHeader());
                ckSet(c.username, h, c.password);
                note('checker account: ' + c.username);
                csUser = c.username; csHeader = h;
              }
              if (csUser == null) break;
              usedCheckers[csUser] = true;
              ensureSupervisorLink(initiator, csUser);
              var a = api('POST', '/v1/change-requests/' + id + '/approve', csHeader, { comment: 'Approved by Excel configuration setup (' + what + ')' });
              if (a.status == 401) { relogCheckerIfNeeded(); a = api('POST', '/v1/change-requests/' + id + '/approve', ckHeader(), { comment: 'Approved by Excel configuration setup (' + what + ')' }); }
              if (a.status != 200) { lastErr = 'checker ' + csUser + ' could not approve: ' + show(a); note(lastErr); continue; }
              votes++;
              var g = crGet(id);
              status = (g.status == 200 && g.body != null && g.body.status != null) ? g.body.status : 'APPROVED';
              note(what + ': change request ' + id + ' approved by ' + csUser + ' (vote ' + votes + ', now ' + status + ')');
            }
            if (status == 'PENDING_APPROVAL') {
              return what + ': change request ' + id + ' is still PENDING_APPROVAL after ' + votes + ' vote(s). ' + (lastErr != null ? lastErr + '. ' : '')
                   + 'Four-eyes: the initiator (' + initiator + ') cannot approve its own request; a different ADMIN/MANAGER linked as its supervisor must. '
                   + 'Fill checkerUsername/checkerPassword in the sheet or governanceCheckers in karate-config.js.';
            }
          }
        }
        if (status == 'APPROVED') {
          var cm = api('POST', '/v1/change-requests/' + id + '/commit', adminHeader, {});
          if (cm.status != 200) {
            var g2 = crGet(id);
            if (!(g2.status == 200 && g2.body != null && g2.body.status == 'COMMITTED')) return what + ': commit of change request ' + id + ' -> ' + show(cm);
          }
          status = 'COMMITTED';
        }
        if (status == 'COMMITTED') { note(what + ': change request ' + id + ' COMMITTED'); return null; }
        return what + ': change request ' + id + ' ended in status ' + status;
      }
      """
    # Resolve change requests already pending for a record (left behind by an earlier run or by
    # someone in the UI) so a fresh request is accepted. Cancel is tried first; if the server
    # refuses, the pending request is approved and committed instead.
    * def resolvePending =
      """
      function(keyword, what) {
        var r = api('GET', '/v1/change-requests/all-pending', adminHeader, null);
        if (r.status != 200) {
          var csh = checkerSession(null);
          if (csh != null) r = api('GET', '/v1/change-requests/pending-approval', csh, null);
        }
        if (r.status != 200 || r.body == null) { note(what + ': could not list pending change requests: ' + show(r)); return false; }
        var handled = 0;
        for (var i = 0; i < r.body.length; i++) {
          var cr = r.body[i];
          var label = '' + (cr.entityLabel != null ? cr.entityLabel : '') + ' ' + (cr.entityId != null ? cr.entityId : '');
          if (label.indexOf(keyword) < 0) continue;
          note(what + ': pending change request ' + cr.id + ' (' + cr.eventCode + ', by ' + cr.initiatedBy + ') blocks this record - resolving it');
          var c = api('POST', '/v1/change-requests/' + cr.id + '/admin-cancel', adminHeader, {});
          if (c.status == 200) { note(what + ': change request ' + cr.id + ' cancelled'); handled++; continue; }
          var err = settleCr(cr, what + ' (pre-existing request ' + cr.id + ')');
          if (err != null) { note(err); continue; }
          handled++;
        }
        return handled > 0;
      }
      """
    # Applies the outcome of a maker call: direct success, a change request to settle, or a
    # PENDING_CHANGE_EXISTS conflict to clear and retry. Anything else fails the row.
    * def governed =
      """
      function(what, res, retryFn, keyword) {
        if (res.status >= 200 && res.status < 300) {
          var b = res.body;
          if (b != null && typeof b == 'object' && b.id != null && b.eventCode != null && b.status != null) {
            note(what + ': change request ' + b.id + ' raised (' + b.eventCode + ', ' + b.status + ', ' + b.eventSeverity + ')');
            var err = settleCr(b, what);
            if (err != null) fail(err);
            return true;
          }
          note(what + ': applied (HTTP ' + res.status + ')');
          return true;
        }
        if (res.status == 409 && res.body != null && res.body.code == 'PENDING_CHANGE_EXISTS' && retryFn != null) {
          note(what + ': ' + res.body.detail);
          if (!resolvePending(keyword, what)) fail(what + ': a change request is already pending and could not be resolved. ' + show(res));
          var r2 = retryFn();
          return governed(what, r2, null, keyword);
        }
        fail(what + ' -> ' + show(res));
      }
      """

    # ── 1. SCORECARD: create or reuse, then PUBLISH ───────────────────────────────────────────
    * def toAttrCode =
      """
      function(s) {
        s = s.toString().trim();
        if (s.indexOf('_') >= 0 || s == s.toUpperCase()) return s.toUpperCase();
        var out = '';
        for (var i = 0; i < s.length; i++) {
          var c = s.charAt(i);
          if (c != c.toLowerCase() && c == c.toUpperCase() && out.length > 0) out += '_';
          out += c.toUpperCase();
        }
        return out;
      }
      """
    * def findCatalogueRow =
      """
      function(cat, a) {
        var cands = [];
        if (a.attributeCode != null) cands.push('' + a.attributeCode);
        if (a.sourceField != null) cands.push('' + a.sourceField);
        if (a.attributeName != null) cands.push('' + a.attributeName);
        // 1. exact: attributeCode, sourceField or attributeName
        for (var k = 0; k < cands.length; k++) {
          var c = cands[k].trim();
          var cu = c.toUpperCase();
          var cc = toAttrCode(c);
          for (var i = 0; i < cat.length; i++) {
            var row = cat[i];
            var code = row.attributeCode != null ? ('' + row.attributeCode).toUpperCase() : '';
            var sf = row.sourceField != null ? ('' + row.sourceField) : '';
            var nm = row.attributeName != null ? ('' + row.attributeName).toUpperCase() : '';
            if (code == cu || code == cc || sf == c || sf.toUpperCase() == cu || nm == cu) return row;
          }
        }
        // 2. by words: MONTHLY_GROSS_INCOME / monthlyGrossIncome -> MONTHLY_INCOME (every word of the
        //    catalogue code appears in the sheet's name; the row matching the most words wins)
        var best = null; var bestScore = 0;
        for (var k2 = 0; k2 < cands.length; k2++) {
          var words = toAttrCode(cands[k2].trim()).split('_');
          for (var j = 0; j < cat.length; j++) {
            var rc = cat[j].attributeCode != null ? ('' + cat[j].attributeCode).toUpperCase() : '';
            if (rc == '') continue;
            var rw = rc.split('_');
            var all = true;
            for (var w = 0; w < rw.length; w++) { if (words.indexOf(rw[w]) < 0) all = false; }
            if (all && rw.length > bestScore) { best = cat[j]; bestScore = rw.length; }
          }
        }
        if (best != null) note('scorecard attribute ' + cands[0] + ' mapped to catalogue attribute ' + best.attributeCode + ' (' + best.sourceField + ')');
        return best;
      }
      """
    * def parseAttributes =
      """
      function() {
        var raw = req('scorecardAttributes', 'when createScorecard=true (JSON array of catalogue attributes with weightage and bands)');
        if (raw.charAt(0) == '[') {
          try { return JSON.parse(raw); } catch (e) { fail('scorecardAttributes is not valid JSON: ' + e); }
        }
        // Compact form: CODE:WEIGHT[:METHOD[:BANDS-JSON]] | CODE:WEIGHT ...
        var out = [];
        var items = raw.split('|');
        for (var i = 0; i < items.length; i++) {
          var parts = items[i].split(':');
          if (parts.length < 1 || parts[0].trim() == '') continue;
          var a = { attributeCode: parts[0].trim() };
          if (parts.length > 1) a.weightage = parseFloat(parts[1]);
          if (parts.length > 2 && parts[2].trim() != '') a.scoringMethod = parts[2].trim().toUpperCase();
          if (parts.length > 3) { var bandsStr = parts.slice(3).join(':'); try { a.bands = JSON.parse(bandsStr); } catch (e) { fail('bands for ' + a.attributeCode + ' are not valid JSON: ' + bandsStr); } }
          out.push(a);
        }
        return out;
      }
      """
    * def normaliseBands =
      """
      function(a, method, dataType, resolver) {
        var src = a.bands;
        if (src == null && a.scoringBands != null) { src = (typeof a.scoringBands == 'string') ? JSON.parse(a.scoringBands) : a.scoringBands; }
        if (src == null) src = [];
        var out = [];
        // Bands are written in the engine's typed form (type RANGE | ENUM | WILDCARD). Untyped ("legacy")
        // bands are matched differently at evaluation time: a categorical value that looks numeric, such
        // as the LOAN_PURPOSE code 001, is compared as a number and never matches its band, so the
        // attribute silently scores 0. Typed ENUM bands compare the value itself, and the engine then
        // requires a WILDCARD fallback band on every STATIC attribute.
        if (method == 'STATIC') {
          var hasWild = false;
          for (var i = 0; i < src.length; i++) {
            var b = src[i];
            var v = b.value != null ? b.value : (b.exactValue != null ? b.exactValue : (b.code != null ? b.code : b.label));
            var score = b.score != null ? Number(b.score) : 0;
            if (b.wildcard == true || ('' + b.type).toUpperCase() == 'WILDCARD' || v == '*') {
              out.push({ type: 'WILDCARD', score: score, label: b.label != null ? '' + b.label : 'Any other value' });
              hasWild = true;
              continue;
            }
            var sb = { type: 'ENUM', value: '' + v, score: score };
            if (b.label != null) sb.label = '' + b.label;
            if (resolver != null) {
              var rv = resolver('' + v);
              if (rv == null) fail('scorecard attribute ' + a.attributeCode + ': band value "' + v + '" is not a LOAN_PURPOSE dropdown option (use the dropdown label or code: ' + resolver.describe() + ')');
              if (sb.label == null) sb.label = rv.label;
              if (rv.code != sb.value) note('scorecard attribute ' + a.attributeCode + ': band value "' + v + '" resolved to purpose code ' + rv.code);
              sb.value = rv.code;
            }
            out.push(sb);
          }
          if (!hasWild) out.push({ type: 'WILDCARD', score: 0, label: 'Any other value' });
          return JSON.stringify(out);
        }
        // A RANGE attribute may carry ONE wildcard band ({"value":"*","wildcard":true,"score":0,...}): the engine's
        // fallback when no range matches - typed evaluation RAISES without one ("No band matched value '-0.1667'
        // and no WILDCARD fallback is defined"), which is what a loss-making financial statement (negative
        // ROA / ROE / margins) hits on a scorecard whose bands all start at 0. It must be emitted as type
        // WILDCARD and kept LAST: written as a RANGE with no bounds it would sort first and match everything.
        var wild = null;
        for (var j = 0; j < src.length; j++) {
          var r = src[j];
          var rv = r.value != null ? r.value : (r.exactValue != null ? r.exactValue : null);
          if (r.wildcard == true || ('' + r.type).toUpperCase() == 'WILDCARD' || rv == '*') {
            wild = { type: 'WILDCARD', score: r.score != null ? Number(r.score) : 0, label: r.label != null ? '' + r.label : 'Any other value' };
            continue;
          }
          var mn = r.min != null ? r.min : (r.minValue != null ? r.minValue : null);
          var mx = r.max != null ? r.max : (r.maxValue != null ? r.maxValue : null);
          var rb = { type: 'RANGE', min: mn == null ? null : Number(mn), max: mx == null ? null : Number(mx), score: r.score != null ? Number(r.score) : 0 };
          if (r.label != null) rb.label = '' + r.label;
          out.push(rb);
        }
        if (out.length == 0) out.push({ type: 'RANGE', min: null, max: null, score: 100, label: 'Any value' });
        // sort by min (open-ended lower bound first)
        for (var x = 0; x < out.length; x++) {
          for (var y = x + 1; y < out.length; y++) {
            var ax = out[x].min == null ? -1e300 : out[x].min;
            var ay = out[y].min == null ? -1e300 : out[y].min;
            if (ay < ax) { var t = out[x]; out[x] = out[y]; out[y] = t; }
          }
        }
        // close gaps between consecutive bands (10000 -> 10001 leaves 10000.5 uncovered)
        for (var g = 1; g < out.length; g++) {
          if (out[g].min != null && out[g - 1].max != null && out[g].min > out[g - 1].max) {
            note('scorecard attribute ' + a.attributeCode + ': closing band gap ' + out[g - 1].max + ' -> ' + out[g].min);
            out[g].min = out[g - 1].max;
          }
        }
        // an open-ended band is mandatory: a value outside every band would fail the evaluation
        var open = false;
        for (var o = 0; o < out.length; o++) { if (out[o].min == null || out[o].max == null) open = true; }
        if (!open) { note('scorecard attribute ' + a.attributeCode + ': making the last band open-ended (max ' + out[out.length - 1].max + ' -> unlimited)'); out[out.length - 1].max = null; }
        if (wild != null) out.push(wild);
        return JSON.stringify(out);
      }
      """
    # STATIC bands on the LOAN_PURPOSE attribute are scored against the purpose *code* (001, 002 ...),
    # which is what origination stores. The sheet may name a purpose by its dropdown label or its code;
    # both are resolved here against the LOAN_PURPOSE dropdown, read through any existing product type
    # (the server exposes the dropdown only per product type).
    * def isPurposeAttribute = function(row) { var c = row.attributeCode != null ? ('' + row.attributeCode).toUpperCase() : ''; var f = row.sourceField != null ? ('' + row.sourceField) : ''; return c == 'LOAN_PURPOSE' || f == 'loanPurpose'; }
    * def purposeResolver =
      """
      function() {
        var cached = karate.get('purposeDropdownCache');
        if (cached == null) {
          var types = api('GET', '/v1/product-types', adminHeader, null);
          if (types.status != 200 || types.body == null || types.body.length == 0) fail('cannot read the LOAN_PURPOSE dropdown: no product type to read it through (' + show(types) + ')');
          var found = {};
          var list = [];
          for (var t = 0; t < types.body.length && list.length == 0; t++) {
            var code = '' + types.body[t].code;
            var seen = [];
            var cur = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/purposes', adminHeader, null);
            if (cur.status == 200) seen = seen.concat(cur.body);
            var lp = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/linkable-purposes', adminHeader, null);
            if (lp.status == 200) seen = seen.concat(lp.body);
            for (var i = 0; i < seen.length; i++) {
              var c = seen[i].valueCode != null ? ('' + seen[i].valueCode) : (seen[i].code != null ? ('' + seen[i].code) : null);
              if (c == null) continue;
              var l = seen[i].label != null ? ('' + seen[i].label) : c;
              if (l == c || found[c]) continue;
              found[c] = true;
              list.push({ code: c, label: l });
            }
          }
          if (list.length == 0) fail('cannot read the LOAN_PURPOSE dropdown from any product type');
          cached = list;
          karate.set('purposeDropdownCache', cached);
        }
        var f = function(v) { var w = ('' + v).trim().toLowerCase(); for (var d = 0; d < cached.length; d++) { if (cached[d].code.toLowerCase() == w || cached[d].label.toLowerCase() == w) return cached[d]; } return null; };
        f.describe = function() { var out = []; for (var d = 0; d < cached.length; d++) out.push(cached[d].code + ' = ' + cached[d].label); return out.join(', '); };
        return f;
      }
      """
    * def buildScorecardAttributes =
      """
      function(cat) {
        var list = parseAttributes();
        if (list.length == 0) fail('scorecardAttributes resolved to no attributes');
        var attrs = [];
        var missing = [];
        var total = 0;
        var withWeight = 0;
        for (var i = 0; i < list.length; i++) {
          var w = list[i].weightage != null ? Number(list[i].weightage) : (list[i].weight != null ? Number(list[i].weight) : null);
          if (w != null && !isNaN(w)) { total += w; withWeight++; }
        }
        for (var k = 0; k < list.length; k++) {
          var a = list[k];
          var row = findCatalogueRow(cat, a);
          if (row == null) { missing.push('' + (a.attributeCode || a.attributeName || a.sourceField)); continue; }
          a.attributeCode = row.attributeCode;
          var dataType = row.dataType != null ? ('' + row.dataType) : ((strVal(a.attributeType, 'NUMERIC').toUpperCase() == 'NUMERIC') ? 'NUMBER' : 'STRING');
          var method = strVal(a.scoringMethod, null);
          if (method == null) method = row.defaultScoringMethod != null ? ('' + row.defaultScoringMethod) : (dataType == 'NUMBER' ? 'RANGE' : 'STATIC');
          method = method.toUpperCase();
          var weight;
          if (withWeight == 0) weight = Math.round(10000 / list.length) / 100;
          else {
            var w2 = a.weightage != null ? Number(a.weightage) : (a.weight != null ? Number(a.weight) : 0);
            weight = (total > 0 && Math.abs(total - 100) > 0.001) ? Math.round(w2 * 10000 / total) / 100 : w2;
          }
          var attrName = strVal(a.attributeName, null);
          if (attrName == null || attrName == ('' + row.sourceField) || attrName.toUpperCase() == ('' + row.attributeCode)) attrName = row.attributeName != null ? ('' + row.attributeName) : ('' + row.attributeCode);
          var attr = {
            attributeCode: row.attributeCode,
            attributeName: attrName,
            description: strVal(a.description, row.description != null ? row.description : ''),
            dataSource: row.dataSource,
            sourceField: row.sourceField,
            dataType: dataType,
            scoringMethod: method,
            weight: weight,
            scoringBands: normaliseBands(a, method, dataType, isPurposeAttribute(row) ? purposeResolver() : null),
            displayOrder: a.displayOrder != null ? Number(a.displayOrder) : (k + 1),
            active: true
          };
          if (a.formula != null) attr.formula = a.formula;
          if (a.mandatory != null) attr.mandatory = isTrue(a.mandatory);
          if (a.missingDataPolicy != null) attr.missingDataPolicy = ('' + a.missingDataPolicy).toUpperCase();
          if (a.defaultScore != null) attr.defaultScore = Number(a.defaultScore);
          if (a.autoRejectScore != null) attr.autoRejectScore = Number(a.autoRejectScore);
          attrs.push(attr);
        }
        if (missing.length > 0) {
          var avail = [];
          for (var m = 0; m < cat.length; m++) avail.push(cat[m].attributeCode + ' (' + cat[m].sourceField + ')');
          fail('scorecard attribute(s) not in the ' + scDomain + ' attribute catalogue: ' + missing.join(', ') + '. A scorecard can only be published with catalogued attributes. Available: ' + avail.join(', ') + '. An extended field becomes available after it is added to a product type (fieldKey vehicleAge -> VEHICLE_AGE).');
        }
        // weights are rounded per attribute; put any rounding remainder on the first one
        var sum = 0;
        for (var s = 0; s < attrs.length; s++) sum += attrs[s].weight;
        if (Math.abs(sum - 100) > 0.001) attrs[0].weight = Math.round((attrs[0].weight + (100 - sum)) * 100) / 100;
        if (withWeight > 0 && Math.abs(total - 100) > 0.001) note('scorecard weightage in the sheet totals ' + total + '% - rescaled to 100%');
        return attrs;
      }
      """
    * def findScorecard =
      """
      function() {
        var r = api('GET', '/v1/config/scorecards?domain=' + scDomain, adminHeader, null);
        if (r.status != 200) fail('cannot list scorecards: ' + show(r));
        var best = null;
        var rank = { ACTIVE: 4, SCHEDULED: 3, DRAFT: 2, INACTIVE: 1, SUPERSEDED: 0 };
        for (var i = 0; i < r.body.length; i++) {
          var sc = r.body[i];
          var code = sc.code != null ? ('' + sc.code).toLowerCase() : '';
          var name = sc.name != null ? ('' + sc.name).toLowerCase() : '';
          if (code == scCode.toLowerCase() || name == scName.toLowerCase()) {
            var rk = rank[sc.status] != null ? rank[sc.status] : -1;
            if (best == null || rk > best.rank) best = { sc: sc, rank: rk };
          }
        }
        return best == null ? null : best.sc;
      }
      """
    # Looks up an ACTIVE (or SCHEDULED) scorecard by code or name — one created by an earlier row, or in
    # the UI. Used when a row attaches an existing scorecard instead of creating one.
    * def requireActiveScorecard =
      """
      function(codeOrName, what) {
        var r = api('GET', '/v1/config/scorecards?domain=' + scDomain, adminHeader, null);
        if (r.status != 200) fail('cannot list scorecards: ' + show(r));
        var best = null; var seen = [];
        var rank = { ACTIVE: 4, SCHEDULED: 3, DRAFT: 2, INACTIVE: 1, SUPERSEDED: 0 };
        for (var i = 0; i < r.body.length; i++) {
          var sc = r.body[i];
          var code = sc.code != null ? ('' + sc.code) : ''; var name = sc.name != null ? ('' + sc.name) : '';
          if (code.toLowerCase() == codeOrName.toLowerCase() || name.toLowerCase() == codeOrName.toLowerCase()) {
            seen.push(code + ' (' + sc.status + ', id ' + sc.id + ')');
            var rk = rank[sc.status] != null ? rank[sc.status] : -1;
            if (best == null || rk > best.rank) best = { sc: sc, rank: rk };
          }
        }
        if (best == null) fail(what + ': scorecard "' + codeOrName + '" does not exist on this server. Create it in an earlier row (createScorecard=true, newScorecardCode=' + codeOrName + ') or in the UI first.');
        if (best.sc.status != 'ACTIVE' && best.sc.status != 'SCHEDULED') fail(what + ': scorecard "' + codeOrName + '" exists but is not published (' + seen.join(', ') + '). Publish it, or create it in an earlier row with createScorecard=true.');
        note(what + ': using existing scorecard ' + best.sc.code + ' (id ' + best.sc.id + ', ' + best.sc.status + ')');
        return best.sc.id;
      }
      """
    # Compares the published scorecard with what the sheet defines (thresholds, basis, and per attribute
    # the weight, scoring method and bands). Returns null when they match, else a short description of
    # the first difference, so a changed sheet produces a new published version instead of being ignored.
    * def scorecardDrift =
      """
      function(id, payload) {
        var g = api('GET', '/v1/config/scorecards/' + id, adminHeader, null);
        if (g.status != 200 || g.body == null) return 'cannot read scorecard ' + id + ': ' + show(g);
        var live = g.body;
        var canon = function(v) {
          if (v == null) return 'null';
          if (typeof v == 'string') { try { var parsed = JSON.parse(v); if (typeof parsed == 'object') return canon(parsed); } catch (e) { } return JSON.stringify(v); }
          if (typeof v == 'number') return '' + Number(v);
          if (typeof v == 'boolean') return '' + v;
          if (Array.isArray(v)) { var xs = []; for (var i = 0; i < v.length; i++) xs.push(canon(v[i])); return '[' + xs.join(',') + ']'; }
          var keys = Object.keys(v).sort(); var parts = [];
          for (var k = 0; k < keys.length; k++) { if (v[keys[k]] == null) continue; parts.push(JSON.stringify(keys[k]) + ':' + canon(v[keys[k]])); }
          return '{' + parts.join(',') + '}';
        };
        if (Number(live.passScore) != Number(payload.passScore)) return 'passScore ' + live.passScore + ' vs sheet ' + payload.passScore;
        if (Number(live.autoRejectScore) != Number(payload.autoRejectScore)) return 'autoRejectScore ' + live.autoRejectScore + ' vs sheet ' + payload.autoRejectScore;
        if (('' + live.maxScoreBasis).toUpperCase() != ('' + payload.maxScoreBasis).toUpperCase()) return 'maxScoreBasis ' + live.maxScoreBasis + ' vs sheet ' + payload.maxScoreBasis;
        var liveAttrs = live.attributes != null ? live.attributes : [];
        var byCode = {};
        for (var i = 0; i < liveAttrs.length; i++) { if (liveAttrs[i].active == false) continue; byCode['' + liveAttrs[i].attributeCode] = liveAttrs[i]; }
        var liveCount = Object.keys(byCode).length;
        if (liveCount != payload.attributes.length) return liveCount + ' live attribute(s) vs ' + payload.attributes.length + ' in the sheet';
        for (var j = 0; j < payload.attributes.length; j++) {
          var want = payload.attributes[j];
          var have = byCode['' + want.attributeCode];
          if (have == null) return 'attribute ' + want.attributeCode + ' is not on the live scorecard';
          if (Number(have.weight) != Number(want.weight)) return want.attributeCode + ' weight ' + have.weight + ' vs sheet ' + want.weight;
          if (('' + have.scoringMethod).toUpperCase() != ('' + want.scoringMethod).toUpperCase()) return want.attributeCode + ' scoringMethod ' + have.scoringMethod + ' vs sheet ' + want.scoringMethod;
          if (canon(have.scoringBands) != canon(want.scoringBands)) return want.attributeCode + ' bands differ';
        }
        return null;
      }
      """
    * def setupScorecard =
      """
      function() {
        if (!reqScorecard) {
          // createScorecard=false + a scorecard code/name = attach that existing scorecard
          var named = strVal(td.newScorecardCode, strVal(td.newScorecardName, null));
          if (named == null) return null;
          return { id: requireActiveScorecard(named, 'row scorecard'), status: 'ACTIVE', reused: true };
        }
        var cat = api('GET', '/v1/config/scorecards/attribute-catalog?domain=' + scDomain, adminHeader, null);
        if (cat.status != 200) fail('cannot read the attribute catalogue: ' + show(cat));
        var attrs = buildScorecardAttributes(cat.body);
        var pass = numVal(req('passScore', 'when createScorecard=true (0-100)'), null);
        var reject = numVal(req('autoRejectScore', 'when createScorecard=true (0-100)'), null);
        if (pass == null || reject == null) fail('passScore / autoRejectScore must be numbers');
        if (pass <= reject) fail('passScore (' + pass + ') must be greater than autoRejectScore (' + reject + ')');
        var effective = strVal(td.scorecardEffectiveFrom, today);
        var payload = {
          scorecardDomain: scDomain, code: scCode, name: scName,
          description: (rowDescription != null && rowDescription.length > 500) ? rowDescription.substring(0, 500) : rowDescription,
          passScore: pass, autoRejectScore: reject,
          maxScoreBasis: req('maxScoreBasis', 'when createScorecard=true (BAND_MAX | FIXED_100)').toUpperCase(),
          effectiveFrom: effective,
          attributes: attrs
        };
        var existing = findScorecard();
        var id = null;
        if (existing != null && (existing.status == 'ACTIVE' || existing.status == 'SCHEDULED')) {
          var drift = scorecardDrift(existing.id, payload);
          if (drift == null) {
            note('scorecard ' + scCode + ' already ' + existing.status + ' (id ' + existing.id + ') and matches the sheet - reusing it');
            return { id: existing.id, status: existing.status, reused: true };
          }
          note('scorecard ' + scCode + ' is ' + existing.status + ' (id ' + existing.id + ') but differs from the sheet (' + drift + ') - publishing a new version');
        }
        if (existing != null && existing.status == 'DRAFT') {
          payload.id = existing.id;
          var u = api('PUT', '/v1/config/scorecards/' + existing.id, adminHeader, payload);
          if (u.status < 200 || u.status >= 300) fail('scorecard ' + scCode + ' draft update -> ' + show(u));
          id = existing.id;
          note('scorecard ' + scCode + ': draft ' + id + ' updated from the sheet');
        } else if (existing != null) {
          var cl = api('POST', '/v1/config/scorecards/' + existing.id + '/clone-as-draft', adminHeader, {});
          if (cl.status < 200 || cl.status >= 300 || cl.body == null || cl.body.id == null) fail('scorecard ' + scCode + ' is ' + existing.status + ' and cloning it as a new draft failed: ' + show(cl));
          id = cl.body.id;
          payload.id = id;
          var u2 = api('PUT', '/v1/config/scorecards/' + id, adminHeader, payload);
          if (u2.status < 200 || u2.status >= 300) fail('scorecard ' + scCode + ' new draft update -> ' + show(u2));
          note('scorecard ' + scCode + ': new draft ' + id + ' cloned from ' + existing.status + ' version ' + existing.id);
        } else {
          var c = api('POST', '/v1/config/scorecards?domain=' + scDomain, adminHeader, payload);
          if (c.status < 200 || c.status >= 300) fail('scorecard ' + scCode + ' create -> ' + show(c) + ' | payload ' + karate.pretty(payload));
          if (c.body != null && c.body.id != null) id = c.body.id;
          else { var again = findScorecard(); if (again != null) id = again.id; }
          if (id == null) fail('scorecard ' + scCode + ' was created but cannot be found by code/name afterwards');
          note('scorecard ' + scCode + ' created (id ' + id + ')');
        }
        var v = api('GET', '/v1/config/scorecards/' + id + '/validation', adminHeader, null);
        if (v.status == 200 && v.body != null && v.body.length > 0) note('scorecard ' + scCode + ' validation findings: ' + karate.pretty(v.body));
        var p = api('POST', '/v1/config/scorecards/' + id + '/publish?effectiveFrom=' + effective, adminHeader, {});
        if (p.status < 200 || p.status >= 300) fail('scorecard ' + scCode + ' (id ' + id + ') could not be published/activated -> ' + show(p));
        var g = api('GET', '/v1/config/scorecards/' + id, adminHeader, null);
        var st = (g.status == 200 && g.body != null) ? g.body.status : null;
        if (st != 'ACTIVE' && st != 'SCHEDULED') fail('scorecard ' + scCode + ' (id ' + id + ') is ' + st + ' after publish, expected ACTIVE');
        note('scorecard ' + scCode + ' (id ' + id + ') is ' + st);
        return { id: id, status: st, reused: false };
      }
      """
    * def scorecard = setupScorecard()
    * def scorecardId = scorecard == null ? null : scorecard.id
    # Stale DRAFT versions of the same scorecard (left by earlier runs or abandoned UI edits) cannot be
    # activated and only confuse the Configure Scorecard screen. deleteStaleScorecardDrafts=true removes
    # every DRAFT version of this code/name other than the one that is now ACTIVE.
    * def deleteStaleDrafts =
      """
      function() {
        if (scorecardId == null || !isTrue(td.deleteStaleScorecardDrafts)) return;
        var r = api('GET', '/v1/config/scorecards?domain=' + scDomain, adminHeader, null);
        if (r.status != 200) fail('cannot list scorecards: ' + show(r));
        var removed = 0;
        for (var i = 0; i < r.body.length; i++) {
          var sc = r.body[i];
          if (('' + sc.id) == ('' + scorecardId) || sc.status != 'DRAFT') continue;
          var code = sc.code != null ? ('' + sc.code).toLowerCase() : ''; var name = sc.name != null ? ('' + sc.name).toLowerCase() : '';
          if (!(code == ('' + scCode).toLowerCase() || (scName != null && name == ('' + scName).toLowerCase()))) continue;
          var d = api('DELETE', '/v1/config/scorecards/' + sc.id, adminHeader, null);
          if (d.status >= 200 && d.status < 300) { removed++; note('stale draft v' + sc.version + ' (id ' + sc.id + ') of ' + scCode + ' deleted'); }
          else note('WARNING: stale draft v' + sc.version + ' (id ' + sc.id + ') of ' + scCode + ' could not be deleted -> ' + show(d));
        }
        note(removed + ' stale draft version(s) of ' + scCode + ' removed');
      }
      """
    * deleteStaleDrafts()

    # ── 2. PRODUCT TYPE: create, or attach the scorecard to an existing one ─────────────────
    * def resolveWorkflowKey =
      """
      function() {
        var r = api('GET', '/v1/product-types/workflow-options', adminHeader, null);
        if (r.status != 200) fail('cannot list published workflows: ' + show(r));
        var keys = [];
        for (var i = 0; i < r.body.length; i++) {
          var k = '' + r.body[i].workflowKey;
          keys.push(k + ' (' + r.body[i].name + ')');
          if (k == wfKeyWanted) return k;
        }
        for (var j = 0; j < r.body.length; j++) {
          var k2 = '' + r.body[j].workflowKey;
          if (k2.toLowerCase() == wfKeyWanted.toLowerCase()) { note('workflow key ' + wfKeyWanted + ' matched case-insensitively to ' + k2); return k2; }
        }
        fail('newWorkflowKey "' + wfKeyWanted + '" is not a published workflow on ' + baseUrl + '. Published workflows: ' + keys.join(', '));
      }
      """
    * def typeConfig =
      """
      function() {
        var cfg = { productTypeCode: ptCode, assessmentMethod: assessmentMethod, routingMethod: routingMethod, scorecardId: scorecardId };
        // documentChecklistId is NOT set here: checklists are attached by Document-Checklist-Automation.xlsx (02-Setup-Document-Checklists.feature)
        var rawCharges = strVal(td.chargesChecklist, null);
        if (rawCharges != null) { try { cfg.charges = JSON.parse(rawCharges); } catch (e) { fail('chargesChecklist is not valid JSON: ' + e); } }
        return cfg;
      }
      """
    * def ptPath = ptCode == null ? null : encodeURIComponent(ptCode)
    * def getSchema = function() { return api('GET', '/v1/product-types/' + ptPath + '/schema', adminHeader, null); }
    # A product type that was DEACTIVATED (Product Types > Delete, supervisor-approved) disappears from the
    # list / schema endpoints but its row stays, and POST /v1/product-types then fails on the unique code
    # constraint (HTTP 409 "A duplicate record already exists"). The only way back is a governed PUT with
    # active=true, which needs the row id - looked up in the database (same approach as the unified helper).
    * def findDormantTypeId =
      """
      function() {
        if (ptCode == null) return null;
        var sql = "select id from beyondlo.blo_prod_types where code = '" + ptCode.replace(/'/g, "''") + "' and active = false order by id desc limit 1";
        var prefix = ('' + baseUrl).indexOf('9190') >= 0 ? 'test: ' : '';
        try {
          var id = Java.type('com.ird.beyond.lo.test.util.DbSupport').queryScalar(prefix + sql);
          return (id == null || ('' + id).trim() == '' || ('' + id) == 'null') ? null : ('' + id).trim();
        } catch (e) { note('WARNING: could not look the inactive product type up in the database (' + e + ') - a CREATE of an existing but deactivated code will fail with 409'); return null; }
      }
      """
    * def setupProductType =
      """
      function() {
        if (!reqProductType) return null;
        var wf = resolveWorkflowKey();
        var s = getSchema();
        if (s.status != 200) {
          var dormantId = findDormantTypeId();
          if (dormantId != null) {
            note('product type ' + ptCode + ' exists but is INACTIVE (id ' + dormantId + ', deactivated earlier) - reactivating it instead of creating a duplicate code');
            if ((assessmentMethod == 'AUTO' || assessmentMethod == 'MANUAL_INTERNAL') && scorecardId == null) fail('assessmentMethod ' + assessmentMethod + ' needs a scorecard to reactivate ' + ptCode + ': set createScorecard=true in the row');
            var curCfg = api('GET', '/v1/product-types/' + ptPath + '/config', adminHeader, null);
            var rcfg = typeConfig();
            if (curCfg.status == 200 && curCfg.body != null && curCfg.body.documentChecklistId != null) rcfg.documentChecklistId = curCfg.body.documentChecklistId;
            var rbody = {
              productType: { id: Number(dormantId), code: ptCode, label: ptName, description: rowDescription, icon: 'credit_card',
                             category: (ptCategory == 'OVERDRAFT' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'OVERDRAFT' : 'LOAN',
                             customerType: (ptCategory == 'ENTERPRISE' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'ENTERPRISE' : 'RETAIL',
                             workflowKey: wf, displayOrder: 0, active: true },
              config: rcfg
            };
            var resend = function() { return api('PUT', '/v1/product-types/' + dormantId, adminHeader, rbody); };
            governed('product type ' + ptCode + ' reactivation (id ' + dormantId + ')', resend(), resend, ptCode);
            var rid = null;
            for (var k = 0; k < 30 && rid == null; k++) { var rchk = getSchema(); if (rchk.status == 200) rid = rchk.body.id; else java.lang.Thread.sleep(1000); }
            if (rid == null) fail('product type ' + ptCode + ' (id ' + dormantId + ') is still inactive after its reactivation was committed');
            note('product type ' + ptCode + ' REACTIVATED (id ' + rid + ', workflow ' + wf + ', scorecard ' + scorecardId + ')');
            return rid;
          }
        }
        if (s.status == 200) {
          var existing = s.body;
          note('product type ' + ptCode + ' already exists (id ' + existing.id + ')');
          var cur = api('GET', '/v1/product-types/' + ptPath + '/config', adminHeader, null);
          var curSc = (cur.status == 200 && cur.body != null) ? cur.body.scorecardId : null;
          var curAm = (cur.status == 200 && cur.body != null) ? cur.body.assessmentMethod : null;
          var wantSc = scorecardId != null ? scorecardId : curSc;
          if (('' + curSc) != ('' + wantSc) || curAm != assessmentMethod) {
            note('product type ' + ptCode + ': scorecard ' + curSc + ' -> ' + wantSc + ', assessment ' + curAm + ' -> ' + assessmentMethod + ' (amendment)');
            var cfg = typeConfig();
            cfg.scorecardId = wantSc;
            // The amendment replaces the whole configuration: keep the checklist 02-Setup-Document-Checklists attached.
            if (cur.status == 200 && cur.body != null && cur.body.documentChecklistId != null) cfg.documentChecklistId = cur.body.documentChecklistId;
            var body = {
              productType: { id: existing.id, code: existing.code, label: strVal(td.newProductTypeName, existing.label), description: existing.description, icon: existing.icon,
                             category: existing.category, customerType: existing.customerType, workflowKey: existing.workflowKey != null ? existing.workflowKey : wf,
                             displayOrder: existing.displayOrder, active: true },
              config: cfg
            };
            var send = function() { return api('PUT', '/v1/product-types/' + existing.id, adminHeader, body); };
            governed('product type ' + ptCode + ' amendment', send(), send, ptCode);
          }
          return existing.id;
        }
        if ((assessmentMethod == 'AUTO' || assessmentMethod == 'MANUAL_INTERNAL') && scorecardId == null) fail('assessmentMethod ' + assessmentMethod + ' needs a scorecard to create ' + ptCode + ': set createScorecard=true in the sheet (or use another assessmentMethod)');
        var payload = {
          productType: { code: ptCode, label: ptName, description: rowDescription,
                         // RETAIL -> RETAIL/LOAN, ENTERPRISE -> ENTERPRISE/LOAN, OVERDRAFT -> RETAIL/OVERDRAFT,
                         // ENTERPRISE_OVERDRAFT -> ENTERPRISE/OVERDRAFT (what 07-BLO-Enterprise-Overdraft-LifeCycle needs).
                         category: (ptCategory == 'OVERDRAFT' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'OVERDRAFT' : 'LOAN',
                         customerType: (ptCategory == 'ENTERPRISE' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'ENTERPRISE' : 'RETAIL',
                         workflowKey: wf, active: true },
          config: typeConfig()
        };
        var create = function() { return api('POST', '/v1/product-types', adminHeader, payload); };
        governed('product type ' + ptCode + ' creation', create(), create, ptCode);
        var id = null;
        for (var i = 0; i < 30 && id == null; i++) {
          var chk = getSchema();
          if (chk.status == 200) id = chk.body.id; else java.lang.Thread.sleep(1000);
        }
        if (id == null) fail('product type ' + ptCode + ' is still not visible after its change request was committed');
        note('product type ' + ptCode + ' is ACTIVE (id ' + id + ', workflow ' + wf + ', scorecard ' + scorecardId + ')');
        return id;
      }
      """
    * def ptIdCreated = setupProductType()
    * def lookupPtId = function() { if (ptCode == null) return null; var s0 = getSchema(); return s0.status == 200 ? s0.body.id : null; }
    * def ptId = ptIdCreated != null ? ptIdCreated : lookupPtId()
    # A row for an EXISTING product type (createProductType=false) that this server does not have is
    # skipped with a warning rather than failed: product type codes differ between environments, and
    # the lifecycle features fall back to whatever type the server has.
    * def typeMissing = (ptCode != null && ptId == null)
    * if (typeMissing) note('WARNING: product type ' + ptCode + ' does not exist on ' + baseUrl + ' and createProductType is not true - row skipped')
    * if (typeMissing) karate.abort()

    # ── 3. ROLE ACCESS: who may originate on this product type ───────────────────────────────
    * def setupRoleAccess =
      """
      function() {
        if (ptCode == null || roleList.length == 0) return;
        if (!reqProductType && strVal(td.roleAccessList, null) == null) return;
        var r = api('GET', '/v1/product-types/' + ptPath + '/role-access', adminHeader, null);
        if (r.status != 200) fail('cannot read role access for ' + ptCode + ': ' + show(r));
        var known = {}; var granted = [];
        for (var i = 0; i < r.body.length; i++) { known[r.body[i].roleCode] = true; if (r.body[i].hasAccess == true) granted.push(r.body[i].roleCode); }
        var missing = []; var unknown = [];
        for (var k = 0; k < roleList.length; k++) {
          var role = roleList[k];
          if (known[role] != true) { unknown.push(role); continue; }
          var has = false;
          for (var g = 0; g < granted.length; g++) { if (granted[g] == role) has = true; }
          if (!has) missing.push(role);
        }
        if (unknown.length > 0) note('WARNING: roleAccessList names role(s) that do not exist on this server and are skipped: ' + unknown.join(', '));
        if (missing.length == 0) { note('role access for ' + ptCode + ' already covers ' + roleList.join(', ')); return; }
        var wanted = granted.slice(0);
        for (var m = 0; m < missing.length; m++) wanted.push(missing[m]);
        var send = function() { return api('PUT', '/v1/product-types/' + ptPath + '/role-access', adminHeader, wanted); };
        governed('role access for ' + ptCode + ' (' + wanted.join(', ') + ')', send(), send, ptCode);
        var v = api('GET', '/v1/product-types/' + ptPath + '/role-access', adminHeader, null);
        var still = [];
        for (var x = 0; x < missing.length; x++) {
          var ok = false;
          for (var y = 0; v.status == 200 && y < v.body.length; y++) { if (v.body[y].roleCode == missing[x] && v.body[y].hasAccess == true) ok = true; }
          if (!ok) still.push(missing[x]);
        }
        if (still.length > 0) fail('role access for ' + ptCode + ' was committed but ' + still.join(', ') + ' still cannot submit it');
        note('role access for ' + ptCode + ' now includes ' + missing.join(', '));
      }
      """
    * setupRoleAccess()

    # ── 4. FIELD SCHEMA (extended fields) ────────────────────────────────────────────────────
    * def setupFields =
      """
      function() {
        var raw = strVal(td.extendedFields, null);
        if (raw == null || ptCode == null) return;
        var list;
        try { list = JSON.parse(raw); } catch (e) { fail('extendedFields is not valid JSON: ' + e); }
        var cur = api('GET', '/v1/product-types/' + ptPath + '/fields', adminHeader, null);
        var have = {};
        for (var i = 0; cur.status == 200 && i < cur.body.length; i++) have['' + cur.body[i].fieldKey] = true;
        for (var f = 0; f < list.length; f++) {
          var fd = list[f];
          if (fd.fieldKey == null) fail('extendedFields entry ' + (f + 1) + ' has no fieldKey');
          if (have['' + fd.fieldKey] == true) { note('field ' + fd.fieldKey + ' already defined on ' + ptCode); continue; }
          fd.productTypeCode = ptCode;
          if (fd.dataType == null) fd.dataType = 'STRING';
          if (fd.active == null) fd.active = true;
          var body = fd;
          var send = function() { return api('POST', '/v1/product-types/' + ptPath + '/fields', adminHeader, body); };
          var res = send();
          // Field keys are unique across ALL product types on a server. A key another product type
          // already owns cannot be added here; the scorecard does not depend on it, so warn and go on.
          if (res.status == 409 && res.body != null && res.body.detail != null && ('' + res.body.detail).indexOf('already used by product type') >= 0) {
            note('WARNING: field ' + fd.fieldKey + ' skipped - ' + res.body.detail + ' Use a unique fieldKey in extendedFields (e.g. ' + ptCode.toLowerCase().replace(/_/g, '') + fd.fieldKey + ').');
            continue;
          }
          governed('field ' + fd.fieldKey + ' on ' + ptCode, res, send, ptCode);
        }
      }
      """
    * setupFields()

    # ── 5. SUB-PRODUCTS: link, then attach the scorecard to each ─────────────────────────────
    * def linkedProducts =
      """
      function() {
        var r = api('GET', '/v1/product-types/' + ptPath + '/products', adminHeader, null);
        var out = [];
        for (var i = 0; r.status == 200 && i < r.body.length; i++) out.push('' + r.body[i].productCode);
        return out;
      }
      """
    * def setupProducts =
      """
      function() {
        if (ptCode == null || productCodes.length == 0) return;
        var linked = linkedProducts();
        var toLink = [];
        for (var i = 0; i < productCodes.length; i++) {
          var has = false;
          for (var j = 0; j < linked.length; j++) { if (linked[j] == productCodes[i]) has = true; }
          if (has) note('sub-product ' + productCodes[i] + ' already linked to ' + ptCode); else toLink.push(productCodes[i]);
        }
        for (var k = 0; k < toLink.length; k++) {
          var code = toLink[k];
          var send = (function(c) { return function() { return api('PUT', '/v1/product-types/' + ptPath + '/products/' + c, adminHeader, {}); }; })(code);
          var res = send();
          if (res.status == 400 || res.status == 404) {
            var lp = api('GET', '/v1/product-types/' + ptPath + '/linkable-products', adminHeader, null);
            var avail = [];
            for (var a = 0; lp.status == 200 && a < lp.body.length; a++) avail.push('' + lp.body[a].productCode);
            fail('sub-product ' + code + ' cannot be linked to ' + ptCode + ' -> ' + show(res) + '. Linkable products: ' + avail.join(', '));
          }
          governed('link sub-product ' + code + ' to ' + ptCode, res, send, code);
        }
        var after = linkedProducts();
        for (var v = 0; v < productCodes.length; v++) {
          var ok = false;
          for (var w = 0; w < after.length; w++) { if (after[w] == productCodes[v]) ok = true; }
          if (!ok) fail('sub-product ' + productCodes[v] + ' is still not linked to ' + ptCode + ' after commit (linked: ' + after.join(', ') + ')');
        }
        // Per sub-product overrides: subProductScorecards = "05040DEFAULTUSD=SC_A, 80001DEFAULTUSD=SC_B".
        // A sub-product not listed gets the row's scorecard (when attachScorecardToProduct is true).
        var overrides = {};
        var rawOv = strVal(td.subProductScorecards, null);
        if (rawOv != null) {
          var pairs = rawOv.split(',');
          for (var o = 0; o < pairs.length; o++) {
            var kv = pairs[o].split('=');
            if (kv.length != 2 || kv[0].trim() == '' || kv[1].trim() == '') fail('subProductScorecards entry "' + pairs[o] + '" must look like PRODUCT_CODE=SCORECARD_CODE');
            overrides[kv[0].trim()] = requireActiveScorecard(kv[1].trim(), 'sub-product ' + kv[0].trim());
          }
        }
        for (var p = 0; p < productCodes.length; p++) {
          var pc = productCodes[p];
          var target = overrides[pc] != null ? overrides[pc] : (attachToProducts ? scorecardId : null);
          if (target == null) continue;
          if (assessmentMethod == '' || routingMethod == '') fail('assessmentMethod and routingMethod are required to attach a scorecard to sub-product ' + pc);
          var cur = api('GET', '/v1/product-types/' + ptPath + '/products/' + pc + '/config', adminHeader, null);
          var curSc = (cur.status == 200 && cur.body != null) ? cur.body.scorecardId : null;
          // A sub-product config row is its own assessment/routing override (AssessmentService resolves the
          // product's row before the type's), so a type switched from AUTO to MANUAL_INTERNAL only takes effect
          // on applications once its sub-product rows follow: converge all three fields, not just the scorecard.
          var curAm = (cur.status == 200 && cur.body != null) ? cur.body.assessmentMethod : null;
          var curRm = (cur.status == 200 && cur.body != null) ? cur.body.routingMethod : null;
          if (('' + curSc) == ('' + target) && curAm == assessmentMethod && curRm == routingMethod) { note('sub-product ' + pc + ' already carries scorecard ' + target + ' (' + curAm + '/' + curRm + ')'); continue; }
          if (('' + curSc) == ('' + target)) note('sub-product ' + pc + ': scorecard ' + target + ' kept, assessment ' + curAm + ' -> ' + assessmentMethod + ', routing ' + curRm + ' -> ' + routingMethod + ' (amendment)');
          var cfg = { productTypeCode: ptCode, productCode: pc, scorecardId: target, assessmentMethod: assessmentMethod, routingMethod: routingMethod, active: true };
          // Keep a sub-product checklist override that 02-Setup-Document-Checklists attached; this row only sets the scorecard.
          if (cur.status == 200 && cur.body != null && cur.body.documentChecklistId != null) cfg.documentChecklistId = cur.body.documentChecklistId;
          var sendCfg = (function(c, b) { return function() { return api('PUT', '/v1/product-types/' + ptPath + '/products/' + c + '/config', adminHeader, b); }; })(pc, cfg);
          governed('attach scorecard ' + target + ' to sub-product ' + pc, sendCfg(), sendCfg, pc);
          var chk = api('GET', '/v1/product-types/' + ptPath + '/products/' + pc + '/config', adminHeader, null);
          var gotSc = (chk.status == 200 && chk.body != null) ? chk.body.scorecardId : null;
          if (('' + gotSc) != ('' + target)) fail('sub-product ' + pc + ' config was committed but scorecardId is ' + gotSc + ', expected ' + target);
        }
        for (var ok in overrides) {
          if (productCodes.indexOf(ok) < 0) fail('subProductScorecards names ' + ok + ', which is not in selectedProductCode (' + productCodes.join(', ') + ')');
        }
      }
      """
    * setupProducts()

    # ── 6. PURPOSES ──────────────────────────────────────────────────────────────────────────
    # Purpose options come back as generic-code options: { valueCode, label } (older builds: { code }).
    * def codeOf = function(o) { return '' + (o.valueCode != null ? o.valueCode : (o.code != null ? o.code : o.label)); }
    * def setupPurposes =
      """
      function() {
        if (ptCode == null) return;
        if (!reqProductType && purposeCodes.length == 0) return;
        var cur = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
        if (cur.status != 200) fail('cannot read purposes of ' + ptCode + ': ' + show(cur));
        var lp = api('GET', '/v1/product-types/' + ptPath + '/linkable-purposes', adminHeader, null);
        if (lp.status != 200) fail('cannot read linkable purposes of ' + ptCode + ': ' + show(lp));
        // The dropdown = LOAN_PURPOSE generic codes. Linked rows carry the real label when the code is
        // in that group, and label == code when it is not (the server stores any string it is given).
        var dropdown = [];
        var linked = [];
        var strange = [];
        for (var i = 0; i < cur.body.length; i++) {
          var c = codeOf(cur.body[i]); var l = cur.body[i].label != null ? ('' + cur.body[i].label) : c;
          linked.push(c);
          if (l == c) strange.push(c); else dropdown.push({ code: c, label: l });
        }
        for (var j = 0; j < lp.body.length; j++) dropdown.push({ code: codeOf(lp.body[j]), label: lp.body[j].label != null ? ('' + lp.body[j].label) : codeOf(lp.body[j]) });
        var describe = function() { var out = []; for (var d = 0; d < dropdown.length; d++) out.push(dropdown[d].code + ' = ' + dropdown[d].label); return out.join(', '); };
        var resolve = function(v) { var w = v.toLowerCase(); for (var d = 0; d < dropdown.length; d++) { if (dropdown[d].code.toLowerCase() == w || dropdown[d].label.toLowerCase() == w) return dropdown[d].code; } return null; };
        // sheet values may be codes or labels
        var wanted = []; var unknown = [];
        for (var w = 0; w < purposeCodes.length; w++) {
          var code = resolve(purposeCodes[w]);
          if (code == null) unknown.push(purposeCodes[w]); else if (wanted.indexOf(code) < 0) wanted.push(code);
        }
        if (unknown.length > 0) fail('linkedPurposes "' + unknown.join('", "') + '" not in the LOAN_PURPOSE dropdown. Use the dropdown labels or codes: ' + describe());
        if (purposeCodes.length == 0) { for (var d2 = 0; d2 < dropdown.length; d2++) wanted.push(dropdown[d2].code); }
        // purposes that are not dropdown options can never be picked in the UI - detach them
        if (strange.length > 0 && removeUnlisted) {
          for (var x = 0; x < strange.length; x++) {
            var sc = strange[x];
            note('purpose ' + sc + ' on ' + ptCode + ' is not a LOAN_PURPOSE dropdown option - detaching it');
            var del = (function(c) { return function() { return api('DELETE', '/v1/product-types/' + ptPath + '/purposes/' + c, adminHeader, null); }; })(sc);
            governed('detach purpose ' + sc + ' from ' + ptCode, del(), del, ptCode);
          }
        }
        var missing = [];
        for (var m = 0; m < wanted.length; m++) { if (linked.indexOf(wanted[m]) < 0) missing.push(wanted[m]); }
        if (missing.length == 0) { note('purposes for ' + ptCode + ' already include ' + wanted.join(', ')); return; }
        var send = function() { return api('PUT', '/v1/product-types/' + ptPath + '/purposes', adminHeader, missing); };
        governed('link purposes ' + missing.join(', ') + ' to ' + ptCode, send(), send, ptCode);
        var after = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
        var got = [];
        for (var a = 0; after.status == 200 && a < after.body.length; a++) got.push(codeOf(after.body[a]));
        for (var k = 0; k < missing.length; k++) {
          if (got.indexOf(missing[k]) < 0) fail('purpose ' + missing[k] + ' is still not attached to ' + ptCode + ' after commit (attached: ' + got.join(', ') + ')');
        }
        note('purposes for ' + ptCode + ' now: ' + got.join(', '));
      }
      """
    * setupPurposes()

    # ── 7. APPROVAL LIMIT: moved to Approval-Limits-Automation.xlsx / 01-Setup-Approval-Limits.feature ──
    # Limits are configured per authority (user / role / credit committee) on the Approval Limits
    # screen, so they live in their own workbook and feature, which the runner executes right after this one.

    # ── 8. VERIFY: what the UI would show, and what a loan officer can do ────────────────────
    * def verifyAll =
      """
      function() {
        var summary = [];
        if (scorecardId != null) {
          var sc = api('GET', '/v1/config/scorecards/' + scorecardId, adminHeader, null);
          var st = (sc.status == 200 && sc.body != null) ? sc.body.status : ('HTTP ' + sc.status);
          if (st != 'ACTIVE' && st != 'SCHEDULED') fail('VERIFY: scorecard ' + scCode + ' (id ' + scorecardId + ') is ' + st + ', expected ACTIVE');
          summary.push('scorecard ' + scCode + ' id=' + scorecardId + ' status=' + st + ' attributes=' + (sc.body.attributes != null ? sc.body.attributes.length : 0));
        }
        if (ptCode != null) {
          var cfg = api('GET', '/v1/product-types/' + ptPath + '/config', adminHeader, null);
          if (cfg.status != 200) fail('VERIFY: product type ' + ptCode + ' has no readable configuration: ' + show(cfg));
          if (reqProductType && scorecardId != null && ('' + cfg.body.scorecardId) != ('' + scorecardId)) fail('VERIFY: product type ' + ptCode + ' config carries scorecard ' + cfg.body.scorecardId + ', expected ' + scorecardId);
          summary.push('product type ' + ptCode + ' id=' + ptId + ' assessment=' + cfg.body.assessmentMethod + ' routing=' + cfg.body.routingMethod + ' scorecard=' + cfg.body.scorecardId + (cfg.body.scorecardName != null ? ' (' + cfg.body.scorecardName + ')' : '') + ' checklist=' + cfg.body.documentChecklistId);
          var ra = api('GET', '/v1/product-types/' + ptPath + '/role-access', adminHeader, null);
          var roles = [];
          for (var i = 0; ra.status == 200 && i < ra.body.length; i++) { if (ra.body[i].hasAccess == true) roles.push(ra.body[i].roleCode); }
          summary.push('roles allowed to originate: ' + roles.join(', '));
          var lps = linkedProducts(); var lpd = [];
          for (var z = 0; z < lps.length; z++) {
            var pcfg = api('GET', '/v1/product-types/' + ptPath + '/products/' + lps[z] + '/config', adminHeader, null);
            var psc = (pcfg.status == 200 && pcfg.body != null && pcfg.body.scorecardId != null) ? pcfg.body.scorecardId + (pcfg.body.scorecardName != null ? ' ' + pcfg.body.scorecardName : '') : 'type default';
            lpd.push(lps[z] + ' [scorecard: ' + psc + ']');
          }
          summary.push('sub-products linked: ' + lpd.join(', '));
          var pu = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
          var pus = [];
          for (var p = 0; pu.status == 200 && p < pu.body.length; p++) pus.push(codeOf(pu.body[p]));
          var pl = []; for (var q = 0; pu.status == 200 && q < pu.body.length; q++) pl.push(codeOf(pu.body[q]) + ' = ' + pu.body[q].label);
          summary.push('purposes: ' + pl.join(', '));
          if (verifyOfficer && (reqProductType || strVal(td.roleAccessList, null) != null)) {
            var officerH = softLogin(officerUserForCheck, officerPassForCheck);
            if (officerH == null) {
              note('WARNING: could not sign in as the loan officer ' + officerUserForCheck + ' to confirm the product type is available in Loan Origination');
            } else {
              var sub = api('GET', '/v1/product-types/submittable', officerH, null);
              var codes = [];
              for (var s = 0; sub.status == 200 && s < sub.body.length; s++) codes.push('' + sub.body[s].code);
              logout(officerH);
              var visible = false;
              for (var c = 0; c < codes.length; c++) { if (codes[c] == ptCode) visible = true; }
              if (!visible) fail('VERIFY: loan officer ' + officerUserForCheck + ' cannot originate on ' + ptCode + ' (submittable: ' + codes.join(', ') + '). Check that the officer\'s role is in roleAccessList: ' + roleList.join(', '));
              summary.push('loan officer ' + officerUserForCheck + ' can originate on ' + ptCode + ' (submittable list confirmed)');
            }
          }
        }
        return summary;
      }
      """
    * def summary = verifyAll()
    * logout(ckHeader())
    * logout(adminHeader)
    * print '======================================================'
    * print rowTag, 'CONFIGURATION COMPLETE'
    * print summary
    * print '======================================================'
