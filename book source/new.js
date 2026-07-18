/** @type {import('./_venera_.js')} */
class ManWaBa extends ComicSource {
  name = '漫蛙吧';
  key = 'manwaba';
  version = '1.0.5';
  minAppVersion = '1.4.0';
//   url = 'https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/manwaba.js';
  // 修复①：原 mwuu.cc 已失效（连接超时），实际可用域名为 manwapi.cc（manwaba.com 重定向目标）
  api = 'https://manwapi.cc/api';

  init() {
    this.fetchJson = async (url, { method = 'GET', params, headers, payload }) => {
      if (params) {
        let params_str = Object.keys(params)
          .map((key) => `${key}=${params[key]}`)
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
    // 章节 API 分页参数为 pageSize(驼峰)。原实现一次性 pageSize:total 会被服务端上限截断，导致章节丢失。改为按页循环拉全。
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
    // 修复②：图片 API 分页参数为 page_size(下划线)且单页有上限(实测 page_size=50 生效、pageSize=300 被忽略成默认25)，
    // 原实现一次性 page_size:total 会被截断，只拿到前 25 张，其余丢失 = 图片异常/无效数据。改为按页循环拉全。
    loadEp: async (comicId, epId) => {
      const imgApi = `${this.api}/comic/image/${epId}`;
      const base = { imageSource: 'https://tu.mhttu.cc' };
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
    /**
     * 修复③：图片服务器需要Referer和User-Agent才能正常访问，否则返回403/Cloudflare挑战
     */
    onImageLoad: (url, comicId, epId) => {
      return {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://manwa.cc/',
          'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
        }
      };
    },
    onThumbnailLoad: (url) => {
      return {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://manwa.cc/',
          'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
        }
      };
    },
  };
}
