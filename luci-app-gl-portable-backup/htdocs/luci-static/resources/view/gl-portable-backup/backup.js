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

	handleRestore: function(ev) {
		var btn = ev.target;
		return ui.uploadFile('/tmp/gl-portable-restore.tar.gz', btn)
			.then(L.bind(function(btn, res) {
				btn.firstChild.data = _('Inspecting archive…');

				/* Read device firmware version alongside the inspect call */
				return Promise.all([
					fs.exec(BACKEND, ['inspect', '/tmp/gl-portable-restore.tar.gz']),
					fs.read('/etc/glversion').then(function(v) {
						return (v || '').trim();
					}).catch(function() { return 'unknown'; })
				]);
			}, this, btn))
			.then(L.bind(function(btn, results) {
				var res = results[0];
				var deviceFw = results[1];

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
						E('li', {}, _('Mode: %s').format(modeLabels[manifest.mode] || manifest.mode)),
						E('li', {}, _('Model: %s').format(manifest.source.model || 'unknown')),
						E('li', {}, _('Hostname: %s').format(manifest.source.hostname || 'unknown')),
						E('li', {}, [
							_('Firmware: %s').format(backupFw),
							(!fwMatch && deviceFw !== 'unknown')
								? E('span', { 'style': 'color: #c44; font-weight: bold' },
									_(' (this device: %s)').format(deviceFw))
								: ''
						]),
						E('li', {}, _('Created: %s').format(manifest.created_at || 'unknown'))
					])
				];

				/* Firmware version mismatch warning */
				if (!fwMatch && deviceFw !== 'unknown' && backupFw !== 'unknown'
						&& manifest.mode !== 'profile') {
					bodyItems.push(E('p', { 'class': 'alert-message warning' },
						_('Firmware version mismatch: backup was created on %s, this device runs %s. UCI config schema may differ between firmware versions. Clone and Remote-Safe restores are safest between identical versions. Consider Profile mode for cross-version portability.').format(backupFw, deviceFw)));
				}

				if (manifest.excluded_sections && manifest.excluded_sections.length > 0) {
					bodyItems.push(E('p', { 'class': 'alert-message' },
						_('The following configs will NOT be overwritten (preserved from this device): %s')
							.format(manifest.excluded_sections.join(', '))));
				}

				if (manifest.mode === 'full') {
					bodyItems.push(E('p', { 'class': 'alert-message danger' },
						_('WARNING: This is a full backup. Hardware identifiers (MAC addresses, DDNS IDs) will be overwritten. Only restore to the same physical device.')));
				}

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
		ui.showModal(_('Restoring…'), [
			E('p', { 'class': 'spinning' }, _('Applying backup configuration. Please wait…'))
		]);

		return fs.exec(BACKEND, ['restore', '/tmp/gl-portable-restore.tar.gz'])
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
					E('td', { 'class': 'td left' }, pkg.name),
					E('td', { 'class': 'td left' }, pkg.version || '-'),
					E('td', { 'class': 'td left' }, pkg.description || '-')
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
					E('td', { 'class': 'td left' }, pkg.name),
					E('td', { 'class': 'td left' }, pkg.version || '-'),
					E('td', { 'class': 'td left' }, pkg.description || '-')
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
						E('strong', {}, pkg.name),
						' ',
						E('span', { 'style': 'color: #888' },
							pkg.available_version || pkg.source_version || ''),
						pkg.description
							? E('span', { 'style': 'color: #666; margin-left: 1em' },
								'\u2014 ' + pkg.description)
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
					E('td', { 'class': 'td left' }, pkg.name),
					E('td', { 'class': 'td left' }, pkg.source_version || '-'),
					E('td', { 'class': 'td left' }, pkg.target_version || '-'),
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

	/* ── Render ──────────────────────────────────────────────────────────── */

	render: function() {
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
							' — ', _('Full configuration for same-model deployment. Strips hardware IDs.')
						])
					]),

					E('div', { 'style': 'margin-bottom: 0.5em' }, [
						E('label', {}, [
							E('input', { type: 'radio', name: 'backup_mode', value: 'remote-safe' }),
							' ', E('strong', {}, _('Remote-Safe')),
							' — ', _('Same as Clone, but preserves ZeroTier, GoodCloud, Tailscale, and SSH config. Use when restoring a device you are connected to remotely.')
						])
					]),

					E('div', { 'style': 'margin-bottom: 0.5em' }, [
						E('label', {}, [
							E('input', { type: 'radio', name: 'backup_mode', value: 'profile' }),
							' ', E('strong', {}, _('Profile')),
							' — ', _('Basic settings only (Wi-Fi, LAN, DNS, firewall). Portable across different GL.iNet models.')
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

		/* ── Footer ─────────────────────────────────────────────────── */
		body.push(E('div', { 'style': 'text-align: center; margin-top: 2em; color: #888; font-size: 0.85em' },
			_('Powered by RemoteToHome Consulting — remotetohome.io')));

		return E('div', { 'class': 'cbi-map' }, body);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
