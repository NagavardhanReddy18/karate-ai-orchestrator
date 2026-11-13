@config-setup @document-checklist-setup @data-driven
Feature: Excel-driven document-checklist setup — Document Categories, Document Configs, Document Checklists and their product-type attachment, driven from Document-Checklist-Automation.xlsx

  # ── WHAT THIS DOES ───────────────────────────────────────────────────────────────────────────
  # Reads testdata/Document-Checklist-Automation.xlsx (sheet Document_Checklists) and, for every row
  # with run=Y, makes the server hold exactly the checklist the row describes and attaches it where the
  # row says. One row covers the four screens an admin would otherwise visit in order:
  #
  #   Configuration > Document Categories     categories        (DOCCAT generic-code values)
  #   Configuration > Document Configs        documentTypes     (document types under a category)
  #   Configuration > Document Checklists     checklistName, active, sections (the "Configurations (Rows)")
  #   Configuration > Product Types > config  attachToProductTypes, attachToSubProducts
  #
  # sections is the form's row list: one object per row with phase (DOC_PHASE code: APPLICATION | SETUP |
  # OFFER_ACCEPT; blank = every phase), category, noOfDocsReq, noOfCopies and docTypes — the document
  # types the row ticks, each with mandatory / primary / coApplicant / guarantor / signatureRequired /
  # original flags. A category or type the sections name but the server lacks is created first (when
  # createMissingCategories / createMissingDocTypes allow it, blank = true) or the row fails and lists what
  # exists. "Workflow level" on the screen IS the phase of each section: the wizard shows APPLICATION
  # rows, loan setup shows SETUP rows and accept-offer shows OFFER_ACCEPT rows. There is no separate
  # workflow attachment on the server; the product type (and optionally a sub-product override) is the
  # only attachment point.
  #
  # Every write is governed (202 + ChangeRequest with SUPERVISOR_APPROVAL severity), so each request is
  # approved by a checker that is not the maker and then committed here. A checklist that already exists
  # with the same name is compared section by section: identical = nothing to do, different = an
  # amendment (PUT) is requested, approved and committed. Attaching is STRICT: a product type named in
  # attachToProductTypes must already exist — create it in Product-Configuration-Automation.xlsx first.
  #
  # ── RUN ──────────────────────────────────────────────────────────────────────────────────────
  #   cd beyond-lo-tests && mvn test -Dkarate.env=dev -Dkarate.tags="@document-checklist-setup"
  # KarateTestRunner.configSetup() runs it after 00-Setup-Configurations.feature and
  # 01-Setup-Approval-Limits.feature (all carry @config-setup), so the product types exist first.

  Background:
    * def ExcelDataLoader = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
    * def excelPath = karate.toAbsolutePath('classpath:features/loans/testdata/Document-Checklist-Automation.xlsx')
    * def rawData = ExcelDataLoader.load(excelPath, 'Document_Checklists')
    * def rows = karate.filter(rawData, function(x){ return x.run && x.run.toString().toUpperCase() == 'Y' })
    * def rowCount = rows.length

  Scenario: Run Document Checklist Setup for all enabled Excel rows
    * print '======================================================'
    * print 'STARTING DOCUMENT CHECKLIST SETUP EXECUTION'
    * print 'Total Enabled Document Checklist Rows:', rowCount
    * print '======================================================'
    * if (rowCount > 0) karate.call('classpath:features/loans/03-Setup-Document-Checklists.feature@executeRow', rows)

  @ignore @executeRow
  Scenario: Execute Single Document Checklist Row
    * def td = typeof __arg !== 'undefined' ? __arg : {}
    * url baseUrl
    * configure retry = { count: 24, interval: 5000 }

    # ── small helpers ─────────────────────────────────────────────────────────────────────────
    * def strVal = function(val, defVal) { return (val != null && val.toString().trim() != '') ? val.toString().trim() : defVal }
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def boolVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; return isTrue(s); }
    * def numVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; var n = parseFloat(('' + s).replace(/,/g, '')); return isNaN(n) ? defVal : n; }
    * def splitList = function(val) { var out = []; var s = strVal(val, ''); if (s == '') return out; var parts = s.split(','); for (var i = 0; i < parts.length; i++) { if (parts[i].trim() != '') out.push(parts[i].trim()); } return out; }
    * def rowTag = '[DOC-CHECKLIST-SETUP ' + strVal(td.checklistId, 'row') + ']'
    * def note = function(m) { karate.log(rowTag, m); }
    # karate.fail() only marks the step failed; the throw is what actually stops the JS function.
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

    # ── inputs from the sheet (the New Checklist form and the screens around it) ──────────────
    * def rowDescription = strVal(td.description, strVal(td.checklistId, 'document checklist'))
    * def checklistName = req('checklistName', 'on every row (Checklist Name on the New Checklist form)')
    * def checklistActive = boolVal(td.active, true)
    * def rawSections = parseJson('sections', true)
    * if (rawSections.length == 0) fail('sections must list at least one row of the checklist (phase, category, docTypes)')
    * def rawCategories = parseJson('categories', false)
    * def rawDocTypes = parseJson('documentTypes', false)
    * def createMissingCategories = boolVal(td.createMissingCategories, true)
    * def createMissingDocTypes = boolVal(td.createMissingDocTypes, true)
    * def attachTypes = splitList(td.attachToProductTypes)
    * def attachSubs = splitList(td.attachToSubProducts)
    * def flag = function(o, k) { return o != null && o[k] != null && isTrue(o[k]); }
    # Sections as the form would submit them (docTypes keyed by code, flags normalised to booleans)
    * def sections =
      """
      (function() {
        var out = [];
        for (var i = 0; i < rawSections.length; i++) {
          var s = rawSections[i];
          var cat = strVal(s.category != null ? s.category : s.docCategory, null);
          if (cat == null) fail('sections[' + i + '] has no category');
          var phase = strVal(s.phase != null ? s.phase : s.phaseId, null);
          var types = s.docTypes != null ? s.docTypes : [];
          if (!Array.isArray(types) || types.length == 0) fail('sections[' + i + '] (' + cat + ') lists no docTypes - tick at least one document type of the category');
          var dts = [];
          for (var j = 0; j < types.length; j++) {
            var t = typeof types[j] == 'string' ? { code: types[j] } : types[j];
            var code = strVal(t.code != null ? t.code : t.documentType, null);
            if (code == null) fail('sections[' + i + '].docTypes[' + j + '] has no code');
            dts.push({ code: code, primary: flag(t, 'primary'), coApplicant: flag(t, 'coApplicant'), guarantor: flag(t, 'guarantor'),
                       mandatory: flag(t, 'mandatory'), signatureRequired: flag(t, 'signatureRequired'), original: flag(t, 'original') });
          }
          var reqd = numVal(s.noOfDocsReq, null);
          if (reqd == null) { reqd = 0; for (var m = 0; m < dts.length; m++) if (dts[m].mandatory) reqd++; }
          if (reqd > dts.length) fail('sections[' + i + '] (' + cat + '): noOfDocsReq ' + reqd + ' exceeds the ' + dts.length + ' document type(s) listed');
          var copies = numVal(s.noOfCopies, 1);
          out.push({ phase: phase, category: cat, noOfDocsReq: reqd, noOfCopies: copies, docTypes: dts });
        }
        var seen = {};
        for (var k = 0; k < out.length; k++) {
          var key = (out[k].phase != null ? out[k].phase.toUpperCase() : '') + ':' + out[k].category.toLowerCase();
          if (seen[key]) fail('sections uses category "' + out[k].category + '" twice in phase ' + (out[k].phase != null ? out[k].phase : '(all)') + ' - each category can only be used once per phase');
          seen[key] = true;
        }
        return out;
      })()
      """
    * print rowTag, 'Processing:', rowDescription, '|', checklistName, '|', sections.length, 'section(s) | attach to:', (attachTypes.length > 0 ? attachTypes.join(', ') : '(none)'), (attachSubs.length > 0 ? '| sub-products: ' + attachSubs.join(', ') : '')

    # ── 0. ACCOUNTS: an admin that manages configuration, a checker that can approve ─────────
    * def excelAdminUser = strVal(td.adminUsername, null)
    * def excelAdminPass = strVal(td.adminPassword, defaultAdminPassword)
    * def excelCheckerUser = strVal(td.checkerUsername, null)
    * def excelCheckerPass = strVal(td.checkerPassword, defaultAdminPassword)
    * def canManage = function(header) { var r = api('GET', '/v1/master-data/document-checklists?size=1', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canManage(h)) return { user: excelAdminUser, header: h, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot read document checklists (needs MENU_CONFIGURATION) - falling back to ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        if (excelAdminUser != defaultAdminUsername) {
          var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
          if (h2 != null && canManage(h2)) return { user: defaultAdminUsername, header: h2, source: 'karate-config' };
          if (h2 != null) logout(h2);
          tried.push(defaultAdminUsername);
        }
        fail('no admin account can manage document checklists (needs MENU_CONFIGURATION). Tried: ' + tried.join(', ') + '. Fill adminUsername/adminPassword in the sheet, or fix roleCandidates.admin in karate-config.js.');
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

    # ── CHANGE-REQUEST HANDLING (maker-checker), same contract as 00 / 01 ─────────────────────
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
              var a = api('POST', '/v1/change-requests/' + id + '/approve', csHeader, { comment: 'Approved by Excel document-checklist setup (' + what + ')' });
              if (a.status == 401) { relogCheckerIfNeeded(); a = api('POST', '/v1/change-requests/' + id + '/approve', ckHeader(), { comment: 'Approved by Excel document-checklist setup (' + what + ')' }); }
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
    # Pending requests that block a write: only those of the same kind (event prefixes) naming this record
    * def resolvePending =
      """
      function(eventPrefixes, keywords, what) {
        var r = api('GET', '/v1/change-requests/all-pending', adminHeader, null);
        if (r.status != 200 || r.body == null) { note(what + ': could not list pending change requests: ' + show(r)); return false; }
        var handled = 0;
        for (var i = 0; i < r.body.length; i++) {
          var cr = r.body[i];
          var ev = '' + cr.eventCode;
          var kind = false;
          for (var p = 0; p < eventPrefixes.length; p++) { if (ev.indexOf(eventPrefixes[p]) == 0) kind = true; }
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
    * def governed =
      """
      function(what, res, retryFn, eventPrefixes, keywords) {
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
        var pendingLike = res.status == 409 && res.body != null && (res.body.code == 'PENDING_CHANGE_EXISTS' || ('' + res.body.error + res.body.detail + res.body.message).toLowerCase().indexOf('pending') >= 0);
        if (pendingLike && retryFn != null) {
          note(what + ': ' + (res.body.detail != null ? res.body.detail : res.body.error));
          if (!resolvePending(eventPrefixes, keywords, what)) fail(what + ': a change request is already pending and could not be resolved. ' + show(res));
          return governed(what, retryFn(), null, eventPrefixes, keywords);
        }
        fail(what + ' -> ' + show(res));
      }
      """

    # ── 1. PHASES the form offers (DOC_PHASE) ─────────────────────────────────────────────────
    * def phaseOptions =
      """
      (function() {
        var r = api('GET', '/v1/generic-codes/DOC_PHASE/options?locale=en', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot read the Phase options (generic-code group DOC_PHASE): ' + show(r));
        return r.body;
      })()
      """
    * def resolvePhase =
      """
      function(p) {
        if (p == null) return null;
        var opts = [];
        for (var i = 0; i < phaseOptions.length; i++) {
          var o = phaseOptions[i];
          opts.push(o.valueCode + ' = ' + o.label);
          if (eq(o.valueCode, p) || eq(o.label, p)) return '' + o.valueCode;
        }
        fail('phase "' + p + '" is not a Phase the New Checklist form offers. Use one of: ' + opts.join(', ') + ' (or leave it blank for every phase)');
      }
      """
    * eval for (var i = 0; i < sections.length; i++) { sections[i].phase = resolvePhase(sections[i].phase); }

    # ── 2. DOCUMENT CATEGORIES (generic-code group DOCCAT): reuse or create ───────────────────
    * def doccat =
      """
      (function() {
        var r = api('GET', '/v1/master-data/generic-code-groups?search=DOCCAT&size=50', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot read the generic-code groups to find DOCCAT: ' + show(r));
        var list = r.body.content != null ? r.body.content : r.body;
        for (var i = 0; i < list.length; i++) { if (list[i].groupCode == 'DOCCAT') return list[i]; }
        fail('the document-category group DOCCAT does not exist on ' + baseUrl + ' - run the database migrations (Document Categories screen shows the same error)');
      })()
      """
    * def listCategories =
      """
      function() {
        var r = api('GET', '/v1/master-data/generic-code-groups/' + doccat.id + '/values', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list document categories: ' + show(r));
        return r.body.content != null ? r.body.content : r.body;
      }
      """
    * def catLabel = function(c) { var n = null; for (var i = 0; c.locales != null && i < c.locales.length; i++) { if (c.locales[i].locale == 'en') n = c.locales[i].name; } return n != null ? n : c.valueCode; }
    * def findCategory = function(list, code) { for (var i = 0; i < list.length; i++) { if (eq(list[i].valueCode, code) || eq(catLabel(list[i]), code)) return list[i]; } return null; }
    * def categorySpec =
      """
      function(code) {
        for (var i = 0; i < rawCategories.length; i++) {
          var c = rawCategories[i];
          var cc = strVal(c.code != null ? c.code : c.valueCode, null);
          if (eq(cc, code)) return { code: cc, name: strVal(c.name, cc), description: strVal(c.description, null) };
        }
        return null;
      }
      """
    * def neededCategories =
      """
      (function() {
        var out = []; var seen = {};
        var add = function(c) { var s = strVal(c, null); if (s == null) return; if (seen[s.toLowerCase()]) return; seen[s.toLowerCase()] = true; out.push(s); };
        for (var i = 0; i < rawCategories.length; i++) add(rawCategories[i].code != null ? rawCategories[i].code : rawCategories[i].valueCode);
        for (var j = 0; j < rawDocTypes.length; j++) add(rawDocTypes[j].category != null ? rawDocTypes[j].category : rawDocTypes[j].docCategoryCode);
        for (var k = 0; k < sections.length; k++) add(sections[k].category);
        return out;
      })()
      """
    * def setupCategories =
      """
      function() {
        var existing = listCategories();
        var made = [];
        for (var i = 0; i < neededCategories.length; i++) {
          var code = neededCategories[i];
          var hit = findCategory(existing, code);
          if (hit != null) {
            if (hit.active == false) note('WARNING: document category ' + hit.valueCode + ' exists but is INACTIVE - the New Checklist form will not offer it');
            continue;
          }
          var spec = categorySpec(code);
          if (spec == null && !createMissingCategories) {
            var names = []; for (var e = 0; e < existing.length; e++) names.push(existing[e].valueCode + ' = ' + catLabel(existing[e]));
            fail('document category "' + code + '" does not exist and createMissingCategories=false. Describe it in the categories column, or use one of: ' + names.join(', '));
          }
          if (spec == null) spec = { code: code, name: code, description: null };
          var body = { groupId: doccat.id, valueCode: spec.code, sortOrder: 10 * (existing.length + made.length + 1), active: true,
                       locales: [{ locale: 'en', name: spec.name, description: spec.description != null ? spec.description : ('Created by Document-Checklist-Automation.xlsx (' + strVal(td.checklistId, 'row') + ')') }] };
          var send = (function(b) { return function() { return api('POST', '/v1/master-data/generic-code-groups/' + doccat.id + '/values', adminHeader, b); }; })(body);
          governed('create document category ' + spec.code, send(), send, ['GENERIC_CODE_VALUE'], [spec.code]);
          made.push(spec.code);
        }
        var after = listCategories();
        for (var v = 0; v < made.length; v++) { if (findCategory(after, made[v]) == null) fail('document category ' + made[v] + ' was committed but is not listed afterwards'); }
        // canonical server codes for everything this row references
        var canon = {};
        for (var n = 0; n < neededCategories.length; n++) { var c2 = findCategory(after, neededCategories[n]); if (c2 == null) fail('document category ' + neededCategories[n] + ' is still missing'); canon[neededCategories[n].toLowerCase()] = '' + c2.valueCode; }
        return { created: made, canon: canon };
      }
      """
    * def catResult = setupCategories()
    * def canonCat = function(code) { var c = catResult.canon[('' + code).trim().toLowerCase()]; return c != null ? c : code; }
    * eval for (var i = 0; i < sections.length; i++) { sections[i].category = canonCat(sections[i].category); }
    * note('document categories: ' + (catResult.created.length > 0 ? 'created ' + catResult.created.join(', ') : 'all present'))

    # ── 3. DOCUMENT CONFIGS (types under a category): reuse or create ─────────────────────────
    * def listDocTypes =
      """
      function() {
        var all = []; var page = 0; var pages = 1;
        while (page < pages && page < 50) {
          var r = api('GET', '/v1/master-data/document-configs?page=' + page + '&size=100', adminHeader, null);
          if (r.status != 200 || r.body == null) fail('cannot list document configs: ' + show(r));
          var list = r.body.content != null ? r.body.content : r.body;
          for (var i = 0; i < list.length; i++) all.push(list[i]);
          pages = r.body.totalPages != null ? r.body.totalPages : 1;
          page++;
        }
        return all;
      }
      """
    * def findDocType = function(list, cat, code) { for (var i = 0; i < list.length; i++) { var d = list[i]; if (eq(d.docCategoryCode, cat) && (eq(d.documentType, code) || eq(d.documentName, code))) return d; } return null; }
    * def docTypeSpec =
      """
      function(cat, code) {
        for (var i = 0; i < rawDocTypes.length; i++) {
          var t = rawDocTypes[i];
          var tc = strVal(t.category != null ? t.category : t.docCategoryCode, null);
          var cc = strVal(t.code != null ? t.code : t.documentType, null);
          if (eq(canonCat(tc), cat) && eq(cc, code)) return { category: cat, code: cc, name: strVal(t.name != null ? t.name : t.documentName, cc), required: flag(t, 'required') };
        }
        return null;
      }
      """
    * def neededDocTypes =
      """
      (function() {
        var out = []; var seen = {};
        var add = function(cat, code) { var c = strVal(cat, null); var s = strVal(code, null); if (c == null || s == null) return; var key = canonCat(c).toLowerCase() + '|' + s.toLowerCase(); if (seen[key]) return; seen[key] = true; out.push({ category: canonCat(c), code: s }); };
        for (var i = 0; i < rawDocTypes.length; i++) add(rawDocTypes[i].category != null ? rawDocTypes[i].category : rawDocTypes[i].docCategoryCode, rawDocTypes[i].code != null ? rawDocTypes[i].code : rawDocTypes[i].documentType);
        for (var j = 0; j < sections.length; j++) { for (var k = 0; k < sections[j].docTypes.length; k++) add(sections[j].category, sections[j].docTypes[k].code); }
        return out;
      })()
      """
    * def doctypeGroup =
      """
      (function() {
        var r = api('GET', '/v1/master-data/generic-code-groups?search=DOCTYPE&size=50', adminHeader, null);
        if (r.status != 200 || r.body == null) return null;
        var list = r.body.content != null ? r.body.content : r.body;
        for (var i = 0; i < list.length; i++) { if (list[i].groupCode == 'DOCTYPE') return list[i]; }
        return null;
      })()
      """
    * def ensureDocTypeLabel =
      """
      function(code, name) {
        if (doctypeGroup == null) return;
        var r = api('GET', '/v1/master-data/generic-code-groups/' + doctypeGroup.id + '/values?search=' + encodeURIComponent(code), adminHeader, null);
        if (r.status != 200 || r.body == null) return;
        var list = r.body.content != null ? r.body.content : r.body;
        for (var i = 0; i < list.length; i++) { if (eq(list[i].valueCode, code)) return; }
        var body = { groupId: doctypeGroup.id, valueCode: code, sortOrder: 10, active: true, locales: [{ locale: 'en', name: name, description: 'Created by Document-Checklist-Automation.xlsx' }] };
        var send = function() { return api('POST', '/v1/master-data/generic-code-groups/' + doctypeGroup.id + '/values', adminHeader, body); };
        governed('create document-type label ' + code + ' (DOCTYPE)', send(), send, ['GENERIC_CODE_VALUE'], [code]);
      }
      """
    * def setupDocTypes =
      """
      function() {
        var existing = listDocTypes();
        var made = [];
        for (var i = 0; i < neededDocTypes.length; i++) {
          var need = neededDocTypes[i];
          var hit = findDocType(existing, need.category, need.code);
          if (hit != null) {
            if (hit.active == false) note('WARNING: document type ' + hit.documentType + ' under ' + need.category + ' exists but is INACTIVE');
            continue;
          }
          var spec = docTypeSpec(need.category, need.code);
          if (spec == null && !createMissingDocTypes) {
            var names = []; for (var e = 0; e < existing.length; e++) { if (eq(existing[e].docCategoryCode, need.category)) names.push(existing[e].documentType); }
            fail('document type "' + need.code + '" does not exist under category ' + need.category + ' and createMissingDocTypes=false. Describe it in the documentTypes column, or use one of: ' + (names.length > 0 ? names.join(', ') : '(none configured for this category yet)'));
          }
          if (spec == null) spec = { category: need.category, code: need.code, name: need.code, required: false };
          ensureDocTypeLabel(spec.code, spec.name);
          var body = { documentType: spec.code, docCategoryCode: spec.category, required: spec.required, active: true };
          var send = (function(b) { return function() { return api('POST', '/v1/master-data/document-configs', adminHeader, b); }; })(body);
          governed('create document type ' + spec.code + ' under ' + spec.category, send(), send, ['DOC_CHANGE'], [spec.code]);
          made.push(spec.category + '/' + spec.code);
        }
        var after = listDocTypes();
        var canon = {};
        for (var n = 0; n < neededDocTypes.length; n++) {
          var d = findDocType(after, neededDocTypes[n].category, neededDocTypes[n].code);
          if (d == null) fail('document type ' + neededDocTypes[n].code + ' under ' + neededDocTypes[n].category + ' is still missing after setup');
          canon[neededDocTypes[n].category.toLowerCase() + '|' + neededDocTypes[n].code.toLowerCase()] = '' + d.documentType;
        }
        return { created: made, canon: canon };
      }
      """
    * def dtResult = setupDocTypes()
    * eval for (var i = 0; i < sections.length; i++) { for (var j = 0; j < sections[i].docTypes.length; j++) { var c = dtResult.canon[sections[i].category.toLowerCase() + '|' + sections[i].docTypes[j].code.toLowerCase()]; if (c != null) sections[i].docTypes[j].code = c; } }
    * note('document types: ' + (dtResult.created.length > 0 ? 'created ' + dtResult.created.join(', ') : 'all present'))

    # ── 4. THE CHECKLIST: desired record as the New Checklist form would submit it ───────────
    * def desired =
      """
      (function() {
        var details = [];
        for (var i = 0; i < sections.length; i++) {
          var s = sections[i];
          details.push({ docCategory: s.category, phaseId: s.phase, noOfDocsReq: s.noOfDocsReq, noOfCopies: s.noOfCopies, docTypes: s.docTypes });
        }
        return { name: checklistName, description: strVal(td.description, null), active: checklistActive, details: details };
      })()
      """
    * def findChecklist =
      """
      function() {
        var r = api('GET', '/v1/master-data/document-checklists?search=' + encodeURIComponent(checklistName) + '&size=100', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search document checklists: ' + show(r));
        var list = r.body.content != null ? r.body.content : r.body;
        for (var i = 0; i < list.length; i++) { if (eq(list[i].name, checklistName)) return list[i]; }
        return null;
      }
      """
    * def normalise =
      """
      function(c) {
        var ds = [];
        var dets = c.details != null ? c.details : [];
        for (var i = 0; i < dets.length; i++) {
          var d = dets[i];
          var ts = [];
          var types = d.docTypes != null ? d.docTypes : [];
          for (var j = 0; j < types.length; j++) {
            var t = types[j];
            ts.push(('' + t.code).toLowerCase() + ':' + (t.mandatory == true) + ':' + (t.primary == true) + ':' + (t.coApplicant == true) + ':' + (t.guarantor == true) + ':' + (t.signatureRequired == true) + ':' + (t.original == true));
          }
          ts.sort();
          ds.push((d.phaseId != null ? ('' + d.phaseId).toUpperCase() : '') + '|' + ('' + d.docCategory).toLowerCase() + '|' + (d.noOfDocsReq != null ? d.noOfDocsReq : 0) + '|' + (d.noOfCopies != null ? d.noOfCopies : 1) + '|' + ts.join(','));
        }
        ds.sort();
        return (c.active == null ? true : c.active == true) + '#' + ds.join('#');
      }
      """
    * def setupChecklist =
      """
      function() {
        var existing = findChecklist();
        if (existing != null) {
          var full = api('GET', '/v1/master-data/document-checklists/' + existing.id, adminHeader, null);
          if (full.status == 200 && full.body != null) existing = full.body;
          if (normalise(existing) == normalise(desired)) {
            note('checklist ' + existing.id + ' "' + existing.name + '" already matches the sheet - nothing to do');
            return { id: existing.id, action: 'unchanged' };
          }
          note('checklist ' + existing.id + ' "' + existing.name + '" differs from the sheet - requesting an amendment');
          var body = karate.merge(desired, { id: existing.id });
          var send = function() { return api('PUT', '/v1/master-data/document-checklists/' + existing.id, adminHeader, body); };
          governed('amend checklist ' + existing.id + ' (' + checklistName + ')', send(), send, ['DOC_CHECKLIST'], [checklistName, existing.id]);
          return { id: existing.id, action: 'amended' };
        }
        var create = function() { return api('POST', '/v1/master-data/document-checklists', adminHeader, desired); };
        governed('create checklist (' + checklistName + ')', create(), create, ['DOC_CHECKLIST'], [checklistName]);
        var made = null;
        for (var i = 0; i < 30 && made == null; i++) { made = findChecklist(); if (made == null) java.lang.Thread.sleep(1000); }
        if (made == null) fail('the change request for checklist "' + checklistName + '" was committed but no checklist with that name is listed afterwards');
        return { id: made.id, action: 'created' };
      }
      """
    * def outcome = setupChecklist()
    * def checklistId = outcome.id
    * def verifyChecklist =
      """
      function() {
        var g = api('GET', '/v1/master-data/document-checklists/' + checklistId, adminHeader, null);
        if (g.status != 200 || g.body == null) fail('VERIFY: checklist ' + checklistId + ' cannot be read back: ' + show(g));
        if (normalise(g.body) != normalise(desired)) fail('VERIFY: checklist ' + checklistId + ' does not match the sheet after ' + outcome.action + '. Server: ' + karate.pretty(g.body) + ' Sheet: ' + karate.pretty(desired));
        var parts = [];
        for (var i = 0; i < g.body.details.length; i++) { var d = g.body.details[i]; var codes = []; for (var j = 0; d.docTypes != null && j < d.docTypes.length; j++) codes.push(d.docTypes[j].code + (d.docTypes[j].mandatory ? '*' : '')); parts.push((d.phaseId != null ? d.phaseId : 'ALL') + '/' + d.docCategory + ' req=' + d.noOfDocsReq + ' [' + codes.join(', ') + ']'); }
        return 'checklist ' + checklistId + ' "' + g.body.name + '" ' + outcome.action + ' active=' + g.body.active + ' | ' + parts.join(' | ');
      }
      """
    * def checklistSummary = verifyChecklist()
    * note(checklistSummary)

    # ── 5. ATTACH to product types (Origination Configuration of each type) ──────────────────
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
        if (('' + cur.documentChecklistId) == ('' + checklistId)) { note('product type ' + pt.code + ' already carries checklist ' + checklistId); return pt.code + ' (already attached)'; }
        var s = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/schema', adminHeader, null);
        if (s.status != 200 || s.body == null) fail('cannot read product type ' + pt.code + ': ' + show(s));
        var ex = s.body;
        // The amendment replaces the whole origination configuration, so every other field is copied from the server.
        var cfg = { productTypeCode: pt.code, documentChecklistId: checklistId, scorecardId: cur.scorecardId, assessmentMethod: cur.assessmentMethod, routingMethod: cur.routingMethod };
        if (cur.charges != null) cfg.charges = cur.charges;
        if (cur.templates != null && cur.templates.length > 0) cfg.templates = cur.templates;
        var body = {
          productType: { id: ex.id, code: ex.code, label: ex.label, description: ex.description, icon: ex.icon, category: ex.category, customerType: ex.customerType,
                         workflowKey: ex.workflowKey, displayOrder: ex.displayOrder, active: true },
          config: cfg
        };
        note('product type ' + pt.code + ': checklist ' + cur.documentChecklistId + ' -> ' + checklistId + ' (amendment)');
        var send = function() { return api('PUT', '/v1/product-types/' + ex.id, adminHeader, body); };
        governed('attach checklist ' + checklistId + ' to product type ' + pt.code, send(), send, ['PRODUCT_TYPE'], [pt.code, ex.id]);
        var chk = typeConfigOf(pt);
        if (('' + chk.documentChecklistId) != ('' + checklistId)) fail('product type ' + pt.code + ' amendment was committed but its configuration carries checklist ' + chk.documentChecklistId + ', expected ' + checklistId);
        return pt.code + ' (attached)';
      }
      """
    * def attachedTypes = []
    * eval for (var i = 0; i < attachTypes.length; i++) attachedTypes.push(attachToType(attachTypes[i]))

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
        if (sub == null) fail('sub-product "' + subRaw + '" is not linked to product type ' + pt.code + '. Link it via selectedProductCode in Product-Configuration-Automation.xlsx, or use one of: ' + (opts.length > 0 ? opts.join(', ') : '(none linked yet)'));
        var typeCfg = typeConfigOf(pt);
        var cur = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, null);
        var curBody = (cur.status == 200 && cur.body != null) ? cur.body : {};
        if (('' + curBody.documentChecklistId) == ('' + checklistId)) { note('sub-product ' + pt.code + '/' + sub + ' already carries checklist ' + checklistId); return pt.code + '/' + sub + ' (already attached)'; }
        var cfg = { productTypeCode: pt.code, productCode: sub, documentChecklistId: checklistId,
                    scorecardId: curBody.scorecardId != null ? curBody.scorecardId : typeCfg.scorecardId,
                    assessmentMethod: curBody.assessmentMethod != null ? curBody.assessmentMethod : typeCfg.assessmentMethod,
                    routingMethod: curBody.routingMethod != null ? curBody.routingMethod : typeCfg.routingMethod, active: true };
        if (curBody.charges != null) cfg.charges = curBody.charges;
        var send = function() { return api('PUT', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, cfg); };
        governed('attach checklist ' + checklistId + ' to sub-product ' + pt.code + '/' + sub, send(), send, ['PRODUCT_TYPE', 'PRODUCT_CONFIG'], [pt.code, sub]);
        var chk = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, null);
        var got = (chk.status == 200 && chk.body != null) ? chk.body.documentChecklistId : null;
        if (('' + got) != ('' + checklistId)) fail('sub-product ' + pt.code + '/' + sub + ' config was committed but carries checklist ' + got + ', expected ' + checklistId);
        return pt.code + '/' + sub + ' (attached)';
      }
      """
    * eval for (var i = 0; i < attachSubs.length; i++) attachedTypes.push(attachToSub(attachSubs[i]))

    # ── 7. VERIFY what the wizard will get for each attached product type ────────────────────
    * def wizardCheck =
      """
      function() {
        var out = [];
        for (var i = 0; i < attachTypes.length; i++) {
          var pt = resolveProductType(attachTypes[i]);
          var lp = api('GET', '/v1/product-types/' + encodeURIComponent(pt.code) + '/products', adminHeader, null);
          var first = (lp.status == 200 && lp.body != null && lp.body.length > 0) ? lp.body[0].productCode : null;
          if (first == null) { out.push(pt.code + ': no sub-product linked yet, wizard lookup skipped'); continue; }
          var w = api('GET', '/v1/product-config/checklist?productTypeCode=' + encodeURIComponent(pt.code) + '&productCode=' + encodeURIComponent(first), adminHeader, null);
          if (w.status != 200 || w.body == null || ('' + w.body.id) != ('' + checklistId)) fail('VERIFY: the wizard lookup for ' + pt.code + '/' + first + ' returns ' + (w.status == 200 ? 'checklist ' + w.body.id : show(w)) + ', expected checklist ' + checklistId);
          out.push(pt.code + '/' + first + ': wizard sees checklist ' + w.body.id);
        }
        return out;
      }
      """
    * def wizardSummary = wizardCheck()
    * note('DOCUMENT CHECKLIST COMPLETE')
    * print rowTag, checklistSummary
    * print rowTag, 'attached to:', (attachedTypes.length > 0 ? attachedTypes.join(', ') : '(nothing - attachToProductTypes and attachToSubProducts are blank)')
    * print rowTag, 'wizard check:', (wizardSummary.length > 0 ? wizardSummary.join(' | ') : '(no product type attached)')
    * if (ckHeader() != null) logout(ckHeader())
    * logout(adminHeader)

