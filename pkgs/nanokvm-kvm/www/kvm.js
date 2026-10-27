// NanoKVM web client: draws the video the server sends over /ws and sends
// keyboard, pointer and ATX commands back (protocol in kvm.c).
"use strict";

const canvas = document.getElementById("screen");
const ctx = canvas.getContext("2d");
const overlay = document.getElementById("overlay");
const $ = (id) => document.getElementById(id);
let ws = null;
let status = {};

function send(s) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(s);
}

function resize(w, h) {
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
    fit();
  }
}

// Display size: the largest box of the picture's aspect inside <main> less
// a 10 px margin each side, larger or smaller than the picture, on every
// window or header change.
function fit() {
  const m = canvas.parentElement.getBoundingClientRect();
  const k = Math.max(0, Math.min((m.width - 20) / canvas.width, (m.height - 20) / canvas.height));
  canvas.style.width = `${Math.floor(canvas.width * k)}px`;
  canvas.style.height = `${Math.floor(canvas.height * k)}px`;
}
new ResizeObserver(fit).observe(canvas.parentElement);

// --- Video ---------------------------------------------------------------

// LZ4 block format decoder.
function lz4(src, dst) {
  let s = 0, d = 0;
  while (s < src.length) {
    const token = src[s++];
    let lit = token >> 4;
    if (lit === 15) for (let b = 255; b === 255; lit += b) b = src[s++];
    dst.set(src.subarray(s, s + lit), d);
    s += lit;
    d += lit;
    if (s >= src.length) break;
    const off = src[s] | (src[s + 1] << 8);
    s += 2;
    let len = token & 15;
    if (len === 15) for (let b = 255; b === 255; len += b) b = src[s++];
    len += 4;
    for (let i = 0; i < len; i++, d++) dst[d] = dst[d - off];
  }
  return d;
}

const clamp = (v) => (v < 0 ? 0 : v > 255 ? 255 : v);
const tileRaw = new Uint8Array(32 * 32 * 2);

// UYVY (BT.601 limited range) into RGBA.
function uyvyToRgba(src, img, w, h) {
  const out = img.data;
  for (let i = 0, o = 0, n = (w * h) / 2; i < n; i++) {
    const u = src[4 * i] - 128, y0 = 1.164 * (src[4 * i + 1] - 16);
    const v = src[4 * i + 2] - 128, y1 = 1.164 * (src[4 * i + 3] - 16);
    const r = 1.596 * v, g = -0.392 * u - 0.813 * v, b = 2.017 * u;
    out[o] = clamp(y0 + r); out[o + 1] = clamp(y0 + g); out[o + 2] = clamp(y0 + b); out[o + 3] = 255;
    out[o + 4] = clamp(y1 + r); out[o + 5] = clamp(y1 + g); out[o + 6] = clamp(y1 + b); out[o + 7] = 255;
    o += 8;
  }
}

const tileImages = new Map();
function tileImage(w, h) {
  const k = w * 64 + h;
  if (!tileImages.has(k)) tileImages.set(k, ctx.createImageData(w, h));
  return tileImages.get(k);
}

function drawTiles(buf) {
  const v = new DataView(buf);
  resize(v.getUint16(2, true), v.getUint16(4, true));
  const n = v.getUint16(6, true);
  const bytes = new Uint8Array(buf);
  let p = 8;
  for (let i = 0; i < n; i++) {
    const x = v.getUint16(p, true), y = v.getUint16(p + 2, true);
    const w = v.getUint16(p + 4, true), h = v.getUint16(p + 6, true);
    const size = v.getUint32(p + 8, true);
    p += 12;
    lz4(bytes.subarray(p, p + size), tileRaw);
    p += size;
    const img = tileImage(w, h);
    uyvyToRgba(tileRaw, img, w, h);
    ctx.putImageData(img, x, y);
  }
}

// Bands of rows (u8 2, u8 0, u16 w, u16 h, u16 y, JPEG): decoded and drawn
// in arrival order, since each covers only the rows that changed.
let jpegChain = Promise.resolve();
function drawJpeg(buf) {
  jpegChain = jpegChain.then(async () => {
    const v = new DataView(buf);
    const w = v.getUint16(2, true), h = v.getUint16(4, true), y = v.getUint16(6, true);
    const bmp = await createImageBitmap(new Blob([new Uint8Array(buf, 8)], { type: "image/jpeg" }));
    // mjpeg-half arrives at half size: keep the canvas at the source size.
    resize(status.width || w, status.height || h);
    const sx = canvas.width / w, sy = canvas.height / h;
    ctx.drawImage(bmp, 0, y * sy, bmp.width * sx, bmp.height * sy);
    bmp.close();
  }).catch(() => {});
}

