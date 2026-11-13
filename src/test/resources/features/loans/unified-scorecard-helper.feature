@ignore
Feature: Unified Scorecard Helper - CREATE, AMEND, DEACTIVATE, DELETE for the Scorecards sheet

  # ── HOW A ROW IS INTERPRETED ───────────────────────────────────────────────────────────────
  #   CREATE     : make the record match the sheet. Missing -> created; present -> amended when it differs.
  #   AMEND      : same as CREATE but the record MUST already exist (a typo in the name fails the row). Exactly like
  #                the screen's Edit: an existing unactivated draft of the code is reused ("Open draft vN"), otherwise a
  #                new draft is cloned from the live version; the draft is then activated (publish) and supersedes it.
  #   DEACTIVATE : the screen's Deactivate button (POST /{id}/deactivate) on the ACTIVE / SCHEDULED version. Product types
  #                and sub-product rows that reference the scorecard are detached first (detachFromProductTypes, default
  #                true) because the server does not check references. Drafts are retired too when deleteStaleDrafts.
  #   DELETE     : (setup workbook) same effect through DELETE /{id}: every live version -> INACTIVE, references detached.
  # The screen has no Delete button - a scorecard is never removed, only retired (INACTIVE) or superseded.
  # Scorecard changes are not governed by maker-checker: they apply immediately.
  # Every governed change (HTTP 202 / ChangeRequest) is approved by a four-eyes checker and committed.
  # Server rules that shape this file were verified against the backend sources on 2026-09-17.

  Scenario: Execute Single Scorecard Row
    * def td = typeof __arg !== 'undefined' ? __arg : {}
    * url baseUrl
    * configure retry = { count: 24, interval: 5000 }

    # ── Small helpers ─────────────────────────────────────────────────────────
    * def strVal = function(val, defVal) { return (val != null && val.toString().trim() != '') ? val.toString().trim() : defVal }
    * def isTrue = function(val) { if (val == null) return false; var s = val.toString().trim().toLowerCase(); return s == 'true' || s == 'y' || s == 'yes' || s == '1'; }
    * def boolVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; return isTrue(s); }
    * def numVal = function(val, defVal) { var s = strVal(val, null); if (s == null) return defVal; var n = parseFloat(('' + s).replace(/,/g, '')); return isNaN(n) ? defVal : n; }
    * def splitList = function(val, sep) { var out = []; var s = strVal(val, ''); if (s == '') return out; var parts = s.split(sep == null ? ',' : sep); for (var i = 0; i < parts.length; i++) { if (parts[i].trim() != '') out.push(parts[i].trim()); } return out; }
    * def eq = function(a, b) { return a != null && b != null && ('' + a).trim().toLowerCase() == ('' + b).trim().toLowerCase(); }
    * def resolveAction =
      """
      function(row) {
        if (row.action != null && ('' + row.action).trim() != '') return ('' + row.action).trim().toUpperCase();
        if (isTrue(row.delete)) return 'DELETE';
        if (isTrue(row.amend)) return 'AMEND';
        return 'CREATE';
      }
      """
    * def action = resolveAction(td)
    * def rowTag = '[SCORECARD ' + action + ' ' + strVal(td.scorecardId, strVal(td.scorecardCode, 'row')) + ']'
    * def note = function(m) { karate.log(rowTag, m); }
    * def fail = function(m) { var msg = rowTag + ' ' + m; karate.log(msg); karate.fail(msg); throw new Error(msg); }
    * def req = function(col, why) { var v = strVal(td[col], null); if (v == null) fail('column "' + col + '" is blank but is required ' + why); return v; }
    * def isoDate =
      """
      function(v, col) {
        var s = strVal(v, null);
        if (s == null) return null;
        if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
        if (/^\d{4}-\d{2}-\d{2}T/.test(s)) return s.substring(0, 10);
        var m = /^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4})$/.exec(s);
        if (m != null) return m[3] + '-' + (m[2].length == 1 ? '0' + m[2] : m[2]) + '-' + (m[1].length == 1 ? '0' + m[1] : m[1]);
        var m2 = /^(\d{4})[\/.](\d{1,2})[\/.](\d{1,2})$/.exec(s);
        if (m2 != null) return m2[1] + '-' + (m2[2].length == 1 ? '0' + m2[2] : m2[2]) + '-' + (m2[3].length == 1 ? '0' + m2[3] : m2[3]);
        fail('column "' + col + '" = "' + s + '" is not a date (use yyyy-MM-dd or dd-MM-yyyy)');
      }
      """
    * def parseJson =
      """
      function(col, required) {
        var s = strVal(td[col], null);
        if (s == null) { if (required) fail('column "' + col + '" is blank but is required for this row'); return []; }
        var v;
        try { v = JSON.parse(s); } catch (e) { fail('column "' + col + '" is not valid JSON: ' + e + ' | value: ' + s); }
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
    # The platform allows one session per user and revokes the older one on a new login, sometimes a call or two
    # late. Every call made with the admin's token therefore uses the CURRENT admin token, and a 401 on it signs the
    # admin in again once and retries.
    * def api =
      """
      function(method, path, header, body) {
        var send = function(hdr) {
          var h = karate.http(baseUrl + path).header('Authorization', hdr).header('Content-Type', 'application/json');
          var m = method.toUpperCase();
          if (m == 'GET') return h.get();
          if (m == 'DELETE') return h.delete();
          if (m == 'PUT') return h.put(body == null ? {} : body);
          return h.post(body == null ? {} : body);
        };
        var known = karate.get('adminTokensStr');
        var isAdmin = header != null && known != null && ('' + known).indexOf('' + header) >= 0;
        var res = send(isAdmin ? karate.get('adminHeaderVal') : header);
        if (res.status == 401 && isAdmin) {
          note('admin session was revoked by the server (' + (res.body != null && res.body.code != null ? res.body.code : '401') + ') - signing in again');
          var nh = softLogin(karate.get('adminUserVal'), karate.get('adminPassVal'));
          if (nh != null) {
            karate.set('adminHeaderVal', nh);
            karate.set('adminTokensStr', known + '|' + nh);
            res = send(nh);
          }
        }
        return res;
      }
      """
    * def today = java.time.LocalDate.now().toString()
    # Charge endpoints wrap their payload as { success, message, data }; everything else is bare JSON.
    * def unwrap = function(b) { return (b != null && typeof b == 'object' && b.data !== undefined && (b.success !== undefined || b.message !== undefined)) ? b.data : b; }

    # ── Login / session handling ──────────────────────────────────────────────
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

    # ── Accounts: an admin that can configure, checkers that can approve ──────
    * def excelAdminUser = strVal(td.adminUsername, null)
    * def excelAdminPass = strVal(td.adminPassword, defaultAdminPassword)
    * def excelCheckerUser = strVal(td.checkerUsername, null)
    * def excelCheckerPass = strVal(td.checkerPassword, defaultAdminPassword)

    * def canConfigure = function(header) { var r = api('GET', '/v1/config/scorecards/attribute-catalog?domain=LOAN_APPLICATION', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canConfigure(h)) return { user: excelAdminUser, header: h, pass: excelAdminPass, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot configure scorecards (403) - falling back to default admin ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
        if (h2 != null && canConfigure(h2)) return { user: defaultAdminUsername, header: h2, pass: defaultAdminPassword, source: 'karate-config' };
        if (h2 != null) logout(h2);
        tried.push(defaultAdminUsername);
        fail('no admin account can configure scorecards. Tried: ' + tried.join(', '));
      }
      """
    * def admin = resolveAdmin()
    * def adminUser = admin.user
    * def adminHeader = admin.header
    * karate.set('adminHeaderVal', admin.header)
    * karate.set('adminTokensStr', admin.header)
    * karate.set('adminUserVal', admin.user)
    * karate.set('adminPassVal', admin.pass)

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
    * def relogCheckerIfNeeded =
      """
      function() {
        if (ckUser() == null) return;
        var h = softLogin(ckUser(), karate.get('ckPassword'));
        if (h != null) karate.set('ckHeaderVal', h);
      }
      """

    # ── Governance (maker-checker approval and commit) ────────────────────────
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
        api('POST', '/v1/supervisor-links', adminHeader, { userUsername: user, supervisorUsername: supervisor, active: true });
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
            var votes = 0;
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
                csUser = c.username; csHeader = h;
              }
              if (csUser == null) break;
              usedCheckers[csUser] = true;
              ensureSupervisorLink(initiator, csUser);
              var a = api('POST', '/v1/change-requests/' + id + '/approve', csHeader, { comment: 'Approved by Excel unified setup (' + what + ')' });
              if (a.status == 401) { relogCheckerIfNeeded(); a = api('POST', '/v1/change-requests/' + id + '/approve', ckHeader(), { comment: 'Approved by Excel unified setup (' + what + ')' }); }
              if (a.status != 200) { note('checker ' + csUser + ' could not approve: ' + show(a)); continue; }
              votes++;
              var g = crGet(id);
              status = (g.status == 200 && g.body != null && g.body.status != null) ? g.body.status : 'APPROVED';
            }
            if (status == 'PENDING_APPROVAL') return what + ': change request ' + id + ' is still PENDING_APPROVAL after ' + votes + ' vote(s) - no checker account (checkerUsername column / karate-config governanceCheckers) could approve it';
          }
        }
        if (status == 'APPROVED') {
          var cm = api('POST', '/v1/change-requests/' + id + '/commit', adminHeader, {});
          if (cm.status != 200) return what + ': commit of change request ' + id + ' failed -> ' + show(cm);
          status = 'COMMITTED';
        }
        if (status == 'REJECTED' || status == 'CANCELLED') return what + ': change request ' + id + ' is ' + status;
        return null;
      }
      """
    # A stale pending change request on the same record blocks a new one (409 PENDING_CHANGE_EXISTS).
    # Cancel it (admin) or settle it, then retry once. hints = event/entity type fragments, keywords = record identifiers.
    * def resolvePending =
      """
      function(hints, keywords, what) {
        var r = api('GET', '/v1/change-requests/all-pending', adminHeader, null);
        if (r.status != 200 || r.body == null) { note(what + ': could not list pending change requests: ' + show(r)); return false; }
        var handled = 0;
        for (var i = 0; i < r.body.length; i++) {
          var cr = r.body[i];
          var ev = ('' + cr.eventCode + ' ' + cr.entityType).toUpperCase();
          var hintHit = (hints == null || hints.length == 0);
          for (var h = 0; !hintHit && h < hints.length; h++) { if (ev.indexOf(('' + hints[h]).toUpperCase()) >= 0) hintHit = true; }
          if (!hintHit) continue;
          var label = ('' + (cr.entityLabel != null ? cr.entityLabel : '') + ' ' + (cr.entityId != null ? cr.entityId : '') + ' ' + (cr.payload != null ? JSON.stringify(cr.payload) : '')).toUpperCase();
          var hit = (keywords == null || keywords.length == 0);
          for (var k = 0; !hit && k < keywords.length; k++) { if (keywords[k] != null && label.indexOf(('' + keywords[k]).toUpperCase()) >= 0) hit = true; }
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
      function(what, res, retryFn, hints, keywords) {
        var b = unwrap(res.body);
        if (res.status >= 200 && res.status < 300) {
          if (b != null && typeof b == 'object' && b.id != null && b.status != null && (b.eventCode != null || b.operation != null)) {
            note(what + ': change request ' + b.id + ' raised (' + b.eventCode + ', ' + b.status + ', ' + b.eventSeverity + ')');
            var err = settleCr(b, what);
            if (err != null) fail(err);
            return true;
          }
          note(what + ': applied (HTTP ' + res.status + ')');
          return true;
        }
        var text = ('' + (res.body == null ? '' : (typeof res.body == 'string' ? res.body : JSON.stringify(res.body)))).toLowerCase();
        if (res.status == 409 && retryFn != null && ((b != null && b.code == 'PENDING_CHANGE_EXISTS') || text.indexOf('pending') >= 0)) {
          note(what + ': ' + text);
          if (!resolvePending(hints, keywords, what)) fail(what + ': a change request is already pending on this record and could not be resolved. ' + show(res));
          return governed(what, retryFn(), null, hints, keywords);
        }
        fail(what + ' -> ' + show(res));
      }
      """

    # ── Product-type helpers shared by every sheet that attaches something to a type ───────
    # PUT /v1/product-types/{id} is a blind overwrite: productType.workflowKey null -> 400, category null ->
    # category wiped, customerType null -> RETAIL, active absent -> the type is DEACTIVATED. So the body is
    # always rebuilt from the type's own /schema and /config, and only the intended fields are changed.
    * def PT_HINTS = ['PRODUCT_TYPE', 'PRODUCT_LINK', 'PRODUCT_CONFIG']
    * def listProductTypes =
      """
      function() {
        var r = api('GET', '/v1/product-types', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list product types: ' + show(r));
        return r.body.content != null ? r.body.content : r.body;
      }
      """
    * def ptLabel = function(pt) { return pt.label != null ? pt.label : (pt.name != null ? pt.name : pt.code); }
    * def findProductType =
      """
      function(raw) {
        var list = listProductTypes();
        for (var i = 0; i < list.length; i++) { if (eq(list[i].code, raw) || eq(ptLabel(list[i]), raw)) return list[i]; }
        return null;
      }
      """
    * def resolveProductType =
      """
      function(raw, why) {
        var list = listProductTypes();
        var opts = [];
        for (var i = 0; i < list.length; i++) {
          opts.push(list[i].code + ' = ' + ptLabel(list[i]));
          if (eq(list[i].code, raw) || eq(ptLabel(list[i]), raw)) return list[i];
        }
        fail('product type "' + raw + '" does not exist (or is inactive) on ' + baseUrl + (why != null ? ' - ' + why : '') + '. Active product types: ' + opts.join(', '));
      }
      """
    * def schemaOf = function(code) { var s = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/schema', adminHeader, null); if (s.status != 200 || s.body == null) fail('cannot read product type ' + code + ' (inactive types are not readable): ' + show(s)); return s.body; }
    * def typeConfigOf = function(code) { var r = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/config', adminHeader, null); if (r.status != 200 || r.body == null) fail('product type ' + code + ' has no readable configuration: ' + show(r)); return r.body; }
    * def stripCharges = function(list) { var out = []; for (var i = 0; list != null && i < list.length; i++) { if (list[i] == null || list[i].chargeDefId == null) continue; out.push({ chargeDefId: list[i].chargeDefId, active: list[i].active != false }); } return out; }
    * def baseTypeConfig =
      """
      function(code, cur) {
        var cfg = { productTypeCode: code, scorecardId: cur.scorecardId, documentChecklistId: cur.documentChecklistId, assessmentMethod: cur.assessmentMethod, routingMethod: cur.routingMethod, active: true };
        if (cur.charges != null) cfg.charges = stripCharges(cur.charges);
        if (cur.templates != null && cur.templates.length > 0) cfg.templates = cur.templates;
        return cfg;
      }
      """
    * def typeUpdateBody =
      """
      function(ex, cfg, overrides) {
        var pt = { id: ex.id, code: ex.code, label: ex.label, description: ex.description,
                   icon: (ex.icon != null && ('' + ex.icon).trim() != '') ? ex.icon : 'credit_card',
                   category: ex.category, customerType: ex.customerType, hasExtendedFields: ex.hasExtendedFields == true,
                   workflowKey: ex.workflowKey, displayOrder: ex.displayOrder != null ? ex.displayOrder : 0, active: true };
        if (overrides != null) { for (var k in overrides) { if (overrides[k] !== undefined) pt[k] = overrides[k]; } }
        return { productType: pt, config: cfg };
      }
      """
    # mutate(cfg, cur, ex) edits the config copy and returns false when nothing has to change.
    * def amendTypeConfig =
      """
      function(code, what, keywords, mutate, overrides) {
        var ex = schemaOf(code);
        var cur = typeConfigOf(code);
        var cfg = baseTypeConfig(code, cur);
        var changed = mutate(cfg, cur, ex);
        if (changed === false) return false;
        if (cfg.assessmentMethod == null) cfg.assessmentMethod = 'MANUAL';
        if (cfg.routingMethod == null) cfg.routingMethod = 'DIRECT';
        var body = typeUpdateBody(ex, cfg, overrides);
        var send = function() { return api('PUT', '/v1/product-types/' + ex.id, adminHeader, body); };
        governed(what, send(), send, PT_HINTS, keywords != null ? keywords : [code, ex.id]);
        return true;
      }
      """
    * def subProductsOf =
      """
      function(code) {
        var r = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/products', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list the sub-products of ' + code + ': ' + show(r));
        return r.body;
      }
      """
    * def resolveSubProduct =
      """
      function(code, raw) {
        var list = subProductsOf(code);
        var opts = [];
        for (var i = 0; i < list.length; i++) {
          opts.push(list[i].productCode + ' = ' + list[i].productDescription);
          if (eq(list[i].productCode, raw) || eq(list[i].productDescription, raw)) return '' + list[i].productCode;
        }
        fail('sub-product "' + raw + '" is not linked to product type ' + code + '. Link it via selectedProductCode in the Product_Types sheet, or use one of: ' + (opts.length > 0 ? opts.join(', ') : '(none linked yet)'));
      }
      """
    # Sub-products that carry a configuration row of their own (the others inherit the type's).
    * def configuredSubs =
      """
      function(code) {
        var r = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/products/configured', adminHeader, null);
        var out = [];
        if (r.status != 200 || r.body == null) return out;
        for (var k in r.body) { if (r.body[k] == true) out.push(k); }
        return out;
      }
      """
    * def subConfigOf = function(code, sub) { var r = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, null); return (r.status == 200 && r.body != null) ? r.body : null; }
    # A sub-product row: charges null = inherits the type's charges; a list (even empty) = its own list.
    * def amendSubConfig =
      """
      function(code, sub, what, keywords, mutate) {
        var cur = subConfigOf(code, sub);
        if (cur == null) cur = {};
        var typeCfg = typeConfigOf(code);
        var cfg = { productTypeCode: code, productCode: sub,
                    scorecardId: cur.scorecardId != null ? cur.scorecardId : typeCfg.scorecardId,
                    documentChecklistId: cur.documentChecklistId,
                    assessmentMethod: cur.assessmentMethod != null ? cur.assessmentMethod : typeCfg.assessmentMethod,
                    routingMethod: cur.routingMethod != null ? cur.routingMethod : typeCfg.routingMethod, active: true };
        if (cur.charges != null) cfg.charges = stripCharges(cur.charges);
        if (cur.templates != null && cur.templates.length > 0) cfg.templates = cur.templates;
        var changed = mutate(cfg, cur, typeCfg);
        if (changed === false) return false;
        if (cfg.assessmentMethod == null) cfg.assessmentMethod = 'MANUAL';
        if (cfg.routingMethod == null) cfg.routingMethod = 'DIRECT';
        var send = function() { return api('PUT', '/v1/product-types/' + encodeURIComponent(code) + '/products/' + encodeURIComponent(sub) + '/config', adminHeader, cfg); };
        governed(what, send(), send, PT_HINTS, keywords != null ? keywords : [code, sub]);
        return true;
      }
      """
    * def genericOptions =
      """
      function(group) {
        var r = api('GET', '/v1/generic-codes/' + group + '/options?locale=en', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot read the options of generic-code group ' + group + ': ' + show(r));
        return r.body;
      }
      """
    * def pickOption =
      """
      function(list, raw, what) {
        var opts = [];
        for (var i = 0; i < list.length; i++) { var o = list[i]; opts.push(o.valueCode + ' = ' + o.label); if (eq(o.valueCode, raw) || eq(o.label, raw)) return '' + o.valueCode; }
        fail(what + ' "' + raw + '" is not one the screen offers. Use one of: ' + opts.join(', '));
      }
      """

    # ── Row fields ────────────────────────────────────────────────────────────
    * def scDomain = strVal(td.scorecardDomain, 'LOAN_APPLICATION')
    # A row is identified by scorecardCode OR scorecardName (either may be blank, not both). The code stored on the
    # server always wins: it is the version key, so a row that names the scorecard never changes its code.
    * def scCodeCol = strVal(td.scorecardCode, null)
    * def scNameCol = strVal(td.scorecardName, null)
    * if (scCodeCol == null && scNameCol == null) fail('fill scorecardCode or scorecardName - one of them is needed to identify the scorecard')
    * def lookupKey = scCodeCol != null ? scCodeCol : scNameCol
    * def scCode = scCodeCol != null ? scCodeCol : scNameCol.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '')
    * def scName = scNameCol != null ? scNameCol : scCode
    # newName renames the scorecard on the next version (the code never changes - it is the version key).
    * def scNewName = strVal(td.newName, null)
    * def rowDescription = strVal(td.description, scName)
    * def attachTypes = splitList(strVal(td.attachToProductType, td.attachToProductTypes))
    * def rank = { ACTIVE: 4, SCHEDULED: 3, DRAFT: 2, INACTIVE: 1, SUPERSEDED: 0 }

    # ── Scorecard lookups (GET list returns every version and status) ─────────
    * def listScorecards =
      """
      function() {
        var r = api('GET', '/v1/config/scorecards?domain=' + scDomain, adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list scorecards: ' + show(r));
        return r.body;
      }
      """
    * def sameScorecard = function(sc, codeOrName) { return eq(sc.code, codeOrName) || eq(sc.name, codeOrName); }
    * def allVersions = function(codeOrName) { var all = listScorecards(); var out = []; for (var i = 0; i < all.length; i++) { if (sameScorecard(all[i], codeOrName)) out.push(all[i]); } return out; }
    * def findScorecard =
      """
      function(codeOrName) {
        var vs = allVersions(codeOrName);
        var best = null;
        for (var i = 0; i < vs.length; i++) {
          var rk = rank[vs[i].status] != null ? rank[vs[i].status] : -1;
          if (best == null || rk > best.rk || (rk == best.rk && Number(vs[i].version) > Number(best.sc.version))) best = { sc: vs[i], rk: rk };
        }
        return best == null ? null : best.sc;
      }
      """
    * def describeScorecards = function() { var all = listScorecards(); var out = []; for (var i = 0; i < all.length; i++) { if (all[i].status == 'ACTIVE' || all[i].status == 'SCHEDULED') out.push(all[i].code + ' = "' + all[i].name + '"'); } return out.join(', '); }
    * def scorecardCodeOf = function(id) { var all = listScorecards(); for (var i = 0; i < all.length; i++) { if (('' + all[i].id) == ('' + id)) return all[i].code; } return null; }

    # ── Attributes: catalogue matching and typed scoring bands ────────────────
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
        var raw = strVal(td.attributes, strVal(td.scorecardAttributes, null));
        if (raw == null) fail('column "attributes" is blank but is required to CREATE / AMEND a scorecard (JSON array of catalogue attributes with weightage and bands)');
        if (raw.charAt(0) == '[') {
          var parsed;
          try { parsed = JSON.parse(raw); } catch (e) { fail('attributes is not valid JSON: ' + e); }
          return parsed;
        }
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
    # The engine evaluates bands in its typed form (type RANGE | ENUM | WILDCARD with min/max/value). Untyped
    # ("legacy") bands are read differently: both bounds inclusive and an ABSENT bound counts as 0, so an
    # open-ended band such as {minValue: 200000, maxValue: null} would never match. Bands are therefore
    # always rewritten in the typed form: RANGE min <= v < max, contiguous, last band open-ended; STATIC
    # attributes become ENUM bands plus a mandatory WILDCARD fallback.
    * def normaliseBands =
      """
      function(a, method, dataType, resolver) {
        var src = a.bands;
        if (src == null && a.scoringBands != null) { src = (typeof a.scoringBands == 'string') ? JSON.parse(a.scoringBands) : a.scoringBands; }
        if (src == null) src = [];
        var out = [];
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
        for (var x = 0; x < out.length; x++) {
          for (var y = x + 1; y < out.length; y++) {
            var ax = out[x].min == null ? -1e300 : out[x].min;
            var ay = out[y].min == null ? -1e300 : out[y].min;
            if (ay < ax) { var t = out[x]; out[x] = out[y]; out[y] = t; }
          }
        }
        for (var g = 1; g < out.length; g++) {
          if (out[g].min != null && out[g - 1].max != null && out[g].min > out[g - 1].max) {
            note('scorecard attribute ' + a.attributeCode + ': closing band gap ' + out[g - 1].max + ' -> ' + out[g].min);
            out[g].min = out[g - 1].max;
          }
        }
        var open = false;
        for (var o = 0; o < out.length; o++) { if (out[o].min == null || out[o].max == null) open = true; }
        if (!open) { note('scorecard attribute ' + a.attributeCode + ': making the last band open-ended (max ' + out[out.length - 1].max + ' -> unlimited)'); out[out.length - 1].max = null; }
        if (wild != null) out.push(wild);
        return JSON.stringify(out);
      }
      """
    # STATIC bands on LOAN_PURPOSE are scored against the purpose CODE (001, 002 ...). The sheet may use the
    # dropdown label or the code; both are resolved through the LOAN_PURPOSE dropdown of any product type.
    * def isPurposeAttribute = function(row) { var c = row.attributeCode != null ? ('' + row.attributeCode).toUpperCase() : ''; var f = row.sourceField != null ? ('' + row.sourceField) : ''; return c == 'LOAN_PURPOSE' || f == 'loanPurpose'; }
    * def purposeResolver =
      """
      function() {
        var cached = karate.get('purposeDropdownCache');
        if (cached == null) {
          var types = listProductTypes();
          if (types.length == 0) fail('cannot read the LOAN_PURPOSE dropdown: no product type to read it through');
          var found = {};
          var list = [];
          for (var t = 0; t < types.length && list.length == 0; t++) {
            var code = '' + types[t].code;
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
        if (list.length == 0) fail('attributes resolved to no attributes');
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
          fail('scorecard attribute(s) not in the ' + scDomain + ' attribute catalogue: ' + missing.join(', ') + '. A scorecard can only be published with catalogued attributes. Available: ' + avail.join(', '));
        }
        var sum = 0;
        for (var s = 0; s < attrs.length; s++) sum += attrs[s].weight;
        if (Math.abs(sum - 100) > 0.001) attrs[0].weight = Math.round((attrs[0].weight + (100 - sum)) * 100) / 100;
        if (withWeight > 0 && Math.abs(total - 100) > 0.001) note('scorecard weightage in the sheet totals ' + total + '% - rescaled to 100%');
        return attrs;
      }
      """
    # Compares the live scorecard with what the sheet defines; null when they match, else the first difference.
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
        if (('' + live.name).trim() != ('' + payload.name).trim()) return 'name "' + live.name + '" vs sheet "' + payload.name + '"';
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
    * def deleteStaleDrafts =
      """
      function(keepId, code) {
        if (!(isTrue(td.deleteStaleDrafts) || isTrue(td.deleteStaleScorecardDrafts))) return;
        var vs = allVersions(code);
        var removed = 0;
        for (var i = 0; i < vs.length; i++) {
          var sc = vs[i];
          if (('' + sc.id) == ('' + keepId) || sc.status != 'DRAFT') continue;
          var d = api('DELETE', '/v1/config/scorecards/' + sc.id, adminHeader, null);
          if (d.status >= 200 && d.status < 300) { removed++; note('stale draft v' + sc.version + ' (id ' + sc.id + ') of ' + code + ' deleted'); }
          else note('WARNING: stale draft v' + sc.version + ' (id ' + sc.id + ') of ' + code + ' could not be deleted -> ' + show(d));
        }
        if (removed > 0) note(removed + ' stale draft version(s) of ' + code + ' removed');
      }
      """

    # ── Attach: the product types in attachToProductType, plus a version roll-forward on every ──
    #    sub-product row of those types that carries an older version of this same scorecard.
    * def attachScorecard =
      """
      function(scId, code) {
        if (attachTypes.length == 0) return [];
        var done = [];
        for (var i = 0; i < attachTypes.length; i++) {
          var pt = resolveProductType(attachTypes[i], 'attachToProductType names it');
          var changed = amendTypeConfig(pt.code, 'attach scorecard ' + code + ' (id ' + scId + ') to product type ' + pt.code, [pt.code, pt.id], function(cfg, cur) {
            if (('' + cur.scorecardId) == ('' + scId)) return false;
            cfg.scorecardId = scId;
            if (cfg.assessmentMethod == null) cfg.assessmentMethod = 'AUTO';
            return true;
          });
          var chk = typeConfigOf(pt.code);
          if (('' + chk.scorecardId) != ('' + scId)) fail('product type ' + pt.code + ' still carries scorecard ' + chk.scorecardId + ' after the amendment, expected ' + scId);
          var rolled = 0;
          var owned = configuredSubs(pt.code);
          for (var s = 0; s < owned.length; s++) {
            var sub = owned[s];
            var cur = subConfigOf(pt.code, sub);
            if (cur == null || cur.scorecardId == null || ('' + cur.scorecardId) == ('' + scId)) continue;
            var curCode = scorecardCodeOf(cur.scorecardId);
            if (curCode != null && !eq(curCode, code)) { note('sub-product ' + pt.code + '/' + sub + ' carries a different scorecard (' + curCode + ') - left alone'); continue; }
            amendSubConfig(pt.code, sub, 'roll scorecard ' + code + ' forward to id ' + scId + ' on sub-product ' + pt.code + '/' + sub, [pt.code, sub], function(cfg) { cfg.scorecardId = scId; return true; });
            rolled++;
          }
          done.push(pt.code + (changed ? ' (attached)' : ' (already attached)') + (rolled > 0 ? ' + ' + rolled + ' sub-product row(s) rolled forward' : ''));
        }
        return done;
      }
      """
    # ── Detach (DELETE): every product type / sub-product row that references any version ──────
    * def needsScorecard = function(m) { var u = m == null ? '' : ('' + m).toUpperCase(); return u == 'AUTO' || u == 'MANUAL_INTERNAL'; }
    * def detachScorecardEverywhere =
      """
      function(ids, code) {
        var inSet = function(id) { return id != null && ids.indexOf('' + id) >= 0; };
        var types = listProductTypes();
        var touched = [];
        for (var i = 0; i < types.length; i++) {
          var code = '' + types[i].code;
          var cfgRes = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/config', adminHeader, null);
          if (cfgRes.status != 200 || cfgRes.body == null) continue;
          if (inSet(cfgRes.body.scorecardId)) {
            amendTypeConfig(code, 'detach scorecard ' + code + ' from product type ' + code, [code, types[i].id], function(cfg) {
              cfg.scorecardId = null;
              if (needsScorecard(cfg.assessmentMethod)) { note('product type ' + code + ' used assessment ' + cfg.assessmentMethod + ' which needs a scorecard - switched to MANUAL'); cfg.assessmentMethod = 'MANUAL'; }
              return true;
            });
            touched.push(code);
          }
          var owned = configuredSubs(code);
          for (var s = 0; s < owned.length; s++) {
            var sub = owned[s];
            var cur = subConfigOf(code, sub);
            if (cur == null || !inSet(cur.scorecardId)) continue;
            amendSubConfig(code, sub, 'detach scorecard ' + code + ' from sub-product ' + code + '/' + sub, [code, sub], function(cfg) {
              cfg.scorecardId = null;
              if (needsScorecard(cfg.assessmentMethod)) cfg.assessmentMethod = 'MANUAL';
              return true;
            });
            touched.push(code + '/' + sub);
          }
        }
        return touched;
      }
      """

    # ── Execute ───────────────────────────────────────────────────────────────
    * def executeScorecard =
      """
      function() {
        if (action == 'DEACTIVATE') {
          var vsD = allVersions(lookupKey);
          if (vsD.length == 0) fail('scorecard "' + lookupKey + '" does not exist on ' + baseUrl + ' (no code or name matches) - nothing to deactivate. Existing: ' + describeScorecards());
          var codeD = '' + vsD[0].code;
          var idsD = []; var liveD = []; var draftsD = [];
          for (var i0 = 0; i0 < vsD.length; i0++) { idsD.push('' + vsD[i0].id); if (vsD[i0].status == 'ACTIVE' || vsD[i0].status == 'SCHEDULED') liveD.push(vsD[i0]); else if (vsD[i0].status == 'DRAFT') draftsD.push(vsD[i0]); }
          var retireDrafts = isTrue(td.deleteStaleDrafts) || isTrue(td.deleteStaleScorecardDrafts);
          if (liveD.length == 0 && (!retireDrafts || draftsD.length == 0)) { note('scorecard ' + codeD + ' has no ACTIVE / SCHEDULED version - already inactive'); return 'scorecard ' + codeD + ' already inactive (no live version)' + (draftsD.length > 0 ? ' | ' + draftsD.length + ' draft(s) left as they are (deleteStaleDrafts = true retires them)' : ''); }
          var touchedD = boolVal(td.detachFromProductTypes, true) ? detachScorecardEverywhere(idsD, codeD) : [];
          var retired = [];
          var toRetire = retireDrafts ? liveD.concat(draftsD) : liveD;
          for (var j0 = 0; j0 < toRetire.length; j0++) {
            var dr = api('POST', '/v1/config/scorecards/' + toRetire[j0].id + '/deactivate', adminHeader, {});
            if (dr.status < 200 || dr.status >= 300) fail('deactivating scorecard ' + codeD + ' v' + toRetire[j0].version + ' (id ' + toRetire[j0].id + ', ' + toRetire[j0].status + ') -> ' + show(dr));
            retired.push('v' + toRetire[j0].version + ' id ' + toRetire[j0].id + ' (' + toRetire[j0].status + ' -> INACTIVE)');
          }
          var afterD = findScorecard(lookupKey);
          if (afterD != null && (afterD.status == 'ACTIVE' || afterD.status == 'SCHEDULED')) fail('scorecard ' + codeD + ' is still ' + afterD.status + ' (id ' + afterD.id + ') after the deactivation');
          return 'scorecard ' + codeD + ' deactivated: ' + retired.join(', ') + (touchedD.length > 0 ? ' | detached from ' + touchedD.join(', ') : '') + (!retireDrafts && draftsD.length > 0 ? ' | ' + draftsD.length + ' draft(s) left as they are' : '');
        }
        if (action == 'DELETE') {
          var vs = allVersions(lookupKey);
          if (vs.length == 0) { note('scorecard "' + lookupKey + '" does not exist - nothing to delete'); return 'scorecard "' + lookupKey + '" not found (nothing to delete)'; }
          var code = '' + vs[0].code;
          var ids = []; var live = [];
          for (var i = 0; i < vs.length; i++) { ids.push('' + vs[i].id); if (vs[i].status == 'ACTIVE' || vs[i].status == 'SCHEDULED' || vs[i].status == 'DRAFT') live.push(vs[i]); }
          var touched = detachScorecardEverywhere(ids, code);
          var removed = [];
          for (var j = 0; j < live.length; j++) {
            var d = api('DELETE', '/v1/config/scorecards/' + live[j].id, adminHeader, null);
            if (d.status < 200 || d.status >= 300) fail('deactivating scorecard ' + code + ' v' + live[j].version + ' (id ' + live[j].id + ', ' + live[j].status + ') -> ' + show(d));
            removed.push('v' + live[j].version + ' id ' + live[j].id + ' (' + live[j].status + ' -> INACTIVE)');
          }
          var after = findScorecard(lookupKey);
          if (after != null && (after.status == 'ACTIVE' || after.status == 'SCHEDULED' || after.status == 'DRAFT')) fail('scorecard ' + code + ' is still ' + after.status + ' (id ' + after.id + ') after deletion');
          return 'scorecard ' + code + ': ' + (removed.length > 0 ? removed.join(', ') : 'no live version (already inactive)') + (touched.length > 0 ? ' | detached from ' + touched.join(', ') : '');
        }

        var code = scCode; var name = scName;
        var existing = findScorecard(lookupKey);
        if (action == 'AMEND' && existing == null) fail('scorecard "' + lookupKey + '" does not exist on ' + baseUrl + ' (no code or name matches) - nothing to amend. Use create=true, or fix scorecardCode / scorecardName. Existing: ' + describeScorecards());
        if (existing != null) {
          if (scCodeCol == null) note('scorecard "' + scNameCol + '" resolved to code ' + existing.code + ' (id ' + existing.id + ', ' + existing.status + ')');
          code = '' + existing.code;
          if (scNameCol == null) name = '' + existing.name;
          if (scNewName != null && scNewName != ('' + existing.name)) { note('scorecard ' + code + ' will be renamed "' + existing.name + '" -> "' + scNewName + '" on the new version'); name = scNewName; }
        } else if (scCodeCol == null) {
          note('scorecardCode is blank - new scorecard "' + scNameCol + '" will be created with code ' + code);
        }
        var catRes = api('GET', '/v1/config/scorecards/attribute-catalog?domain=' + scDomain, adminHeader, null);
        if (catRes.status != 200 || catRes.body == null) fail('cannot read the attribute catalogue: ' + show(catRes));
        var attrs = buildScorecardAttributes(catRes.body);
        var pass = numVal(req('passScore', 'to create / amend a scorecard (0-100)'), null);
        var reject = numVal(req('autoRejectScore', 'to create / amend a scorecard (0-100)'), null);
        if (pass == null || reject == null) fail('passScore / autoRejectScore must be numbers');
        if (pass <= reject) fail('passScore (' + pass + ') must be greater than autoRejectScore (' + reject + ')');
        var effective = isoDate(strVal(td.effectiveFrom, today), 'effectiveFrom');
        var basis = strVal(td.maxScoreBasis, 'BAND_MAX').toUpperCase();
        if (basis != 'BAND_MAX' && basis != 'FIXED_100') fail('maxScoreBasis must be BAND_MAX or FIXED_100, not ' + basis);
        var payload = {
          scorecardDomain: scDomain, code: code, name: name,
          description: rowDescription.length > 500 ? rowDescription.substring(0, 500) : rowDescription,
          passScore: pass, autoRejectScore: reject, maxScoreBasis: basis, effectiveFrom: effective, attributes: attrs
        };
        var id = null;
        var outcome = null;
        if (existing != null && (existing.status == 'ACTIVE' || existing.status == 'SCHEDULED')) {
          var drift = scorecardDrift(existing.id, payload);
          if (drift == null) {
            note('scorecard ' + code + ' is already ' + existing.status + ' (id ' + existing.id + ', v' + existing.version + ') and matches the sheet - nothing to change');
            id = existing.id; outcome = 'unchanged';
          } else {
            note('scorecard ' + code + ' is ' + existing.status + ' (id ' + existing.id + ') but differs from the sheet (' + drift + ') - publishing a new version');
          }
        }
        if (id == null) {
          if (existing != null && existing.status == 'DRAFT') {
            var u = api('PUT', '/v1/config/scorecards/' + existing.id, adminHeader, payload);
            if (u.status < 200 || u.status >= 300) fail('scorecard ' + code + ' draft update -> ' + show(u));
            id = existing.id;
            note('scorecard ' + code + ': draft ' + id + ' updated from the sheet');
          } else if (existing != null) {
            // Like the screen: an unactivated draft of this code is where the pending changes go ("Open draft vN");
            // editing the live version again would create a second draft alongside it.
            var pending = null;
            var vsA = allVersions(code);
            for (var q0 = 0; q0 < vsA.length; q0++) { if (vsA[q0].status == 'DRAFT' && (pending == null || Number(vsA[q0].version) > Number(pending.version))) pending = vsA[q0]; }
            if (pending != null) {
              var u3 = api('PUT', '/v1/config/scorecards/' + pending.id, adminHeader, payload);
              if (u3.status < 200 || u3.status >= 300) fail('scorecard ' + code + ' existing draft v' + pending.version + ' (id ' + pending.id + ') update -> ' + show(u3));
              id = pending.id;
              note('scorecard ' + code + ': existing draft v' + pending.version + ' (id ' + id + ') reused and updated from the sheet');
            } else {
              var cl = api('POST', '/v1/config/scorecards/' + existing.id + '/clone-as-draft', adminHeader, {});
              if (cl.status < 200 || cl.status >= 300 || cl.body == null || cl.body.id == null) fail('scorecard ' + code + ' is ' + existing.status + ' and cloning it as a new draft failed: ' + show(cl));
              id = cl.body.id;
              var u2 = api('PUT', '/v1/config/scorecards/' + id, adminHeader, payload);
              if (u2.status < 200 || u2.status >= 300) fail('scorecard ' + code + ' new draft update -> ' + show(u2));
              note('scorecard ' + code + ': new draft ' + id + ' cloned from ' + existing.status + ' version ' + existing.id);
            }
          } else {
            var c = api('POST', '/v1/config/scorecards?domain=' + scDomain, adminHeader, payload);
            if (c.status < 200 || c.status >= 300) fail('scorecard ' + code + ' create -> ' + show(c) + ' | payload ' + karate.pretty(payload));
            if (c.body != null && c.body.id != null) id = c.body.id;
            else { var again = findScorecard(code); if (again == null) again = findScorecard(lookupKey); if (again != null) id = again.id; }
            if (id == null) fail('scorecard ' + code + ' was created but cannot be found by code/name afterwards');
            note('scorecard ' + code + ' created (id ' + id + ')');
          }
          var v = api('GET', '/v1/config/scorecards/' + id + '/validation', adminHeader, null);
          if (v.status == 200 && v.body != null && v.body.length > 0) note('scorecard ' + code + ' validation findings: ' + karate.pretty(v.body));
          var p = api('POST', '/v1/config/scorecards/' + id + '/publish?effectiveFrom=' + effective, adminHeader, {});
          if (p.status < 200 || p.status >= 300) fail('scorecard ' + code + ' (id ' + id + ') could not be published -> ' + show(p));
          outcome = existing == null ? 'created' : 'new version published';
        }
        var g = api('GET', '/v1/config/scorecards/' + id, adminHeader, null);
        var st = (g.status == 200 && g.body != null) ? g.body.status : null;
        if (st != 'ACTIVE' && st != 'SCHEDULED') fail('scorecard ' + code + ' (id ' + id + ') is ' + st + ' after publish, expected ACTIVE');
        deleteStaleDrafts(id, code);
        var attached = attachScorecard(id, code);
        return 'scorecard ' + code + ' id=' + id + ' v' + g.body.version + ' ' + st + ' (' + outcome + ') pass=' + g.body.passScore + ' reject=' + g.body.autoRejectScore + ' ' + g.body.maxScoreBasis + ' attributes=' + (g.body.attributes != null ? g.body.attributes.length : 0) + (attached.length > 0 ? ' | attached to: ' + attached.join(', ') : '');
      }
      """
    * def summary = executeScorecard()
    * note('SCORECARD ' + action + ' COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(karate.get('adminHeaderVal'))
