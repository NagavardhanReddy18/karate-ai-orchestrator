@ignore
Feature: Unified Incident Charge Helper - CREATE, AMEND, DELETE for the Incident_Charges sheet

  # ── HOW A ROW IS INTERPRETED ───────────────────────────────────────────────────────────────
  #   CREATE : make the record match the sheet. Missing -> created; present -> amended when it differs.
  #   AMEND  : same as CREATE but the record MUST already exist (a typo in the name fails the row).
  #   DELETE : remove the record; anything that references it is detached first.
  # Every governed change (HTTP 202 / ChangeRequest) is approved by a four-eyes checker and committed.
  # Server rules that shape this file were verified against the backend sources on 2026-09-17.

  Scenario: Execute Single Incident Charge Row
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
    * def rowTag = '[CHARGE ' + action + ' ' + strVal(td.chargeId, strVal(td.chargeName, 'row')) + ']'
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

    * def canConfigure = function(header) { var r = api('GET', '/v1/config/incident-charge-definitions?status=ACTIVE', header, null); return r.status == 200; }
    * def resolveAdmin =
      """
      function() {
        var tried = [];
        if (excelAdminUser != null) {
          var h = softLogin(excelAdminUser, excelAdminPass);
          if (h != null && canConfigure(h)) return { user: excelAdminUser, header: h, pass: excelAdminPass, source: 'sheet' };
          if (h != null) { note('WARNING: sheet admin ' + excelAdminUser + ' cannot configure incident charges (403) - falling back to default admin ' + defaultAdminUsername); logout(h); }
          tried.push(excelAdminUser);
        }
        var h2 = softLogin(defaultAdminUsername, defaultAdminPassword);
        if (h2 != null && canConfigure(h2)) return { user: defaultAdminUsername, header: h2, pass: defaultAdminPassword, source: 'karate-config' };
        if (h2 != null) logout(h2);
        tried.push(defaultAdminUsername);
        fail('no admin account can configure incident charges. Tried: ' + tried.join(', '));
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

    # ── Row fields (Incident Charges Definition form) ─────────────────────────
    # chargeName may hold the charge NAME (matched together with incident + currency, names are not unique server-side)
    # or the charge CODE (CHG-000044); with a code, the record's own name, incident and currency are taken from the server.
    * def chargeRef = req('chargeName', 'on every incident charge row (Charge Name, or the CHG-NNNNNN code)')
    * def byCode =
      """
      (function() {
        if (!/^CHG-\d+$/i.test(chargeRef)) return null;
        var r = api('GET', '/v1/config/incident-charge-definitions?search=' + encodeURIComponent(chargeRef), adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search incident charge definitions: ' + show(r));
        var list = unwrap(r.body); if (list != null && list.content != null) list = list.content;
        for (var i = 0; list != null && i < list.length; i++) { if (eq(list[i].chargeCode, chargeRef)) return list[i]; }
        fail('no incident charge has the code ' + chargeRef + ' on ' + baseUrl);
      })()
      """
    * if (byCode != null) note('charge code ' + chargeRef + ' resolved to "' + byCode.chargeName + '" (' + byCode.event + ', ' + byCode.currency + ', id ' + byCode.id + ')')
    * def chargeName = byCode != null ? '' + byCode.chargeName : chargeRef
    # newName renames an existing charge (the row is still found by chargeName / code + incident + currency).
    * def chNewName = strVal(td.newName, null)
    * def STAGE_ORDER = ['APPLICATION', 'ASSESSMENT', 'OFFER', 'OFFER_ACCEPTANCE', 'SETUP']
    * def toStage = function(raw, col) { var u = ('' + raw).trim().toUpperCase().replace(/[\s-]+/g, '_'); if (u == 'DISBURSEMENT') u = 'SETUP'; if (u == 'OFFER_ACCEPT') u = 'OFFER_ACCEPTANCE'; if (STAGE_ORDER.indexOf(u) < 0) fail(col + ' "' + raw + '" is not a stage: use APPLICATION | ASSESSMENT | OFFER | OFFER_ACCEPTANCE | SETUP'); return u; }
    * def incident = byCode != null ? ('' + byCode.event).toUpperCase() : toStage(req('incident', 'on every incident charge row (Incident: APPLICATION | ASSESSMENT | OFFER | SETUP)'), 'incident')
    * if (incident == 'OFFER_ACCEPTANCE') fail('incident OFFER_ACCEPTANCE is only a collection stage (Deferred Until) - a charge is levied at APPLICATION | ASSESSMENT | OFFER | SETUP')
    * def currency = byCode != null ? ('' + byCode.currency).toUpperCase() : strVal(td.currency, 'USD').toUpperCase()
    * def attachTypes = splitList(td.attachToProductTypes)
    * def attachSubs = splitList(td.attachToSubProducts)
    * def CH_HINTS = ['INCIDENT_CHARGE', 'CHARGE']
    * def what = chargeName + ' (' + incident + ', ' + currency + ')'

    # ── Existing charge with the same name / incident / currency ─────────────
    * def listCharges =
      """
      function() {
        var r = api('GET', '/v1/config/incident-charge-definitions?search=' + encodeURIComponent(chargeName), adminHeader, null);
        if (r.status != 200 || r.body == null) fail('cannot search incident charge definitions: ' + show(r));
        var list = unwrap(r.body);
        if (list != null && list.content != null) list = list.content;
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
    * def readCharge = function(id) { var g = api('GET', '/v1/config/incident-charge-definitions/' + id, adminHeader, null); if (g.status != 200) fail('charge ' + id + ' cannot be read back: ' + show(g)); return unwrap(g.body); }

    # ── Desired record, as the form would submit it ───────────────────────────
    # Server contract: chargeNarration (not narration), applicableChannels is a CSV string, chargePseudonym
    # (Charge Receiving Account) is mandatory, taxRate requires taxCurrency + taxPseudonym, min/max only
    # apply to PERCENTAGE, effectiveFromDate must be today or later when CREATING (free on amend).
    * def buildDesired =
      """
      function() {
        var methodRaw = strVal(td.calculationMethod, 'FLAT').toUpperCase().replace(/[\s-]+/g, '_');
        var method = methodRaw == 'FIXED' ? 'FLAT' : (methodRaw == 'TIERS_FLAT' ? 'TIERS_FIXED' : methodRaw);
        if (['FLAT', 'PERCENTAGE', 'TIERS_FIXED', 'TIERS_PERCENTAGE'].indexOf(method) < 0) fail('calculationMethod must be FLAT (FIXED) | PERCENTAGE | TIERS_FIXED | TIERS_PERCENTAGE, not ' + methodRaw);
        var flatAmount = numVal(td.flatAmount, null);
        var rate = numVal(td.rate, null);
        var calcBase = strVal(td.calcBase, null) == null ? null : strVal(td.calcBase, null).toUpperCase();
        var minCharge = numVal(td.minCharge, null);
        var maxCharge = numVal(td.maxCharge, null);
        if (method == 'FLAT' && flatAmount == null) fail('flatAmount is required for calculationMethod FLAT');
        if (method == 'PERCENTAGE' && rate == null) fail('rate is required for calculationMethod PERCENTAGE');
        if (rate != null && rate < 0) fail('rate must not be negative');
        if ((method == 'PERCENTAGE' || method == 'TIERS_PERCENTAGE') && calcBase == null) fail('calcBase (LOAN_AMOUNT | LIMIT_AMOUNT) is required for calculationMethod ' + method);
        if (calcBase != null) { calcBase = calcBase.replace(/[\s-]+/g, '_'); if (calcBase == 'APPROVED_LOAN_AMOUNT') calcBase = 'LOAN_AMOUNT'; if (calcBase != 'LOAN_AMOUNT' && calcBase != 'LIMIT_AMOUNT') fail('calcBase must be LOAN_AMOUNT (Approved Loan Amount) or LIMIT_AMOUNT, not ' + calcBase); }
        if (method == 'PERCENTAGE') {
          if (minCharge != null && minCharge < 0) fail('minCharge must not be negative');
          if (maxCharge != null && maxCharge < 0) fail('maxCharge must not be negative');
          if (minCharge != null && maxCharge != null && minCharge > maxCharge) fail('minCharge ' + minCharge + ' is greater than maxCharge ' + maxCharge);
        } else if (minCharge != null || maxCharge != null) note('minCharge / maxCharge only apply to calculationMethod PERCENTAGE (the server drops them for ' + method + ') - ignored');
        var loanTenor = strVal(td.loanTenor, null) == null ? null : strVal(td.loanTenor, null).toUpperCase();
        if (loanTenor != null) { if (loanTenor == 'MONTH') loanTenor = 'MONTHS'; if (loanTenor == 'YEAR') loanTenor = 'YEARS'; if (loanTenor != 'MONTHS' && loanTenor != 'YEARS') fail('loanTenor (Tenor In) must be MONTHS or YEARS, not ' + loanTenor); }
        var tiers = null;
        if (method == 'TIERS_FIXED' || method == 'TIERS_PERCENTAGE') {
          var tv = parseJson('tiers', true);
          if (tv.length < 2 || tv.length > 10) fail('tiers must list between 2 and 10 tiers for calculationMethod ' + method);
          tiers = [];
          for (var i = 0; i < tv.length; i++) {
            var t = tv[i];
            var tier = { tierSeq: i + 1, fromAmount: numVal(t.fromAmount, 0), toAmount: numVal(t.toAmount, null), tenorFrom: numVal(t.tenorFrom, null), tenorTo: numVal(t.tenorTo, null), fixedAmount: numVal(t.fixedAmount, null), rate: numVal(t.rate, null) };
            if (method == 'TIERS_FIXED' && tier.fixedAmount == null) fail('tiers[' + i + '] needs fixedAmount for TIERS_FIXED');
            if (method == 'TIERS_PERCENTAGE' && tier.rate == null) fail('tiers[' + i + '] needs rate for TIERS_PERCENTAGE');
            if (tier.toAmount != null && tier.toAmount <= tier.fromAmount) fail('tiers[' + i + '] toAmount ' + tier.toAmount + ' must be greater than fromAmount ' + tier.fromAmount + ' (leave toAmount blank for an open-ended last tier)');
            if (tier.tenorFrom != null && tier.tenorTo != null && tier.tenorTo < tier.tenorFrom) fail('tiers[' + i + '] tenorTo ' + tier.tenorTo + ' must not be less than tenorFrom ' + tier.tenorFrom);
            if ((tier.tenorFrom != null || tier.tenorTo != null) && loanTenor == null) fail('tiers[' + i + '] has a tenor band but loanTenor (Tenor In: MONTHS | YEARS) is blank');
            tiers.push(tier);
          }
          // Server rule: two tiers must not cover the same amount AND tenor range (half-open [from, to), blank = unbounded).
          var inf = 1e300;
          var amtOv = function(a, b) { var aTo = a.toAmount == null ? inf : a.toAmount; var bTo = b.toAmount == null ? inf : b.toAmount; return a.fromAmount < bTo && b.fromAmount < aTo; };
          var tenOv = function(a, b) { if ((a.tenorFrom == null && a.tenorTo == null) || (b.tenorFrom == null && b.tenorTo == null)) return true; var aF = a.tenorFrom == null ? -inf : a.tenorFrom, aT = a.tenorTo == null ? inf : a.tenorTo, bF = b.tenorFrom == null ? -inf : b.tenorFrom, bT = b.tenorTo == null ? inf : b.tenorTo; return aF < bT && bF < aT; };
          for (var x = 0; x < tiers.length; x++) {
            for (var y = x + 1; y < tiers.length; y++) {
              var a = tiers[x], b = tiers[y];
              if (('' + a.fromAmount) == ('' + b.fromAmount) && ('' + a.toAmount) == ('' + b.toAmount) && ('' + a.tenorFrom) == ('' + b.tenorFrom) && ('' + a.tenorTo) == ('' + b.tenorTo)) fail('tiers[' + x + '] and tiers[' + y + '] are duplicates (same amount and tenor range)');
              if (amtOv(a, b) && tenOv(a, b)) fail('tiers[' + x + '] and tiers[' + y + '] overlap: amount ' + a.fromAmount + '-' + (a.toAmount == null ? 'open' : a.toAmount) + ' vs ' + b.fromAmount + '-' + (b.toAmount == null ? 'open' : b.toAmount) + (loanTenor != null ? ' and tenor ' + a.tenorFrom + '-' + a.tenorTo + ' vs ' + b.tenorFrom + '-' + b.tenorTo : '') + ' (ranges are [from, to): the next tier may start exactly at the previous "to")');
            }
          }
        } else if (strVal(td.tiers, null) != null) note('tiers are ignored for calculationMethod ' + method);
        var channelsWanted = splitList(strVal(td.channels, 'BEYONDLO'));
        var chOpts = genericOptions('CHANNEL');
        var channels = [];
        for (var c = 0; c < channelsWanted.length; c++) { var cc = pickOption(chOpts, channelsWanted[c], 'channel'); if (channels.indexOf(cc) < 0) channels.push(cc); }
        var deferred = boolVal(td.deferredCharge, false);
        var stage = strVal(td.deferredCollectionStage, null) == null ? null : toStage(strVal(td.deferredCollectionStage, null), 'deferredCollectionStage');
        if (deferred && stage == null) fail('deferredCollectionStage is required when deferredCharge=true (a stage AFTER the incident: ASSESSMENT | OFFER | OFFER_ACCEPTANCE | SETUP)');
        if (deferred && STAGE_ORDER.indexOf(stage) <= STAGE_ORDER.indexOf(incident)) fail('deferredCollectionStage ' + stage + ' must come AFTER the incident ' + incident + ' (order: ' + STAGE_ORDER.join(' -> ') + ')' + (incident == 'SETUP' ? ' - a SETUP charge cannot be deferred' : ''));
        if (!deferred && stage != null) note('deferredCollectionStage is ignored because deferredCharge is not true');
        var effFrom = isoDate(strVal(td.effectiveFrom, today), 'effectiveFrom');
        var effTo = isoDate(td.effectiveTo, 'effectiveTo');
        if (effTo != null && effTo < today) fail('effectiveTo ' + effTo + ' is in the past - the server refuses it (also on amend)');
        if (effTo != null && effTo < effFrom) fail('effectiveTo ' + effTo + ' is before effectiveFrom ' + effFrom);
        var taxRate = numVal(td.taxRate, null);
        if (taxRate != null && taxRate < 0) fail('taxRate must not be negative');
        var taxCurrency = strVal(td.taxCurrency, null) == null ? null : strVal(td.taxCurrency, null).toUpperCase();
        var taxAccount = strVal(td.taxReceivingAccount, null);
        if (taxRate != null && taxCurrency == null) taxCurrency = currency;
        if (taxRate != null && taxAccount == null) fail('taxReceivingAccount is required when taxRate is set');
        var chargeAccount = req('chargeReceivingAccount', 'on every incident charge row (Charge Receiving Account, e.g. BCASH)');
        return {
          chargeName: chargeName, chargeNarration: strVal(td.narration, null), currency: currency, calculationMethod: method,
          loanTenor: loanTenor,
          flatAmount: method == 'FLAT' ? flatAmount : null,
          rate: method == 'PERCENTAGE' ? rate : null,
          minCharge: method == 'PERCENTAGE' ? minCharge : null, maxCharge: method == 'PERCENTAGE' ? maxCharge : null,
          calcBase: (method == 'PERCENTAGE' || method == 'TIERS_PERCENTAGE') ? calcBase : null,
          tiers: tiers,
          taxRate: taxRate, taxCurrency: taxRate != null ? taxCurrency : null, taxPseudonym: taxRate != null ? taxAccount : null,
          chargeStatus: strVal(td.status, 'ACTIVE').toUpperCase(),
          event: incident, refundable: boolVal(td.refundable, false), amendable: boolVal(td.amendable, false),
          effectiveFromDate: effFrom, effectiveToDate: effTo,
          applicableChannels: channels.join(','), allowDeferred: deferred, deferredCollectionStage: deferred ? stage : null,
          chargePseudonym: chargeAccount
        };
      }
      """
    * def num = function(v) { return v == null ? null : Number(v); }
    * def setOf = function(csv) { var s = ('' + (csv == null ? '' : csv)).split(','); var o = []; for (var i = 0; i < s.length; i++) { if (s[i].trim() != '') o.push(s[i].trim().toUpperCase()); } o.sort(); return o.join(','); }
    * def tierKey = function(list) { if (list == null || list.length == 0) return ''; var o = []; for (var i = 0; i < list.length; i++) { var t = list[i]; o.push([num(t.fromAmount), num(t.toAmount), num(t.tenorFrom), num(t.tenorTo), num(t.fixedAmount), num(t.rate)].join('/')); } return o.join('|'); }
    * def differences =
      """
      function(c, desired) {
        var d = [];
        var cmp = function(label, a, b) { var x = (a == null || a === '') ? null : a; var y = (b == null || b === '') ? null : b; if (('' + x) != ('' + y)) d.push(label + ' ' + x + ' -> ' + y); };
        cmp('chargeName', c.chargeName, desired.chargeName);
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

    # ── Attach / detach on product types and sub-product rows ────────────────
    * def hasCharge = function(list, id) { for (var i = 0; list != null && i < list.length; i++) { if (('' + list[i].chargeDefId) == ('' + id) && list[i].active != false) return true; } return false; }
    * def withCharge = function(list, id) { var out = stripCharges(list); var hit = false; for (var i = 0; i < out.length; i++) { if (('' + out[i].chargeDefId) == ('' + id)) { out[i].active = true; hit = true; } } if (!hit) out.push({ chargeDefId: id, active: true }); return out; }
    * def withoutCharge = function(list, id) { var out = []; var s = stripCharges(list); for (var i = 0; i < s.length; i++) { if (('' + s[i].chargeDefId) != ('' + id)) out.push(s[i]); } return out; }
    * def attachCharge =
      """
      function(id, code) {
        var done = [];
        for (var i = 0; i < attachTypes.length; i++) {
          var pt = resolveProductType(attachTypes[i], 'attachToProductTypes names it');
          var changed = amendTypeConfig(pt.code, 'attach charge ' + code + ' to product type ' + pt.code, [pt.code, pt.id], function(cfg, cur) {
            if (hasCharge(cur.charges, id)) return false;
            cfg.charges = withCharge(cur.charges, id);
            return true;
          });
          var chk = typeConfigOf(pt.code);
          if (!hasCharge(chk.charges, id)) fail('product type ' + pt.code + ' amendment was committed but its configuration does not list charge ' + code);
          done.push(pt.code + (changed ? ' (attached)' : ' (already attached)'));
        }
        for (var s = 0; s < attachSubs.length; s++) {
          var kv = attachSubs[s].split(':');
          if (kv.length != 2 || kv[0].trim() == '' || kv[1].trim() == '') fail('attachToSubProducts entry "' + attachSubs[s] + '" must look like PRODUCT_TYPE:SUB_PRODUCT_CODE');
          var pt2 = resolveProductType(kv[0].trim(), 'attachToSubProducts names it');
          var sub = resolveSubProduct(pt2.code, kv[1].trim());
          var changed2 = amendSubConfig(pt2.code, sub, 'attach charge ' + code + ' to sub-product ' + pt2.code + '/' + sub, [pt2.code, sub], function(cfg, cur) {
            if (hasCharge(cur.charges, id)) return false;
            cfg.charges = withCharge(cur.charges, id);
            return true;
          });
          var chk2 = subConfigOf(pt2.code, sub);
          if (chk2 == null || !hasCharge(chk2.charges, id)) fail('sub-product ' + pt2.code + '/' + sub + ' config was committed but does not list charge ' + code);
          done.push(pt2.code + '/' + sub + (changed2 ? ' (attached)' : ' (already attached)'));
        }
        return done;
      }
      """
    * def detachChargeEverywhere =
      """
      function(id, code) {
        var types = listProductTypes();
        var touched = [];
        for (var i = 0; i < types.length; i++) {
          var tc = '' + types[i].code;
          var cfgRes = api('GET', '/v1/product-types/' + encodeURIComponent(tc) + '/config', adminHeader, null);
          if (cfgRes.status != 200 || cfgRes.body == null) continue;
          var listed = false;
          for (var c = 0; cfgRes.body.charges != null && c < cfgRes.body.charges.length; c++) { if (('' + cfgRes.body.charges[c].chargeDefId) == ('' + id)) listed = true; }
          if (listed) {
            amendTypeConfig(tc, 'detach charge ' + code + ' from product type ' + tc, [tc, types[i].id], function(cfg, cur) { cfg.charges = withoutCharge(cur.charges, id); return true; });
            touched.push(tc);
          }
          var owned = configuredSubs(tc);
          for (var s = 0; s < owned.length; s++) {
            var cur = subConfigOf(tc, owned[s]);
            var sl = false;
            for (var k = 0; cur != null && cur.charges != null && k < cur.charges.length; k++) { if (('' + cur.charges[k].chargeDefId) == ('' + id)) sl = true; }
            if (!sl) continue;
            amendSubConfig(tc, owned[s], 'detach charge ' + code + ' from sub-product ' + tc + '/' + owned[s], [tc, owned[s]], function(cfg, cur2) { cfg.charges = withoutCharge(cur2.charges, id); return true; });
            touched.push(tc + '/' + owned[s]);
          }
        }
        return touched;
      }
      """

    # ── Execute ───────────────────────────────────────────────────────────────
    * def executeCharge =
      """
      function() {
        var existing = findExisting();
        if (action == 'DELETE') {
          if (existing == null) { note('charge ' + what + ' does not exist - nothing to delete'); return 'charge ' + what + ' not found (nothing to delete)'; }
          var touched = detachChargeEverywhere(existing.id, existing.chargeCode);
          if (existing.chargeStatus != 'ACTIVE') return 'charge ' + existing.chargeCode + ' (' + what + ') is already ' + existing.chargeStatus + (touched.length > 0 ? ' | detached from ' + touched.join(', ') : '');
          var sendDel = function() { return api('DELETE', '/v1/config/incident-charge-definitions/' + existing.id, adminHeader, null); };
          governed('deactivate charge ' + existing.chargeCode + ' (' + what + ')', sendDel(), sendDel, CH_HINTS, [chargeName, existing.chargeCode, existing.id]);
          var after = readCharge(existing.id);
          if (after.chargeStatus == 'ACTIVE') fail('charge ' + existing.chargeCode + ' is still ACTIVE after its deactivation was committed');
          return 'charge ' + existing.chargeCode + ' (' + what + ') -> ' + after.chargeStatus + (touched.length > 0 ? ' | detached from ' + touched.join(', ') : '');
        }
        if (action == 'AMEND' && existing == null) fail('charge ' + what + ' does not exist on ' + baseUrl + ' - nothing to amend (use create=true, or fix chargeName / incident / currency)');
        var desired = buildDesired();
        var outcome = null;
        var id = null;
        if (existing != null) {
          id = existing.id;
          if (chNewName != null && chNewName != ('' + existing.chargeName)) { note('charge ' + existing.chargeCode + ' will be renamed "' + existing.chargeName + '" -> "' + chNewName + '" (WARNING: the Incident Charges screen locks the name on edit; the API accepts it)'); desired.chargeName = chNewName; }
          var diff = differences(existing, desired);
          if (diff.length == 0) {
            note('charge ' + existing.chargeCode + ' already matches the sheet (' + what + ') - nothing to change');
            outcome = 'unchanged';
          } else {
            note('charge ' + existing.chargeCode + ' differs from the sheet: ' + diff.join(', ') + ' - requesting an amendment');
            var body = karate.merge(desired, { effectiveFromDate: existing.effectiveFromDate });
            var send = function() { return api('PUT', '/v1/config/incident-charge-definitions/' + id, adminHeader, body); };
            governed('amend charge ' + existing.chargeCode + ' (' + what + ')', send(), send, CH_HINTS, [chargeName, existing.chargeCode, id]);
            outcome = 'amended';
          }
        } else {
          if (desired.effectiveFromDate < today) fail('effectiveFrom ' + desired.effectiveFromDate + ' is in the past; the server only accepts today or a future date when creating a charge (leave it blank for today)');
          var create = function() { return api('POST', '/v1/config/incident-charge-definitions', adminHeader, desired); };
          governed('create charge (' + what + ')', create(), create, CH_HINTS, [chargeName]);
          var made = null;
          for (var i = 0; i < 30 && made == null; i++) { made = findExisting(); if (made == null) java.lang.Thread.sleep(1000); }
          if (made == null) fail('the change request for ' + what + ' was committed but no charge with that name / incident / currency is listed afterwards');
          id = made.id;
          outcome = 'created';
        }
        var c = readCharge(id);
        var diff2 = differences(c, desired);
        if (diff2.length > 0) fail('VERIFY: charge ' + c.chargeCode + ' does not match the sheet after ' + outcome + ': ' + diff2.join(', '));
        var attached = attachCharge(id, c.chargeCode);
        var amt = c.calculationMethod == 'FLAT' ? (c.flatAmount + ' ' + c.currency) : (c.calculationMethod == 'PERCENTAGE' ? (c.rate + '% of ' + c.calcBase) : ((c.tiers != null ? c.tiers.length : 0) + ' tiers'));
        return 'charge ' + c.chargeCode + ' (id ' + c.id + ') ' + outcome + ': ' + c.chargeName + ' | ' + c.event + ' | ' + c.calculationMethod + ' ' + amt + (c.taxRate != null ? ' | tax ' + c.taxRate + '% ' + c.taxCurrency : '') + ' | ' + c.effectiveFromDate + ' to ' + (c.effectiveToDate != null ? c.effectiveToDate : 'open') + ' | ' + c.chargeStatus + (attached.length > 0 ? ' | attached to: ' + attached.join(', ') : '');
      }
      """
    * def summary = executeCharge()
    * note('INCIDENT CHARGE ' + action + ' COMPLETE')
    * print rowTag, summary
    * if (ckHeader() != null) logout(ckHeader())
    * logout(karate.get('adminHeaderVal'))
