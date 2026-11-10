/* filebox 网页投递箱 — 直接调用 GitHub API 读写私有仓库的 inbox/ */
(function () {
  'use strict';

  var API = 'https://api.github.com';
  var OWNER = 'lyz-wave';
  var REPO = 'filebox';
  var BRANCH = 'main';
  var INBOX = 'inbox';

  var LS_TOKEN = 'filebox.token';
  var LS_DEVICE = 'filebox.device';
  var LS_REMEMBER = 'filebox.remember';

  var MAX_SIZE = 50 * 1024 * 1024;
  var WARN_SIZE = 25 * 1024 * 1024;
  var MAX_RETRY = 5;

  var state = {
    token: '',
    device: 'web',
    files: [],
    queue: [],
    uploading: false,
    connected: false,
    seq: 0
  };

  var els = {};
  var toastTimer = 0;

  function $(id) { return document.getElementById(id); }

  document.addEventListener('DOMContentLoaded', function () {
    ['setupCard', 'mainPanel', 'tokenInput', 'deviceInput', 'rememberInput', 'connectBtn', 'clearBtn',
      'setupError', 'settingsBtn', 'searchInput', 'refreshBtn', 'dropzone', 'fileInput', 'queueCard',
      'queueList', 'clearQueueBtn', 'fileList', 'fileCount', 'emptyState', 'toast', 'devicePill'
    ].forEach(function (id) { els[id] = $(id); });

    state.device = normalizeDevice(localStorage.getItem(LS_DEVICE) || defaultDevice());
    els.deviceInput.value = state.device;
    els.devicePill.textContent = '本机标签：' + state.device;
    els.rememberInput.checked = localStorage.getItem(LS_REMEMBER) !== '0';

    bindEvents();

    var savedToken = localStorage.getItem(LS_TOKEN) || '';
    if (savedToken) {
      els.tokenInput.value = savedToken;
      state.token = savedToken;
      connect(true);
    } else {
      showSetup();
    }
  });

  function bindEvents() {
    els.connectBtn.addEventListener('click', function () { connect(false); });
    els.clearBtn.addEventListener('click', clearToken);
    els.settingsBtn.addEventListener('click', function () {
      els.tokenInput.value = state.token || '';
      showSetup();
      els.tokenInput.focus();
    });
    els.searchInput.addEventListener('input', renderFiles);
    els.refreshBtn.addEventListener('click', function () { refreshFiles(false); });
    els.fileInput.addEventListener('change', function (ev) {
      addFiles(ev.target.files);
      ev.target.value = '';
    });
    els.dropzone.addEventListener('click', function () { els.fileInput.click(); });
    els.dropzone.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); els.fileInput.click(); }
    });
    ['dragenter', 'dragover'].forEach(function (name) {
      els.dropzone.addEventListener(name, function (ev) {
        ev.preventDefault();
        ev.stopPropagation();
        els.dropzone.classList.add('dragging');
      });
    });
    ['dragleave', 'dragend'].forEach(function (name) {
      els.dropzone.addEventListener(name, function (ev) {
        ev.preventDefault();
        els.dropzone.classList.remove('dragging');
      });
    });
    els.dropzone.addEventListener('drop', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      els.dropzone.classList.remove('dragging');
      if (ev.dataTransfer) addFiles(ev.dataTransfer.files);
    });
    els.clearQueueBtn.addEventListener('click', function () {
      state.queue = state.queue.filter(function (item) { return item.status !== 'done'; });
      renderQueue();
    });
    window.addEventListener('dragover', function (ev) { ev.preventDefault(); });
    window.addEventListener('drop', function (ev) { ev.preventDefault(); });
  }

  /* ---------- 基础工具 ---------- */

  function defaultDevice() {
    var ua = navigator.userAgent || '';
    if (/iphone/i.test(ua)) return 'iphone';
    if (/ipad/i.test(ua)) return 'ipad';
    if (/android/i.test(ua)) return 'android';
    if (/mac os x|macintosh/i.test(ua)) return 'mac';
    if (/windows/i.test(ua)) return 'win';
    return 'web';
  }

  function normalizeDevice(value) {
    var s = String(value || '').toLowerCase()
      .replace(/[^a-z0-9._-]/g, '')
      .replace(/(^[._-]+)|([._-]+$)/g, '')
      .slice(0, 24);
    return s;
  }

  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function stampPrefix() {
    var d = new Date();
    return '' + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) + '-' +
      pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds()) + '_';
  }

  function baseName(path) {
    var s = String(path || '').replace(/\\/g, '/');
    var i = s.lastIndexOf('/');
    return i >= 0 ? s.slice(i + 1) : s;
  }

  function prettyName(name) {
    var m = String(name || '').match(/^[0-9]{8}-[0-9]{6}_([a-z0-9._-]+?)_(.*)$/i);
    return m ? m[2] : name;
  }

  function prettyStamp(name) {
    var m = String(name || '').match(/^([0-9]{8})-([0-9]{6})_/);
    if (!m) return '';
    var d = m[1];
    var t = m[2];
    return d.slice(0, 4) + '-' + d.slice(4, 6) + '-' + d.slice(6, 8) + ' ' +
      t.slice(0, 2) + ':' + t.slice(2, 4) + ':' + t.slice(4, 6);
  }

  function formatSize(bytes) {
    var n = Number(bytes) || 0;
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function iconFor(name) {
    var ext = String(name || '').split('.').pop().toLowerCase();
    var map = {
      pdf: '📄', txt: '📃', md: '📘', doc: '📝', docx: '📝', rtf: '📝',
      xls: '📊', xlsx: '📊', csv: '📊', ppt: '📽', pptx: '📽',
      jpg: '🖼', jpeg: '🖼', png: '🖼', gif: '🖼', webp: '🖼', heic: '🖼', svg: '🖼',
      mp3: '🎧', wav: '🎧', flac: '🎧', m4a: '🎧',
      mp4: '🎬', mov: '🎬', mkv: '🎬', avi: '🎬',
      zip: '🗜', rar: '🗜', '7z': '🗜', tar: '🗜', gz: '🗜',
      exe: '⚙️', msi: '⚙️', dmg: '⚙️', apk: '📱', ipa: '📱',
      json: '🧾', xml: '🧾', yml: '🧾', yaml: '🧾', ps1: '💻', sh: '💻', js: '💻', py: '💻', code: '💻'
    };
    return map[ext] || '📄';
  }

  /* ---------- 提示 ---------- */

  function toast(message, kind) {
    var cls = 'toast show';
    if (kind) cls += ' ' + kind;
    els.toast.className = cls;
    els.toast.textContent = message;
    els.toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      els.toast.className = kind ? ('toast ' + kind) : 'toast';
      els.toast.hidden = true;
    }, kind === 'err' ? 6000 : 3200);
  }

  function setSetupError(message) {
    els.setupError.textContent = message || '';
    els.setupError.hidden = !message;
  }

  function formatError(err) {
    if (err && err.network) return '网络错误：无法连接 api.github.com（检查网络或代理后重试）。';
    if (!err || !err.status) return '请求失败：' + ((err && err.message) || '未知错误');
    if (err.status === 401) return '令牌无效或已过期，请重新生成后再试。';
    if (err.status === 403) {
      if (err.data && err.data.message && /rate limit/i.test(err.data.message)) {
        return '请求太频繁，被 GitHub 限流了，等一会儿再试。';
      }
      return '令牌权限不足（需要 Contents: Read and write），或该令牌没有这个仓库的访问权限。';
    }
    if (err.status === 404) return '仓库或 inbox 不存在：确认令牌选的是 lyz-wave/filebox，且仓库没有被改名。';
    if (err.status === 422) return '请求被 GitHub 拒绝：' + ((err.data && err.data.message) || '文件名可能冲突或内容过大');
    if (err.status === 409) return '文件冲突，换个名字再试。';
    return '请求失败（HTTP ' + err.status + '）：' + (err.message || '');
  }

  /* ---------- GitHub API ---------- */

  function authHeaders(extra) {
    var headers = {
      'Authorization': 'Bearer ' + state.token,
      'X-GitHub-Api-Version': '2022-11-28'
    };
    if (extra) Object.keys(extra).forEach(function (k) { headers[k] = extra[k]; });
    return headers;
  }

  function readError(res) {
    return res.text().then(function (text) {
      var data = null;
      try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
      var err = new Error((data && data.message) || ('HTTP ' + res.status));
      err.status = res.status;
      err.data = data;
      return err;
    });
  }

  function gh(path, method, body) {
    var opts = {
      method: method || 'GET',
      headers: authHeaders({ 'Accept': 'application/vnd.github+json' }),
      cache: 'no-store'
    };
    if (body) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    return fetch(API + path, opts).then(function (res) {
      if (!res.ok) return readError(res).then(function (err) { throw err; });
      if (res.status === 204) return null;
      return res.text().then(function (text) { return text ? JSON.parse(text) : null; });
    }, function () {
      var err = new Error('network');
      err.network = true;
      throw err;
    });
  }

  function listFiles() {
    return gh('/repos/' + OWNER + '/' + REPO + '/contents/' + INBOX + '?ref=' + BRANCH)
      .then(function (data) {
        if (!Array.isArray(data)) return [];
        return data.filter(function (item) {
          return item.type === 'file' && item.name !== '.gitkeep';
        });
      })
      .catch(function (err) {
        if (err.status === 404) return [];
        throw err;
      });
  }

  function connect(auto) {
    var token = String(els.tokenInput.value || '').trim();
    if (!token) {
      setSetupError('请先填写令牌。');
      return;
    }
    state.token = token;
    els.connectBtn.disabled = true;
    setSetupError('');
    gh('/repos/' + OWNER + '/' + REPO).then(function () {
      return listFiles();
    }).then(function (files) {
      state.files = files;
      var device = normalizeDevice(els.deviceInput.value) || state.device || defaultDevice();
      state.device = device;
      els.deviceInput.value = device;
      els.devicePill.textContent = '本机标签：' + device;
      localStorage.setItem(LS_DEVICE, device);
      if (els.rememberInput.checked) {
        localStorage.setItem(LS_TOKEN, token);
        localStorage.setItem(LS_REMEMBER, '1');
      } else {
        localStorage.removeItem(LS_TOKEN);
        localStorage.setItem(LS_REMEMBER, '0');
      }
      state.connected = true;
      els.setupCard.hidden = true;
      els.mainPanel.hidden = false;
      renderFiles();
      toast('已连接：' + OWNER + '/' + REPO, 'ok');
    }).catch(function (err) {
      state.connected = false;
      els.setupCard.hidden = false;
      els.mainPanel.hidden = true;
      setSetupError(formatError(err));
      if (!auto) toast(formatError(err), 'err');
    }).then(function () {
      els.connectBtn.disabled = false;
    });
  }

  function refreshFiles(silent) {
    if (!state.connected) return;
    listFiles().then(function (files) {
      state.files = files;
      renderFiles();
      if (!silent) toast('已刷新', 'ok');
    }).catch(function (err) {
      toast(formatError(err), 'err');
    });
  }

  /* ---------- 文件列表 ---------- */

  function renderFiles() {
    var query = String(els.searchInput.value || '').trim().toLowerCase();
    var files = state.files.slice().sort(function (a, b) {
      return a.name < b.name ? 1 : (a.name > b.name ? -1 : 0);
    });
    if (query) {
      files = files.filter(function (f) {
        return f.name.toLowerCase().indexOf(query) !== -1;
      });
    }
    els.fileList.textContent = '';
    els.fileCount.textContent = query
      ? '(' + files.length + ' / ' + state.files.length + ')'
      : '(' + state.files.length + ')';

    var empty = els.emptyState;
    var emptyText = empty.querySelector('p');
    if (state.files.length === 0) {
      empty.hidden = false;
      emptyText.textContent = '还没有文件。';
    } else if (files.length === 0) {
      empty.hidden = false;
      emptyText.textContent = '没有匹配「' + query + '」的文件。';
    } else {
      empty.hidden = true;
    }

    files.forEach(function (f) {
      var li = document.createElement('li');
      li.className = 'file-row';

      var icon = document.createElement('span');
      icon.className = 'file-icon';
      icon.setAttribute('aria-hidden', 'true');
      icon.textContent = iconFor(f.name);

      var main = document.createElement('div');
      main.className = 'file-main';
      var title = document.createElement('span');
      title.className = 'file-title';
      title.textContent = prettyName(f.name);
      title.title = f.name;
      var meta = document.createElement('span');
      meta.className = 'file-meta';
      var stamp = prettyStamp(f.name);
      meta.textContent = (stamp ? stamp + ' · ' : '') + formatSize(f.size) + ' · ' + f.name;
      main.appendChild(title);
      main.appendChild(meta);

      var actions = document.createElement('div');
      actions.className = 'file-actions';
      var dl = document.createElement('button');
      dl.type = 'button';
      dl.className = 'btn ghost';
      dl.textContent = '下载';
      dl.addEventListener('click', function () { downloadFile(f); });
      var del = document.createElement('button');
      del.type = 'button';
      del.className = 'btn danger';
      del.textContent = '删除';
      del.addEventListener('click', function () { deleteFile(f); });
      actions.appendChild(dl);
      actions.appendChild(del);

      li.appendChild(icon);
      li.appendChild(main);
      li.appendChild(actions);
      els.fileList.appendChild(li);
    });
  }

  function downloadFile(f) {
    var url = API + '/repos/' + OWNER + '/' + REPO + '/contents/' + INBOX + '/' +
      encodeURIComponent(f.name) + '?ref=' + BRANCH;
    fetch(url, {
      headers: authHeaders({ 'Accept': 'application/vnd.github.raw' }),
      cache: 'no-store'
    }).then(function (res) {
      if (!res.ok) return readError(res).then(function (err) { throw err; });
      return res.blob();
    }).then(function (blob) {
      var objectUrl = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = objectUrl;
      a.download = prettyName(f.name);
      a.rel = 'noopener';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(objectUrl); }, 60000);
      toast('已开始下载：' + prettyName(f.name), 'ok');
    }).catch(function (err) {
      toast(formatError(err), 'err');
    });
  }

  function deleteFile(f) {
    if (!window.confirm('从仓库删除这个文件？\n\ninbox/' + f.name + '\n\n（历史里仍保留旧版本，网页不再显示它）')) return;
    gh('/repos/' + OWNER + '/' + REPO + '/contents/' + INBOX + '/' + encodeURIComponent(f.name), 'DELETE', {
      message: 'web delete: ' + f.name,
      sha: f.sha,
      branch: BRANCH
    }).then(function () {
      toast('已删除：' + prettyName(f.name), 'ok');
      return refreshFiles(true);
    }).catch(function (err) {
      toast(formatError(err), 'err');
    });
  }

  /* ---------- 上传队列 ---------- */

  function addFiles(fileList) {
    if (!state.connected) {
      showSetup();
      toast('请先填写令牌并连接仓库。', 'warn');
      return;
    }
    if (!fileList || !fileList.length) return;
    Array.prototype.slice.call(fileList).forEach(function (file) {
      state.queue.push({
        id: ++state.seq,
        file: file,
        status: 'waiting',
        error: '',
        name: ''
      });
    });
    renderQueue();
    startUploads();
  }

  function nextWaiting() {
    for (var i = 0; i < state.queue.length; i++) {
      if (state.queue[i].status === 'waiting') return state.queue[i];
    }
    return null;
  }

  function startUploads() {
    if (state.uploading) return;
    state.uploading = true;
    (function step() {
      var item = nextWaiting();
      if (!item) {
        state.uploading = false;
        renderQueue();
        return;
      }
      uploadOne(item).then(step, step);
    })();
  }

  function uploadOne(item) {
    if (item.file.size > MAX_SIZE) {
      item.status = 'failed';
      item.error = '超过 50MB，请用电脑脚本或 Release 发送';
      renderQueue();
      toast('「' + item.file.name + '」超过 50MB，已跳过。', 'err');
      return Promise.resolve();
    }
    item.status = 'uploading';
    renderQueue();

    var base = baseName(item.file.name) || 'file';
    var prefix = stampPrefix() + state.device + '_';
    var contentPromise = fileToBase64(item.file);
    var attempt = 0;

    if (item.file.size > WARN_SIZE) {
      toast('「' + item.file.name + '」超过 25MB，上传可能较慢。', 'warn');
    }

    function tryPut(name) {
      return contentPromise.then(function (b64) {
        return gh('/repos/' + OWNER + '/' + REPO + '/contents/' + INBOX + '/' + encodeURIComponent(name), 'PUT', {
          message: 'web upload: ' + name,
          content: b64,
          branch: BRANCH
        });
      }).then(function () { return name; });
    }

    function retryLoop(current) {
      return tryPut(current).catch(function (err) {
        if (err && err.status === 422 && attempt < MAX_RETRY) {
          attempt++;
          return retryLoop(suffixName(prefix + base, attempt));
        }
        throw err;
      });
    }

    return retryLoop(prefix + base).then(function (finalName) {
      item.name = finalName;
      item.status = 'done';
      renderQueue();
      toast('已上传：' + prettyName(finalName), 'ok');
      return refreshFiles(true);
    }).catch(function (err) {
      item.status = 'failed';
      item.error = formatError(err);
      renderQueue();
      toast('上传失败：' + formatError(err), 'err');
    });
  }

  function suffixName(name, n) {
    var dot = name.lastIndexOf('.');
    if (dot <= 0) return name + '-' + n;
    return name.slice(0, dot) + '-' + n + name.slice(dot);
  }

  function fileToBase64(file) {
    return new Promise(function (resolve, reject) {
      var reader = new FileReader();
      reader.onload = function () {
        var result = String(reader.result || '');
        var comma = result.indexOf(',');
        resolve(comma >= 0 ? result.slice(comma + 1) : result);
      };
      reader.onerror = function () { reject(new Error('读取文件失败')); };
      reader.readAsDataURL(file);
    });
  }

  function renderQueue() {
    els.queueCard.hidden = state.queue.length === 0;
    els.queueList.textContent = '';
    state.queue.forEach(function (item) {
      var li = document.createElement('li');
      li.className = 'queue-item ' + item.status;

      var head = document.createElement('div');
      head.className = 'q-head';
      var name = document.createElement('span');
      name.className = 'q-name';
      name.textContent = prettyName(item.name || item.file.name);
      name.title = item.file.name;
      var size = document.createElement('span');
      size.className = 'q-size';
      size.textContent = formatSize(item.file.size);
      head.appendChild(name);
      head.appendChild(size);

      var status = document.createElement('div');
      status.className = 'q-status';
      if (item.status === 'waiting') status.textContent = '等待上传…';
      else if (item.status === 'uploading') status.textContent = '上传中…';
      else if (item.status === 'done') status.textContent = '已上传：' + item.name;
      else status.textContent = item.error || '失败';

      li.appendChild(head);
      li.appendChild(status);
      if (item.status === 'uploading') {
        var bar = document.createElement('div');
        bar.className = 'progress';
        bar.appendChild(document.createElement('i'));
        li.appendChild(bar);
      }
      els.queueList.appendChild(li);
    });
  }

  /* ---------- 连接状态 ---------- */

  function showSetup() {
    els.setupCard.hidden = false;
    els.mainPanel.hidden = true;
  }

  function clearToken() {
    localStorage.removeItem(LS_TOKEN);
    localStorage.setItem(LS_REMEMBER, '0');
    els.tokenInput.value = '';
    els.setupError.hidden = true;
    state.token = '';
    state.connected = false;
    state.files = [];
    showSetup();
    toast('已清除本机保存的令牌。', 'ok');
  }

  window.filebox = { repo: OWNER + '/' + REPO, version: '1.0.0' };
})();
