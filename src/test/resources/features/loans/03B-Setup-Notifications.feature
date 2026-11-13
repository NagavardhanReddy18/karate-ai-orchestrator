@config-setup @notification-setup @data-driven
Feature: Excel-driven notification setup — Configuration > Notifications > Message Templates and Notification Rules, driven from Notification-Automation.xlsx

  # ── WHAT THIS DOES ───────────────────────────────────────────────────────────────────────────
  # Reads testdata/Notification-Automation.xlsx and, for every row with run=Y, makes the server hold
  # exactly what the row describes. Sheet Message_Templates runs first (New Template: name, format
  # SMS | EMAIL, language, subject, body, content type, active), then sheet Notification_Rules
  # (Add Rule: name, event code, conditions, channels, recipients, one template per channel, active),
  # so a rule can name a template created by the same workbook.
  #
  # Names are resolved against what the screens offer: event codes from LO_NOTIF_TRIGGER, channels
  # from NOTIF_CHANNEL, party roles from LO_PARTY_ROLE, roles from the role definitions, users from
  # the user list, templates by name or TPL code. An unknown value fails the row and lists the options.
  # A template (name + format) or rule (name) that already exists is compared with the sheet:
  # identical = nothing to do, different = an amendment is requested (PUT). Every write is governed
  # (202 + ChangeRequest with SUPERVISOR_APPROVAL severity), approved by a checker that is not the
  # maker, then committed here. The TPL-NNN template code is assigned by the server.
  #
  # ── RUN ──────────────────────────────────────────────────────────────────────────────────────
  #   cd beyond-lo-tests && mvn test -Dkarate.env=dev -Dkarate.tags="@notification-setup"
  # KarateTestRunner.configSetup() runs it last (all setup features carry @config-setup).

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Notification-Automation.xlsx')
    * def enabled = function(x){ return x.run && x.run.toString().toUpperCase() == 'Y' }
    * def tag = function(kind) { return function(x) { x._kind = kind; return x; } }
    * def templateRows = karate.map(karate.filter(ExcelDataLoader.load(excelPath, 'Message_Templates'), enabled), tag('TEMPLATE'))
    * def ruleRows = karate.map(karate.filter(ExcelDataLoader.load(excelPath, 'Notification_Rules'), enabled), tag('RULE'))

  Scenario: Run Message Template Setup for all enabled Excel rows
    * print '======================================================'
    * print 'STARTING MESSAGE TEMPLATE SETUP EXECUTION'
    * print 'Total Enabled Template Rows:', templateRows.length
    * print '======================================================'
    * if (templateRows.length > 0) karate.call('classpath:features/loans/03B-Setup-Notifications.feature@executeRow', templateRows)

  Scenario: Run Notification Rule Setup for all enabled Excel rows
    * print '======================================================'
    * print 'STARTING NOTIFICATION RULE SETUP EXECUTION'
    * print 'Total Enabled Rule Rows:', ruleRows.length
    * print '======================================================'
    * if (ruleRows.length > 0) karate.call('classpath:features/loans/03B-Setup-Notifications.feature@executeRow', ruleRows)

  @ignore @executeRow
  Scenario: Execute Single Template or Rule Row
    * def td = typeof __arg !== 'undefined' ? __arg : {}
    * def kind = td._kind == 'RULE' ? 'RULE' : 'TEMPLATE'
    * url baseUrl
    * configure retry = { count: 24, interval: 5000 }

    # ── small helpers ─────────────────────────────────────────────────────────────────────────
    * def strVal = function(val, defVal) { return (val != null && val.toString().trim() != '') ? val.toString().trim() : defVal }
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def boolVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; return isTrue(s); }
    * def splitList = function(val, sep) { var out = []; var s = strVal(val, ''); if (s == '') return out; var parts = s.split(sep == null ? ',' : sep); for (var i = 0; i < parts.length; i++) { if (parts[i].trim() != '') out.push(parts[i].trim()); } return out; }
    * def rowTag = '[NOTIFICATION-SETUP ' + strVal(kind == 'RULE' ? td.ruleId : td.templateId, 'row') + ']'
    * def note = function(m) { karate.log(rowTag, m); }
    * def fail = function(m) { var msg = rowTag + ' ' + m; karate.log(msg); karate.fail(msg); throw new Error(msg); }
    * def req = function(col, why) { var v = strVal(td[col], null); if (v == null) fail('column "' + col + '" is blank but is required ' + why); return v; }
    * def eq = function(a, b) { return a != null && b != null && ('' + a).trim().toLowerCase() == ('' + b).trim().toLowerCase(); }
    * def parseJson =
      """
      function(col, required) {
        var s = strVal(td[col], null);
        if (s == null) { if (required) fail('column "' + col + '" is blank but is required (a JSON list)'); return []; }
        var v;
        try { v = JSON.parse(s); } catch (e) { fail('column "' + col + '" is not valid JSON: ' + e); }
        if (v == null) return [];
        if (!Array.isArray(v)) v = [v];
        return v;
      }
      """
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
    * def MODULE = 'LO'

    # ── 0. ACCOUNTS ───────────────────────────────────────────────────────────────────────────
    * def excelAdminUser = strVal(td.adminUsername, null)
    * def excelAdminPass = strVal(td.adminPassword, defaultAdminPassword)
    * def excelCheckerUser = strVal(td.checkerUsername, null)
    * def excelCheckerPass = strVal(td.checkerPassword, defaultAdminPassword)
    * def canManage = function(header) { var r = api('GET', '/v1/notification/templates?module=' + MODULE, header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canManage(h)) return { user: excelAdminUser, header: h, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot read notification templates - falling back to ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        if (excelAdminUser != defaultAdminUsername) {
          var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
          if (h2 != null && canManage(h2)) return { user: defaultAdminUsername, header: h2, source: 'karate-config' };
          if (h2 != null) logout(h2);
          tried.push(defaultAdminUsername);
        }
        fail('no admin account can manage notifications. Tried: ' + tried.join(', ') + '. Fill adminUsername/adminPassword in the sheet, or fix roleCandidates.admin in karate-config.js.');
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

    # ── CHANGE-REQUEST HANDLING (maker-checker), same contract as the other setup features ───
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
              var a = api('POST', '/v1/change-requests/' + id + '/approve', csHeader, { comment: 'Approved by Excel notification setup (' + what + ')' });
              if (a.status == 401) { relogCheckerIfNeeded(); a = api('POST', '/v1/change-requests/' + id + '/approve', ckHeader(), { comment: 'Approved by Excel notification setup (' + what + ')' }); }
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
          var kindHit = false;
          for (var p = 0; p < eventHints.length; p++) { if (ev.indexOf(eventHints[p]) >= 0) kindHit = true; }
          if (!kindHit) continue;
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
      function(what, res, retryFn, eventHints, keywords) {
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
        var text = ('' + (res.body == null ? '' : (typeof res.body == 'string' ? res.body : JSON.stringify(res.body)))).toLowerCase();
        if (res.status == 409 && text.indexOf('pending') >= 0 && retryFn != null) {
          note(what + ': ' + text.substring(0, 300));
          if (!resolvePending(eventHints, keywords, what)) fail(what + ': a change request is already pending and could not be resolved. ' + show(res));
          return governed(what, retryFn(), null, eventHints, keywords);
        }
        fail(what + ' -> ' + show(res));
      }
      """

    # ── TEMPLATES on the server (used by both kinds of row) ──────────────────────────────────
    * def listTemplates =
      """
      function() {
        var r = api('GET', '/v1/notification/templates?module=' + MODULE, adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list message templates: ' + show(r));
        return r.body;
      }
      """
    * def findTemplate = function(list, ref, format) { for (var i = 0; i < list.length; i++) { var t = list[i]; if (format != null && !eq(t.format, format)) continue; if (eq(t.templateCode, ref) || eq(t.name, ref)) return t; } return null; }

    # ═════════════════════════════════════════════════════════════════════════════════════════
    # A. MESSAGE TEMPLATE ROW (New Template)
    # ═════════════════════════════════════════════════════════════════════════════════════════
    * def templateOutcome =
      """
      (function() {
        if (kind != 'TEMPLATE') return null;
        var name = req('templateName', 'on every template row (Template Name)');
        var format = req('format', 'on every template row (SMS | EMAIL)').toUpperCase();
        if (format != 'SMS' && format != 'EMAIL') fail('format must be SMS or EMAIL, not ' + format);
        var language = strVal(td.language, 'EN').toUpperCase();
        var subject = strVal(td.subject, null);
        var body = req('body', 'on every template row (Message Body)');
        var contentType = strVal(td.contentType, 'HTML').toUpperCase();
        if (format == 'EMAIL' && subject == null) fail('subject is required for an EMAIL template');
        if (format == 'SMS' && subject != null) { note('subject is ignored for an SMS template (the server derives the format from the subject)'); subject = null; }
        if (contentType != 'HTML' && contentType != 'PLAIN') fail('contentType must be HTML or PLAIN, not ' + contentType);
        var active = boolVal(td.active, true);
        karate.log(rowTag, 'Processing template:', strVal(td.description, name), '|', name, '|', format, language);
        var desired = { module: MODULE, name: name, format: format, subject: subject, body: body, languageCode: language, active: active, contentType: format == 'EMAIL' ? contentType : 'HTML' };
        var same = function(t) { return eq(t.name, desired.name) && eq(t.format, desired.format) && ('' + (t.subject == null ? '' : t.subject)) == ('' + (desired.subject == null ? '' : desired.subject)) && ('' + t.body).replace(/\r\n/g, '\n') == ('' + desired.body).replace(/\r\n/g, '\n') && eq(t.languageCode, desired.languageCode) && (t.active != false) == desired.active && (format != 'EMAIL' || eq(t.contentType, desired.contentType)); };
        var existing = findTemplate(listTemplates(), name, format);
        var hints = ['NOTIFICATION_TEMPLATE', 'NOTIF'];
        if (existing != null) {
          if (same(existing)) { note('template ' + existing.templateCode + ' "' + existing.name + '" already matches the sheet - nothing to do'); return { code: existing.templateCode, id: existing.id, action: 'unchanged' }; }
          note('template ' + existing.templateCode + ' "' + existing.name + '" differs from the sheet - requesting an amendment');
          var body2 = karate.merge(desired, { id: existing.id, templateCode: existing.templateCode });
          var send = function() { return api('PUT', '/v1/notification/templates/' + existing.id, adminHeader, body2); };
          governed('amend template ' + existing.templateCode + ' (' + name + ')', send(), send, hints, [name, existing.templateCode]);
          return { code: existing.templateCode, id: existing.id, action: 'amended' };
        }
        var create = function() { return api('POST', '/v1/notification/templates?module=' + MODULE, adminHeader, desired); };
        governed('create template (' + name + ', ' + format + ')', create(), create, hints, [name]);
        var made = null;
        for (var i = 0; i < 30 && made == null; i++) { made = findTemplate(listTemplates(), name, format); if (made == null) java.lang.Thread.sleep(1000); }
        if (made == null) fail('the change request for template "' + name + '" was committed but no ' + format + ' template with that name is listed afterwards');
        return { code: made.templateCode, id: made.id, action: 'created' };
      })()
      """
    * def templateSummary =
      """
      (function() {
        if (kind != 'TEMPLATE') return null;
        var g = api('GET', '/v1/notification/templates/' + templateOutcome.id, adminHeader, null);
        if (g.status != 200 || g.body == null) fail('VERIFY: template ' + templateOutcome.code + ' cannot be read back: ' + show(g));
        var t = g.body;
        return 'template ' + t.templateCode + ' (id ' + t.id + ') ' + templateOutcome.action + ': "' + t.name + '" ' + t.format + ' ' + t.languageCode + (t.subject != null ? ' | subject "' + t.subject + '"' : '') + ' | active=' + t.active + ' | body ' + ('' + t.body).length + ' chars';
      })()
      """

    # ═════════════════════════════════════════════════════════════════════════════════════════
    # B. NOTIFICATION RULE ROW (Add Notification Rule)
    # ═════════════════════════════════════════════════════════════════════════════════════════
    * def options =
      """
      function(group) {
        var r = api('GET', '/v1/generic-codes/' + group + '/options?locale=en', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot read the options of generic-code group ' + group + ': ' + show(r));
        return r.body;
      }
      """
    * def pick =
      """
      function(list, raw, what) {
        var opts = [];
        for (var i = 0; i < list.length; i++) { var o = list[i]; opts.push(o.valueCode + ' = ' + o.label); if (eq(o.valueCode, raw) || eq(o.label, raw)) return '' + o.valueCode; }
        fail(what + ' "' + raw + '" is not one the screen offers. Use one of: ' + opts.join(', '));
      }
      """
    * def ruleOutcome =
      """
      (function() {
        if (kind != 'RULE') return null;
        var ruleName = req('ruleName', 'on every rule row (Rule Name)');
        karate.log(rowTag, 'Processing rule:', strVal(td.description, ruleName), '|', ruleName);
        // event code
        var eventCode = pick(options('LO_NOTIF_TRIGGER'), req('eventCode', 'on every rule row (Event Code)'), 'eventCode');
        // conditions
        var rawCondStr = strVal(td.conditions, null);
        var parsedCond = null;
        if (rawCondStr != null) {
          try { parsedCond = JSON.parse(rawCondStr); } catch (e) { fail('column "conditions" is not valid JSON: ' + e + ' | value: ' + rawCondStr); }
        }
        var resolveOp = function(m, def) {
          if (m == null || ('' + m).trim() == '') return def != null ? def : 'AND';
          var s = ('' + m).trim().toUpperCase();
          if (s == 'ANY' || s == 'OR' || s == 'ANY-OR' || s == 'ANY_OR' || s == 'ANY·OR') return 'OR';
          if (s == 'ALL' || s == 'AND' || s == 'ALL-AND' || s == 'ALL_AND' || s == 'ALL·AND') return 'AND';
          return def != null ? def : 'AND';
        };
        var normalizeOp = function(o) {
          if (o == null) return null;
          var s = ('' + o).trim().toUpperCase();
          if (s == 'IS' || s == '=' || s == '==' || s == 'EQUALS' || s == 'EQUAL') return 'EQ';
          if (s == 'IS NOT' || s == '!=' || s == '<>' || s == 'NOT EQUALS' || s == 'NOT_EQUAL' || s == 'NOT EQUAL TO') return 'NEQ';
          if (s == '>' || s == 'GREATER THAN' || s == 'GREATER_THAN' || s == 'MORE THAN') return 'GT';
          if (s == '>=' || s == 'GREATER THAN OR EQUAL' || s == 'GREATER_THAN_OR_EQUAL' || s == 'GREATER THAN OR EQUALS' || s == 'AT LEAST') return 'GTE';
          if (s == '<' || s == 'LESS THAN' || s == 'LESS_THAN') return 'LT';
          if (s == '<=' || s == 'LESS THAN OR EQUAL' || s == 'LESS_THAN_OR_EQUAL' || s == 'LESS THAN OR EQUALS' || s == 'AT MOST') return 'LTE';
          if (s == 'ONE OF' || s == 'IN' || s == 'IS IN' || s == 'IS ONE OF') return 'IN';
          if (s == 'NOT ONE OF' || s == 'NOT IN' || s == 'IS NOT IN' || s == 'NOT IN LIST') return 'NOT_IN';
          if (s == 'IS EMPTY' || s == 'EMPTY' || s == 'BLANK') return 'IS_EMPTY';
          if (s == 'CONTAINS' || s == 'CONTAIN') return 'CONTAINS';
          if (s == 'BETWEEN') return 'BETWEEN';
          return s;
        };
        var cfgR = api('GET', '/v1/notification/modules/' + MODULE + '/config', adminHeader, null);
        var cfg = (cfgR.status == 200 && cfgR.body != null) ? cfgR.body : { variables: [], recipientTypes: [], maxConditions: 20 };
        var totalCondCount = 0;
        var parseNode = function(node, path) {
          if (node == null) return null;
          var groupKids = node.conditions != null ? node.conditions : (node.children != null ? node.children : node.rules);
          if (groupKids != null && Array.isArray(groupKids)) {
            var gOp = resolveOp(node.match != null ? node.match : (node.matchMode != null ? node.matchMode : (node.op != null ? node.op : td.matchMode)), 'AND');
            var kids = [];
            for (var i = 0; i < groupKids.length; i++) {
              var p = parseNode(groupKids[i], path + '[' + i + ']');
              if (p != null) kids.push(p);
            }
            return kids.length == 0 ? null : { op: gOp, children: kids };
          }
          totalCondCount++;
          var variable = strVal(node.variable != null ? node.variable : node.field, null);
          var operator = normalizeOp(node.operator != null ? node.operator : node.op);
          if (variable == null || operator == null || (node.value === undefined && operator != 'IS_EMPTY')) fail(path + ' needs variable, operator and value');
          var v = null; var names = [];
          var cleanVar = function(s) { return s == null ? '' : ('' + s).toLowerCase().replace(/[^a-z0-9]/g, ''); };
          var targetClean = cleanVar(variable);
          for (var j = 0; j < cfg.variables.length; j++) {
            var cv = cfg.variables[j];
            names.push(cv.label + ' [' + cv.name + ']');
            if (eq(cv.name, variable) || eq(cv.label, variable)) v = cv;
            else if (cleanVar(cv.name) == targetClean || cleanVar(cv.label) == targetClean) v = cv;
            else if (targetClean == 'product' && cv.name == 'product_type') v = cv;
            else if (targetClean == 'customer' && cv.name == 'customer_type') v = cv;
            else if (targetClean == 'facility' && cv.name == 'facility_type') v = cv;
            else if (targetClean == 'subproduct' && cv.name == 'sub_product_type') v = cv;
          }
          if (v == null) fail(path + ' variable "' + variable + '" is not a condition variable of module ' + MODULE + '. Use one of: ' + names.join(', '));
          if (v.operators.indexOf(operator) < 0) fail(path + ' operator ' + operator + ' is not allowed for ' + v.name + ' (allowed: ' + v.operators.join(', ') + ')');
          if (operator == 'BETWEEN' && node.value2 === undefined) fail(path + ' BETWEEN needs value2');
          return { variable: v.name, operator: operator, value: node.value === undefined ? null : node.value, value2: node.value2 === undefined ? null : node.value2 };
        };
        var conditionTree = null;
        if (parsedCond != null) {
          if (Array.isArray(parsedCond)) {
            var topOp = resolveOp(td.matchMode, 'AND');
            var topKids = [];
            for (var k = 0; k < parsedCond.length; k++) {
              var pk = parseNode(parsedCond[k], 'conditions[' + k + ']');
              if (pk != null) topKids.push(pk);
            }
            conditionTree = topKids.length == 0 ? null : { op: topOp, children: topKids };
          } else {
            var pObj = parseNode(parsedCond, 'conditions');
            if (pObj != null) {
              conditionTree = pObj.children != null ? pObj : { op: resolveOp(td.matchMode, 'AND'), children: [pObj] };
            }
          }
        }
        if (totalCondCount > cfg.maxConditions) fail('conditions lists ' + totalCondCount + ' conditions; the module allows at most ' + cfg.maxConditions);
        // channels
        var chOpts = options('NOTIF_CHANNEL');
        var chRaw = splitList(td.channels);
        if (chRaw.length == 0) fail('channels is required on every rule row (SMS, EMAIL, IN_APP, PUSH)');
        var channels = [];
        for (var k = 0; k < chRaw.length; k++) { var cc = pick(chOpts, chRaw[k], 'channel'); if (channels.indexOf(cc) < 0) channels.push(cc); }
        // recipients
        var rawRec = parseJson('recipients', true);
        if (rawRec.length == 0) fail('recipients must list at least one recipient');
        var recipients = [];
        var partyRoles = null; var roleDefs = null; var users = null;
        for (var r = 0; r < rawRec.length; r++) {
          var rec = rawRec[r];
          var type = strVal(rec.type != null ? rec.type : rec.recipientType, null) == null ? null : strVal(rec.type != null ? rec.type : rec.recipientType, null).toUpperCase();
          var param = strVal(rec.param != null ? rec.param : rec.recipientParam, null);
          var known = []; var okType = false;
          for (var t = 0; t < cfg.recipientTypes.length; t++) { known.push(cfg.recipientTypes[t].type); if (cfg.recipientTypes[t].type == type) okType = true; }
          if (type == 'RM') okType = true;
          if (!okType) fail('recipients[' + r + '] type "' + type + '" is not a recipient type of module ' + MODULE + '. Use one of: ' + known.join(', '));
          if (type == 'PARTY') {
            if (partyRoles == null) partyRoles = options('LO_PARTY_ROLE');
            param = pick(partyRoles, param == null ? '' : param, 'recipients[' + r + '] party role');
            if (channels.indexOf('IN_APP') >= 0 || channels.indexOf('PUSH') >= 0) fail('In-App and Push notifications cannot be sent to the applicant (Party). Remove the PARTY recipient or the IN_APP / PUSH channel.');
          } else if (type == 'ROLE') {
            if (roleDefs == null) { var rr = api('GET', '/v1/master-data/role-definitions?size=500', adminHeader, null); if (rr.status != 200 || rr.body == null) fail('cannot list role definitions: ' + show(rr)); roleDefs = rr.body.content != null ? rr.body.content : rr.body; }
            var found = null; var ropts = [];
            for (var q = 0; q < roleDefs.length; q++) { var role = roleDefs[q]; if (role.active == false) continue; ropts.push(role.roleCode + ' = ' + role.roleName); if (eq(role.roleCode, param) || eq(role.roleName, param) || eq('ROLE_' + role.roleCode, param)) found = '' + role.roleCode; }
            if (found == null) fail('recipients[' + r + '] role "' + param + '" is not an active role. Roles: ' + ropts.join(', '));
            param = found;
          } else if (type == 'USER') {
            if (users == null) { var ur = api('GET', '/v1/users', adminHeader, null); if (ur.status != 200 || ur.body == null) fail('cannot list users: ' + show(ur)); users = ur.body.content != null ? ur.body.content : ur.body; }
            var fu = null; var uopts = [];
            for (var w = 0; w < users.length; w++) { uopts.push(users[w].username); if (eq(users[w].username, param) || eq(users[w].fullName, param)) fu = '' + users[w].username; }
            if (fu == null) fail('recipients[' + r + '] user "' + param + '" is not a user. Users: ' + uopts.join(', '));
            param = fu;
          } else if (type == 'RM') {
            param = null;
          } else if (param == null) {
            fail('recipients[' + r + '] (' + type + ') needs a param');
          }
          var dup = false;
          for (var d = 0; d < recipients.length; d++) { if (recipients[d].type == type && ('' + recipients[d].param) == ('' + param)) dup = true; }
          if (dup) fail('recipients lists ' + type + ' ' + param + ' twice - each recipient can only be added once');
          recipients.push({ type: type, param: param });
        }
        // templates per channel
        var all = listTemplates();
        var pairs = splitList(td.channelTemplates, ';');
        var chTpl = {};
        for (var p = 0; p < pairs.length; p++) {
          var kv = pairs[p].split('=');
          if (kv.length != 2 || kv[0].trim() == '' || kv[1].trim() == '') fail('channelTemplates entry "' + pairs[p] + '" must look like CHANNEL=Template Name (separate channels with ;)');
          chTpl[pick(chOpts, kv[0].trim(), 'channelTemplates channel')] = kv[1].trim();
        }
        var tplCodes = {};
        for (var x = 0; x < channels.length; x++) {
          var ch = channels[x];
          if (chTpl[ch] == null) fail('channelTemplates has no template for channel ' + ch + ' (every channel needs one: "SMS=Name; EMAIL=Name")');
          var wantFormat = ch == 'EMAIL' ? 'EMAIL' : 'SMS';
          var tpl = findTemplate(all, chTpl[ch], wantFormat);
          if (tpl == null) {
            var names = []; for (var y = 0; y < all.length; y++) { if (eq(all[y].format, wantFormat)) names.push(all[y].templateCode + ' = ' + all[y].name); }
            fail('template "' + chTpl[ch] + '" for channel ' + ch + ' is not a ' + wantFormat + ' template on this server. Create it in the Message_Templates sheet, or use one of: ' + names.join(', '));
          }
          if (tpl.active == false) note('WARNING: template ' + tpl.templateCode + ' for channel ' + ch + ' is INACTIVE');
          tplCodes[ch] = '' + tpl.templateCode;
        }
        var attachment = null;
        var attRaw = strVal(td.attachmentTemplate, null);
        if (attRaw != null) { var at = findTemplate(all, attRaw, null); if (at == null) fail('attachmentTemplate "' + attRaw + '" is not a template on this server'); attachment = '' + at.templateCode; }
        var active = boolVal(td.active, true);
        var targets = [];
        for (var a = 0; a < channels.length; a++) {
          for (var b = 0; b < recipients.length; b++) {
            targets.push({ channel: channels[a], recipientType: recipients[b].type, recipientParam: recipients[b].param, templateCode: tplCodes[channels[a]], attachmentTemplateCode: (channels[a] == 'EMAIL' ? attachment : null) });
          }
        }
        var desired = { ruleName: ruleName, eventCode: eventCode, conditionTree: conditionTree, active: active, targets: targets };
        var norm = function(rule) {
          var ts = [];
          var tg = rule.targets != null ? rule.targets : [];
          for (var i = 0; i < tg.length; i++) { var t = tg[i]; ts.push(t.channel + '|' + t.recipientType + '|' + (t.recipientParam == null ? '' : t.recipientParam) + '|' + t.templateCode + '|' + (t.attachmentTemplateCode == null ? '' : t.attachmentTemplateCode)); }
          ts.sort();
          // The server echoes the tree with every field present (op/children null on leaves, group flags), so
          // compare a canonical rendering: leaves as variable|operator|value|value2, groups as op(child,child).
          var canon = function(n) {
            if (n == null) return '';
            if (n.children != null && n.children.length > 0) { var cs = []; for (var c = 0; c < n.children.length; c++) cs.push(canon(n.children[c])); cs.sort(); return ('' + n.op).toUpperCase() + '(' + cs.join(',') + ')'; }
            if (n.variable == null) return '';
            return n.variable + '|' + ('' + n.operator).toUpperCase() + '|' + JSON.stringify(n.value === undefined ? null : n.value) + '|' + JSON.stringify(n.value2 === undefined ? null : n.value2);
          };
          return ('' + rule.eventCode) + '#' + (rule.active != false) + '#' + canon(rule.conditionTree) + '#' + ts.join(',');
        };
        var lr = api('GET', '/v1/notification/rules?module=' + MODULE, adminHeader, null);
        if (lr.status != 200 || lr.body == null) fail('cannot list notification rules: ' + show(lr));
        var existing = null;
        for (var e = 0; e < lr.body.length; e++) { if (eq(lr.body[e].ruleName, ruleName)) existing = lr.body[e]; }
        var hints = ['NOTIFICATION_RULE', 'NOTIF'];
        if (existing != null) {
          if (norm(existing) == norm(desired)) { note('rule ' + existing.id + ' "' + ruleName + '" already matches the sheet - nothing to do'); return { id: existing.id, action: 'unchanged', desired: desired, norm: norm }; }
          note('rule ' + existing.id + ' "' + ruleName + '" differs from the sheet - requesting an amendment');
          var body2 = karate.merge(desired, { id: existing.id });
          var send = function() { return api('PUT', '/v1/notification/rules/' + existing.id + '?module=' + MODULE, adminHeader, body2); };
          governed('amend rule ' + existing.id + ' (' + ruleName + ')', send(), send, hints, [ruleName, existing.id]);
          return { id: existing.id, action: 'amended', desired: desired, norm: norm };
        }
        var create = function() { return api('POST', '/v1/notification/rules?module=' + MODULE, adminHeader, desired); };
        governed('create rule (' + ruleName + ')', create(), create, hints, [ruleName]);
        var made = null;
        for (var i2 = 0; i2 < 30 && made == null; i2++) {
          var l2 = api('GET', '/v1/notification/rules?module=' + MODULE, adminHeader, null);
          for (var e2 = 0; l2.status == 200 && l2.body != null && e2 < l2.body.length; e2++) { if (eq(l2.body[e2].ruleName, ruleName)) made = l2.body[e2]; }
          if (made == null) java.lang.Thread.sleep(1000);
        }
        if (made == null) fail('the change request for rule "' + ruleName + '" was committed but no rule with that name is listed afterwards');
        return { id: made.id, action: 'created', desired: desired, norm: norm };
      })()
      """
    * def ruleSummary =
      """
      (function() {
        if (kind != 'RULE') return null;
        var g = api('GET', '/v1/notification/rules/' + ruleOutcome.id + '?module=' + MODULE, adminHeader, null);
        if (g.status != 200 || g.body == null) fail('VERIFY: rule ' + ruleOutcome.id + ' cannot be read back: ' + show(g));
        if (ruleOutcome.norm(g.body) != ruleOutcome.norm(ruleOutcome.desired)) fail('VERIFY: rule ' + ruleOutcome.id + ' does not match the sheet after ' + ruleOutcome.action + '. Server: ' + karate.pretty(g.body) + ' Sheet: ' + karate.pretty(ruleOutcome.desired));
        var parts = [];
        for (var i = 0; i < g.body.targets.length; i++) { var t = g.body.targets[i]; parts.push(t.channel + ' -> ' + t.recipientType + (t.recipientParam != null ? ' ' + t.recipientParam : '') + ' [' + t.templateCode + ']'); }
        return 'rule ' + g.body.id + ' "' + g.body.ruleName + '" ' + ruleOutcome.action + ': on ' + g.body.eventCode + (g.body.conditionTree != null ? ' when ' + JSON.stringify(g.body.conditionTree) : ' (every event)') + ' | active=' + g.body.active + ' | ' + parts.join(' | ');
      })()
      """

    * def summary = kind == 'RULE' ? ruleSummary : templateSummary
    * note((kind == 'RULE' ? 'NOTIFICATION RULE' : 'MESSAGE TEMPLATE') + ' COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(adminHeader)

