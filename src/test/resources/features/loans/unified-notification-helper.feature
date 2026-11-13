@ignore
Feature: Unified Notification Helper - CREATE, AMEND, DELETE for the Notification_Templates and Notification_Rules sheets

  # ── HOW A ROW IS INTERPRETED ───────────────────────────────────────────────────────────────
  #   CREATE : make the record match the sheet. Missing -> created; present -> amended when it differs.
  #   AMEND  : same as CREATE but the record MUST already exist (a typo in the name fails the row).
  #   DELETE : remove the record; anything that references it is detached first.
  # Every governed change (HTTP 202 / ChangeRequest) is approved by a four-eyes checker and committed.
  # Server rules that shape this file were verified against the backend sources on 2026-09-17.

  Scenario: Execute Single Notification Template or Rule Row
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
    * def rowTag = '[NOTIFICATION ' + action + ' ' + strVal(td.ruleId != null ? td.ruleId : td.templateId, strVal(td.ruleName, strVal(td.templateName, 'row'))) + ']'
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

    * def canConfigure = function(header) { var r = api('GET', '/v1/notification/templates?module=LO', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canConfigure(h)) return { user: excelAdminUser, header: h, pass: excelAdminPass, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot configure notifications (403) - falling back to default admin ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
        if (h2 != null && canConfigure(h2)) return { user: defaultAdminUsername, header: h2, pass: defaultAdminPassword, source: 'karate-config' };
        if (h2 != null) logout(h2);
        tried.push(defaultAdminUsername);
        fail('no admin account can configure notifications. Tried: ' + tried.join(', '));
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

    # ── Which sheet this row came from ────────────────────────────────────────
    # 00-Setup-All-Configurations tags rows with _kind (TEMPLATE | RULE); the column sniff is a fallback.
    * def kind = (td._kind != null && ('' + td._kind).toUpperCase() == 'RULE') || (td._kind == null && (strVal(td.ruleName, null) != null || strVal(td.eventCode, null) != null)) ? 'RULE' : 'TEMPLATE'
    * def MODULE = 'LO'
    # newName renames an existing template / rule (the row is still found by templateName / ruleName or the TPL code).
    * def ntfNewName = strVal(td.newName, null)
    * def TPL_HINTS = ['NOTIFICATION_TEMPLATE', 'NOTIF']
    * def RUL_HINTS = ['NOTIFICATION_RULE', 'NOTIF']

    # ── Lookups (notification endpoints return bare JSON lists) ──────────────
    * def listTemplates =
      """
      function() {
        var r = api('GET', '/v1/notification/templates?module=' + MODULE, adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list message templates: ' + show(r));
        return r.body;
      }
      """
    * def findTemplate = function(list, ref, format) { for (var i = 0; i < list.length; i++) { var t = list[i]; if (format != null && !eq(t.format, format)) continue; if (eq(t.templateCode, ref) || eq(t.name, ref)) return t; } return null; }
    * def listRules =
      """
      function() {
        var r = api('GET', '/v1/notification/rules?module=' + MODULE, adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot list notification rules: ' + show(r));
        return r.body;
      }
      """
    * def findRule = function(name) { var list = listRules(); for (var i = 0; i < list.length; i++) { if (eq(list[i].ruleName, name)) return list[i]; } return null; }

    # ═════════════════════════════════════════════════════════════════════════
    # A. MESSAGE TEMPLATE (New Template form). The server derives the format from the subject
    #    (EMAIL when a subject is present), keeps contentType PLAIN or HTML, and assigns TPL-NNN.
    #    Names are not unique server-side, so the sheet's templateName + format identify a template.
    # ═════════════════════════════════════════════════════════════════════════
    * def executeTemplate =
      """
      function() {
        var name = req('templateName', 'on every template row (Template Name, or the TPL-NNN code)');
        var format = strVal(td.format, 'SMS').toUpperCase();
        if (format != 'SMS' && format != 'EMAIL') fail('format must be SMS or EMAIL, not ' + format);
        var existing = findTemplate(listTemplates(), name, /^TPL-\d+$/i.test(name) ? null : format);
        if (existing != null && eq(existing.templateCode, name)) {
          note('template code ' + name + ' resolved to "' + existing.name + '" (' + existing.format + ', id ' + existing.id + ')');
          name = '' + existing.name; format = '' + existing.format;
        }
        if (action == 'DELETE') {
          if (existing == null) { note('template "' + name + '" (' + format + ') does not exist - nothing to delete'); return 'template "' + name + '" not found (nothing to delete)'; }
          var users = [];
          var rules = listRules();
          for (var r = 0; r < rules.length; r++) {
            var tg = rules[r].targets != null ? rules[r].targets : [];
            for (var t = 0; t < tg.length; t++) { if (eq(tg[t].templateCode, existing.templateCode) || eq(tg[t].attachmentTemplateCode, existing.templateCode)) { users.push(rules[r].ruleName); break; } }
          }
          if (users.length > 0) fail('template ' + existing.templateCode + ' "' + name + '" is still used by notification rule(s) ' + users.join(', ') + ' - the server refuses to delete it. Delete or re-point those rules first (Notification_Rules sheet).');
          var sendDel = function() { return api('DELETE', '/v1/notification/templates/' + existing.id, adminHeader, null); };
          governed('delete template ' + existing.templateCode + ' (' + name + ')', sendDel(), sendDel, TPL_HINTS, [name, existing.templateCode, existing.id]);
          if (findTemplate(listTemplates(), name, format) != null) fail('template ' + existing.templateCode + ' is still listed after its deletion was committed');
          return 'template ' + existing.templateCode + ' "' + name + '" (' + format + ') deleted';
        }
        if (action == 'AMEND' && existing == null) fail('template "' + name + '" (' + format + ') does not exist on ' + baseUrl + ' - nothing to amend (use create=true, or fix templateName / format)');
        var language = strVal(td.language, 'EN').toUpperCase();
        var subject = strVal(td.subject, null);
        var body = req('body', 'on every template row (Message Body)');
        var contentType = strVal(td.contentType, 'HTML').toUpperCase();
        if (format == 'EMAIL' && subject == null) fail('subject is required for an EMAIL template (the server derives the format from it)');
        if (format == 'SMS' && subject != null) { note('subject is ignored for an SMS template (a subject would turn it into an EMAIL template)'); subject = null; }
        if (contentType != 'HTML' && contentType != 'PLAIN') fail('contentType must be HTML or PLAIN, not ' + contentType);
        var active = boolVal(td.active, true);
        var wantName = (existing != null && ntfNewName != null) ? ntfNewName : name;
        if (existing != null && ntfNewName != null && ntfNewName != ('' + existing.name)) note('template ' + existing.templateCode + ' will be renamed "' + existing.name + '" -> "' + ntfNewName + '"');
        var desired = { module: MODULE, name: wantName, format: format, subject: subject, body: body, languageCode: language, active: active, contentType: format == 'EMAIL' ? contentType : 'HTML' };
        var same = function(t) { return eq(t.name, desired.name) && eq(t.format, desired.format) && ('' + (t.subject == null ? '' : t.subject)) == ('' + (desired.subject == null ? '' : desired.subject)) && ('' + t.body).replace(/\r\n/g, '\n') == ('' + desired.body).replace(/\r\n/g, '\n') && eq(t.languageCode, desired.languageCode) && (t.active != false) == desired.active && (format != 'EMAIL' || eq(t.contentType, desired.contentType)); };
        var outcome = null; var id = null; var code = null;
        if (existing != null) {
          id = existing.id; code = existing.templateCode;
          if (same(existing)) { note('template ' + code + ' "' + name + '" already matches the sheet - nothing to change'); outcome = 'unchanged'; }
          else {
            note('template ' + code + ' "' + name + '" differs from the sheet - requesting an amendment');
            var body2 = karate.merge(desired, { id: id, templateCode: code });
            var send = function() { return api('PUT', '/v1/notification/templates/' + id, adminHeader, body2); };
            governed('amend template ' + code + ' (' + name + ')', send(), send, TPL_HINTS, [name, code, id]);
            outcome = 'amended';
          }
        } else {
          var create = function() { return api('POST', '/v1/notification/templates?module=' + MODULE, adminHeader, desired); };
          governed('create template (' + name + ', ' + format + ')', create(), create, TPL_HINTS, [name]);
          var made = null;
          for (var i = 0; i < 30 && made == null; i++) { made = findTemplate(listTemplates(), wantName, format); if (made == null) java.lang.Thread.sleep(1000); }
          if (made == null) fail('the change request for template "' + name + '" was committed but no ' + format + ' template with that name is listed afterwards');
          id = made.id; code = made.templateCode; outcome = 'created';
        }
        var g = api('GET', '/v1/notification/templates/' + id, adminHeader, null);
        if (g.status != 200 || g.body == null) fail('VERIFY: template ' + code + ' cannot be read back: ' + show(g));
        if (!same(g.body)) fail('VERIFY: template ' + code + ' does not match the sheet after ' + outcome + '. Server: ' + karate.pretty(g.body));
        var t = g.body;
        return 'template ' + t.templateCode + ' (id ' + t.id + ') ' + outcome + ': "' + t.name + '" ' + t.format + ' ' + t.languageCode + (t.subject != null ? ' | subject "' + t.subject + '"' : '') + ' | active=' + t.active + ' | body ' + ('' + t.body).length + ' chars';
      }
      """

    # ═════════════════════════════════════════════════════════════════════════
    # B. NOTIFICATION RULE (Add Notification Rule form).
    #    targets = every channel x every recipient; recipientType PARTY | ROLE | USER (+ recipientParam);
    #    IN_APP / PUSH cannot target PARTY; templateCode must be an existing template (checked at commit,
    #    so it is validated here up front); rule names are unique per module and may only contain
    #    letters, digits, spaces, _ and -.
    # ═════════════════════════════════════════════════════════════════════════
    * def executeRule =
      """
      function() {
        var ruleName = req('ruleName', 'on every rule row (Rule Name)');
        if (!/^[A-Za-z][A-Za-z0-9 _-]*$/.test(ruleName)) fail('ruleName "' + ruleName + '" is not accepted by the server: use letters, digits, spaces, _ and - only (no parentheses or other punctuation)');
        var existing = findRule(ruleName);
        if (action == 'DELETE') {
          if (existing == null) { note('rule "' + ruleName + '" does not exist - nothing to delete'); return 'rule "' + ruleName + '" not found (nothing to delete)'; }
          var sendDel = function() { return api('DELETE', '/v1/notification/rules/' + existing.id + '?module=' + MODULE, adminHeader, null); };
          governed('delete rule ' + existing.id + ' (' + ruleName + ')', sendDel(), sendDel, RUL_HINTS, [ruleName, existing.id]);
          if (findRule(ruleName) != null) fail('rule "' + ruleName + '" (id ' + existing.id + ') is still listed after its deletion was committed');
          return 'rule ' + existing.id + ' "' + ruleName + '" deleted';
        }
        if (action == 'AMEND' && existing == null) fail('rule "' + ruleName + '" does not exist on ' + baseUrl + ' - nothing to amend (use create=true, or fix ruleName)');
        var eventCode = pickOption(genericOptions('LO_NOTIF_TRIGGER'), req('eventCode', 'on every rule row (Event Code)'), 'eventCode');
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
        var chOpts = genericOptions('NOTIF_CHANNEL');
        var chRaw = splitList(td.channels);
        if (chRaw.length == 0) fail('channels is required on every rule row (SMS, EMAIL, IN_APP, PUSH)');
        var channels = [];
        for (var k = 0; k < chRaw.length; k++) { var cc = pickOption(chOpts, chRaw[k], 'channel'); if (channels.indexOf(cc) < 0) channels.push(cc); }
        var rawRec = parseJson('recipients', true);
        if (rawRec.length == 0) fail('recipients must list at least one recipient, e.g. [{"type":"PARTY","param":"PRIMARY_APPLICANT"}]');
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
            if (partyRoles == null) partyRoles = genericOptions('LO_PARTY_ROLE');
            param = pickOption(partyRoles, param == null ? '' : param, 'recipients[' + r + '] party role');
            if (channels.indexOf('IN_APP') >= 0 || channels.indexOf('PUSH') >= 0) fail('In-App and Push notifications cannot be sent to the applicant (PARTY). Remove the PARTY recipient or the IN_APP / PUSH channel.');
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
        var all = listTemplates();
        var rawPairs = strVal(td.channelTemplates, '');
        var pairs = splitList(rawPairs, rawPairs.indexOf(';') >= 0 ? ';' : ',');
        var chTpl = {};
        for (var p = 0; p < pairs.length; p++) {
          var kv = pairs[p].split('=');
          if (kv.length != 2 || kv[0].trim() == '' || kv[1].trim() == '') fail('channelTemplates entry "' + pairs[p] + '" must look like CHANNEL=Template Name (separate channels with ;)');
          chTpl[pickOption(chOpts, kv[0].trim(), 'channelTemplates channel')] = kv[1].trim();
        }
        var tplCodes = {};
        for (var x = 0; x < channels.length; x++) {
          var ch = channels[x];
          if (chTpl[ch] == null) fail('channelTemplates has no template for channel ' + ch + ' (every channel needs one: "SMS=Name; EMAIL=Name")');
          var wantFormat = ch == 'EMAIL' ? 'EMAIL' : 'SMS';
          var tpl = findTemplate(all, chTpl[ch], wantFormat);
          if (tpl == null) {
            var names2 = []; for (var y = 0; y < all.length; y++) { if (eq(all[y].format, wantFormat)) names2.push(all[y].templateCode + ' = ' + all[y].name); }
            fail('template "' + chTpl[ch] + '" for channel ' + ch + ' is not a ' + wantFormat + ' template on this server. Create it in the Notification_Templates sheet, or use one of: ' + names2.join(', '));
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
        var wantRuleName = (existing != null && ntfNewName != null) ? ntfNewName : ruleName;
        if (wantRuleName != ruleName) {
          if (!/^[A-Za-z][A-Za-z0-9 _-]*$/.test(wantRuleName)) fail('newName "' + wantRuleName + '" is not accepted by the server: use letters, digits, spaces, _ and - only');
          var clash = findRule(wantRuleName);
          if (clash != null && ('' + clash.id) != ('' + existing.id)) fail('newName "' + wantRuleName + '" is already used by rule ' + clash.id + ' - rule names are unique per module');
          note('rule ' + existing.id + ' will be renamed "' + ruleName + '" -> "' + wantRuleName + '"');
        }
        var desired = { ruleName: wantRuleName, eventCode: eventCode, conditionTree: conditionTree, active: active, targets: targets };
        var norm = function(rule) {
          var ts = [];
          var tg = rule.targets != null ? rule.targets : [];
          for (var i2 = 0; i2 < tg.length; i2++) { var t2 = tg[i2]; ts.push(t2.channel + '|' + t2.recipientType + '|' + (t2.recipientParam == null ? '' : t2.recipientParam) + '|' + t2.templateCode + '|' + (t2.attachmentTemplateCode == null ? '' : t2.attachmentTemplateCode)); }
          ts.sort();
          var canon = function(n) {
            if (n == null) return '';
            if (n.children != null && n.children.length > 0) { var cs = []; for (var c2 = 0; c2 < n.children.length; c2++) cs.push(canon(n.children[c2])); cs.sort(); return ('' + n.op).toUpperCase() + '(' + cs.join(',') + ')'; }
            if (n.variable == null) return '';
            return n.variable + '|' + ('' + n.operator).toUpperCase() + '|' + JSON.stringify(n.value === undefined ? null : n.value) + '|' + JSON.stringify(n.value2 === undefined ? null : n.value2);
          };
          return ('' + rule.eventCode) + '#' + (rule.active != false) + '#' + canon(rule.conditionTree) + '#' + ts.join(',');
        };
        var outcome = null; var id = null;
        if (existing != null) {
          id = existing.id;
          if (norm(existing) == norm(desired) && ('' + existing.ruleName) == desired.ruleName) { note('rule ' + id + ' "' + ruleName + '" already matches the sheet - nothing to change'); outcome = 'unchanged'; }
          else {
            note('rule ' + id + ' "' + ruleName + '" differs from the sheet - requesting an amendment');
            var body2 = karate.merge(desired, { id: id });
            var send = function() { return api('PUT', '/v1/notification/rules/' + id + '?module=' + MODULE, adminHeader, body2); };
            governed('amend rule ' + id + ' (' + ruleName + ')', send(), send, RUL_HINTS, [ruleName, id]);
            outcome = 'amended';
          }
        } else {
          var create = function() { return api('POST', '/v1/notification/rules?module=' + MODULE, adminHeader, desired); };
          governed('create rule (' + ruleName + ')', create(), create, RUL_HINTS, [ruleName]);
          var made = null;
          for (var i3 = 0; i3 < 30 && made == null; i3++) { made = findRule(ruleName); if (made == null) java.lang.Thread.sleep(1000); }
          if (made == null) fail('the change request for rule "' + ruleName + '" was committed but no rule with that name is listed afterwards');
          id = made.id; outcome = 'created';
        }
        var g = api('GET', '/v1/notification/rules/' + id + '?module=' + MODULE, adminHeader, null);
        if (g.status != 200 || g.body == null) fail('VERIFY: rule ' + id + ' cannot be read back: ' + show(g));
        if (('' + g.body.ruleName) != desired.ruleName) fail('VERIFY: rule ' + id + ' is named "' + g.body.ruleName + '" after ' + outcome + ', expected "' + desired.ruleName + '"');
        if (norm(g.body) != norm(desired)) fail('VERIFY: rule ' + id + ' does not match the sheet after ' + outcome + '. Server: ' + karate.pretty(g.body) + ' Sheet: ' + karate.pretty(desired));
        var parts = [];
        for (var z = 0; z < g.body.targets.length; z++) { var tz = g.body.targets[z]; parts.push(tz.channel + ' -> ' + tz.recipientType + (tz.recipientParam != null ? ' ' + tz.recipientParam : '') + ' [' + tz.templateCode + ']'); }
        return 'rule ' + g.body.id + ' "' + g.body.ruleName + '" ' + outcome + ': on ' + g.body.eventCode + (g.body.conditionTree != null ? ' when ' + JSON.stringify(g.body.conditionTree) : ' (every event)') + ' | active=' + g.body.active + ' | ' + parts.join(' | ');
      }
      """
    * def summary = kind == 'RULE' ? executeRule() : executeTemplate()
    * note((kind == 'RULE' ? 'NOTIFICATION RULE ' : 'MESSAGE TEMPLATE ') + action + ' COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(karate.get('adminHeaderVal'))
