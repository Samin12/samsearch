"use strict";

const ReactReconciler = require("react-reconciler");
const { resolveIcon, accessoryText } = require("./icons");
const { shortcutString, runAction } = require("./components");
const nav = require("./navigation");
const hostConfig = require("./host-config");

const Reconciler = ReactReconciler(hostConfig);

let nextViewId = 0;
const mounted = new Map();
let session = null;

function newSession(entry) {
  return {
    id: ++nextViewId, entry, container: null, root: null, scheduled: false,
    lastJson: "", currentView: null, searchText: "", selectedId: null,
    formValues: {}, dropdownFired: new WeakSet(), actions: new Map(),
    actionRoots: new Map(), actionIds: new WeakMap(), nextAction: 0, renderGeneration: 0, previousActions: new Map(), error: null,
  };
}

function scheduleRender() {
  if (!session || session.scheduled) return;
  const target = session;
  target.scheduled = true;
  setTimeout(() => {
    target.scheduled = false;
    if (session === target) flushRender();
  }, 16);
}

function childrenOf(node) {
  if (!node) return [];
  return (node.children || []).filter((c) => c && c.type !== "#text");
}

function findAll(node, type, out) {
  if (!node) return out;
  if (node.type === type) out.push(node);
  for (const child of node.children || []) findAll(child, type, out);
  return out;
}

function actionId(prefix, identity) {
  return session.id + ":" + prefix + ":" + encodeURIComponent(identity);
}

function collectActions(node, prefix) {
  const actions = [];
  if (!node) return actions;
  const walk = (n) => {
    if (!n || n.type === "#text") return;
    if (n.type === "Action") {
      const props = n.props || {};
      let identity = props.id || session.actionIds.get(n);
      if (!identity) { identity = "action-" + (++session.nextAction); session.actionIds.set(n, identity); }
      const id = actionId(prefix || "actions", identity);
      session.actions.set(id, props);
      actions.push({
        id,
        title: props.title || "Action",
        shortcut: shortcutString(props.shortcut),
      });
      return;
    }
    for (const child of n.children || []) walk(child);
  };
  walk(node);
  return actions;
}

function itemFrom(node, index) {
  const props = node.props || {};
  const id = props.id != null ? String(props.id) : "item-" + index + "-" + String(props.title || index);
  const actionsNode = (node.children || []).find((c) => c.type === "ActionPanel");
  const actions = actionsNode ? collectActions(actionsNode, "item-" + id) : actionsFromElement(props.actions, "item-" + id);
  const accessories = Array.isArray(props.accessories) ? props.accessories.map(accessoryText).filter(Boolean) : [];
  return {
    id,
    title: props.title != null ? String(props.title) : "",
    subtitle: props.subtitle != null ? String(props.subtitle) : "",
    icon: resolveIcon(props.icon || props.content),
    accessories,
    keywords: props.keywords || [],
    actions,
  };
}

function actionsFromElement(element, prefix) {
  if (!element || typeof element !== "object") return [];
  const key = prefix || "actions";
  let scratch = session.actionRoots.get(key);
  if (!scratch) {
    scratch = { root: null, onCommit() {} };
    const target = session;
    const onError = (error) => reportRenderError(error, target);
    scratch.fiber = Reconciler.createContainer(scratch, 0, null, false, null, "", onError, onError, onError);
    session.actionRoots.set(key, scratch);
  }
  scratch.generation = session.renderGeneration;
  Reconciler.updateContainerSync(element, scratch.fiber, null);
  Reconciler.flushSyncWork();
  return scratch.root ? collectActions(scratch.root, key) : [];
}

