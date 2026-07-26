/** @type {import('./_venera_.js')} */
// 虫虫漫画 (warchina.com) 书源
// 站点结构（实测）：
//   首页    : https://warchina.com/            （div.chong 卡片，无分页）
//   搜索    : https://warchina.com/search?keyword=xxx   （单页，最多 ~85 条，无分页）
//   详情    : https://warchina.com/comic/{id}/
//   章节阅读: https://warchina.com/comic/{id}/{cid}.html
// 图片加载  : 阅读页 var params 里的 chapter_images2 = Base64( "url1$qingtiandy$url2$qingtiandy$..." )
//             decodeBase64 -> decodeUtf8 -> split('$qingtiandy$') = 完整图片 URL 数组
// 图片为标准 WebP，无需解密；但图片 CDN 会拒绝带 warchina referer 的请求（503/超时），
// 故 onImageLoad 只给 UA、不设 referer，复刻"无 referer 直连"的成功路径。
class WarChina extends ComicSource {
  name = '虫虫漫画';
  key = 'warchina';
  version = '1.0.1';
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
      let url = this.baseUrl + '/search?keyword=' + encodeURIComponent(keyword);
      let res = await Network.get(url, this.headers);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let comics = this.parseCards(res.body);
      // warchina 搜索无分页，单页返回全部命中
      return { comics: comics, maxPage: 1 };
    },
  };

  comic = {
    loadInfo: async (id) => {
      let url = this.baseUrl + '/comic/' + id + '/';
      let res = await Network.get(url, this.headers);
      if (res.status !== 200) throw 'Invalid status: ' + res.status;
      let html = res.body;
      let doc = new HtmlDocument(html);

      // 标题：<h1>
      let titleEl = doc.querySelector('h1');
      let title = titleEl ? titleEl.text.trim() : '';

      // 封面：第一张 /upload2/ 图片（详情页头部即为封面，_small.jpg 是真封面）
      let cover = '';
      let imgs = doc.querySelectorAll('img');
      for (let i = 0; i < imgs.length; i++) {
        let s = imgs[i].attributes['src'] || '';
        if (s.indexOf('/upload2/') >= 0) { cover = this.abs(s); break; }
      }

      // 作者：<a href*="/author/">文本
      let author = '';
      let authorEl = doc.querySelector('a[href*="/author/"]');
      if (authorEl) author = authorEl.text.trim();

      // 分类：<a href*="/cate/">文本
      let category = '';
      let cateEl = doc.querySelector('a[href*="/cate/"]');
      if (cateEl) category = cateEl.text.trim();

      // 状态 / 更新时间：正则取原始 HTML（HtmlDocument 不便读整段散文文本）
      let status = '';
      let sm = html.match(/漫画状态[：:]\s*([^\s<]+)/);
      if (sm) status = sm[1].trim();
      let updateTime = '';
      let um = html.match(/最后更新[：:]\s*([\d\-\/]+)/);
      if (um) updateTime = um[1].trim();

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
