/** @type {import('./_venera_.js')} */
// 酷笔漫画 (kubb.cc) 书源
// 来源：2026-10-04 用户提供 /user/login 后实测。
//
// ★ 站点最特殊的坑：按 UA 分流，桌面 UA 一律 403 Forbidden（nginx 层）。
//   桌面 Chrome UA → 403（915 字节）
//   iPhone Safari UA → 200（46KB）
//   所以 headers 里必须写 iPhone UA，改成桌面 UA 这个源直接死。
//
// 站点结构（实测）：
//   全部分类 : /dir/0/0/1/1?page=N     （每页 30 本，page 参数有效）
//   分类树   : /dir/{a}/{b}/{c}/{d}
//   漫画详情 : /byf/{书拼音}.html       ← 详情与分类同路径格式，都是 /byf/xxx.html
//   章节     : /evf/{书拼音}/{章节拼音}.html
//   图片     : 章节页内 <img src="https://{p|t}.wx4.top/cdn/...">，标准 WebP 直链
//             ⚠️ 图床**子域名不固定**（p.wx4.top / t.wx4.top 都见过）→ 必须匹配整个 wx4.top 域
//             ⚠️ 文件名是哈希（1669065588bf604042da50d06f239d6f_zb.webp），**没有页码**，
//               不能按数字排序，HTML 出现顺序即阅读顺序
//             实测 62KB~435KB/张，**不校验 referer**（带与不带都是 200）
//   404 页   : 带 <meta http-equiv="refresh" content="2; url=/">，会自动跳首页
//
// 站点**没有搜索功能**（/search、/so、/find、/sitemap 全 404，JS 里也没有搜索端点）。
// sitemap/comic/{n}.xml 是无限分片（每片 2000 条）且只有拼音 URL 没有书名，不可用。
// 故 search.load 走「抓全部分类页建索引 → 客户端按书名筛选」，30 页 ≈ 900 本，缓存 24h。
//
// 详情页用标准 Open Graph 漫画协议，字段很好解析：
//   og:comic:book_name / og:comic:author / og:comic:category / og:comic:status
//   og:comic:update_time / og:comic:latest_chapter_name / og:comic:latest_chapter_url
class Kubb extends ComicSource {
  name = '酷笔漫画';
  key = 'kubb';
  version = '1.0.1';
  minAppVersion = '1.4.0';
  url = 'https://cdn.jsdelivr.net/gh/lll152872/venera-lll@master/book%20source/kubb.js';

  baseUrl = 'https://www.kubb.cc';
  imgHost = 'https://wx4.top'; // 图床域（子域名不固定：p. / t. 等）
  listUrl = this.baseUrl + '/dir/0/0/1/1'; // 全部分类
  indexPages = 30; // 抓多少页建索引（30 × 30 = 900 本）

  // ⚠️ 必须 iPhone UA，桌面 UA 403
  headers = {
    'user-agent':
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1',
    accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'accept-language': 'zh-CN,zh;q=0.9',
  };

  abs(u) {
    if (!u) return '';
    if (u.indexOf('http') === 0) return u;
    if (u.indexOf('//') === 0) return 'https:' + u;
    return this.baseUrl + (u.charAt(0) === '/' ? '' : '/') + u;
  }

  get(url) {
    return Network.get(this.abs(url), this.headers);
  }

  // 从分类/索引页提取漫画卡片：<a href="/byf/{slug}.html">…书名…</a>
  parseComics(html) {
    let doc = new HtmlDocument(html);
    let seen = new Set();
    let comics = [];
    for (let a of doc.querySelectorAll('a')) {
      let href = a.attributes['href'] || '';
      let m = href.match(/\/byf\/([a-z0-9_]+)\.html$/i);
      if (!m) continue;
      let slug = m[1];
      if (seen.has(slug)) continue;
      let img = a.querySelector('img');
      // 书名：img 的 alt 优先（实测 alt 常为空），否则取链接文本
      let title = '';
      if (img) title = (img.attributes['alt'] || '').trim();
      if (!title) title = (a.text || '').trim();
      if (!title) continue;
      let cover = '';
      if (img) cover = this.abs(img.attributes['data-src'] || img.attributes['src'] || '');
      seen.add(slug);
      comics.push(new Comic({ id: slug, title: title, cover: cover, subTitle: '', description: '' }));
    }
    return comics;
  }

