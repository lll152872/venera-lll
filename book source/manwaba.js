/** @type {import('./_venera_.js')} */
class ManWaBa extends ComicSource {
  name = '漫蛙吧';
  key = 'manwaba';
  version = '1.4.0';
  minAppVersion = '1.4.0';
  url = 'https://cdn.jsdelivr.net/gh/lll152872/venera-lll@master/assets/sources/manwaba.js';
  // 修复①：原 mwuu.cc 已失效，实际可用域名为 manwapi.cc；2026-08 起 manwapi.cc 301 到 manwali.cc
  // 修复⑥（2026-09-01 实测）：manwali.cc 已 301 → manwari.cc。
  //   旧域名每次请求都要多付一次 DNS+TCP+TLS 往返，实测 TTFB 1059ms vs 直连 565ms，慢近一倍。
  //   本源 loadInfo/loadEp 会串行发多次请求（章节分页 + 图片分页），惩罚会被成倍放大。
  //   ⚠️ 务必写死最终域名，不要留会 301 的中间域名。
  api = 'https://manwari.cc/api';
  // 图片 AES-CBC 解密密钥（从 manwaba.com base.js 提取）
  AES_KEY = '0B6666A0-BB59-1381-B746-a0E4C9AC';
  // 单页拉取上限（2026-09-01 实测，改这两个值前先看 loadInfo 里的注释）
  //   章节 API：pageSize 可到 500，一次返回全部（228 条实测无截断）
  //   图片 API：page_size 硬上限 100，传 500 也只回 100 条（多传无效，别自作聪明改大）
  CH_PAGE_SIZE = 500;
  IMG_PAGE_SIZE = 100;

  init() {
    this.fetchJson = async (url, { method = 'GET', params, headers, payload } = {}) => {
      if (params) {
        let params_str = Object.keys(params)
          .map((key) => `${key}=${encodeURIComponent(params[key])}`)
          .join('&');
        url += `?${params_str}`;
      }
      let res = await Network.sendRequest(method, url, headers, payload);
      if (res.status !== 200) {
        throw `Invalid status code: ${res.status}, body: ${res.body}`;
      }
      return JSON.parse(res.body);
    };
    this.logger = {
      error: (msg) => { log('error', this.name, msg); },
      info: (msg) => { log('info', this.name, msg); },
      warn: (msg) => { log('warning', this.name, msg); },
    };
  }

  explore = [
    {
      title: this.name,
      type: 'singlePageWithMultiPart',
      load: async (page) => {
        let params = { page: 1, pageSize: 6, type: '', flag: false };
        const url = `${this.api}/home`;
        const data = await this.fetchJson(url, { params }).then((res) => res.data);
        let magnaList = {
          热门: data.comicList,
          最新完整版: data.gufengList,
          最新更新: data.xuanhuanList,
          热门收藏: data.xiaoyuanList,
        };
        function parseComic(comic) {
          return new Comic({
            id: comic.id.toString(),
            title: comic.title,
            subTitle: comic.author,
            cover: comic.pic,
            tags: comic.tags.split(','),
          });
        }
        let result = {};
        for (let key in magnaList) {
          result[key] = magnaList[key].map(parseComic);
        }
        return result;
      },
    },
  ];

  category = {
    title: this.name,
    parts: [
      {
        name: '类型',
        type: 'fixed',
        categories: ['全部','热血','玄幻','恋爱','冒险','古风','都市','穿越','奇幻','其他','搞笑','少男','战斗','重生','逆袭','爆笑','少年','后宫','系统','BL','韩漫','完整版','19r','台版'],
        itemType: 'category',
        categoryParams: ['','热血','玄幻','恋爱','冒险','古风','都市','穿越','奇幻','其他','搞笑','少男','战斗','重生','逆袭','爆笑','少年','后宫','系统','BL','韩漫','完整版','19r','台版'],
      },
    ],
    enableRankingPage: false,
  };

