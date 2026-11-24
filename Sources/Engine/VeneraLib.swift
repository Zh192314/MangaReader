import Foundation

/// Venera（venera-app/venera）JS 源兼容层。
///
/// Venera 用 flutter_qjs + Dart 桥：`sendMessage()` 返回 Promise，HTML 解析、编解码、
/// 网络全在 Dart 侧完成。本文件把这套 API 用纯 JS + 少量同步桥重新实现，
/// 让 `venera-configs` 仓库里的源脚本可以原样跑在 JavaScriptCore 上。
///
/// 与 Venera 的关键差异（有意为之）：
/// - `sendMessage()` 同步返回结果，不再返回 Promise。`await` 一个普通值时引擎会挂一帧
///   微任务，由 VeneraRuntime 的泵驱动完成，行为与原来一致。
/// - HTML 解析完全在 JS 内完成，不依赖宿主。
/// - 源的入口实例由 `__veneraActivate()` 自动发现（Venera 由 Dart 侧反射）。
enum VeneraLib {

    static let bootstrap: String = #"""
// ===== Venera JS 源兼容运行时 =====

var __vs = { done: false, value: null, error: null };

function __errText(e) {
  if (e == null) return 'unknown error';
  if (typeof e === 'string') return e;
  if (e && e.message) return String(e.message);
  try { return String(e); } catch (_) { return 'unknown error'; }
}

// 把 Map / Set / class 实例转成可 JSON 化的普通值
function __plain(v, depth) {
  depth = depth || 0;
  if (v === null || v === undefined) return null;
  if (depth > 10) return null;
  var t = typeof v;
  if (t === 'function') return null;
  if (t === 'string' || t === 'number' || t === 'boolean') return v;
  if (Object.prototype.toString.call(v) === '[object ArrayBuffer]') return null;
  if (Array.isArray(v)) {
    var arr = [];
    for (var i = 0; i < v.length; i++) arr.push(__plain(v[i], depth + 1));
    return arr;
  }
  if (typeof Map !== 'undefined' && v instanceof Map) {
    var mo = {};
    v.forEach(function (val, key) { mo[String(key)] = __plain(val, depth + 1); });
    return mo;
  }
  if (typeof Set !== 'undefined' && v instanceof Set) {
    var sa = [];
    v.forEach(function (x) { sa.push(__plain(x, depth + 1)); });
    return sa;
  }
  if (t === 'object') {
    var o = {};
    for (var k in v) {
      if (!Object.prototype.hasOwnProperty.call(v, k)) continue;
      var val2 = v[k];
      if (typeof val2 === 'function') continue;
      o[k] = __plain(val2, depth + 1);
    }
    return o;
  }
  return null;
}

// ===== 泵：Swift 侧同步驱动 async 源函数 =====

function __pumpBegin(path, argsJson) {
  __vs.done = false;
  __vs.value = null;
  __vs.error = null;
  var target;
  try {
    target = __resolvePath(path);
    if (!target || typeof target.fn !== 'function') {
      __vs.done = true;
      __vs.error = '源未实现 ' + path;
      return;
    }
  } catch (e) {
    __vs.done = true;
    __vs.error = __errText(e);
    return;
  }
  var args = [];
  try { args = JSON.parse(argsJson || '[]'); } catch (e) { args = []; }
  try {
    var p = target.fn.apply(target.self, args);
    Promise.resolve(p).then(function (v) {
      try { __vs.value = __plain(v, 0); } catch (e2) { __vs.value = null; }
      __vs.done = true;
    }, function (e) {
      __vs.error = __errText(e);
      __vs.done = true;
    });
  } catch (e) {
    __vs.done = true;
    __vs.error = __errText(e);
  }
}

function __vsDone() { return __vs.done === true; }

function __vsTake() {
  var payload = { ok: __vs.error == null, error: __vs.error, value: __vs.value };
  try { return JSON.stringify(payload); }
  catch (e) { return JSON.stringify({ ok: false, error: '结果无法序列化: ' + __errText(e), value: null }); }
}

function __resolvePath(path) {
  // 兼容层自己的辅助函数（__veneraSearch / __veneraLoadDetail ...）直接挂在全局
  if (path.indexOf('.') < 0 && path.indexOf('[') < 0) {
    var g = null;
    try { g = globalThis[path]; } catch (e) { g = null; }
    if (typeof g === 'function') return { fn: g, self: null };
  }
  var cur = __veneraSource;
  if (!cur) return null;
  var lastFn = null, lastSelf = null;
  var re = /([A-Za-z_$][\w$]*)|\[(\d+)\]/g, m;
  while ((m = re.exec(path))) {
    lastSelf = cur;
    var key = m[1] != null ? m[1] : Number(m[2]);
    if (cur == null) return null;
    lastFn = cur[key];
    cur = cur[key];
  }
  return { fn: lastFn, self: lastSelf };
}

// ===== sendMessage =====

function sendMessage(msg) {
  if (!msg) return null;
  var m = msg.method;
  if (m === 'http') return __doHttp(msg);
  if (m === 'convert') return __doConvert(msg);
  if (m === 'html') return __disposeOrNull(msg);
  if (m === 'load_data') {
    var rawData = __kvGet(String(msg.key || ''), String(msg.data_key || ''));
    if (rawData == null || rawData === '' || rawData === 'null') return null;
    try { return JSON.parse(rawData); } catch (e) { return rawData; }
  }
  if (m === 'save_data') { __kvSet(String(msg.key || ''), String(msg.data_key || ''), JSON.stringify(msg.data === undefined ? null : msg.data)); return null; }
  if (m === 'delete_data') { __kvDel(String(msg.key || ''), String(msg.data_key || '')); return null; }
  if (m === 'load_setting') return null;
  if (m === 'isLogged') return false;
  if (m === 'delay') return null;
  if (m === 'cookie') return null;
  return null;
}

function __disposeOrNull(msg) { return null; }

function __doHttp(o) {
  var headers = o.headers;
  if (!headers || typeof headers !== 'object') headers = {};
  var body = o.data;
  if (body == null) body = '';
  else if (typeof body === 'string') { /* keep */ }
  else if (Object.prototype.toString.call(body) === '[object ArrayBuffer]') body = __bytesToStr(body);
  else if (typeof body === 'object') body = JSON.stringify(body);
  else body = String(body);

  var referer = '';
  for (var k in headers) {
    if (String(k).toLowerCase() === 'referer') referer = String(headers[k]);
  }
  var raw = __httpFull(String(o.http_method || 'GET'), String(o.url || ''), body, JSON.stringify(headers), referer);
  var res = null;
  try { res = JSON.parse(String(raw || '')); } catch (e) { res = null; }
  if (!res) res = { error: '网络请求失败', status: 0, headers: {}, body: '' };
  if (res.error) return res;
  if (o.bytes) res.body = __strToBytes(res.body == null ? '' : String(res.body));
  return res;
}

function __doConvert(o) {
  var type = String(o.type || 'utf8');
  var encode = o.isEncode === true;
  var val = o.value;
  if (type === 'utf8') {
    if (encode) return __strToBytes(String(val == null ? '' : val));
    return __bytesToStr(val);
  }
  if (type === 'base64') {
    if (encode) return __b64(__bytesToLatin1(val));
    return __latin1ToBytes(__b64decode(String(val == null ? '' : val)));
  }
  if (type === 'gbk' || type === 'gb2312' || type === 'gb18030') {
    if (encode) return __latin1ToBytes(__gbkEnc(String(val == null ? '' : val)));
    return __gbkDec(__bytesToLatin1(val));
  }
  if (type === 'hex') {
    if (encode) return __hexOf(__bytesToLatin1(val));
  }
  if (type === 'md5' || type === 'sha1' || type === 'sha256' || type === 'sha512') {
    return __latin1ToBytes(__hexDecode(__hash(type, __bytesToLatin1(val))));
  }
  return encode ? __strToBytes('') : '';
}

// ===== 字节工具 =====

function __strToBytes(s) {
  var out = new Uint8Array(s.length * 3);
  var p = 0;
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c < 0x80) { out[p++] = c; }
    else if (c < 0x800) { out[p++] = 0xC0 | (c >> 6); out[p++] = 0x80 | (c & 0x3F); }
    else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      var c2 = s.charCodeAt(i + 1);
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        var cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
        i++;
        out[p++] = 0xF0 | (cp >> 18);
        out[p++] = 0x80 | ((cp >> 12) & 0x3F);
        out[p++] = 0x80 | ((cp >> 6) & 0x3F);
        out[p++] = 0x80 | (cp & 0x3F);
      } else {
        out[p++] = 0xE0 | (c >> 12); out[p++] = 0x80 | ((c >> 6) & 0x3F); out[p++] = 0x80 | (c & 0x3F);
      }
    } else {
      out[p++] = 0xE0 | (c >> 12); out[p++] = 0x80 | ((c >> 6) & 0x3F); out[p++] = 0x80 | (c & 0x3F);
    }
  }
  return out.buffer.slice(0, p);
}

