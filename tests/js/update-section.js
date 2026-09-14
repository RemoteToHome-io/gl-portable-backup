#!/usr/bin/env node
'use strict';
/* Loads backup.js with stubbed LuCI globals and checks the Plugin section's pure parts: parseVersion and
 * renderUpdateState. The E() stub refuses a bare string child (LuCI renders it as HTML). */
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
	ui: { createHandlerFn: function(self, fn) { return function() {}; }, hideModal: function() {}, showModal: function() {} }
};
var view = new Function('view', 'dom', 'fs', 'ui', 'rpc', 'L', 'E', '_', src)(
	stubs.view, stubs.dom, stubs.fs, stubs.ui, stubs.rpc, stubs.L, E, stubs._);

var failed = 0;
function check(cond, what) { if (cond) { console.log('ok ' + what); } else { console.log('FAIL ' + what); failed++; } }
function text(node) {
	if (typeof node === 'string') return node;
	return node.children.map(function(c) { return typeof c === 'string' ? c : text(c); }).join('');
}
function find(nodes, tag) {
	var out = [];
	(Array.isArray(nodes) ? nodes : [nodes]).forEach(function(n) {
		if (typeof n === 'string') return;
		if (n.tag === tag) out.push(n);
		out = out.concat(find(n.children || [], tag));
	});
	return out;
}
function allText(nodes) { return (Array.isArray(nodes) ? nodes : [nodes]).map(text).join(' | '); }

/* 1. parseVersion */
check(view.parseVersion('gl-portable-backup 1.1.0\n') === '1.1.0', 'parseVersion: tool line');
check(view.parseVersion('') === 'unknown', 'parseVersion: empty');
check(view.parseVersion('garbage') === 'unknown', 'parseVersion: no version');

/* 2. initial state: version line only */
var s0 = view.renderUpdateState({ installed: '1.1.0' });
check(allText(s0) === 'Installed version: 1.1.0', 'initial: version line only');
check(find(s0, 'button').length === 0, 'initial: no button');

/* 3. update available with a project release URL */
var s1 = view.renderUpdateState({ installed: '1.1.0', installed_via_opkg: true, latest: '1.2.0', update_available: true,
	release_url: 'https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.2.0', message: '', checked: true });
check(allText(s1).indexOf('Version 1.2.0 is available.') >= 0, 'available: sentence');
var a = find(s1, 'a');
check(a.length === 1 && a[0].attrs.href === 'https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.2.0'
	&& a[0].attrs.target === '_blank' && a[0].attrs.rel === 'noopener', 'available: release link with noopener');
var b = find(s1, 'button');
check(b.length === 1 && text(b[0]) === 'Update to 1.2.0', 'available: update button');

/* 4. a release URL outside the project renders no link, the button stays */
var s2 = view.renderUpdateState({ installed: '1.1.0', installed_via_opkg: true, latest: '1.2.0', update_available: true,
	release_url: 'https://evil.example/x', message: '', checked: true });
check(find(s2, 'a').length === 0, 'foreign url: no link');
check(find(s2, 'button').length === 1, 'foreign url: button stays');

/* 5. a message that looks like markup is a text child */
var s3 = view.renderUpdateState({ installed: '1.1.0', message: '<img src=x onerror=alert(1)>', checked: true });
var p = find(s3, 'p').filter(function(n) { return n.attrs['class'] === 'alert-message'; });
check(p.length === 1 && p[0].children.length === 1 && p[0].children[0] === '<img src=x onerror=alert(1)>', 'message: text child');

/* 6. not installed through opkg: notice, no button even when a release exists */
var s4 = view.renderUpdateState({ installed: '1.1.0', installed_via_opkg: false, latest: '1.2.0', update_available: false, message: '', checked: true });
check(allText(s4).indexOf('Not installed through opkg') >= 0, 'not via opkg: notice');
check(find(s4, 'button').length === 0, 'not via opkg: no button');

/* 7. checked and current */
var s5 = view.renderUpdateState({ installed: '1.2.0', installed_via_opkg: true, latest: '1.2.0', update_available: false, message: '', checked: true });
check(allText(s5).indexOf('Up to date.') >= 0, 'current: up to date');

console.log(failed === 0 ? 'update-section: all checks passed' : ('update-section: ' + failed + ' check(s) failed'));
process.exit(failed === 0 ? 0 : 1);
