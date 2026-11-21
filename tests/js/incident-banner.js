#!/usr/bin/env node
'use strict';
/* Loads backup.js with stubbed LuCI globals and checks the incident-check parts of the page: the
 * banner for each result, the "Security incident backup" tag in the mode list, and the restore
 * dialog's actions for an archive restore refuses. The E() stub refuses a bare string child (LuCI
 * renders it as HTML); every detail string comes from the backend. */
var fs = require('fs');
var path = require('path');
var src = fs.readFileSync(path.join(__dirname, '..', '..', 'luci-app-gl-portable-backup', 'htdocs',
	'luci-static', 'resources', 'view', 'gl-portable-backup', 'backup.js'), 'utf8');

function E(tag, attrs, children) {
	if (typeof children === 'string')
		throw new Error('bare string child on <' + tag + '> would be rendered as HTML');
	return { tag: tag, attrs: attrs || {}, children: children == null ? [] : children };
}
String.prototype.format = function() {
	var args = arguments, i = 0;
	return this.replace(/%[sd]/g, function() { return String(args[i++]); });
};
var stubs = {
	view: { extend: function(o) { return o; } },
	L: { bind: function(f, self) {
		var a = Array.prototype.slice.call(arguments, 2);
		return function() { return f.apply(self, a.concat(Array.prototype.slice.call(arguments))); };
	} },
	_: function(s) { return s; },
	dom: { content: function() {} }, fs: {}, rpc: {},
	ui: { createHandlerFn: function(self, fn, arg) { return { handler: fn, arg: arg }; }, hideModal: function() {}, showModal: function() {} }
};
var view = new Function('view', 'dom', 'fs', 'ui', 'rpc', 'L', 'E', '_', src)(
	stubs.view, stubs.dom, stubs.fs, stubs.ui, stubs.rpc, stubs.L, E, stubs._);

var failed = 0;
function check(cond, what) { if (cond) { console.log('ok ' + what); } else { console.log('FAIL ' + what); failed++; } }
function text(node) {
	if (node == null || node === '') return '';
	if (typeof node === 'string') return node;
	return (node.children || []).map(text).join('');
}
function find(nodes, pred) {
	var out = [];
	(Array.isArray(nodes) ? nodes : [nodes]).forEach(function(n) {
		if (!n || typeof n === 'string') return;
		if (pred(n)) out.push(n);
		out = out.concat(find(n.children || [], pred));
	});
	return out;
}
function byTag(tag) { return function(n) { return n.tag === tag; }; }
var LINK = 'https://github.com/RemoteToHome-io/gl-security-incident-2026';
function linkOk(node) {
	var a = find(node, byTag('a'));
	return a.length === 1 && a[0].attrs.href === LINK && a[0].attrs.target === '_blank'
		&& a[0].attrs.rel === 'noopener noreferrer' && text(a[0]) === 'What is known and how to recover';
}

/* 1. indicators: danger, heading, the details as text children, what to replace, the link */
var hostile = '<img src=x onerror=alert(1)>';
var ind = view.renderIncidentBanner({ result: 'indicators', indicators: [
	{ id: 'tmp-fifo', detail: '/tmp/f is a named pipe: the remote shell has run since the last boot' },
	{ id: 'x', detail: hostile } ] });
check(ind.attrs['class'] === 'alert-message danger', 'indicators: danger alert');
check(/^Indicators of the November 2026 GL\.iNet cloud incident were found on this router/.test(text(ind)), 'indicators: heading');
var li = find(ind, byTag('li'));
check(li.length === 2 && li[0].children.length === 1 && li[0].children[0] === '/tmp/f is a named pipe: the remote shell has run since the last boot'
	&& li[1].children[0] === hostile, 'indicators: each detail is an array text child');
check(/Treat every key and password on this router as exposed and replace them: VPN keys and profiles \(client and server\), Wi-Fi passwords, the admin password, DDNS and cloud credentials, SSH keys\./.test(text(ind)),
	'indicators: what to replace');
check(/VPN client profiles and SSH client keys that this router held must also be revoked on the server they connect to\./.test(text(ind)),
	'indicators: revoke at the server');
