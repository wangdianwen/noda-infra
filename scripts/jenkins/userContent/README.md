# userContent — Jenkins 前端补丁存档

线上实位：JS 在 `~/.jenkins/userContent/`，主题配置在 `~/.jenkins/org.codefirst.SimpleThemeDecorator.xml`。

- `fix-input-json.js`：input 审批表单兜底——submit 捕获阶段发现表单无 `json` 字段时补
  `{"parameter":[{name,value}]}`（上游 JENKINS-54629/#313；2.580.1 起原生 behaviour
  序列化已可用，本件防退化，真浏览器 Proceed/Abort 三连测通过 2026-10-06）。
- `org.codefirst.SimpleThemeDecorator.xml`：simple-theme-plugin 配置，经 jsUrl 把上面
  JS 注入所有页面（readResolve 自动迁移为 elements=[JsUrlThemeElement]）。

变更后部署：复制到上述实位 + `brew services restart jenkins-lts`（须无构建的空闲窗口）。
