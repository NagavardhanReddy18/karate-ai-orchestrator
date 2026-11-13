@config-setup @approval-limit-setup @data-driven
Feature: Excel-driven approval-limit setup — the Approval Limits screen (LP-CONF-001) driven from Approval-Limits-Automation.xlsx

  # ── WHAT THIS DOES ───────────────────────────────────────────────────────────────────────────
  # Reads testdata/Approval-Limits-Automation.xlsx (sheet Approval_Limits) and, for every row with
  # run=Y, makes the server hold exactly the approval limit the row describes — the same record an
  # admin would submit through Configuration > Approval Limits > New Approval Limit:
  #
  #   AUTHORITY      authorityType   User | Role | Credit Committee   (USER | ROLE | CREDIT_COMMITTEE)
  #                  authorityName   username, role (code or display name), or committee role
  #   LOAN PRODUCT   loanType        product type (code or name, e.g. CAR LOAN)
  #                  subProductCode  optional — blank applies to all sub-products of the loan type
  #   LIMIT DETAILS  limitAmount, currencyCode
  #   EFFECTIVE      effectiveFrom (required), effectiveTo (blank = open-ended)
  #   SETTINGS       approvalWithinBranch  (Approval within Branch / Own Branch Only; blank = true)
  #                  approvalBySelfAllowed (USER only), votesRequired (CREDIT_COMMITTEE only)
  #   OPTIONAL       partyType PERSONAL | ENTERPRISE (blank = any party), facilityType LOAN | OVERDRAFT
  #                  adminUsername/adminPassword, checkerUsername/checkerPassword (blank = karate-config)
  #
  # Every write is governed (POST -> 202 + ChangeRequest with SUPERVISOR_APPROVAL severity), so each
  # request is approved by a checker that is not the maker and then committed here; the limit is
  # ACTIVE when the row finishes. A limit that already exists with the same authority / loan type /
  # sub-product / party type / currency is compared field by field: identical = nothing to do,
  # different = an amendment is requested (PUT /request-amendment), approved and committed.
  #
  # Names are resolved against what the server's own dropdowns offer (users, role definitions,
  # product types, linked sub-products); an unknown value fails the row and lists the options.
  #
  # ── RUN ──────────────────────────────────────────────────────────────────────────────────────
  #   cd beyond-lo-tests && mvn test -Dkarate.env=dev -Dkarate.tags="@approval-limit-setup"
  # KarateTestRunner.configSetup() runs it right after 00-Setup-Configurations.feature (both carry
  # @config-setup), so product types created by the config sheet exist before their limits are set.

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Approval-Limits-Automation.xlsx')
    * def rawData = ExcelDataLoader.load(excelPath, 'Approval_Limits')
    * def rows = karate.filter(rawData, function(x){ return x.run && x.run.toString().toUpperCase() == 'Y' })
    * def rowCount = rows.length

  Scenario: Run Approval Limit Setup for all enabled Excel rows
    * print '======================================================'
    * print 'STARTING APPROVAL LIMIT SETUP EXECUTION'
    * print 'Total Enabled Approval Limit Rows:', rowCount
    * print '======================================================'
    * if (rowCount > 0) karate.call('classpath:features/loans/02-Setup-Approval-Limits.feature@executeRow', rows)

  @ignore @executeRow
  Scenario: Execute Single Approval Limit Row
    * def td = typeof __arg !== 'undefined' ? __arg : {}
    * url baseUrl
    * configure retry = { count: 24, interval: 5000 }

    # ── small helpers ─────────────────────────────────────────────────────────────────────────
    * def strVal = function(val, defVal) { return (val != null && val.toString().trim() != '') ? val.toString().trim() : defVal }
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def boolVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; return isTrue(s); }
    * def numVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; var n = parseFloat(s.replace(/,/g, '')); return isNaN(n) ? defVal : n; }
    * def rowTag = '[APPROVAL-LIMIT-SETUP ' + strVal(td.limitId, 'row') + ']'
    * def note = function(m) { karate.log(rowTag, m); }
    # karate.fail() only marks the step failed; the throw is what actually stops the JS function.
    * def fail = function(m) { var msg = rowTag + ' ' + m; karate.log(msg); karate.fail(msg); throw new Error(msg); }
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
    # Sheet dates: yyyy-MM-dd, dd-MM-yyyy or dd/MM/yyyy (the screen shows dd-mm-yyyy) -> ISO yyyy-MM-dd
    * def isoDate =
      """
      function(v, col) {
        var s = strVal(v, null);
        if (s == null) return null;
        if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
        var m = /^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4})$/.exec(s);
        if (m != null) return m[3] + '-' + (m[2].length == 1 ? '0' + m[2] : m[2]) + '-' + (m[1].length == 1 ? '0' + m[1] : m[1]);
        var m2 = /^(\d{4})[\/.](\d{1,2})[\/.](\d{1,2})$/.exec(s);
        if (m2 != null) return m2[1] + '-' + (m2[2].length == 1 ? '0' + m2[2] : m2[2]) + '-' + (m2[3].length == 1 ? '0' + m2[3] : m2[3]);
        fail('column "' + col + '" = "' + s + '" is not a date (use yyyy-MM-dd or dd-MM-yyyy)');
      }
      """
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

    # ── inputs from the sheet (the New Approval Limit form) ───────────────────────────────────
    * def rowDescription = strVal(td.description, strVal(td.limitId, 'approval limit'))
    * def authorityTypeRaw = req('authorityType', 'on every row (User | Role | Credit Committee)')
    * def authorityNameRaw = req('authorityName', 'on every row (username, role, or credit-committee role)')
    * def loanTypeRaw = req('loanType', 'on every row (the product type code or name)')
    * def subProductRaw = strVal(td.subProductCode, null)
    * def limitAmount = numVal(req('limitAmount', 'on every row'), null)
    * if (limitAmount == null || limitAmount <= 0) fail('limitAmount must be a number greater than 0')
    * def currencyCode = req('currencyCode', 'on every row (e.g. USD)').toUpperCase()
    * def effectiveFrom = isoDate(req('effectiveFrom', 'on every row (yyyy-MM-dd; a past date so the limit resolves today)'), 'effectiveFrom')
    * def effectiveTo = isoDate(td.effectiveTo, 'effectiveTo')
    * if (effectiveTo != null && effectiveTo <= effectiveFrom) fail('effectiveTo (' + effectiveTo + ') must be after effectiveFrom (' + effectiveFrom + ')')
    * if (effectiveTo != null && effectiveTo <= today) fail('effectiveTo (' + effectiveTo + ') has already passed; the server refuses to approve an expired limit')
    * def withinBranch = boolVal(td.approvalWithinBranch, true)
    * def partyType = strVal(td.partyType, null) == null ? null : strVal(td.partyType, null).toUpperCase()
    * if (partyType != null && partyType != 'PERSONAL' && partyType != 'ENTERPRISE') fail('partyType must be PERSONAL, ENTERPRISE or blank (any party), not ' + partyType)
    * def facilityType = strVal(td.facilityType, 'LOAN').toUpperCase()
    * if (facilityType != 'LOAN' && facilityType != 'OVERDRAFT' && facilityType != 'COMMITMENTS') fail('facilityType must be LOAN, OVERDRAFT or COMMITMENTS, not ' + facilityType)
    * def toAuthorityType =
      """
      function(s) {
        var k = s.toUpperCase().replace(/[\s_-]+/g, '');
        if (k == 'USER') return 'USER';
        if (k == 'ROLE') return 'ROLE';
        if (k == 'CREDITCOMMITTEE' || k == 'COMMITTEE' || k == 'CC') return 'CREDIT_COMMITTEE';
        fail('authorityType "' + s + '" is not one of User | Role | Credit Committee');
      }
      """
    * def authorityType = toAuthorityType(authorityTypeRaw)
    * def votesRequired = numVal(td.votesRequired, null)
    * if (authorityType == 'CREDIT_COMMITTEE' && votesRequired == null) fail('votesRequired is required for a Credit Committee limit (<= active members of the committee role)')
    * if (authorityType != 'CREDIT_COMMITTEE' && votesRequired != null) note('votesRequired is ignored for authorityType ' + authorityType)
    * def selfAllowed = authorityType == 'USER' ? boolVal(td.approvalBySelfAllowed, false) : false
    * if (authorityType != 'USER' && strVal(td.approvalBySelfAllowed, null) != null) note('approvalBySelfAllowed is ignored for authorityType ' + authorityType)

    * print rowTag, 'Processing:', rowDescription, '|', authorityType, authorityNameRaw, '|', loanTypeRaw, '|', limitAmount, currencyCode

    # ── 0. ACCOUNTS: an admin that manages limits, a checker that can approve ─────────────────
    * def excelAdminUser = strVal(td.adminUsername, null)
    * def excelAdminPass = strVal(td.adminPassword, defaultAdminPassword)
    * def excelCheckerUser = strVal(td.checkerUsername, null)
    * def excelCheckerPass = strVal(td.checkerPassword, defaultAdminPassword)
    * def canManage = function(header) { var r = api('GET', '/v1/approval-limits?size=1', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canManage(h)) return { user: excelAdminUser, header: h, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot read approval limits (needs MANAGE_APPROVAL_LIMITS) - falling back to ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        if (excelAdminUser != defaultAdminUsername) {
          var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
          if (h2 != null && canManage(h2)) return { user: defaultAdminUsername, header: h2, source: 'karate-config' };
          if (h2 != null) logout(h2);
          tried.push(defaultAdminUsername);
        }
        fail('no admin account can manage approval limits (needs MANAGE_APPROVAL_LIMITS). Tried: ' + tried.join(', ') + '. Fill adminUsername/adminPassword in the sheet, or fix roleCandidates.admin in karate-config.js.');
      }
      """
    * def admin = resolveAdmin()
    * def adminUser = admin.user
    * def adminHeader = admin.header
    * note('admin account: ' + adminUser + ' (' + admin.source + ')')
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
    * def ckUsername = null
    * def ckHeaderVal = null
    * def ckPassword = null
    * def ckUser = function() { return karate.get('ckUsername'); }
    * def ckHeader = function() { return karate.get('ckHeaderVal'); }
    * def ckSet = function(u, h, p) { karate.set('ckUsername', u); karate.set('ckHeaderVal', h); karate.set('ckPassword', p); }
    * def relogCheckerIfNeeded = function() { if (ckUser() == null) return; var h = softLogin(ckUser(), karate.get('ckPassword')); if (h != null) karate.set('ckHeaderVal', h); }

    # ── CHANGE-REQUEST HANDLING (maker-checker), same contract as 00-Setup-Configurations ─────
    * def ensureSupervisorLink =
      """
      function(user, supervisor) {
        if (user == null || user == supervisor) return;
        var ex = api('GET', '/v1/supervisor-links/by-user/' + user, adminHeader, null);
        if (ex.status == 200 && ex.body != null) {
          for (var i = 0; i < ex.body.length; i++) { if (ex.body[i].supervisorUsername == supervisor && ex.body[i].active) return; }
        }
        var r = api('POST', '/v1/supervisor-links', adminHeader, { userUsername: user, supervisorUsername: supervisor, active: true });
        note('supervisor link ' + user + ' -> ' + supervisor + ': HTTP ' + r.status);
      }
      """
    * def crGet = function(id) { return api('GET', '/v1/change-requests/' + id, adminHeader, null); }
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
            var votes = 0; var lastErr = null; var usedCheckers = {}; var guard = 0;
            while (status == 'PENDING_APPROVAL' && guard < 4) {
              guard++;
              var csUser = null; var csHeader = null;
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
              var a = api('POST', '/v1/change-requests/' + id + '/approve', csHeader, { comment: 'Approved by Excel approval-limit setup (' + what + ')' });
              if (a.status == 401) { relogCheckerIfNeeded(); a = api('POST', '/v1/change-requests/' + id + '/approve', ckHeader(), { comment: 'Approved by Excel approval-limit setup (' + what + ')' }); }
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
    * def resolvePending =
      """
      function(keywords, what) {
        var r = api('GET', '/v1/change-requests/all-pending', adminHeader, null);
        if (r.status != 200 || r.body == null) { note(what + ': could not list pending change requests: ' + show(r)); return false; }
        var handled = 0;
        for (var i = 0; i < r.body.length; i++) {
          var cr = r.body[i];
          if (('' + cr.eventCode).indexOf('APPROVAL_LIMIT') < 0) continue;
          var label = ('' + (cr.entityLabel != null ? cr.entityLabel : '') + ' ' + (cr.entityId != null ? cr.entityId : '') + ' ' + (cr.payload != null ? JSON.stringify(cr.payload) : '')).toUpperCase();
          var hit = false;
          for (var k = 0; k < keywords.length; k++) { if (keywords[k] != null && label.indexOf(('' + keywords[k]).toUpperCase()) >= 0) hit = true; }
          if (!hit) continue;
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
    * def governed =
      """
      function(what, res, retryFn, keywords) {
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
          if (!resolvePending(keywords, what)) fail(what + ': a change request is already pending and could not be resolved. ' + show(res));
          return governed(what, retryFn(), null, keywords);
        }
        fail(what + ' -> ' + show(res));
      }
      """

    # ── 1. RESOLVE the dropdown values the form offers ────────────────────────────────────────
    * def eq = function(a, b) { return a != null && b != null && ('' + a).trim().toLowerCase() == ('' + b).trim().toLowerCase(); }
    * def resolveAuthorityName =
      """
      function() {
        if (authorityType == 'USER') {
          var u = api('GET', '/v1/users', adminHeader, null);
          if (u.status != 200 || u.body == null) fail('cannot list users to validate authorityName: ' + show(u));
          var names = [];
          for (var i = 0; i < u.body.length; i++) {
            var row = u.body[i];
            names.push(row.username + (row.fullName != null ? ' (' + row.fullName + ')' : ''));
            if (eq(row.username, authorityNameRaw) || eq(row.fullName, authorityNameRaw)) return { code: '' + row.username, label: row.fullName != null ? '' + row.fullName : '' + row.username };
          }
          fail('authorityName "' + authorityNameRaw + '" is not an active user. Users: ' + names.join(', '));
        }
        // ROLE and CREDIT_COMMITTEE both name a role definition; the server stores the role code
        var r = api('GET', '/v1/master-data/role-definitions?size=500', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list role definitions to validate authorityName: ' + show(r));
        var list = r.body.content != null ? r.body.content : r.body;
        var opts = [];
        var found = null;
        for (var j = 0; j < list.length; j++) {
          var role = list[j];
          if (role.active == false) continue;
          opts.push(role.roleCode + ' = ' + role.roleName);
          if (eq(role.roleCode, authorityNameRaw) || eq(role.roleName, authorityNameRaw) || eq('ROLE_' + role.roleCode, authorityNameRaw)) found = { code: '' + role.roleCode, label: '' + role.roleName };
        }
        if (found == null) fail('authorityName "' + authorityNameRaw + '" is not an active role. Roles: ' + opts.join(', '));
        if (found.code != authorityNameRaw) note('authorityName "' + authorityNameRaw + '" resolved to role ' + found.code);
        return found;
      }
      """
    * def authority = resolveAuthorityName()
    * def authorityName = authority.code
    * def resolveLoanType =
      """
      function() {
        var r = api('GET', '/v1/product-types', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list product types to validate loanType: ' + show(r));
        var opts = [];
        for (var i = 0; i < r.body.length; i++) {
          var pt = r.body[i];
          opts.push(pt.code + ' = ' + pt.name);
          if (eq(pt.code, loanTypeRaw) || eq(pt.name, loanTypeRaw)) return { code: '' + pt.code, label: '' + pt.name };
        }
        fail('loanType "' + loanTypeRaw + '" is not a product type on this server. Create it in the Product_Configurations sheet first, or use one of: ' + opts.join(', '));
      }
      """
    * def loanTypeObj = resolveLoanType()
    * def loanType = loanTypeObj.code
    * if (loanType != loanTypeRaw) note('loanType "' + loanTypeRaw + '" resolved to product type ' + loanType)
    * def ltPath = encodeURIComponent(loanType)
    * def resolveSubProduct =
      """
      function() {
        if (subProductRaw == null) return null;
        var r = api('GET', '/v1/product-types/' + ltPath + '/products', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list the sub-products of ' + loanType + ': ' + show(r));
        var opts = [];
        for (var i = 0; i < r.body.length; i++) {
          var p = r.body[i];
          opts.push(p.productCode + ' = ' + p.productDescription);
          if (eq(p.productCode, subProductRaw) || eq(p.productDescription, subProductRaw)) return '' + p.productCode;
        }
        fail('subProductCode "' + subProductRaw + '" is not linked to product type ' + loanType + '. Leave it blank for all sub-products, or use one of: ' + (opts.length > 0 ? opts.join(', ') : '(none linked yet - link it via selectedProductCode in Product_Configurations)'));
      }
      """
    * def subProductCode = resolveSubProduct()

    # ── 2. DESIRED RECORD, as the form would submit it ────────────────────────────────────────
    * def desired =
      """
      {
        authorityType: '#(authorityType)',
        authorityName: '#(authorityName)',
        facilityType: '#(facilityType)',
        loanType: '#(loanType)',
        subProductCode: '#(subProductCode)',
        partyType: '#(partyType)',
        limitAmount: '#(limitAmount)',
        currencyCode: '#(currencyCode)',
        effectiveFrom: '#(effectiveFrom)',
        effectiveTo: '#(effectiveTo)',
        approvalWithinBranch: '#(withinBranch)',
        approvalBySelfAllowed: '#(selfAllowed)',
        votesRequired: '#(authorityType == "CREDIT_COMMITTEE" ? votesRequired : null)'
      }
      """
    * def what = authorityType + ' ' + authorityName + ' on ' + loanType + (subProductCode != null ? '/' + subProductCode : '') + ' ' + limitAmount + ' ' + currencyCode

    # ── 3. EXISTING LIMIT for the same authority / loan product / party / currency ────────────
    * def findExisting =
      """
      function() {
        var r = api('GET', '/v1/approval-limits?status=ACTIVE&size=500&loanType=' + ltPath + '&currencyCode=' + encodeURIComponent(currencyCode) + '&authorityType=' + authorityType, adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search approval limits: ' + show(r));
        var rows = r.body.content != null ? r.body.content : r.body;
        var same = function(a, b) { var x = strVal(a, null); var y = strVal(b, null); return (x == null && y == null) || (x != null && y != null && x.toLowerCase() == y.toLowerCase()); };
        // The server's duplicate rule (AC3) treats a limit with no party type as the same record as one
        // for PERSONAL or ENTERPRISE, so a party-agnostic limit is matched (and then amended) rather
        // than duplicated. An exact party-type match wins over a party-agnostic one.
        var fallback = null;
        for (var i = 0; i < rows.length; i++) {
          var l = rows[i];
          if (l.status != 'ACTIVE') continue;
          if (!same(l.authorityName, authorityName)) continue;
          if (!same(l.subProductCode, subProductCode)) continue;
          if (same(l.partyType, partyType)) return l;
          if (fallback == null && (strVal(l.partyType, null) == null || partyType == null)) fallback = l;
        }
        return fallback;
      }
      """
    * def differences =
      """
      function(l) {
        var d = [];
        if (Number(l.limitAmount) != Number(limitAmount)) d.push('limitAmount ' + l.limitAmount + ' -> ' + limitAmount);
        if (strVal(l.effectiveFrom, null) != effectiveFrom) d.push('effectiveFrom ' + l.effectiveFrom + ' -> ' + effectiveFrom);
        if (strVal(l.effectiveTo, null) != effectiveTo) d.push('effectiveTo ' + l.effectiveTo + ' -> ' + (effectiveTo == null ? 'open-ended' : effectiveTo));
        var lb = l.approvalWithinBranch == null ? true : l.approvalWithinBranch == true;
        if (lb != withinBranch) d.push('approvalWithinBranch ' + lb + ' -> ' + withinBranch);
        if (authorityType == 'USER' && (l.approvalBySelfAllowed == true) != selfAllowed) d.push('approvalBySelfAllowed ' + (l.approvalBySelfAllowed == true) + ' -> ' + selfAllowed);
        if (authorityType == 'CREDIT_COMMITTEE' && Number(l.votesRequired) != Number(votesRequired)) d.push('votesRequired ' + l.votesRequired + ' -> ' + votesRequired);
        if (strVal(l.facilityType, 'LOAN').toUpperCase() != facilityType) d.push('facilityType ' + l.facilityType + ' -> ' + facilityType);
        var lp = strVal(l.partyType, null); var lpu = lp == null ? null : lp.toUpperCase();
        if (lpu != partyType) d.push('partyType ' + (lpu == null ? 'any' : lpu) + ' -> ' + (partyType == null ? 'any' : partyType));
        return d;
      }
      """

    # ── 4. CREATE or AMEND through governance ─────────────────────────────────────────────────
    * def setupLimit =
      """
      function() {
        var existing = findExisting();
        var keywords = [loanType, authorityName];
        if (existing != null) {
          var diff = differences(existing);
          if (diff.length == 0) {
            note('limit ' + existing.id + ' already ACTIVE and identical to the sheet (' + what + ') - nothing to do');
            return { id: existing.id, action: 'unchanged' };
          }
          note('limit ' + existing.id + ' differs from the sheet: ' + diff.join(', ') + ' - requesting an amendment');
          var body = karate.merge(desired, { id: existing.id });
          var send = function() { return api('PUT', '/v1/approval-limits/' + existing.id + '/request-amendment', adminHeader, body); };
          governed('amend limit ' + existing.id + ' (' + what + ')', send(), send, keywords);
          return { id: existing.id, action: 'amended' };
        }
        var create = function() { return api('POST', '/v1/approval-limits', adminHeader, desired); };
        governed('create limit (' + what + ')', create(), create, keywords);
        var made = findExisting();
        if (made == null) fail('the change request for ' + what + ' was committed but no ACTIVE limit with that authority / loan type / sub-product / party type / currency can be found afterwards');
        return { id: made.id, action: 'created' };
      }
      """
    * def outcome = setupLimit()

    # ── 5. VERIFY: re-read the limit the way the Approval Limits screen would list it ─────────
    * def verify =
      """
      function() {
        var g = api('GET', '/v1/approval-limits/' + outcome.id, adminHeader, null);
        if (g.status != 200 || g.body == null) fail('VERIFY: limit ' + outcome.id + ' cannot be read back: ' + show(g));
        var l = g.body;
        if (l.status != 'ACTIVE') fail('VERIFY: limit ' + outcome.id + ' is ' + l.status + ', expected ACTIVE');
        var diff = differences(l);
        if (diff.length > 0) fail('VERIFY: limit ' + outcome.id + ' does not match the sheet after ' + outcome.action + ': ' + diff.join(', '));
        return 'limit ' + l.id + ' ' + outcome.action + ': ' + l.authorityType + ' ' + l.authorityName + ' | ' + l.loanType + (l.subProductCode != null ? ' / ' + l.subProductCode : ' / all sub-products') + ' | ' + l.limitAmount + ' ' + l.currencyCode + ' | ' + l.effectiveFrom + ' to ' + (l.effectiveTo != null ? l.effectiveTo : 'open-ended') + ' | own branch only=' + (l.approvalWithinBranch == null ? true : l.approvalWithinBranch) + (l.votesRequired != null ? ' | votes=' + l.votesRequired : '') + (l.partyType != null ? ' | party=' + l.partyType : ' | any party');
      }
      """
    * def summary = verify()
    * note('APPROVAL LIMIT COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(adminHeader)