check(/A backup made now is a record only; this plugin will refuse to restore it\./.test(text(ind)), 'indicators: record only');
check(linkOk(ind), 'indicators: the incident page link, constant, new tab, noopener');

/* 2. none: neutral, never "clean"; the GoodCloud line only when it is on */
var none = view.renderIncidentBanner({ result: 'none', indicators: [], goodcloud_enabled: false });
check(none.attrs['class'] === 'alert-message', 'none: neutral alert');
check(text(none).indexOf('Incident check: no known indicator found on this router. This does not show it was never compromised: the known remote shell leaves no file and is gone after a reboot.') === 0,
	'none: text');
check(!/clean|safe|guarantee/i.test(text(none)), 'none: no clean/safe/guarantee wording');
check(text(none).indexOf('GoodCloud') === -1, 'none: no GoodCloud line when it is off');
check(linkOk(none), 'none: the link');
var noneGc = view.renderIncidentBanner({ result: 'none', indicators: [], goodcloud_enabled: true });
check(/GoodCloud is switched on on this router\./.test(text(noneGc)), 'none: GoodCloud line when it is on');

/* 3. inconclusive: a warning listing why the router cannot be cleared, each reason a text child */
var MAP = '/etc/mp_ip_mapping_info was written on or after 2026-11-20 although multi-path tunnelling is off: the cloud client\'s handler that the attack used has run on this router. This is also the only trace of it that survives a restart.';
var inc = view.renderIncidentBanner({ result: 'inconclusive', indicators: [], cannot_clear: [
	{ id: 'mp-ip-mapping-file', detail: MAP },
	{ id: 'restarted-since-incident', detail: 'the router has restarted since the attack window' },
	{ id: 'x', detail: hostile } ] });
check(inc.attrs['class'] === 'alert-message warning', 'inconclusive: warning alert');
check(/^No strong indicator was found, but this router cannot be cleared:/.test(text(inc)), 'inconclusive: heading');
var incLi = find(inc, byTag('li'));
check(incLi.length === 3 && incLi[0].children.length === 1 && incLi[0].children[0] === MAP
	&& incLi[2].children[0] === hostile, 'inconclusive: each cannot-clear detail is an array text child');
check(/If you have any other reason to suspect it, treat it as compromised\./.test(text(inc)), 'inconclusive: the closing sentence');
check(linkOk(inc), 'inconclusive: the link');
check(find(view.renderIncidentBanner({ result: 'inconclusive', indicators: [] }), byTag('li')).length === 0, 'inconclusive without reasons: an empty list, no crash');

/* 4. unknown */
var unk = view.renderIncidentBanner({ result: 'unknown' });
check(unk.attrs['class'] === 'alert-message warning' && /The incident check could not be run\./.test(text(unk)), 'unknown: warning');

/* 5. parseCheck: exit 0 and 3 are replies, anything else or garbage is unknown */
check(view.parseCheck({ code: 3, stdout: '{"result":"indicators","indicators":[]}\n' }).result === 'indicators', 'parseCheck: exit 3 parsed');
check(view.parseCheck({ code: 0, stdout: '{"result":"none","indicators":[]}' }).result === 'none', 'parseCheck: exit 0 parsed');
check(view.parseCheck({ code: 0, stdout: '{"result":"inconclusive","indicators":[]}' }).result === 'inconclusive', 'parseCheck: inconclusive');
check(view.parseCheck({ code: 0, stdout: 'garbage' }).result === 'unknown', 'parseCheck: garbage is unknown');
check(view.parseCheck({ code: 1, stdout: '{"result":"none"}' }).result === 'unknown', 'parseCheck: other exit is unknown');
check(view.parseCheck({ code: 0, stdout: '{"result":"clean"}' }).result === 'unknown', 'parseCheck: an unknown result is unknown');
check(view.parseCheck(null).result === 'unknown', 'parseCheck: no reply is unknown');

