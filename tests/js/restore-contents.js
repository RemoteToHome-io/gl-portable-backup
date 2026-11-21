#!/usr/bin/env node
'use strict';
/* Loads backup.js with stubbed LuCI globals and checks renderContents(manifest). The E() stub
 * refuses a bare string child: LuCI's dom.append assigns such a child to innerHTML, and every
 * entry rendered here comes from an archive. */
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
	dom: {}, fs: {}, ui: {}, rpc: {}
};
var view = new Function('view', 'dom', 'fs', 'ui', 'rpc', 'L', 'E', '_', src)(
	stubs.view, stubs.dom, stubs.fs, stubs.ui, stubs.rpc, stubs.L, E, stubs._);

var failed = 0;
function check(cond, what) { if (cond) { console.log('ok ' + what); } else { console.log('FAIL ' + what); failed++; } }
function text(node) {
	return node.children.map(function(c) { return typeof c === 'string' ? c : text(c); }).join('');
}
function find(node, tag) {
	var out = [];
	(node.children || []).forEach(function(c) {
		if (typeof c === 'string') return;
		if (c.tag === tag) out.push(c);
		out = out.concat(find(c, tag));
	});
	return out;
}

/* 1. Full archive: both lists, counts in the summary */
var full = view.renderContents({ mode: 'full', sections: ['network', 'wireless'],
	extra_files: ['/etc/crontabs/root', '/etc/dropbear/authorized_keys', '/etc/hosts'] });
check(full && full.tag === 'details', 'full: renders a details block');
check(text(find(full, 'summary')[0]) === 'Contents (as declared by the archive): 2 config files, 3 extra files', 'full: summary counts');
check(find(full, 'strong').map(text).join('|') === 'Config files|Extra files', 'full: two list headings');
check(find(full, 'li').length === 5, 'full: five entries');

/* 2. Profile archive: API captures; no extra-files count or list even though the array is present */
var profile = view.renderContents({ mode: 'profile',
	sections: ['wifi.get_config', 'dns.get_config', 'vlan_subnet.get_subnets'], extra_files: [] });
check(text(find(profile, 'summary')[0]) === 'Contents (as declared by the archive): 3 API captures', 'profile: summary counts');
check(find(profile, 'strong').map(text).join('|') === 'API captures', 'profile: single heading');

/* 3. Remote-Safe archive: rendered like Full; excluded_sections is not this block's business */
var rs = view.renderContents({ mode: 'remote-safe', sections: ['network'], excluded_sections: ['zerotier'], extra_files: [] });
check(text(find(rs, 'summary')[0]) === 'Contents (as declared by the archive): 1 config files, 0 extra files', 'remote-safe: summary counts');
check(find(rs, 'strong').map(text).join('|') === 'Config files', 'remote-safe: no empty extra-files list');

/* 4. A manifest without either list (older tool) renders nothing */
check(view.renderContents({ mode: 'clone' }) === null, 'legacy manifest: null');

/* 5. An entry that looks like markup stays a text child — the E() stub throws on a bare string */
var hostile = view.renderContents({ mode: 'full', sections: ['<img src=x onerror=alert(1)>'], extra_files: [] });
var li = find(hostile, 'li')[0];
check(li.children.length === 1 && li.children[0] === '<img src=x onerror=alert(1)>', 'markup-looking entry is a text child');

/* 6. renderCompromiseWarnings: nothing for empty or absent arrays */
check(Array.isArray(view.renderCompromiseWarnings({})) && view.renderCompromiseWarnings({}).length === 0,
	'compromise warnings: none for a manifest without the keys');
check(view.renderCompromiseWarnings({ startup_and_login_files: [], suspect_markers: [] }).length === 0,
	'compromise warnings: none for empty arrays');
check(view.renderCompromiseWarnings({ startup_and_login_files: '/etc/rc.local', suspect_markers: 'x' }).length === 0,
	'compromise warnings: none for non-array values');

/* 7. Startup/login files: one warning paragraph whose paths are text children */
var sw = view.renderCompromiseWarnings({ startup_and_login_files: ['/etc/rc.local', '/etc/crontabs/root'] });
check(sw.length === 1 && sw[0].tag === 'div' && sw[0].attrs['class'] === 'alert-message warning',
	'startup files: one warning block (a div: a list may not sit inside a <p>)');
var swLi = find(sw[0], 'li');
check(swLi.length === 2 && swLi[0].children[0] === '/etc/rc.local' && swLi[1].children[0] === '/etc/crontabs/root',
	'startup files: each path is an array text child');
