'use strict';
'require view';
'require dom';
'require fs';
'require ui';
'require rpc';

/* GL Portable Backup
 * Copyright (c) 2026 RemoteToHome Consulting — https://remotetohome.io
 * Licensed under the GNU General Public License v3.0 or later.
 */

var BACKEND = '/usr/sbin/gl-portable-backup';

/* Only release pages under the project are ever rendered as a link; the URL comes from the network. */
var RELEASES_URL_PREFIX = 'https://github.com/RemoteToHome-io/gl-portable-backup/';

return view.extend({

	handleCreate: function(ev) {
		var mode = document.querySelector('input[name="backup_mode"]:checked');
		if (!mode) {
			ui.addNotification(null, E('p', _('Please select a backup mode.')));
			return;
		}
		mode = mode.value;

		var notes = document.getElementById('backup_notes');
		var notesVal = notes ? notes.value.trim() : '';

		var btn = ev.target;
		btn.disabled = true;
		btn.firstChild.data = _('Creating backup…');

		var args = ['create', '--mode', mode];
		if (notesVal)
			args.push('--notes', notesVal);

		return fs.exec(BACKEND, args).then(L.bind(function(res) {
			if (res.code !== 0) {
				ui.addNotification(null, [
					E('p', _('Backup creation failed with code %d').format(res.code)),
					res.stderr ? E('pre', {}, [ res.stderr ]) : ''
				]);
				return;
			}

			var archivePath = (res.stdout || '').trim();
			if (!archivePath) {
				ui.addNotification(null, E('p', _('Backup created but no output path returned.')));
				return;
			}

			/* Download the backup file via CGI */
			var form = E('form', {
				method: 'post',
				action: L.env.cgi_base + '/cgi-download',
				enctype: 'application/x-www-form-urlencoded'
			}, [
				E('input', { type: 'hidden', name: 'sessionid', value: rpc.getSessionID() }),
				E('input', { type: 'hidden', name: 'path', value: archivePath }),
				E('input', { type: 'hidden', name: 'filename', value: archivePath.split('/').pop() })
			]);

			document.body.appendChild(form);
			form.submit();
			document.body.removeChild(form);

			/* Clean up temp file after a delay */
			window.setTimeout(function() {
				fs.remove(archivePath);
			}, 5000);

			ui.addNotification(null, E('p', _('Backup created successfully.')), 'info');

		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', _('Error: %s').format(e.message)));
		}).finally(function() {
			btn.disabled = false;
			btn.firstChild.data = _('Create backup');
		});
	},

	/* The archive's contents, from the manifest the backend's inspect command returned. Rendered
	 * collapsed: a Full archive lists roughly 80 config files and 100 extra files. Every entry is
	 * an archive-controlled string, so each one is passed to E() inside an array — LuCI renders a
	 * bare string child as HTML. Returns null for a manifest that carries neither list. */
	renderContents: function(manifest) {
		var sections = Array.isArray(manifest.sections) ? manifest.sections : null;
		var extra = Array.isArray(manifest.extra_files) ? manifest.extra_files : null;
		if (!sections && !extra)
			return null;

		var isProfile = (manifest.mode === 'profile');
		var counts = [];
		if (sections)
			counts.push(isProfile ? _('%d API captures').format(sections.length)
			                      : _('%d config files').format(sections.length));
		if (extra && !isProfile)
			counts.push(_('%d extra files').format(extra.length));

		var listOf = function(items) {
			return E('ul', { 'style': 'margin: 0 0 0.5em 1.2em; padding: 0' }, items.map(function(item) {
				return E('li', {}, [ '' + item ]);
			}));
		};

		var body = [];
		if (sections) {
			body.push(E('strong', {}, [ isProfile ? _('API captures') : _('Config files') ]));
			body.push(listOf(sections));
		}
		if (extra && extra.length > 0) {
			body.push(E('strong', {}, [ _('Extra files') ]));
			body.push(listOf(extra));
		}

		return E('details', { 'style': 'margin: 0.5em 0' }, [
			E('summary', {}, [ _('Contents: %s').format(counts.join(', ')) ]),
			E('div', { 'style': 'max-height: 12em; overflow: auto; font-family: monospace; font-size: 90%; padding: 0.25em 0 0 0.5em' }, body)
		]);
	},

	/* Warnings for an archive that may come from a compromised router, from the keys the backend's
	 * inspect command appends (startup_and_login_files) and the manifest records at backup time
	 * (suspect_markers). Every path is an archive-controlled string, so each one is passed to E()
	 * inside an array — LuCI renders a bare string child as HTML. Returns an array of nodes, empty
	 * when neither list has entries. */
	renderCompromiseWarnings: function(manifest) {
		var nodes = [];
		var listOf = function(items) {
			return E('ul', { 'style': 'margin: 0.25em 0 0 1.2em; padding: 0; font-family: monospace' }, items.map(function(item) {
				return E('li', {}, [ '' + item ]);
			}));
		};
		var startup = Array.isArray(manifest.startup_and_login_files) ? manifest.startup_and_login_files : [];
		var markers = Array.isArray(manifest.suspect_markers) ? manifest.suspect_markers : [];

		if (startup.length > 0) {
			nodes.push(E('p', { 'class': 'alert-message warning' }, [
				_('WARNING: this archive restores files that run at startup or control logins. If the source router may have been compromised, inspect these before rebooting:'),
				listOf(startup)
			]));
		}
		if (markers.length > 0) {
			nodes.push(E('p', { 'class': 'alert-message danger' }, [
				_('WARNING: this archive was made on a router that showed signs of the 2026-11-20 compromise. A backup of a compromised router can carry the attacker\'s changes back; treat every key and password in it as exposed. Paths found:'),
				listOf(markers)
			]));
		}
		return nodes;
	},

	handleRestore: function(ev) {
		var btn = ev.target;
		return ui.uploadFile('/tmp/gl-portable-restore.tar.gz', btn)
			.then(L.bind(function(btn, res) {
				btn.firstChild.data = _('Inspecting archive…');

				/* Read device firmware version and the archive's SSH host-key fingerprint
				 * alongside the inspect call */
				return Promise.all([
					fs.exec(BACKEND, ['inspect', '/tmp/gl-portable-restore.tar.gz']),
					fs.read('/etc/glversion').then(function(v) {
						return (v || '').trim();
					}).catch(function() { return 'unknown'; }),
					fs.exec(BACKEND, ['fingerprint', '/tmp/gl-portable-restore.tar.gz'])
						.then(function(r) {
							return ((r.stdout || '').trim()).replace(/^Fingerprint:\s*/i, '');
						}).catch(function() { return ''; })
				]);
			}, this, btn))
			.then(L.bind(function(btn, results) {
				var res = results[0];
				var deviceFw = results[1];
				var hostKeyFp = results[2];

				if (res.code !== 0) {
					ui.addNotification(null, E('p', _('Invalid backup archive.')));
					return fs.remove('/tmp/gl-portable-restore.tar.gz');
				}

				var manifest;
				try {
					manifest = JSON.parse(res.stdout);
				} catch(e) {
					ui.addNotification(null, E('p', _('Failed to parse backup manifest.')));
					return fs.remove('/tmp/gl-portable-restore.tar.gz');
				}

				var modeLabels = {
					'clone': _('Clone (same-model deployment)'),
					'remote-safe': _('Remote-Safe (preserves remote access)'),
					'profile': _('Profile (cross-model essentials)'),
					'full': _('Full (device-specific raw backup)')
				};

				var backupFw = manifest.source.firmware_version || 'unknown';
				var fwMatch = (backupFw === deviceFw);

				var bodyItems = [
					E('p', _('Backup details:')),
					E('ul', {}, [
						E('li', {}, [ _('Mode: %s').format(modeLabels[manifest.mode] || manifest.mode) ]),
						E('li', {}, [ _('Model: %s').format(manifest.source.model || 'unknown') ]),
						E('li', {}, [ _('Hostname: %s').format(manifest.source.hostname || 'unknown') ]),
						E('li', {}, [
							_('Firmware: %s').format(backupFw),
							(!fwMatch && deviceFw !== 'unknown')
								? E('span', { 'style': 'color: #c44; font-weight: bold' },
									[ _(' (this device: %s)').format(deviceFw) ])
								: ''
						]),
						E('li', {}, [ _('Created: %s').format(manifest.created_at || 'unknown') ])
					])
				];
				/* The archive's contents — collapsed, so the warnings below stay in view */
				var contents = this.renderContents(manifest);
				if (contents)
					bodyItems.push(contents);

				/* Firmware version mismatch warning */
				if (!fwMatch && deviceFw !== 'unknown' && backupFw !== 'unknown'
						&& manifest.mode !== 'profile') {
					bodyItems.push(E('p', { 'class': 'alert-message warning' },
						[ _('Firmware version mismatch: backup was created on %s, this device runs %s. UCI config schema may differ between firmware versions. Clone and Remote-Safe restores are safest between identical versions. Consider Profile mode for cross-version portability.').format(backupFw, deviceFw) ]));
				}

				if (manifest.excluded_sections && manifest.excluded_sections.length > 0) {
					bodyItems.push(E('p', { 'class': 'alert-message' },
						[ _('The following configs will NOT be overwritten (preserved from this device): %s')
							.format(manifest.excluded_sections.join(', ')) ]));
				}

				if (manifest.mode === 'full') {
					bodyItems.push(E('p', { 'class': 'alert-message danger' },
						_('WARNING: This is a full backup. Hardware identifiers (MAC addresses, DDNS IDs) will be overwritten. Only restore to the same physical device.')));
				}

				/* Identity overwrites: the SSH host keys (opt-out below) and the root password */
				if (manifest.restores_ssh_host_keys) {
					bodyItems.push(E('p', { 'class': 'alert-message warning' },
						[ hostKeyFp
							? _('WARNING: this archive restores the SSH host keys of the source router — SSH clients will see a changed key. Expected fingerprint after restore: %s').format(hostKeyFp)
							: _('WARNING: this archive restores the SSH host keys of the source router — SSH clients will see a changed key.') ]));
					bodyItems.push(E('div', { 'style': 'padding: 0.25em 0 0.75em' }, [
						E('label', {}, [
							E('input', { 'type': 'checkbox', 'id': 'gl-pb-keep-host-keys' }), ' ',
							_('Keep this device\'s SSH host keys')
						])
					]));
				}

				if (manifest.restores_root_password) {
					bodyItems.push(E('p', { 'class': 'alert-message warning' },
						_('WARNING: this archive restores /etc/shadow — the root (admin) password becomes the password of the source unit.')));
				}

				/* Startup/login files and compromise markers — archive-controlled paths */
				this.renderCompromiseWarnings(manifest).forEach(function(node) {
					bodyItems.push(node);
				});

				if (manifest.mode === 'clone' || manifest.mode === 'remote-safe') {
					bodyItems.push(E('p', { 'class': 'alert-message' },
						_('Hardware identifiers will be preserved. WireGuard keys will need to be regenerated after restore.')));
				}

				bodyItems.push(E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.createHandlerFn(this, function() {
							return fs.remove('/tmp/gl-portable-restore.tar.gz').finally(ui.hideModal);
						})
					}, [ _('Cancel') ]), ' ',
					E('button', {
						'class': 'btn cbi-button-action important',
						'click': ui.createHandlerFn(this, 'handleRestoreConfirm', btn)
					}, [ _('Restore') ])
				]));

				ui.showModal(_('Restore backup?'), bodyItems);

			}, this, btn))
			.catch(function(e) {
				ui.addNotification(null, E('p', _('Error: %s').format(e.message)));
			})
			.finally(L.bind(function(btn) {
				btn.firstChild.data = _('Upload archive…');
			}, this, btn));
	},

	handleRestoreConfirm: function(btn, ev) {
		/* Read the opt-out before showModal replaces the confirm dialog's DOM */
		var keepHostKeys = document.getElementById('gl-pb-keep-host-keys');
		var args = [ 'restore' ];
		if (keepHostKeys && keepHostKeys.checked)
			args.push('--keep-host-keys');
		args.push('/tmp/gl-portable-restore.tar.gz');

		ui.showModal(_('Restoring…'), [
			E('p', { 'class': 'spinning' }, _('Applying backup configuration. Please wait…'))
		]);

		return fs.exec(BACKEND, args)
			.then(L.bind(function(res) {
				if (res.code !== 0 || (res.stdout || '').indexOf('RESTORE_OK') === -1) {
					ui.hideModal();
					ui.addNotification(null, [
						E('p', _('Restore failed.')),
						res.stderr ? E('pre', {}, [ res.stderr ]) : '',
						res.stdout ? E('pre', {}, [ res.stdout ]) : ''
					]);
					return;
				}

				ui.showModal(_('Restore complete'), [
					E('p', _('Configuration has been restored. A reboot is recommended to apply all changes.')),
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'btn',
							'click': ui.createHandlerFn(this, function() {
								fs.remove('/tmp/gl-portable-restore.tar.gz');
								ui.hideModal();
							})
						}, [ _('Close') ]), ' ',
						E('button', {
							'class': 'btn cbi-button-action',
							'click': ui.createHandlerFn(this, 'handlePackageReview',
								'/tmp/gl-portable-restore.tar.gz')
						}, [ _('Review packages…') ]), ' ',
						E('button', {
							'class': 'btn cbi-button-action important',
							'click': ui.createHandlerFn(this, function() {
								fs.remove('/tmp/gl-portable-restore.tar.gz');
								ui.showModal(_('Rebooting…'), [
									E('p', { 'class': 'spinning' }, _('The router is rebooting. You may need to reconnect.'))
								]);
								fs.exec('/sbin/reboot');
								ui.awaitReconnect(window.location.host);
							})
						}, [ _('Reboot now') ])
					])
				]);
			}, this))
			.catch(function(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Error: %s').format(e.message)));
			});
	},

	/* ── Package Review ─────────────────────────────────────────────────── */

	handlePackageReview: function(archive, ev) {
		ui.showModal(_('Package Review'), [
			E('p', { 'class': 'spinning' }, _('Comparing packages…'))
		]);

		return fs.exec(BACKEND, ['packages', archive]).then(L.bind(function(res) {
			if (res.code !== 0) {
				ui.hideModal();
				ui.addNotification(null, [
					E('p', _('Package comparison failed.')),
					res.stderr ? E('pre', {}, [ res.stderr ]) : ''
				]);
				return;
			}

			var data;
			try {
				data = JSON.parse(res.stdout);
			} catch(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Failed to parse package comparison results.')));
				return;
			}

			this.showPackageReviewModal(data);
		}, this));
	},

	handlePackageReviewStandalone: function(ev) {
		var btn = ev.target;
		var archivePath = '/tmp/gl-portable-pkgreview.tar.gz';

		return ui.uploadFile(archivePath, btn)
			.then(L.bind(function(btn, res) {
				btn.firstChild.data = _('Analyzing packages…');
				return this.handlePackageReview(archivePath);
			}, this, btn))
			.catch(function(e) {
				ui.addNotification(null, E('p', _('Error: %s').format(e.message)));
			})
			.finally(L.bind(function(btn) {
				btn.firstChild.data = _('Review packages in archive…');
				fs.remove(archivePath);
			}, this, btn));
	},

	showPackageReviewModal: function(data) {
		var body = [];
		var selectedPkgs = {};

		/* ── Header: kernel info ── */
		var kernelStatus = data.kernel_match
			? E('span', { 'style': 'color: #2a2' }, _('Match'))
			: E('span', { 'style': 'color: #c44; font-weight: bold' }, _('MISMATCH'));

		body.push(E('div', { 'style': 'margin-bottom: 1em' }, [
			E('p', {}, [
				E('strong', {}, _('Source kernel: ')),
				data.source_kernel || _('unknown')
			]),
			E('p', {}, [
				E('strong', {}, _('Target kernel: ')),
				data.target_kernel || _('unknown')
			]),
			E('p', {}, [
				E('strong', {}, _('Kernel compatibility: ')),
				kernelStatus
			])
		]));

		/* ── Feeds warning ── */
		if (!data.feeds_available) {
			body.push(E('p', { 'class': 'alert-message warning' },
				_('opkg package feeds are not available. Cannot determine which missing packages are installable from repositories. Connect to the internet and run "opkg update" first for best results.')));
		}

		/* ── Section 1: Kernel Modules ── */
		if (data.missing_kmod && data.missing_kmod.length > 0) {
			body.push(E('h4', {},
				_('Kernel Modules — Manual Install Required (%d)').format(data.missing_kmod.length)));
			body.push(E('p', { 'class': 'alert-message danger' },
				_('These kernel modules are tied to a specific firmware build. They cannot be installed from opkg repositories. Install firmware-matched .ipk files manually.')));

			var kmodRows = [
				E('tr', { 'class': 'tr cbi-section-table-titles' }, [
					E('th', { 'class': 'th left' }, _('Package')),
					E('th', { 'class': 'th left' }, _('Version')),
					E('th', { 'class': 'th left' }, _('Description'))
				])
			];
			data.missing_kmod.forEach(function(pkg) {
				kmodRows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, [ pkg.name || '-' ]),
					E('td', { 'class': 'td left' }, [ pkg.version || '-' ]),
					E('td', { 'class': 'td left' }, [ pkg.description || '-' ])
				]));
			});
			body.push(E('table', { 'class': 'table' }, kmodRows));
		}

		/* ── Section 2: Missing — Not in repositories ── */
		if (data.missing_unavailable && data.missing_unavailable.length > 0) {
			body.push(E('h4', {},
				_('Missing — Not in Repositories (%d)').format(data.missing_unavailable.length)));
			body.push(E('p', { 'class': 'alert-message' },
				_('These packages are not available in configured opkg feeds. Install from .ipk files.')));

			var unavRows = [
				E('tr', { 'class': 'tr cbi-section-table-titles' }, [
					E('th', { 'class': 'th left' }, _('Package')),
					E('th', { 'class': 'th left' }, _('Version')),
					E('th', { 'class': 'th left' }, _('Description'))
				])
			];
			data.missing_unavailable.forEach(function(pkg) {
				unavRows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, [ pkg.name || '-' ]),
					E('td', { 'class': 'td left' }, [ pkg.version || '-' ]),
					E('td', { 'class': 'td left' }, [ pkg.description || '-' ])
				]));
			});
			body.push(E('table', { 'class': 'table' }, unavRows));
		}

		/* ── Section 3: Missing — Available (checkboxes) ── */
		var installBtn;

		function countSelected() {
			var n = 0;
			for (var k in selectedPkgs) if (selectedPkgs[k]) n++;
			return n;
		}

		function updateInstallButton() {
			if (!installBtn) return;
			var n = countSelected();
			installBtn.firstChild.data = n > 0
				? _('Install %d selected packages').format(n)
				: _('No packages selected');
			installBtn.disabled = (n === 0);
		}

		if (data.missing_available && data.missing_available.length > 0) {
			body.push(E('h4', {},
				_('Missing — Available in Repositories (%d)').format(data.missing_available.length)));

			var availList = E('div', { 'class': 'cbi-section' });

			data.missing_available.forEach(function(pkg) {
				selectedPkgs[pkg.name] = true;

				var cb = E('input', {
					'type': 'checkbox',
					'checked': 'checked',
					'data-package': pkg.name,
					'change': function(ev) {
						selectedPkgs[ev.target.getAttribute('data-package')] = ev.target.checked;
						updateInstallButton();
					}
				});

				availList.appendChild(E('div', { 'style': 'padding: 0.25em 0' }, [
					E('label', {}, [
						cb, ' ',
						E('strong', {}, [ pkg.name || '' ]),
						' ',
						E('span', { 'style': 'color: #888' },
							[ pkg.available_version || pkg.source_version || '' ]),
						pkg.description
							? E('span', { 'style': 'color: #666; margin-left: 1em' },
								[ '\u2014 ' + pkg.description ])
							: ''
					])
				]));
			});

			body.push(availList);

			body.push(E('div', { 'style': 'margin: 0.5em 0' }, [
				E('a', {
					'href': '#',
					'click': function(ev) {
						ev.preventDefault();
						availList.querySelectorAll('input[type="checkbox"]').forEach(function(cb) {
							cb.checked = true;
							selectedPkgs[cb.getAttribute('data-package')] = true;
						});
						updateInstallButton();
					}
				}, _('Select all')),
				' | ',
				E('a', {
					'href': '#',
					'click': function(ev) {
						ev.preventDefault();
						availList.querySelectorAll('input[type="checkbox"]').forEach(function(cb) {
							cb.checked = false;
							selectedPkgs[cb.getAttribute('data-package')] = false;
						});
						updateInstallButton();
					}
				}, _('Deselect all'))
			]));
		}

		/* ── Section 4: Already installed ── */
		if (data.installed && data.installed.length > 0) {
			body.push(E('h4', {},
				_('Already Installed (%d)').format(data.installed.length)));

			var instRows = [
				E('tr', { 'class': 'tr cbi-section-table-titles' }, [
					E('th', { 'class': 'th left' }, _('Package')),
					E('th', { 'class': 'th left' }, _('Source Version')),
					E('th', { 'class': 'th left' }, _('Target Version')),
					E('th', { 'class': 'th left' }, _('Status'))
				])
			];

			data.installed.forEach(function(pkg) {
				var statusEl = (pkg.version_match === true)
					? E('span', { 'style': 'color: #2a2' }, _('Match'))
					: (pkg.source_version && pkg.target_version)
						? E('span', { 'style': 'color: #e90' }, _('Version differs'))
						: E('span', { 'style': 'color: #888' }, '-');

				instRows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, [ pkg.name || '-' ]),
					E('td', { 'class': 'td left' }, [ pkg.source_version || '-' ]),
					E('td', { 'class': 'td left' }, [ pkg.target_version || '-' ]),
					E('td', { 'class': 'td left' }, [ statusEl ])
				]));
			});

			body.push(E('table', { 'class': 'table' }, instRows));
		}

		/* ── No packages at all ── */
		if ((!data.installed || data.installed.length === 0) &&
			(!data.missing_kmod || data.missing_kmod.length === 0) &&
			(!data.missing_available || data.missing_available.length === 0) &&
			(!data.missing_unavailable || data.missing_unavailable.length === 0)) {
			body.push(E('p', { 'style': 'color: #888' },
				_('No user-installed packages found in backup archive.')));
		}

		/* ── Footer buttons ── */
		var hasInstallable = data.missing_available && data.missing_available.length > 0;

		var footerButtons = [
			E('button', {
				'class': 'btn',
				'click': ui.hideModal
			}, [ _('Close') ])
		];

		if (hasInstallable) {
			installBtn = E('button', {
				'class': 'btn cbi-button-action important',
				'click': ui.createHandlerFn(this, 'handleInstallSelected', selectedPkgs)
			}, [ _('Install %d selected packages').format(countSelected()) ]);
			footerButtons.push(document.createTextNode(' '));
			footerButtons.push(installBtn);
		}

		body.push(E('div', { 'class': 'right', 'style': 'margin-top: 1em' }, footerButtons));

		ui.showModal(_('Package Review'), body);
	},

	handleInstallSelected: function(selectedPkgs, ev) {
		var pkgs = [];
		for (var name in selectedPkgs) {
			if (selectedPkgs[name]) pkgs.push(name);
		}

		if (pkgs.length === 0) return;

		var total = pkgs.length;
		var current = 0;
		var results = [];

		var progressEl = E('p', { 'class': 'spinning' },
			_('Installing package %d of %d…').format(1, total));
		var logEl = E('pre', { 'style': 'max-height: 300px; overflow-y: auto; font-size: 0.85em' }, []);

		ui.showModal(_('Installing Packages'), [ progressEl, logEl ]);

		var installNext = L.bind(function() {
			if (current >= pkgs.length) {
				/* All done */
				progressEl.classList.remove('spinning');

				var successes = results.filter(function(r) { return r.code === 0; }).length;
				var failures = results.filter(function(r) { return r.code !== 0; }).length;

				progressEl.textContent = _('Installation complete. %d succeeded, %d failed.')
					.format(successes, failures);

				var doneBtn = E('div', { 'class': 'right', 'style': 'margin-top: 1em' }, [
					E('button', {
						'class': 'btn',
						'click': ui.hideModal
					}, [ _('Close') ])
				]);

				progressEl.parentNode.appendChild(doneBtn);
				return;
			}

			var pkg = pkgs[current];
			progressEl.textContent = _('Installing %s (%d of %d)…').format(pkg, current + 1, total);

			fs.exec_direct('/usr/libexec/opkg-call', ['install', pkg], 'json')
				.then(L.bind(function(pkg, res) {
					var code = (res && res.code !== undefined) ? res.code : -1;
					results.push({ name: pkg, code: code });

					if (code === 0) {
						logEl.appendChild(document.createTextNode(
							'\u2713 ' + pkg + ': installed successfully\n'));
					} else {
						logEl.appendChild(document.createTextNode(
							'\u2717 ' + pkg + ': failed \u2014 ' +
							(res.stderr || 'unknown error').trim() + '\n'));
					}

					logEl.scrollTop = logEl.scrollHeight;
					current++;
					installNext();
				}, this, pkg))
				.catch(L.bind(function(pkg, err) {
					results.push({ name: pkg, code: -1 });
					logEl.appendChild(document.createTextNode(
						'\u2717 ' + pkg + ': error \u2014 ' + err.message + '\n'));
					current++;
					installNext();
				}, this, pkg));
		}, this);

		installNext();
	},

	/* ── Plugin self-update ──────────────────────────────────────────── */

	/* "gl-portable-backup 1.1.0" → "1.1.0"; anything else → "unknown". */
	parseVersion: function(stdout) {
		var m = /(\d+(?:\.\d+)*(?:-[\w.]+)?)\s*$/.exec((stdout || '').trim());
		return m ? m[1] : 'unknown';
	},

	/* Only a page under the project's own GitHub releases may be linked: the URL came over the network.
	 * A dot segment would let github.com resolve the link elsewhere on the site, so those are refused too. */
	releaseLinkOk: function(url) {
		if (typeof url !== 'string' || url.indexOf(RELEASES_URL_PREFIX) !== 0)
			return false;
		var rest = url.substring(RELEASES_URL_PREFIX.length);
		return !/(^|\/)\.\.?(\/|$)/.test(rest) && !/[\s\\]/.test(rest);
	},

	load: function() {
		return fs.exec(BACKEND, ['version']).then(L.bind(function(res) {
			return { version: this.parseVersion(res.stdout) };
		}, this)).catch(function() { return { version: 'unknown' }; });
	},

	/* The Plugin section's body for one state (the update-check reply plus `installed` and `checked`).
	 * Every string that came over the network is an array child of E(): LuCI renders a bare string
	 * child as HTML. */
	renderUpdateState: function(state) {
		var nodes = [ E('p', {}, [ _('Installed version: %s').format(state.installed || 'unknown') ]) ];
		if (state.message)
			nodes.push(E('p', { 'class': 'alert-message' }, [ '' + state.message ]));
		if (state.installed_via_opkg === false)
			nodes.push(E('p', {}, [ _('Not installed through opkg, so self-update is unavailable — install a release package first.') ]));
		if (state.update_available) {
			var line = [ _('Version %s is available.').format(state.latest) ];
			if (this.releaseLinkOk(state.release_url)) {
				line.push(' ');
				line.push(E('a', { 'href': state.release_url, 'target': '_blank', 'rel': 'noopener noreferrer' }, [ _('Release notes') ]));
			}
			nodes.push(E('p', {}, line));
			nodes.push(E('button', {
				'class': 'btn cbi-button-action important',
				'click': ui.createHandlerFn(this, 'handleUpdateNow', state.latest)
			}, [ _('Update to %s').format(state.latest) ]));
		} else if (state.checked && !state.message && state.installed_via_opkg !== false) {
			nodes.push(E('p', {}, [ _('Up to date.') ]));
		}
		return nodes;
	},

	setUpdateState: function(state) {
		var box = document.getElementById('gl-pb-update');
		if (!box)
			return;
		if (!state.installed)
			state.installed = this.installedVersion || 'unknown';
		dom.content(box, this.renderUpdateState(state));
	},

	handleUpdateCheck: function(ev) {
		var btn = ev.target;
		btn.disabled = true;
		return fs.exec(BACKEND, ['update-check']).then(L.bind(function(res) {
			var st = null;
			if (res.code === 0) {
				try { st = JSON.parse((res.stdout || '').trim()); } catch (e) { st = null; }
			}
			if (!st)
				st = { message: _('The update check failed: %s').format(((res.stderr || res.stdout || '').trim()) || _('no details were reported')) };
			st.checked = true;
			this.setUpdateState(st);
		}, this)).catch(L.bind(function(e) {
			this.setUpdateState({ message: _('The update check failed: %s').format((e && e.message) || _('request error')), checked: true });
		}, this)).finally(function() { btn.disabled = false; });
	},

	handleUpdateNow: function(version, ev) {
		ui.showModal(_('Update the plugin?'), [
			E('p', {}, [ _('Version %s will be downloaded from GitHub over HTTPS, verified against the release\'s SHA256SUMS, and installed with opkg. Reload the page when it finishes.').format(version) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, 'handleUpdateStart')
				}, [ _('Update now') ])
			])
		]);
	},

	handleUpdateStart: function(ev) {
		ui.showModal(_('Updating…'), [
			E('p', { 'class': 'spinning', 'id': 'gl-pb-update-progress' }, [ _('Starting…') ])
		]);
		return fs.exec(BACKEND, ['update-start']).then(L.bind(function(res) {
			var st = null;
			if (res.code === 0) {
				try { st = JSON.parse((res.stdout || '').trim()); } catch (e) { st = null; }
			}
			if (!st || st.status !== 'started') {
				this.finishUpdate({ status: 'error', message: (st && st.message) || ((res.stderr || res.stdout || '').trim()) || _('The update could not be started.') });
				return;
			}
			this.pollUpdate(Date.now() + 15 * 60 * 1000);
		}, this)).catch(L.bind(function(e) {
			this.finishUpdate({ status: 'error', message: (e && e.message) || _('The update could not be started.') });
		}, this));
	},

	/* Polls update-status every 2 s until a terminal status. A reply that cannot be read — the backend file
	 * is being replaced by opkg mid-install — keeps the poll going; only the deadline ends it. */
	pollUpdate: function(deadline) {
		var self = this;
		var again = function() {
			if (Date.now() > deadline) {
				self.finishUpdate({ status: 'timeout', message: _('The update is still running after 15 minutes. Reload the page to see the installed version, or run "gl-portable-backup update-status" over SSH.') });
				return;
			}
			window.setTimeout(function() { self.pollUpdate(deadline); }, 2000);
		};
		return fs.exec(BACKEND, ['update-status']).then(function(res) {
			var st = null;
			if (res.code === 0) {
				try { st = JSON.parse((res.stdout || '').trim()); } catch (e) { st = null; }
			}
			if (!st || st.status === 'running' || st.status === 'idle') {
				var p = document.getElementById('gl-pb-update-progress');
				if (p && st && st.message)
					dom.content(p, [ '' + st.message ]);
				again();
				return;
			}
			self.finishUpdate(st);
		}).catch(again);
	},

	finishUpdate: function(st) {
		var ok = (st.status === 'success');
		var title = ok ? _('Update finished') : (st.status === 'timeout' ? _('Update still running') : _('Update failed'));
		var msg = st.message || (ok ? _('Done.') : _('No details were reported.'));
		ui.showModal(title, [
			E('p', {}, [ '' + msg ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ]), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': function() { window.location.reload(); } }, [ _('Reload page') ])
			])
		]);
	},

	/* ── Render ──────────────────────────────────────────────────────────── */

	render: function(data) {
		this.installedVersion = (data && data.version) || 'unknown';
		var body = [];

		/* ── Header ─────────────────────────────────────────────────── */
		body.push(E('h2', {}, _('GL Portable Backup')));

		/* ── Create Backup Section ──────────────────────────────────── */
		body.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Create Backup')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Select a backup mode and click "Create backup" to download an archive.')),

			E('div', { 'class': 'cbi-value', 'style': 'margin-bottom: 1em' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Backup Mode')),
				E('div', { 'class': 'cbi-value-field' }, [

					E('div', { 'style': 'margin-bottom: 0.5em' }, [
						E('label', {}, [
							E('input', { type: 'radio', name: 'backup_mode', value: 'clone', checked: 'checked' }),
							' ', E('strong', {}, _('Clone')),
							' — ', _('Full configuration for same-model deployment. Strips hardware IDs, VPN keys and per-device identity (ZeroTier node secret, Tailscale state, TLS and SSH keys). Capture is tested; this mode\'s restore has not yet been run end to end on a router.')
						])
					]),

					E('div', { 'style': 'margin-bottom: 0.5em' }, [
						E('label', {}, [
							E('input', { type: 'radio', name: 'backup_mode', value: 'remote-safe' }),
							' ', E('strong', {}, _('Remote-Safe')),
							' — ', _('Same as Clone, but preserves the ZeroTier, GoodCloud, Tailscale and SSH config files. Use when restoring a device you are connected to remotely. In this release the target\'s ZeroTier/Tailscale network and firewall sections are NOT preserved — re-enable those services after the restore — and this mode\'s restore has not yet been run end to end on a router.')
						])
					]),

					E('div', { 'style': 'margin-bottom: 0.5em' }, [
						E('label', {}, [
							E('input', { type: 'radio', name: 'backup_mode', value: 'profile' }),
							' ', E('strong', {}, _('Profile')),
							' — ', _('Complete portable setup for a different GL.iNet model — Wi-Fi, LAN, DNS, firewall, VPN client tunnels and saved access points. Contains Wi-Fi passwords, VPN keys and credentials and saved AP passwords in cleartext; handle like a Full backup. Contains no GoodCloud binding, SSH keys or root password.')
						])
					]),

					E('div', { 'style': 'margin-bottom: 0.5em' }, [
						E('label', {}, [
							E('input', { type: 'radio', name: 'backup_mode', value: 'full' }),
							' ', E('strong', {}, _('Full')),
							' — ', _('Complete raw backup including hardware IDs. For same-device disaster recovery only.')
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Notes (optional)')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						type: 'text', id: 'backup_notes',
						'class': 'cbi-input-text',
						placeholder: _('e.g., Golden image for MT3000 fleet')
					})
				])
			]),

			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, 'handleCreate')
				}, [ _('Create backup') ])
			])
		]));

		/* ── Restore Backup Section ─────────────────────────────────── */
		body.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Restore Backup')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Upload a previously created backup archive to restore configuration.')),

			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, 'handleRestore')
				}, [ _('Upload archive…') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-neutral',
					'click': ui.createHandlerFn(this, 'handlePackageReviewStandalone')
				}, [ _('Review packages in archive…') ])
			])
		]));

		/* ── Plugin Section ─────────────────────────────────────────── */
		body.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Plugin')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Checks GitHub for a newer stable release only when you click. An update is downloaded over HTTPS, verified against the release\'s SHA256SUMS, checked for its own version, and installed with opkg.')),
			E('div', { 'id': 'gl-pb-update' }, this.renderUpdateState({ installed: this.installedVersion })),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleUpdateCheck')
				}, [ _('Check for updates') ])
			])
		]));

		/* ── Footer ─────────────────────────────────────────────────── */
		body.push(E('div', { 'style': 'text-align: center; margin-top: 2em; color: #888; font-size: 0.85em' },
			_('Powered by RemoteToHome Consulting — remotetohome.io')));

		return E('div', { 'class': 'cbi-map' }, body);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
