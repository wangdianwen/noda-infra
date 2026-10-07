// fix-input-json.js — 修复经典 UI input 步骤审批表单（上游缺陷 JENKINS-54629 / pipeline-input-step #313）
// /input/<id>/submit 表单只提交 name/value/proceed，缺 Stapler getSubmittedForm() 必需的
// "json" 参数，Proceed/Abort 恒 400 "This page expects a form submission"。
// 本脚本在 submit 时把页面参数控件序列化成 {"parameter":[{name,value}]} 塞进隐藏 json 字段。
// 部署方式：经 simple-theme-plugin extraJs 注入（2026-10-06 探针实测 json POST 302 通过）。
(function () {
  'use strict';

  function valueOf(control) {
    if (control.type === 'checkbox') {
      return control.checked ? 'true' : 'false';
    }
    return control.value || '';
  }

  function findValueControl(nameInput, form, used) {
    // 从 name 隐藏域最近的容器往外找同名 value 控件，保证多参数时配对正确
    var el = nameInput.parentElement;
    for (var depth = 0; el && el !== form && depth < 6; depth++, el = el.parentElement) {
      var controls = el.querySelectorAll('select[name="value"], input[name="value"], textarea[name="value"]');
      for (var i = 0; i < controls.length; i++) {
        if (!used.has(controls[i])) return controls[i];
      }
    }
    return null;
  }

  function buildJson(form) {
    var used = new Set();
    var params = [];
    form.querySelectorAll('input[name="name"]').forEach(function (nameInput) {
      var control = findValueControl(nameInput, form, used);
      if (!control) return;
      used.add(control);
      params.push({ name: nameInput.value, value: valueOf(control) });
    });
    if (params.length === 0) return null;
    return JSON.stringify({ parameter: params });
  }

  document.addEventListener('submit', function (e) {
    var form = e.target;
    if (!form || form.tagName !== 'FORM') return;
    if (!/\/input\/[^/]+\/submit\/?$/.test(form.action || '')) return;
    if (form.elements['json']) return;
    try {
      var payload = buildJson(form);
      if (!payload) return;
      var hidden = document.createElement('input');
      hidden.type = 'hidden';
      hidden.name = 'json';
      hidden.value = payload;
      form.appendChild(hidden);
    } catch (err) {
      console.error('fix-input-json: failed to build json payload', err);
    }
  }, true);
})();

// ── 未登录横幅（2026-10-08）──────────────────────────────────────────────
// 事故背景：Jenkins 2.580.1 允许匿名只读，匿名会话下构建页无 Proceed 按钮、
// /input/ 页静默渲染成无表单空壳——用户点来点去毫无反应（"审批按钮没反应"
// 根因）。此横幅把"静默死路"变成显式提示：未登录即全程红条提醒，一键带
// 回跳登录。
(function () {
  'use strict';
  if (/^\/login/.test(location.pathname)) return;
  if (document.getElementById('noda-auth-banner')) return;
  fetch('/whoAmI/api/json', { credentials: 'same-origin' })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) {
      if (!d || !/^anonymous$/i.test(d.name || '')) return;
      var bar = document.createElement('div');
      bar.id = 'noda-auth-banner';
      bar.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;'
        + 'background:#b3261e;color:#fff;padding:8px 16px;font-size:14px;'
        + 'font-family:system-ui,sans-serif;display:flex;gap:12px;align-items:center;'
        + 'justify-content:center;box-shadow:0 2px 6px rgba(0,0,0,.3);';
      var msg = document.createElement('span');
      msg.textContent = '⚠️ 当前未登录（只读模式）：发布 / 审批按钮不会出现或点击无效';
      var link = document.createElement('a');
      link.href = '/login?from=' + encodeURIComponent(location.pathname + location.search);
      link.textContent = '点此登录（登录后自动返回本页）';
      link.style.cssText = 'color:#fff;font-weight:700;text-decoration:underline;';
      bar.appendChild(msg);
      bar.appendChild(link);
      document.body.appendChild(bar);
    })
    .catch(function () { /* 探测失败保持静默，不影响页面 */ });
})();
