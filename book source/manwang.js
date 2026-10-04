/** @type {import('./_venera_.js')} */
// 漫网 (manwang.net) 书源
// 站点结构（2026-10-04 实测）：
//   更新列表  : https://www.manwang.net/custom/update/page/{n}/      30 本/页
//   分类列表  : https://www.manwang.net/category/tags/{tagId}/page/{n}/
//   详情      : https://www.manwang.net/book/{comicId}              纯 HTML，章节全在页内
//   章节      : https://www.manwang.net/chapter/{comicId}-{chapterId}
//
// 图片解密（关键）：
//   章节页 HTML 里 `var tpl_path='...', params='<base64>'`，
//   params 由 /template/pc/33/js/pic-v2.js 的 decryptParams() 做 AES-128-CBC 解密。
//   密钥从该 js 的 jsjiami 混淆里还原（已验证）：9S8$vJnU2ANeSRoF
//   步骤：raw = base64decode(params); iv = raw[0:16]; ciphertext = raw[16:]
//   → 明文 JSON，含 host / source_id / comic_id / chapter_id / images[]。
//   ⚠️ 排查坑：用 CryptoJS hook 打出来的 "IV" 是 64 字节，别照抄。
//      那 64 字节 = iv[16:] 与 ciphertext 前 48 字节的重叠（CBC 只用 iv 前 16 字节），
//      按 16 字节切才解得开。截出来的 64 字节 IV 会直接抛 "Invalid initialization vector"。
//
// 图片防盗链（硬性要求，实测）：
//   图床 dmw.546457.xyz 必须带 `Referer: https://www.manwang.net/`（站点根，不能带路径）才返回 200，
//   缺 referer 或换成其它 referer 一律 403 text/html。
//   图片本身是明文 WebP（source_id=15 不触发 decryptImage 的图片 AES 解密）。
//   站点另有 img1.baipiaoguai.org 兜底域名，仅 source_id==12 时用，本源实测不需要。
//
// ⚠️ 站内搜索已失效：/search/{kw}、/index.php/search?key= 对任意书名都返回
//    "搜索结果（0）"（2026-10-04 多关键词实测，索引已废），故 search 直接抛错，
//    改用分类页浏览。
//
// ⚠️ 部分书已下架：/book/{id} 会 302 到 /err/comic，getHtml 已跟随并转成可读报错。
class ManWang extends ComicSource {
  name = '漫网';
  key = 'manwang';
  version = '1.0.0';
  minAppVersion = '1.4.0';
  url = 'https://cdn.jsdelivr.net/gh/lll152872/venera-lll@master/book%20source/manwang.js';

  baseUrl = 'https://www.manwang.net';
  // 图片防盗链需要的 Referer（站点根，不能带路径）
  imgReferer = 'https://www.manwang.net/';
  // 章节页 params 的 AES-128-CBC 密钥（从 pic-v2.js 混淆还原并实测验证）
  paramsKey = '9S8$vJnU2ANeSRoF';