function __bytesToStr(buf) {
  if (buf == null) return '';
  if (typeof buf === 'string') return buf;
  var u8 = new Uint8Array(buf);
  var out = '';
  var i = 0;
  while (i < u8.length) {
    var b = u8[i++];
    if (b < 0x80) { out += String.fromCharCode(b); }
    else if (b < 0xE0) { out += String.fromCharCode(((b & 0x1F) << 6) | (u8[i++] & 0x3F)); }
    else if (b < 0xF0) {
      out += String.fromCharCode(((b & 0x0F) << 12) | ((u8[i++] & 0x3F) << 6) | (u8[i++] & 0x3F));
    } else {
      var cp = ((b & 0x07) << 18) | ((u8[i++] & 0x3F) << 12) | ((u8[i++] & 0x3F) << 6) | (u8[i++] & 0x3F);
      cp -= 0x10000;
      out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
    }
  }
  return out;
}

function __bytesToLatin1(buf) {
  if (buf == null) return '';
  if (typeof buf === 'string') return buf;
  var u8 = new Uint8Array(buf);
  var out = '';
  for (var i = 0; i < u8.length; i++) out += String.fromCharCode(u8[i]);
  return out;
}

function __latin1ToBytes(s) {
  var u8 = new Uint8Array(s.length);
  for (var i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i) & 0xFF;
  return u8.buffer;
}