let decoder = null, decoderCodec = "";
// avc1.PPCCLL from the SPS (NAL type 7).
function codecFromSps(au) {
  for (let i = 0; i + 4 < au.length; i++)
    if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 1 && (au[i + 3] & 0x1f) === 7) {
      const hex = (b) => b.toString(16).padStart(2, "0");
      return "avc1." + hex(au[i + 4]) + hex(au[i + 5]) + hex(au[i + 6]);
    }
  return null;
}

function drawH264(buf) {
  if (!("VideoDecoder" in window)) {
    overlay.textContent = "This browser has no WebCodecs (needs HTTPS or localhost): choose tiles or mjpeg";
    return;
  }
  const v = new DataView(buf);
  const key = v.getUint8(1) === 1;
  const au = new Uint8Array(buf, 6);
  if (key) {
    const codec = codecFromSps(au);
    if (codec && (!decoder || codec !== decoderCodec || decoder.state === "closed")) {
      if (decoder && decoder.state !== "closed") decoder.close();
      decoder = new VideoDecoder({
        output: (frame) => {
          resize(frame.displayWidth, frame.displayHeight);
          ctx.drawImage(frame, 0, 0);
          frame.close();
        },
        error: (e) => { overlay.textContent = "H.264: " + e.message; decoder = null; send("key"); },
      });
      decoder.configure({ codec, optimizeForLatency: true });
      decoderCodec = codec;
    }
  }
  if (!decoder || decoder.state !== "configured") return;
  if (decoder.decodeQueueSize > 4 && !key) return;
  decoder.decode(new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: performance.now() * 1000, data: au }));
}

// --- Status --------------------------------------------------------------

function onStatus(s) {
  const modeChanged = s.mode !== status.mode;
  status = s;
  const sel = $("mode");
  if (sel.options.length !== s.modes.length)
    sel.replaceChildren(...s.modes.map((m) => new Option(m, m)));
  sel.value = s.mode;
  $("stats").textContent = s.signal
    ? `${s.width}×${s.height} · ${s.fps.toFixed(1)} fps · ${(s.kbps / 1000).toFixed(1)} Mbit/s · ${s.encode_ms.toFixed(0)} ms/frame`
    : "";
  $("viewers").textContent = `${s.viewers} viewer${s.viewers === 1 ? "" : "s"}`;
  if (!note.until || performance.now() > note.until) overlay.textContent = s.signal ? "" : "No HDMI signal";
  $("usb").classList.toggle("on", s.usb === "configured");
  $("caps").classList.toggle("on", (s.leds & 2) !== 0);
  $("led").classList.toggle("on", s.power_led === 1);
  // ATX controls only for the lines marked wired (ATX… menu).
  const atx = s.atx || {};
  $("power").hidden = $("powerlong").hidden = !atx.power;
  $("reset").hidden = !atx.reset;
  $("led").hidden = !atx.led;
  for (const box of document.querySelectorAll("#atxpanel input"))
    if (document.activeElement !== box) box.checked = !!atx[box.dataset.line];
  if (modeChanged) send("key");
}

// --- Connection ----------------------------------------------------------

function connect() {
  ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
  ws.binaryType = "arraybuffer";
  ws.onopen = () => { overlay.textContent = ""; send("key"); };
  ws.onclose = () => { overlay.textContent = "Disconnected; reconnecting…"; setTimeout(connect, 1000); };
  ws.onmessage = (e) => {
    if (typeof e.data === "string") {
      const s = JSON.parse(e.data);
      if (s.t === "status") onStatus(s);
      return;
    }
    const type = new Uint8Array(e.data, 0, 1)[0];
    if (type === 1) drawTiles(e.data);
    else if (type === 2) drawJpeg(e.data);
    else if (type === 3) drawH264(e.data);
  };
}

$("mode").onchange = (e) => send("mode " + e.target.value);

// --- Keyboard ------------------------------------------------------------

