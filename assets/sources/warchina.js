/** @type {import('./_venera_.js')} */
// 虫虫漫画 (warchina.com) 书源
// 站点结构（实测 2026-10-04）：
//   首页    : https://warchina.com/            （div.chong 卡片，无分页）
//   搜索    : https://warchina.com/statics/search.aspx?key=xxx   ← 真实端点
//   ✗ 错误端点 https://warchina.com/search?keyword=xxx 完全不读 keyword，
//     返回的是首页镜像（"JJ韩漫更新"/"更新排行"推荐位），任何关键词都返回同样的 ~84 本。
//     站点 JS b.min.js 里的 All.S() 用的是 /statics/search.aspx?key=，且有
//     `if (All.P=="2") alert("搜索功能暂时关闭")` 分支 —— 实测该端点 200 但结果容器
//     <div class="clearfix"></div> 为空，站点后端已关闭搜索。
//     故 search.load 走「站内索引 + 客户端精筛」：抓 /comic/ 全量索引页，按标题/分类匹配。
//   详情    : https://warchina.com/comic/{id}/
//   章节阅读: https://warchina.com/comic/{id}/{cid}.html
// 图片加载  : 阅读页 var params 里的 chapter_images2 = Base64( "url1$qingtiandy$url2$qingtiandy$..." )
//             decodeBase64 -> decodeUtf8 -> split('$qingtiandy$') = 完整图片 URL 数组
// 图片为标准 WebP，无需解密；但图片 CDN 会拒绝带 warchina referer 的请求（503/超时），
// 故 onImageLoad 只给 UA、不设 referer，复刻"无 referer 直连"的成功路径。
class WarChina extends ComicSource {
  name = '虫虫漫画';
  key = 'warchina';
  version = '1.0.3';
  minAppVersion = '1.4.0';
  url = 'https://cdn.jsdelivr.net/gh/lll152872/venera-lll@master/book%20source/warchina.js';

  baseUrl = 'https://warchina.com';
  imgHost = 'https://www.warchina.com';