function __hexOf(s) {
  var out = '';
  for (var i = 0; i < s.length; i++) {
    var h = s.charCodeAt(i).toString(16);
    out += (h.length < 2 ? '0' + h : h);
  }
  return out;
}

function __hexDecode(hex) {
  hex = String(hex || '');
  var out = '';
  for (var i = 0; i + 1 < hex.length; i += 2) {
    out += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
  }
  return out;
}

// ===== Convert =====

var Convert = {
  encodeUtf8: function (s) { return __strToBytes(String(s == null ? '' : s)); },
  decodeUtf8: function (b) { return __bytesToStr(b); },
  encodeGbk: function (s) { return __latin1ToBytes(__gbkEnc(String(s == null ? '' : s))); },
  decodeGbk: function (b) { return __gbkDec(__bytesToLatin1(b)); },
  encodeBase64: function (b) { return __b64(__bytesToLatin1(b)); },
  decodeBase64: function (s) { return __latin1ToBytes(__b64decode(String(s == null ? '' : s))); },
  md5: function (b) { return __latin1ToBytes(__hexDecode(__hash('md5', __bytesToLatin1(b)))); },
  sha1: function (b) { return __latin1ToBytes(__hexDecode(__hash('sha1', __bytesToLatin1(b)))); },
  sha256: function (b) { return __latin1ToBytes(__hexDecode(__hash('sha256', __bytesToLatin1(b)))); },
  sha512: function (b) { return __latin1ToBytes(__hexDecode(__hash('sha512', __bytesToLatin1(b)))); },
  hmac: function () { return __strToBytes(''); },
  hmacString: function () { return ''; },
  hexEncode: function (b) { return __hexOf(__bytesToLatin1(b)); },
  decryptAesEcb: function () { return __strToBytes(''); },
  decryptAesCbc: function () { return __strToBytes(''); },
  decryptAesCfb: function () { return __strToBytes(''); },
  decryptAesOfb: function () { return __strToBytes(''); },
  decryptRsa: function () { return __strToBytes(''); }
};

// ===== Network =====

var Network = {
  async fetchBytes(method, url, headers, data, extra) {
    var r = __doHttp({ http_method: method, url: url, headers: headers, data: data, bytes: true });
    if (r.error) throw r.error;
    return r;
  },
  async sendRequest(method, url, headers, data, extra) {
    var r = __doHttp({ http_method: method, url: url, headers: headers, data: data, bytes: false });
    if (r.error) throw r.error;
    return r;
  },
  async get(url, headers, extra) { return this.sendRequest('GET', url, headers, null, extra); },
  async post(url, headers, data, extra) { return this.sendRequest('POST', url, headers, data, extra); },
  async put(url, headers, data, extra) { return this.sendRequest('PUT', url, headers, data, extra); },
  async patch(url, headers, data, extra) { return this.sendRequest('PATCH', url, headers, data, extra); },
  async delete(url, headers, extra) { return this.sendRequest('DELETE', url, headers, null, extra); },
  setCookies(url, cookies) { return null; },
  getCookies(url) { return []; },
  deleteCookies(url) { return null; }
};