  explore = [
    {
      title: this.name,
      type: 'singlePageWithMultiPart',
      load: async (page) => {
        let res = await this.get(this.listUrl);
        if (res.status !== 200) throw 'Invalid status: ' + res.status;
        return { 最新: this.parseComics(res.body) };
      },
    },
  ];

  // 分类：站点 /dir/{国别}/{分类}/{排序}/{页码}
  // ★ 结构必须严格对齐 App 的 _loadCategoryData()（lib/foundation/comic_source/parser.dart:430）：
  //   category.title 必填字符串（缺了 App 直接 return null，整个分类页看不到这个源）
  //   parts[].name（不是 title）、parts[].type='fixed'、parts[].itemType='category'
  //   categories 与 categoryParams 长度必须相等
  //
  // ⚠️ 为什么硬编码而不运行时抓：App 在 parser.dart 里是
  //   `runCode("...init()")` **同步调用、不 await Promise**，紧接着同步解析 category。
  //   所以异步抓分类来不及（首次进分类页仍只有「全部」），init() 里抓也不行。
  //   下面这份是 2026-10-04 实测的完整 61 个分类，categories 与 categoryParams 严格一一对应。
  //   ensureCategories() 会在用户打开分类页时异步刷新并写回，站点改版后能自愈。
  category = {
    title: this.name,
    parts: [
      {
        name: '酷笔分类',
        type: 'fixed',
        itemType: 'category',
        categories: [
          '全部', '热血', '冒险', '动作', '都市', '恋爱', '彩虹', '日漫', '校园', '玄幻',
          '高H', '待分类', '韩漫', '生', '架空', '耽美', '悬疑', '年下攻', '后宫', '甜文',
          '漫画', '励志', '同人', '腹黑攻', '短篇', '健气受', '竞技', '恐怖', '清水', 'ABO',
          '穿越', '古风', '诱受', '可爱受', '霸总', '科幻', '美人受', '傲娇受', '战争', '青梅竹马',
          '灵异', '总裁', '壮受', '淫荡受', '巨屌', '兽耳', '办公室恋情', '美人攻', '忠犬攻', '奇幻',
          '生活', '修真', '纯爱', '异能', '正太', 'Sm', '灵', '巨乳',
        ],
        categoryParams: [
          '0/0/1/1', '0/2/1/1', '0/3/1/1', '0/4/1/1', '0/5/1/1', '0/6/1/1', '0/7/1/1', '0/8/1/1', '0/9/1/1', '0/10/1/1',
          '0/11/1/1', '0/12/1/1', '0/13/1/1', '0/14/1/1', '0/15/1/1', '0/16/1/1', '0/17/1/1', '0/18/1/1', '0/19/1/1', '0/20/1/1',
          '0/21/1/1', '0/22/1/1', '0/23/1/1', '0/24/1/1', '0/25/1/1', '0/26/1/1', '0/27/1/1', '0/28/1/1', '0/29/1/1', '0/30/1/1',
          '0/31/1/1', '0/32/1/1', '0/33/1/1', '0/34/1/1', '0/35/1/1', '0/36/1/1', '0/37/1/1', '0/38/1/1', '0/39/1/1', '0/40/1/1',
          '0/41/1/1', '0/42/1/1', '0/43/1/1', '0/44/1/1', '0/45/1/1', '0/46/1/1', '0/47/1/1', '0/48/1/1', '0/49/1/1', '0/50/1/1',
          '0/51/1/1', '0/52/1/1', '0/53/1/1', '0/55/1/1', '0/56/1/1', '0/57/1/1', '0/58/1/1', '0/59/1/1',
        ],
      },
    ],
    enableRankingPage: false,
  };

