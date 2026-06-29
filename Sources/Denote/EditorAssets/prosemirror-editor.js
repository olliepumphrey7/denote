import {baseKeymap, chainCommands, createParagraphNear, liftEmptyBlock, newlineInCode, setBlockType, splitBlock, toggleMark} from "prosemirror-commands";
import {history, redo, undo} from "prosemirror-history";
import {inputRules, smartQuotes, textblockTypeInputRule, wrappingInputRule} from "prosemirror-inputrules";
import {keymap} from "prosemirror-keymap";
import {DOMParser, DOMSerializer, Schema} from "prosemirror-model";
import {schema as basicSchema} from "prosemirror-schema-basic";
import {addListNodes, liftListItem, sinkListItem, splitListItem, wrapInList} from "prosemirror-schema-list";
import {EditorState, NodeSelection, Plugin} from "prosemirror-state";
import {addColumnAfter, addColumnBefore, addRowAfter, addRowBefore, CellSelection, columnResizing, deleteColumn, deleteRow, deleteTable, fixTables, goToNextCell, mergeCells, splitCell, tableEditing, tableNodes, toggleHeaderRow} from "prosemirror-tables";
import {EditorView} from "prosemirror-view";

const tableNodeSpec = tableNodes({
  tableGroup: "block",
  cellContent: "block+",
  cellAttributes: {
    style: {
      default: null,
      getFromDOM(dom) {
        return dom.getAttribute("style");
      },
      setDOMAttr(value, attrs) {
        if (value) attrs.style = value;
      }
    }
  }
});

const nodes = addListNodes(
  basicSchema.spec.nodes,
  "paragraph block*",
  "block"
).append(tableNodeSpec);

export const schema = new Schema({
  nodes,
  marks: basicSchema.spec.marks
});

export const headingTriggers = [
  {pattern: /^\\\s$/, level: 1},
  {pattern: /^\\\\\s$/, level: 2},
  {pattern: /^\\\\\\\s$/, level: 3}
];

let view;
let suppressChange = false;
let rememberedViewportAnchor = null;
let viewportAnchorFrame = 0;
let viewportRestoreFrame = 0;

function post(name, payload = {}) {
  window.webkit.messageHandlers[name].postMessage(payload);
}

export function serializeHTML(doc) {
  const fragment = DOMSerializer.fromSchema(schema).serializeFragment(doc.content);
  const container = document.createElement("div");
  container.appendChild(fragment);
  return container.innerHTML;
}

export function plainText(doc) {
  return doc.textBetween(0, doc.content.size, "\n\n", "\n");
}

function notifyChange() {
  if (suppressChange || !view) return;
  post("editorChanged", {
    modelJSON: JSON.stringify(view.state.doc.toJSON()),
    html: serializeHTML(view.state.doc),
    plainText: plainText(view.state.doc)
  });
}

export function captureViewportAnchor() {
  if (!view) return null;
  const targetY = Math.max(0, Math.min(window.innerHeight - 1, window.innerHeight / 2));
  const targetX = Math.max(0, Math.min(window.innerWidth - 1, window.innerWidth / 2));
  const position = view.posAtCoords({left: targetX, top: targetY}) || {pos: view.state.selection.head};

  try {
    const coords = view.coordsAtPos(position.pos);
    return {
      pos: position.pos,
      targetY,
      topOffset: coords.top - targetY
    };
  } catch {
    return {
      pos: view.state.selection.head,
      targetY,
      topOffset: 0
    };
  }
}

function rememberViewportAnchor() {
  rememberedViewportAnchor = captureViewportAnchor() || rememberedViewportAnchor;
  return rememberedViewportAnchor;
}

function scheduleViewportAnchorCapture() {
  if (viewportAnchorFrame) cancelAnimationFrame(viewportAnchorFrame);
  viewportAnchorFrame = requestAnimationFrame(() => {
    viewportAnchorFrame = 0;
    rememberViewportAnchor();
  });
}

export function restoreViewportAnchor(anchor = rememberedViewportAnchor) {
  if (!view || !anchor) return false;
  const pos = Math.max(0, Math.min(anchor.pos, view.state.doc.content.size));

  try {
    const coords = view.coordsAtPos(pos);
    window.scrollBy(0, coords.top - anchor.targetY - anchor.topOffset);
    rememberedViewportAnchor = {
      ...anchor,
      pos
    };
    return true;
  } catch {
    view.dispatch(view.state.tr.scrollIntoView());
    return false;
  }
}