  categoryComics = {
    load: async (category, param, options, page) => {
      let pathMap = {
        '': '/cate', '热血': '/cate/hotblooded', '玄幻': '/cate/xuanhuan', '恋爱': '/cate/romance',
        '冒险': '/cate/adventure', '古风': '/cate/historical', '都市': '/cate/urban', '穿越': '/cate/transmigration',
        '奇幻': '/cate/fantasy', '搞笑': '/cate/comedy', '少男': '/cate/shounen', '战斗': '/cate/action',
        '重生': '/cate/rebirth', '逆袭': '/cate/counterattack', '爆笑': '/cate/hilarious', '少年': '/cate/youth',
        '系统': '/cate/system', 'BL': '/cate/bl', '韩漫': '/cate/manhwa', '完整版': '/cate/fullversion',
        '19r': '/cate/19plus', '台版': '/cate/taiwanver',
      };
      let url = this.api + (pathMap[param] || '/cate');
      let payload = JSON.stringify({
        page: { page: page, pageSize: 10 },
        category: 'comic',
        sort: parseInt(options[2]),
        comic: { status: parseInt(options[0] == '2' ? -1 : options[0]), day: parseInt(options[1]), tag: param },
        video: { year: 0, typeId: 0, typeId1: 0, area: '', lang: '', status: -1, day: 0 },
        novel: { status: -1, day: 0, sortId: 0 },
      });
      // 修复⑧（2026-09-01）：POST 必须带 Content-Type: application/json，
      //   否则站点返回 415 Unsupported Media Type（.NET 后端的典型行为），分类页整页报错。
      let data = await this.fetchJson(url, {
        method: 'POST',
        payload,
        headers: { 'Content-Type': 'application/json' },
      }).then((res) => res.data.list);
      function parseComic(comic) {
        return new Comic({
          id: comic.url.split('/').pop(),
          title: comic.title,
          subTitle: comic.author,
          cover: comic.pic,
          tags: comic.tags.split(','),
          description: comic.intro,
          status: comic.status == 0 ? '连载中' : '已完结',
        });
      }
      return { comics: data.map(parseComic), maxPage: 100 };
    },
    optionList: [
      { options: ['2-全部', '0-连载中', '1-已完结'] },
      { options: ['0-全部','1-周一','2-周二','3-周三','4-周四','5-周五','6-周六','7-周日'] },
      { options: ['0-更新','1-新作','2-畅销','3-热门','4-收藏'] },
    ],
  };

  search = {
    load: async (keyword, options, page) => {
      const pageSize = 20;
      let url = `${this.api}/search`;
      let params = { keyword, type: 'mh', page, pageSize };
      let data = await this.fetchJson(url, { params }).then((res) => res.data);
      let total = data.total;
      let comics = data.list.map((item) => {
        return new Comic({
          id: item.id.toString(),
          title: item.title,
          subTitle: item.author,
          cover: item.cover,
          tags: item.tags.split(','),
          description: item.description,
          status: item.status == 0 ? '连载中' : '已完结',
        });
      });
      let maxPage = Math.ceil(total / pageSize);
      return { comics, maxPage };
    },
  };

  // 修复④（核心）：manwaba 图片 CDN 返回的是 AES-CBC 加密数据，不是标准图片。
  // 从 base.js 提取的解密逻辑：前16字节=IV，其余=密文，AES-256-CBC 解密后得到 WebP。
  // onImageLoad 返回 onResponse 回调，Venera 下载图片后会调用它，用解密后的数据替换原始数据。
  // 修复⑤：封面/缩略图同样走 AES 加密（2026-08 CDN 全面加密 en_images 路径），
  // 必须实现 onThumbnailLoad，否则封面显示为密文乱码/黑图。
  _imageLoadConfig(imageKey) {
    if (!imageKey || !imageKey.includes('en_images')) {
      return {};
    }
    return {
      headers: {
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'referer': 'https://manwaba.com/',
      },
      onResponse: (buffer) => {
        // buffer 是下载的原始字节数组 (ArrayBuffer/Uint8Array)
        let view = new Uint8Array(buffer);
        // 检查是否已经是标准图片（不需要解密）
        if ((view[0] === 0xFF && view[1] === 0xD8) ||  // JPEG
            (view[0] === 0x89 && view[1] === 0x50) ||  // PNG
            (view[0] === 0x47 && view[1] === 0x49) ||  // GIF
            (view[0] === 0x52 && view[1] === 0x49)) {  // RIFF (WebP)
          return buffer;
        }
        // AES-CBC 解密：前16字节=IV，其余=密文
        // 注意：必须用 ArrayBuffer/Uint8Array 传参，flutter_js 才能把它们识别为 Uint8List
        // 普通数组 [] 会被识别为 List<dynamic>，导致 Dart 端 AES 报类型错误
        let iv = new Uint8Array(16);
        for (let i = 0; i < 16; i++) iv[i] = view[i];
        let ciphertext = new Uint8Array(view.length - 16);
        for (let i = 0; i < ciphertext.length; i++) ciphertext[i] = view[16 + i];
        let keyBytes = new Uint8Array(32);
        let rawKey = this.AES_KEY;
        for (let i = 0; i < 32 && i < rawKey.length; i++) {
          keyBytes[i] = rawKey.charCodeAt(i);
        }
        let decrypted = sendMessage({
          method: "convert",
          type: "aes-cbc",
          value: ciphertext.buffer,
          key: keyBytes.buffer,
          iv: iv.buffer,
          isEncode: false
        });
        return decrypted;
      },
    };
  }