  headers = {
    'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  };

  // 分类 id → 名称。
  // ⚠️ 不要硬编码 tagId：站点有 600+ 个标签且 id 与名称的对应关系无法凭直觉猜
  //    （例：2583 是「编剧」不是「恋爱」，2585 才是「玄幻」）。
  //    这里在 init 后首次访问分类页时动态抓取，站点改 id 也能自适应。
  //    下面只是首屏兜底（分类页请求失败时至少还能用）。
  fallbackTags = {
    2585: '玄幻',
    2597: '系统',
    2573: '穿越',
    2586: '修仙',
    2592: '战斗',
    2600: '悬疑',
    2617: '恋爱',
    2613: '爱情',
    2618: '同人',
    2686: '热门漫画',
    3043: '完结',
    2660: '连载中',
  };
  // 运行时抓到的 tag 缓存：id → 名称
  tagCache = {};
  tagsFetched = false;
  // 分类页 / 更新页 总页数上限（分页条尾页显示 50）
  maxPageCount = 50;

  init() {
    this.logger = {
      error: (msg) => { log('error', this.name, msg); },
      info: (msg) => { log('info', this.name, msg); },
      warn: (msg) => { log('warning', this.name, msg); },
    };
    // App 在 Future.delayed(50ms) 里调 init()，分类页打开远晚于此，
    // 这里把抓到的 600+ 标签直接写回 category.parts[0]，让 App 读到完整分类。
    return this.ensureTags().then(() => {
      let opts = [];
      let seen = new Set();
      for (let id in this.tagCache) {
        let name = this.tagCache[id];
        if (seen.has(name)) continue;
        seen.add(name);
        opts.push({ id: id, name: name });
      }
      if (opts.length > 0 && this.category && this.category.parts && this.category.parts[0]) {
        this.category.parts[0].categories = opts.map((o) => o.name);
        this.category.parts[0].categoryParams = opts.map((o) => o.id);
        this.logger.info(`分类表就绪：${opts.length} 个分类`);
      }
    }).catch((e) => {
      this.logger.warn('初始化分类表失败，保留兜底: ' + e);
    });
  }

  // GET 一个 HTML 页面，返回 body；跟随 3xx，遇下架页转成可读报错
  async getHtml(url, depth = 0) {
    if (depth > 4) throw '重定向次数过多';
    let res = await Network.get(url, this.headers);
    // App 的 Network.get 会自动跟随 3xx，所以下架 book's 302→/err/comic 会变成
    // 「200 + 165 字节错误页」。先按 status 判（未跟随时有效），再按 body 特征兜底判。
    if (res.status >= 300 && res.status < 400) {
      let loc = '';
      if (res.headers) loc = res.headers['location'] || res.headers['Location'] || '';
      if (loc.indexOf('/err/') >= 0) throw '漫画不存在或已下架';
      if (loc) {
        if (loc.indexOf('http') !== 0) {
          loc = this.baseUrl + (loc.indexOf('/') === 0 ? '' : '/') + loc;
        }
        return this.getHtml(loc, depth + 1);
      }
    }
    if (res.status !== 200) throw 'Invalid status code: ' + res.status;
    // 已跟随重定向的下架页：内容极短且不含详情页特征
    if (res.body && res.body.length < 600 && res.body.indexOf('detail-title') < 0) {
      throw '漫画不存在或已下架';
    }
    return res.body;
  }

  // 章节页 params → 明文 JSON（AES-128-CBC）
  // pic-v2.js 语义：raw = base64decode(params)；iv = raw[0:16]；密文 = raw[16:]
  //
  // ⚠️ 传字节必须用 `.buffer`：Dart 端 CBCBlockCipher 只认 Uint8List，
  //    直接传普通数组会变 List<dynamic>、传 Uint8Array 会变 Map，都报类型错。
  //    同理别用 String.fromCharCode 拼 latin1 再传 —— 字节 ≥0x80 时 JS 字符串按
  //    UTF-16 存，Dart 侧取字节会按 UTF-8 重新编码导致长度膨胀、IV 直接失效。
  decodeParams(params) {
    let raw = Convert.decodeBase64(params);
    if (!raw) throw 'params 为空';
    // 统一成可索引的字节视图
    let view;
    if (raw instanceof ArrayBuffer) {
      view = new Uint8Array(raw);
    } else if (raw instanceof Uint8Array) {
      view = raw;
    } else if (raw.length !== undefined) {
      view = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) view[i] = raw[i] & 0xff;
    } else {
      throw 'params 解码结果类型异常';
    }
    if (view.length < 32) throw 'params 长度异常';

    let iv = new Uint8Array(16);
    for (let i = 0; i < 16; i++) iv[i] = view[i];
    let ctLen = view.length - 16;
    let ciphertext = new Uint8Array(ctLen);
    for (let i = 0; i < ctLen; i++) ciphertext[i] = view[16 + i];

    // key 是 16 个 ASCII 字符，按字节展开
    let rawKey = this.paramsKey;
    let keyBytes = new Uint8Array(rawKey.length);
    for (let i = 0; i < rawKey.length; i++) keyBytes[i] = rawKey.charCodeAt(i) & 0xff;

    // 优先走 sendMessage（App 真实路径，Dart 端只认 Uint8List）
    // 降级走 Convert.decryptAesCbc（测试工具等只实现了 Convert 的环境）
    // ⚠️ sendMessage 是全局函数，用 typeof 探测；直接引用未定义标识符会 ReferenceError。
    let hasSendMessage = false;
    try { hasSendMessage = typeof sendMessage === 'function'; } catch (e) { hasSendMessage = false; }
    let plain = null;
    if (hasSendMessage) {
      plain = sendMessage({
        method: 'convert',
        type: 'aes-cbc',
        value: ciphertext.buffer,
        key: keyBytes.buffer,
        iv: iv.buffer,
        isEncode: false,
      });
    }
    if (!plain && Convert && typeof Convert.decryptAesCbc === 'function') {
      // ⚠️ 这条降级路径不能把字节拼成 String 再传：字节 ≥0x80 时 JS 字符串按 UTF-16 存，
      //    接收侧取字节会按 UTF-8 重编码导致长度膨胀、IV 直接失效。
      //    传 ArrayBuffer（Uint8Array.buffer）才是字节安全的形态。
      plain = Convert.decryptAesCbc(ciphertext.buffer, keyBytes.buffer, iv.buffer);
    }
    if (!plain) throw 'params 解密失败：AES 接口不可用';

    let pb = plain instanceof ArrayBuffer ? new Uint8Array(plain) : new Uint8Array(plain);
    // ⚠️ Dart 端 aes-cbc 走 CBCBlockCipher.processBlock，不去 PKCS#7 padding，
    //    返回字节尾部带 padding。JSON.parse 遇到尾部垃圾字节会直接抛错，必须自己剥。
    let len = pb.length;
    if (len > 0) {
      let pad = pb[len - 1] & 0xff;
      if (pad >= 1 && pad <= 16 && pad <= len) {
        let ok = true;
        for (let i = len - pad; i < len; i++) {
          if ((pb[i] & 0xff) !== pad) { ok = false; break; }
        }
        if (ok) len = len - pad;
      }
    }
    let text = Convert.decodeUtf8(pb.buffer.slice(0, len));
    return JSON.parse(text);
  }

