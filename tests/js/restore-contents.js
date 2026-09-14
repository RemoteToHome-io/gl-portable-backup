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
check(text(find(full, 'summary')[0]) === 'Contents: 2 config files, 3 extra files', 'full: summary counts');
check(find(full, 'strong').map(text).join('|') === 'Config files|Extra files', 'full: two list headings');
check(find(full, 'li').length === 5, 'full: five entries');

/* 2. Profile archive: API captures; no extra-files count or list even though the array is present */
var profile = view.renderContents({ mode: 'profile',
	sections: ['wifi.get_config', 'dns.get_config', 'vlan_subnet.get_subnets'], extra_files: [] });
check(text(find(profile, 'summary')[0]) === 'Contents: 3 API captures', 'profile: summary counts');
check(find(profile, 'strong').map(text).join('|') === 'API captures', 'profile: single heading');

/* 3. Remote-Safe archive: rendered like Full; excluded_sections is not this block's business */
var rs = view.renderContents({ mode: 'remote-safe', sections: ['network'], excluded_sections: ['zerotier'], extra_files: [] });
check(text(find(rs, 'summary')[0]) === 'Contents: 1 config files, 0 extra files', 'remote-safe: summary counts');
check(find(rs, 'strong').map(text).join('|') === 'Config files', 'remote-safe: no empty extra-files list');

/* 4. A manifest without either list (older tool) renders nothing */
check(view.renderContents({ mode: 'clone' }) === null, 'legacy manifest: null');

/* 5. An entry that looks like markup stays a text child — the E() stub throws on a bare string */
var hostile = view.renderContents({ mode: 'full', sections: ['<img src=x onerror=alert(1)>'], extra_files: [] });
var li = find(hostile, 'li')[0];
check(li.children.length === 1 && li.children[0] === '<img src=x onerror=alert(1)>', 'markup-looking entry is a text child');

console.log(failed === 0 ? 'restore-contents: all checks passed' : ('restore-contents: ' + failed + ' check(s) failed'));
process.exit(failed === 0 ? 0 : 1);
