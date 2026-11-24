import Foundation

/// 首次启动写入的内置源。
/// 说明：内置「MangaDex」是真实可用的公开 API 源；
/// 其余为可直接改写的模板（默认关闭），避免用户点了全是失败页。
enum BuiltinSources {

    static var all: [MangaSource] {
        [mangadexZH, mangadexEN, templateHTML, templateJSON, templateMinimal]
    }

    // MARK: - MangaDex 中文

    private static var mangadexZH: MangaSource {
        var s = MangaSource(id: "mangadex-zh", name: "MangaDex 中文")
        s.version = "1.2.0"
        s.lang = .zh
        s.kind = .js
        s.baseURL = "https://mangadex.org"
        s.author = "MangaDex"
        s.desc = "MangaDex 公开 API，筛选简体/繁体中文译本"
        s.enabled = true
        s.builtin = true
        s.order = 0
        s.timeout = 20
        s.headers = ["User-Agent": "MangaReader/1.4 (iOS)"]
        s.script = mangadexScript
        return s
    }

    // MARK: - MangaDex English

    private static var mangadexEN: MangaSource {
        var s = mangadexZH
        s.id = "mangadex-en"
        s.name = "MangaDex English"
        s.lang = .en
        s.desc = "MangaDex 公开 API，英文译本"
        s.order = 1
        s.script = mangadexScript.replacingOccurrences(of: "zh-hk", with: "en")
            .replacingOccurrences(of: "translatedLanguage[]=zh&", with: "translatedLanguage[]=en&")
        return s
    }

    private static let mangadexScript = #"""
// name: MangaDex
// 源约定：search(keyword,page) / detail(url) / chapters(url) / images(chapterUrl)
// 内部 URL 约定：作品 "md:<uuid>"，章节 "mdc:<uuid>"

var API = 'https://api.mangadex.org';
var UP  = 'https://uploads.mangadex.org';
var __tagCache = null;

function __mdId(u) {
  if (!u) return '';
  var s = String(u);
  if (s.indexOf('md:') === 0) return s.substring(3);
  var m = s.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i);
  return m ? m[1] : s;
}

function __pick(obj) {
  if (!obj) return '';
  var k = ['zh', 'zh-hk', 'zh-hans', 'ja', 'en'];
  for (var i = 0; i < k.length; i++) {
    if (obj[k[i]]) return obj[k[i]];
  }
  for (var p in obj) { if (obj[p]) return obj[p]; }
  return '';
}

function __coverOf(m) {
  var rels = m.relationships || [];
  for (var i = 0; i < rels.length; i++) {
    var r = rels[i];
    if (r.type === 'cover_art' && r.attributes && r.attributes.fileName) {
      return UP + '/covers/' + m.id + '/' + r.attributes.fileName + '.512.jpg';
    }
  }
  return '';
}

function __relName(m, type) {
  var rels = m.relationships || [];
  for (var i = 0; i < rels.length; i++) {
    var r = rels[i];
    if (r.type === type && r.attributes && r.attributes.name) return r.attributes.name;
  }
  return '';
}

function __map(list) {
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var m = list[i] || {};
    var a = m.attributes || {};
    out.push({
      url: 'md:' + m.id,
      title: __pick(a.title) || '(无标题)',
      cover: __coverOf(m),
      author: __relName(m, 'author')
    });
  }
  return out;
}

function __query(page, extra) {
  var offset = ((page || 1) - 1) * 20;
  var u = API + '/manga?limit=20&offset=' + offset
        + '&includes[]=cover_art&includes[]=author'
        + '&contentRating[]=safe&contentRating[]=suggestive'
        + '&availableTranslatedLanguage[]=zh&availableTranslatedLanguage[]=zh-hk';
  return u + (extra || '');
}

function __tagId(name) {
  if (!__tagCache) {
    try { __tagCache = JSON.parse(get(API + '/manga/tag')).data || []; }
    catch (e) { __tagCache = []; }
  }
  for (var i = 0; i < __tagCache.length; i++) {
    var n = (__tagCache[i].attributes || {}).name || {};
    if (n['zh'] === name || n['en'] === name || n['ja'] === name) return __tagCache[i].id;
  }
  return '';
}

function search(q, page) {
  var extra = '&order[relevance]=desc';
  if (q) extra += '&title=' + encodeURIComponent(q);
  var r = JSON.parse(get(__query(page, extra)));
  return __map(r.data || []);
}

function category(param, page) {
  var extra = '&order[followedCount]=desc';
  var tid = param ? __tagId(param) : '';
  if (tid) extra += '&includedTags[]=' + tid + '&includedTagsMode=AND';
  var r = JSON.parse(get(__query(page, extra)));
  return __map(r.data || []);
}

function ranking(key, page) {
  var order = 'followedCount';
  if (key === 'new-male' || key === 'new-female') order = 'latestUploadedChapter';
  if (key === 'rising') order = 'rating';
  if (key === 'bestseller') order = 'rating';
  var r = JSON.parse(get(__query(page, '&order[' + order + ']=desc')));
  return __map(r.data || []);
}

function detail(url) {
  var id = __mdId(url);
  var r = JSON.parse(get(API + '/manga/' + id +
    '?includes[]=cover_art&includes[]=author&includes[]=artist'));
  var m = r.data || {};
  var a = m.attributes || {};

  var tags = [];
  var tg = a.tags || [];
  for (var i = 0; i < tg.length; i++) {
    var v = __pick((tg[i].attributes || {}).name);
    if (v) tags.push(v);
  }

  var smap = { ongoing: '连载中', completed: '已完结', hiatus: '休刊中', cancelled: '已停止发布' };

  return {
    url: url,
    title: __pick(a.title) || '(无标题)',
    cover: __coverOf(m),
    author: __relName(m, 'author'),
    desc: stripTags(__pick(a.description)),
    genre: tags.join(' / '),
    status: smap[a.status] || (a.status || '')
  };
}

