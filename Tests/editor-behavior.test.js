import assert from "node:assert/strict";
import test from "node:test";
import {JSDOM} from "jsdom";
import {NodeSelection, TextSelection} from "prosemirror-state";
import {
  cleanIncomingHTML,
  createEditorState,
  deleteSelectedTable,
  documentFromHTML,
  headingTriggers,
  makeKeymapBindings,
  normalizeDocumentTransaction,
  plainText,
  schema,
  serializeHTML
} from "../Sources/EphemeralNotes/EditorAssets/prosemirror-editor.js";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
globalThis.window = dom.window;
globalThis.document = dom.window.document;
Object.defineProperty(globalThis, "navigator", {
  value: dom.window.navigator,
  configurable: true
});

function normalize(state) {
  const transaction = normalizeDocumentTransaction(state);
  return transaction ? state.apply(transaction) : state;
}

function firstTablePosition(doc) {
  let found = null;
  doc.descendants((node, position) => {
    if (node.type === schema.nodes.table && found === null) {
      found = position;
      return false;
    }
    return true;
  });
  return found;
}

test("pasted table keeps a following paragraph for continued writing", () => {
  const doc = documentFromHTML("<table><tr><td>One</td><td>Two</td></tr></table>");
  const state = normalize(createEditorState(doc));
  assert.equal(state.doc.childCount, 2);
  assert.equal(state.doc.child(0).type, schema.nodes.table);
  assert.equal(state.doc.child(1).type, schema.nodes.paragraph);
});

test("merged table cells survive parsing and serialization", () => {
  const doc = documentFromHTML("<table><tr><td colspan=\"2\">Merged</td></tr><tr><td>A</td><td>B</td></tr></table>");
  const html = serializeHTML(doc);
  assert.match(html, /colspan="2"/);
  assert.match(html, /Merged/);
});

test("fully emptied tables are removed rather than left as an empty box", () => {
  const doc = documentFromHTML("<p>Before</p><table><tr><td><p></p></td><td><p></p></td></tr></table><p>After</p>");
  const state = normalize(createEditorState(doc));
  assert.equal(firstTablePosition(state.doc), null);
  assert.match(plainText(state.doc), /Before/);
  assert.match(plainText(state.doc), /After/);
});

test("selected table can be deleted as a whole", () => {
  const doc = documentFromHTML("<p>Before</p><table><tr><td>One</td></tr></table><p>After</p>");
  const tablePosition = firstTablePosition(doc);
  let state = createEditorState(doc);
  state = state.apply(state.tr.setSelection(NodeSelection.create(state.doc, tablePosition)));
  let dispatched = null;
  assert.equal(deleteSelectedTable(state, (transaction) => { dispatched = transaction; }), true);
  state = state.apply(dispatched);
  assert.equal(firstTablePosition(state.doc), null);
  assert.match(plainText(state.doc), /Before/);
  assert.match(plainText(state.doc), /After/);
});

test("bullet and numbered list HTML parse into structured list nodes", () => {
  const doc = documentFromHTML("<ul><li>Alpha</li><li>Beta</li></ul><ol><li>One</li></ol>");
  assert.equal(doc.child(0).type, schema.nodes.bullet_list);
  assert.equal(doc.child(1).type, schema.nodes.ordered_list);
  assert.match(plainText(doc), /Alpha/);
  assert.match(plainText(doc), /One/);
});

test("unsafe pasted HTML is stripped before parsing", () => {
  const cleaned = cleanIncomingHTML("<p onclick=\"bad()\">Ok<script>alert(1)</script></p><iframe src=\"x\"></iframe>");
  assert.equal(cleaned, "<p>Ok</p>");
});

test("plain editing content serializes to HTML and plain text", () => {
  const doc = documentFromHTML("<h1>Title</h1><p>Hello <strong>there</strong></p>");
  assert.match(serializeHTML(doc), /<h1>Title<\/h1>/);
  assert.match(plainText(doc), /Title/);
  assert.match(plainText(doc), /Hello there/);
});

test("heading input triggers use backslash rather than hash", () => {
  assert.equal(headingTriggers[0].pattern.test("\\ "), true);
  assert.equal(headingTriggers[1].pattern.test("\\\\ "), true);
  assert.equal(headingTriggers[2].pattern.test("\\\\\\ "), true);
  assert.equal(headingTriggers[0].pattern.test("# "), false);
});

test("keyboard shortcuts apply bold and heading formatting", () => {
  let state = createEditorState(documentFromHTML("<p>Hello</p>"));
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, 1, 6)));
  let dispatched = null;
  assert.equal(makeKeymapBindings()["Mod-b"](state, (transaction) => { dispatched = transaction; }), true);
  state = state.apply(dispatched);
  assert.equal(state.doc.child(0).child(0).marks.some((mark) => mark.type === schema.marks.strong), true);

  dispatched = null;
  assert.equal(makeKeymapBindings()["Mod-1"](state, (transaction) => { dispatched = transaction; }), true);
  state = state.apply(dispatched);
  assert.equal(state.doc.child(0).type, schema.nodes.heading);
  assert.equal(state.doc.child(0).attrs.level, 1);
});
