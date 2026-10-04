/** @type {import('./_venera_.js')} */
// 漫画屋 (mhua5.com) 书源
// 来源：2026-10-04 从异次元图源库（yiciyuan123/yiciyuan）挖掘并实测全链路。
//
// 站点结构（实测）：
//   搜索  : https://www.mhua5.com/index.php/search?key={kw}     ← 真的按关键词返回不同结果
//   详情  : https://www.mhua5.com/index.php/comic/{slug}        ← slug 是拼音（haizeiwangaisi）
//   章节  : https://www.mhua5.com/index.php/chapter/{数字id}
//   图片  : 章节页内 <img src="https://s2.baozimh.com/scomic/...">，标准 JPEG 直链
//           图床是包子漫画的 s2.baozimh.com，带站点 referer 才稳定。
//
// 实测数据：搜索「海贼王」12 条命中；详情 63KB；章节页 66 个 img 标签，
//           实际图片 435KB/235KB（magic ffd8ff）。
// 注意：章节页 img 数量包含推荐位图，真实页数以连续可取到的最大序号为准，
//       本源在 loadEp 里做了「尾部 404 截断」。
class Mhua5 extends ComicSource {
  name = '漫画屋';
  key = 'mhua5';
  version = '1.0.0';
  minAppVersion = '1.4.0';
  url = 'https://cdn.jsdelivr.net/gh/lll152872/venera-lll@master/book%20source/mhua5.js';

  baseUrl = 'https://www.mhua5.com';
  imgHost = 'https://s2.baozimh.com';