function chapters(url) {
  var id = __mdId(url);
  var out = [];
  var offset = 0;
  for (var p = 0; p < 4; p++) {
    var u = API + '/manga/' + id + '/feed?limit=500&offset=' + offset
          + '&translatedLanguage[]=zh&translatedLanguage[]=zh-hk'
          + '&order[volume]=asc&order[chapter]=asc'
          + '&includeEmptyPages=0&includeExternalUrl=0';
    var r = JSON.parse(get(u));
    var data = r.data || [];
    for (var i = 0; i < data.length; i++) {
      var c = data[i];
      var ca = c.attributes || {};
      var name = '第 ' + (ca.chapter || '?') + ' 话';
      if (ca.title) name += ' · ' + ca.title;
      out.push({ url: 'mdc:' + c.id, name: name, index: out.length });
    }
    if (data.length < 500) break;
    offset += 500;
  }
  return out;
}

function images(chapterUrl) {
  var id = String(chapterUrl).replace('mdc:', '');
  var r = JSON.parse(get(API + '/at-home/server/' + id));
  var base = r.baseUrl || '';
  var ch = r.chapter || {};
  var hash = ch.hash || '';
  var files = ch.data || [];
  var out = [];
  for (var i = 0; i < files.length; i++) {
    out.push({ url: base + '/data/' + hash + '/' + files[i], referer: 'https://mangadex.org/' });
  }
  return out;
}
"""#

    // MARK: - 模板：通用 HTML 源

    private static var templateHTML: MangaSource {
        var s = MangaSource(id: "template-html", name: "模板 · 通用网页源")
        s.version = "1.0.0"
        s.lang = .zh
        s.kind = .js
        s.baseURL = "https://example.com"
        s.author = "内置"
        s.desc = "把 baseURL 改成目标站域名即可跑；用链接特征猜详情页"
        s.enabled = false
        s.builtin = true
        s.order = 2
        s.script = SourceImporter.genericScript(base: "https://example.com")
        return s
    }

    // MARK: - 模板：JSON 规则源

    private static var templateJSON: MangaSource {
        var r = SourceRules.empty
        r.searchURL = "{base}/search?keyword={keyword}&page={page}"
        r.searchMethod = "GET"
        r.searchList = ".book-list .item"
        r.searchTitle = "h3@title"
        r.searchCover = "img@data-src"
        r.searchLink = "a@href"
        r.searchAuthor = ".author"
        r.detailTitle = "h1"
        r.detailCover = ".cover img@src"
        r.detailAuthor = ".info .author"
        r.detailDesc = ".intro"
        r.detailGenre = ".tags a"
        r.detailStatus = ".status"
        r.chapterList = "#chapter-list a"
        r.chapterName = ""
        r.chapterLink = "@href"
        r.chapterReverse = true
        r.imageList = "#images img"
        r.imageAttr = "data-original"
        r.imageReferer = "{chapterURL}"
        r.categoryURL = "{base}/list/{keyword}/{page}.html"
        r.categoryList = ".book-list .item"
        r.categoryName = "h3@title"

        var s = MangaSource(id: "template-json", name: "模板 · 声明式规则")
        s.version = "1.0.0"
        s.lang = .zh
        s.kind = .json
        s.baseURL = "https://example.com"
        s.author = "内置"
        s.desc = "只写选择器，不用写 JS；括号内为可用占位符"
        s.enabled = false
        s.builtin = true
        s.order = 3
        s.rules = r
        return s
    }

    // MARK: - 模板：最小 JS 源

    private static var templateMinimal: MangaSource {
        var s = MangaSource(id: "template-min", name: "模板 · 最小 JS 源")
        s.version = "1.0.0"
        s.lang = .zh
        s.kind = .js
        s.baseURL = "https://example.com"
        s.author = "内置"
        s.desc = "四个函数的最小骨架，复制后改选择器"
        s.enabled = false
        s.builtin = true
        s.order = 4
        s.script = #"""
// name: 最小源
var BASE = 'https://example.com';

function search(q, page) {
  var html = get(BASE + '/search?q=' + encodeURIComponent(q) + '&page=' + (page || 1));
  var out = [];
  doc(html).find('.item').each(function (i, el) {
    out.push({
      url: abs(el.find('a').attr('href'), BASE),
      title: el.find('h3').text(),
      cover: fixImg(el.find('img').attr('src'), BASE),
      author: el.find('.author').text()
    });
  });
  return out;
}

function detail(url) {
  var d = doc(get(url));
  return {
    url: url,
    title: d.find('h1').first().text(),
    cover: fixImg(d.find('.cover img').attr('src'), url),
    author: d.find('.author').first().text(),
    desc: d.find('.intro').first().text(),
    genre: '',
    status: ''
  };
}

function chapters(url) {
  var out = [];
  doc(get(url)).find('#list a').each(function (i, el) {
    out.push({ url: abs(el.attr('href'), url), name: el.text(), index: i });
  });
  return out;
}

function images(chapterUrl) {
  var out = [];
  doc(get(chapterUrl)).find('#images img').each(function (i, el) {
    out.push({ url: fixImg(el.attr('data-src'), chapterUrl), referer: chapterUrl });
  });
  return out;
}
"""#
        return s
    }
}