  // 从列表页提取漫画卡片
  // <li><section class="mod-hitem-comic"><a href="/book/{id}" class="comic-item">
  //   <img data-src="{cover}"><div class="comic-info"><h2>{title}</h2>
  //   <p class="process">{更新至…}</p><div class="tag-list">{tag 空格分隔}</div>
  //   <p class="desc">{简介}</p>
  parseList(html) {
    let doc = new HtmlDocument(html);
    let items = doc.querySelectorAll('a.comic-item');
    let comics = [];
    let seen = new Set();
    for (let i = 0; i < items.length; i++) {
      let a = items[i];
      let href = a.attributes['href'] || '';
      let m = href.match(/\/book\/(\d+)/);
      if (!m) continue;
      let id = m[1];
      if (seen.has(id)) continue;

      let img = a.querySelector('img');
      let title = '';
      let h2 = a.querySelector('h2');
      if (h2) title = h2.text.trim();
      if (!title && img) title = (img.attributes['alt'] || '').trim();
      if (!title) continue;

      let cover = '';
      if (img) cover = img.attributes['data-src'] || img.attributes['src'] || '';

      let subTitle = '';
      let desc = '';
      let ps = a.querySelectorAll('p');
      for (let j = 0; j < ps.length; j++) {
        let cls = ps[j].attributes['class'] || '';
        if (cls.indexOf('process') >= 0) {
          subTitle = ps[j].text.trim();
        } else if (cls.indexOf('desc') >= 0) {
          desc = ps[j].text.trim();
        }
      }
      let tags = [];
      let tagEl = a.querySelector('div.tag-list');
      if (tagEl) {
        let t = tagEl.text.replace(/\s+/g, ' ').trim();
        if (t) tags = t.split(' ');
      }
      seen.add(id);
      comics.push(
        new Comic({
          id: id,
          title: title,
          cover: cover,
          subTitle: subTitle,
          description: desc,
          tags: tags,
        })
      );
    }
    return comics;
  }