function scheduleViewportAnchorRestore() {
  if (!rememberedViewportAnchor) return;
  if (viewportRestoreFrame) cancelAnimationFrame(viewportRestoreFrame);
  viewportRestoreFrame = requestAnimationFrame(() => {
    viewportRestoreFrame = 0;
    restoreViewportAnchor();
    setTimeout(() => restoreViewportAnchor(), 60);
  });
}

export function cleanIncomingHTML(html) {
  const template = document.createElement("template");
  template.innerHTML = html;
  template.content.querySelectorAll("script, style, meta, link, object, embed, iframe").forEach((node) => node.remove());
  template.content.querySelectorAll("*").forEach((node) => {
    [...node.attributes].forEach((attr) => {
      const name = attr.name.toLowerCase();
      if (name.startsWith("on")) node.removeAttribute(attr.name);
    });
  });
  return template.innerHTML;
}

export function documentFromHTML(html) {
  const container = document.createElement("div");
  container.innerHTML = cleanIncomingHTML(html || "<p></p>");
  return DOMParser.fromSchema(schema).parse(container);
}

export function documentFromModelJSON(modelJSON, fallbackHTML) {
  if (modelJSON) {
    try {
      return schema.nodeFromJSON(JSON.parse(modelJSON));
    } catch {
      return documentFromHTML(fallbackHTML);
    }
  }
  return documentFromHTML(fallbackHTML);
}

export function makeInputRules() {
  return inputRules({
    rules: [
      ...smartQuotes,
      wrappingInputRule(/^\s*([-+*])\s$/, schema.nodes.bullet_list),
      wrappingInputRule(/^(\d+)\.\s$/, schema.nodes.ordered_list, (match) => ({order: +match[1]}), (match, node) => node.childCount + node.attrs.order === +match[1]),
      ...headingTriggers.map((trigger) => textblockTypeInputRule(trigger.pattern, schema.nodes.heading, {level: trigger.level})),
      textblockTypeInputRule(/^>\s$/, schema.nodes.blockquote)
    ]
  });
}

export function deleteSelectedTable(state, dispatch) {
  const selection = state.selection;
  if (selection instanceof CellSelection || (selection instanceof NodeSelection && selection.node.type === schema.nodes.table)) {
    return deleteTable(state, dispatch);
  }
  return false;
}

function nodeIsEmptyTextblock(node) {
  return node.isTextblock && node.textContent.trim() === "";
}

function tableIsEmpty(table) {
  let empty = true;
  table.descendants((node) => {
    if (node.isText && node.text?.trim()) {
      empty = false;
      return false;
    }
    if (!node.isText && !["table_row", "table_cell", "table_header", "paragraph"].includes(node.type.name) && !nodeIsEmptyTextblock(node)) {
      empty = false;
      return false;
    }
    return true;
  });
  return empty;
}

export function normalizeDocumentTransaction(state) {
  let transaction = fixTables(state);
  let doc = transaction ? transaction.doc : state.doc;
  let changed = Boolean(transaction);

  for (let position = doc.content.size, index = doc.childCount - 1; index >= 0; index -= 1) {
    const child = doc.child(index);
    position -= child.nodeSize;
    if (child.type === schema.nodes.table && tableIsEmpty(child)) {
      if (!transaction) transaction = state.tr;
      transaction.delete(position, position + child.nodeSize);
      changed = true;
    }
  }

  if (changed && transaction) {
    doc = transaction.doc;
  }

  const lastChild = doc.lastChild;
  if (lastChild && lastChild.type === schema.nodes.table) {
    if (!transaction) transaction = state.tr;
    transaction.insert(doc.content.size, schema.nodes.paragraph.create());
    changed = true;
  }

  return changed ? transaction : null;
}

export function createEditorState(doc = documentFromHTML("<p></p>")) {
  return EditorState.create({
    schema,
    doc,
    plugins: makePlugins()
  });
}