  comic = {
    // 修复②：章节 API 分页参数 pageSize(驼峰)
    // 修复⑦（2026-09-01 性能优化）：
    //   原实现 = 「详情」+「pageSize=1 探测总数」+「按 100 分页循环」共 1+1+N 次**串行**请求，
    //   每次约 750ms，一本 228 话的漫画要 5 次 ≈ 3.7 秒。
    //   实测结论：
    //     a) `comic/{id}` 返回的 `data.id` === 传入的 id → 章节请求不必等详情返回，两者可并发；
    //     b) 章节 API 的 pageSize 可到 500 且一次返回全部（228 条实测无截断）→ 探测请求可省；
    //     c) 图片 API 单页**硬上限 100**（page_size=500 也只回 100 条，多传无效）→ 用 100 而非 50。
    //   优化后：详情 + 章节并发 1 个 RTT ≈ 800ms 出结果；图片列表页数减半且补页并发。
    loadInfo: async (id) => {
      let chapterApi = `${this.api}/comic/chapter`;
      // 并发发详情 + 章节首页（章节直接用传入 id，不依赖详情结果）
      const pair = await Promise.all([
        this.fetchJson(`${this.api}/comic/${id}`, { payload: undefined }),
        this.fetchJson(chapterApi, {
          params: { comicId: id, page: 1, pageSize: this.CH_PAGE_SIZE },
        }),
      ]);
      const data = pair[0].data;
      let raw = pair[1].data || [];
      const total = pair[1].pagination ? pair[1].pagination.total : raw.length;
      // 兜底：若服务端截断了（章节数超过单页上限），并发补齐剩余页
      if (raw.length < total) {
        const pages = Math.ceil(total / this.CH_PAGE_SIZE);
        const tasks = [];
        for (let p = 2; p <= pages; p++) {
          tasks.push(
            this.fetchJson(chapterApi, {
              params: { comicId: id, page: p, pageSize: this.CH_PAGE_SIZE },
            })
          );
        }
        const rest = await Promise.all(tasks);
        for (let i = 0; i < rest.length; i++) {
          const list = rest[i].data || [];
          for (let j = 0; j < list.length; j++) raw.push(list[j]);
        }
      }
      const chapters = new Map();
      for (let i = 0; i < raw.length; i++) {
        chapters.set(raw[i].id.toString(), raw[i].title.toString());
      }
      return new ComicDetails({
        title: data.title.toString(),
        subTitle: data.author.toString(),
        cover: data.cover,
        tags: { 类型: data.tags.split(','), 状态: data.status == 0 ? '连载中' : '已完结' },
        chapters,
        description: data.intro,
        updateTime: new Date(data.editTime * 1000).toLocaleDateString(),
      });
    },
    // 修复③：图片 API 分页参数 page_size(下划线)
    // 修复⑦（2026-09-01 性能优化）：单页上限实测为 100（不是 50），且**不需要先发探测请求**——
    //   首页响应里就带 pagination.total，拿返回条数和 total 比一下就知道还有没有下一页。
    //   原实现 1 次探测 + N 次分页串行；现在 1 次拿首页 + 剩余页并发。
    loadEp: async (comicId, epId) => {
      const imgApi = `${this.api}/comic/image/${epId}`;
      const base = { image_source: 'https://tu.mhttu.cc' };
      const first = await this.fetchJson(imgApi, {
        params: { ...base, page: 1, page_size: this.IMG_PAGE_SIZE },
      });
      const data = first.data || {};
      const images = [];
      const list = data.images || [];
      for (let i = 0; i < list.length; i++) images.push(list[i].url);
      const total = data.pagination ? data.pagination.total : images.length;
      if (images.length < total) {
        const pages = Math.ceil(total / this.IMG_PAGE_SIZE);
        const tasks = [];
        for (let p = 2; p <= pages; p++) {
          tasks.push(
            this.fetchJson(imgApi, { params: { ...base, page: p, page_size: this.IMG_PAGE_SIZE } })
          );
        }
        const rest = await Promise.all(tasks);
        for (let i = 0; i < rest.length; i++) {
          const l = (rest[i].data || {}).images || [];
          for (let j = 0; j < l.length; j++) images.push(l[j].url);
        }
      }
      return { images };
    },
    // 修复④（核心）：manwaba 图片 CDN 返回的是 AES-CBC 加密数据，不是标准图片。
    // 从 base.js 提取的解密逻辑：前16字节=IV，其余=密文，AES-256-CBC 解密后得到 WebP。
    // onImageLoad 返回 onResponse 回调，Venera 下载图片后会调用它，用解密后的数据替换原始数据。
    onImageLoad: (imageKey, comicId, ep) => {
      return this._imageLoadConfig(imageKey);
    },
    // 修复⑤（封面 bug）：封面/缩略图同样被 AES 加密，必须走 onThumbnailLoad 解密，
    // 否则封面下载下来是密文，Venera 直接当图片显示 → 封面黑图/乱码。
    onThumbnailLoad: (imageKey) => {
      return this._imageLoadConfig(imageKey);
    },
  };
}
