import Foundation

/// 把声明式规则（SourceRules）编译成等价 JS 脚本。
/// 规则里每个字段的写法：
///   "a.item-title"        → 在条目内查询，取文本
///   "img@src"             → 在条目内查询，取属性
///   "@href"               → 取条目自身的属性
///   ""                    → 取条目自身文本 / 自身链接
enum JSONSourceCompiler {

    static func compile(_ s: MangaSource) -> String {
        let r = s.rules ?? .empty
        var lines: [String] = []
        lines.append("// 自动编译源：\(s.name)")
        lines.append("var __R = {")
        lines.append("  searchURL: \(js(r.searchURL)),")
        lines.append("  searchMethod: \(js(r.searchMethod.isEmpty ? "GET" : r.searchMethod)),")
        lines.append("  searchBody: \(js(r.searchBody ?? "")),")
        lines.append("  chapterReverse: \(r.chapterReverse ? "true" : "false")")
        lines.append("};")
        lines.append("")

        // 提取表达式生成器
        func expr(_ spec: String, _ fallback: String) -> String {
            let spec = spec.trimmingCharacters(in: .whitespaces)
            guard !spec.isEmpty else { return fallback }
            if spec.hasPrefix("@") {
                return "el.attr(\(js(String(spec.dropFirst()))))"
            }
            if let atRange = spec.range(of: "@", options: .backwards) {
                let sel = String(spec[spec.startIndex..<atRange.lowerBound])
                let attr = String(spec[atRange.upperBound...])
                return "el.find(\(js(sel))).attr(\(js(attr)))"
            }
            return "el.find(\(js(spec))).text()"
        }
        func exprText(_ spec: String, _ fallback: String) -> String {
            let spec = spec.trimmingCharacters(in: .whitespaces)
            guard !spec.isEmpty else { return fallback }
            if spec.hasPrefix("@") {
                return "el.attr(\(js(String(spec.dropFirst()))))"
            }
            if spec.hasSuffix("@text") {
                let sel = String(spec.dropLast(5))
                return "el.find(\(js(sel))).text()"
            }
            if let atRange = spec.range(of: "@", options: .backwards) {
                let sel = String(spec[spec.startIndex..<atRange.lowerBound])
                let attr = String(spec[atRange.upperBound...])
                return "el.find(\(js(sel))).attr(\(js(attr)))"
            }
            return "el.find(\(js(spec))).text()"
        }

        // search
        lines.append("""
        function search(q, page){
          page = page || 1;
          var u = __R.searchURL.replace(/\\{q\\}/g, encodeURIComponent(q)).replace(/\\{page\\}/g, page).replace(/\\{query\\}/g, q);
          u = abs(u);
          var html = __R.searchMethod === 'POST' ? post(u, (__R.searchBody || '').replace(/\\{q\\}/g, encodeURIComponent(q)), null, BASE) : get(u, null, BASE);
          var out = [];
          doc(html).find(\(js(r.searchList.isEmpty ? "body" : r.searchList))).each(function(i, el){
            var u2 = \(expr(r.searchLink, "el.find('a').attr('href')"));
            var t2 = \(exprText(r.searchTitle, "el.text()"));
            var c2 = \(expr(r.searchCover, "el.find('img').attr('src')"));
            var a2 = \(exprText(r.searchAuthor, "''"));
            if (u2 && t2) out.push(item(abs(u2), t2, c2, a2));
          });
          return dedup(out);
        }
        """)

        // detail
        lines.append("""
        function detail(url){
          var html = get(url, null, url);
          var d = doc(html);
          var title = \(r.detailTitle.isEmpty ? "d.find('h1').first().text()" : "d.find(\(js(r.detailTitle))).first().text()");
          var cover = \(r.detailCover.isEmpty ? "d.find('img').first().attr('src')" : "d.find(\(js(r.detailCover))).first().attr('src')");
          var author = \(r.detailAuthor.isEmpty ? "''" : "d.find(\(js(r.detailAuthor))).first().text()");
          var desc = \(r.detailDesc.isEmpty ? "''" : "d.find(\(js(r.detailDesc))).first().text()");
          var genre = \(r.detailGenre.isEmpty ? "''" : "d.find(\(js(r.detailGenre))).first().text()");
          var status = \(r.detailStatus.isEmpty ? "''" : "d.find(\(js(r.detailStatus))).first().text()");
          return { url: url, title: __norm(title), cover: fixImg(cover), author: __norm(author),
                   desc: __norm(desc), genre: __norm(genre), status: __norm(status) };
        }
        """)

        // chapters
        lines.append("""
        function chapters(url){
          var html = get(url, null, url);
          var out = [];
          doc(html).find(\(js(r.chapterList.isEmpty ? "#chapter-list a" : r.chapterList))).each(function(i, el){
            var u2 = \(expr(r.chapterLink, "el.attr('href')"));
            var t2 = \(exprText(r.chapterName, "el.text()"));
            if (u2 && t2) out.push({ url: abs(u2), name: __norm(t2), index: i });
          });
          var seen = {}, res = [];
          for (var k = 0; k < out.length; k++) {
            if (seen[out[k].url]) continue;
            seen[out[k].url] = 1;
            res.push(out[k]);
          }
          if (__R.chapterReverse) res.reverse();
          return res;
        }
        """)

        // images
        lines.append("""
        function images(chapterUrl){
          var html = get(chapterUrl, null, chapterUrl);
          var out = [];
          doc(html).find(\(js(r.imageList.isEmpty ? "img" : r.imageList))).each(function(i, el){
            var u2 = el.attr(\(js(r.imageAttr.isEmpty ? "src" : r.imageAttr)));
            if (!u2) u2 = el.attr('data-src') || el.attr('data-original') || el.attr('src');
            u2 = fixImg(u2, chapterUrl);
            if (u2 && u2.indexOf('data:image/gif') !== 0) out.push({ url: u2, referer: \(js(r.imageReferer)) || chapterUrl });
          });
          // 过滤明显的占位图与 logo
          out = out.filter(function(x){
            var u = x.url.toLowerCase();
            return u.length > 12 && !/loading|placeholder|\/logo|spacer|1x1/.test(u);
          });
          return out;
        }
        """)

        // category（可选）
        if !r.categoryURL.isEmpty, !r.categoryList.isEmpty {
            lines.append("""
            function category(param, page){
              page = page || 1;
              var u = abs(\(js(r.categoryURL)).replace(/\\{param\\}/g, encodeURIComponent(param || '')).replace(/\\{page\\}/g, page));
              var html = get(u, null, BASE);
              var out = [];
              doc(html).find(\(js(r.categoryList))).each(function(i, el){
                var u2 = el.find('a').attr('href') || el.attr('href');
                var t2 = el.find(\(js(r.categoryName.isEmpty ? ".title" : r.categoryName))).text() || el.text();
                var c2 = el.find('img').attr('src') || el.attr('data-src');
                if (u2 && t2) out.push(item(abs(u2), t2, c2));
              });
              return dedup(out);
            }
            """)
        }

        return lines.joined(separator: "\n")
    }

    private static func js(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        // arr 形如 ["..."]，去掉外层中括号
        return String(arr.dropFirst().dropLast())
    }
}
