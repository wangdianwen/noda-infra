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
