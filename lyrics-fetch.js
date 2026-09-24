'use strict';
// 歌词抓取器 v3（被 lyrics-overlay.ps1 通过子进程调用）
// 用法: node lyrics-fetch.js <请求json> <输出json> [缓存json]
// 请求: { artist, title, album, duration }
// 输出: { ok, src, name, lines: [{ t, s, tr }], transCount, transRate, matchInfo, cached }
//
// v3 改进：
//  1) 网易云候选按「时长最接近 + 歌手名匹配」挑，避免搜到 live/翻唱版
//  2) 翻译配对两轮：严格 ±0.8s -> 单调顺序 ±3.5s（两来源时间戳常差 1~2 秒）
//  3) 本地缓存：命中的曲子直接返回，避免反复请求导致网易云限流（"翻译时有时无"的主因）
//     有翻译的结果缓存 60 天；没翻译的结果只缓存 6 小时（以便稍后重试）

const fs = require('fs');
const path = require('path');

function out(p, obj) { try { fs.writeFileSync(p, JSON.stringify(obj), 'utf8'); } catch (e) { } }
function norm(s) { return String(s || '').replace(/\s+/g, ''); }

// ---------- 候选是否"就是这首歌"的硬判定 ----------
// 网易云对「没版权 / 已下架」的歌（例如罗大佑的部分作品）不会返回空，
// 而是返回该歌手其他热门歌或同名翻唱。旧版只对歌手名不匹配扣 25 分、
// 从不拒绝，于是会拿《东方之珠》的歌词/逐字/翻译去配《皇后大道东》。
const CACHE_VER = 3;                       // 判定逻辑变了 -> 旧缓存作废
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
    // 歌手名对不上（常见"群星""DJ版"这种条目）：只有时长几乎完全一致才认
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

// ---------- 翻译配对（两轮） ----------
function attachTrans(lines, transLines) {
    const info = { pass1: 0, pass2: 0, total: 0 };
    if (!lines || !lines.length || !transLines || !transLines.length) return info;
    const used = new Array(transLines.length).fill(false);
    const ok = (ln, tr) => tr && norm(tr.s) && norm(tr.s) !== norm(ln.s);

    for (const ln of lines) {                       // 第一轮：严格 ±0.8s
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
    for (const ln of lines) {                       // 第二轮：单调顺序 ±3.5s
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
            if (r.status === 404) return null;          // 明确不存在，重试也没用
        } catch { }
        await sleep(350 * (attempt + 1));               // 503 / 429 / 网络抖动 -> 退避重试
    }
    return null;
}
function lrclibItem(j, src, q) {
    if (!j || !j.syncedLyrics) return null;
    if (titleMatch(j.trackName, q.title) === 0) return null;   // 标题不像就别用
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
        if (!q.duration || !x.duration) return true;          // 没时长可比时放宽，靠排序压后
        return Math.abs(x.duration - q.duration) <= 8;        // 换歌手翻唱：时长必须接近
    });
    if (!cand.length) return null;
    const rank = (x) => (artistMatch(x.artistName, q.artist) > 0 ? 0 : 1000) + Math.abs((x.duration || 0) - (q.duration || 0));
    cand.sort((a, b) => rank(a) - rank(b));
    return cand[0];
}
async function lrclib(q) {
    const A = encodeURIComponent(q.artist || ''), T = encodeURIComponent(q.title || '');
    const D = Math.round(q.duration || 0);

    // 1) 精确匹配（带时长）：最可靠，绝大多数歌走这一步就结束
    if (D > 0) {
        const it = lrclibItem(await lrclibFetch('https://lrclib.net/api/get?artist_name=' + A + '&track_name=' + T + '&duration=' + D), 'lrclib/get', q);
        if (it) return it;
    }
    // 2) 精确匹配（不带时长）：时长差 1~2 秒导致 /get 匹配不上时，这一步能救回来
    {
        const it = lrclibItem(await lrclibFetch('https://lrclib.net/api/get?artist_name=' + A + '&track_name=' + T), 'lrclib/get', q);
        if (it) return it;
    }
    // 3) 结构化搜索（比自由文本稳）
    {
        const it = lrclibItem(lrclibPick(await lrclibFetch('https://lrclib.net/api/search?track_name=' + T + '&artist_name=' + A, true), q), 'lrclib/search', q);
        if (it) return it;
    }
    // 4) 自由文本搜索
    {
        const it = lrclibItem(lrclibPick(await lrclibFetch('https://lrclib.net/api/search?q=' + encodeURIComponent((q.artist || '') + ' ' + (q.title || '')), true), q), 'lrclib/search', q);
        if (it) return it;
    }
    // 5) 只搜歌名：简繁 / 别名差异时的兜底，仍然要求标题匹配（艺人或时长作为排序）
    {
        const it = lrclibItem(lrclibPick(await lrclibFetch('https://lrclib.net/api/search?q=' + T, true), q), 'lrclib/search', q);
        if (it) return it;
    }
    return null;
}

