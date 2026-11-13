@ignore
Feature: Unified Product Type Helper - CREATE, AMEND, DELETE (with cascade), DEACTIVATE and link amendments for the Product_Types sheet

  # ── HOW A ROW IS INTERPRETED ───────────────────────────────────────────────────────────────
  #   CREATE     : make the record match the sheet. Missing -> created; present -> amended when it differs.
  #   AMEND      : same as CREATE but the record MUST already exist (a typo in the name fails the row).
  #                With _mode = LINKS (CRUD-Configurations workbook) or any attach* / detach* column filled, the
  #                row only attaches / detaches sub-products, purposes, charges, the document checklist and the scorecard.
  #   DELETE     : remove the record; anything that references it is detached first (cascade).
  #   DEACTIVATE : what the screen's "Deactivate" button does - DELETE /v1/product-types/{id}, a change request that a
  #                supervisor / checker approves. Nothing linked is touched unless detachEverything = true.
  # Every governed change (HTTP 202 / ChangeRequest) is approved by a four-eyes checker and committed.
  # Server rules that shape this file were verified against the backend sources on 2026-09-17.

  Scenario: Execute Single Product Type Row
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
    * def rowTag = '[PRODUCT-TYPE ' + action + ' ' + strVal(td.configId, strVal(td.newProductTypeCode, strVal(td.productTypeCode, 'row'))) + ']'
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

    * def canConfigure = function(header) { var r = api('GET', '/v1/product-types', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canConfigure(h)) return { user: excelAdminUser, header: h, pass: excelAdminPass, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot configure product types (403) - falling back to default admin ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
        if (h2 != null && canConfigure(h2)) return { user: defaultAdminUsername, header: h2, pass: defaultAdminPassword, source: 'karate-config' };
        if (h2 != null) logout(h2);
        tried.push(defaultAdminUsername);
        fail('no admin account can configure product types. Tried: ' + tried.join(', '));
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
    # A row is identified by newProductTypeCode OR newProductTypeName (the label shown in the UI). With only a name,
    # the existing type's code is taken from the server; a CREATE with only a name derives the code from it.
    # The CRUD-Configurations workbook names the columns productTypeCode / productTypeName.
    * def ptCodeCol = strVal(td.newProductTypeCode, strVal(td.productTypeCode, null))
    * def ptNameCol = strVal(td.newProductTypeName, strVal(td.productTypeName, null))
    * if (ptCodeCol == null && ptNameCol == null) fail('fill newProductTypeCode or newProductTypeName - one of them is needed to identify the product type')
    * def ptByName = (ptCodeCol == null) ? findProductType(ptNameCol) : null
    * if (ptCodeCol == null && ptByName != null) note('product type "' + ptNameCol + '" resolved to code ' + ptByName.code + ' (id ' + ptByName.id + ')')
    * def ptCode = ptCodeCol != null ? ptCodeCol : (ptByName != null ? '' + ptByName.code : ptNameCol.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, ''))
    * if (ptCodeCol == null && ptByName == null && action != 'DELETE') note('newProductTypeCode is blank and no type is labelled "' + ptNameCol + '" - a CREATE will use code ' + ptCode)
    * def ptPath = encodeURIComponent(ptCode)
    # newName renames the type (its label, what the screen shows); the code is read-only on the Edit dialog.
    * def ptNewName = strVal(td.newName, null)
    * def ptName = ptNewName != null ? ptNewName : ptNameCol
    * def rowDescription = strVal(td.description, null)
    # Creation columns: the setup workbook names them newProductCategory / newWorkflowKey / selectedProductCode /
    # linkedPurposes / attachScorecardToProduct; the amendment workbook productCategory / workflowKey / subProducts /
    # purposes / scorecardToSubProducts. Both spellings are accepted.
    * def ptCategory = strVal(td.newProductCategory, strVal(td.productCategory, 'RETAIL')).toUpperCase().replace(/[ -]+/g, '_')
    * def wfKeyWanted = strVal(td.newWorkflowKey, strVal(td.workflowKey, null))
    * def assessmentWanted = strVal(td.assessmentMethod, null) == null ? null : strVal(td.assessmentMethod, null).toUpperCase()
    * def routingWanted = strVal(td.routingMethod, null) == null ? null : strVal(td.routingMethod, null).toUpperCase()
    * def roleList = splitList(td.roleAccessList)
    * def productCodes = splitList(strVal(td.selectedProductCode, td.subProducts))
    * def purposeCodes = splitList(strVal(td.linkedPurposes, td.purposes))
    * def attachToProducts = isTrue(td.attachScorecardToProduct) || isTrue(td.scorecardToSubProducts)
    * def removeUnlisted = isTrue(td.removeUnlistedPurposes)
    * def verifyOfficer = isTrue(td.verifyOfficerSubmittable)
    * def officerUserForCheck = strVal(td.officerUsername, defaultOfficerUsername)
    * def officerPassForCheck = strVal(td.officerUsername, null) != null ? strVal(td.officerPassword, defaultOfficerPassword) : defaultOfficerPassword
    * def scDomain = strVal(td.scorecardDomain, 'LOAN_APPLICATION')
    # The scorecard a new type is created with: newScorecardCode / scorecardCode (setup workbook) or attachScorecard (CRUD
    # workbook, where attach* columns are the only link columns and also serve the create row).
    * def scWantedCode = strVal(td.newScorecardCode, strVal(td.scorecardCode, action == 'CREATE' ? strVal(td.attachScorecard, null) : null))
    * def needsScorecard = function(m) { var u = m == null ? '' : ('' + m).toUpperCase(); return u == 'AUTO' || u == 'MANUAL_INTERNAL'; }
    * def codeOf = function(o) { return '' + (o.valueCode != null ? o.valueCode : (o.code != null ? o.code : o.label)); }

    # ── Scorecard by code / name: must already be PUBLISHED (created by the Scorecards sheet) ───
    * def requireActiveScorecard =
      """
      function(codeOrName, what) {
        var r = api('GET', '/v1/config/scorecards?domain=' + scDomain, adminHeader, null);
        if (r.status != 200) fail('cannot list scorecards: ' + show(r));
        var best = null; var seen = [];
        var rank = { ACTIVE: 4, SCHEDULED: 3, DRAFT: 2, INACTIVE: 1, SUPERSEDED: 0 };
        for (var i = 0; i < r.body.length; i++) {
          var sc = r.body[i];
          if (eq(sc.code, codeOrName) || eq(sc.name, codeOrName)) {
            seen.push(sc.code + ' (' + sc.status + ', id ' + sc.id + ')');
            var rk = rank[sc.status] != null ? rank[sc.status] : -1;
            if (best == null || rk > best.rank || (rk == best.rank && Number(sc.version) > Number(best.sc.version))) best = { sc: sc, rank: rk };
          }
        }
        if (best == null) fail(what + ': scorecard "' + codeOrName + '" does not exist on this server. Create it in the Scorecards sheet (create=true) first, or in the UI.');
        if (best.sc.status != 'ACTIVE' && best.sc.status != 'SCHEDULED') fail(what + ': scorecard "' + codeOrName + '" exists but is not published (' + seen.join(', ') + '). Publish it via the Scorecards sheet first.');
        return best.sc.id;
      }
      """
    * def resolveWorkflowKey =
      """
      function(wanted) {
        var r = api('GET', '/v1/product-types/workflow-options', adminHeader, null);
        if (r.status != 200) fail('cannot list published workflows: ' + show(r));
        var keys = [];
        for (var i = 0; i < r.body.length; i++) {
          var k = '' + r.body[i].workflowKey;
          keys.push(k + ' (' + r.body[i].name + ')');
          if (k == wanted) return k;
        }
        for (var j = 0; j < r.body.length; j++) {
          var k2 = '' + r.body[j].workflowKey;
          if (k2.toLowerCase() == ('' + wanted).toLowerCase()) { note('workflow key ' + wanted + ' matched case-insensitively to ' + k2); return k2; }
        }
        fail('newWorkflowKey "' + wanted + '" is not a published workflow on ' + baseUrl + '. Published workflows: ' + keys.join(', '));
      }
      """
    * def getSchema = function() { return api('GET', '/v1/product-types/' + ptPath + '/schema', adminHeader, null); }
    # A deactivated type keeps its code, and the code is unique in the database, so a CREATE of the same code fails at
    # commit (409 DUPLICATE). The API cannot list inactive types, so the id is read from the database (db.properties:
    # 'test' connection for 9190, default for 9090) and the type is reactivated with PUT /v1/product-types/{id}
    # (productType.active = true - the same amendment the Edit dialog sends), which the checker approves.
    * def findInactiveTypeId =
      """
      function(code) {
        var sql = "select id from beyondlo.blo_prod_types where code = '" + code.replace(/'/g, "''") + "' and active = false order by id desc limit 1";
        var prefix = ('' + baseUrl).indexOf('9190') >= 0 ? 'test: ' : '';
        try {
          var id = Java.type('com.ird.beyond.lo.test.util.DbSupport').queryScalar(prefix + sql);
          return (id == null || ('' + id).trim() == '' || ('' + id) == 'null') ? null : ('' + id).trim();
        } catch (e) { note('WARNING: could not look the inactive product type up in the database (' + e + ') - a CREATE of an existing but deactivated code will fail with 409'); return null; }
      }
      """
    * def reactivateType =
      """
      function(id, wf, assessment, routing, scorecardId) {
        var curRes = api('GET', '/v1/product-types/' + ptPath + '/config', adminHeader, null);
        var cur = (curRes.status == 200 && curRes.body != null) ? curRes.body : {};
        var cfg = baseTypeConfig(ptCode, cur);
        cfg.assessmentMethod = assessment; cfg.routingMethod = routing;
        if (scorecardId != null) cfg.scorecardId = scorecardId;
        if (needsScorecard(cfg.assessmentMethod) && cfg.scorecardId == null) fail('assessmentMethod ' + assessment + ' needs a scorecard to reactivate ' + ptCode + ': set scorecardCode to a published scorecard');
        var sheetCharges = chargesFromSheet();
        if (sheetCharges != null) cfg.charges = sheetCharges;
        var pt = { id: Number(id), code: ptCode, label: ptName != null ? ptName : ptCode, description: rowDescription != null ? rowDescription : (ptName != null ? ptName : ptCode),
                   icon: 'credit_card', category: (ptCategory == 'OVERDRAFT' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'OVERDRAFT' : 'LOAN',
                   customerType: (ptCategory == 'ENTERPRISE' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'ENTERPRISE' : 'RETAIL',
                   hasExtendedFields: strVal(td.extendedFields, null) != null, workflowKey: wf, displayOrder: 0, active: true };
        var body = { productType: pt, config: cfg };
        var send = function() { return api('PUT', '/v1/product-types/' + id, adminHeader, body); };
        governed('reactivate product type ' + ptCode + ' (id ' + id + ', deactivated earlier)', send(), send, PT_HINTS, [ptCode, id]);
        var chk = getSchema();
        if (chk.status != 200) fail('product type ' + ptCode + ' (id ' + id + ') is still inactive after its reactivation was committed: ' + show(chk));
        return chk.body;
      }
      """
    * def chargesFromSheet =
      """
      function() {
        var raw = strVal(td.chargesChecklist, null);
        if (raw == null) return null;
        var list;
        try { list = JSON.parse(raw); } catch (e) { fail('chargesChecklist is not valid JSON (expected [{"chargeDefId": 1, "active": true}]): ' + e); }
        return stripCharges(list);
      }
      """

    # ── Role access (PUT replaces the whole list) ─────────────────────────────
    * def setupRoleAccess =
      """
      function() {
        if (roleList.length == 0) return null;
        var r = api('GET', '/v1/product-types/' + ptPath + '/role-access', adminHeader, null);
        if (r.status != 200) fail('cannot read role access for ' + ptCode + ': ' + show(r));
        var known = {}; var granted = [];
        for (var i = 0; i < r.body.length; i++) { known[r.body[i].roleCode] = true; if (r.body[i].hasAccess == true) granted.push(r.body[i].roleCode); }
        var missing = []; var unknown = [];
        for (var k = 0; k < roleList.length; k++) {
          var role = roleList[k];
          if (known[role] != true) { unknown.push(role); continue; }
          if (granted.indexOf(role) < 0) missing.push(role);
        }
        if (unknown.length > 0) fail('roleAccessList names role(s) that do not exist on this server: ' + unknown.join(', ') + '. Known roles: ' + Object.keys(known).join(', '));
        if (missing.length == 0) { note('role access for ' + ptCode + ' already covers ' + roleList.join(', ')); return 'roles ' + granted.join(', '); }
        var wanted = granted.slice(0);
        for (var m = 0; m < missing.length; m++) wanted.push(missing[m]);
        var send = function() { return api('PUT', '/v1/product-types/' + ptPath + '/role-access', adminHeader, wanted); };
        governed('role access for ' + ptCode + ' (' + wanted.join(', ') + ')', send(), send, PT_HINTS, [ptCode]);
        var v = api('GET', '/v1/product-types/' + ptPath + '/role-access', adminHeader, null);
        var still = [];
        for (var x = 0; x < missing.length; x++) {
          var ok = false;
          for (var y = 0; v.status == 200 && y < v.body.length; y++) { if (v.body[y].roleCode == missing[x] && v.body[y].hasAccess == true) ok = true; }
          if (!ok) still.push(missing[x]);
        }
        if (still.length > 0) fail('role access for ' + ptCode + ' was committed but ' + still.join(', ') + ' still cannot originate it');
        return 'roles ' + wanted.join(', ') + ' (added ' + missing.join(', ') + ')';
      }
      """

    # ── Extended fields (fieldKey is unique across ALL product types on a server) ────────────
    * def setupFields =
      """
      function() {
        var raw = strVal(td.extendedFields, null);
        if (raw == null) return null;
        var list;
        try { list = JSON.parse(raw); } catch (e) { fail('extendedFields is not valid JSON: ' + e); }
        var cur = api('GET', '/v1/product-types/' + ptPath + '/fields', adminHeader, null);
        var have = {};
        for (var i = 0; cur.status == 200 && i < cur.body.length; i++) have['' + cur.body[i].fieldKey] = true;
        var added = []; var skipped = [];
        for (var f = 0; f < list.length; f++) {
          var fd = list[f];
          if (fd.fieldKey == null) fail('extendedFields entry ' + (f + 1) + ' has no fieldKey');
          if (!/^[a-z][a-zA-Z0-9]*$/.test('' + fd.fieldKey)) fail('extendedFields fieldKey "' + fd.fieldKey + '" must start with a lower-case letter and contain only letters and digits');
          if (have['' + fd.fieldKey] == true) { note('field ' + fd.fieldKey + ' already defined on ' + ptCode); continue; }
          fd.productTypeCode = ptCode;
          if (fd.dataType == null) fd.dataType = 'STRING';
          if (fd.active == null) fd.active = true;
          var body = fd;
          var send = (function(b) { return function() { return api('POST', '/v1/product-types/' + ptPath + '/fields', adminHeader, b); }; })(body);
          var res = send();
          if (res.status == 409 && res.body != null && res.body.detail != null && ('' + res.body.detail).indexOf('already used by product type') >= 0) {
            note('WARNING: field ' + fd.fieldKey + ' skipped - ' + res.body.detail + ' Use a unique fieldKey (e.g. ' + ptCode.toLowerCase().replace(/_/g, '') + fd.fieldKey + ').');
            skipped.push('' + fd.fieldKey);
            continue;
          }
          governed('field ' + fd.fieldKey + ' on ' + ptCode, res, send, PT_HINTS, [ptCode, fd.fieldKey]);
          added.push('' + fd.fieldKey);
        }
        return 'fields' + (added.length > 0 ? ' added ' + added.join(', ') : ' unchanged') + (skipped.length > 0 ? ' (skipped: ' + skipped.join(', ') + ')' : '');
      }
      """

    # ── Sub-products: link, then per-sub-product scorecard rows ──────────────
    * def linkedProducts = function() { var list = subProductsOf(ptCode); var out = []; for (var i = 0; i < list.length; i++) out.push('' + list[i].productCode); return out; }
    * def setupProducts =
      """
      function(scorecardId) {
        if (productCodes.length == 0) return null;
        var linked = linkedProducts();
        var toLink = [];
        for (var i = 0; i < productCodes.length; i++) { if (linked.indexOf(productCodes[i]) < 0) toLink.push(productCodes[i]); }
        for (var k = 0; k < toLink.length; k++) {
          var code = toLink[k];
          var send = (function(c) { return function() { return api('PUT', '/v1/product-types/' + ptPath + '/products/' + encodeURIComponent(c), adminHeader, {}); }; })(code);
          var res = send();
          if (res.status == 400 || res.status == 404) {
            var lp = api('GET', '/v1/product-types/' + ptPath + '/linkable-products', adminHeader, null);
            var avail = [];
            for (var a = 0; lp.status == 200 && a < lp.body.length; a++) avail.push('' + lp.body[a].productCode);
            fail('sub-product ' + code + ' cannot be linked to ' + ptCode + ' -> ' + show(res) + '. Linkable products: ' + avail.join(', '));
          }
          governed('link sub-product ' + code + ' to ' + ptCode, res, send, PT_HINTS, [ptCode, code]);
        }
        var after = linkedProducts();
        for (var v = 0; v < productCodes.length; v++) {
          if (after.indexOf(productCodes[v]) < 0) fail('sub-product ' + productCodes[v] + ' is still not linked to ' + ptCode + ' after commit (linked: ' + after.join(', ') + ')');
        }
        // Per sub-product overrides: subProductScorecards = "05040DEFAULTUSD=SC_A, 80001DEFAULTUSD=SC_B".
        var overrides = {};
        var rawOv = strVal(td.subProductScorecards, null);
        if (rawOv != null) {
          var pairs = rawOv.split(',');
          for (var o = 0; o < pairs.length; o++) {
            var kv = pairs[o].split('=');
            if (kv.length != 2 || kv[0].trim() == '' || kv[1].trim() == '') fail('subProductScorecards entry "' + pairs[o] + '" must look like PRODUCT_CODE=SCORECARD_CODE');
            if (productCodes.indexOf(kv[0].trim()) < 0) fail('subProductScorecards names ' + kv[0].trim() + ', which is not in selectedProductCode (' + productCodes.join(', ') + ')');
            overrides[kv[0].trim()] = requireActiveScorecard(kv[1].trim(), 'sub-product ' + kv[0].trim());
          }
        }
        var set = 0;
        for (var p = 0; p < productCodes.length; p++) {
          var pc = productCodes[p];
          var target = overrides[pc] != null ? overrides[pc] : (attachToProducts ? scorecardId : null);
          if (target == null) continue;
          var changed = amendSubConfig(ptCode, pc, 'attach scorecard ' + target + ' to sub-product ' + ptCode + '/' + pc, [ptCode, pc], function(cfg, cur) {
            // The sub-product row overrides the type's assessment/routing for applications on that product, so it
            // must follow the row's assessmentMethod / routingMethod too (a type switched AUTO -> MANUAL_INTERNAL
            // otherwise keeps auto-deciding on its sub-products).
            var wantAm = assessmentWanted != null ? assessmentWanted : cfg.assessmentMethod;
            var wantRm = routingWanted != null ? routingWanted : cfg.routingMethod;
            if (('' + cur.scorecardId) == ('' + target) && cfg.assessmentMethod == wantAm && cfg.routingMethod == wantRm) return false;
            cfg.scorecardId = target; cfg.assessmentMethod = wantAm; cfg.routingMethod = wantRm;
            return true;
          });
          if (changed) {
            set++;
            var chk = subConfigOf(ptCode, pc);
            if (chk == null || ('' + chk.scorecardId) != ('' + target)) fail('sub-product ' + pc + ' config was committed but scorecardId is ' + (chk == null ? null : chk.scorecardId) + ', expected ' + target);
          }
        }
        return 'sub-products ' + after.join(', ') + (toLink.length > 0 ? ' (linked ' + toLink.join(', ') + ')' : '') + (set > 0 ? ' (scorecard set on ' + set + ')' : '');
      }
      """

    # ── Purposes (LOAN_PURPOSE dropdown; sheet values may be labels or codes) ─
    * def setupPurposes =
      """
      function() {
        if (purposeCodes.length == 0 && !removeUnlisted) return null;
        var cur = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
        if (cur.status != 200) fail('cannot read purposes of ' + ptCode + ': ' + show(cur));
        var lp = api('GET', '/v1/product-types/' + ptPath + '/linkable-purposes', adminHeader, null);
        if (lp.status != 200) fail('cannot read linkable purposes of ' + ptCode + ': ' + show(lp));
        var dropdown = []; var linked = []; var strange = [];
        for (var i = 0; i < cur.body.length; i++) {
          var c = codeOf(cur.body[i]); var l = cur.body[i].label != null ? ('' + cur.body[i].label) : c;
          linked.push(c);
          if (l == c) strange.push(c); else dropdown.push({ code: c, label: l });
        }
        for (var j = 0; j < lp.body.length; j++) dropdown.push({ code: codeOf(lp.body[j]), label: lp.body[j].label != null ? ('' + lp.body[j].label) : codeOf(lp.body[j]) });
        var describe = function() { var out = []; for (var d = 0; d < dropdown.length; d++) out.push(dropdown[d].code + ' = ' + dropdown[d].label); return out.join(', '); };
        var resolve = function(v) { var w = v.toLowerCase(); for (var d = 0; d < dropdown.length; d++) { if (dropdown[d].code.toLowerCase() == w || dropdown[d].label.toLowerCase() == w) return dropdown[d].code; } return null; };
        var wanted = []; var unknown = [];
        for (var w = 0; w < purposeCodes.length; w++) {
          var code = resolve(purposeCodes[w]);
          if (code == null) unknown.push(purposeCodes[w]); else if (wanted.indexOf(code) < 0) wanted.push(code);
        }
        if (unknown.length > 0) fail('linkedPurposes "' + unknown.join('", "') + '" not in the LOAN_PURPOSE dropdown. Use the dropdown labels or codes: ' + describe());
        var detached = [];
        if (removeUnlisted) {
          // detach purposes that are not dropdown options, and (when the sheet lists purposes) any linked purpose not listed
          for (var x = 0; x < linked.length; x++) {
            var lc = linked[x];
            var drop = strange.indexOf(lc) >= 0 || (purposeCodes.length > 0 && wanted.indexOf(lc) < 0);
            if (!drop) continue;
            var del = (function(cc) { return function() { return api('DELETE', '/v1/product-types/' + ptPath + '/purposes/' + encodeURIComponent(cc), adminHeader, null); }; })(lc);
            governed('detach purpose ' + lc + ' from ' + ptCode, del(), del, PT_HINTS, [ptCode, lc]);
            detached.push(lc);
          }
        }
        var missing = [];
        for (var m = 0; m < wanted.length; m++) { if (linked.indexOf(wanted[m]) < 0) missing.push(wanted[m]); }
        if (missing.length > 0) {
          var send = function() { return api('PUT', '/v1/product-types/' + ptPath + '/purposes', adminHeader, missing); };
          governed('link purposes ' + missing.join(', ') + ' to ' + ptCode, send(), send, PT_HINTS, [ptCode]);
        }
        var after = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
        var got = [];
        for (var a = 0; after.status == 200 && a < after.body.length; a++) got.push(codeOf(after.body[a]) + ' = ' + after.body[a].label);
        for (var k = 0; k < missing.length; k++) {
          var hit = false; for (var g = 0; g < got.length; g++) { if (got[g].indexOf(missing[k] + ' =') == 0) hit = true; }
          if (!hit) fail('purpose ' + missing[k] + ' is still not attached to ' + ptCode + ' after commit (attached: ' + got.join(', ') + ')');
        }
        return 'purposes ' + got.join(', ') + (missing.length > 0 ? ' (linked ' + missing.join(', ') + ')' : '') + (detached.length > 0 ? ' (detached ' + detached.join(', ') + ')' : '');
      }
      """

    # ── Verify what the UI would show, and (optionally) that a loan officer can originate ───
    * def verifyOfficerCanSubmit =
      """
      function() {
        if (!verifyOfficer) return null;
        var officerH = softLogin(officerUserForCheck, officerPassForCheck);
        if (officerH == null) fail('verifyOfficerSubmittable=true but the loan officer ' + officerUserForCheck + ' cannot sign in');
        var sub = api('GET', '/v1/product-types/submittable', officerH, null);
        var codes = [];
        for (var s = 0; sub.status == 200 && s < sub.body.length; s++) codes.push('' + sub.body[s].code);
        logout(officerH);
        if (codes.indexOf(ptCode) < 0) fail('loan officer ' + officerUserForCheck + ' cannot originate on ' + ptCode + ' (submittable: ' + codes.join(', ') + '). Check that the officer\'s role is in roleAccessList: ' + roleList.join(', '));
        return 'loan officer ' + officerUserForCheck + ' can originate on ' + ptCode;
      }
      """

    # ── DELETE with cascade ───────────────────────────────────────────────────
    # Deactivation (DELETE /v1/product-types/{id}) does not cascade on the server: limits, rules, links,
    # purposes, fields and the configuration rows all stay behind (and field keys are unique server-wide,
    # so a re-created type could not re-add them). Everything is detached here first, one record at a time,
    # because PUT .../products and .../purposes reject an empty list.
    * def cascadeDelete =
      """
      function(existing) {
        var log = [];
        // 1. approval limits on this loan type
        var limRes = api('GET', '/v1/approval-limits?status=ACTIVE&size=100&loanType=' + ptPath, adminHeader, null);
        if (limRes.status == 200 && limRes.body != null) {
          var limList = limRes.body.content != null ? limRes.body.content : limRes.body;
          for (var l = 0; l < limList.length; l++) {
            var limit = limList[l];
            if (!eq(limit.loanType, ptCode) || limit.status != 'ACTIVE') continue;
            var sendDelLim = (function(id) { return function() { return api('POST', '/v1/approval-limits/' + id + '/request-deletion', adminHeader, {}); }; })(limit.id);
            governed('delete approval limit ' + limit.id + ' (' + limit.authorityType + ' ' + limit.authorityName + ' on ' + ptCode + ')', sendDelLim(), sendDelLim, ['APPROVAL_LIMIT'], [ptCode, limit.id]);
            log.push('limit ' + limit.id);
          }
        } else note('WARNING: could not list approval limits for ' + ptCode + ': ' + show(limRes));
        // 2. notification rules conditioned on this product type
        var rulRes = api('GET', '/v1/notification/rules?module=LO', adminHeader, null);
        if (rulRes.status == 200 && rulRes.body != null) {
          for (var r = 0; r < rulRes.body.length; r++) {
            var rule = rulRes.body[r];
            var cond = (rule.conditionTree != null ? JSON.stringify(rule.conditionTree) : '').toUpperCase();
            if (cond.indexOf('"' + ptCode.toUpperCase() + '"') < 0) continue;
            var sendDelRule = (function(id) { return function() { return api('DELETE', '/v1/notification/rules/' + id + '?module=LO', adminHeader, null); }; })(rule.id);
            governed('delete notification rule ' + rule.id + ' (' + rule.ruleName + ') conditioned on ' + ptCode, sendDelRule(), sendDelRule, ['NOTIFICATION_RULE'], [rule.ruleName, rule.id]);
            log.push('rule ' + rule.id + ' ' + rule.ruleName);
          }
        } else note('WARNING: could not list notification rules: ' + show(rulRes));
        // 3. type-level configuration: drop charges, checklist and scorecard in ONE amendment
        var cleared = amendTypeConfig(ptCode, 'clear configuration of ' + ptCode + ' (charges, checklist, scorecard)', [ptCode, existing.id], function(cfg, cur) {
          var had = (cur.charges != null && cur.charges.length > 0) || cur.documentChecklistId != null || cur.scorecardId != null;
          if (!had) return false;
          cfg.charges = []; cfg.documentChecklistId = null; cfg.scorecardId = null;
          if (needsScorecard(cfg.assessmentMethod)) cfg.assessmentMethod = 'MANUAL';
          return true;
        });
        if (cleared) log.push('configuration cleared');
        // 4. sub-products: unlink each (the server also drops the sub-product's own configuration row)
        var subs = linkedProducts();
        for (var s = 0; s < subs.length; s++) {
          var sendUnlink = (function(c) { return function() { return api('DELETE', '/v1/product-types/' + ptPath + '/products/' + encodeURIComponent(c), adminHeader, null); }; })(subs[s]);
          governed('unlink sub-product ' + subs[s] + ' from ' + ptCode, sendUnlink(), sendUnlink, PT_HINTS, [ptCode, subs[s]]);
        }
        if (subs.length > 0) log.push(subs.length + ' sub-product(s) unlinked');
        // 5. purposes
        var pur = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
        var purs = [];
        for (var p = 0; pur.status == 200 && p < pur.body.length; p++) purs.push(codeOf(pur.body[p]));
        for (var q = 0; q < purs.length; q++) {
          var sendPur = (function(c) { return function() { return api('DELETE', '/v1/product-types/' + ptPath + '/purposes/' + encodeURIComponent(c), adminHeader, null); }; })(purs[q]);
          governed('detach purpose ' + purs[q] + ' from ' + ptCode, sendPur(), sendPur, PT_HINTS, [ptCode, purs[q]]);
        }
        if (purs.length > 0) log.push(purs.length + ' purpose(s) detached');
        // 6. extended fields (409 when a scorecard still bands the derived attribute)
        var flds = api('GET', '/v1/product-types/' + ptPath + '/fields', adminHeader, null);
        var fkept = [];
        for (var f = 0; flds.status == 200 && f < flds.body.length; f++) {
          var fd = flds.body[f];
          var sendFld = (function(id) { return function() { return api('DELETE', '/v1/product-types/fields/' + id, adminHeader, null); }; })(fd.id);
          var fres = sendFld();
          if (fres.status == 409) { note('WARNING: field ' + fd.fieldKey + ' kept - ' + show(fres)); fkept.push('' + fd.fieldKey); continue; }
          governed('delete field ' + fd.fieldKey + ' of ' + ptCode, fres, sendFld, PT_HINTS, [ptCode, fd.fieldKey]);
        }
        if (flds.status == 200 && flds.body.length > 0) log.push((flds.body.length - fkept.length) + ' field(s) deleted' + (fkept.length > 0 ? ' (kept: ' + fkept.join(', ') + ')' : ''));
        // 7. role access
        var ra = api('GET', '/v1/product-types/' + ptPath + '/role-access', adminHeader, null);
        var granted = [];
        for (var g = 0; ra.status == 200 && g < ra.body.length; g++) { if (ra.body[g].hasAccess == true) granted.push(ra.body[g].roleCode); }
        if (granted.length > 0) {
          var sendRa = function() { return api('PUT', '/v1/product-types/' + ptPath + '/role-access', adminHeader, []); };
          governed('revoke role access (' + granted.join(', ') + ') on ' + ptCode, sendRa(), sendRa, PT_HINTS, [ptCode]);
          log.push('role access revoked');
        }
        // 8. deactivate the type itself
        var sendDel = function() { return api('DELETE', '/v1/product-types/' + existing.id, adminHeader, null); };
        governed('deactivate product type ' + ptCode + ' (id ' + existing.id + ')', sendDel(), sendDel, PT_HINTS, [ptCode, existing.id]);
        var chk = getSchema();
        if (chk.status == 200) fail('product type ' + ptCode + ' is still active after its deactivation was committed');
        return 'product type ' + ptCode + ' (id ' + existing.id + ') deactivated | ' + (log.length > 0 ? log.join(', ') : 'nothing was attached');
      }
      """

    # ── Link amendments (CRUD-Configurations workbook, Product_Types sheet) ───────────────
    # attachSubProducts / detachSubProducts : sub-product codes (or descriptions) - one change request each
    # attachPurposes / detachPurposes       : LOAN_PURPOSE labels or codes - attach in one request, detach one by one
    # attachCharges / detachCharges         : charge names or CHG-NNNNNN codes -> the type's own charge list (attach needs
    #                                         an ACTIVE charge; detach also accepts an inactive one)
    # attachChecklist / detachChecklist     : checklist name (or id) / true -> documentChecklistId on the type config
    # attachScorecard / detachScorecard     : scorecard code or name / true -> scorecardId on the type config
    # attachNotificationRules / detach...   : rule names -> the rule's product_type condition gains / loses this code
    #                                         (a rule detached from its last type is deactivated, not made global)
    # scorecardToSubProducts = true         : the scorecard change is also applied to every sub-product row that owns
    #                                         its own configuration (otherwise those rows keep their own scorecard)
    # Charges, checklist and scorecard are changed in ONE amendment of the type (one change request).
    * def LINK_COLS = ['attachSubProducts', 'detachSubProducts', 'attachPurposes', 'detachPurposes', 'attachCharges', 'detachCharges', 'attachChecklist', 'detachChecklist', 'attachScorecard', 'detachScorecard', 'attachNotificationRules', 'detachNotificationRules']
    * def hasLinkColumns = function() { for (var i = 0; i < LINK_COLS.length; i++) { if (strVal(td[LINK_COLS[i]], null) != null) return true; } return strVal(td.newName, null) != null; }
    * def linkMode = (td._mode != null && ('' + td._mode).toUpperCase() == 'LINKS') || (action == 'AMEND' && hasLinkColumns())
    * def findChargeRef =
      """
      function(raw, allowInactive) {
        var r = api('GET', '/v1/config/incident-charge-definitions?search=' + encodeURIComponent(raw), adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search incident charge definitions: ' + show(r));
        var list = r.body.data != null ? r.body.data : r.body;
        if (list != null && list.content != null) list = list.content;
        var hits = []; var opts = [];
        for (var i = 0; list != null && i < list.length; i++) {
          var c = list[i];
          opts.push(c.chargeCode + ' = ' + c.chargeName + ' (' + c.event + ', ' + c.currency + ', ' + c.chargeStatus + ')');
          if (eq(c.chargeCode, raw)) return c;
          if (eq(c.chargeName, raw) && (c.chargeStatus == 'ACTIVE' || allowInactive == true)) hits.push(c);
        }
        if (hits.length == 1) return hits[0];
        if (hits.length > 1 && allowInactive == true) { var act = []; for (var h0 = 0; h0 < hits.length; h0++) { if (hits[h0].chargeStatus == 'ACTIVE') act.push(hits[h0]); } if (act.length == 1) return act[0]; }
        if (hits.length > 1) { var hs = []; for (var h = 0; h < hits.length; h++) hs.push(hits[h].chargeCode + ' (' + hits[h].event + ', ' + hits[h].currency + ')'); fail('charge "' + raw + '" matches several ACTIVE charges - use the CHG code instead: ' + hs.join(', ')); }
        fail('charge "' + raw + '" is not an ' + (allowInactive == true ? '' : 'ACTIVE ') + 'incident charge on ' + baseUrl + ' (use the Charge Name or the CHG-NNNNNN code). Charges found for that search: ' + (opts.length > 0 ? opts.join(', ') : '(none)'));
      }
      """
    * def findChecklistRef =
      """
      function(raw) {
        var r = api('GET', '/v1/master-data/document-checklists?search=' + encodeURIComponent(/^\d+$/.test(raw) ? '' : raw) + '&size=100', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search document checklists: ' + show(r));
        var list = r.body.content != null ? r.body.content : r.body;
        var opts = [];
        for (var i = 0; i < list.length; i++) { opts.push(list[i].id + ' = ' + list[i].name); if (('' + list[i].id) == raw || eq(list[i].name, raw)) return list[i]; }
        fail('document checklist "' + raw + '" does not exist on ' + baseUrl + ' (use the checklist name or id). Checklists: ' + opts.join(', '));
      }
      """
    * def executeLinkAmend =
      """
      function(existing) {
        var id = existing.id;
        var summary = [];
        var attachSubs = splitList(td.attachSubProducts); var detachSubs = splitList(td.detachSubProducts);
        var attachPurs = splitList(td.attachPurposes); var detachPurs = splitList(td.detachPurposes);
        var attachChg = splitList(td.attachCharges); var detachChg = splitList(td.detachCharges);
        var attachCl = strVal(td.attachChecklist, null); var detachCl = isTrue(td.detachChecklist);
        var attachSc = strVal(td.attachScorecard, null); var detachSc = isTrue(td.detachScorecard);
        var scToSubs = isTrue(td.scorecardToSubProducts);
        if (attachCl != null && detachCl) fail('attachChecklist and detachChecklist are both filled - fill one of them');
        if (attachSc != null && detachSc) fail('attachScorecard and detachScorecard are both filled - fill one of them');
        if (attachSubs.length + detachSubs.length + attachPurs.length + detachPurs.length + attachChg.length + detachChg.length + splitList(td.attachNotificationRules).length + splitList(td.detachNotificationRules).length == 0 && attachCl == null && !detachCl && attachSc == null && !detachSc && ptNewName == null) {
          note('no attach / detach column is filled for ' + ptCode + ' - nothing to change');
          return 'product type ' + ptCode + ' (id ' + id + '): nothing to change (no attach / detach column filled)';
        }

        // 1. sub-products: detach first (frees the codes), then attach
        if (detachSubs.length > 0) {
          var linkedNow = subProductsOf(ptCode);
          var done = []; var skipped = [];
          for (var d = 0; d < detachSubs.length; d++) {
            var hit = null;
            for (var l = 0; l < linkedNow.length; l++) { if (eq(linkedNow[l].productCode, detachSubs[d]) || eq(linkedNow[l].productDescription, detachSubs[d])) hit = '' + linkedNow[l].productCode; }
            if (hit == null) { skipped.push(detachSubs[d]); continue; }
            var sendUnlink = (function(c) { return function() { return api('DELETE', '/v1/product-types/' + ptPath + '/products/' + encodeURIComponent(c), adminHeader, null); }; })(hit);
            governed('detach sub-product ' + hit + ' from ' + ptCode, sendUnlink(), sendUnlink, PT_HINTS, [ptCode, hit]);
            done.push(hit);
          }
          var afterD = linkedProducts();
          for (var v = 0; v < done.length; v++) { if (afterD.indexOf(done[v]) >= 0) fail('sub-product ' + done[v] + ' is still linked to ' + ptCode + ' after the detachment was committed'); }
          summary.push('sub-products detached: ' + (done.length > 0 ? done.join(', ') : 'none') + (skipped.length > 0 ? ' (not linked, skipped: ' + skipped.join(', ') + ')' : ''));
        }
        if (attachSubs.length > 0) {
          var linkedA = linkedProducts();
          var toLink = []; var already = [];
          for (var a = 0; a < attachSubs.length; a++) { if (linkedA.indexOf(attachSubs[a]) < 0) toLink.push(attachSubs[a]); else already.push(attachSubs[a]); }
          for (var k = 0; k < toLink.length; k++) {
            var code = toLink[k];
            var sendLink = (function(c) { return function() { return api('PUT', '/v1/product-types/' + ptPath + '/products/' + encodeURIComponent(c), adminHeader, {}); }; })(code);
            var res = sendLink();
            if (res.status == 400 || res.status == 404) {
              var lp = api('GET', '/v1/product-types/' + ptPath + '/linkable-products', adminHeader, null);
              var avail = [];
              for (var q = 0; lp.status == 200 && q < lp.body.length; q++) avail.push('' + lp.body[q].productCode);
              fail('sub-product ' + code + ' cannot be linked to ' + ptCode + ' -> ' + show(res) + '. Linkable products: ' + avail.join(', '));
            }
            governed('attach sub-product ' + code + ' to ' + ptCode, res, sendLink, PT_HINTS, [ptCode, code]);
          }
          var afterA = linkedProducts();
          for (var w = 0; w < toLink.length; w++) { if (afterA.indexOf(toLink[w]) < 0) fail('sub-product ' + toLink[w] + ' is still not linked to ' + ptCode + ' after the attachment was committed (linked: ' + afterA.join(', ') + ')'); }
          summary.push('sub-products attached: ' + (toLink.length > 0 ? toLink.join(', ') : 'none') + (already.length > 0 ? ' (already linked: ' + already.join(', ') + ')' : ''));
        }

        // 2. purposes (labels or codes of the LOAN_PURPOSE dropdown)
        if (detachPurs.length > 0 || attachPurs.length > 0) {
          var cur = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
          if (cur.status != 200) fail('cannot read purposes of ' + ptCode + ': ' + show(cur));
          var lpu = api('GET', '/v1/product-types/' + ptPath + '/linkable-purposes', adminHeader, null);
          if (lpu.status != 200) fail('cannot read linkable purposes of ' + ptCode + ': ' + show(lpu));
          var dropdown = []; var linkedP = [];
          for (var i = 0; i < cur.body.length; i++) { var c1 = codeOf(cur.body[i]); linkedP.push(c1); dropdown.push({ code: c1, label: cur.body[i].label != null ? ('' + cur.body[i].label) : c1 }); }
          for (var j = 0; j < lpu.body.length; j++) dropdown.push({ code: codeOf(lpu.body[j]), label: lpu.body[j].label != null ? ('' + lpu.body[j].label) : codeOf(lpu.body[j]) });
          var describe = function() { var out = []; for (var x = 0; x < dropdown.length; x++) out.push(dropdown[x].code + ' = ' + dropdown[x].label); return out.join(', '); };
          var resolveP = function(v) { for (var x = 0; x < dropdown.length; x++) { if (eq(dropdown[x].code, v) || eq(dropdown[x].label, v)) return dropdown[x].code; } fail('purpose "' + v + '" is not in the LOAN_PURPOSE dropdown. Use the dropdown labels or codes: ' + describe()); };
          var detachedP = []; var notLinked = [];
          for (var dp = 0; dp < detachPurs.length; dp++) {
            var pc = resolveP(detachPurs[dp]);
            if (linkedP.indexOf(pc) < 0) { notLinked.push(detachPurs[dp]); continue; }
            var sendPur = (function(cc) { return function() { return api('DELETE', '/v1/product-types/' + ptPath + '/purposes/' + encodeURIComponent(cc), adminHeader, null); }; })(pc);
            governed('detach purpose ' + pc + ' from ' + ptCode, sendPur(), sendPur, PT_HINTS, [ptCode, pc]);
            detachedP.push(pc);
          }
          var missingP = []; var alreadyP = [];
          for (var ap = 0; ap < attachPurs.length; ap++) { var pc2 = resolveP(attachPurs[ap]); if (linkedP.indexOf(pc2) >= 0 && detachedP.indexOf(pc2) < 0) alreadyP.push(pc2); else if (missingP.indexOf(pc2) < 0) missingP.push(pc2); }
          if (missingP.length > 0) {
            var sendAttP = function() { return api('PUT', '/v1/product-types/' + ptPath + '/purposes', adminHeader, missingP); };
            governed('attach purposes ' + missingP.join(', ') + ' to ' + ptCode, sendAttP(), sendAttP, PT_HINTS, [ptCode]);
          }
          var afterP = api('GET', '/v1/product-types/' + ptPath + '/purposes', adminHeader, null);
          var gotP = [];
          for (var g = 0; afterP.status == 200 && g < afterP.body.length; g++) gotP.push(codeOf(afterP.body[g]));
          for (var m = 0; m < missingP.length; m++) { if (gotP.indexOf(missingP[m]) < 0) fail('purpose ' + missingP[m] + ' is still not attached to ' + ptCode + ' after commit (attached: ' + gotP.join(', ') + ')'); }
          for (var n = 0; n < detachedP.length; n++) { if (gotP.indexOf(detachedP[n]) >= 0) fail('purpose ' + detachedP[n] + ' is still attached to ' + ptCode + ' after its detachment was committed'); }
          if (detachPurs.length > 0) summary.push('purposes detached: ' + (detachedP.length > 0 ? detachedP.join(', ') : 'none') + (notLinked.length > 0 ? ' (not attached, skipped: ' + notLinked.join(', ') + ')' : ''));
          if (attachPurs.length > 0) summary.push('purposes attached: ' + (missingP.length > 0 ? missingP.join(', ') : 'none') + (alreadyP.length > 0 ? ' (already attached: ' + alreadyP.join(', ') + ')' : ''));
          summary.push('purposes now: ' + gotP.join(', '));
        }

        // 3. charges + checklist + scorecard: one amendment of the type's own configuration
        var addChg = []; var dropChg = [];
        for (var ac = 0; ac < attachChg.length; ac++) { var cA = findChargeRef(attachChg[ac]); addChg.push({ id: cA.id, code: cA.chargeCode }); }
        for (var dc = 0; dc < detachChg.length; dc++) { var cD = findChargeRef(detachChg[dc], true); dropChg.push({ id: cD.id, code: cD.chargeCode }); }
        var clTarget = attachCl != null ? findChecklistRef(attachCl) : null;
        var scTarget = attachSc != null ? requireActiveScorecard(attachSc, 'attachScorecard') : null;
        var cfgChanges = [];
        var renameTo = (ptNewName != null && ptNewName != ('' + existing.label)) ? ptNewName : null;
        if (renameTo != null) cfgChanges.push('label "' + existing.label + '" -> "' + renameTo + '"');
        if (addChg.length + dropChg.length > 0 || clTarget != null || detachCl || scTarget != null || detachSc || renameTo != null) {
          amendTypeConfig(ptCode, (renameTo != null ? 'rename and ' : '') + 'amend links of product type ' + ptCode, [ptCode, id], function(cfg, curCfg) {
            var changed = renameTo != null;
            var list = stripCharges(curCfg.charges);
            for (var x1 = 0; x1 < dropChg.length; x1++) {
              var kept = []; var had = false;
              for (var y1 = 0; y1 < list.length; y1++) { if (('' + list[y1].chargeDefId) == ('' + dropChg[x1].id)) had = true; else kept.push(list[y1]); }
              list = kept;
              if (had) { changed = true; cfgChanges.push('charge ' + dropChg[x1].code + ' detached'); } else cfgChanges.push('charge ' + dropChg[x1].code + ' was not attached');
            }
            for (var x2 = 0; x2 < addChg.length; x2++) {
              var hit2 = false;
              for (var y2 = 0; y2 < list.length; y2++) { if (('' + list[y2].chargeDefId) == ('' + addChg[x2].id)) { hit2 = true; if (list[y2].active == false) { list[y2].active = true; changed = true; } } }
              if (!hit2) { list.push({ chargeDefId: addChg[x2].id, active: true }); changed = true; cfgChanges.push('charge ' + addChg[x2].code + ' attached'); } else cfgChanges.push('charge ' + addChg[x2].code + ' already attached');
            }
            if (addChg.length + dropChg.length > 0) cfg.charges = list;
            if (detachCl) { if (curCfg.documentChecklistId != null) { cfg.documentChecklistId = null; changed = true; cfgChanges.push('checklist ' + curCfg.documentChecklistId + ' detached'); } else cfgChanges.push('no checklist was attached'); }
            if (clTarget != null) { if (('' + curCfg.documentChecklistId) != ('' + clTarget.id)) { cfg.documentChecklistId = clTarget.id; changed = true; cfgChanges.push('checklist ' + clTarget.id + ' "' + clTarget.name + '" attached'); } else cfgChanges.push('checklist ' + clTarget.id + ' already attached'); }
            if (detachSc) { if (curCfg.scorecardId != null) { cfg.scorecardId = null; changed = true; cfgChanges.push('scorecard ' + curCfg.scorecardId + ' detached'); if (needsScorecard(cfg.assessmentMethod)) { cfg.assessmentMethod = 'MANUAL'; cfgChanges.push('assessment ' + curCfg.assessmentMethod + ' -> MANUAL (needs a scorecard)'); } } else cfgChanges.push('no scorecard was attached'); }
            if (scTarget != null) { if (('' + curCfg.scorecardId) != ('' + scTarget)) { cfg.scorecardId = scTarget; changed = true; cfgChanges.push('scorecard ' + scTarget + ' (' + attachSc + ') attached'); } else cfgChanges.push('scorecard ' + scTarget + ' already attached'); if (!needsScorecard(cfg.assessmentMethod)) { cfgChanges.push('assessment ' + cfg.assessmentMethod + ' -> AUTO (uses the scorecard)'); cfg.assessmentMethod = 'AUTO'; changed = true; } }
            return changed;
          }, renameTo != null ? { label: renameTo } : null);
          if (renameTo != null) { var sch = getSchema(); if (sch.status != 200 || ('' + sch.body.label) != renameTo) fail('product type ' + ptCode + ' is still labelled "' + (sch.status == 200 ? sch.body.label : '?') + '" after the rename was committed, expected "' + renameTo + '"'); }
          var after = typeConfigOf(ptCode);
          for (var z1 = 0; z1 < addChg.length; z1++) { var ok1 = false; for (var z2 = 0; after.charges != null && z2 < after.charges.length; z2++) { if (('' + after.charges[z2].chargeDefId) == ('' + addChg[z1].id) && after.charges[z2].active != false) ok1 = true; } if (!ok1) fail('charge ' + addChg[z1].code + ' is not on ' + ptCode + ' after the amendment was committed'); }
          for (var z3 = 0; z3 < dropChg.length; z3++) { for (var z4 = 0; after.charges != null && z4 < after.charges.length; z4++) { if (('' + after.charges[z4].chargeDefId) == ('' + dropChg[z3].id)) fail('charge ' + dropChg[z3].code + ' is still on ' + ptCode + ' after the amendment was committed'); } }
          if (clTarget != null && ('' + after.documentChecklistId) != ('' + clTarget.id)) fail('product type ' + ptCode + ' carries checklist ' + after.documentChecklistId + ' after the amendment, expected ' + clTarget.id);
          if (detachCl && after.documentChecklistId != null) fail('product type ' + ptCode + ' still carries checklist ' + after.documentChecklistId + ' after the amendment');
          if (scTarget != null && ('' + after.scorecardId) != ('' + scTarget)) fail('product type ' + ptCode + ' carries scorecard ' + after.scorecardId + ' after the amendment, expected ' + scTarget);
          if (detachSc && after.scorecardId != null) fail('product type ' + ptCode + ' still carries scorecard ' + after.scorecardId + ' after the amendment');
          if (scTarget != null && !needsScorecard(after.assessmentMethod)) fail('product type ' + ptCode + ' has assessment ' + after.assessmentMethod + ' after the scorecard was attached, expected AUTO');
          summary.push(cfgChanges.join(', '));
          // sub-product rows that own a configuration: optionally follow the scorecard change
          if (scToSubs && (scTarget != null || detachSc)) {
            var owned = configuredSubs(ptCode); var rolled = 0;
            for (var s1 = 0; s1 < owned.length; s1++) {
              var sub = owned[s1];
              var ch = amendSubConfig(ptCode, sub, (scTarget != null ? 'attach scorecard ' + scTarget + ' to' : 'detach scorecard from') + ' sub-product ' + ptCode + '/' + sub, [ptCode, sub], function(cfg2, cur2) {
                if (scTarget != null) { var same2 = ('' + cur2.scorecardId) == ('' + scTarget); if (same2 && needsScorecard(cfg2.assessmentMethod)) return false; cfg2.scorecardId = scTarget; if (!needsScorecard(cfg2.assessmentMethod)) cfg2.assessmentMethod = 'AUTO'; return true; }
                if (cur2.scorecardId == null) return false;
                cfg2.scorecardId = null; if (needsScorecard(cfg2.assessmentMethod)) cfg2.assessmentMethod = 'MANUAL'; return true;
              });
              if (ch) rolled++;
            }
            summary.push('scorecard change applied to ' + rolled + ' of ' + owned.length + ' sub-product row(s) with their own configuration');
          }
        }
        // 4. notification rules: a rule is "attached" to a type through its product_type condition
        var attachRules = splitList(td.attachNotificationRules); var detachRules = splitList(td.detachNotificationRules);
        if (attachRules.length + detachRules.length > 0) {
          var ruleOut = [];
          var RUL_HINTS2 = ['NOTIFICATION_RULE', 'NOTIF'];
          var listRules2 = function() { var r = api('GET', '/v1/notification/rules?module=LO', adminHeader, null); if (r.status != 200 || r.body == null) fail('cannot list notification rules: ' + show(r)); return r.body; };
          var readRule = function(id) { var g = api('GET', '/v1/notification/rules/' + id + '?module=LO', adminHeader, null); if (g.status != 200 || g.body == null) fail('cannot read notification rule ' + id + ': ' + show(g)); return g.body; };
          var findRule2 = function(name) { var all = listRules2(); var names = []; for (var i = 0; i < all.length; i++) { names.push(all[i].ruleName); if (eq(all[i].ruleName, name)) return all[i]; } fail('notification rule "' + name + '" does not exist on ' + baseUrl + '. Rules: ' + names.join(', ')); };
          // the product_type condition of a rule: {node, values[]} or null
          var ptCond = function(tree) { if (tree == null || tree.children == null) return null; for (var i = 0; i < tree.children.length; i++) { var c = tree.children[i]; if (c != null && ('' + c.variable).toLowerCase() == 'product_type') return c; } return null; };
          var valuesOf = function(c) { if (c == null || c.value == null) return []; if (Array.isArray(c.value)) return c.value.map(function(v) { return '' + v; }); var s = '' + c.value; return s.indexOf(',') >= 0 ? s.split(',').map(function(v) { return v.trim(); }) : [s]; };
          var putRule = function(rule, tree, what) {
            var body = { id: rule.id, ruleName: rule.ruleName, eventCode: rule.eventCode, conditionTree: tree, active: rule.active != false, targets: rule.targets };
            var send = function() { return api('PUT', '/v1/notification/rules/' + rule.id + '?module=LO', adminHeader, body); };
            governed(what, send(), send, RUL_HINTS2, [rule.ruleName, rule.id]);
          };
          for (var ar = 0; ar < attachRules.length; ar++) {
            var rule = readRule(findRule2(attachRules[ar]).id);
            // plain JSON copy: the response nodes are Java-backed proxies that cannot be compared or edited reliably
            var tree = rule.conditionTree == null ? null : JSON.parse(JSON.stringify(rule.conditionTree)); var cond = ptCond(tree); var vals = valuesOf(cond);
            if (vals.indexOf(ptCode) >= 0) { ruleOut.push('rule "' + rule.ruleName + '" already attached'); continue; }
            var newTree;
            if (cond == null) {
              newTree = tree == null || tree.children == null ? { op: 'AND', children: [] } : tree;
              newTree.children.push({ variable: 'product_type', operator: 'EQ', value: ptCode, value2: null });
            } else {
              vals.push(ptCode); cond.operator = 'IN'; cond.value = vals; newTree = tree;
            }
            putRule(rule, newTree, 'attach notification rule "' + rule.ruleName + '" to product type ' + ptCode);
            var chk = readRule(rule.id);
            if (valuesOf(ptCond(chk.conditionTree)).indexOf(ptCode) < 0) fail('rule "' + rule.ruleName + '" still has no product_type condition for ' + ptCode + ' after the amendment was committed');
            ruleOut.push('rule "' + rule.ruleName + '" attached' + (vals.length > 1 ? ' (product types now ' + vals.join(', ') + ')' : ''));
          }
          for (var dr = 0; dr < detachRules.length; dr++) {
            var rule2 = readRule(findRule2(detachRules[dr]).id);
            var tree2 = rule2.conditionTree == null ? null : JSON.parse(JSON.stringify(rule2.conditionTree)); var cond2 = ptCond(tree2); var vals2 = valuesOf(cond2);
            if (vals2.indexOf(ptCode) < 0) { ruleOut.push('rule "' + rule2.ruleName + '" was not attached (product types: ' + (vals2.length > 0 ? vals2.join(', ') : 'every product type') + ')'); continue; }
            var rest = []; for (var v = 0; v < vals2.length; v++) { if (vals2[v] != ptCode) rest.push(vals2[v]); }
            var newTree2 = tree2;
            if (rest.length == 0) {
              // last product type: without the condition the rule would fire for EVERY product, so it is deactivated instead
              var kept = []; for (var k = 0; k < tree2.children.length; k++) { var ck = tree2.children[k]; if (ck == null || ('' + ck.variable).toLowerCase() != 'product_type') kept.push(ck); }
              newTree2 = kept.length > 0 ? { op: tree2.op, children: kept } : null;
              rule2.active = false;
              note('rule "' + rule2.ruleName + '" was attached only to ' + ptCode + ' - it is deactivated so that it does not start firing for every product type (delete it with the Notification_Rules sheet, or attach another type and re-activate it there)');
            } else { cond2.operator = rest.length == 1 ? 'EQ' : 'IN'; cond2.value = rest.length == 1 ? rest[0] : rest; }
            putRule(rule2, newTree2, 'detach notification rule "' + rule2.ruleName + '" from product type ' + ptCode);
            var chk2 = readRule(rule2.id);
            if (valuesOf(ptCond(chk2.conditionTree)).indexOf(ptCode) >= 0) fail('rule "' + rule2.ruleName + '" still names ' + ptCode + ' after the amendment was committed');
            ruleOut.push('rule "' + rule2.ruleName + '" detached' + (rest.length == 0 ? ' and deactivated (it had no other product type)' : ' (product types now ' + rest.join(', ') + ')'));
          }
          summary.push(ruleOut.join(', '));
        }
        return 'product type ' + ptCode + ' (id ' + id + '): ' + summary.join(' | ');
      }
      """

    # ── Execute ───────────────────────────────────────────────────────────────
    * def executeProductType =
      """
      function() {
        var s = getSchema();
        var existing = (s.status == 200 && s.body != null) ? s.body : null;
        if (action == 'DELETE') {
          if (existing == null) { note('product type ' + ptCode + ' does not exist (or is already inactive) - nothing to delete'); return 'product type ' + ptCode + ' not found (nothing to delete)'; }
          return cascadeDelete(existing);
        }
        if (action == 'DEACTIVATE') {
          if (existing == null) { note('product type ' + ptCode + ' does not exist (or is already inactive) - nothing to deactivate'); return 'product type ' + ptCode + ' not found (nothing to deactivate)'; }
          if (isTrue(td.detachEverything)) { note('detachEverything = true: limits, rules, charges, checklist, scorecard, sub-products, purposes, fields and role access are detached before the deactivation'); return cascadeDelete(existing); }
          var sendDeact = function() { return api('DELETE', '/v1/product-types/' + existing.id, adminHeader, null); };
          governed('deactivate product type ' + ptCode + ' (id ' + existing.id + ') - supervisor approval', sendDeact(), sendDeact, PT_HINTS, [ptCode, existing.id]);
          var gone = getSchema();
          if (gone.status == 200) fail('product type ' + ptCode + ' is still active after its deactivation was approved and committed');
          return 'product type ' + ptCode + ' (id ' + existing.id + ') deactivated with supervisor approval | sub-products, purposes, charges, checklist and scorecard left in place (set detachEverything = true to remove them)';
        }
        if (action == 'AMEND' && existing == null) fail('product type ' + ptCode + ' does not exist on ' + baseUrl + ' (or is inactive) - nothing to amend (use create=true, or fix productTypeCode / newProductTypeCode)');
        if (action == 'AMEND' && linkMode) return executeLinkAmend(existing);
        var scorecardId = scWantedCode != null ? requireActiveScorecard(scWantedCode, 'row scorecard') : null;
        var summary = [];
        var id = null;
        if (existing == null) {
          var dormant = findInactiveTypeId(ptCode);
          if (dormant != null) {
            note('product type ' + ptCode + ' exists but is deactivated (id ' + dormant + ') - reactivating it instead of creating a duplicate code');
            var wf0 = resolveWorkflowKey(wfKeyWanted != null ? wfKeyWanted : req('workflowKey', 'to reactivate a product type (a published workflow key, see /v1/product-types/workflow-options)'));
            existing = reactivateType(dormant, wf0, assessmentWanted != null ? assessmentWanted : 'AUTO', routingWanted != null ? routingWanted : 'DIRECT', scorecardId);
            summary.push('reactivated (id ' + dormant + ', workflow ' + wf0 + ')');
          }
        }
        if (existing == null) {
          var assessment = assessmentWanted != null ? assessmentWanted : 'AUTO';
          var routing = routingWanted != null ? routingWanted : 'DIRECT';
          if (needsScorecard(assessment) && scorecardId == null) fail('assessmentMethod ' + assessment + ' needs a scorecard to create ' + ptCode + ': set newScorecardCode to a scorecard published by the Scorecards sheet');
          if (wfKeyWanted == null) fail('column "workflowKey" (newWorkflowKey in the setup workbook) is blank but is required to create a product type (a published workflow key, see /v1/product-types/workflow-options)');
          var wf = resolveWorkflowKey(wfKeyWanted);
          var cfg = { productTypeCode: ptCode, assessmentMethod: assessment, routingMethod: routing, scorecardId: scorecardId, active: true };
          var sheetCharges = chargesFromSheet();
          if (sheetCharges != null) cfg.charges = sheetCharges;
          var payload = {
            productType: { code: ptCode, label: ptName != null ? ptName : ptCode, description: rowDescription != null ? rowDescription : (ptName != null ? ptName : ptCode),
                           category: (ptCategory == 'OVERDRAFT' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'OVERDRAFT' : 'LOAN',
                           customerType: (ptCategory == 'ENTERPRISE' || ptCategory == 'ENTERPRISE_OVERDRAFT') ? 'ENTERPRISE' : 'RETAIL',
                           workflowKey: wf, hasExtendedFields: strVal(td.extendedFields, null) != null, active: true },
            config: cfg
          };
          var create = function() { return api('POST', '/v1/product-types', adminHeader, payload); };
          governed('create product type ' + ptCode, create(), create, PT_HINTS, [ptCode]);
          for (var i = 0; i < 30 && id == null; i++) {
            var chk = getSchema();
            if (chk.status == 200) id = chk.body.id; else java.lang.Thread.sleep(1000);
          }
          if (id == null) fail('product type ' + ptCode + ' is still not visible after its change request was committed');
          summary.push('created (id ' + id + ', workflow ' + wf + ', ' + assessment + '/' + routing + ', scorecard ' + scorecardId + ')');
        } else {
          id = existing.id;
          var cur = typeConfigOf(ptCode);
          var wantSc = scorecardId != null ? scorecardId : cur.scorecardId;
          var wantAm = assessmentWanted != null ? assessmentWanted : cur.assessmentMethod;
          var wantRm = routingWanted != null ? routingWanted : cur.routingMethod;
          if (needsScorecard(wantAm) && wantSc == null) fail('assessmentMethod ' + wantAm + ' needs a scorecard on ' + ptCode + ': set newScorecardCode to a scorecard published by the Scorecards sheet');
          var wantWf = wfKeyWanted != null ? resolveWorkflowKey(wfKeyWanted) : existing.workflowKey;
          var sheetCharges2 = chargesFromSheet();
          var diffs = [];
          if (ptName != null && ptName != ('' + existing.label)) diffs.push('label "' + existing.label + '" -> "' + ptName + '"');
          if (rowDescription != null && rowDescription != ('' + (existing.description == null ? '' : existing.description))) diffs.push('description');
          if (wantWf != existing.workflowKey) diffs.push('workflow ' + existing.workflowKey + ' -> ' + wantWf);
          if (('' + cur.scorecardId) != ('' + wantSc)) diffs.push('scorecard ' + cur.scorecardId + ' -> ' + wantSc);
          if (('' + cur.assessmentMethod) != ('' + wantAm)) diffs.push('assessment ' + cur.assessmentMethod + ' -> ' + wantAm);
          if (('' + cur.routingMethod) != ('' + wantRm)) diffs.push('routing ' + cur.routingMethod + ' -> ' + wantRm);
          if (sheetCharges2 != null && JSON.stringify(sheetCharges2) != JSON.stringify(stripCharges(cur.charges))) diffs.push('charges');
          if (diffs.length == 0) {
            summary.push('already matches the sheet (id ' + id + ')');
          } else {
            note('product type ' + ptCode + ' differs from the sheet: ' + diffs.join(', ') + ' - requesting an amendment');
            amendTypeConfig(ptCode, 'amend product type ' + ptCode + ' (' + diffs.join(', ') + ')', [ptCode, id], function(cfg2) {
              cfg2.scorecardId = wantSc; cfg2.assessmentMethod = wantAm; cfg2.routingMethod = wantRm;
              if (sheetCharges2 != null) cfg2.charges = sheetCharges2;
              return true;
            }, { label: ptName != null ? ptName : undefined, description: rowDescription != null ? rowDescription : undefined, workflowKey: wantWf,
                 hasExtendedFields: (existing.hasExtendedFields == true || strVal(td.extendedFields, null) != null) });
            var after = typeConfigOf(ptCode);
            if (('' + after.scorecardId) != ('' + wantSc) || ('' + after.assessmentMethod) != ('' + wantAm)) fail('product type ' + ptCode + ' amendment was committed but its configuration is scorecard ' + after.scorecardId + ' / ' + after.assessmentMethod + ', expected ' + wantSc + ' / ' + wantAm);
            summary.push('amended: ' + diffs.join(', '));
          }
        }
        var ra = setupRoleAccess(); if (ra != null) summary.push(ra);
        var fl = setupFields(); if (fl != null) summary.push(fl);
        var pr = setupProducts(scorecardId != null ? scorecardId : typeConfigOf(ptCode).scorecardId); if (pr != null) summary.push(pr);
        var pu = setupPurposes(); if (pu != null) summary.push(pu);
        var vo = verifyOfficerCanSubmit(); if (vo != null) summary.push(vo);
        // A CREATE row may also carry attach* / detach* columns (charges, checklist, scorecard by name, ...): apply them now.
        if (hasLinkColumns()) { var la = executeLinkAmend(getSchema().body); summary.push(la.substring(la.indexOf('): ') + 3)); }
        return 'product type ' + ptCode + ' (id ' + id + '): ' + summary.join(' | ');
      }
      """
    * def summary = executeProductType()
    * note('PRODUCT TYPE ' + action + ' COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(karate.get('adminHeaderVal'))