async function fetch(url, options) {
  var method = 'GET', headers = {}, data = null;
  if (options) {
    method = options.method || method;
    headers = options.headers || headers;
    data = options.body === undefined ? null : options.body;
  }
  var result = await Network.fetchBytes(method, url, headers, data);
  return {
    ok: result.status >= 200 && result.status < 300,
    status: result.status,
    statusText: '',
    headers: result.headers || {},
    arrayBuffer: async function () { return result.body; },
    text: async function () { return Convert.decodeUtf8(result.body); },
    json: async function () {
      var body = Convert.decodeUtf8(result.body);
      try { return JSON.parse(body); }
      catch (e) {
        var ct = (result.headers && (result.headers['content-type'] || result.headers['Content-Type'])) || 'unknown';
        throw new SyntaxError('Invalid JSON response from ' + String(url).split(/[?#]/, 1)[0] +
          ' (HTTP ' + result.status + ', Content-Type ' + ct + '): ' + __errText(e));
      }
    }
  };
}

function Cookie(o) {
  o = o || {};
  this.name = o.name;
  this.value = o.value;
  this.domain = o.domain;
}

// ===== HTML DOM =====

var __nodes = {};
var __nodeSeq = 1;
var __docSeq = 1;
var __docs = {};

function __buildNode(raw, parent) {
  var tag = raw.t == null ? 'div' : String(raw.t);
  var node = {
    key: __nodeSeq++,
    tag: tag,
    attrs: raw.a || {},
    text: raw.x == null ? '' : String(raw.x),
    children: [],
    parent: parent,
    nodeType: tag === '#text' ? 3 : (tag === '#comment' ? 8 : 1)
  };
  __nodes[node.key] = node;
  if (raw.c && raw.c.length) {
    for (var i = 0; i < raw.c.length; i++) node.children.push(__buildNode(raw.c[i], node));
  }
  return node;
}

function __elementsOf(n) {
  var out = [];
  if (!n) return out;
  for (var i = 0; i < n.children.length; i++) {
    if (n.children[i].nodeType === 1) out.push(n.children[i]);
  }
  return out;
}

function __prevEl(n) {
  if (!n || !n.parent) return null;
  var sibs = __elementsOf(n.parent);
  var idx = sibs.indexOf(n);
  return idx > 0 ? sibs[idx - 1] : null;
}

function __nextEl(n) {
  if (!n || !n.parent) return null;
  var sibs = __elementsOf(n.parent);
  var idx = sibs.indexOf(n);
  return idx >= 0 && idx + 1 < sibs.length ? sibs[idx + 1] : null;
}

function __descendants(n, out) {
  out = out || [];
  if (!n) return out;
  for (var i = 0; i < n.children.length; i++) {
    var c = n.children[i];
    if (c.nodeType === 1) { out.push(c); __descendants(c, out); }
  }
  return out;
}

function __attrMatch(node, body) {
  var m = String(body).match(/^\s*([\w:.-]+)\s*(?:([~^$*|]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\s*$/);
  if (!m) return false;
  var name = m[1].toLowerCase();
  var op = m[2];
  var val = m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : m[5]);
  var has = Object.prototype.hasOwnProperty.call(node.attrs, name);
  if (!op) return has;
  if (!has) return false;
  var av = node.attrs[name] == null ? '' : String(node.attrs[name]);
  if (val === undefined) val = '';
  if (op === '=') return av === val;
  if (op === '~=') return (' ' + av + ' ').indexOf(' ' + val + ' ') >= 0;
  if (op === '^=') return val.length > 0 && av.indexOf(val) === 0;
  if (op === '$=') return val.length > 0 && av.length >= val.length && av.lastIndexOf(val) === av.length - val.length;
  if (op === '*=') return val.length > 0 && av.indexOf(val) >= 0;
  if (op === '|=') return av === val || av.indexOf(val + '-') === 0;
  return false;
}

function __nthOk(n, arg) {
  var sibs = n.parent ? __elementsOf(n.parent) : [n];
  var idx = sibs.indexOf(n) + 1;
  arg = String(arg || '').trim().toLowerCase();
  if (arg === 'odd') return idx % 2 === 1;
  if (arg === 'even') return idx % 2 === 0;
  var m = arg.match(/^(-?\d*)n\s*([+-]\s*\d+)?$/);
  if (m) {
    var a = m[1] === '' || m[1] === '+' ? 1 : (m[1] === '-' ? -1 : parseInt(m[1], 10));
    var b = m[2] ? parseInt(m[2].replace(/\s/g, ''), 10) : 0;
    if (a === 0) return idx === b;
    var k = (idx - b) / a;
    return k >= 0 && Math.floor(k) === k;
  }
  return idx === parseInt(arg, 10);
}

function __pseudoMatch(node, name, arg) {
  if (name === 'first-child') { var s1 = node.parent ? __elementsOf(node.parent) : [node]; return s1[0] === node; }
  if (name === 'last-child') { var s2 = node.parent ? __elementsOf(node.parent) : [node]; return s2[s2.length - 1] === node; }
  if (name === 'only-child') { var s3 = node.parent ? __elementsOf(node.parent) : [node]; return s3.length === 1; }
  if (name === 'nth-child') return __nthOk(node, arg);
  if (name === 'first-of-type' || name === 'last-of-type') {
    var sibs = node.parent ? __elementsOf(node.parent) : [node];
    var same = sibs.filter(function (x) { return x.tag === node.tag; });
    return name === 'first-of-type' ? same[0] === node : same[same.length - 1] === node;
  }
  if (name === 'nth-of-type') {
    var sibs2 = node.parent ? __elementsOf(node.parent) : [node];
    var same2 = sibs2.filter(function (x) { return x.tag === node.tag; });
    var pos = same2.indexOf(node) + 1;
    var argS = String(arg || '').trim().toLowerCase();
    if (argS === 'odd') return pos % 2 === 1;
    if (argS === 'even') return pos % 2 === 0;
    var mm = argS.match(/^(-?\d*)n\s*([+-]\s*\d+)?$/);
    if (mm) {
      var a2 = mm[1] === '' || mm[1] === '+' ? 1 : (mm[1] === '-' ? -1 : parseInt(mm[1], 10));
      var b2 = mm[2] ? parseInt(mm[2].replace(/\s/g, ''), 10) : 0;
      if (a2 === 0) return pos === b2;
      var k2 = (pos - b2) / a2;
      return k2 >= 0 && Math.floor(k2) === k2;
    }
    return pos === parseInt(argS, 10);
  }
  if (name === 'not') return !__compoundMatch(node, String(arg || ''));
  if (name === 'is' || name === 'where') return __compoundMatch(node, String(arg || ''));
  if (name === 'empty') {
    for (var i = 0; i < node.children.length; i++) {
      if (node.children[i].nodeType === 1) return false;
      if (node.children[i].text.trim().length > 0) return false;
    }
    return true;
  }
  if (name === 'contains') return __textOf(node).indexOf(String(arg || '').replace(/^["']|["']$/g, '')) >= 0;
  if (name === 'has') {
    var subs = __descendants(node);
    for (var j = 0; j < subs.length; j++) if (__compoundMatch(subs[j], String(arg || ''))) return true;
    return false;
  }
  return false;
}

function __compoundMatch(node, comp) {
  if (!node || node.nodeType !== 1) return false;
  comp = String(comp || '').trim();
  if (comp === '' || comp === '*') return true;
  var i = 0, n = comp.length;
  var tagRead = false;
  while (i < n) {
    var ch = comp[i];
    if (ch === '*') { i++; continue; }
    if (ch === '.') {
      i++;
      var st = i;
      while (i < n && /[\w-]/.test(comp[i])) i++;
      var cls = comp.substring(st, i);
      if (cls === '') return false;
      var classes = (' ' + String(node.attrs['class'] || '') + ' ');
      if (classes.indexOf(' ' + cls + ' ') < 0) return false;
      continue;
    }
    if (ch === '#') {
      i++;
      var st2 = i;
      while (i < n && /[\w-]/.test(comp[i])) i++;
      if (String(node.attrs['id'] || '') !== comp.substring(st2, i)) return false;
      continue;
    }
    if (ch === '[') {
      var close = -1, depthB = 0;
      for (var q = i; q < n; q++) {
        if (comp[q] === '[') depthB++;
        else if (comp[q] === ']') { depthB--; if (depthB === 0) { close = q; break; } }
      }
      if (close < 0) return false;
      if (!__attrMatch(node, comp.substring(i + 1, close))) return false;
      i = close + 1;
      continue;
    }
    if (ch === ':') {
      i++;
      var st3 = i;
      while (i < n && /[\w-]/.test(comp[i])) i++;
      var nm = comp.substring(st3, i).toLowerCase();
      var arg = null;
      if (comp[i] === '(') {
        var depthP = 0, k = i;
        for (; k < n; k++) {
          if (comp[k] === '(') depthP++;
          else if (comp[k] === ')') { depthP--; if (depthP === 0) break; }
        }
        arg = comp.substring(i + 1, k);
        i = k + 1;
      }
      if (!__pseudoMatch(node, nm, arg)) return false;
      continue;
    }
    var st4 = i;
    while (i < n && /[\w-]/.test(comp[i])) i++;
    if (i === st4) { i++; continue; }
    tagRead = true;
    if (node.tag.toLowerCase() !== comp.substring(st4, i).toLowerCase()) return false;
  }
  return true;
}

function __parseChain(group) {
  var s = String(group || '').trim().replace(/\s*([>+~])\s*/g, ' $1 ');
  var toks = s.split(/\s+/).filter(function (x) { return x.length > 0; });
  var chain = [], pending = ' ';
  for (var i = 0; i < toks.length; i++) {
    var t = toks[i];
    if (t === '>' || t === '+' || t === '~') { pending = t; continue; }
    chain.push({ comb: pending, simple: t });
    pending = ' ';
  }
  return chain;
}

function __chainMatch(node, chain, idx) {
  if (idx < 0) return true;
  var part = chain[idx];
  if (!__compoundMatch(node, part.simple)) return false;
  if (idx === 0) return true;
  var comb = part.comb;
  if (comb === '>') {
    var p = node.parent;
    return !!(p && p.nodeType === 1 && __chainMatch(p, chain, idx - 1));
  }
  if (comb === '+') {
    var prev = __prevEl(node);
    return !!(prev && __chainMatch(prev, chain, idx - 1));
  }
  if (comb === '~') {
    var s2 = __prevEl(node);
    while (s2) {
      if (__chainMatch(s2, chain, idx - 1)) return true;
      s2 = __prevEl(s2);
    }
    return false;
  }
  var anc = node.parent;
  while (anc && anc.nodeType === 1) {
    if (__chainMatch(anc, chain, idx - 1)) return true;
    anc = anc.parent;
  }
  return false;
}

function __selectAll(scope, selector) {
  var groups = String(selector || '').split(',');
  var chains = [];
  for (var g = 0; g < groups.length; g++) {
    var ch = __parseChain(groups[g]);
    if (ch.length) chains.push(ch);
  }
  if (!chains.length) return [];
  var pool = __descendants(scope);
  var out = [];
  for (var i = 0; i < pool.length; i++) {
    for (var c = 0; c < chains.length; c++) {
      if (__chainMatch(pool[i], chains[c], chains[c].length - 1)) { out.push(pool[i]); break; }
    }
  }
  return out;
}

function __textOf(node) {
  if (!node) return '';
  if (node.nodeType === 3) return node.text;
  var s = '';
  for (var i = 0; i < node.children.length; i++) s += __textOf(node.children[i]);
  return s;
}

function __htmlOut(node) {
  if (!node) return '';
  if (node.nodeType === 3) return node.text;
  if (node.nodeType === 8) return '';
  var s = '<' + node.tag;
  for (var k in node.attrs) {
    if (!Object.prototype.hasOwnProperty.call(node.attrs, k)) continue;
    s += ' ' + k + '="' + String(node.attrs[k] == null ? '' : node.attrs[k]).replace(/"/g, '&quot;') + '"';
  }
  s += '>';
  for (var i = 0; i < node.children.length; i++) s += __htmlOut(node.children[i]);
  return s + '</' + node.tag + '>';
}

class HtmlNode {
  constructor(k, doc) { this.key = k; this.doc = doc; }
  get type() {
    var n = __nodes[this.key];
    if (!n) return 'unknown';
    if (n.nodeType === 3) return 'text';
    if (n.nodeType === 8) return 'comment';
    return 'element';
  }
  get text() { return __textOf(__nodes[this.key]); }
  toElement() {
    var n = __nodes[this.key];
    if (!n || n.nodeType !== 1) return null;
    return new HtmlElement(this.key, this.doc);
  }
}

class HtmlElement {
  constructor(k, doc) { this.key = k; this.doc = doc; }
  get node() { return __nodes[this.key]; }
  get text() { return __textOf(this.node); }
  get attributes() {
    var n = this.node;
    var out = {};
    if (n) for (var k in n.attrs) if (Object.prototype.hasOwnProperty.call(n.attrs, k)) out[k] = n.attrs[k];
    return out;
  }
  querySelector(sel) {
    var all = __selectAll(this.node, sel);
    return all.length ? new HtmlElement(all[0].key, this.doc) : null;
  }
  querySelectorAll(sel) {
    var self = this;
    return __selectAll(this.node, sel).map(function (x) { return new HtmlElement(x.key, self.doc); });
  }
  getElementById(id) { return this.querySelector('[id="' + String(id) + '"]'); }
  get children() {
    var self = this;
    return __elementsOf(this.node).map(function (x) { return new HtmlElement(x.key, self.doc); });
  }
  get nodes() {
    var n = this.node;
    if (!n) return [];
    var self = this;
    return n.children.map(function (x) { return new HtmlNode(x.key, self.doc); });
  }
  get innerHTML() {
    var n = this.node;
    if (!n) return '';
    var s = '';
    for (var i = 0; i < n.children.length; i++) s += __htmlOut(n.children[i]);
    return s;
  }
  get innerHtml() { return this.innerHTML; }
  get outerHTML() { return __htmlOut(this.node); }
  get parent() {
    var n = this.node;
    if (!n || !n.parent || n.parent.nodeType !== 1) return null;
    return new HtmlElement(n.parent.key, this.doc);
  }
  get classNames() { return String((this.node && this.node.attrs['class']) || '').split(/\s+/).filter(function (x) { return x; }); }
  get id() { return this.node ? (this.node.attrs['id'] || null) : null; }
  get localName() { return this.node ? this.node.tag : ''; }
  get previousElementSibling() {
    var p = __prevEl(this.node);
    return p ? new HtmlElement(p.key, this.doc) : null;
  }
  get nextElementSibling() {
    var p = __nextEl(this.node);
    return p ? new HtmlElement(p.key, this.doc) : null;
  }
  get previousSibling() { return this.previousElementSibling; }
  get nextSibling() { return this.nextElementSibling; }
  get attrList() { return this.attributes; }
  attr(name) { var a = this.attributes; return a[String(name)] === undefined ? null : a[String(name)]; }
}

class HtmlDocument {
  constructor(html) {
    this.doc = __docSeq++;
    var raw = null;
    try { raw = JSON.parse(__parseHTML(String(html == null ? '' : html))); } catch (e) { raw = null; }
    if (!raw) raw = { t: '#root', a: {}, x: '', c: [] };
    this.key = __buildNode(raw, null).key;
    __docs[this.doc] = this.key;
  }
  get root() { return __nodes[this.key]; }
  querySelector(sel) {
    var all = __selectAll(this.root, sel);
    return all.length ? new HtmlElement(all[0].key, this.doc) : null;
  }
  querySelectorAll(sel) {
    var self = this;
    return __selectAll(this.root, sel).map(function (x) { return new HtmlElement(x.key, self.doc); });
  }
  getElementById(id) { return this.querySelector('[id="' + String(id) + '"]'); }
  dispose() {
    var root = this.root;
    if (root) {
      var pool = __descendants(root);
      for (var i = 0; i < pool.length; i++) delete __nodes[pool[i].key];
      delete __nodes[root.key];
    }
    delete __docs[this.doc];
  }
  get body() { return this.querySelector('body') || this.querySelector('html') || new HtmlElement(this.key, this.doc); }
}

// ===== 类型构造器 =====

function Comic(o) {
  o = o || {};
  this.id = o.id;
  this.title = o.title;
  this.subtitle = o.subtitle;
  this.subTitle = o.subTitle !== undefined ? o.subTitle : o.subtitle;
  this.cover = o.cover;
  this.tags = o.tags;
  this.description = o.description;
  this.maxPage = o.maxPage;
  this.language = o.language;
  this.favoriteId = o.favoriteId;
  this.stars = o.stars;
  this.updateTime = o.updateTime;
}

function ComicDetails(o) {
  o = o || {};
  this.title = o.title;
  this.subtitle = o.subtitle;
  this.subTitle = o.subTitle !== undefined ? o.subTitle : o.subtitle;
  this.cover = o.cover;
  this.description = o.description;
  this.tags = o.tags;
  this.chapters = o.chapters;
  this.isFavorite = o.isFavorite;
  this.subId = o.subId;
  this.thumbnails = o.thumbnails;
  this.recommend = o.recommend;
  this.commentCount = o.commentCount;
  this.likesCount = o.likesCount;
  this.isLiked = o.isLiked;
  this.uploader = o.uploader;
  this.updateTime = o.updateTime;
  this.uploadTime = o.uploadTime;
  this.url = o.url;
  this.stars = o.stars;
  this.maxPage = o.maxPage;
  this.comments = o.comments;
}

function Comment(o) {
  o = o || {};
  this.userName = o.userName;
  this.avatar = o.avatar;
  this.content = o.content;
  this.time = o.time;
  this.replyCount = o.replyCount;
  this.id = o.id;
  this.isLiked = o.isLiked;
  this.score = o.score;
  this.voteStatus = o.voteStatus;
}

function ImageLoadingConfig(o) {
  o = o || {};
  this.url = o.url;
  this.method = o.method;
  this.data = o.data;
  this.headers = o.headers;
  this.onResponse = o.onResponse;
  this.modifyImage = o.modifyImage;
  this.onLoadFailed = o.onLoadFailed;
}

// ===== ComicSource =====

var __sourceRuntime = {
  instances: [],
  register: function (s) { this.instances.push(s); },
  message: function () { return null; }
};

class ComicSource {
  constructor() { __sourceRuntime.register(this); }
  loadData(dataKey) { return __kvGet(String(this.key || ''), String(dataKey || '')); }
  saveData(dataKey, data) { __kvSet(String(this.key || ''), String(dataKey || ''), JSON.stringify(data === undefined ? null : data)); }
  deleteData(dataKey) { __kvDel(String(this.key || ''), String(dataKey || '')); }
  loadSetting(key) { return null; }
  get isLogged() { return false; }
  translate(key) { return key; }
  init() { }
}
ComicSource.sources = {};

var __veneraSource = null;

// 入口类：源的 `class Xxx extends ComicSource` 是**词法声明**，
// 不会挂到 globalThis 上，所以宿主在 eval 源之后把类对象直接传进来。
function __veneraActivate(cls) {
  if (cls && typeof cls === 'function') {
    try { __veneraSource = new cls(); return true; }
    catch (e) { __log('实例化源失败: ' + __errText(e)); __veneraSource = null; }
  }
  if (__sourceRuntime.instances.length > 0) {
    __veneraSource = __sourceRuntime.instances[0];
    return true;
  }
  // 兜底：`var X = class extends ComicSource {}` 这类写法会出现在 globalThis 上
  var found = null;
  var names;
  try { names = Object.getOwnPropertyNames(globalThis); } catch (e) { names = []; }
  for (var i = 0; i < names.length; i++) {
    var v;
    try { v = globalThis[names[i]]; } catch (e2) { continue; }
    if (typeof v !== 'function' || !v.prototype) continue;
    if (names[i] === 'ComicSource') continue;
    try { if (v.prototype instanceof ComicSource) found = v; } catch (e3) { }
  }
  if (!found) return false;
  try { __veneraSource = new found(); } catch (e4) { return false; }
  return true;
}

function __veneraMeta() {
  var s = __veneraSource;
  if (!s) return JSON.stringify({ ok: false });
  var out = {
    ok: true,
    name: s.name == null ? '' : String(s.name),
    key: s.key == null ? '' : String(s.key),
    version: s.version == null ? '' : String(s.version),
    url: s.url == null ? '' : String(s.url),
    hasSearch: !!(s.search && (typeof s.search.load === 'function' || typeof s.search.loadNext === 'function')),
    hasComic: !!(s.comic && typeof s.comic.loadInfo === 'function' && typeof s.comic.loadEp === 'function'),
    hasExplore: !!(s.explore && s.explore.length),
    exploreCount: (s.explore && s.explore.length) ? s.explore.length : 0,
    exploreTitles: (s.explore && s.explore.length) ? s.explore.map(function (e) { return String(e.title || ''); }) : []
  };
  try { return JSON.stringify(out); } catch (e) { return JSON.stringify({ ok: true, name: '', key: '', version: '' }); }
}

// ===== 杂项 =====

var UI = {
  showMessage: function (m) { __log(String(m)); },
  showDialog: function () { },
  launchUrl: function (u) { },
  showLoading: function () { return 0; },
  cancelLoading: function () { },
  showInputDialog: function () { return null; },
  showSelectDialog: function (t, opts, i) { return (opts && opts.length) ? (i || 0) : null; }
};

var APP = {
  locale: 'zh_CN',
  version: '1.18.4',
  isAndroid: false,
  isIOS: true,
  isMacOS: false,
  isWindows: false,
  isLinux: false,
  theme: 'light'
};

function log(level, title, content) {
  __log('[' + String(level) + '] ' + String(title == null ? '' : title) + ' ' + String(content == null ? '' : content));
}

var console = {
  log: function () { __log(Array.prototype.slice.call(arguments).join(' ')); },
  info: function () { __log(Array.prototype.slice.call(arguments).join(' ')); },
  warn: function () { __log('[warn] ' + Array.prototype.slice.call(arguments).join(' ')); },
  error: function () { __log('[error] ' + Array.prototype.slice.call(arguments).join(' ')); },
  debug: function () { __log(Array.prototype.slice.call(arguments).join(' ')); }
};

function setTimeout(fn, ms) {
  if (typeof fn === 'function') Promise.resolve().then(function () { fn(); });
  return 0;
}

function clearTimeout() { }
function setInterval() { return 0; }
function clearInterval() { }

function createUuid() {
  var s = '';
  for (var i = 0; i < 32; i++) {
    s += Math.floor(Math.random() * 16).toString(16);
    if (i === 8 || i === 12 || i === 16 || i === 20) s += '-';
  }
  return s;
}

function randomInt(min, max) {
  min = Math.ceil(Number(min) || 0);
  max = Math.floor(Number(max) || 0);
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function randomDouble(min, max) {
  return Math.random() * ((Number(max) || 1) - (Number(min) || 0)) + (Number(min) || 0);
}

function compute(fn) {
  var args = Array.prototype.slice.call(arguments, 1);
  try { return Promise.resolve(fn.apply(null, args)); } catch (e) { return Promise.reject(e); }
}

function setClipboard(t) { }
function getClipboard() { return ''; }

class Image {
  constructor(key) { this.key = key; }
  get width() { return 0; }
  get height() { return 0; }
  copyRange() { return null; }
  copyAndRotate90() { return null; }
  fillImageAt() { }
  fillImageRangeAt() { }
  static empty() { return null; }
}
"""#
}
