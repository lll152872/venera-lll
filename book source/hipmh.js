class Hipmh extends ComicSource {
    name = "嬉皮漫画"
    key = "hipmh"
    version = "1.0.1"
    minAppVersion = "1.6.0"
    url = "https://gcore.jsdelivr.net/gh/venera-app/venera-configs@main/hipmh.js"

    apiBaseUrl = "https://hipapi1.s3file.top"
    coverBaseUrl = "https://cover.s3imgs.top"
    readerBaseUrl = "https://reader.hipmh.top"

    userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    // 图片解码相关常量
    srcTable = "_-9876543210abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    tgtTable = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    prefix = "qM9"
    suffix = "Z7"
    frag = "Vx"
    middle = "pL0"
    blockSize = 7

    // 解码混淆的图片数据
    decodeImages = (raw) => {
        if (!raw.startsWith(this.prefix) || !raw.endsWith(this.suffix)) {
            throw "Invalid images payload"
        }
        const s = raw.substring(this.prefix.length, raw.length - this.suffix.length)
        const len = s.length - this.frag.length - this.middle.length
        if (len <= 0) throw "Invalid images payload"

        const c1 = Math.floor(len / 3)
        const c2 = Math.floor((len - c1) / 2)
        const b = len - c1 - c2
        const p1 = s.substring(0, c2)
        const p2 = s.substring(c2, c2 + this.frag.length)
        const p3 = s.substring(c2 + this.frag.length, c2 + this.frag.length + b)
        const p4 = s.substring(c2 + this.frag.length + b, c2 + this.frag.length + b + this.middle.length)
        const p5 = s.substring(c2 + this.frag.length + b + this.middle.length)
        if (p2 !== this.frag || p4 !== this.middle || p5.length !== c1) {
            throw "Images payload checksum failed"
        }

        const combined = p5 + p1 + p3
        let reversed = ""
        let block = 0
        for (let i = 0; i < combined.length; i += this.blockSize) {
            const chunk = combined.substring(i, Math.min(i + this.blockSize, combined.length))
            reversed += (block % 2 !== 0) ? chunk.split("").reverse().join("") : chunk
            block++
        }

        let b64 = ""
        for (let i = 0; i < reversed.length; i++) {
            const ch = reversed[i]
            const idx = this.srcTable.indexOf(ch)
            if (idx < 0) throw `Unexpected character '${ch}'`
            b64 += this.tgtTable[idx]
        }

        let encoded = b64.replace(/-/g, "+").replace(/_/g, "/")
        while (encoded.length % 4 !== 0) encoded += "="
        const text = decodeURIComponent(escape(atob(encoded)))
        const arr = JSON.parse(text)
        return arr
    }

    // 解析漫画列表页面（HTML格式）
    parseMangaListHtml = (doc) => {
        const comics = doc.querySelectorAll("a.manga-card-link").map(el => {
            const href = el.attributes.href
            const id = href.split("/").pop()
            const title = el.querySelector("h3.manga-card-title")?.text?.trim() || el.attributes["aria-label"] || ""
            const cover = el.querySelector("img.manga-card-image")?.attributes.src || ""
            return {
                id: id,
                title: title,
                cover: cover.startsWith("http") ? cover : this.coverBaseUrl + cover
            }
        })
        const next = doc.querySelector("a.pagination-next")
        const hasNext = comics.length > 0 && next != null && next.attributes["aria-disabled"] !== "true"
        return { comics, hasNext }
    }

    // 解析搜索结果
    parseSearchResult = (json, isSearch) => {
        const data = json.data || {}
        const list = isSearch ? (data.data || []) : (data.items || [])
        // 部分接口可能不返回 total_pages，此时用 total / 每页数量兜底
        let totalPages = parseInt(data.total_pages)
        if (!totalPages || totalPages < 1) {
            const total = parseInt(data.total)
            const perPage = parseInt(isSearch ? data.page_size : data.per_page) || (isSearch ? 24 : 18)
            totalPages = total > 0 ? Math.ceil(total / perPage) : 1
        }
        const comics = list.map(item => {
            if (isSearch) {
                return this.parseSearchComic(item)
            } else {
                return this.parseBrowseComic(item)
            }
        })
        return { comics, totalPages }
    }

    // 解析搜索漫画数据
    parseSearchComic = (item) => {
        const authors = (item.authors || []).map(a => a.name).filter(a => a).join(", ")
        const genres = (item.genres || []).map(g => g.name).filter(g => g).join(", ")
        let status = "unknown"
        if (item.status === "completed") status = "completed"
        else if (item.status === "ongoing") status = "ongoing"

        return {
            id: item.id?.toString() || "",
            title: item.title || "",
            cover: item.vertical_image_url ? this.coverBaseUrl + item.vertical_image_url : "",
            description: item.description || "",
            author: authors,
            tags: genres,
            status: status
        }
    }

    // 解析浏览漫画数据
    parseBrowseComic = (item) => {
        const authors = (item.author_names || []).filter(a => a).join(", ")
        const genres = (item.genres || []).filter(g => g).join(", ")

        return {
            id: item.mid?.toString() || "",
            title: item.title || "",
            cover: item.vertical_image_url ? this.coverBaseUrl + item.vertical_image_url : "",
            author: authors,
            tags: genres
        }
    }

    // 解析漫画详情页
    parseMangaDetail = (doc, url) => {
        const title = doc.querySelector("h1")?.text?.trim() || ""
        let cover = ""
        const coverConfig = doc.querySelector("#chapters-config")?.attributes["data-cover"]
        if (coverConfig) {
            cover = coverConfig
        } else {
            const ogImage = doc.querySelector("meta[property='og:image']")?.attributes.content
            if (ogImage) {
                cover = ogImage.startsWith("http") ? ogImage : this.coverBaseUrl + ogImage
            }
        }

        const description = doc.querySelector("meta[property='og:description']")?.attributes.content || ""
        const genres = doc.querySelectorAll("a[href^='/genre/']").map(a => a.text.trim()).filter(g => g)

        let status = "unknown"
        if (doc.querySelector("a[href='/completed']")) status = "completed"
        else if (doc.querySelector("a[href='/ongoing']")) status = "ongoing"

        // 从URL中提取mid，URL格式: /works/{mid}-{slug}
        let mid = ""
        const urlMatch = url.match(/\/works\/([^-]+)/)
        if (urlMatch) {
            mid = urlMatch[1]
        }

        return {
            id: mid,
            title: title,
            cover: cover,
            description: description,
            tags: genres.join(", "),
            status: status
        }
    }

    // 解析章节列表
    parseChapterList = (items) => {
        return items.map(ch => {
            const number = parseFloat(ch.chapter_number) || 0
            let updateTime = 0
            try {
                updateTime = new Date(ch.updated_at).getTime()
            } catch (e) {}

            return {
                id: ch.hid || "",
                title: ch.title || (number > 0 ? `第 ${Math.floor(number)} 话` : ""),
                number: number,
                updateTime: updateTime
            }
        })
    }

    // 获取请求头
    getJsonHeaders = () => {
        return {
            "User-Agent": this.userAgent,
            "Accept": "application/json, text/plain, */*"
        }
    }

    // 发现页配置
    explore = [{
        title: "嬉皮漫画",
        type: "multiPageComicList",
        load: async (page) => {
            const url = `${this.apiBaseUrl}/v1/mangas?sort=updated&page=${page}&per_page=18`
            const res = await Network.get(url, this.getJsonHeaders())

            if (res.status !== 200) {
                throw `请求失败: ${res.status}`
            }

            const json = JSON.parse(res.body)
            if (json.code !== 200) {
                throw `接口返回错误: ${json.message}`
            }

            const result = this.parseSearchResult(json, false)
            return {
                comics: result.comics.map(c => ({
                    id: c.id,
                    title: c.title,
                    cover: c.cover,
                    subTitle: c.author || ""
                })),
                maxPage: result.totalPages
            }
        }
    }]

    // 分类配置
    category = {
        title: "嬉皮漫画",
        parts: [{
            name: "分类",
            type: "fixed",
            categories: ["全部", "国漫", "韩漫", "日漫", "武侠", "玄幻", "系统", "冒险", "异能", "剧情", "宫斗", "逆袭", "重生", "穿越", "大女主", "动作", "复仇"],
            // c 前缀表示 category 分类，g 前缀表示 genre 题材
            categoryParams: ["", "c2", "c1", "c3", "g39", "g27", "g67", "g38", "g51", "g3", "g44", "g32", "g46", "g20", "g30", "g40", "g31"],
            itemType: "category"
        }],
        enableRankingPage: false
    }

    // 分类漫画加载配置
    categoryComics = {
        load: async (category, param, options, page) => {
            let url = `${this.apiBaseUrl}/v1/mangas?page=${page}&per_page=18&sort=updated`
            if (param) {
                const type = param[0]
                const value = param.slice(1)
                if (/^\d+$/.test(value)) {
                    if (type === "c") {
                        url += `&category=${value}`
                    } else if (type === "g") {
                        url += `&genre=${value}`
                    }
                }
            }

            const res = await Network.get(url, this.getJsonHeaders())
            if (res.status !== 200) {
                throw `请求失败: ${res.status}`
            }

            const json = JSON.parse(res.body)
            if (json.code !== 200) {
                throw `接口返回错误: ${json.message}`
            }

            const result = this.parseSearchResult(json, false)
            return {
                comics: result.comics.map(c => ({
                    id: c.id,
                    title: c.title,
                    cover: c.cover,
                    subTitle: c.author || ""
                })),
                maxPage: result.totalPages
            }
        },
        optionList: []
    }

    // 搜索配置
    search = {
        load: async (keyword, options, page) => {
            const url = `${this.apiBaseUrl}/v1/search?q=${encodeURIComponent(keyword)}&page=${page}&page_size=24`
            const res = await Network.get(url, this.getJsonHeaders())

            if (res.status !== 200) {
                throw `搜索请求失败: ${res.status}`
            }

            const json = JSON.parse(res.body)
            if (json.code !== 200) {
                throw `接口返回错误: ${json.message}`
            }

            const result = this.parseSearchResult(json, true)
            return {
                comics: result.comics.map(c => ({
                    id: c.id,
                    title: c.title,
                    cover: c.cover,
                    subTitle: c.author || "",
                    description: c.description || ""
                })),
                maxPage: result.totalPages
            }
        }
    }

    // 漫画详情配置
    comic = {
        loadInfo: async (id) => {
            // API只接受短mid（第一个-之前的部分）
            const shortMid = id.split("-")[0]

            // 使用API获取漫画详情
            const apiUrl = `${this.apiBaseUrl}/v1/manga?mid=${shortMid}`
            const apiRes = await Network.get(apiUrl, this.getJsonHeaders())

            if (apiRes.status !== 200) {
                throw `漫画详情请求失败: ${apiRes.status}`
            }

            const apiJson = JSON.parse(apiRes.body)
            if (apiJson.code !== 200) {
                throw `接口返回错误: ${apiJson.message}`
            }

            const data = apiJson.data
            const title = data.title || ""
            const description = data.description || ""
            const cover = data.vertical_image_url ? `https://cover.s3imgs.top${data.vertical_image_url}` : ""
            const authors = (data.authors || []).map(a => a.name).filter(a => a)
            const genres = (data.genres || []).map(g => g.name).filter(g => g)
            const status = data.status === "completed" ? "completed" : data.status === "ongoing" ? "ongoing" : "unknown"

            // 获取章节列表
            let allChapters = []
            let page = 1
            while (true) {
                const chapterUrl = `${this.apiBaseUrl}/v1/manga/chapters?mid=${shortMid}&page=${page}&per_page=100&order=asc`
                const chapterRes = await Network.get(chapterUrl, this.getJsonHeaders())

                if (chapterRes.status !== 200) {
                    break
                }

                const chapterJson = JSON.parse(chapterRes.body)
                if (chapterJson.code !== 200) {
                    break
                }

                const items = chapterJson.data?.items || []
                if (items.length === 0) break

                allChapters = allChapters.concat(this.parseChapterList(items))

                const totalPages = chapterJson.data?.total_pages || page
                if (page >= totalPages) break
                page++
            }

            const chapters = {}
            allChapters.forEach(ch => {
                chapters[ch.id] = ch.title
            })

            return new ComicDetails({
                title: title,
                cover: cover,
                description: description,
                tags: {
                    "作者": authors,
                    "类型": genres
                },
                chapters: chapters,
                recommend: []
            })
        },

        loadEp: async (comicId, epId) => {
            // 先获取阅读页面
            const readUrl = `${this.readerBaseUrl}/chapter/${epId}`
            const readRes = await Network.get(readUrl, { "User-Agent": this.userAgent })

            if (readRes.status !== 200) {
                throw `阅读页面请求失败: ${readRes.status}`
            }

            const doc = new HtmlDocument(readRes.body)
            const content = doc.querySelector("#chapcontent")
            if (!content) {
                throw "阅读页内容未找到"
            }

            const apiHid = content.attributes["data-api-hid"]
            if (!apiHid) {
                throw "未找到章节图片标识"
            }

            let imgBase = content.attributes["data-chapter-img-base-line1"] ||
                           content.attributes["data-chapter-img-base-line2"] ||
                           content.attributes["data-chapter-img-base"] || ""
            doc.dispose()

            // 获取图片数据
            const apiUrl = `${this.apiBaseUrl}/v2/chapter?hid=${apiHid}`
            const apiRes = await Network.get(apiUrl, this.getJsonHeaders())

            if (apiRes.status !== 200) {
                throw `图片接口请求失败: ${apiRes.status}`
            }

            const json = JSON.parse(apiRes.body)
            if (json.code !== 200) {
                throw `图片接口返回错误: ${json.message}`
            }

            const payload = json.data?.images || ""
            const images = this.decodeImages(payload)

            return {
                images: images.map(path => imgBase + path)
            }
        },

        onImageLoad: (url, comicId, epId) => {
            // 根据设置选择线路
            const selectedLine = this.loadSetting("imageLine")
            const newUrl = url.replace(/hip-(tx|cf)-1\.s3imgs\.top/, selectedLine)

            return {
                url: newUrl,
                method: "GET",
                headers: {
                    "User-Agent": this.userAgent,
                    "Referer": this.readerBaseUrl,
                    "Accept": "image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
                }
            }
        },

        onThumbnailLoad: (url) => {
            return {
                url: url,
                method: "GET",
                headers: {
                    "User-Agent": this.userAgent,
                    "Referer": "https://m.hipmh.com/"
                }
            }
        }
    }

    // 设置配置
    settings = {
        imageLine: {
            title: "图片线路",
            type: "select",
            options: [
                { value: "hip-tx-1.s3imgs.top", text: "线路1 (tx)" },
                { value: "hip-cf-1.s3imgs.top", text: "线路2 (cf)" }
            ],
            default: "hip-tx-1.s3imgs.top"
        }
    }
}
