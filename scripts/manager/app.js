"use strict";
const output = document.querySelector("#result");
const chooser = document.querySelector("#workspace");
const buttons = [...document.querySelectorAll("button")];
const applied = document.querySelector("#workspace-status");
async function request(path, value) {
  const init = value === undefined ? {credentials:"same-origin"} : {
    method:"POST", headers:{"Content-Type":"application/json"},
    credentials:"same-origin", body:JSON.stringify(value)
  };
  const response = await fetch(path, init);
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || "Request failed");
  return payload;
}
async function refresh() {
  const state = await request("/api/state");
  const health = {RUNNING:"运行中", STOPPED:"已停止", UNKNOWN:"无法确认"};
  const workspace = {UNKNOWN:"无法确认（旧版 native 服务请重启一次）", STOPPED:"服务已停止", UNAVAILABLE:"无法读取运行状态", CUSTOM:"与当前工作区配置不匹配"};
  const verification = {YES:"是", NO:"否", UNKNOWN:"尚未验证"};
  applied.textContent = `AgentDock：${health[state.agentdock] || "无法确认"} ｜ Tunnel：${health[state.tunnel] || "无法确认"} ｜ 配置工作区：${state.default_workspace} ｜ 运行工作区：${workspace[state.running_workspace] || state.running_workspace} ｜ 已应用：${verification[state.config_applied] || "尚未验证"}`;
  chooser.replaceChildren();
  for (const w of state.workspaces) {
    const option = document.createElement("option");
    option.value = w.name;
    option.textContent = w.name + " (" + w.mode + ")";
    option.disabled = w.mode !== "rw";
    option.selected = w.name === state.default_workspace;
    chooser.append(option);
  }
}
async function run(task) {
  buttons.forEach(b => b.disabled = true);
  try { const result = await task(); output.textContent = JSON.stringify(result, null, 2); await refresh(); }
  catch (error) { output.textContent = "失败：" + error.message; }
  finally { buttons.forEach(b => b.disabled = false); }
}
document.querySelector("#actions").addEventListener("click", event => {
  const action = event.target.closest("button")?.dataset.action;
  if (action) run(() => request("/api/action", {action}));
});
document.querySelector("#save").addEventListener("click", () => run(() =>
  request("/api/workspace", {name:chooser.value})));
refresh().catch(error => { output.textContent = "无法读取配置：" + error.message; });
