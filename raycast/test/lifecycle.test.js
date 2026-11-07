"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const host = path.join(__dirname, "../dist/host.js");

function command(t, source, mode = "view") {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "samsearch-host-test-"));
  fs.mkdirSync(path.join(dir, "commands"));
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ name: "fixture", commands: [{ name: "test", mode }] }));
  fs.writeFileSync(path.join(dir, "commands/test.js"), 'const React = require("react"); const {List, Detail, Form, ActionPanel, Action, showToast, showHUD, Clipboard, popToRoot} = require("@raycast/api"); const h = React.createElement;\n' + source);
  const child = spawn(process.execPath, [host, "run", dir, "test"]);
  const lines = [];
  let buffer = "", stderr = "", cursor = 0;
  const closed = new Promise((resolve) => child.once("close", resolve));
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
      if (line) lines.push(JSON.parse(line));
    }
  });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  t.after(async () => { child.kill(); await closed; fs.rmSync(dir, { recursive: true, force: true }); });
  return {
    child, lines, closed,
    send(message) { child.stdin.write(JSON.stringify(message) + "\n"); },
    async wait(predicate) {
      const until = Date.now() + 4000;
      while (Date.now() < until) {
        for (; cursor < lines.length; cursor++) {
          if (predicate(lines[cursor])) return lines[cursor++];
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      throw new Error("Missing protocol message: " + JSON.stringify(lines) + " stderr=" + stderr);
    },
  };
}
const render = (s, predicate = () => true) => s.wait((m) => m.type === "render" && predicate(m.view));
const actions = (v) => v.kind === "list" ? v.sections.flatMap((s) => s.items).flatMap((i) => i.actions) : v.actions;

test("navigation retains mounted parent, search and selection; new dropdown mounts fire", async (t) => {
  const s = command(t, `let mounts = 0; function Child() {
    const [fired, setFired] = React.useState(0);
    return h(List, {navigationTitle: "Child " + fired, searchBarAccessory: h(List.Dropdown, {defaultValue:"a", onChange: () => setFired(n => n+1)})});
  }
  module.exports = function Parent() {
    const [id] = React.useState(() => ++mounts);
    return h(List, {navigationTitle:"Parent " + id}, h(List.Item, {id:"one", title:"One"}), h(List.Item, {id:"two", title:"Two", actions:h(ActionPanel, null, h(Action.Push, {title:"Child", target:h(Child)}))}));
  };`);
  const first = (await render(s)).view;
  s.send({ type: "search", text: "Two" });
  const filtered = (await render(s, (v) => v.sections[0].items.length === 1)).view;
  s.send({ type: "select", id: "two" });
  const selected = (await render(s, (v) => v.selected === "two")).view;
  for (let n = 0; n < 2; n++) {
    s.send({ type: "action", id: actions(selected)[0].id });
    const child = (await render(s, (v) => v.title === "Child 1")).view;
    assert.notEqual(child.viewId, first.viewId);
    s.send({ type: "pop" });
    const back = (await render(s, (v) => v.title === "Parent 1")).view;
    assert.equal(back.viewId, first.viewId);
    assert.equal(back.searchText, "Two");
    assert.equal(back.selected, "two");
    assert.equal(back.sections[0].items.length, filtered.sections[0].items.length);
  }
});

test("form submits untouched defaults and later controlled values override typing", async (t) => {
  const s = command(t, `module.exports = function Demo() {
    const [value, setValue] = React.useState("initial");
    return h(Form, {actions:h(ActionPanel, null,
      h(Action.SubmitForm, {title:"Submit", onSubmit: values => showToast({title:JSON.stringify(values)})}),
      h(Action, {title:"Set controlled", onAction:() => setValue("server")}) )},
      h(Form.TextField, {id:"default", defaultValue:"untouched"}),
      h(Form.Checkbox, {id:"check", defaultValue:true}),
      h(Form.Dropdown, {id:"option"}, h(Form.Dropdown.Item, {value:"first", title:"First"})),
      h(Form.TextField, {id:"controlled", value}));
  };`);
  const first = (await render(s)).view;
  s.send({type:"field", id:"controlled", value:"typed"});
  s.send({type:"action", id:first.actions[1].id});
  await render(s, v => v.fields.find(f => f.id === "controlled").value === "server");
  s.send({type:"action", id:first.actions[0].id});
  const submitted = await s.wait(m => m.type === "toast");
  assert.deepEqual(JSON.parse(submitted.title), {default:"untouched", check:true, option:"first", controlled:"server"});
});

test("streaming actions keep semantic ids after an earlier action is inserted", async (t) => {
  const s = command(t, `module.exports = function Demo() {
    const [more,setMore] = React.useState(false);
    return h(Detail, {markdown:"Stream", actions:h(ActionPanel, null,
      more && h(Action, {title:"Inserted", key:"inserted"}),
      h(Action, {title:"Update", key:"update", onAction:()=>setMore(true)}),
      h(Action.CopyToClipboard, {title:"Copy", key:"copy", content:"done"}))});
  };`);
  const first = (await render(s)).view;
  const copy = first.actions.find(a => a.title === "Copy");
  s.send({type:"action", id:first.actions[0].id});
  const next = (await render(s, v => v.actions.length === 3)).view;
  assert.equal(next.actions.find(a => a.title === "Copy").id, copy.id);
  s.send({type:"action", id:copy.id});
  assert.equal((await s.wait(m => m.type === "copy")).text, "done");
});

test("render exception replaces the dead action surface with an error view", async (t) => {
  const s = command(t, `module.exports = function Demo() {
    const [bad,setBad] = React.useState(false); if(bad) throw new Error("render exploded");
    return h(Detail, {markdown:"Ready", actions:h(ActionPanel,null,h(Action,{title:"Crash",onAction:()=>setBad(true)}))});
  };`);
  const first = (await render(s)).view;
  s.send({type:"action",id:first.actions[0].id});
  const error = (await render(s, v => v.title === "Error")).view;
  assert.match(error.markdown, /render exploded/);
  assert.deepEqual(error.actions, []);
});

test("controlled search text reaches the wire and filters with the controlled value", async (t) => {
  const s = command(t, `module.exports = () => h(List,{searchText:"Beta"},h(List.Item,{id:"a",title:"Alpha"}),h(List.Item,{id:"b",title:"Beta"}));`);
  const view = (await render(s)).view;
  assert.equal(view.searchText, "Beta");
  assert.equal(view.sections[0].items.length, 1);
  s.send({type:"search",text:"Alpha"});
  assert.equal((await render(s)).view.searchText,"Beta");
});

test("no-view commands read replies, emit toast setters and hide, and finish after popToRoot", async (t) => {
  const s = command(t, `module.exports = async () => {
    const text = await Clipboard.readText(); const toast = await showToast({title:text});
    toast.title="updated"; toast.message="message"; toast.style="failure"; await toast.hide();
    await popToRoot(); await showToast({title:"after root"});
  };`, "no-view");
  const request = await s.wait(m => m.type === "request");
  s.send({type:"reply",id:request.id,result:"x".repeat(100000)});
  const initial = await s.wait(m => m.type === "toast");
  assert.equal(initial.title.length,100000);
  const update = await s.wait(m => m.type === "toast" && m.style === "failure");
  assert.equal(update.title,"updated"); assert.equal(update.message,"message");
  assert.equal((await s.wait(m => m.type === "toast_hide")).id, initial.id);
  await s.wait(m => m.type === "pop_to_root");
  assert.equal((await s.wait(m => m.type === "toast")).title,"after root");
  await s.wait(m => m.type === "exit");
});

test("load and asynchronous crash errors are reported before exit", async (t) => {
  const load = command(t, 'throw new Error("load exploded");',"no-view");
  assert.match((await load.wait(m => m.type === "error")).message,/load exploded/);
  assert.match((await render(load, v=>v.title === "Error")).view.markdown,/load exploded/);
  const crash = command(t, 'module.exports = () => { setTimeout(() => { throw new Error("async exploded"); },20); return h(Detail,{markdown:"Ready"}); };');
  assert.match((await crash.wait(m=>m.type === "error")).message,/async exploded/);
  await crash.wait(m=>m.type === "exit");
});

test("request timeout and host stop reject pending promises", async () => {
  const child = spawn(process.execPath,["-e", `const p=require(${JSON.stringify(path.join(__dirname,"../src/protocol"))});
    (async()=>{try{await p.request("timeout",{},20)}catch(e){console.error(e.message)}
    const waiting=p.request("pending"); p.stop(); try{await waiting}catch(e){console.error(e.message)} process.exit(0)})();`]);
  let stderr=""; child.stderr.on("data",c=>{stderr+=c});
  await new Promise(resolve=>child.on("close",resolve));
  assert.match(stderr,/timed out: timeout/); assert.match(stderr,/host stopped/);
});

test("storage retains types, atomic write failure keeps old bytes, and replacement preserves legacy data", async (t) => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),"samsearch-storage-test-"));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const extension=path.join(dir,"demo"); fs.mkdirSync(extension);
  fs.writeFileSync(path.join(extension,"package.json"),JSON.stringify({name:"demo",commands:[]}));
  fs.writeFileSync(path.join(extension,"preferences.json"),JSON.stringify({answer:42}));
  const env=require("../src/environment"); env.init(extension,"test");
  const {LocalStorage, Cache, atomicWrite}=require("../src/storage");
  await LocalStorage.setItem("number",42); await LocalStorage.setItem("bool",false); await LocalStorage.setItem("string","42");
  assert.deepEqual(await LocalStorage.allItems(),{number:42,bool:false,string:"42"});
  const cache=new Cache(); cache.set("key","cached");
  const file=path.join(dir,"atomic.json"); atomicWrite(file,{old:true});
  const original=fs.renameSync;
  fs.renameSync=()=>{throw new Error("rename failed")};
  try{assert.throws(()=>atomicWrite(file,{new:true}),/rename failed/)}finally{fs.renameSync=original}
  assert.deepEqual(JSON.parse(fs.readFileSync(file)),{old:true});
  assert.equal(fs.readdirSync(dir).some(n=>n.includes(".tmp-")),false);
  const built=path.join(dir,"built"); fs.mkdirSync(built); fs.copyFileSync(path.join(extension,"package.json"),path.join(built,"package.json"));
  require("../src/install").replaceBundle(built,extension);
  env.init(extension,"test");
  assert.deepEqual(await LocalStorage.allItems(),{number:42,bool:false,string:"42"});
  assert.equal(cache.get("key"),"cached"); assert.equal(env.state.preferences.answer,42);
});