  // 分页 URL：第 1 页用不带 /page/1 的形式，>=2 才拼（实测 /page/1/ 也通，但保持与首页一致）
  pageUrl(base, page) {
    if (page <= 1) return `${this.baseUrl}${base}/`;
    return `${this.baseUrl}${base}/page/${page}/`;
  }

  // 从 /category 总页动态抓「tagId → 名称」全表（站点 600+ 标签）
  // 只抓一次并缓存。失败时回落到 fallbackTags。
  async ensureTags() {
    if (this.tagsFetched) return;
    this.tagsFetched = true;
    try {
      let html = await this.getHtml(`${this.baseUrl}/category`);
      // <a href="/category/tags/{id}">{name}</a>
      let re = /\/category\/tags\/(\d+)[^>]*>\s*([^<]{1,16}?)\s*</g;
      let m;
      let found = 0;
      while ((m = re.exec(html)) !== null) {
        let id = m[1];
        let name = m[2].trim();
        if (!name) continue;
        if (this.tagCache[id]) continue;
        this.tagCache[id] = name;
        found++;
      }
      if (found < 10) {
        this.logger.warn(`分类表只抓到 ${found} 条，使用兜底表`);
        this.tagCache = Object.assign({}, this.fallbackTags);
      }
    } catch (e) {
      this.logger.warn('抓取分类表失败，使用兜底表: ' + e);
      this.tagCache = Object.assign({}, this.fallbackTags);
    }
  }

  // 分类选项列表：[{id, name}]，按名称去重（同名不同 id 只留第一个）
  async tagOptions() {
    await this.ensureTags();
    let seen = new Set();
    let out = [];
    for (let id in this.tagCache) {
      let name = this.tagCache[id];
      if (seen.has(name)) continue;
      seen.add(name);
      out.push({ id: id, name: name });
    }
    return out;
  }

  explore = [
    {
      title: '最近更新',
      type: 'multiPart',
      load: async (page) => {
        let html = await this.getHtml(this.pageUrl('/custom/update', page));
        return { comics: this.parseList(html) };
      },
    },
  ];

  category = {
    title: this.name,
    parts: [
      {
        name: '分类',
        type: 'fixed',
        // 分类名与 tagId 一一对应；App 读 categories[i] 传给 categoryComics.load 的 category 参数
        categories: Object.keys(this.fallbackTags).map((id) => this.fallbackTags[id]),
        itemType: 'category',
        categoryParams: Object.keys(this.fallbackTags),
        // 动态抓到的完整表在运行时补进来（见 ensureCategoryOptions）
      },
    ],
    enableRankingPage: false,
  };

  categoryComics = {
    load: async (category, param, options, page) => {
      let pn = page || 1;
      if (pn > this.maxPageCount) return { comics: [], maxPage: this.maxPageCount };
      // param 传的是 tagId（与 category.categoryParams 一一对应）
      let tagId = String(param);
      if (!/^\d+$/.test(tagId)) {
        // 容错：万一传进来的是名称，反查一次
        await this.ensureTags();
        let found = '';
        for (let id in this.tagCache) {
          if (this.tagCache[id] === tagId) { found = id; break; }
        }
        if (!found) return { comics: [], maxPage: 1 };
        tagId = found;
      }
      let html = await this.getHtml(this.pageUrl(`/category/tags/${tagId}`, pn));
      return { comics: this.parseList(html), maxPage: this.maxPageCount };
    },
    optionList: [],
  };

