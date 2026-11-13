@ignore
Feature: Unified Approval Limit Helper - CREATE, AMEND, DELETE for the Approval_Limits sheet

  # ── HOW A ROW IS INTERPRETED ───────────────────────────────────────────────────────────────
  #   CREATE : make the record match the sheet. Missing -> created; present -> amended when it differs.
  #   AMEND  : same as CREATE but the record MUST already exist (a typo in the name fails the row).
  #   DELETE : remove the record; anything that references it is detached first.
  # Every governed change (HTTP 202 / ChangeRequest) is approved by a four-eyes checker and committed.
  # Server rules that shape this file were verified against the backend sources on 2026-09-17.

  Scenario: Execute Single Approval Limit Row
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
    * def rowTag = '[APPROVAL-LIMIT ' + action + ' ' + strVal(td.limitId, strVal(td.authorityName, 'row')) + ']'
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

    * def canConfigure = function(header) { var r = api('GET', '/v1/approval-limits?size=1', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canConfigure(h)) return { user: excelAdminUser, header: h, pass: excelAdminPass, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot configure approval limits (403) - falling back to default admin ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
        if (h2 != null && canConfigure(h2)) return { user: defaultAdminUsername, header: h2, pass: defaultAdminPassword, source: 'karate-config' };
        if (h2 != null) logout(h2);
        tried.push(defaultAdminUsername);
        fail('no admin account can configure approval limits. Tried: ' + tried.join(', '));
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

    # ── Row fields (New Approval Limit form) ──────────────────────────────────
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
    * def authorityType = toAuthorityType(req('authorityType', 'on every approval limit row (User | Role | Credit Committee)'))
    * def authorityNameRaw = req('authorityName', 'on every approval limit row (username, role, or credit-committee role)')
    * def loanTypeRaw = req('loanType', 'on every approval limit row (the product type code or name)')
    * def subProductRaw = strVal(td.subProductCode, null)
    * def currencyCode = strVal(td.currencyCode, 'USD').toUpperCase()
    * def partyType = strVal(td.partyType, null) == null ? null : strVal(td.partyType, null).toUpperCase()
    * def facilityType = strVal(td.facilityType, 'LOAN').toUpperCase()
    * def withinBranch = boolVal(td.approvalWithinBranch, true)
    * def selfAllowed = authorityType == 'USER' ? boolVal(td.approvalBySelfAllowed, false) : false
    * def votesRequired = numVal(td.votesRequired, null)
    * def LIM_HINTS = ['APPROVAL_LIMIT']
    * if (partyType != null && partyType != 'PERSONAL' && partyType != 'ENTERPRISE') fail('partyType must be PERSONAL, ENTERPRISE or blank (any party), not ' + partyType)
    * if (['LOAN', 'OVERDRAFT', 'COMMITMENTS'].indexOf(facilityType) < 0) fail('facilityType must be LOAN, OVERDRAFT or COMMITMENTS, not ' + facilityType)

    # ── Resolve the dropdown values the form offers ───────────────────────────
    * def resolveAuthorityName =
      """
      function() {
        if (authorityType == 'USER') {
          var u = api('GET', '/v1/users', adminHeader, null);
          if (u.status != 200 || u.body == null) fail('cannot list users to validate authorityName: ' + show(u));
          var ul = u.body.content != null ? u.body.content : u.body;
          var names = [];
          for (var i = 0; i < ul.length; i++) {
            var row = ul[i];
            names.push(row.username + (row.fullName != null ? ' (' + row.fullName + ')' : ''));
            if (eq(row.username, authorityNameRaw) || eq(row.fullName, authorityNameRaw)) return '' + row.username;
          }
          fail('authorityName "' + authorityNameRaw + '" is not a user. Users: ' + names.join(', '));
        }
        var r = api('GET', '/v1/master-data/role-definitions?size=500', adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list role definitions to validate authorityName: ' + show(r));
        var list = r.body.content != null ? r.body.content : r.body;
        var opts = [];
        for (var j = 0; j < list.length; j++) {
          var role = list[j];
          if (role.active == false) continue;
          opts.push(role.roleCode + ' = ' + role.roleName);
          if (eq(role.roleCode, authorityNameRaw) || eq(role.roleName, authorityNameRaw) || eq('ROLE_' + role.roleCode, authorityNameRaw)) return '' + role.roleCode;
        }
        fail('authorityName "' + authorityNameRaw + '" is not an active role. Roles: ' + opts.join(', '));
      }
      """
    * def authorityName = resolveAuthorityName()
    # The loan type is the product type CODE. On DELETE the type may already be gone (it is deleted after its limits), so the raw value is kept.
    * def loanTypeObj = findProductType(loanTypeRaw)
    * if (loanTypeObj == null && action != 'DELETE') resolveProductType(loanTypeRaw, 'loanType names it - create it in the Product_Types sheet first')
    * def loanType = loanTypeObj != null ? '' + loanTypeObj.code : loanTypeRaw
    * def ltPath = encodeURIComponent(loanType)
    * def subProductCode = subProductRaw == null ? null : (loanTypeObj != null ? resolveSubProduct(loanType, subProductRaw) : subProductRaw)
    * def what = authorityType + ' ' + authorityName + ' on ' + loanType + (subProductCode != null ? '/' + subProductCode : '') + (partyType != null ? ' (' + partyType + ')' : '') + ' ' + currencyCode

    # ── Existing ACTIVE limit for the same authority / loan type / sub-product / party / currency ─
    # Search: size is capped at 100 by the server and there is no authorityName filter, so the match is done here.
    * def findExisting =
      """
      function() {
        var r = api('GET', '/v1/approval-limits?status=ACTIVE&size=100&loanType=' + ltPath + '&currencyCode=' + encodeURIComponent(currencyCode) + '&authorityType=' + authorityType, adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search approval limits: ' + show(r));
        var rows = r.body.content != null ? r.body.content : r.body;
        var same = function(a, b) { var x = strVal(a, null); var y = strVal(b, null); return (x == null && y == null) || (x != null && y != null && x.toLowerCase() == y.toLowerCase()); };
        // The server's duplicate rule (AC3) treats a party-agnostic limit as the same record as a PERSONAL /
        // ENTERPRISE one, so such a limit is matched (and amended) rather than duplicated.
        var fallback = null;
        for (var i = 0; i < rows.length; i++) {
          var l = rows[i];
          if (l.status != 'ACTIVE') continue;
          if (!same(l.authorityName, authorityName) || !same(l.subProductCode, subProductCode)) continue;
          if (same(l.partyType, partyType)) return l;
          if (fallback == null && (strVal(l.partyType, null) == null || partyType == null)) fallback = l;
        }
        return fallback;
      }
      """
    * def differences =
      """
      function(l, d) {
        var out = [];
        if (Number(l.limitAmount) != Number(d.limitAmount)) out.push('limitAmount ' + l.limitAmount + ' -> ' + d.limitAmount);
        if (strVal(l.effectiveFrom, null) != d.effectiveFrom) out.push('effectiveFrom ' + l.effectiveFrom + ' -> ' + d.effectiveFrom);
        if (strVal(l.effectiveTo, null) != d.effectiveTo) out.push('effectiveTo ' + l.effectiveTo + ' -> ' + (d.effectiveTo == null ? 'open-ended' : d.effectiveTo));
        var lb = l.approvalWithinBranch == null ? true : l.approvalWithinBranch == true;
        if (lb != d.approvalWithinBranch) out.push('approvalWithinBranch ' + lb + ' -> ' + d.approvalWithinBranch);
        if (authorityType == 'USER' && (l.approvalBySelfAllowed == true) != d.approvalBySelfAllowed) out.push('approvalBySelfAllowed ' + (l.approvalBySelfAllowed == true) + ' -> ' + d.approvalBySelfAllowed);
        if (authorityType == 'CREDIT_COMMITTEE' && Number(l.votesRequired) != Number(d.votesRequired)) out.push('votesRequired ' + l.votesRequired + ' -> ' + d.votesRequired);
        if (strVal(l.facilityType, 'LOAN').toUpperCase() != d.facilityType) out.push('facilityType ' + l.facilityType + ' -> ' + d.facilityType);
        var lp = strVal(l.partyType, null); var lpu = lp == null ? null : lp.toUpperCase();
        if (lpu != d.partyType) out.push('partyType ' + (lpu == null ? 'any' : lpu) + ' -> ' + (d.partyType == null ? 'any' : d.partyType));
        return out;
      }
      """

    # ── Execute ───────────────────────────────────────────────────────────────
    * def executeLimit =
      """
      function() {
        var existing = findExisting();
        if (action == 'DELETE') {
          if (existing == null) { note('no ACTIVE approval limit for ' + what + ' - nothing to delete'); return 'limit for ' + what + ' not found (nothing to delete)'; }
          var sendDel = function() { return api('POST', '/v1/approval-limits/' + existing.id + '/request-deletion', adminHeader, {}); };
          governed('delete limit ' + existing.id + ' (' + what + ')', sendDel(), sendDel, LIM_HINTS, [loanType, authorityName, existing.id]);
          var g0 = api('GET', '/v1/approval-limits/' + existing.id, adminHeader, null);
          if (g0.status == 200 && g0.body != null && g0.body.status == 'ACTIVE') fail('limit ' + existing.id + ' is still ACTIVE after its deletion was committed');
          return 'limit ' + existing.id + ' (' + what + ', ' + existing.limitAmount + ' ' + existing.currencyCode + ') -> ' + (g0.status == 200 && g0.body != null ? g0.body.status : 'deleted');
        }
        if (action == 'AMEND' && existing == null) fail('no ACTIVE approval limit for ' + what + ' on ' + baseUrl + ' - nothing to amend (use create=true, or fix authorityName / loanType / subProductCode / partyType / currencyCode)');
        var limitAmount = numVal(req('limitAmount', 'on every approval limit row'), null);
        if (limitAmount == null || limitAmount <= 0) fail('limitAmount must be a positive number');
        if (authorityType == 'CREDIT_COMMITTEE' && votesRequired == null) fail('votesRequired is required for a Credit Committee limit (<= active members of the committee role)');
        var desired = {
          authorityType: authorityType, authorityName: authorityName, facilityType: facilityType, loanType: loanType,
          subProductCode: subProductCode, partyType: partyType, limitAmount: limitAmount, currencyCode: currencyCode,
          effectiveFrom: isoDate(req('effectiveFrom', 'on every approval limit row (yyyy-MM-dd; a past date so the limit applies today)'), 'effectiveFrom'),
          effectiveTo: isoDate(td.effectiveTo, 'effectiveTo'),
          approvalWithinBranch: withinBranch, approvalBySelfAllowed: selfAllowed,
          votesRequired: authorityType == 'CREDIT_COMMITTEE' ? votesRequired : null
        };
        if (desired.effectiveTo != null && desired.effectiveTo <= desired.effectiveFrom) fail('effectiveTo ' + desired.effectiveTo + ' must be after effectiveFrom ' + desired.effectiveFrom);
        if (desired.effectiveTo != null && desired.effectiveTo <= today) fail('effectiveTo ' + desired.effectiveTo + ' is not after today - the server refuses to commit an expired limit (AC5)');
        var outcome = null; var id = null;
        if (existing != null) {
          id = existing.id;
          var diff = differences(existing, desired);
          if (diff.length == 0) { note('limit ' + id + ' already ACTIVE and identical to the sheet (' + what + ') - nothing to change'); outcome = 'unchanged'; }
          else {
            note('limit ' + id + ' differs from the sheet: ' + diff.join(', ') + ' - requesting an amendment');
            var body = karate.merge(desired, { id: id });
            var send = function() { return api('PUT', '/v1/approval-limits/' + id + '/request-amendment', adminHeader, body); };
            governed('amend limit ' + id + ' (' + what + ')', send(), send, LIM_HINTS, [loanType, authorityName, id]);
            outcome = 'amended';
          }
        } else {
          var create = function() { return api('POST', '/v1/approval-limits', adminHeader, desired); };
          governed('create limit (' + what + ' ' + limitAmount + ')', create(), create, LIM_HINTS, [loanType, authorityName]);
          var made = null;
          for (var i = 0; i < 30 && made == null; i++) { made = findExisting(); if (made == null) java.lang.Thread.sleep(1000); }
          if (made == null) fail('the change request for ' + what + ' was committed but no ACTIVE limit for that authority / loan type / sub-product / party type / currency can be found afterwards');
          id = made.id; outcome = 'created';
        }
        var g = api('GET', '/v1/approval-limits/' + id, adminHeader, null);
        if (g.status != 200 || g.body == null) fail('VERIFY: limit ' + id + ' cannot be read back: ' + show(g));
        var l = g.body;
        if (l.status != 'ACTIVE') fail('VERIFY: limit ' + id + ' is ' + l.status + ', expected ACTIVE');
        var diff2 = differences(l, desired);
        if (diff2.length > 0) fail('VERIFY: limit ' + id + ' does not match the sheet after ' + outcome + ': ' + diff2.join(', '));
        return 'limit ' + l.id + ' ' + outcome + ': ' + l.authorityType + ' ' + l.authorityName + ' | ' + l.loanType + (l.subProductCode != null ? ' / ' + l.subProductCode : ' / all sub-products') + ' | ' + l.limitAmount + ' ' + l.currencyCode + ' | ' + l.effectiveFrom + ' to ' + (l.effectiveTo != null ? l.effectiveTo : 'open-ended') + ' | own branch only=' + (l.approvalWithinBranch == null ? true : l.approvalWithinBranch) + (l.votesRequired != null ? ' | votes=' + l.votesRequired : '') + (l.partyType != null ? ' | party=' + l.partyType : ' | any party');
      }
      """
    * def summary = executeLimit()
    * note('APPROVAL LIMIT ' + action + ' COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(karate.get('adminHeaderVal'))
