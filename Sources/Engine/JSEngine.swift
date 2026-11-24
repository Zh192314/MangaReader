import Foundation
import JavaScriptCore
import CryptoKit

/// JavaScriptCore 运行时封装。
/// 设计取舍：源脚本走「同步阻塞 HTTP」风格，不引入 Promise / event loop，
/// 这样脚本写起来是直白的顺序代码，JSContext 也不需要跑 run loop。
final class JSEngine {

    let context: JSContext
    let source: MangaSource
    private let queue: DispatchQueue

    private(set) var lastError: String?

    init(source: MangaSource) {
        self.source = source
        self.queue = DispatchQueue(label: "js.engine.\(source.id)", qos: .userInitiated)
        self.context = JSContext()!
        installBridge()
        installBootstrap()
        if let script = source.script, !script.isEmpty {
            run(script)
        }
    }

    // MARK: - 桥

    private func installBridge() {
        let ctx = context!

        ctx.exceptionHandler = { [weak self] _, exc in
            self?.lastError = exc?.toString() ?? "unknown js error"
        }

        // HTTP：method, url, body, headersJson, referer -> String
        let httpBlock: @convention(block) (String, String, String, String, String) -> String = {
            method, url, body, headersJSON, referer in
            var headers: [String: String]? = nil
            if !headersJSON.isEmpty, headersJSON != "null",
               let d = headersJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                headers = obj
            }
            let ref = referer.isEmpty || referer == "null" ? nil : referer
            return HTTPClient.shared.syncRequest(url,
                                                 method: method.isEmpty ? "GET" : method,
                                                 body: body.isEmpty || body == "null" ? nil : body,
                                                 headers: headers,
                                                 referer: ref)
        }
        ctx.setObject(httpBlock, forKeyedSubscript: "__http" as NSString)

        // HTML -> JSON 树
        let htmlBlock: @convention(block) (String) -> String = { html in
            let root = HTMLParser.parse(html)
            return root.jsonString()
        }
        ctx.setObject(htmlBlock, forKeyedSubscript: "__parseHTML" as NSString)

        let b64Block: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        ctx.setObject(b64Block, forKeyedSubscript: "__b64" as NSString)

        let b64DecBlock: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        ctx.setObject(b64DecBlock, forKeyedSubscript: "__b64decode" as NSString)

        let md5Block: @convention(block) (String) -> String = { s in
            let digest = Insecure.MD5.hash(data: Data(s.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        ctx.setObject(md5Block, forKeyedSubscript: "__md5" as NSString)

        let logBlock: @convention(block) (String) -> Void = { s in
            #if DEBUG
            print("[JS] \(s)")
            #endif
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__log" as NSString)

        let nowBlock: @convention(block) () -> Double = { Date().timeIntervalSince1970 }
        ctx.setObject(nowBlock, forKeyedSubscript: "__now" as NSString)

        // 源上下文常量
        ctx.setObject(source.baseURL, forKeyedSubscript: "__BASE" as NSString)
        ctx.setObject(source.id, forKeyedSubscript: "__SOURCE_ID" as NSString)
        if let h = source.effectiveHeaders as [String: String]?,
           let d = try? JSONSerialization.data(withJSONObject: h),
           let s = String(data: d, encoding: .utf8) {
            ctx.setObject(s, forKeyedSubscript: "__HEADERS" as NSString)
        } else {
            ctx.setObject("{}" as NSString, forKeyedSubscript: "__HEADERS" as NSString)
        }
    }

    private func installBootstrap() {
        context.evaluateScript(JSEngine.bootstrap)
    }

    @discardableResult
    func run(_ script: String) -> JSValue? {
        lastError = nil
        let v = context.evaluateScript(script)
        if let e = context.exception {
            lastError = e.toString()
            context.exception = nil
        }
        return v
    }

    /// 调用脚本里的函数并取回可序列化结果
    func callJSON(_ fn: String, _ args: [Any]) throws -> Any? {
        var result: Any?
        var err: String?
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            defer { sem.signal() }
            guard let f = self.context.objectForKeyedSubscript(fn), !f.isUndefined else {
                err = "源脚本缺少函数 \(fn)()"
                return
            }
            let vals: [JSValue] = args.map { JSValue(jsonObject: $0, in: self.context) ?? JSValue(undefinedIn: self.context) }
            let out = f.call(withArguments: vals)
            if let e = self.context.exception {
                err = e.toString() ?? "js exception"
                self.context.exception = nil
                return
            }
            guard let out = out, !out.isUndefined, !out.isNull else {
                err = "\(fn)() 返回空"
                return
            }
            result = out.toObject()
        }
        _ = sem.wait(timeout: .now() + 90)
        if let err = err { throw SourceError.script(err) }
        return normalize(result)
    }

    /// JSValue.toObject 可能给出 NSDictionary / NSArray / __NSCF 类型，统一成纯 Swift
    private func normalize(_ any: Any?) -> Any? {
        guard let any = any else { return nil }
        if any is NSNull { return nil }
        if let d = any as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = normalize(v) }
            return out
        }
        if let a = any as? [Any] {
            return a.map { normalize($0) }
        }
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n }
        return String(describing: any)
    }
}