export function makeKeymapBindings() {
  const listItem = schema.nodes.list_item;
  return {
    "Mod-b": toggleMark(schema.marks.strong),
    "Mod-i": toggleMark(schema.marks.em),
    "Mod-0": setBlockType(schema.nodes.paragraph),
    "Mod-1": setBlockType(schema.nodes.heading, {level: 1}),
    "Mod-2": setBlockType(schema.nodes.heading, {level: 2}),
    "Mod-3": setBlockType(schema.nodes.heading, {level: 3}),
    "Mod-z": undo,
    "Shift-Mod-z": redo,
    "Mod-y": redo,
    "Backspace": deleteSelectedTable,
    "Delete": deleteSelectedTable,
    "Enter": chainCommands(newlineInCode, splitListItem(listItem), createParagraphNear, liftEmptyBlock, splitBlock),
    "Tab": chainCommands(sinkListItem(listItem), goToNextCell(1)),
    "Shift-Tab": chainCommands(liftListItem(listItem), goToNextCell(-1)),
    "Mod-Shift-8": wrapInList(schema.nodes.bullet_list),
    "Mod-Shift-7": wrapInList(schema.nodes.ordered_list)
  };
}

export function makePlugins() {
  return [
    makeInputRules(),
    columnResizing(),
    tableEditing(),
    history(),
    keymap(makeKeymapBindings()),
    keymap(baseKeymap),
    new Plugin({
      appendTransaction(_, __, state) {
        return normalizeDocumentTransaction(state);
      },
      view() {
        return {
          update: notifyChange
        };
      },
      props: {
        handlePaste(editorView, event) {
          const html = event.clipboardData && event.clipboardData.getData("text/html");
          if (!html) return false;
          const doc = documentFromHTML(html);
          const slice = doc.slice(0, doc.content.size);
          const transaction = editorView.state.tr.replaceSelection(slice);
          editorView.dispatch(transaction.scrollIntoView());
          return true;
        }
      }
    })
  ];
}

function createEditor() {
  const host = document.getElementById("editor");
  view = new EditorView(host, {
    state: createEditorState(),
    dispatchTransaction(transaction) {
      rememberViewportAnchor();
      const nextState = view.state.apply(transaction);
      view.updateState(nextState);
      notifyChange();
      scheduleViewportAnchorCapture();
    }
  });
  rememberViewportAnchor();
}

if (globalThis.window) {
  window.editorSetDocument = (payload) => {
    const doc = documentFromModelJSON(payload.modelJSON, payload.html);
    suppressChange = true;
    view.updateState(createEditorState(doc));
    suppressChange = false;
    notifyChange();
    scheduleViewportAnchorCapture();
  };

  window.editorFocus = () => {
    if (view) view.focus();
  };

  window.editorCaptureViewportAnchor = () => {
    rememberViewportAnchor();
  };

  window.editorRestoreViewportAnchor = () => {
    restoreViewportAnchor();
  };

  window.editorInsertText = (payload) => {
    if (!view || !payload?.text) return;
    const text = String(payload.text);
    view.focus();
    view.dispatch(view.state.tr.insertText(text).scrollIntoView());
    notifyChange();
    scheduleViewportAnchorCapture();
  };

  window.editorPastePlainText = (payload) => {
    if (!view) return;
    const text = String(payload?.text || "");
    if (!text) return;
    view.focus();
    view.dispatch(view.state.tr.insertText(text).scrollIntoView());
    notifyChange();
    scheduleViewportAnchorCapture();
  };

  window.editorApplyNormalStyle = () => {
    if (!view) return;
    const {from, to} = view.state.selection;
    view.dispatch(view.state.tr.removeMark(from, to).setBlockType(from, to, schema.nodes.paragraph));
    notifyChange();
  };

  window.editorPaintFormat = () => {};

  window.editorTableCommand = (name) => {
    const commands = {
      addColumnBefore,
      addColumnAfter,
      deleteColumn,
      addRowBefore,
      addRowAfter,
      deleteRow,
      deleteTable,
      mergeCells,
      splitCell,
      toggleHeaderRow
    };
    const command = commands[name];
    if (command) command(view.state, view.dispatch, view);
  };

  window.addEventListener("scroll", scheduleViewportAnchorCapture, {passive: true});
  window.addEventListener("resize", scheduleViewportAnchorRestore);
}

if (globalThis.window?.webkit?.messageHandlers) {
  createEditor();
  post("editorReady");
}