test("a second install is blocked and cancellation removes staging and npm process groups", async (t) => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),"samsearch-install-test-"));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const src=path.join(__dirname,"../src");
  const child=spawn(process.execPath,["-e", `
    const fs=require("fs"),path=require("path"),cp=require("child_process");
    const originalSpawn=cp.spawn;
    cp.spawn=(_cmd,_args,options)=>{
      const child=originalSpawn(process.execPath,["-e","setInterval(()=>{},1000)"],options);
      console.log(JSON.stringify({pid:child.pid})); return child;
    };
    const github=${JSON.stringify(path.join(src,"github.js"))};
    require.cache[github]={id:github,filename:github,loaded:true,exports:{parseRef:()=>({name:"fixture"}),downloadExtension:async(_name,tmp)=>{
      fs.mkdirSync(tmp,{recursive:true}); fs.writeFileSync(path.join(tmp,"package.json"),JSON.stringify({name:"fixture",dependencies:{fake:"1"},commands:[{name:"test"}]}));
    }}};
    const install=require(${JSON.stringify(path.join(src,"install.js"))});
    install.installExtension("fixture",${JSON.stringify(dir)}).catch(()=>{});
    install.installExtension("second",${JSON.stringify(dir)}).catch(e=>console.log(JSON.stringify({error:e.message})));
  `]);
  const closed=new Promise(resolve=>child.on("close",resolve));
  let text="", stderr=""; child.stdout.on("data",c=>{text+=c}); child.stderr.on("data",c=>{stderr+=c});
  t.after(async()=>{child.kill();await closed});
  for(let n=0;n<400&&!text.includes('"pid"');n++) await new Promise(resolve=>setTimeout(resolve,5));
  assert.match(text,/already running/);
  const pid=JSON.parse(text.split("\n").find(line=>line.includes('"pid"'))).pid;
  child.kill("SIGTERM"); await closed;
  assert.deepEqual(fs.readdirSync(dir),[]);
  for(let n=0;n<200;n++) {
    try { process.kill(pid,0); } catch(error) { if(error.code==="ESRCH") return; throw error; }
    await new Promise(resolve=>setTimeout(resolve,5));
  }
  assert.fail("npm child survived cancellation: "+pid+" stderr="+stderr);
});

test("an action component render error becomes an error view", async (t) => {
  const s=command(t,`function BadActions(){throw new Error("actions exploded")}
    module.exports=()=>h(Detail,{markdown:"Ready",actions:h(BadActions)});`);
  const view=(await render(s,v=>v.title==="Error")).view;
  assert.match(view.markdown,/actions exploded/);
  assert.deepEqual(view.actions,[]);
});