enum SourceError: LocalizedError {
    case script(String)
    case parse(String)
    case disabled
    case empty

    var errorDescription: String? {
        switch self {
        case .script(let s): return "源脚本错误：\(s)"
        case .parse(let s): return "解析失败：\(s)"
        case .disabled: return "源已停用"
        case .empty: return "没有拿到数据"
        }
    }
}

// MARK: - Bootstrap：jQuery 风格 DOM 查询 + 工具函数

extension JSEngine {

    static let bootstrap = #"""
// ===== 漫阅源运行时 bootstrap =====
var console = {
  log: function(){ __log(Array.prototype.slice.call(arguments).join(' ')); },
  error: function(){ __log('[err] ' + Array.prototype.slice.call(arguments).join(' ')); }
};

var BASE = __BASE || '';
var HEADERS = (function(){ try { return JSON.parse(__HEADERS || '{}'); } catch(e){ return {}; } })();
var SOURCE_ID = __SOURCE_ID || '';

function mergeHeaders(h){
  var o = {};
  for (var k in HEADERS) o[k] = HEADERS[k];
  if (h) for (var j in h) o[j] = h[j];
  return o;
}

function get(url, headers, referer){
  var r = __http('GET', url, '', JSON.stringify(mergeHeaders(headers)), referer || '');
  if (r.indexOf('__ERROR__:') === 0) throw new Error(r.slice(10));
  return r;
}

function post(url, body, headers, referer){
  var r = __http('POST', url, body || '', JSON.stringify(mergeHeaders(headers)), referer || '');
  if (r.indexOf('__ERROR__:') === 0) throw new Error(r.slice(10));
  return r;
}

function getJSON(url, headers, referer){
  var s = get(url, headers, referer);
  try { return JSON.parse(s); } catch(e){
    var m = s.match(/\{[\s\S]*\}|\[[\s\S]*\]/);
    if (m) { try { return JSON.parse(m[0]); } catch(e2){} }
    throw new Error('JSON 解析失败: ' + s.slice(0, 120));
  }
}

function postJSON(url, body, headers, referer){
  var s = post(url, body, headers, referer);
  try { return JSON.parse(s); } catch(e){
    var m = s.match(/\{[\s\S]*\}|\[[\s\S]*\]/);
    if (m) { try { return JSON.parse(m[0]); } catch(e2){} }
    throw new Error('JSON 解析失败: ' + s.slice(0, 120));
  }
}

// ===== URL 工具 =====
function abs(u, base){
  if (!u) return '';
  u = String(u).trim();
  if (/^(https?:|data:|blob:)/i.test(u)) return u;
  if (u.indexOf('//') === 0) return 'https:' + u;
  var b = base || BASE || '';
  if (u.charAt(0) === '/') {
    var m = b.match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] + u : u;
  }
  var origin = b.replace(/\/[^\/]*$/, '/');
  return origin + u.replace(/^\.\//, '');
}

function fixImg(u, base){
  if (!u) return '';
  u = String(u).trim();
  var mm = u.match(/url\(['"]?([^'")]+)['"]?\)/i);
  if (mm) u = mm[1];
  if (u.indexOf('data:') === 0) return u;
  return abs(u, base);
}

function stripTags(s){
  return String(s || '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
}

function txt(s){ return stripTags(s); }

function num(s){
  var m = String(s || '').match(/[\d.]+/);
  return m ? parseFloat(m[0]) : 0;
}

function sleep(ms){
  var end = __now() + ms / 1000;
  while (__now() < end) {}
}

// ===== 极简 DOM =====
function __mk(node){
  if (!node) return null;
  return {
    t: node.t || '',
    a: node.a || {},
    x: node.x || '',
    c: node.c || [],
    p: node.p || null
  };
}

function __prep(node, parent){
  var n = __mk(node);
  if (!n) return null;
  n.p = parent;
  if (n.c && n.c.length) {
    for (var i = 0; i < n.c.length; i++) {
      __prep(n.c[i], n);
    }
  }
  return n;
}

function __text(node){
  if (!node) return '';
  if (node.t === '#text') return node.x || '';
  var s = node.x || '';
  var kids = node.c || [];
  for (var i = 0; i < kids.length; i++) s += __text(kids[i]);
  return s;
}

function __norm(s){
  return String(s || '').replace(/\u00a0/g, ' ').replace(/[\t\r\n]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
}

// 选择器：支持 tag / .cls / #id / [attr] / [attr=v] / [attr*=v] / [attr^=v] / [attr$=v]
// 以及空格后代、> 子代、逗号分组、:first :last :eq(n) :contains(s)
function __simpleMatch(node, sel){
  if (!node || node.t === '#text') return false;
  var s = sel.trim();
  if (!s) return false;

  // 伪类
  var pseudo = null;
  var pm = s.match(/:(first|last|eq\(\d+\)|contains\([^)]*\))$/);
  if (pm) {
    pseudo = pm[0];
    s = s.slice(0, s.length - pseudo.length);
  }

  var ok = true;
  var tagM = s.match(/^([a-zA-Z][\w-]*|\*)/);
  if (tagM) {
    if (tagM[1] !== '*' && node.t.toLowerCase() !== tagM[1].toLowerCase()) ok = false;
    s = s.slice(tagM[0].length);
  } else if (s.charAt(0) !== '.' && s.charAt(0) !== '#' && s.charAt(0) !== '[') {
    // 纯字符串没有合法部分
    if (s.length) ok = false;
  }
  if (!ok) return false;

  while (s.length) {
    if (s.charAt(0) === '.') {
      var cm = s.match(/^\.([\w\-\u4e00-\u9fa5]+)/);
      if (!cm) { return false; }
      var cls = (node.a && node.a['class']) || '';
      if ((' ' + cls + ' ').indexOf(' ' + cm[1] + ' ') < 0) return false;
      s = s.slice(cm[0].length);
    } else if (s.charAt(0) === '#') {
      var im = s.match(/^#([\w\-\u4e00-\u9fa5]+)/);
      if (!im) return false;
      if ((node.a && node.a['id']) !== im[1]) return false;
      s = s.slice(im[0].length);
    } else if (s.charAt(0) === '[') {
      var am = s.match(/^\[([\w\-:]+)(?:([*^$]?=)["']?([^\]"']*)["']?)?\]/);
      if (!am) return false;
      var an = am[1], op = am[2], av = am[3];
      var v = node.a ? node.a[an] : undefined;
      if (v === undefined) {
        // 大小写不敏感回退
        for (var k in (node.a || {})) { if (k.toLowerCase() === an.toLowerCase()) { v = node.a[k]; } }
      }
      if (v === undefined) return false;
      if (op) {
        v = String(v);
        if (op === '=' && v !== av) return false;
        if (op === '*=' && v.indexOf(av) < 0) return false;
        if (op === '^=' && v.indexOf(av) !== 0) return false;
        if (op === '$=' && v.lastIndexOf(av) !== v.length - av.length) return false;
      }
      s = s.slice(am[0].length);
    } else {
      return false;
    }
  }

  if (pseudo) {
    // 伪类留到列表层处理，这里只做 contains
    var cm2 = pseudo.match(/^:contains\(([^)]*)\)$/);
    if (cm2) {
      if (__text(node).indexOf(cm2[1]) < 0) return false;
    }
  }
  return true;
}

function __collect(root, sel){
  // 拆逗号
  var groups = sel.split(',').map(function(x){ return x.trim(); }).filter(function(x){ return x.length; });
  var out = [];
  for (var g = 0; g < groups.length; g++) {
    var parts = groups[g].replace(/\s*>\s*/g, ' > ').split(/\s+/).filter(function(x){ return x.length; });
    var cur = [root];
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      var childOnly = false;
      if (part === '>') { childOnly = true; i++; part = parts[i]; }
      if (!part) break;
      var next = [];
      for (var c = 0; c < cur.length; c++) {
        var pool = childOnly ? (cur[c].c || []) : __allDesc(cur[c]);
        for (var k = 0; k < pool.length; k++) {
          if (__simpleMatch(pool[k], part)) next.push(pool[k]);
        }
      }
      cur = next;
    }
    for (var m = 0; m < cur.length; m++) if (out.indexOf(cur[m]) < 0) out.push(cur[m]);
  }
  // 伪类后处理
  var first = /:first\b/.test(sel), last = /:last\b/.test(sel);
  var eqm = sel.match(/:eq\((\d+)\)/);
  if (eqm) { var idx = parseInt(eqm[1], 10); return idx < out.length ? [out[idx]] : []; }
  if (first) return out.slice(0, 1);
  if (last) return out.slice(out.length - 1);
  return out;
}

function __allDesc(node){
  var out = [];
  var kids = node.c || [];
  for (var i = 0; i < kids.length; i++) {
    if (kids[i].t === '#text') continue;
    out.push(kids[i]);
    var sub = __allDesc(kids[i]);
    for (var j = 0; j < sub.length; j++) out.push(sub[j]);
  }
  return out;
}

function Q(list){
  this.list = list || [];
  this.length = this.list.length;
  for (var i = 0; i < this.list.length; i++) this[i] = this.list[i];
}

Q.prototype.each = function(fn){
  for (var i = 0; i < this.list.length; i++) {
    var el = new Q([this.list[i]]);
    el.raw = this.list[i];
    if (fn.call(el, i, el) === false) break;
  }
  return this;
};

Q.prototype.eq = function(i){ return new Q(i < 0 ? [this.list[this.list.length + i]].filter(Boolean) : [this.list[i]].filter(Boolean)); };
Q.prototype.first = function(){ return new Q(this.list.slice(0,1)); };
Q.prototype.last = function(){ return new Q(this.list.slice(-1)); };

Q.prototype.find = function(sel){
  var out = [];
  for (var i = 0; i < this.list.length; i++) {
    var sub = __collect(this.list[i], sel);
    for (var j = 0; j < sub.length; j++) out.push(sub[j]);
  }
  return new Q(out);
};

Q.prototype.filter = function(sel){
  var out = [];
  for (var i = 0; i < this.list.length; i++) {
    if (__simpleMatch(this.list[i], sel)) out.push(this.list[i]);
  }
  return new Q(out);
};

Q.prototype.children = function(sel){
  var out = [];
  for (var i = 0; i < this.list.length; i++) {
    var kids = this.list[i].c || [];
    for (var j = 0; j < kids.length; j++) {
      if (kids[j].t === '#text') continue;
      if (!sel || __simpleMatch(kids[j], sel)) out.push(kids[j]);
    }
  }
  return new Q(out);
};

Q.prototype.parent = function(){
  var out = [];
  for (var i = 0; i < this.list.length; i++) if (this.list[i].p) out.push(this.list[i].p);
  return new Q(out);
};

Q.prototype.next = function(){
  var out = [];
  for (var i = 0; i < this.list.length; i++) {
    var p = this.list[i].p;
    if (!p) continue;
    var kids = (p.c || []).filter(function(x){ return x.t !== '#text'; });
    var idx = kids.indexOf(this.list[i]);
    if (idx >= 0 && idx + 1 < kids.length) out.push(kids[idx + 1]);
  }
  return new Q(out);
};

Q.prototype.attr = function(name){
  if (!this.list.length) return null;
  var n = this.list[0];
  if (!n.a) return null;
  if (n.a[name] !== undefined) return n.a[name];
  for (var k in n.a) if (k.toLowerCase() === name.toLowerCase()) return n.a[k];
  return null;
};

Q.prototype.text = function(){
  var s = '';
  for (var i = 0; i < this.list.length; i++) s += __text(this.list[i]);
  return __norm(s);
};

Q.prototype.rawText = function(){
  var s = '';
  for (var i = 0; i < this.list.length; i++) s += __text(this.list[i]);
  return s;
};

Q.prototype.html = function(){
  if (!this.list.length) return '';
  return __innerHTML(this.list[0]);
};

Q.prototype.val = function(){
  if (!this.list.length) return '';
  var n = this.list[0];
  return (n.a && (n.a['value'] || n.a['content'])) || '';
};

Q.prototype.hasClass = function(c){
  if (!this.list.length) return false;
  var cls = (this.list[0].a && this.list[0].a['class']) || '';
  return (' ' + cls + ' ').indexOf(' ' + c + ' ') >= 0;
};

Q.prototype.data = function(k){
  if (!this.list.length) return null;
  var n = this.list[0];
  return (n.a && n.a['data-' + k]) || null;
};

Q.prototype.map = function(fn){
  var out = [];
  for (var i = 0; i < this.list.length; i++) {
    var r = fn.call(new Q([this.list[i]]), i, new Q([this.list[i]]));
    if (r !== null && r !== undefined) out.push(r);
  }
  return out;
};

Q.prototype.get = function(i){ return new Q([this.list[i]]); };

function __innerHTML(node){
  var s = node.x || '';
  var kids = node.c || [];
  for (var i = 0; i < kids.length; i++) {
    var k = kids[i];
    s += '<' + k.t;
    for (var a in (k.a || {})) s += ' ' + a + '="' + k.a[a] + '"';
    s += '>' + __innerHTML(k) + '</' + k.t + '>';
  }
  return s;
}

function doc(html){
  var raw = __parseHTML(String(html || ''));
  var root = null;
  try { root = JSON.parse(raw); } catch(e){ root = {t:'#root', c:[]}; }
  var prepped = __prep(root, null);
  return new Q([prepped]);
}

function $(html){
  if (html instanceof Q) return html;
  if (html && typeof html === 'object' && html.list) return html;
  if (html && typeof html === 'object' && html.t) return new Q([html]);
  return doc(html);
}

// ===== 结果构造辅助 =====
function item(url, title, cover, author){
  return {
    url: String(url || ''),
    title: __norm(title || ''),
    cover: fixImg(cover || ''),
    author: __norm(author || '')
  };
}

function dedup(list){
  var seen = {}, out = [];
  for (var i = 0; i < list.length; i++) {
    var it = list[i];
    if (!it || !it.url || !it.title) continue;
    if (seen[it.url]) continue;
    seen[it.url] = 1;
    out.push(it);
  }
  return out;
}

// ===== 可选能力：分类 / 榜单 =====
var __SOURCE_META = {
  id: SOURCE_ID,
  base: BASE
};
"""#
}