  headers = {
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  // 通用：补全相对图片/链接地址
  abs(u) {
    if (!u) return '';
    if (u.indexOf('http') === 0) return u;
    return this.imgHost + (u.charAt(0) === '/' ? '' : '/') + u;
  }

  // 通用：从搜索页/首页 HTML 提取漫画卡片
  // 每个卡片：带 <img> 的 <a href="/comic/{id}/" title="标题"> —— 取首个，按 id 去重
  parseCards(html) {
    let doc = new HtmlDocument(html);
    let links = doc.querySelectorAll('a');
    let seen = new Set();
    let comics = [];
    for (let i = 0; i < links.length; i++) {
      let a = links[i];
      let href = a.attributes['href'] || '';
      // 仅详情页链接 /comic/{id}/ 或 /comic/{id}（结尾，排除章节 .html 链接）
      let m = href.match(/\/comic\/(\d+)\/?$/);
      if (!m) continue;
      let id = m[1];
      if (seen.has(id)) continue;
      let img = a.querySelector('img');
      if (!img) continue; // 跳过纯文字标题链接，封面来自图片链接
      let src = img.attributes['src'] || '';
      if (src.indexOf('/upload2/') < 0) continue; // 只要漫画封面，排除 logo/广告
      let title = (a.attributes['title'] || img.attributes['alt'] || a.text || '').trim();
      if (!title) continue;
      seen.add(id);
      comics.push(new Comic({
        id: id,
        title: title,
        cover: this.abs(src),
        subTitle: '',
        description: '',
      }));
    }
    return comics;
  }

  explore = [
    {
      title: this.name,
      type: 'singlePageWithMultiPart',
      load: async (page) => {
        let res = await Network.get(this.baseUrl, this.headers);
        if (res.status !== 200) throw 'Invalid status: ' + res.status;
        return { 推荐: this.parseCards(res.body) };
      },
    },
  ];

  search = {
    load: async (keyword, options, page) => {
      let kw = String(keyword || '').trim();
      if (!kw) return { comics: [], maxPage: 1 };

      // ① 先试真实端点 /statics/search.aspx?key=xx（站点若恢复搜索则直接命中）
      let direct = [];
      try {
        let res = await Network.get(
          this.baseUrl + '/statics/search.aspx?key=' + encodeURIComponent(kw),
          this.headers,
        );
        if (res.status === 200) {
          direct = this.parseCards(res.body).filter((c) => this.matchTitle(c.title, kw));
        }
      } catch (e) {
        // 忽略，走索引兜底
      }
      if (direct.length) {
        return { comics: this.sortByRelevance(direct, kw), maxPage: 1 };
      }

      // ② 兜底：抓全站索引页，客户端精筛。
      //    站点搜索后端已关闭（结果容器 clearfix 为空），只能这样。
      let all = await this.getIndex();
      let hit = all.filter((c) => this.matchTitle(c.title, kw));
      return { comics: this.sortByRelevance(hit, kw), maxPage: 1 };
    },
  };

  // 索引缓存：首次抓全库（99 页 × 30 本 ≈ 2300 本）后写入书源 data，
  // 之后 24 小时内直接复用。数据是 [{i, t, c}] 紧凑数组，比存对象省一半空间。
  async getIndex() {
    let cache = this.loadData('index');
    let fresh = cache && cache.d && Date.now() - cache.d < 24 * 3600 * 1000;
    if (fresh && Array.isArray(cache.l) && cache.l.length > 100) {
      return cache.l.map((x) => ({ id: x[0], title: x[1], cover: this.abs(x[2]) }));
    }
    let list = await this.fetchAllIndex();
    if (list.length > 100) {
      try {
        this.saveData('index', {
          d: Date.now(),
          l: list.map((c) => [c.id, c.title, c.cover]),
        });
      } catch (e) {
        // 缓存写失败不影响本次搜索
      }
    }
    return list;
  }

  // 抓多页索引（/comic/{n}.html，30 本/页），并发拿全量漫画库用于客户端筛选。
  // 分页必须带 .html：实测 /comic/?page=2 每页都返回同样 30 本（静默失效）。
  // p>=100 起返回 404 首页（84 本推荐位），故上限 99，实测总库约 2300 本。
  async fetchAllIndex() {
    let seen = new Map();
    let urls = [this.baseUrl + '/comic/'];
    for (let p = 2; p <= 99; p++) urls.push(this.baseUrl + '/comic/' + p + '.html');
    let CONC = 8;
    for (let i = 0; i < urls.length; i += CONC) {
      let batch = urls.slice(i, i + CONC);
      await Promise.all(
        batch.map(async (u) => {
          try {
            let res = await Network.get(u, this.headers);
            // 越界页会返回首页（84 本推荐位），用长度阈值挡掉，避免污染索引
            if (res.status !== 200) return;
            let cards = this.parseCards(res.body);
            if (cards.length > 60) return;
            for (let c of cards) {
              if (c.id && c.title && !seen.has(c.id)) seen.set(c.id, c);
            }
          } catch (e) {
            // 单页失败不影响整体
          }
        }),
      );
    }
    return Array.from(seen.values());
  }

  // 标题匹配：全部关键词都必须在标题里（AND）。空泛命中直接丢弃。
  matchTitle(title, kw) {
    let t = String(title || '').toLowerCase();
    if (!t) return false;
    let parts = kw.toLowerCase().split(/\s+/).filter((x) => x);
    if (!parts.length) return false;
    for (let p of parts) {
      if (t.indexOf(p) < 0) return false;
    }
    return true;
  }

  // 相关度排序：完全相等 > 前缀匹配 > 标题短（更可能相关）
  sortByRelevance(list, kw) {
    let k = kw.toLowerCase();
    return list.slice().sort((a, b) => {
      let ta = String(a.title).toLowerCase();
      let tb = String(b.title).toLowerCase();
      let sa = (ta === k ? 0 : ta.indexOf(k) === 0 ? 1 : 2) * 1000 + ta.length;
      let sb = (tb === k ? 0 : tb.indexOf(k) === 0 ? 1 : 2) * 1000 + tb.length;
      return sa - sb;
    });
  }

  comic = {
    loadInfo: async (id) => {
      let url = this.baseUrl + '/comic/' + id + '/';
      let res = await Network.get(url, this.headers);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let html = res.body;
      let doc = new HtmlDocument(html);

      // 元数据优先用 <meta og:novel:*>（静态、最可靠，不依赖散文文本/推荐区干扰）
      let meta = (p) => {
        let m = html.match(new RegExp('property="' + p + '"\\s+content="([^"]*)"'));
        return m ? m[1] : '';
      };
      let title = meta('og:title');
      let cover = meta('og:image');                    // 即 _small.jpg 封面
      let author = meta('og:novel:author');
      let status = meta('og:novel:status');
      // 原散文正则 `最后更新:\s*(\d...)` 会因日期被 <font color="red"> 包裹而失配，改用 meta
      let updateTime = meta('og:novel:update_time');

      // 分类：从 info3 信息块"漫画类别："后取，避免被右侧"精彩推荐"区的 cate 链接干扰
      let category = '';
      let infoIdx = html.indexOf('info3');
      if (infoIdx >= 0) {
        let block = html.slice(infoIdx, infoIdx + 500);
        let cm = block.match(/漫画类别[：:]\s*<a[^>]*>([^<]+)<\/a>/);
        if (cm) category = cm[1].trim();
      }

      // 章节列表：所有 <a href="/comic/{id}/{cid}.html">，按 cid 去重
      // 站点 HTML 默认倒序（最新/番外在前、第1话在尾），先收集再反转为正序（第1话在前）
      let chArr = [];
      let seen = new Set();
      let links = doc.querySelectorAll('a');
      let reg = new RegExp('/comic/' + id + '/(\\d+)\\.html');
      for (let i = 0; i < links.length; i++) {
        let href = links[i].attributes['href'] || '';
        let m = href.match(reg);
        if (!m) continue;
        let cid = m[1];
        if (seen.has(cid)) continue;
        let ctitle = (links[i].text || '').trim();
        if (!ctitle) continue;
        seen.add(cid);
        chArr.push({ cid: cid, title: ctitle });
      }
      chArr.reverse();
      let chapters = new Map();
      for (let i = 0; i < chArr.length; i++) {
        chapters.set(chArr[i].cid, chArr[i].title);
      }

      // 简介：warchina 多数漫画不提供简介（meta 写"暂未提供"），尝试常见容器，失败则留空
      let description = '';
      let selList = ['.intro', '.desc', '#intro', '.jianjie', '.content', '.info', '.summary'];
      for (let i = 0; i < selList.length; i++) {
        let el = doc.querySelector(selList[i]);
        if (el) {
          let t = el.text.trim();
          if (t && t.indexOf('暂未提供') < 0) { description = t; break; }
        }
      }

      let tags = {};
      if (author) tags['作者'] = [author];
      if (category) tags['分类'] = [category];
      if (status) tags['状态'] = [status];

      return new ComicDetails({
        title: title,
        cover: cover,
        description: description,
        tags: tags,
        chapters: chapters,
        updateTime: updateTime,
      });
    },

    loadEp: async (comicId, epId) => {
      let url = this.baseUrl + '/comic/' + comicId + '/' + epId + '.html';
      let res = await Network.get(url, this.headers);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let html = res.body;
      // 阅读页内嵌 var params = {...,"chapter_images2":"BASE64",...}
      let m = html.match(/chapter_images2"\s*:\s*"([^"]+)"/);
      if (!m) m = html.match(/chapter_images"\s*:\s*"([^"]+)"/); // 兜底字段名
      if (!m) throw '未找到 chapter_images2（章节可能为空或页面结构变更）';
      // decodeBase64 返回字节，需 decodeUtf8 转字符串（参考 jm.js 的 Convert 用法）
      let bytes = Convert.decodeBase64(m[1]);
      let str = Convert.decodeUtf8(bytes);
      let parts = str.split('$qingtiandy$');
      let images = [];
      for (let i = 0; i < parts.length; i++) {
        if (parts[i]) images.push(parts[i]);
      }
      return { images: images };
    },

    // 图片 CDN 会拒绝带 warchina referer 的请求（实测 503/超时），
    // 无 referer 直连成功。这里只给 UA、故意不设 referer。
    onImageLoad: (imageKey, comicId, ep) => {
      return {
        headers: {
          'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      };
    },
  };
}
