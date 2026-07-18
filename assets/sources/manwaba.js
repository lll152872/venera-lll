/** @type {import('./_venera_.js')} */
class ManWaBa extends ComicSource {
  name = '漫蛙吧';
  key = 'manwaba';
  version = '1.1.0';
  minAppVersion = '1.4.0';
  url = 'https://cdn.jsdelivr.net/gh/lll152872/venera-lll@master/assets/sources/manwaba.js';
  // 修复①：原 mwuu.cc 已失效，实际可用域名为 manwapi.cc
  api = 'https://manwapi.cc/api';
  // 图片 AES-CBC 解密密钥（从 manwaba.com base.js 提取）
  AES_KEY = '0B6666A0-BB59-1381-B746-a0E4C9AC';

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
      let data = await this.fetchJson(url, { method: 'POST', payload }).then((res) => res.data.list);
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

  comic = {
    // 修复②：章节 API 分页参数 pageSize(驼峰)，单页有上限，按页循环拉全
    loadInfo: async (id) => {
      let url = `${this.api}/comic/${id}`;
      let data = await this.fetchJson(url, { payload: undefined }).then((res) => res.data);
      let chapterApi = `${this.api}/comic/chapter`;
      const first = await this.fetchJson(chapterApi, { params: { comicId: data.id, page: 1, pageSize: 1 } });
      const total = first.pagination.total;
      const chapters = new Map();
      const pageSize = 100;
      const pages = Math.ceil(total / pageSize);
      for (let p = 1; p <= pages; p++) {
        const r = await this.fetchJson(chapterApi, { params: { comicId: data.id, page: p, pageSize } });
        for (const item of r.data) {
          chapters.set(item.id.toString(), item.title.toString());
        }
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
    // 修复③：图片 API 分页参数 page_size(下划线)，单页有上限，按页循环拉全
    loadEp: async (comicId, epId) => {
      const imgApi = `${this.api}/comic/image/${epId}`;
      const base = { image_source: 'https://tu.mhttu.cc' };
      const first = await this.fetchJson(imgApi, { params: { ...base, page: 1, page_size: 1 } });
      const total = first.data.pagination.total;
      const images = [];
      const pageSize = 50;
      const pages = Math.ceil(total / pageSize);
      for (let p = 1; p <= pages; p++) {
        const r = await this.fetchJson(imgApi, { params: { ...base, page: p, page_size: pageSize } });
        for (const it of r.data.images) {
          images.push(it.url);
        }
      }
      return { images };
    },
    // 修复④（核心）：manwaba 图片 CDN 返回的是 AES-CBC 加密数据，不是标准图片。
    // 从 base.js 提取的解密逻辑：前16字节=IV，其余=密文，AES-256-CBC 解密后得到 WebP。
    // onImageLoad 返回 onResponse 回调，Venera 下载图片后会调用它，用解密后的数据替换原始数据。
    onImageLoad: (imageKey, comicId, ep) => {
      // 只对漫画内容图片（en_images 路径）做解密，封面/缩略图不需要
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
    },
  };
}