// KeyboardEvent.code -> USB HID usage (keyboard page).
const usage = {};
"abcdefghijklmnopqrstuvwxyz".split("").forEach((c, i) => (usage["Key" + c.toUpperCase()] = 4 + i));
"1234567890".split("").forEach((c, i) => (usage["Digit" + c] = 30 + i));
Object.assign(usage, {
  Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46, BracketLeft: 47,
  BracketRight: 48, Backslash: 49, Semicolon: 51, Quote: 52, Backquote: 53, Comma: 54, Period: 55,
  Slash: 56, CapsLock: 57, PrintScreen: 70, ScrollLock: 71, Pause: 72, Insert: 73, Home: 74,
  PageUp: 75, Delete: 76, End: 77, PageDown: 78, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81,
  ArrowUp: 82, NumLock: 83, NumpadDivide: 84, NumpadMultiply: 85, NumpadSubtract: 86, NumpadAdd: 87,
  NumpadEnter: 88, NumpadDecimal: 99, IntlBackslash: 100, ContextMenu: 101, NumpadEqual: 103,
  IntlRo: 135, IntlYen: 137,
  ControlLeft: 0xe0, ShiftLeft: 0xe1, AltLeft: 0xe2, MetaLeft: 0xe3,
  ControlRight: 0xe4, ShiftRight: 0xe5, AltRight: 0xe6, MetaRight: 0xe7,
});
for (let i = 1; i <= 12; i++) usage["F" + i] = 57 + i;
for (let i = 13; i <= 24; i++) usage["F" + i] = 104 + i - 13;
for (let i = 1; i <= 9; i++) usage["Numpad" + i] = 88 + i;
usage.Numpad0 = 98;

// Caps Lock follows this computer's state: on any Caps Lock event and
// before any other key goes down, if the target's Caps Lock LED differs
// from ours, tap it. The key's own events are never forwarded as such
// (macOS browsers report one event per press), so the two cannot drift:
// pages opened with Caps Lock on, or toggled without focus, catch up.
let capsSentAt = 0;
function syncCaps(e) {
  const mine = e.getModifierState("CapsLock");
  const theirs = (status.leds & 2) !== 0;
  // The target's LED report lags a tap; don't tap twice meanwhile.
  if (mine === theirs || performance.now() - capsSentAt < 500) return;
  capsSentAt = performance.now();
  send(`k ${usage.CapsLock} 1`);
  send(`k ${usage.CapsLock} 0`);
}

const isMac = /Mac/.test(navigator.platform);
$("pastehint").textContent = isMac ? "⌘V pastes" : "Ctrl+V pastes";

function key(e, down) {
  // ⌘V (Ctrl+V elsewhere) pastes this computer's clipboard instead: let
  // the browser's paste reach the hidden box (pasteBox below).
  if (down && e.code === "KeyV" && (isMac ? e.metaKey : e.ctrlKey) && !e.altKey) {
    // The modifier is already down on the target. Tap F24 under it so
    // that releasing it does not open the Start menu, then release all.
    tap(usage.F24);
    send("r");
    pasteBox.focus();
    return;
  }
  const u = usage[e.code];
  if (u === undefined) return;
  e.preventDefault();
  if (e.code === "CapsLock") return syncCaps(e);
  if (down) syncCaps(e);
  send(`k ${u} ${down ? 1 : 0}`);
}
canvas.addEventListener("keydown", (e) => key(e, true));
canvas.addEventListener("keyup", (e) => key(e, false));
canvas.addEventListener("blur", () => send("r"));

function tap(...usages) {
  usages.forEach((u) => send(`k ${u} 1`));
  usages.slice().reverse().forEach((u) => send(`k ${u} 0`));
}
$("cad").onclick = () => { tap(0xe0, 0xe2, 76); canvas.focus(); };

// Text -> key taps on a US layout.
const shifted = '~!@#$%^&*()_+{}|:"<>?';
const unshifted = "`1234567890-=[]\\;',./";
function charKeys(c) {
  if (c >= "a" && c <= "z") return [false, 4 + c.charCodeAt(0) - 97];
  if (c >= "A" && c <= "Z") return [true, 4 + c.charCodeAt(0) - 65];
  if (c >= "1" && c <= "9") return [false, 30 + c.charCodeAt(0) - 49];
  if (c === "0") return [false, 39];
  if (c === " ") return [false, 44];
  if (c === "\n") return [false, 40];
  if (c === "\t") return [false, 43];
  const codes = [53, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 47, 48, 49, 51, 52, 54, 55, 56];
  let i = unshifted.indexOf(c);
  if (i >= 0) return [false, codes[i]];
  i = shifted.indexOf(c);
  if (i >= 0) return [true, codes[i]];
  return null;
}
// A short message over the picture, kept for 3 s.
function note(text) {
  overlay.textContent = text;
  note.until = performance.now() + 3000;
  clearTimeout(note.timer);
  note.timer = setTimeout(() => { overlay.textContent = status.signal ? "" : "No HDMI signal"; }, 3000);
}