function serializeList(node, kind) {
  const props = node.props || {};
  const sections = [];
  const loose = [];
  let empty = null;
  for (const child of childrenOf(node)) {
    if (child.type === "List.Section" || child.type === "Grid.Section") {
      const items = [];
      let i = 0;
      for (const item of childrenOf(child)) {
        if (item.type === "List.Item" || item.type === "Grid.Item") {
          items.push(itemFrom(item, i));
          i += 1;
        }
      }
      sections.push({ title: (child.props && child.props.title) || "", items });
    } else if (child.type === "List.Item" || child.type === "Grid.Item") {
      loose.push(itemFrom(child, loose.length));
    } else if (child.type === "List.EmptyView" || child.type === "Grid.EmptyView") {
      empty = {
        title: (child.props && child.props.title) || "",
        description: (child.props && child.props.description) || "",
      };
    }
  }
  if (loose.length) sections.unshift({ title: "", items: loose });
  if (!sections.length) sections.push({ title: "", items: [] });
  const listActions = actionsFromElement(props.actions, "list");
  return {
    kind: kind === "Grid" ? "list" : "list",
    title: props.navigationTitle || props.title || "",
    placeholder: props.searchBarPlaceholder || "",
    loading: !!props.isLoading,
    sections,
    empty,
    selected: props.selectedItemId !== undefined ? props.selectedItemId : session.selectedId,
    searchText: props.searchText !== undefined ? String(props.searchText) : session.searchText,
    searchControlled: props.searchText !== undefined,
    actions: listActions,
    filtering: props.filtering !== false,
    hasSearchHandler: typeof props.onSearchTextChange === "function",
    _node: node,
  };
}

function metadataOf(node) {
  const labels = [];
  const walk = (n) => {
    if (!n) return;
    if (n.type === "Detail.Metadata.Label" || n.type === "Detail.Metadata.Link") {
      labels.push({
        label: (n.props && (n.props.title || n.props.label)) || "",
        text: (n.props && (n.props.text || n.props.title || n.props.target)) || "",
      });
    }
    for (const c of n.children || []) walk(c);
  };
  walk(node);
  return labels;
}

function serializeDetail(node) {
  const props = node.props || {};
  let metaNode = (node.children || []).find((c) => c.type === "Detail.Metadata");
  return {
    kind: "detail",
    title: props.navigationTitle || "",
    markdown: props.markdown != null ? String(props.markdown) : "",
    loading: !!props.isLoading,
    metadata: metaNode ? metadataOf(metaNode) : [],
    actions: actionsFromElement(props.actions, "detail"),
    _node: node,
  };
}

function fieldType(type) {
  if (type === "Form.TextArea") return "textarea";
  if (type === "Form.PasswordField") return "password";
  if (type === "Form.Checkbox") return "checkbox";
  if (type === "Form.Dropdown" || type === "Form.TagPicker") return "dropdown";
  if (type === "Form.DatePicker") return "date";
  if (type === "Form.Separator") return "separator";
  if (type === "Form.Description") return "description";
  return "text";
}

function serializeForm(node) {
  const props = node.props || {};
  const fields = [];
  const walk = (n) => {
    if (!n || n.type === "#text") return;
    const t = fieldType(n.type);
    if (n.type && n.type.startsWith("Form.") && n.type !== "Form") {
      const p = n.props || {};
      const id = p.id != null ? String(p.id) : "field-" + fields.length;
      const options = [];
      for (const c of childrenOf(n)) {
        if (c.type.endsWith(".Item")) {
          options.push({ value: String(c.props.value ?? ""), title: String(c.props.title ?? c.props.value ?? "") });
        }
      }
      const stored = Object.prototype.hasOwnProperty.call(session.formValues, id) ? session.formValues[id] : undefined;
      let value = p.value !== undefined ? p.value : stored !== undefined ? stored : p.defaultValue;
      if (value === undefined) value = t === "checkbox" ? false : t === "dropdown" && options.length ? options[0].value : "";
      session.formValues[id] = value;
      fields.push({
        id,
        type: t,
        controlled: p.value !== undefined,
        title: p.title || p.label || "",
        value,
        placeholder: p.placeholder || "",
        options,
      });
      return;
    }
    for (const c of n.children || []) walk(c);
  };
  for (const c of node.children || []) walk(c);
  return {
    kind: "form",
    title: props.navigationTitle || "",
    loading: !!props.isLoading,
    fields,
    actions: actionsFromElement(props.actions, "form"),
    _node: node,
  };
}