  // 站内搜索索引已失效（任意关键词均 0 结果），明确报错而不是静默返回空
  search = {
    load: async (keyword, options, page) => {
      throw '漫网站内搜索已失效，请在分类页浏览';
    },
    optionList: [],
  };

  comic = {
    loadInfo: async (id) => {
      let html = await this.getHtml(`${this.baseUrl}/book/${id}`);
      let doc = new HtmlDocument(html);

      let title = '';
      let t = doc.querySelector('h1.detail-title');
      if (t) title = t.text.trim();

      let author = '';
      let au = doc.querySelector('p.author');
      if (au) author = au.text.trim();

      let cover = '';
      let cimg = doc.querySelector('div.banner-img img');
      if (cimg) cover = cimg.attributes['data-src'] || cimg.attributes['src'] || '';

      let desc = '';
      let de = doc.querySelector('div.detail-desc');
      if (de) desc = de.text.trim();

      // 更新至：<span>更新至:第413话 欢迎来到地球</span>
      let updateTime = '';
      let spans = doc.querySelectorAll('span');
      for (let i = 0; i < spans.length; i++) {
        let tx = spans[i].text.trim();
        if (tx.indexOf('更新至') === 0) {
          updateTime = tx.replace('更新至:', '').trim();
          break;
        }
      }

      // 标签：<div class="detail-info-btags"><div class="tag-list"><a>玄幻</a>…
      let tagList = [];
      let tagBox = doc.querySelector('div.detail-info-btags div.tag-list');
      if (!tagBox) tagBox = doc.querySelector('div.tag-list');
      if (tagBox) {
        let as = tagBox.querySelectorAll('a');
        for (let i = 0; i < as.length; i++) {
          let tx = as[i].text.trim();
          if (tx) tagList.push(tx);
        }
      }
      let tags = {};
      if (tagList.length > 0) tags['分类'] = tagList;
      if (author) tags['作者'] = [author];

      // 章节：<ol class="chapter-list" id="j_chapter_list">
      //   <li class="item" data-id="1" data-chapter="161408">
      //     <a title="00 诸天最强神祇" href="/chapter/507169-161408"><p class="name">…</p></a>
      // 页内 li 已是正序（第 1 话在前），直接按 DOM 顺序取。
      let chapters = new Map();
      let list = doc.querySelector('ol.chapter-list');
      if (list) {
        let lis = list.querySelectorAll('li');
        for (let i = 0; i < lis.length; i++) {
          let li = lis[i];
          let cid = li.attributes['data-chapter'];
          if (!cid) continue;
          let name = '';
          let a = li.querySelector('a');
          if (a) name = (a.attributes['title'] || a.text || '').trim();
          if (!name) {
            let p = li.querySelector('p.name');
            if (p) name = p.text.trim();
          }
          // <i class="j_chapter_badge"> 徽标会混进 text，title 属性更干净
          if (!name) name = cid;
          chapters.set(cid, name);
        }
      }
      if (chapters.size === 0) {
        // 走到这里说明页面正常但没章节区：多为该书被站点清空章节（页面还在、内容没了）
        throw '未解析到章节，该书可能已停更或被清空';
      }

      return new ComicDetails({
        title: title,
        subTitle: author,
        cover: cover,
        description: desc,
        tags: tags,
        chapters: chapters,
        updateTime: updateTime,
      });
    },

    loadEp: async (comicId, epId) => {
      let html = await this.getHtml(`${this.baseUrl}/chapter/${comicId}-${epId}`);
      let m = html.match(/params\s*=\s*'([^']+)'/);
      if (!m) throw '章节页未找到 params，结构可能已变';
      let info = this.decodeParams(m[1]);
      if (!info || !info.images || info.images.length === 0) throw '解密后无图片';
      return { images: info.images };
    },

    // 图床防盗链：必须带站点 referer，否则 403
    onImageLoad: (imageKey, comicId, ep) => {
      return {
        headers: {
          'User-Agent': this.headers['user-agent'],
          Referer: this.imgReferer,
        },
      };
    },
  };
}