/* 6. the mode list: the tag on Full only for none and inconclusive, Full pre-selected then */
function modes(result) { return view.renderModeList({ result: result, indicators: [] }); }
function tags(nodes) { return find(nodes, function(n) { return n.tag === 'span' && text(n) === 'Security incident backup'; }); }
function radio(nodes, value) { return find(nodes, function(n) { return n.tag === 'input' && n.attrs.value === value; })[0]; }
function labelOf(nodes, value) { return find(nodes, function(n) { return n.tag === 'label' && find(n, function(c) { return c.tag === 'input' && c.attrs.value === value; }).length > 0; })[0]; }
var mn = modes('none');
check(tags(mn).length === 1 && tags(labelOf(mn, 'full')).length === 1, 'none: one tag, on Full');
check(radio(mn, 'full').attrs.checked === 'checked' && !radio(mn, 'clone').attrs.checked, 'none: Full pre-selected');
check(/For the November 2026 incident: take this before you factory reset and install the fixed firmware, then restore it on the same router; read the files the restore dialog flags before rebooting\./.test(text(labelOf(mn, 'full'))),
	'none: Full description gains the incident sentence');
check(!/treat it as compromised/.test(text(mn)), 'none: no inconclusive sentence');
var mi = modes('inconclusive');
check(tags(mi).length === 1 && tags(labelOf(mi, 'full')).length === 1 && radio(mi, 'full').attrs.checked === 'checked', 'inconclusive: tag on Full, pre-selected');
check(/If you have any other reason to suspect this router, treat it as compromised\./.test(text(labelOf(mi, 'full'))), 'inconclusive: the added sentence');
var mx = modes('indicators');
check(tags(mx).length === 0, 'indicators: no tag');
check(/^Backups made now are records only and cannot be restored with this plugin\./.test(text(mx[0])), 'indicators: the records-only line above the modes');
check(radio(mx, 'clone').attrs.checked === 'checked', 'indicators: Clone stays the default');
var mu = modes('unknown');
check(tags(mu).length === 0 && radio(mu, 'clone').attrs.checked === 'checked', 'unknown: no tag, Clone default');
check(text(mu).indexOf('records only') === -1, 'unknown: no records-only line');

/* 7. the restore dialog's actions: no Restore button for a refused archive */
function buttons(nodes) { return find(nodes, byTag('button')).map(text); }
var refused = view.renderRestoreActions({ restore_refused: true }, null);
check(buttons(refused).join('|') === 'Cancel', 'refused: Cancel only');
var dz = find(refused, function(n) { return n.attrs && n.attrs['class'] === 'alert-message danger'; });
check(dz.length === 1 && /This archive was made on a router that showed indicators of compromise\. It is a record only and is not restored/.test(text(dz[0])),
	'refused: the refusal text in a danger alert');
var allowed = view.renderRestoreActions({ restore_refused: false }, null);
check(buttons(allowed).join('|') === 'Cancel|Restore', 'not refused: Cancel and Restore');
check(buttons(view.renderRestoreActions({}, null)).join('|') === 'Cancel|Restore', 'older manifest without the key: Restore offered');
var cc = view.renderRestoreActions({ restore_refused: false, incident_check: { result: 'inconclusive', cannot_clear: ['mp-ip-mapping-file', hostile] } }, null);
check(buttons(cc).join('|') === 'Cancel|Restore', 'inconclusive archive: Restore offered');
var ccw = find(cc, function(n) { return n.attrs && n.attrs['class'] === 'alert-message warning'; });
check(ccw.length === 1 && ccw[0].children.length === 1 && ccw[0].children[0] === 'WARNING: this archive was made on a router that could not be cleared (mp-ip-mapping-file, ' + hostile + '). Restore its keys and passwords only if you accept that.',
	'inconclusive archive: the warning, as one text child');
check(find(view.renderRestoreActions({ restore_refused: false, incident_check: { result: 'none' } }, null), function(n) { return n.attrs && /alert-message/.test(n.attrs['class'] || ''); }).length === 0,
	'none archive: no warning');

console.log(failed === 0 ? 'incident-banner: all checks passed' : ('incident-banner: ' + failed + ' check(s) failed'));
process.exit(failed === 0 ? 0 : 1);