function serialize(node) {
  if (!node) return { kind: "list", title: "", placeholder: "", loading: false, sections: [{ title: "", items: [] }], empty: null, selected: null, actions: [] };
  if (node.type === "List" || node.type === "Grid") return serializeList(node, node.type);
  if (node.type === "Detail") return serializeDetail(node);
  if (node.type === "Form") return serializeForm(node);
  const nested = childrenOf(node);
  if (nested.length === 1) return serialize(nested[0]);
  const found = [];
  const scan = (n) => {
    if (!n) return;
    if (n.type === "List" || n.type === "Grid" || n.type === "Detail" || n.type === "Form") found.push(n);
    else for (const c of n.children || []) scan(c);
  };
  scan(node);
  if (found[0]) return serialize(found[0]);
  return {
    kind: "detail",
    title: "",
    markdown: node.type === "#text" ? node.text : "Unsupported view: " + (node.type || "unknown"),
    loading: false,
    metadata: [],
    actions: [],
  };
}

function applySearch(view) {
  if (view.kind !== "list") return strip(view);
  const node = view._node;
  const props = (node && node.props) || {};
  if (typeof props.onSearchTextChange === "function" || props.filtering === false) {
    return strip(view);
  }
  const q = (view.searchText || "").trim().toLowerCase();
  if (!q) return strip(view);
  const sections = view.sections.map((section) => ({
    title: section.title,
    items: section.items.filter((item) => {
      const hay = [item.title, item.subtitle, ...(item.keywords || []), ...(item.accessories || [])]
        .join(" ")
        .toLowerCase();
      return hay.includes(q) || fuzzy(hay, q);
    }),
  }));
  return strip({ ...view, sections });
}

function fuzzy(hay, q) {
  let i = 0;
  for (const ch of hay) {
    if (ch === q[i]) i += 1;
    if (i >= q.length) return true;
  }
  return false;
}

function strip(view) {
  const out = { ...view };
  delete out._node;
  delete out._actionsElement;
  delete out.filtering;
  delete out.hasSearchHandler;
  if (out.sections) {
    out.sections = out.sections.map((s) => ({
      title: s.title,
      items: s.items.map((item) => ({
        id: item.id,
        title: item.title,
        subtitle: item.subtitle || "",
        icon: item.icon || null,
        accessories: item.accessories || [],
        actions: item.actions || [],
      })),
    }));
  }
  return out;
}

function wireActions(view) {
  if (view.kind === "list" && session.selectedId) {
    for (const section of view.sections) {
      const item = section.items.find((it) => it.id === session.selectedId);
      if (item && item.actions && item.actions.length) view.actions = item.actions;
    }
  }
  return view;
}

function flushRender() {
  if (!session) return;
  session.previousActions = session.actions;
  session.actions = new Map();
  session.renderGeneration++;
  const hostNode = session.container && session.container.root;
  if (!hostNode && !session.error) return;
  let view = session.error ? {
    kind: "detail", title: "Error", markdown: "# Error\n\n" + session.error,
    actions: [], loading: false,
  } : applySearch(wireActions(serialize(hostNode)));
  if (!view.selected && view.kind === "list") {
    const first = view.sections.flatMap((s) => s.items)[0];
    view.selected = first ? first.id : null;
  }
  for (const [key, scratch] of session.actionRoots) {
    if (scratch.generation !== session.renderGeneration) {
      Reconciler.updateContainerSync(null, scratch.fiber, null);
      session.actionRoots.delete(key);
    }
  }
  Reconciler.flushSyncWork();
  view.viewId = session.id;
  session.currentView = view;
  const json = JSON.stringify(view);
  if (json === session.lastJson) return;
  session.lastJson = json;
  require("./protocol").send({ type: "render", view });
  if (!session.error) initDropdown(hostNode);
}

function dispose(target) {
  Reconciler.updateContainerSync(null, target.root, null);
  for (const scratch of target.actionRoots.values()) {
    Reconciler.updateContainerSync(null, scratch.fiber, null);
  }
  Reconciler.flushSyncWork();
  target.actions.clear();
  target.actionRoots.clear();
}