  // 异步刷新分类（打开分类页时触发）。写回 parts[0] 的两个数组。
  // 抓不到就保持硬编码那份，不影响使用。
  async ensureCategories() {
    if (this._cats && this._cats.length > 1) return this._cats;
    let names = [];
    let params = [];
    try {
      let res = await this.get(this.listUrl);
      if (res.status === 200) {
        let doc = new HtmlDocument(res.body);
        let seen = new Set(['0/0/1/1']);
        for (let a of doc.querySelectorAll('a')) {
          let href = a.attributes['href'] || '';
          let m = href.match(/\/dir\/(\d+\/\d+\/\d+\/\d+)/);
          if (!m) continue;
          let key = m[1];
          if (seen.has(key)) continue;
          let name = (a.text || a.attributes['title'] || '').trim();
          if (!name || name.length > 6) continue; // 过滤「全部分类」等导航标题
          seen.add(key);
          names.push(name);
          params.push(key);
        }
      }
    } catch (e) {
      // 忽略，用硬编码那份
    }
    // 只有抓到的比硬编码那份更多才覆盖（避免站点临时异常导致分类变少）
    if (names.length > this.category.parts[0].categories.length) {
      this.category.parts[0].categories = ['全部', ...names];
      this.category.parts[0].categoryParams = ['0/0/1/1', ...params];
    }
    this._cats = this.category.parts[0].categories;
    return this._cats;
  }

  categoryComics = {
    load: async (category, param, options, page) => {
      let key = param || '0/0/1/1';
      // 后台异步刷新分类名（不阻塞本次加载）
      this.ensureCategories();
      let res = await this.get('/dir/' + key + (page > 1 ? '?page=' + page : ''));
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      return { comics: this.parseComics(res.body) };
    },
  };

  search = {
    load: async (keyword, options, page) => {
      let kw = String(keyword || '').trim();
      if (!kw) return { comics: [], maxPage: 1 };
      // 站点无搜索，只能本地索引筛；仅第一页做筛选，后续页交给客户端翻页
      if (page > 1) return { comics: [], maxPage: 1 };
      let lib = await this.getIndex();
      let k = kw.toLowerCase();
      let hit = [];
      for (let i = 0; i < lib.length; i++) {
        if (String(lib[i][1]).toLowerCase().indexOf(k) >= 0) {
          hit.push(new Comic({ id: lib[i][0], title: lib[i][1], cover: '', subTitle: '', description: '' }));
        }
      }
      // 完全相等 > 前缀 > 标题短
      hit.sort((a, b) => {
        let ta = a.title.toLowerCase();
        let tb = b.title.toLowerCase();
        let sa = (ta === k ? 0 : ta.indexOf(k) === 0 ? 1 : 2) * 1000 + ta.length;
        let sb = (tb === k ? 0 : tb.indexOf(k) === 0 ? 1 : 2) * 1000 + tb.length;
        return sa - sb;
      });
      return { comics: hit, maxPage: 1 };
    },
  };

  // 索引缓存：[[slug, title], ...]，24 小时内复用
  async getIndex() {
    let cache = this.loadData('index');
    if (cache && cache.d && Date.now() - cache.d < 24 * 3600 * 1000 && Array.isArray(cache.l) && cache.l.length > 100) {
      return cache.l;
    }
    let seen = new Map();
    let batch = 6;
    for (let i = 1; i <= this.indexPages; i += batch) {
      let jobs = [];
      for (let p = i; p < i + batch && p <= this.indexPages; p++) {
        jobs.push(
          this.get(this.listUrl + '?page=' + p)
            .then((res) => {
              if (res.status !== 200) return;
              for (let c of this.parseComics(res.body)) {
                if (c.id && c.title && !seen.has(c.id)) seen.set(c.id, c.title);
              }
            })
            .catch(() => {}),
        );
      }
      await Promise.all(jobs);
    }
    let list = Array.from(seen.entries());
    if (list.length > 50) {
      try {
        this.saveData('index', { d: Date.now(), l: list });
      } catch (e) {
        // 缓存写失败不影响本次搜索
      }
    }
    return list;
  }

