"use strict";
const output = document.querySelector("#result");
const chooser = document.querySelector("#workspace");
const buttons = [...document.querySelectorAll("button")];
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
  try { output.textContent = JSON.stringify(await task(), null, 2); await refresh(); }
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