function activate() {
  const entries = new Set(nav.stack);
  for (const [entry, target] of mounted) {
    if (!entries.has(entry)) { dispose(target); mounted.delete(entry); }
  }
  const entry = nav.topEntry();
  if (!entry) return;
  let target = mounted.get(entry);
  if (!target) {
    target = newSession(entry);
    mounted.set(entry, target);
    target.container = { root: null, onCommit: () => { if (session === target) scheduleRender(); } };
    target.root = Reconciler.createContainer(target.container, 1, null, false, null, "ss", (err) => reportRenderError(err, target), (err) => reportRenderError(err, target), (err) => reportRenderError(err, target));
    session = target;
    update(entry.element);
  } else {
    session = target;
    force();
  }
}

function mount(element) {
  if (!nav.topEntry()) nav.reset(element);
  nav.setNavigator(activate);
  activate();
}

function update(element) {
  Reconciler.updateContainer(element, session.root, null);
}

function reportRenderError(error, target = session) {
  const { log, send } = require("./protocol");
  log("render error", error && error.stack ? error.stack : error);
  target.error = error && error.message ? error.message : String(error);
  target.actions.clear();
  send({ type: "error", message: target.error });
  if (target === session) scheduleRender();
}

function force() {
  session.lastJson = "";
  flushRender();
}

function setSearch(text) {
  session.searchText = text == null ? "" : String(text);
  session.selectedId = null;
  const node = session.container && session.container.root;
  const props = findSearchProps(node);
  if (props && typeof props.onSearchTextChange === "function") {
    props.onSearchTextChange(session.searchText);
  }
  session.lastJson = "";
  scheduleRender();
}

function findSearchProps(node) {
  if (!node) return null;
  if (node.type === "List" || node.type === "Grid") return node.props;
  for (const c of node.children || []) {
    const found = findSearchProps(c);
    if (found) return found;
  }
  return null;
}

function setSelected(id) {
  session.selectedId = id;
  const node = session.container && session.container.root;
  const props = findSearchProps(node);
  if (props && typeof props.onSelectionChange === "function") {
    props.onSelectionChange(id);
  }
  session.lastJson = "";
  scheduleRender();
}

function setField(id, value) {
  session.formValues[id] = value;
  const node = session.container && session.container.root;
  const field = findField(node, id);
  if (field && field.props) {
    if (typeof field.props.onChange === "function") field.props.onChange(value);
  }
  session.lastJson = "";
  scheduleRender();
}

function findField(node, id) {
  if (!node) return null;
  if (node.props && node.props.id === id) return node;
  for (const c of node.children || []) {
    const found = findField(c, id);
    if (found) return found;
  }
  return null;
}

function runActionById(id) {
  if (session.error) return;
  const props = session.actions.get(id) || session.previousActions.get(id);
  if (!props) return;
  if (props.__action === "Action.SubmitForm") {
    const node = session.container && session.container.root;
    const form = findForm(node);
    const values = { ...session.formValues };
    if (form && form.props && typeof form.props.onSubmit === "function") {
      Promise.resolve(form.props.onSubmit(values)).catch((err) => {
        const { send } = require("./protocol");
        send({ type: "error", message: err && err.message ? err.message : String(err) });
      });
    } else if (typeof props.onSubmit === "function") {
      props.onSubmit(values);
    }
    return;
  }
  runAction(props);
  session.lastJson = "";
  scheduleRender();
}

function findForm(node) {
  if (!node) return null;
  if (node.type === "Form") return node;
  for (const c of node.children || []) {
    const found = findForm(c);
    if (found) return found;
  }
  return null;
}

function initDropdown(node) {
  if (!node || session.dropdownFired.has(node)) return;
  if (node.type === "List.Dropdown" || node.type === "Grid.Dropdown") {
    session.dropdownFired.add(node);
    const props = node.props || {};
    const value = props.value !== undefined ? props.value : props.defaultValue;
    if (value !== undefined && typeof props.onChange === "function") {
      queueMicrotask(() => {
        try { props.onChange(value); } catch (err) { reportRenderError(err); }
      });
    }
  }
  for (const c of node.children || []) initDropdown(c);
}

module.exports = {
  mount,
  update,
  force,
  setSearch,
  setSelected,
  setField,
  runActionById,
  scheduleRender,
  initDropdown,
  getView: () => session && session.currentView,
  getViewId: () => session && session.id,
  getRoot: () => (session && session.container ? session.container.root : null),
};
