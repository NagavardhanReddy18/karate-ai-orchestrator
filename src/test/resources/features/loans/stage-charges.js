// Stage charges for a row - the same rules 04-07 apply inline, shared here because 08 collects in several
// @ignore scenarios. The product configuration levies each charge at a collection stage; each stage has a sheet
// column naming the charges that stage's user collects (charge name or code, any case, ';' between several):
//   APPLICATION applicationCharges | ASSESSMENT assessmentCharges | OFFER offerCharges
//   OFFER_ACCEPTANCE offerAcceptanceCharges | SETUP setupCharges
// The result has an error when a charge due at the stage is not named in its column, a named charge is not
// configured at that stage, or a named charge could not be collected (POST .../collect answers HTTP 200 even
// when the host posting failed, so the body decides). A charge that will not settle is waived when the row's
// chargeFallbackAction is WAIVE, with chargeWaiveReason as the reason.
//
// Usage:  * def stageCharges = read('classpath:features/loans/stage-charges.js')
//         * def res = stageCharges(hdr, 'SETUP', 'setupCharges', appId, td, feeAcct)
function(hdr, stage, column, chargeAppId, td, feeAcct) {
  var baseUrl = karate.get('baseUrl');
  var note = function(m) { karate.log('[charges ' + stage + ']', m); };
  var key = function(v) { return v == null ? '' : ('' + v).trim().toLowerCase(); };
  var cell = function(name) { var v = td[name]; return (v == null || ('' + v).trim() == '') ? null : ('' + v).trim(); };
  var label = function(c) { return c.chargeName + ' (' + c.chargeCode + ')'; };
  var isOpen = function(c) { return c.status != 'COLLECTED' && c.status != 'WAIVED'; };
  var isNamed = function(c, n) { return key(c.chargeCode) == key(n) || key(c.chargeName) == key(n); };
  var names = [];
  var parts = (cell(column) == null ? '' : cell(column)).split(';');
  for (var i = 0; i < parts.length; i++) if (key(parts[i]) != '') names.push(parts[i].trim());
  var namedAny = function(c) { for (var i = 0; i < names.length; i++) if (isNamed(c, names[i])) return true; return false; };

  // includeSettled: a charge already collected (e.g. before a send-back) still counts as configured here
  var list = function() {
    var r = karate.http(baseUrl + '/v1/charge-collection/' + chargeAppId + '/collectable?includeSettled=true&phase=' + stage).header('Authorization', hdr).get();
    if (r.status != 200 || r.body == null) return null;
    var out = [];
    var n = karate.sizeOf(r.body);
    for (var i = 0; i < n; i++) if (r.body[i] != null && r.body[i].id != null) out.push(r.body[i]);
    return out;
  };
  var all = list();
  if (all == null) return { error: 'the charges of application ' + chargeAppId + ' could not be read at ' + stage, collected: [], waived: [] };

  var configured = [], unknown = [], missing = [];
  for (var j = 0; j < all.length; j++) configured.push(label(all[j]));
  for (var i = 0; i < names.length; i++) {
    var hit = false;
    for (var j = 0; j < all.length; j++) if (isNamed(all[j], names[i])) hit = true;
    if (!hit) unknown.push(names[i]);
  }
  for (var j = 0; j < all.length; j++) if (isOpen(all[j]) && all[j].dueHere && !namedAny(all[j])) missing.push(label(all[j]));
  var errs = [];
  if (unknown.length) errs.push('not configured at ' + stage + ' but named in ' + column + ': ' + unknown.join('; '));
  if (missing.length) errs.push('due at ' + stage + ' but not named in ' + column + ': ' + missing.join('; '));
  if (errs.length) return { error: errs.join(' | ') + ' (configured at ' + stage + ': ' + (configured.length ? configured.join('; ') : 'none') + ')', collected: [], waived: [] };
  if (names.length == 0) { note('none configured, none named'); return { error: null, collected: [], waived: [] }; }

  var fallback = cell('chargeFallbackAction') == null ? 'COLLECT' : cell('chargeFallbackAction').toUpperCase();
  var mode = cell('chargeCollectionMode') != null ? cell('chargeCollectionMode') : 'FEES_FUNDING_ACCOUNT';
  var collected = [], waived = [], reasons = [];
  // A waive is a maker-checker change request raised by the stage user. Only an amendable charge can be waived
  // (the server answers 409 "cannot be waived" otherwise). A request the governance rules do not auto-approve
  // is approved - by the user itself when it is WARNING severity (/proceed), otherwise by the admin as checker -
  // and then committed, which writes the charge off.
  var post = function(path, h, body) { return karate.http(baseUrl + path).header('Authorization', h).header('Content-Type', 'application/json').post(body); };
  var waive = function(c) {
    if (cell('chargeWaiveReason') == null) { reasons.push(label(c) + ': not waived - chargeWaiveReason is blank'); return; }
    var w = post('/v1/charge-collection/' + c.id + '/waive', hdr, { reason: cell('chargeWaiveReason') });
    var cr = (w.body != null && w.body.data != null) ? w.body.data : w.body;
    if (w.status != 200 || cr == null || cr.id == null) {
      var refused = (w.body != null && w.body.detail) ? w.body.detail : ('HTTP ' + w.status + ' ' + karate.toString(w.body));
      reasons.push(label(c) + ': waive refused - ' + refused);
      note(label(c) + ' waive refused -> ' + refused);
      return;
    }
    note(label(c) + ' waive requested -> change request ' + cr.id + ' (' + cr.status + ')');
    if (cr.status == 'PENDING' || cr.status == 'PENDING_APPROVAL' || cr.status == 'SUBMITTED') {
      var ap = post('/v1/change-requests/' + cr.id + '/proceed', hdr, {});
      var approvedBy = ap.status == 200 ? 'the maker (WARNING severity)' : null;
      // Four-eyes: core-iam resolves who may approve from /v1/supervisor-links. As approval-limit-helper does,
      // each candidate from karate-config's governanceCheckers is linked (by the admin) as a supervisor of the
      // maker, then asked to approve; the change is committed only once one of them has. The maker and the
      // stage accounts are never signed in here - a second sign-in revokes the session the row is using.
      var login = function(u, pw) {
        var lr = karate.http(baseUrl + '/auth/login').header('Content-Type', 'application/json').post({ username: u, password: pw });
        var lb = (lr.body != null && lr.body.data) ? lr.body.data : lr.body;
        if (lb != null && lb.confirmToken) { lr = karate.http(baseUrl + '/auth/confirm-session').header('Content-Type', 'application/json').post({ confirmToken: lb.confirmToken }); lb = (lr.body != null && lr.body.data) ? lr.body.data : lr.body; }
        var t = (lr.status != 200 || lb == null) ? null : (lb.accessToken || lb.token);
        return t == null ? null : 'Bearer ' + t;
      };
      var B64 = Java.type('java.util.Base64'), JStr = Java.type('java.lang.String');
      var claims = JSON.parse(new JStr(B64.getUrlDecoder().decode(hdr.replace('Bearer ', '').split('.')[1]), 'UTF-8'));
      var maker = claims.preferred_username || claims.username || claims.sub;
      var busy = [maker];
      ['Officer', 'Underwriter', 'Approver1', 'Approver2', 'Issuer', 'Acceptor', 'Setup'].forEach(function(s) { busy.push(karate.get('default' + s + 'Username')); });
      var adminHdr = null;
      var refusals = [];
      var checkers = karate.get('governanceCheckers') || [];
      for (var k = 0; approvedBy == null && k < checkers.length; k++) {
        var cu = checkers[k].username;
        if (busy.indexOf(cu) >= 0) continue;
        var chk = login(cu, checkers[k].password);
        if (chk == null) { refusals.push(cu + ': cannot sign in'); continue; }
        if (adminHdr == null) adminHdr = login(karate.get('defaultAdminUsername'), karate.get('defaultAdminPassword'));
        var links = karate.http(baseUrl + '/v1/supervisor-links/by-user/' + maker).header('Authorization', adminHdr).get();
        var linked = false;
        if (links.status == 200 && links.body != null) for (var li = 0; li < links.body.length; li++) if (links.body[li].supervisorUsername == cu && links.body[li].active) linked = true;
        if (!linked) note('supervisor link ' + maker + ' -> ' + cu + ': HTTP ' + post('/v1/supervisor-links', adminHdr, { userUsername: maker, supervisorUsername: cu, active: true }).status);
        ap = post('/v1/change-requests/' + cr.id + '/approve', chk, { comment: cell('chargeWaiveReason') });
        if (ap.status == 200) approvedBy = cu;
        else refusals.push(cu + ': HTTP ' + ap.status + ' ' + karate.toString(ap.body));
      }
      if (approvedBy == null) {
        reasons.push(label(c) + ': waive change request ' + cr.id + ' could not be approved by any configured checker (' + refusals.join('; ') + ')');
        note('waive change request ' + cr.id + ' NOT approved - ' + refusals.join('; '));
        return;
      }
      note('waive change request ' + cr.id + ' approved by ' + approvedBy);
    }
    var cm = post('/v1/charge-collection/commit/' + cr.id, hdr, {});
    note('waive change request ' + cr.id + ' committed -> HTTP ' + cm.status + (cm.status != 200 ? ' ' + karate.toString(cm.body) : ''));
    if (cm.status != 200) reasons.push(label(c) + ': waive change request ' + cr.id + ' not committed - HTTP ' + cm.status);
  };
  for (var j = 0; j < all.length; j++) {
    var c = all[j];
    if (!namedAny(c)) continue;
    if (!isOpen(c)) { note(label(c) + ' already ' + c.status); continue; }
    var res = karate.http(baseUrl + '/v1/charge-collection/' + c.id + '/collect')
                    .header('Authorization', hdr).header('Content-Type', 'application/json')
                    .post({ collectionMode: mode, fundingAccount: feeAcct });
    if (res.status == 200 && res.body != null && res.body.status != 'FAILED') { collected.push(label(c)); note(label(c) + ' collected from ' + feeAcct); continue; }
    var why = (res.body != null && res.body.errorMessage) ? res.body.errorMessage : ('HTTP ' + res.status + ' ' + karate.toString(res.body));
    reasons.push(label(c) + ': ' + why);
    note(label(c) + ' could NOT be collected: ' + why);
    if (fallback == 'WAIVE') waive(c);
  }
  var left = [];
  var after = list();
  if (after != null) {
    for (var j = 0; j < after.length; j++) {
      if (!namedAny(after[j])) continue;
      if (isOpen(after[j])) left.push(label(after[j]) + ' [' + after[j].status + ']');
      else if (after[j].status == 'WAIVED' && reasons.join(' ').indexOf(after[j].chargeCode) >= 0) waived.push(label(after[j]));
    }
  }
  if (left.length) return { error: 'could not be ' + (fallback == 'WAIVE' ? 'collected or waived' : 'collected') + ' at ' + stage + ': ' + (reasons.length ? reasons.join('; ') : left.join('; ')) + (left.length ? ' | still open: ' + left.join('; ') : ''), collected: collected, waived: waived };
  return { error: null, collected: collected, waived: waived };
}