check(/run at startup or control logins/.test(text(sw[0])), 'startup files: fixed sentence present');
check(/outside \/etc/.test(text(sw[0])), 'startup files: files outside /etc are named in the sentence');

/* 8. Suspect markers: one danger paragraph naming them */
var mw = view.renderCompromiseWarnings({ suspect_markers: ['/etc/config/.gl'] });
check(mw.length === 1 && mw[0].tag === 'div' && mw[0].attrs['class'] === 'alert-message danger', 'markers: one danger block');
check(/cleanup script in GL\.iNet's KVM firmware removes after the 2026-11-20 incident/.test(text(mw[0])), 'markers: KVM-derived wording');
check(!/signs of/.test(text(mw[0])), 'markers: never called signs of compromise');
var mwLi = find(mw[0], 'li');
check(mwLi.length === 1 && mwLi[0].children.length === 1 && mwLi[0].children[0] === '/etc/config/.gl',
	'markers: path is an array text child');

/* 9. Both present: startup warning first, then markers; markup-looking paths stay text */
var both = view.renderCompromiseWarnings({ startup_and_login_files: ['<img src=x onerror=alert(1)>'],
	suspect_markers: ['<script>alert(1)</script>'] });
check(both.length === 2 && both[0].attrs['class'] === 'alert-message warning' && both[1].attrs['class'] === 'alert-message danger',
	'both: two paragraphs in order');
check(find(both[0], 'li')[0].children[0] === '<img src=x onerror=alert(1)>', 'both: markup-looking startup path is a text child');
check(find(both[1], 'li')[0].children[0] === '<script>alert(1)</script>', 'both: markup-looking marker path is a text child');

/* 10. The restore-complete modal repeats every WARNING line the backend printed, as text */
var rw = view.renderRestoreWarnings('Extracting backup...\n  WARNING: 2 hidden entries under extra/ in this archive were NOT restored\nRestore complete.\nWARNING: <img src=x onerror=alert(1)>\n');
check(rw && rw.tag === 'div' && rw.attrs['class'] === 'alert-message warning', 'restore warnings: one warning block');
var rwPre = find(rw, 'pre');
check(rwPre.length === 1 && rwPre[0].children.length === 1 &&
	rwPre[0].children[0] === 'WARNING: 2 hidden entries under extra/ in this archive were NOT restored\nWARNING: <img src=x onerror=alert(1)>',
	'restore warnings: only the WARNING lines, as one text child');
check(view.renderRestoreWarnings('Restore complete.\n') === null, 'restore warnings: none without WARNING lines');
check(view.renderRestoreWarnings(undefined) === null, 'restore warnings: none without stderr');

/* 11. handleRestoreConfirm wires them into the "Restore complete" modal, above the buttons */
var shown = [];
stubs.ui.showModal = function(title, body) { shown.push({ title: title, body: body }); };
stubs.ui.hideModal = function() {};
stubs.ui.addNotification = function() { shown.push({ title: 'notification' }); };
stubs.ui.createHandlerFn = function() { return function() {}; };
stubs.fs.exec = function() { return Promise.resolve({ code: 0, stdout: 'RESTORE_OK\n',
	stderr: 'Applying\n  WARNING: 1 symbolic links or other non-regular entries under extra/ in this archive were NOT restored\n' }); };
global.document = { getElementById: function() { return null; } };
var pending = view.handleRestoreConfirm(null, {}).then(function() {
	var done = shown.filter(function(m) { return m.title === 'Restore complete'; })[0];
	check(!!done, 'confirm: the Restore complete modal is shown');
	var idxWarn = -1, idxButtons = -1;
	(done ? done.body : []).forEach(function(n, i) {
		if (n && n.attrs && n.attrs['class'] === 'alert-message warning') idxWarn = i;
		if (n && n.attrs && n.attrs['class'] === 'right') idxButtons = i;
	});
	check(idxWarn >= 0 && idxButtons > idxWarn, 'confirm: the warnings sit above the buttons');
	check(idxWarn >= 0 && /symbolic links or other non-regular entries/.test(text(done.body[idxWarn])), 'confirm: the backend warning is shown');
});

pending.then(function() {
console.log(failed === 0 ? 'restore-contents: all checks passed' : ('restore-contents: ' + failed + ' check(s) failed'));
process.exit(failed === 0 ? 0 : 1);
}).catch(function(e) { console.log('FAIL harness: ' + e); process.exit(1); });
