'use strict';
// 歌词抓取器 v5
// 用法: node lyrics-fetch.js <请求json> <输出json> [缓存json]
// 取词链路（越精确越先试，任何一步成功即返回）：
//   LRCLIB  五段式级联（get+时长 → get → 结构化搜索 → 自由文本 → 只搜歌名），503 退避重试
//   网易云  双接口搜索 + yrc 逐字时间轴 + tlyric 翻译
//   酷狗    KRC 逐字（补网易云没有逐字的歌）；原文/逐字之外无翻译
//   QQ音乐  仅行级原文兜底（翻译与逐字需要登录态，实测取不到）
// 每行的 w 字段 = [[起始ms, 时长ms, 文本], ...]（统一成绝对毫秒，供 KTV 按字填充）

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

function out(p, obj) { try { fs.writeFileSync(p, JSON.stringify(obj), 'utf8'); } catch (e) { } }
function norm(s) { return String(s || '').replace(/\s+/g, ''); }

// ---------- 候选是否"就是这首歌"的硬判定 ----------
// 网易云对「没版权 / 已下架」的歌（例如罗大佑的部分作品）不会返回空，
// 而是返回该歌手其他热门歌或同名翻唱。旧版只对歌手名不匹配扣 25 分、
// 从不拒绝，于是会拿《东方之珠》的逐字/歌词去配《皇后大道东》。
const CACHE_VER = 4;                       // 取词链加了源 -> 旧缓存作废（顺便让老歌补上逐字）
function normKey(s) {
    return String(s || '').toLowerCase()
        .replace(/[\(\[（【][^\)\]）】]*[\)\]）】]/g, '')   // 去掉 (Live) (Remastered) 之类
        .replace(/[\s\-–—_.,!?'"·:：;；/\\|]/g, '');
}
function titleMatch(a, b) {
    const x = normKey(a), y = normKey(b);
    if (!x || !y) return 0;
    if (x === y) return 2;
    if (x.length >= 3 && y.length >= 3 && (x.includes(y) || y.includes(x))) return 1;
    return 0;
}
function artistMatch(a, b) {
    const x = normKey(a), y = normKey(b);
    if (!x || !y) return 0;
    if (x === y) return 2;
    if (x.includes(y) || y.includes(x)) return 1;
    return 0;
}
function songOk(song, q) {
    if (titleMatch(song.name, q.title) === 0) return false;   // 标题不像 -> 一票否决
    if (artistMatch(((song.artists || [])[0] || {}).name, q.artist) > 0) return true;
    const want = q.duration || 0;
    if (!want || !song.duration) return false;
    return Math.abs(song.duration / 1000 - want) <= 3;
}

function parseLrc(lrc) {
    if (!lrc) return [];
    const rx = /^\[(\d+):(\d+(?:[.:]\d+)?)\](.*)$/;
    const lines = [];
    for (const raw of String(lrc).split(/\r?\n/)) {
        const m = rx.exec(raw.trim());
        if (!m) continue;
        const sec = parseInt(m[1], 10) * 60 + parseFloat(m[2].replace(':', '.'));
        const txt = (m[3] || '').trim();
        if (txt) lines.push({ t: sec, s: txt });
    }
    lines.sort((a, b) => a.t - b.t);
    return lines;
}

// ---------- yrc 解析 ----------
// 格式: [行起始ms,行时长ms](词起始ms,词时长ms,flag)词文本(...)词文本
// 括号里是绝对毫秒
function parseYrc(text) {
    if (!text) return [];
    const lines = [];
    for (const raw of String(text).split(/\r?\n/)) {
        const line = raw.trim();
        if (!line) continue;
        const m = /^\[(\d+),(\d+)\](.*)$/.exec(line);
        if (!m) continue;
        const t = parseInt(m[1], 10) / 1000;
        const durMs = parseInt(m[2], 10);
        const rest = m[3];
        const words = [];
        const rx = /\((\d+),(\d+),(\d+)\)/g;
        let mm, prev = null, prevEnd = 0;
        while ((mm = rx.exec(rest)) !== null) {
            if (prev) {
                const txt = rest.slice(prevEnd, mm.index);
                if (txt) words.push([prev[0], prev[1], txt]);
            }
            prev = [parseInt(mm[1], 10), parseInt(mm[2], 10)];
            prevEnd = rx.lastIndex;
        }
        if (prev) {
            const tail = rest.slice(prevEnd);
            if (tail) words.push([prev[0], prev[1], tail]);
        }
        const s = words.map((w) => w[2]).join('').trim();
        if (!s) continue;
        lines.push({ t, s, d: durMs, w: words });
    }
    lines.sort((a, b) => a.t - b.t);
    return lines;
}

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function jget(url, ms, headers) {
    const r = await fetch(url, {
        signal: AbortSignal.timeout(ms),
        headers: Object.assign({ 'User-Agent': UA, Accept: 'application/json' }, headers || {}),
    });
    const text = await r.text();
    return { status: r.status, text };
}

// ---------- 翻译配对（与 v3 相同的两轮策略） ----------
function attachTrans(lines, transLines) {
    const info = { pass1: 0, pass2: 0, total: 0 };
    if (!lines || !lines.length || !transLines || !transLines.length) return info;
    const used = new Array(transLines.length).fill(false);
    const ok = (ln, tr) => tr && norm(tr.s) && norm(tr.s) !== norm(ln.s);

    for (const ln of lines) {
        let best = -1, bestD = 1e9;
        for (let i = 0; i < transLines.length; i++) {
            if (used[i]) continue;
            const d = Math.abs(transLines[i].t - ln.t);
            if (d < bestD) { bestD = d; best = i; }
        }
        if (best >= 0 && bestD <= 0.8 && ok(ln, transLines[best])) {
            ln.tr = transLines[best].s; used[best] = true; info.pass1++;
        }
    }
    let j = 0;
    for (const ln of lines) {
        if (ln.tr) continue;
        while (j < transLines.length && transLines[j].t < ln.t - 3.5) j++;
        let k = j;
        while (k < transLines.length && transLines[k].t <= ln.t + 3.5) {
            if (!used[k] && ok(ln, transLines[k])) {
                ln.tr = transLines[k].s; used[k] = true; info.pass2++;
                j = k + 1; break;
            }
            k++;
        }
    }
    let hit = 0;
    for (const ln of lines) if (ln.tr) hit++;
    info.total = lines.length ? hit / lines.length : 0;
    info.hit = hit;
    return info;
}

// ---------- LRCLIB（多策略级联 + 过载重试） ----------
// 两个坑：
//  1) LRCLIB 是社区服务，高峰期直接回 503 {"ServerOverloaded"}——旧版当成"没找到"就放弃了
//  2) 自由文本 ?q=艺人+歌名 比结构化查询更容易空手（简繁、别名、副标题都会影响）
// 所以按"越精确越先试"依次尝试，任何一步成功立即返回
async function lrclibFetch(url, expectArray) {
    for (let attempt = 0; attempt < 3; attempt++) {
        try {
            const r = await jget(url, 12000, null);
            if (r.status === 200) {
                let j = null; try { j = JSON.parse(r.text); } catch { return null; }
                return expectArray ? (Array.isArray(j) ? j : null) : j;
            }
            if (r.status === 404) return null;
        } catch { }
        await sleep(350 * (attempt + 1));
    }
    return null;
}
function lrclibItem(j, src, q) {
    if (!j || !j.syncedLyrics) return null;
    if (titleMatch(j.trackName, q.title) === 0) return null;
    const lines = parseLrc(j.syncedLyrics);
    if (!lines.length) return null;
    return { src, name: (j.artistName || '') + ' - ' + (j.trackName || ''), lines };
}
function lrclibPick(arr, q) {
    if (!Array.isArray(arr)) return null;
    const cand = arr.filter((x) => {
        if (!x || !x.syncedLyrics) return false;
        if (titleMatch(x.trackName, q.title) === 0) return false;
        if (artistMatch(x.artistName, q.artist) > 0) return true;
        if (!q.duration || !x.duration) return true;
        return Math.abs(x.duration - q.duration) <= 8;
    });
    if (!cand.length) return null;
    const rank = (x) => (artistMatch(x.artistName, q.artist) > 0 ? 0 : 1000) + Math.abs((x.duration || 0) - (q.duration || 0));
    cand.sort((a, b) => rank(a) - rank(b));
    return cand[0];
}
async function lrclib(q) {
    const A = encodeURIComponent(q.artist || ''), T = encodeURIComponent(q.title || '');
    const D = Math.round(q.duration || 0);

    if (D > 0) {
        const it = lrclibItem(await lrclibFetch('https://lrclib.net/api/get?artist_name=' + A + '&track_name=' + T + '&duration=' + D), 'lrclib/get', q);
        if (it) return it;
    }
    {
        const it = lrclibItem(await lrclibFetch('https://lrclib.net/api/get?artist_name=' + A + '&track_name=' + T), 'lrclib/get', q);
        if (it) return it;
    }
    {
        const it = lrclibItem(lrclibPick(await lrclibFetch('https://lrclib.net/api/search?track_name=' + T + '&artist_name=' + A, true), q), 'lrclib/search', q);
        if (it) return it;
    }
    {
        const it = lrclibItem(lrclibPick(await lrclibFetch('https://lrclib.net/api/search?q=' + encodeURIComponent((q.artist || '') + ' ' + (q.title || '')), true), q), 'lrclib/search', q);
        if (it) return it;
    }
    {
        const it = lrclibItem(lrclibPick(await lrclibFetch('https://lrclib.net/api/search?q=' + T, true), q), 'lrclib/search', q);
        if (it) return it;
    }
    return null;
}

// ---------- 网易云（带 yv=-1 取逐字，候选打分同 v3） ----------
// ---------- 网易云搜索（双接口 + 频率检测） ----------
// 坑：/api/search/get/web 被限流时返回的是 HTTP 200 + {"code":405,"msg":"操作频繁"}，
// 只看 status 会把它当成"没有结果"，于是静默丢掉网易云这一整条来源，
// 表现就是"逐字歌词时有时无"。旧的 /api/search/get 是另一个限流桶，常常还能用。
async function neSearch(kw, h) {
    const urls = [
        'https://music.163.com/api/search/get/web?csrf_token=&s=' + encodeURIComponent(kw) + '&type=1&offset=0&total=true&limit=10',
        'https://music.163.com/api/search/get?s=' + encodeURIComponent(kw) + '&type=1&offset=0&limit=10',
    ];
    for (const u of urls) {
        const r = await jget(u, 12000, h).catch(() => null);
        if (!r || r.status !== 200) continue;
        let j = null; try { j = JSON.parse(r.text); } catch { continue; }
        if (j.code === 405 || j.msg) continue;                 // "操作频繁，请稍候再试"
        const list = (j.result && j.result.songs) || [];
        if (list.length) return list;
    }
    return [];
}

async function neteaseOnce(q) {
    const h = { 'Referer': 'https://music.163.com/', 'Cookie': 'appver=2.0.2' };
    const songs = await neSearch(q.artist + ' ' + q.title, h);
    if (!songs.length) return null;

    // 先剔除根本不像的候选；一个都不剩就返回 null，让上游回退到 LRCLIB
    const cands = songs.filter((song) => songOk(song, q));
    if (!cands.length) return null;

    const want = q.duration || 0;
    const score = (song) => {
        let sc = song.duration ? Math.min(Math.abs(song.duration / 1000 - want), 60) : 60;
        const an = norm(((song.artists || [])[0] || {}).name), qa = norm(q.artist);
        if (qa && an && !(an.includes(qa) || qa.includes(an))) sc += 25;
        if (norm(song.name) !== norm(q.title)) sc += 3;
        return sc;
    };
    cands.sort((a, b) => score(a) - score(b));

    // 在合格候选里挑最优：优先「有逐字 + 有翻译」，同级再比时长接近度。
    // （旧版是"谁先带翻译就用谁"，可能在拿到逐字之前就定下来了）
    let best = null;
    for (const song of cands.slice(0, 5)) {
        const ly = await jget('https://music.163.com/api/song/lyric?id=' + song.id + '&lv=-1&kv=-1&tv=-1&yv=-1', 12000, h);
        if (ly.status !== 200) continue;
        let lj; try { lj = JSON.parse(ly.text); } catch { continue; }
        const artist = ((song.artists || [])[0] || {}).name || '';

        const yrcLines = parseYrc(lj.yrc && lj.yrc.lyric);
        const lrcLines = parseLrc(lj.lrc && lj.lrc.lyric);
        if (!yrcLines.length && !lrcLines.length) continue;

        // 翻译：优先 tlyric，没有就用 ytlrc（网易云的逐字翻译，实际是行级的）
        let trans = parseLrc(lj.tlyric && lj.tlyric.lyric);
        let transKind = 'tlyric';
        if (!trans.length) { trans = parseLrc(lj.ytlrc && lj.ytlrc.lyric); transKind = trans.length ? 'ytlrc' : 'none'; }

        const hasWords = yrcLines.length > 0;
        const lines = hasWords ? yrcLines : lrcLines;
        const info = trans.length ? attachTrans(lines, trans) : { pass1: 0, pass2: 0, total: 0, hit: 0 };
        // 逐字行数（真正带词时间轴的）
        const wordLines = lines.filter((l) => l.w && l.w.length > 1).length;

        const item = {
            src: hasWords ? 'netease/yrc' : 'netease',
            name: artist + ' - ' + song.name,
            duration: song.duration ? song.duration / 1000 : 0,
            lines, trans, transInfo: info, transKind, hasWords, wordLines,
        };
        const dd = (want && song.duration) ? Math.abs(song.duration / 1000 - want) : 999;
        const rank = (hasWords ? 2 : 0) + (info.hit > 0 ? 1 : 0);
        if (!best || rank > best.rank || (rank === best.rank && dd < best.dd)) best = { item, rank, dd };
        if (rank === 3 && dd <= 3) break;               // 已经完美，不必再请求
    }
    return best ? best.item : null;
}

async function netease(q) {
    let r = null;
    for (let i = 0; i < 2 && !r; i++) {
        try { r = await neteaseOnce(q); } catch { r = null; }
        if (!r) await sleep(700);
    }
    return r;
}

// ---------- 酷狗：KRC 逐字（补网易云没有逐字的歌） ----------
// KRC 是加密的：文件头 "krc1"(4 字节)，**从偏移 4 开始**整段与 16 字节固定密钥循环
// XOR，然后 zlib 压缩。两个容易踩错的点（实测出来的，网上流传的版本会解不出来）：
//   1) 密钥**不做**"前 4 字节混合"
//   2) 密文从 **偏移 4** 开始，不是 8
const KRC_KEY = Buffer.from([0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69]);
function krcDecrypt(buf) {
    try {
        if (buf.length < 32 || buf.slice(0, 4).toString('latin1') !== 'krc1') return null;
        const body = Buffer.from(buf.slice(4));
        for (let i = 0; i < body.length; i++) body[i] ^= KRC_KEY[i % 16];
        return zlib.inflateSync(body).toString('utf8');
    } catch { return null; }
}
// 明文格式: [行起始ms,行时长ms]<词起始ms(相对行首),词时长ms,0>词文本...
// 词时间是**相对行首**的，必须加上行起始，统一成绝对毫秒（和网易云 yrc 一致）
function parseKrc(text) {
    if (!text) return [];
    const out = [];
    for (const raw of String(text).split(/\r?\n/)) {
        const line = raw.replace(/^\uFEFF/, '').trim();
        const m = /^\[(\d+),(\d+)\](.*)$/.exec(line);
        if (!m) continue;
        const tMs = parseInt(m[1], 10), dMs = parseInt(m[2], 10), rest = m[3];
        const words = [];
        const rx = /<(\d+),(\d+),\d+>/g;
        let mm, prev = null, prevEnd = 0;
        while ((mm = rx.exec(rest)) !== null) {
            if (prev) { const txt = rest.slice(prevEnd, mm.index); if (txt) words.push([prev[0], prev[1], txt]); }
            prev = [tMs + parseInt(mm[1], 10), parseInt(mm[2], 10)];
            prevEnd = rx.lastIndex;
        }
        if (prev) { const tail = rest.slice(prevEnd); if (tail) words.push([prev[0], prev[1], tail]); }
        const s = words.map((w) => w[2]).join('').trim();
        if (!s) continue;
        out.push({ t: tMs / 1000, s, d: dMs, w: words });
    }
    out.sort((a, b) => a.t - b.t);
    return out;
}
async function kugou(q) {
    const h = { 'Referer': 'https://www.kugou.com/' };
    try {
        const s = await jget('https://songsearch.kugou.com/song_search_v2?keyword=' +
            encodeURIComponent(q.artist + ' ' + q.title) + '&page=1&pagesize=8&platform=WebFilter', 12000, h);
        if (s.status !== 200) return null;
        let sj = null; try { sj = JSON.parse(s.text); } catch { return null; }
        const list = ((sj.data && sj.data.lists) || []).filter((x) => {
            if (titleMatch(x.SongName, q.title) === 0) return false;
            if (artistMatch(x.SingerName, q.artist) > 0) return true;
            if (!q.duration || !x.Duration) return false;
            return Math.abs(x.Duration / 1000 - q.duration) <= 3;
        });
        if (!list.length) return null;
        const rank = (x) => (artistMatch(x.SingerName, q.artist) > 0 ? 0 : 1000) + Math.abs((x.Duration || 0) / 1000 - (q.duration || 0));
        list.sort((a, b) => rank(a) - rank(b));
        const pick = list[0];

        const kr = await jget('https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=' +
            encodeURIComponent(pick.FileHash) + '&duration=' + pick.Duration + '&hash=' + pick.FileHash, 12000, h);
        if (kr.status !== 200) return null;
        let kj = null; try { kj = JSON.parse(kr.text); } catch { return null; }
        const c = (kj.candidates || [])[0];
        if (!c || !c.id || !c.accesskey) return null;

        const d = await jget('https://lyrics.kugou.com/download?ver=1&client=pc&id=' + c.id +
            '&accesskey=' + c.accesskey + '&fmt=krc&charset=utf8', 12000, h);
        if (d.status !== 200) return null;
        let dj = null; try { dj = JSON.parse(d.text); } catch { return null; }
        if (!dj.content) return null;
        const text = krcDecrypt(Buffer.from(dj.content, 'base64'));
        if (!text) return null;
        const lines = parseKrc(text);
        if (!lines.length) return null;
        const wordLines = lines.filter((l) => l.w && l.w.length > 1).length;
        return {
            src: 'kugou/krc', name: (pick.SingerName || '') + ' - ' + (pick.SongName || ''),
            lines, hasWords: wordLines > 0, wordLines, trans: [],
        };
    } catch { return null; }
}

// ---------- QQ音乐：仅行级原文兜底 ----------
// 说明：QQ 的翻译(trans)与逐字(qrc)字段存在但实测恒为空，需要登录态才给。
// 所以这里只当"最后一道行级兜底"，不当主要来源。
async function qqMusic(q) {
    const h = { 'Referer': 'https://y.qq.com/portal/player.html' };
    try {
        const s = await jget('https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp?w=' +
            encodeURIComponent(q.artist + ' ' + q.title) + '&format=json&n=8&p=1', 12000, h);
        if (s.status !== 200) return null;
        let sj = null; try { sj = JSON.parse(s.text); } catch { return null; }
        const singerOf = (x) => (x.singer || []).map((y) => y.name).join('/');
        const list = ((sj.data && sj.data.song && sj.data.song.list) || []).filter((x) => {
            if (titleMatch(x.songname, q.title) === 0) return false;
            if (artistMatch(singerOf(x), q.artist) > 0) return true;
            if (!q.duration || !x.interval) return false;
            return Math.abs(x.interval - q.duration) <= 3;
        });
        if (!list.length) return null;
        const rank = (x) => (artistMatch(singerOf(x), q.artist) > 0 ? 0 : 1000) + Math.abs((x.interval || 0) - (q.duration || 0));
        list.sort((a, b) => rank(a) - rank(b));
        const pick = list[0];

        const lr = await jget('https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=' + pick.songmid +
            '&g_tk=5381&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0&nobase64=1', 12000, h);
        if (lr.status !== 200) return null;
        let lj = null; try { lj = JSON.parse(lr.text); } catch { return null; }
        if (!lj.lyric) return null;
        const lines = parseLrc(lj.lyric);
        if (!lines.length) return null;
        return { src: 'qq', name: singerOf(pick) + ' - ' + pick.songname, lines, hasWords: false, wordLines: 0, trans: [] };
    } catch { return null; }
}

// ---------- 缓存 ----------
function cacheKey(q) { return (norm(q.artist) + '|' + norm(q.title) + '|' + Math.round(q.duration || 0)).toLowerCase(); }
function cacheLoad(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')) || {}; } catch { return {}; } }
function cacheSave(p, c) { try { fs.writeFileSync(p, JSON.stringify(c), 'utf8'); } catch { } }
// 缓存上限：带逐字的数据每条 6~16KB，不封顶会一直长下去（文件越大越慢，也越难备份）。
// 超了就按写入时间丢掉最老的。150 条足够覆盖日常反复听的那批歌。
function cacheTrim(c, maxEntries) {
    const keys = Object.keys(c);
    if (keys.length <= maxEntries) return c;
    keys.sort((a, b) => (c[a].ts || 0) - (c[b].ts || 0));
    for (const k of keys.slice(0, keys.length - maxEntries)) delete c[k];
    return c;
}

// ---------- 主流程 ----------
(async () => {
    const reqPath = process.argv[2], outPath = process.argv[3];
    const cachePath = process.argv[4] || path.join(path.dirname(outPath), 'lyrics-cache.json');

    let q = {};
    try { q = JSON.parse(fs.readFileSync(reqPath, 'utf8')); }
    catch (e) { return out(outPath, { ok: false, err: 'bad request: ' + e.message }); }

    const key = cacheKey(q);
    const cache = cacheLoad(cachePath);
    const now = Math.floor(Date.now() / 1000);

    const hit = cache[key];
    if (!q.force && hit && hit.ver === CACHE_VER && hit.lines && hit.lines.length && (now - hit.ts) < (hit.ttl || 0)) {
        return out(outPath, Object.assign({}, hit, { cached: true }));
    }

    // LRCLIB 与网易云互不依赖 -> 并行请求。
    // 串行做是 2~8 个网络来回，新歌第一次播放要等 1~3 秒才出词；并行后只等最慢的那条链。
    const [base, ne] = await Promise.all([lrclib(q), netease(q)]);

    // 只有在"网易云没给出逐字"时才去问酷狗：KRC 请求链要三次往返，能省则省
    let kg = null;
    if (!(ne && ne.hasWords)) kg = await kugou(q);

    // QQ 只做最后的行级兜底：前面三源都没结果时才问（它没有翻译也没有逐字）
    let qqRes = null;
    if (!(ne && ne.hasWords) && !(kg && kg.hasWords) && !base && !(ne && ne.lines && ne.lines.length) && !(kg && kg.lines && kg.lines.length)) {
        qqRes = await qqMusic(q);
    }

    let result = null, info = { pass1: 0, pass2: 0, total: 0, hit: 0 }, transSrc = '';
    if (ne && ne.hasWords) {
        // 有逐字时间轴 -> 用网易云的行当主歌词（翻译已在 neteaseOnce 里配好）
        result = { src: ne.src, name: ne.name, lines: ne.lines };
        info = ne.transInfo || info;
        transSrc = ne.name + ' (' + ne.transKind + ')';
    } else if (kg && kg.hasWords) {
        // 网易云没有逐字、酷狗 KRC 有 -> 用酷狗的逐字行，翻译仍借网易云的
        result = { src: kg.src, name: kg.name, lines: kg.lines };
        if (ne && ne.trans && ne.trans.length) {
            info = attachTrans(kg.lines, ne.trans);
            transSrc = ne.name;
        }
    } else if (base) {
        result = { src: base.src, name: base.name, lines: base.lines };
        if (ne && ne.trans && ne.trans.length) {
            info = attachTrans(base.lines, ne.trans);
            transSrc = ne.name;
        }
    } else if (ne && ne.lines && ne.lines.length) {
        result = { src: ne.src, name: ne.name, lines: ne.lines };
        info = ne.transInfo || info;
    } else if (kg && kg.lines && kg.lines.length) {
        result = { src: kg.src, name: kg.name, lines: kg.lines };
    } else if (qqRes) {
        result = { src: qqRes.src, name: qqRes.name, lines: qqRes.lines };
    }

    if (!result || !result.lines.length) return out(outPath, { ok: false, err: 'no lyrics found' });

    if (info.hit > 0 && info.total < 0.20) {
        for (const ln of result.lines) delete ln.tr;
        info.dropped = true;
    }

    const transCount = result.lines.filter((l) => l.tr).length;
    const wordLines = result.lines.filter((l) => l.w && l.w.length > 1).length;
    const wordChars = result.lines.reduce((n, l) => n + ((l.w && l.w.length > 1) ? l.s.length : 0), 0);
    const allChars = result.lines.reduce((n, l) => n + l.s.length, 0);

    const payload = {
        ok: true,
        src: result.src,
        name: result.name,
        transSrc,
        transCount,
        transRate: result.lines.length ? transCount / result.lines.length : 0,
        matchInfo: info,
        lines: result.lines,
        // 逐字诊断
        hasWords: wordLines > 0,
        wordLines,
        wordRate: result.lines.length ? wordLines / result.lines.length : 0,
        charRate: allChars ? wordChars / allChars : 0,
        cached: false,
        ts: now,
        // 有翻译 -> 60 天；有逐字时间轴 -> 也缓存 60 天（数据已经够好，反复去问网易云会被限流）
        ttl: (transCount > 0 || wordLines > 0) ? 60 * 24 * 3600 : 6 * 3600,
    };
    cache[key] = {
        ver: CACHE_VER,
        ok: true, src: payload.src, name: payload.name, transSrc: payload.transSrc,
        transCount: payload.transCount, transRate: payload.transRate, matchInfo: payload.matchInfo,
        hasWords: payload.hasWords, wordLines: payload.wordLines, wordRate: payload.wordRate, charRate: payload.charRate,
        lines: payload.lines, ts: payload.ts, ttl: payload.ttl,
    };
    cacheSave(cachePath, cacheTrim(cache, 150));
    out(outPath, payload);
})();