// Types clipboard text into the target, never showing it (it is often a
// secret). Caps Lock on the target inverts letters: shift them the other way.
function typeText(text) {
  if (/[\0-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(text)) return note("The clipboard holds binary data; nothing typed");
  const caps = (status.leds & 2) !== 0;
  let typed = 0, skipped = 0;
  for (const c of text.replace(/\r\n?/g, "\n")) {
    const k = charKeys(c);
    if (!k) { skipped++; continue; }
    const letter = c.toLowerCase() !== c.toUpperCase();
    if (k[0] !== (caps && letter)) tap(0xe1, k[1]);
    else tap(k[1]);
    typed++;
  }
  note(skipped ? `Typed ${typed} characters; skipped ${skipped} a US keyboard cannot type` : `Typed ${typed} characters`);
}

// The paste lands here: a focused text box gets the clipboard on ⌘V with no
// browser prompt, where a button reading the clipboard gets one in Safari.
const pasteBox = document.createElement("textarea");
pasteBox.setAttribute("aria-hidden", "true");
pasteBox.tabIndex = -1;
pasteBox.style.cssText = "position:fixed;left:-9999px;top:0;width:1px;height:1px;opacity:0";
document.body.append(pasteBox);
pasteBox.addEventListener("paste", (e) => {
  e.preventDefault();
  const d = e.clipboardData;
  const text = d ? d.getData("text/plain") : "";
  canvas.focus();
  if (text) return typeText(text);
  note(d && d.types.length ? "The clipboard holds no text (an image or file?); nothing typed" : "The clipboard is empty");
});
// Not pasted (the browser refused): back to the picture.
pasteBox.addEventListener("blur", () => { pasteBox.value = ""; });
pasteBox.addEventListener("keyup", () => canvas.focus());

// --- Pointer -------------------------------------------------------------

let buttons = 0, pending = null, wheel = 0;
function pointer(e) {
  const r = canvas.getBoundingClientRect();
  const x = Math.round(((e.clientX - r.left) / r.width) * 32767);
  const y = Math.round(((e.clientY - r.top) / r.height) * 32767);
  pending = [x, y];
}
function flushPointer() {
  if (pending || wheel) {
    const [x, y] = pending || [lastX, lastY];
    lastX = x; lastY = y;
    send(`m ${x} ${y} ${buttons} ${wheel}`);
    pending = null;
    wheel = 0;
  }
  requestAnimationFrame(flushPointer);
}
let lastX = 0, lastY = 0;
requestAnimationFrame(flushPointer);
const buttonBit = [1, 4, 2, 8, 16]; // DOM left, middle, right, back, forward
canvas.addEventListener("mousemove", pointer);
canvas.addEventListener("mousedown", (e) => {
  canvas.focus();
  pointer(e);
  buttons |= buttonBit[e.button] || 0;
  pending = pending || [lastX, lastY];
  flushPointerNow();
  e.preventDefault();
});
canvas.addEventListener("mouseup", (e) => {
  pointer(e);
  buttons &= ~(buttonBit[e.button] || 0);
  flushPointerNow();
  e.preventDefault();
});
function flushPointerNow() {
  const [x, y] = pending || [lastX, lastY];
  lastX = x; lastY = y;
  send(`m ${x} ${y} ${buttons} 0`);
  pending = null;
}
canvas.addEventListener("contextmenu", (e) => e.preventDefault());
canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  wheel += e.deltaY > 0 ? -1 : e.deltaY < 0 ? 1 : 0;
}, { passive: false });

// --- ATX ------------------------------------------------------------------

// Press lengths as in Sipeed's UI: 800 ms short, 5 s to force off.
$("power").onclick = () => send("atx power 800");
$("powerlong").onclick = () => { if (confirm("Hold the target's power button for 5 seconds?")) send("atx power 5000"); };
$("reset").onclick = () => { if (confirm("Press the target's reset button?")) send("atx reset 800"); };
$("atx").onclick = () => {
  const p = $("atxpanel");
  p.hidden = !p.hidden;
  // Open toward the wider side: the header wraps, so the button can be anywhere.
  const left = $("atx").getBoundingClientRect().left < innerWidth / 2;
  p.style.left = left ? "0" : "auto";
  p.style.right = left ? "auto" : "0";
};
document.addEventListener("click", (e) => {
  if (!e.target.closest(".atx-menu")) $("atxpanel").hidden = true;
});
for (const box of document.querySelectorAll("#atxpanel input"))
  box.onchange = () => send(`atx-wired ${box.dataset.line} ${box.checked ? 1 : 0}`);

connect();
canvas.focus();