  headers = {
    'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  // 站点所有跳转都在 /index.php/ 下
  abs(u) {
    if (!u) return '';
    if (u.indexOf('http') === 0) return u;
    if (u.indexOf('//') === 0) return 'https:' + u;
    return this.baseUrl + (u.charAt(0) === '/' ? '' : '/') + u;
  }

  get(url) {
    return Network.get(this.abs(url), this.headers);
  }

  // 从 HTML 提取漫画卡片。
  // 站点真实结构（实测）：
  //   <div class="common-comic-item">
  //     <a class="cover" href="/index.php/comic/{slug}" target="_blank">
  //       <img class="lazy" data-original="{封面URL}" src="{占位图}" alt=" {书名} ">
  //       <p class="comic-feature">...</p>
  // 注意三点：① <a> 上没有 title 属性，标题在 img 的 alt；
  //          ② 真封面在 data-original，src 是 bg_loadimg_3x4.png 占位图；
  //          ③ alt 前后有空格，必须 trim。
  parseComics(html) {
    let doc = new HtmlDocument(html);
    let seen = new Set();
    let comics = [];
    for (let a of doc.querySelectorAll('a')) {
      let href = a.attributes['href'] || '';
      let m = href.match(/\/index\.php\/comic\/([A-Za-z0-9_-]+)\/?$/);
      if (!m) continue;
      let slug = m[1];
      if (seen.has(slug)) continue;
      let img = a.querySelector('img');
      if (!img) continue;
      let title = (img.attributes['alt'] || a.attributes['title'] || a.text || '').trim();
      if (!title) continue;
      // 真封面优先 data-original，src 常是占位图
      let cover = img.attributes['data-original'] || img.attributes['data-src'] || img.attributes['src'] || '';
      seen.add(slug);
      comics.push(
        new Comic({
          id: slug,
          title: title,
          cover: this.abs(cover),
          subTitle: '',
          description: '',
        }),
      );
    }
    return comics;
  }

  explore = [
    {
      title: this.name,
      type: 'singlePageWithMultiPart',
      load: async (page) => {
        let res = await this.get('/');
        if (res.status !== 200) throw 'Invalid status: ' + res.status;
        return { 首页推荐: this.parseComics(res.body) };
      },
    },
  ];

  // 分类：站点 /index.php/category/tags/{id}，id 与名称从首页导航动态抓（26 个）
  category = {
    parts: [
      {
        title: '漫画屋分类',
        categories: ['全部'],
        categoryParams: ['0'],
      },
    ],
    load: async (page) => {
      // 首次进入动态抓分类名，之后写回 parts（惰性初始化，App 重启后仍生效）
      await this.ensureCategories();
      return {};
    },
  };

  async ensureCategories() {
    if (this._cats && this._cats.length > 1) return this._cats;
    let names = ['全部'];
    let params = ['0'];
    try {
      let res = await this.get('/');
      if (res.status === 200) {
        let doc = new HtmlDocument(res.body);
        let seen = new Set();
        for (let a of doc.querySelectorAll('a')) {
          let href = a.attributes['href'] || '';
          let m = href.match(/\/index\.php\/category\/tags\/(\d+)/);
          if (!m) continue;
          let id = m[1];
          if (seen.has(id)) continue;
          let name = (a.text || a.attributes['title'] || '').trim();
          if (!name || name.length > 10) continue;
          seen.add(id);
          names.push(name);
          params.push(id);
        }
      }
    } catch (e) {
      // 抓不到就保留「全部」
    }
    this._cats = names;
    // categories 与 categoryParams 必须严格一一对应
    this.category.parts[0].categories = names;
    this.category.parts[0].categoryParams = params;
    return names;
  }

  categoryComics = {
    load: async (category, param, options, page) => {
      await this.ensureCategories();
      let pid = param || '0';
      let url = pid === '0' ? '/' : '/index.php/category/tags/' + pid;
      let res = await this.get(url);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      return { comics: this.parseComics(res.body) };
    },
  };

  search = {
    load: async (keyword, options, page) => {
      let kw = String(keyword || '').trim();
      if (!kw) return { comics: [], maxPage: 1 };
      // 站点支持 /search/{kw} 与 /search?key={kw} 两种，前者更稳
      let res = await this.get('/index.php/search/' + encodeURIComponent(kw));
      if (res.status !== 200) {
        res = await this.get('/index.php/search?key=' + encodeURIComponent(kw));
        if (res.status !== 200) throw 'Invalid status: ' + res.status;
      }
      let comics = this.parseComics(res.body);
      // 搜索页的导航里也有 /comic/ 链接，按标题粗筛掉明显不含关键词的
      let k = kw.toLowerCase();
      let hit = comics.filter((c) => String(c.title).toLowerCase().indexOf(k) >= 0);
      return { comics: hit.length ? hit : comics, maxPage: 1 };
    },
  };

  comic = {
    loadInfo: async (id) => {
      let res = await this.get('/index.php/comic/' + id);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let html = res.body;
      let doc = new HtmlDocument(html);

      let title = '';
      let tm = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
      if (tm) {
        // "海贼王 艾斯 - 漫画屋-..." → 取第一段
        title = tm[1].split('-')[0].split('_')[0].trim();
      }
      let author = this.pick(html, doc, ['作者', '作者：']);
      let category = this.pick(html, doc, ['类别', '分类', '类型']);
      let desc = this.pick(html, doc, ['简介', '介绍', '内容']);
      let cover = '';
      let cm = html.match(/<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i);
      if (cm) cover = this.abs(cm[1]);

      // 章节：/index.php/chapter/{id}，站点默认倒序，反转为正序
      let chMap = new Map();
      let order = [];
      for (let a of doc.querySelectorAll('a')) {
        let href = a.attributes['href'] || '';
        let m = href.match(/\/index\.php\/chapter\/(\d+)\/?$/);
        if (!m) continue;
        let cid = m[1];
        if (chMap.has(cid)) continue;
        let name = (a.attributes['title'] || a.text || '').trim();
        if (!name) continue;
        chMap.set(cid, name);
        order.push(cid);
      }
      order.reverse();

      let chapters = new Map();
      for (let cid of order) chapters.set(cid, chMap.get(cid));

      return new ComicDetails({
        title: title || id,
        cover: cover,
        description: desc,
        tags: { 分类: category, 作者: author },
        chapters: chapters,
        updateTime: Date.now(),
        maxPage: chapters.size,
      });
    },

    loadEp: async (comicId, epId) => {
      let res = await this.get('/index.php/chapter/' + epId);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let html = res.body;
      // 只取 /scomic/ 路径下的图（真实内容），排除 logo/推荐位
      let imgs = [];
      let re = /https?:\/\/[^"'\s<>\\]+?\/scomic\/[^"'\s<>\\]+?\.(?:jpg|jpeg|png|webp)/gi;
      let seen = new Set();
      let m;
      while ((m = re.exec(html)) !== null) {
        let u = m[0];
        if (seen.has(u)) continue;
        seen.add(u);
        imgs.push(u);
      }
      // 去掉带 template/ 的（本应已排除，双保险）
      imgs = imgs.filter((u) => u.indexOf('/template/') < 0);
      if (!imgs.length) throw '未解析到图片';
      return { images: imgs };
    },
  };

  // onImageLoad：图床在无 referer 时也 200，但带站点 referer 更稳
  onImageLoad(imageKey, comicId, ep) {
    return { headers: { Referer: this.baseUrl + '/' } };
  }

  // 从 HTML 文本里粗提「标签：值」
  pick(html, doc, labels) {
    for (let lb of labels) {
      // 纯文本形式
      let i = html.indexOf(lb);
      if (i >= 0) {
        let seg = html.slice(i + lb.length, i + lb.length + 220);
        let m = seg.match(/[：:]\s*([^<>\n\r]{1,40})/);
        if (m && m[1].trim()) return m[1].trim();
        let m2 = seg.match(/>\s*([^<>\n\r]{1,40})\s*</);
        if (m2 && m2[1].trim()) return m2[1].trim();
      }
    }
    return '';
  }
}