// ---------- 网易云搜索（双接口 + 频率检测） ----------
// 坑：/api/search/get/web 被限流时返回的是 HTTP 200 + {"code":405,"msg":"操作频繁"}，
// 只看 status 会把它当成"没有结果"，于是静默丢掉网易云这一整条来源。
// 旧的 /api/search/get 是另一个限流桶，常常还能用，所以两个都试。
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

// ---------- 网易云（候选打分 + 失败重试一次） ----------
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

    // 依次尝试前几个候选，优先返回「带翻译」的那一个
    let fallback = null;
    for (const song of cands.slice(0, 4)) {
        const ly = await jget('https://music.163.com/api/song/lyric?id=' + song.id + '&lv=-1&kv=-1&tv=-1', 12000, h);
        if (ly.status !== 200) continue;
        let lj; try { lj = JSON.parse(ly.text); } catch { continue; }
        const lines = parseLrc(lj.lrc && lj.lrc.lyric);
        if (!lines.length) continue;
        const trans = parseLrc(lj.tlyric && lj.tlyric.lyric);
        const artist = ((song.artists || [])[0] || {}).name || '';
        const info = trans.length ? attachTrans(lines, trans) : { pass1: 0, pass2: 0, total: 0, hit: 0 };
        const item = { src: 'netease', name: artist + ' - ' + song.name, duration: song.duration ? song.duration / 1000 : 0, lines, trans, transInfo: info };
        if (info.hit > 0) return item;          // 找到带翻译的，直接用
        if (!fallback) fallback = item;         // 记下第一个可用的作为兜底
    }
    return fallback;
}

async function netease(q) {
    let r = null;
    for (let i = 0; i < 2 && !r; i++) {         // 失败重试一次（限流常是瞬时的）
        try { r = await neteaseOnce(q); } catch { r = null; }
        if (!r) await sleep(700);
    }
    return r;
}

// ---------- 缓存 ----------
function cacheKey(q) { return (norm(q.artist) + '|' + norm(q.title) + '|' + Math.round(q.duration || 0)).toLowerCase(); }
function cacheLoad(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')) || {}; } catch { return {}; } }
function cacheSave(p, c) { try { fs.writeFileSync(p, JSON.stringify(c), 'utf8'); } catch { } }

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

    const base = await lrclib(q);
    const ne = await netease(q);

    let result = null, info = { pass1: 0, pass2: 0, total: 0, hit: 0 };
    if (base) {
        result = base;
        if (ne && ne.trans && ne.trans.length) {
            info = attachTrans(base.lines, ne.trans);
            result.transSrc = ne.name;
        }
    } else if (ne && ne.lines && ne.lines.length) {
        result = { src: ne.src, name: ne.name, lines: ne.lines };
        info = ne.transInfo || info;
    }

    if (!result || !result.lines.length) return out(outPath, { ok: false, err: 'no lyrics found' });

    // 有翻译但配对率过低 -> 丢弃翻译（宁缺勿错）。阈值放宽到 20%：
    // 两轮配对后仍然很低，通常说明这首本来就几乎没翻译行，而不是错位。
    if (info.hit > 0 && info.total < 0.20) {
        for (const ln of result.lines) delete ln.tr;
        info.dropped = true;
    }

    const transCount = result.lines.filter((l) => l.tr).length;
    const payload = {
        ok: true,
        src: result.src,
        name: result.name,
        transSrc: result.transSrc || '',
        transCount,
        transRate: transCount / result.lines.length,
        matchInfo: info,
        lines: result.lines,
        cached: false,
        ts: now,
        // 有翻译缓存 60 天；没有就只缓存 6 小时，方便稍后重试（网易云限流是瞬时的）
        ttl: transCount > 0 ? 60 * 24 * 3600 : 6 * 3600,
    };
    cache[key] = {
        ver: CACHE_VER,
        ok: true, src: payload.src, name: payload.name, transSrc: payload.transSrc,
        transCount: payload.transCount, transRate: payload.transRate,
        matchInfo: payload.matchInfo, lines: payload.lines, ts: payload.ts, ttl: payload.ttl,
    };
    cacheSave(cachePath, cache);
    out(outPath, payload);
})();