  comic = {
    loadInfo: async (id) => {
      let res = await this.get('/byf/' + id + '.html');
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let html = res.body;
      // OG 漫画协议（实测字段齐全，比解析正文稳）
      let og = (p) => {
        let m = html.match(new RegExp('<meta[^>]+property=["\']' + p + '["\'][^>]+content=["\']([^"\']*)["\']', 'i'));
        if (m) return this.unesc(m[1]);
        // 属性顺序可能相反
        m = html.match(new RegExp('<meta[^>]+content=["\']([^"\']*)["\'][^>]+property=["\']' + p + '["\']', 'i'));
        return m ? this.unesc(m[1]) : '';
      };
      let title = og('og:comic:book_name') || og('og:title');
      if (!title) {
        let m = html.match(/<h1[^>]*>([^<]{1,60})</i);
        title = m ? m[1].trim() : id;
      }
      let cover = og('og:image');
      let author = og('og:comic:author') || og('og:author');
      let category = og('og:comic:category');
      let status = og('og:comic:status');
      let desc = og('og:description') || og('og:comic:description');
      let updateStr = og('og:comic:update_time');
      let latest = og('og:comic:latest_chapter_name');

      // 章节：/evf/{书slug}/{章节slug}.html，默认倒序 → 反转正序
      let chMap = new Map();
      let order = [];
      let re = /\/evf\/([a-z0-9_]+)\/([a-z0-9_]+)\.html/gi;
      let m;
      let nameByUrl = {};
      let reName = /\/evf\/[a-z0-9_]+\/[a-z0-9_]+\.html[^>]*>([^<]{1,40})/gi;
      while ((m = reName.exec(html)) !== null) {
        let v = this.unesc(m[1]).trim();
        if (v) nameByUrl[m[0]] = v;
      }
      while ((m = re.exec(html)) !== null) {
        let url = m[0];
        if (chMap.has(url)) continue;
        let name = nameByUrl[url] || latest || m[2];
        chMap.set(url, name);
        order.push(url);
      }
      order.reverse();

      let chapters = new Map();
      for (let u of order) chapters.set(u, chMap.get(u));

      let ts = 0;
      if (updateStr) {
        let t = Date.parse(updateStr.replace(/-/g, '/'));
        if (!isNaN(t)) ts = t;
      }

      let tags = {};
      if (category && category !== '待分类') tags['分类'] = category;
      if (author) tags['作者'] = author;
      if (status) tags['状态'] = status;

      return new ComicDetails({
        title: title,
        cover: cover ? this.abs(cover) : '',
        description: desc,
        tags: tags,
        chapters: chapters,
        updateTime: ts || Date.now(),
        maxPage: chapters.size,
      });
    },

    loadEp: async (comicId, epId) => {
      // epId 就是 /evf/... 完整路径
      let res = await this.get(epId);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let html = res.body;
      // 图床子域名不固定（实测 p.wx4.top / t.wx4.top 都用），所以匹配整个 wx4.top 域。
      // 文件名是哈希（1669065588bf604042da50d06f239d6f_zb.webp），**没有页码**，
      // 不能按数字排序 —— HTML 里的出现顺序就是正确阅读顺序。
      let imgs = [];
      let seen = new Set();
      let re = /https?:\/\/[a-z0-9-]+\.wx4\.top\/[^"'\s<>\\]+?\.(?:jpg|jpeg|png|webp)/gi;
      let m;
      while ((m = re.exec(html)) !== null) {
        let u = m[0];
        if (seen.has(u)) continue;
        seen.add(u);
        imgs.push(u);
      }
      if (!imgs.length) throw '未解析到图片';
      return { images: imgs };
    },
  };

  onImageLoad(imageKey, comicId, ep) {
    // 实测不校验 referer，仍带上站点头更稳
    return { headers: { Referer: this.baseUrl + '/' } };
  }

  // HTML 实体反转义（书名里常有 &#43; 之类）
  unesc(s) {
    if (!s) return '';
    return String(s)
      .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
      .replace(/&#x([0-9a-f]+);/gi, (_, hx) => String.fromCharCode(parseInt(hx, 16)))
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .trim();
  }
}
