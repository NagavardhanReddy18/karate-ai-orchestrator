@config-setup @incident-charge-setup @data-driven
Feature: Excel-driven incident-charge setup — Configuration > Incident Charges Definition and the product types that levy them, driven from Incident-Charges-Automation.xlsx

  # ── WHAT THIS DOES ───────────────────────────────────────────────────────────────────────────
  # Reads testdata/Incident-Charges-Automation.xlsx (sheet Incident_Charges) and, for every row with
  # run=Y, makes the server hold exactly the charge definition the row describes — the record an admin
  # submits through New Charge Definition — and attaches it to the product types the row names:
  #
  #   CHARGE DETAILS   chargeName, incident (APPLICATION | ASSESSMENT | OFFER | SETUP), channels,
  #                    deferredCharge + deferredCollectionStage, narration, refundable, amendable
  #   CALCULATION      calculationMethod FLAT (FIXED on the screen) | PERCENTAGE | TIERS_FIXED | TIERS_PERCENTAGE
  #                    flatAmount | rate + calcBase (+ minCharge / maxCharge) | tiers JSON (+ loanTenor)
  #   PERIOD           effectiveFrom (blank = today; the server refuses a past date), effectiveTo, currency
  #   TAX              taxRate, taxCurrency
  #   RECEIVING        chargeReceivingAccount (charge pseudonym), taxReceivingAccount (tax pseudonym)
  #   ATTACH           attachToProductTypes (comma list), attachToSubProducts (TYPE:SUBPRODUCT pairs)
  #
  # A charge that already exists with the same name, incident and currency is compared field by field:
  # identical = nothing to do, different = an amendment is requested (PUT). Every write is governed
  # (202 + ChangeRequest with SUPERVISOR_APPROVAL severity): approved by a checker that is not the
  # maker, then committed here. The charge code CHG-NNNNNN is assigned by the server on commit.
  #
  # Attaching adds the charge to the product type's Origination Configuration (the same amendment the
  # Product Types screen sends), keeping the charges, scorecard, methods and checklist already there.
  # A product type named here must already exist — Product-Configuration-Automation.xlsx creates it.
  # The lifecycle features then collect whatever the attached charges materialise at each phase.
  #
  # ── RUN ──────────────────────────────────────────────────────────────────────────────────────
  #   cd beyond-lo-tests && mvn test -Dkarate.env=dev -Dkarate.tags="@incident-charge-setup"
  # KarateTestRunner.configSetup() runs it after 00 / 01 / 02 (all carry @config-setup).

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Incident-Charges-Automation.xlsx')
    * def rawData = ExcelDataLoader.load(excelPath, 'Incident_Charges')
    * def rows = karate.filter(rawData, function(x){ return x.run && x.run.toString().toUpperCase() == 'Y' })
    * def rowCount = rows.length

  Scenario: Run Incident Charge Setup for all enabled Excel rows
    * print '======================================================'
    * print 'STARTING INCIDENT CHARGE SETUP EXECUTION'
    * print 'Total Enabled Incident Charge Rows:', rowCount
    * print '======================================================'
    * if (rowCount > 0) karate.call('classpath:features/loans/03A-Setup-Incident-Charges.feature@executeRow', rows)

  @ignore @executeRow
  Scenario: Execute Single Incident Charge Row
    * def td = typeof __arg !== 'undefined' ? __arg : {}
    * url baseUrl
    * configure retry = { count: 24, interval: 5000 }

    # ── small helpers ─────────────────────────────────────────────────────────────────────────
    * def strVal = function(val, defVal) { return (val != null && val.toString().trim() != '') ? val.toString().trim() : defVal }
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def boolVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; return isTrue(s); }
    * def numVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; var n = parseFloat(('' + s).replace(/,/g, '')); return isNaN(n) ? defVal : n; }
    * def splitList = function(val) { var out = []; var s = strVal(val, ''); if (s == '') return out; var parts = s.split(','); for (var i = 0; i < parts.length; i++) { if (parts[i].trim() != '') out.push(parts[i].trim()); } return out; }
    * def rowTag = '[INCIDENT-CHARGE-SETUP ' + strVal(td.chargeId, 'row') + ']'
    * def note = function(m) { karate.log(rowTag, m); }
    * def fail = function(m) { var msg = rowTag + ' ' + m; karate.log(msg); karate.fail(msg); throw new Error(msg); }
    * def req = function(col, why) { var v = strVal(td[col], null); if (v == null) fail('column "' + col + '" is blank but is required ' + why); return v; }
    * def eq = function(a, b) { return a != null && b != null && ('' + a).trim().toLowerCase() == ('' + b).trim().toLowerCase(); }
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
        if (m == 'PATCH') return h.patch(body == null ? {} : body);
        return h.post(body == null ? {} : body);
      }
      """
    * def today = java.time.LocalDate.now().toString()
    * def isoDate =
      """
      function(v, col) {
        var s = strVal(v, null);
        if (s == null) return null;
        if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
        var m = /^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4})$/.exec(s);
        if (m != null) return m[3] + '-' + (m[2].length == 1 ? '0' + m[2] : m[2]) + '-' + (m[1].length == 1 ? '0' + m[1] : m[1]);
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

    # ── inputs from the sheet (the New Charge Definition form) ───────────────────────────────
    * def rowDescription = strVal(td.description, strVal(td.chargeId, 'incident charge'))
    * def chargeName = req('chargeName', 'on every row (Charge Name)')
    * def incident = req('incident', 'on every row (Incident: APPLICATION | ASSESSMENT | OFFER | SETUP)').toUpperCase()
    * if (['APPLICATION', 'ASSESSMENT', 'OFFER', 'SETUP'].indexOf(incident) < 0) fail('incident must be APPLICATION, ASSESSMENT, OFFER or SETUP, not ' + incident)
    * def channelsWanted = splitList(strVal(td.channels, 'BEYONDLO'))
    * def deferred = boolVal(td.deferredCharge, false)
    * def deferredStage = strVal(td.deferredCollectionStage, null) == null ? null : strVal(td.deferredCollectionStage, null).toUpperCase()
    * if (deferred && deferredStage == null) fail('deferredCollectionStage is required when deferredCharge=true (APPLICATION | ASSESSMENT | OFFER | OFFER_ACCEPTANCE | SETUP, later than the incident)')
    * if (!deferred && deferredStage != null) fail('deferredCollectionStage can only be set when deferredCharge=true')
    * def narration = strVal(td.narration, null)
    * def refundable = boolVal(td.refundable, false)
    * def amendable = boolVal(td.amendable, false)
    * def methodRaw = req('calculationMethod', 'on every row (FLAT | PERCENTAGE | TIERS_FIXED | TIERS_PERCENTAGE)').toUpperCase().replace(/[\s-]+/g, '_')
    * def method = methodRaw == 'FIXED' ? 'FLAT' : (methodRaw == 'TIERS_FLAT' ? 'TIERS_FIXED' : methodRaw)
    * if (['FLAT', 'PERCENTAGE', 'TIERS_FIXED', 'TIERS_PERCENTAGE'].indexOf(method) < 0) fail('calculationMethod must be FLAT (FIXED), PERCENTAGE, TIERS_FIXED or TIERS_PERCENTAGE, not ' + methodRaw)
    * def flatAmount = numVal(td.flatAmount, null)
    * def rate = numVal(td.rate, null)
    * def calcBase = strVal(td.calcBase, null) == null ? null : strVal(td.calcBase, null).toUpperCase()
    * def minCharge = numVal(td.minCharge, null)
    * def maxCharge = numVal(td.maxCharge, null)
    * def loanTenor = strVal(td.loanTenor, null) == null ? null : strVal(td.loanTenor, null).toUpperCase()
    * if (method == 'FLAT' && flatAmount == null) fail('flatAmount is required when calculationMethod is FLAT')
    * if ((method == 'PERCENTAGE') && rate == null) fail('rate is required when calculationMethod is PERCENTAGE')
    * if ((method == 'PERCENTAGE' || method == 'TIERS_PERCENTAGE') && calcBase == null) fail('calcBase is required when calculationMethod is ' + method + ' (e.g. LOAN_AMOUNT)')
    * def tiers =
      """
      (function() {
        var s = strVal(td.tiers, null);
        if (method != 'TIERS_FIXED' && method != 'TIERS_PERCENTAGE') { if (s != null) note('tiers are ignored for calculationMethod ' + method); return null; }
        if (s == null) fail('tiers is required when calculationMethod is ' + method + ' (JSON list of at least 2 tiers)');
        var v;
        try { v = JSON.parse(s); } catch (e) { fail('tiers is not valid JSON: ' + e); }
        if (!Array.isArray(v) || v.length < 2) fail('tiers must list at least 2 tiers');
        var out = [];
        for (var i = 0; i < v.length; i++) {
          var t = v[i];
          var tier = { tierSeq: i + 1, fromAmount: numVal(t.fromAmount, 0), toAmount: numVal(t.toAmount, null), tenorFrom: numVal(t.tenorFrom, null), tenorTo: numVal(t.tenorTo, null), fixedAmount: numVal(t.fixedAmount, null), rate: numVal(t.rate, null) };
          if (method == 'TIERS_FIXED' && tier.fixedAmount == null) fail('tiers[' + i + '] needs fixedAmount for TIERS_FIXED');
          if (method == 'TIERS_PERCENTAGE' && tier.rate == null) fail('tiers[' + i + '] needs rate for TIERS_PERCENTAGE');
          out.push(tier);
        }
        return out;
      })()
      """
    * def effectiveFrom = isoDate(strVal(td.effectiveFrom, today), 'effectiveFrom')
    * def effectiveTo = isoDate(td.effectiveTo, 'effectiveTo')
    * if (effectiveTo != null && effectiveTo < effectiveFrom) fail('effectiveTo (' + effectiveTo + ') must be on or after effectiveFrom (' + effectiveFrom + ')')
    * def currency = req('currency', 'on every row (e.g. USD)').toUpperCase()
    * def taxRate = numVal(td.taxRate, null)
    * def taxCurrency = strVal(td.taxCurrency, null) == null ? null : strVal(td.taxCurrency, null).toUpperCase()
    * if (taxRate != null && taxCurrency == null) fail('taxCurrency is required when taxRate is given')
    * def chargeAccount = req('chargeReceivingAccount', 'on every row (Charge Receiving Account)')
    * def taxAccount = strVal(td.taxReceivingAccount, null)
    * if (taxRate != null && taxAccount == null) fail('taxReceivingAccount is required when taxRate is given')
    * def status = strVal(td.status, 'ACTIVE').toUpperCase()
    * if (status != 'ACTIVE' && status != 'INACTIVE') fail('status must be ACTIVE or INACTIVE, not ' + status)
    * def attachTypes = splitList(td.attachToProductTypes)
    * def attachSubs = splitList(td.attachToSubProducts)
    * print rowTag, 'Processing:', rowDescription, '|', chargeName, '|', incident, method, currency, '| attach to:', (attachTypes.length > 0 ? attachTypes.join(', ') : '(none)'), (attachSubs.length > 0 ? '| sub-products: ' + attachSubs.join(', ') : '')

    # ── 0. ACCOUNTS ───────────────────────────────────────────────────────────────────────────
    * def excelAdminUser = strVal(td.adminUsername, null)
    * def excelAdminPass = strVal(td.adminPassword, defaultAdminPassword)
    * def excelCheckerUser = strVal(td.checkerUsername, null)
    * def excelCheckerPass = strVal(td.checkerPassword, defaultAdminPassword)
    * def canManage = function(header) { var r = api('GET', '/v1/config/incident-charge-definitions?status=ACTIVE', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canManage(h)) return { user: excelAdminUser, header: h, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot read incident charge definitions (needs MANAGE_INCIDENT_CHARGE_DEFINITIONS) - falling back to ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        if (excelAdminUser != defaultAdminUsername) {
          var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
          if (h2 != null && canManage(h2)) return { user: defaultAdminUsername, header: h2, source: 'karate-config' };
          if (h2 != null) logout(h2);
          tried.push(defaultAdminUsername);
        }
        fail('no admin account can manage incident charge definitions (needs MANAGE_INCIDENT_CHARGE_DEFINITIONS). Tried: ' + tried.join(', ') + '. Fill adminUsername/adminPassword in the sheet, or fix roleCandidates.admin in karate-config.js.');
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

    # ── CHANGE-REQUEST HANDLING (maker-checker), same contract as 00 / 01 / 02 ────────────────
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
              var a = api('POST', '/v1/change-requests/' + id + '/approve', csHeader, { comment: 'Approved by Excel incident-charge setup (' + what + ')' });
              if (a.status == 401) { relogCheckerIfNeeded(); a = api('POST', '/v1/change-requests/' + id + '/approve', ckHeader(), { comment: 'Approved by Excel incident-charge setup (' + what + ')' }); }
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
      function(eventHints, keywords, what) {
        var r = api('GET', '/v1/change-requests/all-pending', adminHeader, null);
        if (r.status != 200 || r.body == null) { note(what + ': could not list pending change requests: ' + show(r)); return false; }
        var handled = 0;
        for (var i = 0; i < r.body.length; i++) {
          var cr = r.body[i];
          var ev = ('' + cr.eventCode + ' ' + cr.entityType).toUpperCase();
          var kind = false;
          for (var p = 0; p < eventHints.length; p++) { if (ev.indexOf(eventHints[p]) >= 0) kind = true; }
          if (!kind) continue;
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
    # The charge API wraps its answers: { success, message, data } — the change request is in data.
    * def unwrap = function(b) { return (b != null && typeof b == 'object' && b.data !== undefined && (b.success !== undefined || b.message !== undefined)) ? b.data : b; }
    * def governed =
      """
      function(what, res, retryFn, eventHints, keywords) {
        if (res.status >= 200 && res.status < 300) {
          var b = unwrap(res.body);
          if (b != null && typeof b == 'object' && b.id != null && b.eventCode != null && b.status != null) {
            note(what + ': change request ' + b.id + ' raised (' + b.eventCode + ', ' + b.status + ', ' + b.eventSeverity + ')');
            var err = settleCr(b, what);
            if (err != null) fail(err);
            return true;
          }
          note(what + ': applied (HTTP ' + res.status + ')');
          return true;
        }
        var text = ('' + (res.body == null ? '' : (typeof res.body == 'string' ? res.body : JSON.stringify(res.body)))).toLowerCase();
        var pendingLike = res.status == 409 && text.indexOf('pending') >= 0;
        if (pendingLike && retryFn != null) {
          note(what + ': ' + text.substring(0, 300));
          if (!resolvePending(eventHints, keywords, what)) fail(what + ': a change request is already pending and could not be resolved. ' + show(res));
          return governed(what, retryFn(), null, eventHints, keywords);
        }
        fail(what + ' -> ' + show(res));
      }
      """

    # ── 1. CHANNELS the form offers (generic-code group CHANNEL) ─────────────────────────────
    * def channelCodes =
      """
      (function() {
        var r = api('GET', '/v1/generic-codes/CHANNEL/options?locale=en', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot read the Channel options (generic-code group CHANNEL): ' + show(r));
        var out = []; var opts = [];
        for (var i = 0; i < channelsWanted.length; i++) {
          var found = null;
          for (var j = 0; j < r.body.length; j++) { var o = r.body[j]; if (opts.length < r.body.length) opts.push(o.valueCode + ' = ' + o.label); if (eq(o.valueCode, channelsWanted[i]) || eq(o.label, channelsWanted[i])) found = '' + o.valueCode; }
          if (found == null) fail('channel "' + channelsWanted[i] + '" is not a Channel the form offers. Use one of: ' + opts.join(', '));
          if (out.indexOf(found) < 0) out.push(found);
        }
        return out;
      })()
      """

    # ── 2. DESIRED RECORD, as the form would submit it ────────────────────────────────────────
    * def desired =
      """
      (function() {
        var d = {
          chargeName: chargeName, chargeNarration: narration, currency: currency, calculationMethod: method,
          loanTenor: loanTenor, flatAmount: method == 'FLAT' ? flatAmount : null,
          rate: (method == 'PERCENTAGE') ? rate : null, minCharge: method == 'PERCENTAGE' ? minCharge : null, maxCharge: method == 'PERCENTAGE' ? maxCharge : null,
          taxRate: taxRate, taxCurrency: taxRate != null ? taxCurrency : null, chargeStatus: status, tiers: tiers,
          event: incident, refundable: refundable, amendable: amendable,
          effectiveFromDate: effectiveFrom, effectiveToDate: effectiveTo,
          calcBase: (method == 'PERCENTAGE' || method == 'TIERS_PERCENTAGE') ? calcBase : null,
          applicableChannels: channelCodes.join(','), allowDeferred: deferred, deferredCollectionStage: deferred ? deferredStage : null,
          chargePseudonym: chargeAccount, taxPseudonym: taxRate != null ? taxAccount : null
        };
        return d;
      })()
      """
    * def what = chargeName + ' (' + incident + ', ' + method + ', ' + currency + ')'

    # ── 3. EXISTING charge with the same name / incident / currency ──────────────────────────
    * def listCharges =
      """
      function() {
        var r = api('GET', '/v1/config/incident-charge-definitions?search=' + encodeURIComponent(chargeName), adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search incident charge definitions: ' + show(r));
        var list = unwrap(r.body);
        return list == null ? [] : list;
      }
      """
    * def findExisting =
      """
      function() {
        var list = listCharges();
        var best = null;
        for (var i = 0; i < list.length; i++) {
          var c = list[i];
          if (!eq(c.chargeName, chargeName) || !eq(c.event, incident) || !eq(c.currency, currency)) continue;
          if (c.chargeStatus == 'ACTIVE') return c;
          if (best == null) best = c;
        }
        return best;
      }
      """
    * def num = function(v) { return v == null ? null : Number(v); }
    * def setOf = function(csv) { var s = ('' + (csv == null ? '' : csv)).split(','); var o = []; for (var i = 0; i < s.length; i++) { if (s[i].trim() != '') o.push(s[i].trim().toUpperCase()); } o.sort(); return o.join(','); }
    * def tierKey = function(list) { if (list == null || list.length == 0) return ''; var o = []; for (var i = 0; i < list.length; i++) { var t = list[i]; o.push([num(t.fromAmount), num(t.toAmount), num(t.tenorFrom), num(t.tenorTo), num(t.fixedAmount), num(t.rate)].join('/')); } return o.join('|'); }
    * def differences =
      """
      function(c) {
        var d = [];
        var cmp = function(label, a, b) { var x = (a == null || a === '') ? null : a; var y = (b == null || b === '') ? null : b; if (('' + x) != ('' + y)) d.push(label + ' ' + x + ' -> ' + y); };
        cmp('narration', c.chargeNarration, desired.chargeNarration);
        cmp('calculationMethod', c.calculationMethod, desired.calculationMethod);
        cmp('flatAmount', num(c.flatAmount), num(desired.flatAmount));
        cmp('rate', num(c.rate), num(desired.rate));
        cmp('calcBase', c.calcBase, desired.calcBase);
        cmp('minCharge', num(c.minCharge), num(desired.minCharge));
        cmp('maxCharge', num(c.maxCharge), num(desired.maxCharge));
        cmp('loanTenor', c.loanTenor, desired.loanTenor);
        cmp('taxRate', num(c.taxRate), num(desired.taxRate));
        cmp('taxCurrency', c.taxCurrency, desired.taxCurrency);
        cmp('status', c.chargeStatus, desired.chargeStatus);
        cmp('refundable', c.refundable == true, desired.refundable);
        cmp('amendable', c.amendable == true, desired.amendable);
        cmp('effectiveTo', c.effectiveToDate, desired.effectiveToDate);
        cmp('channels', setOf(c.applicableChannels), setOf(desired.applicableChannels));
        cmp('deferred', c.allowDeferred == true, desired.allowDeferred);
        cmp('deferredCollectionStage', c.deferredCollectionStage, desired.deferredCollectionStage);
        cmp('chargeReceivingAccount', c.chargePseudonym, desired.chargePseudonym);
        cmp('taxReceivingAccount', c.taxPseudonym, desired.taxPseudonym);
        cmp('tiers', tierKey(c.tiers), tierKey(desired.tiers));
        return d;
      }
      """

    # ── 4. CREATE or AMEND through governance ─────────────────────────────────────────────────
    * def setupCharge =
      """
      function() {
        var existing = findExisting();
        var hints = ['CHARGE', 'INCIDENT'];
        if (existing != null) {
          var diff = differences(existing);
          if (diff.length == 0) {
            note('charge ' + existing.id + ' ' + existing.chargeCode + ' already matches the sheet (' + what + ') - nothing to do');
            return { id: existing.id, code: existing.chargeCode, action: 'unchanged' };
          }
          note('charge ' + existing.id + ' ' + existing.chargeCode + ' differs from the sheet: ' + diff.join(', ') + ' - requesting an amendment');
          // effectiveFromDate is locked on update: keep the server's value
          var body = karate.merge(desired, { effectiveFromDate: existing.effectiveFromDate });
          var send = function() { return api('PUT', '/v1/config/incident-charge-definitions/' + existing.id, adminHeader, body); };
          governed('amend charge ' + existing.chargeCode + ' (' + what + ')', send(), send, hints, [chargeName, existing.chargeCode, existing.id]);
          return { id: existing.id, code: existing.chargeCode, action: 'amended' };
        }
        if (effectiveFrom < today) fail('effectiveFrom ' + effectiveFrom + ' is in the past; the server only accepts today or a future date when creating a charge (leave it blank for today)');
        var create = function() { return api('POST', '/v1/config/incident-charge-definitions', adminHeader, desired); };
        governed('create charge (' + what + ')', create(), create, hints, [chargeName]);
        var made = null;
        for (var i = 0; i < 30 && made == null; i++) { made = findExisting(); if (made == null) java.lang.Thread.sleep(1000); }
        if (made == null) fail('the change request for ' + what + ' was committed but no charge with that name / incident / currency is listed afterwards');
        return { id: made.id, code: made.chargeCode, action: 'created' };
      }
      """
    * def outcome = setupCharge()
    * def chargeDefId = outcome.id
    * def verifyCharge =
      """
      function() {
        var g = api('GET', '/v1/config/incident-charge-definitions/' + chargeDefId, adminHeader, null);
        if (g.status != 200) fail('VERIFY: charge ' + chargeDefId + ' cannot be read back: ' + show(g));
        var c = unwrap(g.body);
        var diff = differences(c);
        if (diff.length > 0) fail('VERIFY: charge ' + c.chargeCode + ' does not match the sheet after ' + outcome.action + ': ' + diff.join(', '));
        var amt = c.calculationMethod == 'FLAT' ? (c.flatAmount + ' ' + c.currency) : (c.calculationMethod == 'PERCENTAGE' ? (c.rate + '% of ' + c.calcBase + (c.minCharge != null ? ' min ' + c.minCharge : '') + (c.maxCharge != null ? ' max ' + c.maxCharge : '')) : (c.tiers.length + ' tiers'));
        return 'charge ' + c.chargeCode + ' (id ' + c.id + ') ' + outcome.action + ': ' + c.chargeName + ' | ' + c.event + ' | ' + c.calculationMethod + ' ' + amt + (c.taxRate != null ? ' | tax ' + c.taxRate + '% ' + c.taxCurrency : '') + ' | ' + c.effectiveFromDate + ' to ' + (c.effectiveToDate != null ? c.effectiveToDate : 'open') + ' | ' + c.chargeStatus + ' | channels ' + c.applicableChannels + (c.allowDeferred ? ' | deferred to ' + c.deferredCollectionStage : '');
      }
      """
    * def chargeSummary = verifyCharge()
    * note(chargeSummary)

    # ── 5. ATTACH to product types (Origination Configuration > Charges) ─────────────────────
    * def productTypes =
      """
      (function() {
        if (attachTypes.length == 0 && attachSubs.length == 0) return [];
        var r = api('GET', '/v1/product-types', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list product types: ' + show(r));
        return r.body.content != null ? r.body.content : r.body;
      })()
      """
    * def resolveProductType =
      """
      function(raw) {
        var opts = [];
        for (var i = 0; i < productTypes.length; i++) {
          var pt = productTypes[i];
          var nm = pt.label != null ? pt.label : (pt.name != null ? pt.name : pt.code);
          opts.push(pt.code + ' = ' + nm);
          if (eq(pt.code, raw) || eq(nm, raw)) return pt;
        }
        fail('product type "' + raw + '" does not exist on ' + baseUrl + '. Create it in Product-Configuration-Automation.xlsx (run=Y) and re-run the configuration setup, or use one of: ' + opts.join(', '));
      }
      """
    * def hasCharge = function(list) { for (var i = 0; list != null && i < list.length; i++) { if (('' + list[i].chargeDefId) == ('' + chargeDefId) && list[i].active != false) return true; } return false; }
    * def withCharge = function(list) { var out = []; for (var i = 0; list != null && i < list.length; i++) { if (('' + list[i].chargeDefId) == ('' + chargeDefId)) continue; out.push({ chargeDefId: list[i].chargeDefId, active: list[i].active != false }); } out.push({ chargeDefId: chargeDefId, active: true }); return out; }
    * def typeConfigOf =
      """
      function(pt) {
        var r = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/config', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('product type ' + pt.code + ' has no readable configuration: ' + show(r));
        return r.body;
      }
      """
    * def attachToType =
      """
      function(raw) {
        var pt = resolveProductType(raw);
        var cur = typeConfigOf(pt);
        if (hasCharge(cur.charges)) { note('product type ' + pt.code + ' already levies charge ' + outcome.code); return pt.code + ' (already attached)'; }
        var s = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/schema', adminHeader, null);
        if (s.status != 200 || s.body == null) fail('cannot read product type ' + pt.code + ': ' + show(s));
        var ex = s.body;
        // The amendment replaces the whole origination configuration, so everything else is copied from the server.
        var cfg = { productTypeCode: pt.code, scorecardId: cur.scorecardId, assessmentMethod: cur.assessmentMethod, routingMethod: cur.routingMethod, charges: withCharge(cur.charges) };
        if (cur.documentChecklistId != null) cfg.documentChecklistId = cur.documentChecklistId;
        if (cur.templates != null && cur.templates.length > 0) cfg.templates = cur.templates;
        var body = {
          productType: { id: ex.id, code: ex.code, label: ex.label, description: ex.description, icon: ex.icon, category: ex.category, customerType: ex.customerType,
                         workflowKey: ex.workflowKey, displayOrder: ex.displayOrder, active: true },
          config: cfg
        };
        note('product type ' + pt.code + ': adding charge ' + outcome.code + ' to its ' + (cur.charges != null ? cur.charges.length : 0) + ' configured charge(s) (amendment)');
        var send = function() { return api('PUT', '/v1/product-types/' + ex.id, adminHeader, body); };
        governed('attach charge ' + outcome.code + ' to product type ' + pt.code, send(), send, ['PRODUCT_TYPE'], [pt.code, ex.id]);
        var chk = typeConfigOf(pt);
        if (!hasCharge(chk.charges)) fail('product type ' + pt.code + ' amendment was committed but its configuration does not list charge ' + outcome.code);
        return pt.code + ' (attached)';
      }
      """
    * def attached = []
    * eval for (var i = 0; i < attachTypes.length; i++) attached.push(attachToType(attachTypes[i]))

    # ── 6. ATTACH as a sub-product override (TYPE:SUBPRODUCT) ────────────────────────────────
    * def attachToSub =
      """
      function(pair) {
        var kv = pair.split(':');
        if (kv.length != 2 || kv[0].trim() == '' || kv[1].trim() == '') fail('attachToSubProducts entry "' + pair + '" must look like PRODUCT_TYPE:SUB_PRODUCT_CODE');
        var pt = resolveProductType(kv[0].trim());
        var subRaw = kv[1].trim();
        var lp = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products', adminHeader, null);
        if (lp.status != 200 || lp.body == null) fail('cannot list the sub-products of ' + pt.code + ': ' + show(lp));
        var sub = null; var opts = [];
        for (var i = 0; i < lp.body.length; i++) { var p = lp.body[i]; opts.push(p.productCode + ' = ' + p.productDescription); if (eq(p.productCode, subRaw) || eq(p.productDescription, subRaw)) sub = '' + p.productCode; }
        if (sub == null) fail('sub-product "' + subRaw + '" is not linked to product type ' + pt.code + '. Use one of: ' + (opts.length > 0 ? opts.join(', ') : '(none linked yet)'));
        var typeCfg = typeConfigOf(pt);
        var cur = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, null);
        var curBody = (cur.status == 200 && cur.body != null) ? cur.body : {};
        if (hasCharge(curBody.charges)) { note('sub-product ' + pt.code + '/' + sub + ' already levies charge ' + outcome.code); return pt.code + '/' + sub + ' (already attached)'; }
        var cfg = { productTypeCode: pt.code, productCode: sub, charges: withCharge(curBody.charges),
                    scorecardId: curBody.scorecardId != null ? curBody.scorecardId : typeCfg.scorecardId,
                    assessmentMethod: curBody.assessmentMethod != null ? curBody.assessmentMethod : typeCfg.assessmentMethod,
                    routingMethod: curBody.routingMethod != null ? curBody.routingMethod : typeCfg.routingMethod, active: true };
        if (curBody.documentChecklistId != null) cfg.documentChecklistId = curBody.documentChecklistId;
        var send = function() { return api('PUT', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, cfg); };
        governed('attach charge ' + outcome.code + ' to sub-product ' + pt.code + '/' + sub, send(), send, ['PRODUCT_TYPE', 'PRODUCT_CONFIG', 'PRODUCT_LINK'], [pt.code, sub]);
        var chk = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, null);
        if (!(chk.status == 200 && chk.body != null && hasCharge(chk.body.charges))) fail('sub-product ' + pt.code + '/' + sub + ' config was committed but does not list charge ' + outcome.code);
        return pt.code + '/' + sub + ' (attached)';
      }
      """
    * eval for (var i = 0; i < attachSubs.length; i++) attached.push(attachToSub(attachSubs[i]))

    * note('INCIDENT CHARGE COMPLETE')
    * print rowTag, chargeSummary
    * print rowTag, 'attached to:', (attached.length > 0 ? attached.join(', ') : '(nothing - attachToProductTypes and attachToSubProducts are blank)')
    * if (ckHeader() != null) logout(ckHeader())
    * logout(adminHeader)

