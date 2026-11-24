import Foundation

/// 轻量 HTML 解析：只做「够用」的事——容错、快、能把页面变成可查询的节点树。
/// 不追求完整 HTML5 规范，抗住源站那些缺闭合标签的脏页面即可。
final class HNode {
    var tag: String
    var attrs: [String: String]
    var text: String = ""
    var children: [HNode] = []
    weak var parent: HNode?

    init(tag: String, attrs: [String: String] = [:]) {
        self.tag = tag
        self.attrs = attrs
    }

    var ownText: String { text }

    /// 递归取全部文本，按 HTML 语义折叠空白
    var allText: String {
        var buf = text
        for c in children { buf += c.allText }
        return buf
    }

    var normalizedText: String {
        allText.replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func attr(_ name: String) -> String? {
        if let v = attrs[name] { return v }
        // 大小写不敏感回退
        let lower = name.lowercased()
        for (k, v) in attrs where k.lowercased() == lower { return v }
        return nil
    }

    func descendants() -> [HNode] {
        var out: [HNode] = []
        var stack = children
        while let n = stack.popLast() {
            out.append(n)
            stack.append(contentsOf: n.children)
        }
        return out
    }

    // MARK: 转 JSON（给 JS）

    func toJSONDict() -> [String: Any] {
        var d: [String: Any] = ["t": tag]
        if !attrs.isEmpty { d["a"] = attrs }
        if !text.isEmpty { d["x"] = text }
        if !children.isEmpty { d["c"] = children.map { $0.toJSONDict() } }
        return d
    }

    func jsonString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: toJSONDict(),
                                                    options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

enum HTMLParser {

    private static let voidTags: Set<String> = [
        "br", "img", "input", "meta", "link", "hr", "source", "area",
        "base", "col", "embed", "param", "track", "wbr"
    ]

    /// 这些标签的内容不当节点处理（脚本文本没有查询价值，且容易破坏结构）
    private static let rawTags: Set<String> = ["script", "style", "noscript"]

    static func parse(_ html: String) -> HNode {
        let root = HNode(tag: "#root")
        var stack: [HNode] = [root]
        let chars = Array(html)
        var i = 0
        let n = chars.count
        var textBuf = ""

        func flushText() {
            guard !textBuf.isEmpty else { return }
            let node = HNode(tag: "#text")
            node.text = textBuf
            node.parent = stack.last
            stack.last?.children.append(node)
            textBuf = ""
        }

        while i < n {
            let c = chars[i]
            if c == "<" {
                // 注释
                if i + 3 < n, chars[i+1] == "!", chars[i+2] == "-", chars[i+3] == "-" {
                    var j = i + 4
                    while j + 2 < n, !(chars[j] == "-" && chars[j+1] == "-" && chars[j+2] == ">") { j += 1 }
                    i = min(j + 3, n)
                    continue
                }
                // CDATA / DOCTYPE / 其他声明
                if i + 1 < n, chars[i+1] == "!" || chars[i+1] == "?" {
                    var j = i + 1
                    while j < n, chars[j] != ">" { j += 1 }
                    i = min(j + 1, n)
                    continue
                }

                guard i + 1 < n else { textBuf.append(c); i += 1; continue }
                let next = chars[i+1]

                if next == "/" {
                    // 结束标签
                    var j = i + 2
                    var name = ""
                    while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == ":" {
                        name.append(chars[j]); j += 1
                    }
                    while j < n, chars[j] != ">" { j += 1 }
                    i = min(j + 1, n)
                    flushText()
                    let lower = name.lowercased()
                    // 向上找同名节点关闭
                    if let idx = stack.lastIndex(where: { $0.tag == lower }), idx > 0 {
                        stack.removeSubrange(idx...)
                    }
                    continue
                }

                // 开始标签
                if next.isLetter {
                    var j = i + 1
                    var name = ""
                    while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == ":" {
                        name.append(chars[j]); j += 1
                    }
                    var attrDict: [String: String] = [:]
                    var selfClose = false

                    // 解析属性
                    while j < n {
                        // 跳过空白
                        while j < n, chars[j].isWhitespace { j += 1 }
                        guard j < n else { break }
                        if chars[j] == ">" { j += 1; break }
                        if chars[j] == "/" {
                            if j + 1 < n, chars[j+1] == ">" { selfClose = true; j += 2; break }
                            j += 1; continue
                        }
                        // 属性名
                        var an = ""
                        while j < n, !chars[j].isWhitespace, chars[j] != "=", chars[j] != ">", chars[j] != "/" {
                            an.append(chars[j]); j += 1
                        }
                        if an.isEmpty { j += 1; continue }
                        while j < n, chars[j].isWhitespace { j += 1 }
                        var av = ""
                        if j < n, chars[j] == "=" {
                            j += 1
                            while j < n, chars[j].isWhitespace { j += 1 }
                            if j < n, chars[j] == "\"" || chars[j] == "'" {
                                let quote = chars[j]; j += 1
                                while j < n, chars[j] != quote { av.append(chars[j]); j += 1 }
                                if j < n { j += 1 }
                            } else {
                                while j < n, !chars[j].isWhitespace, chars[j] != ">" {
                                    av.append(chars[j]); j += 1
                                }
                            }
                        }
                        if attrDict[an] == nil {
                            attrDict[an] = decodeEntities(av)
                        }
                    }

                    flushText()
                    let lower = name.lowercased()
                    let node = HNode(tag: lower, attrs: attrDict)
                    node.parent = stack.last
                    stack.last?.children.append(node)
                    i = min(j, n)

                    if voidTags.contains(lower) || selfClose { continue }

                    if rawTags.contains(lower) {
                        // 吞到对应结束标签
                        var k = i
                        var closeTag = "</\(lower)"
                        while k < n {
                            if chars[k] == "<", matchAhead(chars, k, closeTag) {
                                var e = k
                                while e < n, chars[e] != ">" { e += 1 }
                                k = min(e + 1, n)
                                break
                            }
                            k += 1
                        }
                        i = k
                        continue
                    }

                    stack.append(node)
                    continue
                }

                // 不是标签，当普通字符
                textBuf.append(c)
                i += 1
                continue
            }

            textBuf.append(c)
            i += 1
        }
        flushText()
        return root
    }

    private static func matchAhead(_ chars: [Character], _ idx: Int, _ target: String) -> Bool {
        let t = Array(target.lowercased())
        guard idx + t.count <= chars.count else { return false }
        for k in 0..<t.count {
            if chars[idx + k].lowercased() != String(t[k]) { return false }
        }
        return true
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&#160;": " ",
            "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…", "&middot;": "·"
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // 数字实体
        if out.contains("&#") {
            var result = ""
            var i = out.startIndex
            while i < out.endIndex {
                if out[i] == "&", out.index(after: i) < out.endIndex, out[out.index(after: i)] == "#" {
                    var j = out.index(i, offsetBy: 2)
                    var numStr = ""
                    if j < out.endIndex, out[j] == "x" || out[j] == "X" {
                        j = out.index(after: j)
                        while j < out.endIndex, out[j].isHexDigit { numStr.append(out[j]); j = out.index(after: j) }
                        if let code = UInt32(numStr, radix: 16), let scalar = Unicode.Scalar(code) {
                            result.append(Character(scalar))
                        }
                        if j < out.endIndex, out[j] == ";" { j = out.index(after: j) }
                        i = j
                        continue
                    } else {
                        while j < out.endIndex, out[j].isNumber { numStr.append(out[j]); j = out.index(after: j) }
                        if let code = UInt32(numStr), let scalar = Unicode.Scalar(code) {
                            result.append(Character(scalar))
                        }
                        if j < out.endIndex, out[j] == ";" { j = out.index(after: j) }
                        i = j
                        continue
                    }
                }
                result.append(out[i])
                i = out.index(after: i)
            }
            out = result
        }
        return out
    }
}
