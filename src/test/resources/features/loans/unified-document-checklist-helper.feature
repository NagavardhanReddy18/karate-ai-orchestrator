@ignore
Feature: Unified Document Checklist Helper - CREATE, AMEND, DELETE for the Document_Checklists sheet

  # ── HOW A ROW IS INTERPRETED ───────────────────────────────────────────────────────────────
  #   CREATE : make the record match the sheet. Missing -> created; present -> amended when it differs.
  #   AMEND  : same as CREATE but the record MUST already exist (a typo in the name fails the row).
  #   DELETE : remove the record; anything that references it is detached first.
  # Every governed change (HTTP 202 / ChangeRequest) is approved by a four-eyes checker and committed.
  # Server rules that shape this file were verified against the backend sources on 2026-09-17.

  Scenario: Execute Single Document Checklist Row
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
    * def rowTag = '[CHECKLIST ' + action + ' ' + strVal(td.checklistId, strVal(td.checklistName, 'row')) + ']'
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

    * def canConfigure = function(header) { var r = api('GET', '/v1/master-data/document-checklists?size=1', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canConfigure(h)) return { user: excelAdminUser, header: h, pass: excelAdminPass, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot configure document checklists (403) - falling back to default admin ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
        if (h2 != null && canConfigure(h2)) return { user: defaultAdminUsername, header: h2, pass: defaultAdminPassword, source: 'karate-config' };
        if (h2 != null) logout(h2);
        tried.push(defaultAdminUsername);
        fail('no admin account can configure document checklists. Tried: ' + tried.join(', '));
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
    * def checklistName = req('checklistName', 'on every document checklist row (Checklist Name on the New Checklist form)')
    # newName renames an existing checklist (the row is still found by checklistName).
    * def clNewName = strVal(td.newName, null)
    * def rowDescription = strVal(td.description, null)
    * def checklistActive = boolVal(td.active, true)
    * def rawCategories = parseJson('categories', false)
    * def rawDocTypes = parseJson('documentTypes', false)
    * def createMissingCategories = boolVal(td.createMissingCategories, true)
    * def createMissingDocTypes = boolVal(td.createMissingDocTypes, true)
    * def attachTypes = splitList(td.attachToProductTypes)
    * def attachSubs = splitList(td.attachToSubProducts)
    * def flag = function(o, k) { return o != null && o[k] != null && isTrue(o[k]); }
    * def CL_HINTS = ['DOC_CHECKLIST', 'DOCUMENT_CHECKLIST', 'DocumentChecklist']

    # ── Checklist lookups (GET list: search = LIKE on name, size capped at 100) ─
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
    * def readChecklist = function(id) { var g = api('GET', '/v1/master-data/document-checklists/' + id, adminHeader, null); return (g.status == 200 && g.body != null) ? g.body : null; }

    # ── Sections from the sheet (category / phase / doc types) ───────────────
    * def buildSections =
      """
      function() {
        var rawSections = parseJson('sections', true);
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
          out.push({ phase: phase, category: cat, noOfDocsReq: reqd, noOfCopies: numVal(s.noOfCopies, 1), docTypes: dts });
        }
        var seen = {};
        for (var k = 0; k < out.length; k++) {
          var key = (out[k].phase != null ? out[k].phase.toUpperCase() : '') + ':' + out[k].category.toLowerCase();
          if (seen[key]) fail('sections uses category "' + out[k].category + '" twice in phase ' + (out[k].phase != null ? out[k].phase : '(all)') + ' - each category can only be used once per phase');
          seen[key] = true;
        }
        return out;
      }
      """
    * def resolvePhase =
      """
      function(p, phaseOptions) {
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

    # ── Document categories = generic-code group DOCCAT (values are the codes the checklist stores) ─
    * def doccatGroup =
      """
      function() {
        var r = api('GET', '/v1/master-data/generic-code-groups?search=DOCCAT&size=50', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot read the generic-code groups to find DOCCAT: ' + show(r));
        var list = r.body.content != null ? r.body.content : r.body;
        for (var i = 0; i < list.length; i++) { if (list[i].groupCode == 'DOCCAT') return list[i]; }
        fail('the document-category group DOCCAT does not exist on ' + baseUrl);
      }
      """
    * def listCategories =
      """
      function(group) {
        var r = api('GET', '/v1/master-data/generic-code-groups/' + group.id + '/values', adminHeader, null);
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
    * def setupCategories =
      """
      function(sections) {
        var needed = []; var seen = {};
        var add = function(c) { var s = strVal(c, null); if (s == null) return; if (seen[s.toLowerCase()]) return; seen[s.toLowerCase()] = true; needed.push(s); };
        for (var i = 0; i < rawCategories.length; i++) add(rawCategories[i].code != null ? rawCategories[i].code : rawCategories[i].valueCode);
        for (var j = 0; j < rawDocTypes.length; j++) add(rawDocTypes[j].category != null ? rawDocTypes[j].category : rawDocTypes[j].docCategoryCode);
        for (var k = 0; k < sections.length; k++) add(sections[k].category);
        var group = doccatGroup();
        var existing = listCategories(group);
        var made = [];
        for (var n = 0; n < needed.length; n++) {
          var code = needed[n];
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
          var body = { groupId: group.id, valueCode: spec.code, sortOrder: 10 * (existing.length + made.length + 1), active: true,
                       locales: [{ locale: 'en', name: spec.name, description: spec.description != null ? spec.description : ('Created by Unified-Configuration-Automation.xlsx (' + strVal(td.checklistId, 'row') + ')') }] };
          var send = (function(b) { return function() { return api('POST', '/v1/master-data/generic-code-groups/' + group.id + '/values', adminHeader, b); }; })(body);
          governed('create document category ' + spec.code, send(), send, ['GENERIC_CODE'], [spec.code]);
          made.push(spec.code);
        }
        var after = listCategories(group);
        var canon = {};
        for (var m = 0; m < needed.length; m++) { var c2 = findCategory(after, needed[m]); if (c2 == null) fail('document category ' + needed[m] + ' is still missing after setup'); canon[needed[m].toLowerCase()] = '' + c2.valueCode; }
        return { created: made, canon: canon };
      }
      """

    # ── Document types = rows of /v1/master-data/document-configs (documentType is the code stored) ─
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
    * def doctypeGroup =
      """
      function() {
        var r = api('GET', '/v1/master-data/generic-code-groups?search=DOCTYPE&size=50', adminHeader, null);
        if (r.status != 200 || r.body == null) return null;
        var list = r.body.content != null ? r.body.content : r.body;
        for (var i = 0; i < list.length; i++) { if (list[i].groupCode == 'DOCTYPE') return list[i]; }
        return null;
      }
      """
    * def ensureDocTypeLabel =
      """
      function(group, code, name) {
        if (group == null) return;
        var r = api('GET', '/v1/master-data/generic-code-groups/' + group.id + '/values?search=' + encodeURIComponent(code), adminHeader, null);
        if (r.status != 200 || r.body == null) return;
        var list = r.body.content != null ? r.body.content : r.body;
        for (var i = 0; i < list.length; i++) { if (eq(list[i].valueCode, code)) return; }
        var body = { groupId: group.id, valueCode: code, sortOrder: 10, active: true, locales: [{ locale: 'en', name: name, description: 'Created by Unified-Configuration-Automation.xlsx' }] };
        var send = function() { return api('POST', '/v1/master-data/generic-code-groups/' + group.id + '/values', adminHeader, body); };
        governed('create document-type label ' + code + ' (DOCTYPE)', send(), send, ['GENERIC_CODE'], [code]);
      }
      """
    * def setupDocTypes =
      """
      function(sections, canonCat) {
        var needed = []; var seen = {};
        var add = function(cat, code) { var c = strVal(cat, null); var s = strVal(code, null); if (c == null || s == null) return; var key = canonCat(c).toLowerCase() + '|' + s.toLowerCase(); if (seen[key]) return; seen[key] = true; needed.push({ category: canonCat(c), code: s }); };
        for (var i = 0; i < rawDocTypes.length; i++) add(rawDocTypes[i].category != null ? rawDocTypes[i].category : rawDocTypes[i].docCategoryCode, rawDocTypes[i].code != null ? rawDocTypes[i].code : rawDocTypes[i].documentType);
        for (var j = 0; j < sections.length; j++) { for (var k = 0; k < sections[j].docTypes.length; k++) add(sections[j].category, sections[j].docTypes[k].code); }
        var existing = listDocTypes();
        var group = null;
        var made = [];
        for (var n = 0; n < needed.length; n++) {
          var need = needed[n];
          var hit = findDocType(existing, need.category, need.code);
          if (hit != null) {
            if (hit.active == false) note('WARNING: document type ' + hit.documentType + ' under ' + need.category + ' exists but is INACTIVE');
            continue;
          }
          var spec = null;
          for (var s = 0; s < rawDocTypes.length; s++) {
            var t = rawDocTypes[s];
            var tc = strVal(t.category != null ? t.category : t.docCategoryCode, null);
            var cc = strVal(t.code != null ? t.code : t.documentType, null);
            if (tc != null && eq(canonCat(tc), need.category) && eq(cc, need.code)) spec = { category: need.category, code: cc, name: strVal(t.name != null ? t.name : t.documentName, cc), required: flag(t, 'required') };
          }
          if (spec == null && !createMissingDocTypes) {
            var names = []; for (var e = 0; e < existing.length; e++) { if (eq(existing[e].docCategoryCode, need.category)) names.push(existing[e].documentType); }
            fail('document type "' + need.code + '" does not exist under category ' + need.category + ' and createMissingDocTypes=false. Describe it in the documentTypes column, or use one of: ' + (names.length > 0 ? names.join(', ') : '(none configured for this category yet)'));
          }
          if (spec == null) spec = { category: need.category, code: need.code, name: need.code, required: false };
          if (group == null) group = doctypeGroup();
          ensureDocTypeLabel(group, spec.code, spec.name);
          var body = { documentType: spec.code, docCategoryCode: spec.category, required: spec.required, active: true };
          var send = (function(b) { return function() { return api('POST', '/v1/master-data/document-configs', adminHeader, b); }; })(body);
          governed('create document type ' + spec.code + ' under ' + spec.category, send(), send, ['DOC_', 'DOCUMENT'], [spec.code]);
          made.push(spec.category + '/' + spec.code);
        }
        var after = listDocTypes();
        var canon = {};
        for (var m = 0; m < needed.length; m++) {
          var d = findDocType(after, needed[m].category, needed[m].code);
          if (d == null) fail('document type ' + needed[m].code + ' under ' + needed[m].category + ' is still missing after setup');
          canon[needed[m].category.toLowerCase() + '|' + needed[m].code.toLowerCase()] = '' + d.documentType;
        }
        return { created: made, canon: canon };
      }
      """

    # ── Desired record, comparison, attach / detach ───────────────────────────
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
    * def attachChecklist =
      """
      function(checklistId) {
        var done = [];
        for (var i = 0; i < attachTypes.length; i++) {
          var pt = resolveProductType(attachTypes[i], 'attachToProductTypes names it');
          var changed = amendTypeConfig(pt.code, 'attach checklist ' + checklistId + ' (' + checklistName + ') to product type ' + pt.code, [pt.code, pt.id], function(cfg, cur) {
            if (('' + cur.documentChecklistId) == ('' + checklistId)) return false;
            cfg.documentChecklistId = checklistId;
            return true;
          });
          var chk = typeConfigOf(pt.code);
          if (('' + chk.documentChecklistId) != ('' + checklistId)) fail('product type ' + pt.code + ' amendment was committed but its configuration carries checklist ' + chk.documentChecklistId + ', expected ' + checklistId);
          done.push(pt.code + (changed ? ' (attached)' : ' (already attached)'));
        }
        for (var s = 0; s < attachSubs.length; s++) {
          var kv = attachSubs[s].split(':');
          if (kv.length != 2 || kv[0].trim() == '' || kv[1].trim() == '') fail('attachToSubProducts entry "' + attachSubs[s] + '" must look like PRODUCT_TYPE:SUB_PRODUCT_CODE');
          var pt2 = resolveProductType(kv[0].trim(), 'attachToSubProducts names it');
          var sub = resolveSubProduct(pt2.code, kv[1].trim());
          var changed2 = amendSubConfig(pt2.code, sub, 'attach checklist ' + checklistId + ' to sub-product ' + pt2.code + '/' + sub, [pt2.code, sub], function(cfg, cur) {
            if (('' + cur.documentChecklistId) == ('' + checklistId)) return false;
            cfg.documentChecklistId = checklistId;
            return true;
          });
          var chk2 = subConfigOf(pt2.code, sub);
          if (chk2 == null || ('' + chk2.documentChecklistId) != ('' + checklistId)) fail('sub-product ' + pt2.code + '/' + sub + ' config was committed but carries checklist ' + (chk2 == null ? null : chk2.documentChecklistId) + ', expected ' + checklistId);
          done.push(pt2.code + '/' + sub + (changed2 ? ' (attached)' : ' (already attached)'));
        }
        return done;
      }
      """
    # The server hard-deletes a checklist without checking who references it, and a dangling id then
    # breaks every later save of that product configuration - so every reference is removed first.
    * def detachChecklistEverywhere =
      """
      function(checklistId) {
        var types = listProductTypes();
        var touched = [];
        for (var i = 0; i < types.length; i++) {
          var code = '' + types[i].code;
          var cfgRes = api('GET', '/v1/product-types/' + encodeURIComponent(code) + '/config', adminHeader, null);
          if (cfgRes.status != 200 || cfgRes.body == null) continue;
          if (('' + cfgRes.body.documentChecklistId) == ('' + checklistId)) {
            amendTypeConfig(code, 'detach checklist ' + checklistId + ' from product type ' + code, [code, types[i].id], function(cfg) { cfg.documentChecklistId = null; return true; });
            touched.push(code);
          }
          var owned = configuredSubs(code);
          for (var s = 0; s < owned.length; s++) {
            var cur = subConfigOf(code, owned[s]);
            if (cur == null || ('' + cur.documentChecklistId) != ('' + checklistId)) continue;
            amendSubConfig(code, owned[s], 'detach checklist ' + checklistId + ' from sub-product ' + code + '/' + owned[s], [code, owned[s]], function(cfg) { cfg.documentChecklistId = null; return true; });
            touched.push(code + '/' + owned[s]);
          }
        }
        return touched;
      }
      """
    * def wizardCheck =
      """
      function(checklistId) {
        var out = [];
        for (var i = 0; i < attachTypes.length; i++) {
          var pt = resolveProductType(attachTypes[i]);
          var lp = subProductsOf(pt.code);
          var first = lp.length > 0 ? lp[0].productCode : null;
          if (first == null) { out.push(pt.code + ': no sub-product linked yet, wizard lookup skipped'); continue; }
          var w = api('GET', '/v1/product-config/checklist?productTypeCode=' + encodeURIComponent(pt.code) + '&productCode=' + encodeURIComponent(first), adminHeader, null);
          if (w.status != 200 || w.body == null || ('' + w.body.id) != ('' + checklistId)) fail('VERIFY: the wizard lookup for ' + pt.code + '/' + first + ' returns ' + (w.status == 200 ? 'checklist ' + w.body.id : show(w)) + ', expected checklist ' + checklistId);
          out.push(pt.code + '/' + first + ': wizard sees checklist ' + w.body.id);
        }
        return out;
      }
      """

    # ── Execute ───────────────────────────────────────────────────────────────
    * def executeChecklist =
      """
      function() {
        var existing = findChecklist();
        if (action == 'DELETE') {
          if (existing == null) { note('checklist "' + checklistName + '" does not exist - nothing to delete'); return 'checklist "' + checklistName + '" not found (nothing to delete)'; }
          var touched = detachChecklistEverywhere(existing.id);
          var sendDel = function() { return api('DELETE', '/v1/master-data/document-checklists/' + existing.id, adminHeader, null); };
          governed('delete checklist ' + existing.id + ' (' + checklistName + ')', sendDel(), sendDel, CL_HINTS, [checklistName, existing.id]);
          if (findChecklist() != null) fail('checklist "' + checklistName + '" (id ' + existing.id + ') is still listed after its deletion was committed');
          return 'checklist ' + existing.id + ' "' + checklistName + '" deleted' + (touched.length > 0 ? ' | detached from ' + touched.join(', ') : '');
        }
        if (action == 'AMEND' && existing == null) fail('checklist "' + checklistName + '" does not exist on ' + baseUrl + ' - nothing to amend (use create=true, or fix checklistName)');

        var sections = buildSections();
        var phaseOptions = genericOptions('DOC_PHASE');
        for (var i = 0; i < sections.length; i++) sections[i].phase = resolvePhase(sections[i].phase, phaseOptions);
        var catResult = setupCategories(sections);
        var canonCat = function(code) { var c = catResult.canon[('' + code).trim().toLowerCase()]; return c != null ? c : code; };
        for (var c = 0; c < sections.length; c++) sections[c].category = canonCat(sections[c].category);
        var dtResult = setupDocTypes(sections, canonCat);
        for (var d = 0; d < sections.length; d++) { for (var j = 0; j < sections[d].docTypes.length; j++) { var cc = dtResult.canon[sections[d].category.toLowerCase() + '|' + sections[d].docTypes[j].code.toLowerCase()]; if (cc != null) sections[d].docTypes[j].code = cc; } }
        note('document categories: ' + (catResult.created.length > 0 ? 'created ' + catResult.created.join(', ') : 'all present') + ' | document types: ' + (dtResult.created.length > 0 ? 'created ' + dtResult.created.join(', ') : 'all present'));

        var details = [];
        for (var k = 0; k < sections.length; k++) { var s = sections[k]; details.push({ docCategory: s.category, phaseId: s.phase, noOfDocsReq: s.noOfDocsReq, noOfCopies: s.noOfCopies, docTypes: s.docTypes }); }
        var desired = { name: (existing != null && clNewName != null) ? clNewName : checklistName, description: rowDescription, active: checklistActive, details: details };
        if (existing != null && clNewName != null && clNewName != ('' + existing.name)) note('checklist ' + existing.id + ' will be renamed "' + existing.name + '" -> "' + clNewName + '"');

        var outcome = null;
        var id = null;
        if (existing != null) {
          var full = readChecklist(existing.id);
          if (full != null) existing = full;
          id = existing.id;
          if (normalise(existing) == normalise(desired) && ('' + existing.name) == desired.name && ('' + (existing.description == null ? '' : existing.description)) == ('' + (rowDescription == null ? (existing.description == null ? '' : existing.description) : rowDescription))) {
            note('checklist ' + id + ' "' + existing.name + '" already matches the sheet - nothing to change');
            outcome = 'unchanged';
          } else {
            note('checklist ' + id + ' "' + existing.name + '" differs from the sheet - requesting an amendment');
            if (desired.description == null) desired.description = existing.description;
            var send = function() { return api('PUT', '/v1/master-data/document-checklists/' + id, adminHeader, desired); };
            governed('amend checklist ' + id + ' (' + checklistName + ')', send(), send, CL_HINTS, [checklistName, id]);
            outcome = 'amended';
          }
        } else {
          var create = function() { return api('POST', '/v1/master-data/document-checklists', adminHeader, desired); };
          governed('create checklist (' + checklistName + ')', create(), create, CL_HINTS, [checklistName]);
          var made = null;
          for (var w = 0; w < 30 && made == null; w++) { made = findChecklist(); if (made == null) java.lang.Thread.sleep(1000); }
          if (made == null) fail('the change request for checklist "' + checklistName + '" was committed but no checklist with that name is listed afterwards');
          id = made.id;
          outcome = 'created';
        }
        var g = readChecklist(id);
        if (g == null) fail('VERIFY: checklist ' + id + ' cannot be read back');
        if (('' + g.name) != desired.name) fail('VERIFY: checklist ' + id + ' is named "' + g.name + '" after ' + outcome + ', expected "' + desired.name + '"');
        if (normalise(g) != normalise(desired)) fail('VERIFY: checklist ' + id + ' does not match the sheet after ' + outcome + '. Server: ' + karate.pretty(g) + ' Sheet: ' + karate.pretty(desired));
        var parts = [];
        for (var p = 0; p < g.details.length; p++) { var dd = g.details[p]; var codes = []; for (var q = 0; dd.docTypes != null && q < dd.docTypes.length; q++) codes.push(dd.docTypes[q].code + (dd.docTypes[q].mandatory ? '*' : '')); parts.push((dd.phaseId != null ? dd.phaseId : 'ALL') + '/' + dd.docCategory + ' req=' + dd.noOfDocsReq + ' [' + codes.join(', ') + ']'); }
        var attached = attachChecklist(id);
        var wizard = wizardCheck(id);
        return 'checklist ' + id + ' "' + g.name + '" ' + outcome + ' active=' + g.active + ' | ' + parts.join(' | ') + (attached.length > 0 ? ' | attached to: ' + attached.join(', ') : '') + (wizard.length > 0 ? ' | ' + wizard.join('; ') : '');
      }
      """
    * def summary = executeChecklist()
    * note('DOCUMENT CHECKLIST ' + action + ' COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(karate.get('adminHeaderVal'))
